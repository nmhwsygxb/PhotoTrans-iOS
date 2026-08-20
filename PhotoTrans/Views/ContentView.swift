import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import AVFoundation
import Network
import UniformTypeIdentifiers

// MARK: - Device list model

/// Wraps discovered + manually entered devices for the main list UI.
final class DeviceListModel: ObservableObject {
    @Published var nearDevices: [NearDeviceRow] = []
    @Published var isSearching = false

    struct NearDeviceRow: Identifiable {
        let id = UUID()
        let name: String
        let endpoint: NWEndpoint
    }

    private let networkService: NetworkServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    init(networkService: NetworkServiceProtocol) {
        self.networkService = networkService
        networkService.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.nearDevices = devices.map {
                    NearDeviceRow(name: $0.name, endpoint: $0.endpoint)
                }
                self?.isSearching = !devices.isEmpty
            }
            .store(in: &cancellables)
    }

    func refresh() {
        networkService.stopDiscovery()
        networkService.startDiscovery()
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    @State private var mode: TransferMode = .near
    @State private var ipInput = ""
    @State private var peerHost: String?
    @State private var peerPort: UInt16 = 47600
    @State private var peerName: String?
    @State private var showQR = false
    @State private var showScanner = false
    @State private var showDocumentPicker = false
    @State private var pickedURLs: [URL] = []
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    deviceSection
                    progressSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("PhotoTrans")
            .onAppear {
                // Always listen for inbound connections (both modes) so the
                // peer can reach this device right after connecting.
                appState.networkService.startAdvertising(
                    deviceName: UIDeviceHelper.current.modelName,
                    brand: .apple)
                if mode == .near {
                    appState.networkService.startDiscovery()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: ModelManagementView()) {
                        Image(systemName: "square.stack.3d.up")
                    }
                }
            }
            .sheet(isPresented: $showQR) { MyQRView(appState: appState) }
            .sheet(isPresented: $showScanner) { QRScannerView { value in
                showScanner = false
                handleScanned(value)
            } }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker { urls in
                    if peerHost != nil {
                        pickedURLs = urls
                        appState.transferService.sendFiles(urls: urls)
                        toast = "已发送 \(urls.count) 个文件"
                    } else {
                        toast = "请先连接设备"
                    }
                }
            }
        }
    }

    // MARK: Connection card

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("模式", selection: $mode) {
                Text("近距离").tag(TransferMode.near)
                Text("远距离").tag(TransferMode.far)
            }
            .pickerStyle(.segmented)

            if let peerName {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已连接: \(peerName)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("断开") {
                        disconnect()
                    }
                    .font(.footnote)
                }
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("选择文件发送", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if mode == .near {
                HStack {
                    Button(action: {
                        appState.networkService.startAdvertising(
                            deviceName: UIDeviceHelper.current.modelName,
                            brand: .apple)
                        appState.networkService.startDiscovery()
                        toast = "正在搜索附近设备…"
                    }) {
                        Label("搜索设备", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("显示二维码", systemImage: "qrcode") {
                        showQR = true
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // Far mode: IP + port + QR
                HStack {
                    TextField("对方 IP (如 192.168.1.10)", text: $ipInput)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    Button("连接") {
                        connectFar()
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack {
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫码连接", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showQR = true
                    } label: {
                        Label("我的二维码", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Devices

    @ViewBuilder
    private var deviceSection: some View {
        if mode == .near {
            VStack(alignment: .leading, spacing: 8) {
                Text("附近设备")
                    .font(.headline)
                if appState.deviceList.nearDevices.isEmpty {
                    Text(appState.deviceList.isSearching ? "正在搜索…" : "暂无设备，点击上方「搜索设备」")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.deviceList.nearDevices) { device in
                        HStack {
                            Image(systemName: "iphone")
                            Text(device.name)
                            Spacer()
                            Button("连接") {
                                connectNear(device)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        if !appState.transferService.activeTransfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("传输队列")
                    .font(.headline)
                ForEach(appState.transferService.activeTransfers) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(t.percentText).font(.footnote.monospacedDigit())
                        }
                        ProgressView(value: t.fractionComplete)
                        HStack {
                            Text("\(t.speedText())\(t.etaText == "—" ? "" : " · \(t.etaText)")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(phaseLabel(t.phase))
                                .font(.caption2)
                                .foregroundColor(phaseColor(t.phase))
                        }
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func phaseLabel(_ phase: TransferPhase) -> String {
        switch phase {
        case .idle: return "等待"
        case .negotiating: return "握手"
        case .connecting: return "连接中"
        case .running: return "传输中"
        case .paused: return "暂停"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "取消"
        }
    }

    private func phaseColor(_ phase: TransferPhase) -> Color {
        switch phase {
        case .completed: return .green
        case .failed, .cancelled: return .red
        case .running: return .blue
        default: return .secondary
        }
    }

    // MARK: Actions

    private func connectNear(_ device: DeviceListModel.NearDeviceRow) {
        if case let .hostPort(hostAddr, port) = device.endpoint {
            connectFar(host: "\(hostAddr)", port: port.rawValue)
            return
        }
        // Bonjour endpoint without explicit ip:port — resolve via the hostname.
        let host = device.endpoint.host?.debugDescription ?? ""
        networkConnect(host: host, port: 47600)
    }

    private func connectFar() {
        let parsed = parseHostPort(ipInput)
        if let parsed {
            connectFar(host: parsed.host, port: parsed.port)
        } else {
            toast = "地址格式不正确"
        }
    }

    private func connectFar(host: String, port: UInt16) {
        let pub = appState.networkService.connect(host: host, port: port)
        pub.sink { completion in
            if case .failure(let error) = completion {
                DispatchQueue.main.async { self.toast = "连接失败: \(error.localizedDescription)" }
            }
        } receiveValue: { connection in
            DispatchQueue.main.async {
                self.peerHost = host
                self.peerPort = port
                self.peerName = host
                self.appState.transferService.adoptConnection(connection)
                self.appState.transferService.registerPeer(host)
                self.toast = "已连接: \(host)"
            }
        }
        .store(in: &cancellables)
    }

    /// Connect using a hostname (Bonjour) — resolves via NWConnection.
    private func networkConnect(host: String, port: UInt16) {
        connectFar(host: host, port: port)
    }

    private func handleScanned(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseHostPort(trimmed) {
            ipInput = trimmed
            connectFar(host: parsed.host, port: parsed.port)
        } else {
            toast = "二维码内容不是有效地址"
        }
    }

    private func disconnect() {
        peerHost = nil
        peerPort = 47600
        peerName = nil
        appState.transferService.cancelActiveTransfers()
        toast = "已断开连接"
    }

    private func parseHostPort(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.contains("]:"),
           let end = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let portStr = trimmed[trimmed.index(after: end)...].dropFirst()
            if let port = UInt16(portStr) {
                return (host, port)
            }
            return (host, 47600)
        }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                return (String(parts[0]), port)
            }
        }
        return (trimmed, 47600)
    }

    @State private var cancellables = Set<AnyCancellable>()
}

// MARK: - My QR view

struct MyQRView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(spacing: 20) {
            Text("扫码连接我")
                .font(.headline)
            if let qrImage = qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 120))
                    .foregroundColor(.gray)
            }
            Text(qrContent)
                .font(.footnote.monospaced())
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
                .multilineTextAlignment(.center)
            Text("对方在「远距离」输入此 IP 或扫码即可连接")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("关闭") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var qrContent: String {
        let ip = appState.networkService.localHostIP ?? "unknown"
        return "\(ip):47600"
    }

    private var qrImage: UIImage? {
        filter.message = Data(qrContent.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - QR scanner

struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private var captureSession: AVCaptureSession?

    override func viewDidLoad() {
        super.viewDidLoad()
        let session = AVCaptureSession()
        captureSession = session
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        captureSession?.stopRunning()
        onResult?(value)
    }
}

// MARK: - Document picker

struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPicked(urls)
        }
    }
}

extension NWEndpoint {
    var host: NWEndpoint.Host? {
        switch self {
        case .hostPort(let host, _): return host
        default: return nil
        }
    }
}