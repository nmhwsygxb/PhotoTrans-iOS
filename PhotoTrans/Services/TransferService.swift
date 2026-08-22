import Foundation
import Network
import Combine

/// Owns the file-transfer pipeline on both sides (send + receive).
///
/// Wire protocol (compatible with the Android build & the 互传联盟 HTTP PUT):
///   Sender  ->  "PUT /<percent-encoded-name> HTTP/1.1\r\nContent-Length: <n>\r\n\r\n"
///   Sender  ->  <n raw file bytes>
///   Receiver -> "HTTP/1.1 200 OK\r\n\r\n"
///
/// Handshake uses NetworkService's PT-HI text-based handshake (compatible
/// with the Android / HarmonyOS versions): sender writes "PT-HI <name>\n".
final class TransferService: NSObject, ObservableObject {
    var settings = AppSettings()
    private let modelStore: LocalModelStore
    private let formatDetector: FormatDetector
    private let networkService: NetworkService
    private let fileManager = FileManager.default
    private let receiveQueue = DispatchQueue(label: "com.phototrans.receive", qos: .userInitiated)

    @Published private(set) var activeTransfers: [TransferProgress] = []
    @Published private(set) var incomingFiles: [URL] = []

    private var speedTimers: [UUID: Timer] = [:]
    private var lastSample: [UUID: (Date, Int64)] = [:]
    private var latestConnection: NWConnection?
    private var peerName: String?
    /// Per-connection receive buffer for assembling HTTP headers across TCP segments.
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

    override init() {
        fatalError("use init(networkService:modelStore:formatDetector:)")
    }

    init(networkService: NetworkService,
         modelStore: LocalModelStore,
         formatDetector: FormatDetector) {
        self.networkService = networkService
        self.modelStore = modelStore
        self.formatDetector = formatDetector
        super.init()
        // Receive inbound file transfers over fully-handshaken connections.
        networkService.handshakeCompleteHandler = { [weak self] connection, peerName in
            self?.registerPeer(peerName)
            self?.handleInbound(connection)
        }
    }

    // MARK: - Public API

    /// Send a local file to a connected remote over TCP.
    func sendFile(url: URL) {
        guard let connection = latestConnection else {
            DispatchQueue.main.async { self.postError("Not connected. Connect to a device first.") }
            return
        }
        let transfer = TransferProgress(name: url.lastPathComponent,
                                        totalBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                                        phase: .connecting)
        DispatchQueue.main.async { self.activeTransfers.append(transfer) }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                // Build and send the HTTP PUT request frame (compatible with
                // Android / 互传联盟). Delegated to NetworkService for reuse.
                let headerData = NetworkService.buildHttpPutHeader(fileName: url.lastPathComponent,
                                                                    contentLength: transfer.totalBytes)
                connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.failTransfer(transfer, error: error)
                        return
                    }
                    self.startSpeedTimer(for: transfer)
                    let chunk = self.settings.transferChunkSize
                    var sent: Int64 = 0
                    while true {
                        let data = handle.readData(ofLength: chunk)
                        if data.isEmpty { break }
                        connection.send(content: data, completion: .contentProcessed { sendError in
                            if let sendError {
                                self.failTransfer(transfer, error: sendError)
                                return
                            }
                            sent += Int64(data.count)
                            DispatchQueue.main.async {
                                if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                                    self.activeTransfers[idx].transferredBytes = sent
                                    self.activeTransfers[idx].phase = .running
                                }
                            }
                            self.lastSample[transfer.id] = (Date(), sent)
                        })
                        if transfer.totalBytes > 0 && sent >= transfer.totalBytes { break }
                    }
                    // Read short response line.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
                        guard let self else { return }
                        let ok = data?.isEmpty == false && error == nil
                        self.completeTransfer(transfer)
                    }
                })
            } catch {
                self.failTransfer(transfer, error: error)
            }
        }
    }

    /// Send every URL the user picked from the document / photo picker.
    /// For each file, creates a new connection (compatible with Android/HarmonyOS
    /// receivers that close the socket after one PUT).
    func sendFiles(urls: [URL], host: String, port: UInt16) {
        var remaining = Array(urls)
        func sendNext() {
            guard !remaining.isEmpty else { return }
            let url = remaining.removeFirst()
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(PhotoTransProtocol.defaultTransferPort),
                                          using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    self.sendFileOnConnection(connection, url: url) {
                        sendNext()
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        sendNext()
    }

    /// Send one file on a freshly-connected socket (no prior handshake needed —
    /// the connection is new so the receiver will PT-HI handshake first).
    private func sendFileOnConnection(_ connection: NWConnection, url: URL, completion: @escaping () -> Void) {
        let fileName = url.lastPathComponent
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let transfer = TransferProgress(name: fileName, totalBytes: fileSize, phase: .connecting)
        DispatchQueue.main.async { self.activeTransfers.append(transfer) }

        // 1. Send PT-HI handshake (same connection, iOS receiver expects this)
        let deviceName = UIDeviceHelper.current.modelName
        let handshakeLine = "\(PhotoTransProtocol.handshakePrefix) \(deviceName)\n"
        connection.send(content: Data(handshakeLine.utf8), completion: .contentProcessed { error in
            if let error { self.failTransfer(transfer, error: error); return }
            // 2. Read remote PT-HI reply
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                // ignore the reply; just proceed to send the file
                self.streamFileOnConnection(connection, url: url, transfer: transfer, completion: completion)
            }
        })
    }

    /// Stream file body and read the HTTP response.
    private func streamFileOnConnection(_ connection: NWConnection, url: URL,
                                         transfer: TransferProgress, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let headerData = NetworkService.buildHttpPutHeader(fileName: url.lastPathComponent,
                                                                    contentLength: transfer.totalBytes)
                connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error { self.failTransfer(transfer, error: error); return }
                    self.startSpeedTimer(for: transfer)
                    let chunk = self.settings.transferChunkSize
                    var sent: Int64 = 0
                    while true {
                        let data = handle.readData(ofLength: chunk)
                        if data.isEmpty { break }
                        connection.send(content: data, completion: .contentProcessed { sendError in
                            if let sendError { self.failTransfer(transfer, error: sendError); return }
                            sent += Int64(data.count)
                            DispatchQueue.main.async {
                                if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                                    self.activeTransfers[idx].transferredBytes = sent
                                    self.activeTransfers[idx].phase = .running
                                }
                            }
                            self.lastSample[transfer.id] = (Date(), sent)
                        })
                        if transfer.totalBytes > 0 && sent >= transfer.totalBytes { break }
                    }
                    // Read response
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
                        guard let self else { return }
                        // Check response status (200 OK expected)
                        let ok = data?.isEmpty == false
                        if ok {
                            self.completeTransfer(transfer)
                        } else {
                            self.failTransfer(transfer, error: TransferError.writeFailed)
                        }
                        // Close the per-file connection
                        connection.cancel()
                        completion()
                    }
                })
            } catch {
                self.failTransfer(transfer, error: error)
                completion()
            }
        }
    }

    func registerPeer(_ name: String?) {
        peerName = name
    }

    /// Store the latest handshaken outbound connection so sends target it.
    func adoptConnection(_ connection: NWConnection) {
        latestConnection = connection
    }

    var currentPeerName: String? { peerName }

    func cancelActiveTransfers() {
        speedTimers.values.forEach { $0.invalidate() }
        speedTimers.removeAll()
        lastSample.removeAll()
        DispatchQueue.main.async {
            self.activeTransfers.removeAll()
        }
    }

    // MARK: - Inbound (receive)

    private func handleInbound(_ connection: NWConnection) {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            let key = ObjectIdentifier(connection)
            // Check for data that arrived with the handshake (same TCP segment).
            if let pending = self.networkService.takePendingData(for: connection) {
                self.receiveBuffers[key] = pending
            }
            self.readRequestLine(connection)
        }
    }

    private func readRequestLine(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { connection.cancel(); return }
            guard let data, !data.isEmpty else { connection.cancel(); return }

            // Accumulate into the per-connection buffer.
            var buf = self.receiveBuffers.removeValue(forKey: key) ?? Data()
            buf.append(data)

            // Try to find the header terminator in the accumulated buffer.
            guard let headerStr = String(data: buf, encoding: .utf8),
                  let headerRange = headerStr.range(of: "\r\n\r\n") else {
                // Incomplete header; save buffer and keep reading.
                self.receiveBuffers[key] = buf
                self.readRequestLine(connection)
                return
            }

            // Found complete header – extract header text and body bytes.
            let headerEnd = headerStr.utf8.distance(from: headerStr.startIndex, to: headerRange.upperBound)
            let bodyPrefix = buf[headerEnd...]
            try? self.parseHeader(Data(String(headerStr[..<headerRange.lowerBound]).utf8),
                                  bodyPrefix: Data(bodyPrefix), connection: connection)
        }
    }

    private func parseHeader(_ headerData: Data, bodyPrefix: Data, connection: NWConnection) {
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            reject(connection, reason: "400 Bad Request")
            return
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.hasPrefix("PUT ") else {
            reject(connection, reason: "400 Bad Request")
            return
        }
        let path = requestLine
            .replacingOccurrences(of: "PUT ", with: "")
            .replacingOccurrences(of: " HTTP/1.1", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Sanitize: prevent path traversal by stripping slashes and dots.
        let fileName = (path.removingPercentEncoding ?? path)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        guard !fileName.isEmpty, fileName != "/" else {
            reject(connection, reason: "400 Bad Request")
            return
        }

        var contentLength: Int64 = 0
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.split(separator: ":").map(String.init)[1].trimmingCharacters(in: .whitespaces)
                contentLength = Int64(value) ?? 0
            }
        }
        guard contentLength > 0 else {
            reject(connection, reason: "411 Length Required")
            return
        }

        // Safety cap.
        if contentLength > settings.maxReceiveFileSize {
            reject(connection, reason: "413 Payload Too Large")
            return
        }

        let transfer = TransferProgress(name: fileName, totalBytes: contentLength, phase: .running)
        DispatchQueue.main.async {
            self.activeTransfers.append(transfer)
            self.startSpeedTimer(for: transfer)
        }

        // Write body to Documents/PhotoTrans (media gets mirrored to Photos in
        // saveReceivedFile, gallery-visible for images/videos).
        let destDir = Self.receiveDirectory()
        let destURL = destDir.appendingPathComponent(fileName)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: destURL.path, contents: bodyPrefix)
        var written = Int64(bodyPrefix.count)
        self.lastSample[transfer.id] = (Date(), written)

        receiveBody(connection, remaining: contentLength - Int64(bodyPrefix.count),
                    destURL: destURL, transfer: transfer, written: written)
    }

    private func receiveBody(_ connection: NWConnection, remaining: Int64,
                             destURL: URL, transfer: TransferProgress, written: Int64) {
        guard remaining > 0 else {
            finishReceive(connection, destURL: destURL, transfer: transfer)
            return
        }
        receiveQueue.async { [weak self] in
            self?.receiveBodyChunk(connection, remaining: remaining, destURL: destURL, transfer: transfer, written: written)
        }
    }

    private func receiveBodyChunk(_ connection: NWConnection, remaining: Int64,
                                  destURL: URL, transfer: TransferProgress, written: Int64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int(min(remaining, 128 * 1024))) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { connection.cancel(); self.failTransfer(transfer, error: error); return }
            guard let data, !data.isEmpty else {
                connection.cancel()
                self.failTransfer(transfer, error: TransferError.writeFailed)
                return
            }
            if let handle = try? FileHandle(forWritingTo: destURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
            let newWritten = written + Int64(data.count)
            self.lastSample[transfer.id] = (Date(), newWritten)
            DispatchQueue.main.async {
                if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                    self.activeTransfers[idx].transferredBytes = newWritten
                }
            }
            let newRemaining = remaining - Int64(data.count)
            if newRemaining <= 0 {
                self.finishReceive(connection, destURL: destURL, transfer: transfer)
            } else {
                self.receiveBody(connection, remaining: newRemaining, destURL: destURL, transfer: transfer, written: newWritten)
            }
        }
    }

    private func finishReceive(_ connection: NWConnection, destURL: URL, transfer: TransferProgress) {
        // Acknowledge.
        connection.send(content: NetworkService.buildHttpResponse(status: "200 OK"),
                        completion: .contentProcessed { _ in connection.cancel() })
        DispatchQueue.main.async {
            if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                self.activeTransfers[idx].transferredBytes = transfer.totalBytes
                self.activeTransfers[idx].phase = .completed
            }
            self.incomingFiles.append(destURL)
            self.saveReceivedFileToPhotosIfPossible(destURL)
        }
    }

    private func reject(_ connection: NWConnection, reason: String) {
        let resp = NetworkService.buildHttpResponse(status: reason)
        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Photos mirror

    private func saveReceivedFileToPhotosIfPossible(_ url: URL) {
        guard settings.storeReceivedFilesInPhotos else { return }
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp"].contains(ext)
        let isVideo = ["mp4", "mov", "m4v", "3gp"].contains(ext)
        guard isImage || isVideo else { return }
        #if canImport(Photos)
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isImage ? .photo : .video, fileURL: url, options: nil)
        } completionHandler: { _, error in
            if let error {
                print("Photos mirror failed: \(error)")
            }
        }
        #endif
    }

    // MARK: - Progress / speed helpers

    private func startSpeedTimer(for transfer: TransferProgress) {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  let (prevDate, prevBytes) = self.lastSample[transfer.id] else { return }
            let now = Date()
            let delta = now.timeIntervalSince(prevDate)
            let bytes = transfer.transferredBytes - prevBytes
            var speed: Double = 0
            if delta > 0, bytes >= 0 { speed = Double(bytes) / delta }
            DispatchQueue.main.async {
                if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                    self.activeTransfers[idx].currentSpeedBytesPerSecond = speed
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        speedTimers[transfer.id] = timer
    }

    private func completeTransfer(_ transfer: TransferProgress) {
        speedTimers[transfer.id]?.invalidate()
        speedTimers.removeValue(forKey: transfer.id)
        DispatchQueue.main.async {
            if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                self.activeTransfers[idx].transferredBytes = transfer.totalBytes
                self.activeTransfers[idx].phase = .completed
            }
        }
    }

    private func failTransfer(_ transfer: TransferProgress, error: Error) {
        speedTimers[transfer.id]?.invalidate()
        speedTimers.removeValue(forKey: transfer.id)
        DispatchQueue.main.async {
            if let idx = self.activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                self.activeTransfers[idx].phase = .failed
                self.activeTransfers[idx].errorDescription = error.localizedDescription
            }
        }
    }

    private func postError(_ message: String) {
        #if DEBUG
        print("TransferError: \(message)")
        #endif
    }

    // MARK: - Storage locations

    /// Publicly accessible download directory: Documents/PhotoTrans.
    static func receiveDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PhotoTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

import Photos