import Foundation
import Combine

/// The two supported connection modes.
enum TransferMode: String, Codable, CaseIterable, Identifiable {
    /// LAN / Wi-Fi direct-like via Bonjour.
    case near
    /// IP based TCP direct connection, optionally with a QR flow.
    case far

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .near: return "Near (LAN)"
        case .far:  return "Far (IP)"
        }
    }
}

/// State of a single transfer session.
enum TransferPhase: String, Codable, Equatable {
    case idle
    case negotiating       // PT-HI handshake in progress
    case connecting
    case running           // bytes flowing
    case paused
    case completed
    case failed
    case cancelled
}

/// Errors surfaced by the transfer pipeline.
enum TransferError: LocalizedError {
    case connectionFailed
    case handshakeFailed(String)
    case fileUnreadable(URL)
    case writeFailed
    case remoteRejected(String)
    case cancelled
    case notConnected
    case missingAsset

    var errorDescription: String? {
        switch self {
        case .connectionFailed:   return "Could not establish connection to the remote device."
        case .handshakeFailed(let msg): return "Device handshake failed: \(msg)"
        case .fileUnreadable(let url):  return "Cannot read file at \(url.lastPathComponent)."
        case .writeFailed:        return "Failed to write received data to disk."
        case .remoteRejected(let msg): return "Remote device rejected the transfer: \(msg)"
        case .cancelled:          return "Transfer cancelled."
        case .notConnected:       return "Transfer attempted before connection was established."
        case .missingAsset:       return "The requested Photos asset is no longer available."
        }
    }
}

/// A file descriptor describing one targeted transfer.
struct FileInfo: Sendable, Identifiable, Equatable {
    var id: UUID
    let url: URL
    let name: String
    let size: Int64
    let format: PhotoFormat

    init(url: URL, name: String? = nil, size: Int64? = nil, format: PhotoFormat = .unknown) {
        self.id = UUID()
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = size ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        self.format = format
    }
}

/// Live status of an in-flight transfer. Published so the progress view can
/// observe it via Combine. Equality is by identity (`id`), so the struct does
/// not declare Equatable (synthesis is impossible with property wrappers).
struct TransferProgress: Sendable, Identifiable {
    let id: UUID
    let name: String
    let totalBytes: Int64
    @Atomic var transferredBytes: Int64 = 0
    @Atomic var currentSpeedBytesPerSecond: Double = 0
    @Atomic var averageSpeedBytesPerSecond: Double = 0
    @Atomic var startedAt: Date = Date()
    var phase: TransferPhase
    var errorDescription: String?

    init(id: UUID = UUID(),
         name: String,
         totalBytes: Int64,
         phase: TransferPhase = .idle,
         errorDescription: String? = nil) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.phase = phase
        self.errorDescription = errorDescription
    }

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(transferredBytes) / Double(totalBytes), 1.0)
    }

    var percentText: String {
        String(format: "%.1f%%", fractionComplete * 100)
    }

    /// Human readable speed string in B/s, KB/s, MB/s or GB/s.
    func speedText(bytesPerSecond: Double? = nil) -> String {
        let bps = bytesPerSecond ?? currentSpeedBytesPerSecond
        return Self.humanBytes(bps, perSecond: true)
    }

    /// Estimated time of arrival / remaining time.
    var etaText: String {
        guard phase == .running, currentSpeedBytesPerSecond > 0, totalBytes > 0 else { return "—" }
        let remaining = Double(totalBytes - transferredBytes) / currentSpeedBytesPerSecond
        return Self.humanDuration(remaining)
    }

    static func humanBytes(_ bytes: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        let speed = String(format: value >= 100 ? "%.0f" : "%.1f", value)
        return perSecond ? "\(speed) \(units[idx])/s" : "\(speed) \(units[idx])"
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

/// Property wrapper that makes a numeric field observable in `TransferProgress`
/// even though the struct itself is a value type re-published wholesale.
@propertyWrapper
struct Atomic<T>: Sendable {
    private let lock = NSLock()
    private var storage: T

    init(wrappedValue: T) {
        self.storage = wrappedValue
    }

    var wrappedValue: T {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}

// MARK: - Settings

/// User configurable app settings, persisted as JSON in Application Support.
struct AppSettings: Codable, Equatable {
    var nearHandshakeTimeout: TimeInterval = 8
    var connectRetryCount: Int = 3
    var transferChunkSize: Int = 64 * 1024          // 64 KB
    var maxReceiveFileSize: Int64 = 50 * 1024 * 1024 * 1024  // 50 GB safety cap
    var cacheDirectoryName = "PhotoTransCache"
    var theme: AppTheme = .system
    var showLargeFileWarnings = true
    var storeReceivedFilesInPhotos = false

    enum AppTheme: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
    }

    private static let fileName = "PhotoTransSettings.json"

    static func defaultSettingsPath() -> URL {
        Self.supportDirectory().appendingPathComponent(fileName)
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PhotoTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Load settings from disk, or create defaults if none exists.
    static func loadOrCreate() -> AppSettings {
        let path = defaultSettingsPath()
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.defaultSettingsPath(), options: .atomic)
    }
}

import SwiftUI

/// Bridge so SwiftUI can read the theme directly.
extension AppSettings.AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}