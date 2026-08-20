import Foundation
import Network
import Combine

/// A discovered or manually added remote device.
struct DeviceInfo: Identifiable, Hashable, Sendable {
    var id: String {
        serviceName ?? addressString ?? host ?? UUID().uuidString
    }
    var distanceMode: TransferMode
    var serviceName: String?
    var hostname: String?
    var ipAddress: String?
    var host: String?
    var port: UInt16?
    var lastSeen: Date
    var isManual: Bool

    var displayName: String {
        var name = (serviceName?.replacingOccurrences(of: PhotoTransProtocol.serviceInstancePrefix, with: "") ?? "")
        if name.isEmpty { name = hostname ?? ipAddress ?? host ?? "Unknown device" }
        return name
    }
}

/// A device discovered on the LAN via Bonjour.
struct NearDevice: Sendable {
    let name: String
    let endpoint: NWEndpoint
}

/// Constants for the PhotoTrans wire protocol.
enum PhotoTransProtocol {
    static let serviceType = "_phototrans._tcp"
    static let serviceDomain = "local."
    static let serviceInstancePrefix = "PhotoTrans-"
    /// Magic token prefixed to every handshake frame ("PT-HI-1").
    static let magicToken = "PT-HI-1"
    /// 4-byte big-endian length header for the handshake payload.
    static let protonHeaderSize = 4
}

/// Handshake frame exchanged at connection start ("PT-HI" protocol).
struct HandshakeMessage: Codable, Sendable {
    enum Kind: String, Codable {
        case hello
        case helloAck
        case error
    }
    var kind: Kind
    var deviceName: String
    var deviceBrand: DeviceBrand
    var appVersion: String
    var magicToken: String = PhotoTransProtocol.magicToken
    var payload: String?
}

/// Low-level networking abstraction over NWConnection / NWListener.
///
/// Responsibilities:
///  - Advertise this device over Bonjour (Near mode).
///  - Discover peers advertising the same service (Near mode).
///  - Accept incoming TCP connections and run the PT-HI handshake.
///  - Establish outbound TCP connections and run the PT-HI handshake.
///
/// After a successful handshake the raw `NWConnection` is returned so that
/// `TransferService` can run the file-transfer payload over the same socket.
protocol NetworkServiceProtocol: ObservableObject {
    var discoveredDevices: [NearDevice] { get }
    var isAdvertising: Bool { get }
    var isDiscovering: Bool { get }
    var localHostIP: String? { get }
    var port: UInt16 { get }

    func startAdvertising(deviceName: String, brand: DeviceBrand)
    func stopAdvertising()
    func startDiscovery()
    func stopDiscovery()

    func connect(host: String, port: UInt16) -> AnyPublisher<NWConnection, Error>
}

final class NetworkService: NSObject, NetworkServiceProtocol {
    @Published var discoveredDevices: [NearDevice] = []
    @Published private(set) var isAdvertising = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var localHostIP: String?
    @Published private(set) var port: UInt16 = 47600

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let sendQueue = DispatchQueue(label: "com.phototrans.network.send", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.phototrans.network.connections", qos: .userInitiated)

    /// Settings reference for handshake timeouts; mutated externally.
    weak var onSettingsChanged: ((DispatchQueue) -> Void)?
    var settings = AppSettings()

    private var handshakeHandlers: [ObjectIdentifier: (NWConnection) -> Void] = [:]

    override init() {
        super.init()
        probeLocalIP()
    }

    // MARK: - Local IP probing

    private func probeLocalIP() {
        enumerateIPv4Addresses { [weak self] preferred in
            DispatchQueue.main.async {
                if let preferred, !preferred.isEmpty, self?.localHostIP == nil {
                    self?.localHostIP = preferred
                }
            }
        }
    }

    /// Enumerate active, non-loopback IPv4 addresses, preferring private LAN
    /// ranges (RFC 1918) which are what Bonjour and Far-mode QR flows need.
    private func enumerateIPv4Addresses(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var addresses: [String] = []
            var candidates: [String] = []

            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddr) == 0 else {
                completion(nil)
                return
            }
            defer { freeifaddrs(ifaddr) }

            var cursor = ifaddr
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let addr = entry.pointee.ifa_addr else { continue }
                if addr.pointee.sa_family != UInt8(AF_INET) { continue }

                let flags = Int32(entry.pointee.ifa_flags)
                let up = (flags & IFF_UP) != 0
                let loopback = (flags & IFF_LOOPBACK) != 0
                guard up && !loopback else { continue }

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    candidates.append(ip)
                    if isPrivateIPv4(ip) { addresses.append(ip) }
                }
            }
            completion((addresses.count > 0 ? addresses.first : candidates.first))
        }
    }

    private func isPrivateIPv4(_ ip: String) -> Bool {
        // RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    // MARK: - Advertising (Near mode)

    func startAdvertising(deviceName: String, brand: DeviceBrand) {
        guard !isAdvertising else { return }
        do {
            let list = try NWListener(using: .tcp, on: .any)
            listener = list
            port = list.port?.rawValue ?? 47600
            list.service = NWListener.Service(name: deviceName, type: PhotoTransProtocol.serviceType)
            list.newConnectionHandler = { [weak self] connection in
                self?.handleIncoming(connection)
            }
            list.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isAdvertising = true
                case .failed(let error):
                    print("NWListener failed: \(error)")
                    self?.isAdvertising = false
                default:
                    break
                }
            }
            list.start(queue: connectionQueue)
        } catch {
            print("Failed to create NWListener: \(error)")
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
    }

    // MARK: - Discovery (Near mode)

    func startDiscovery() {
        // Covers an already-running browser.
        guard !isDiscovering else { return }
        let parameters = NWParameters()
        let browser = NWBrowser(for: .bonjour(type: PhotoTransProtocol.serviceType,
                                               domain: PhotoTransProtocol.serviceDomain),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isDiscovering = true
            case .failed(let error):
                print("NWBrowser failed: \(error)")
                self?.isDiscovering = false
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> NearDevice? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return NearDevice(name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                self?.discoveredDevices = devices
            }
        }
        browser.start(queue: connectionQueue)
        self.browser = browser
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isDiscovering = false
        discoveredDevices = []
    }

    // MARK: - Incoming connections

    private func handleIncoming(_ connection: NWConnection) {
        performHandshake(on: connection) { [weak self] result in
            switch result {
            case .success(let conn):
                self?.handshakeCompleteHandler?(conn)
            case .failure(let error):
                print("Inbound handshake failed: \(error)")
                connection.cancel()
            }
        }
    }

    /// Set by TransferService to receive fully-handshaken connections.
    var handshakeCompleteHandler: ((NWConnection) -> Void)?

    // MARK: - Outbound connections

    func connect(host: String, port: UInt16) -> AnyPublisher<NWConnection, Error> {
        Future { [weak self] promise in
            guard let self else {
                promise(.failure(TransferError.connectionFailed))
                return
            }
            let parameters = NWParameters.tcp
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: port)!,
                                          using: parameters)
            self.performHandshake(on: connection) { result in
                switch result {
                case .success(let conn):
                    promise(.success(conn))
                case .failure(let error):
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: - PT-HI handshake

    /// Establishes the connection, writes the "PT-HI" hello with a length
    /// prefix, reads the peer's hello, and validates the magic token.
    func performHandshake(on connection: NWConnection,
                          completion: @escaping (Result<NWConnection, Error>) -> Void) {
        let key = ObjectIdentifier(connection)
        handshakeHandlers[key] = completion

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHello(on: connection, key: key, completion: completion)
            case .failed(let error):
                self.finishHandshake(key: key, result: .failure(error), connection: connection)
            default:
                break
            }
        }
        connection.start(queue: connectionQueue)

        let timeout = 8.0
        connectionQueue.asyncAfter(deadline: .now() + timeout) {
            if self.handshakeHandlers[key] != nil {
                self.finishHandshake(key: key,
                                     result: .failure(TransferError.handshakeFailed("Handshake timed out")),
                                     connection: connection)
            }
        }
    }

    private func sendHello(on connection: NWConnection,
                           key: ObjectIdentifier,
                           completion: @escaping (Result<NWConnection, Error>) -> Void) {
        let hello = HandshakeMessage(kind: .hello,
                                     deviceName: UIDeviceHelper.current.modelName,
                                     deviceBrand: .apple,
                                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        guard let body = try? JSONEncoder().encode(hello),
              let magic = PhotoTransProtocol.magicToken.data(using: .utf8) else {
            finishHandshake(key: key, result: .failure(TransferError.handshakeFailed("Encode failed")), connection: connection)
            return
        }
        var frame = magic
        var length = UInt32(body.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(body)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finishHandshake(key: key, result: .failure(error), connection: connection)
            } else {
                self?.receiveHelloReply(on: connection, key: key, completion: completion)
            }
        })
    }

    private func receiveHelloReply(on connection: NWConnection,
                                   key: ObjectIdentifier,
                                   completion: @escaping (Result<NWConnection, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: PhotoTransProtocol.magicToken.count,
                           maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finishHandshake(key: key, result: .failure(error), connection: connection)
                return
            }
            guard let data = data, let magic = PhotoTransProtocol.magicToken.data(using: .utf8),
                  data.count >= magic.count,
                  data.starts(with: magic) else {
                if isComplete {
                    self.finishHandshake(key: key,
                                         result: .failure(TransferError.handshakeFailed("Peer closed / bad magic")),
                                         connection: connection)
                } else {
                    self.receiveHelloReply(on: connection, key: key, completion: completion)
                }
                return
            }
            self.finishHandshake(key: key, result: .success(connection), connection: connection)
        }
    }

    private func finishHandshake(key: ObjectIdentifier,
                                 result: Result<NWConnection, Error>,
                                 connection: NWConnection) {
        guard let handler = handshakeHandlers.removeValue(forKey: key) else { return }
        if case .failure = result { connection.cancel() }
        handler(result)
    }
}

/// Lightweight device-name helper for handshakes; avoids heavy UIKit on non-iOS
/// targets while still identifying the machine.
enum UIDeviceHelper {
    static var current: DeviceIdentity {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let bytes = mirror.children.map { $0.value as! Int8 }
        var name = String(cString: bytes)
        // For iOS, expose a friendly name.
        #if os(iOS)
        name = friendlyName(for: name)
        #endif
        return DeviceIdentity(modelName: name)
    }

    #if os(iOS)
    private static func friendlyName(for raw: String) -> String {
        switch raw {
        case "iPhone14,2", "iPhone14,3": return "iPhone 14 Pro"
        case "iPhone14,7", "iPhone14,8" : return "iPhone 14"
        case "iPhone15,2", "iPhone15,3" : return "iPhone 15 Pro"
        case "iPhone15,4", "iPhone15,5" : return "iPhone 15"
        case "iPad13,8"                 : return "iPad Pro"
        default                         : return raw
        }
    }
    #endif
}

struct DeviceIdentity: Sendable {
    let modelName: String
}