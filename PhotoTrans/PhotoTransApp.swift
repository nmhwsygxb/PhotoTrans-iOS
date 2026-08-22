import SwiftUI
import Combine

@main
struct PhotoTransApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(appState.settings.theme.colorScheme)
        }
    }
}

/// Root application state. Owns the long-lived services and orchestrates
/// the transfer / device-discovery flows so that SwiftUI views stay thin.
final class AppState: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published private(set) var networkService: any NetworkServiceProtocol
    @Published var transferService: TransferService
    @Published var deviceList: DeviceListModel

    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings.loadOrCreate()
        self.settings = settings

        let netService = NetworkService()
        self.networkService = netService
        self.deviceList = DeviceListModel(networkService: netService)

        let transfer = TransferService(
            networkService: netService,
            modelStore: LocalModelStore.defaultStore,
            formatDetector: FormatDetector()
        )
        self.transferService = transfer

        // Keep settings published so views can react to theme / cache changes.
        netService.settings = settings
        transfer.settings = settings
    }

    /// Stops advertising, pending transfers, and Bonjour discovery.
    /// Called from Settings when the user toggles network off or clears cache.
    func shutdown() {
        networkService.stopAdvertising()
        networkService.stopDiscovery()
        transferService.cancelActiveTransfers()
    }
}