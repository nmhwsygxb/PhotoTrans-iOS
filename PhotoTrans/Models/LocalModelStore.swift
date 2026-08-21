import Foundation
import Combine

/// A single installed model version of the format-detection database.
struct ModelVersion: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let channel: String          // stable / beta
    let releaseDate: Date
    /// Set of device brands this model claims to recognize.
    let supportedBrands: [DeviceBrand]
    /// The signature rules shipped with this version.
    let signatures: [FormatSignature]
    /// Optional user-visible changelog.
    let changelog: String

    var displayVersion: String { "v\(version) · \(channel.capitalized)" }
    var supportedBrandDescription: String {
        supportedBrands.map(\.displayName).joined(separator: ", ")
    }
}

/// JSON representation used for persistence / sharing between devices.
struct ModelManifest: Codable, Sendable {
    let id: String
    let name: String
    let version: String
    let channel: String
    let supportedBrands: [DeviceBrand]
    let signatures: [FormatSignature]
}

/// Manages the installed detection-model versions: metadata, activation,
/// deletion, and the seeding of bundled default models.
final class LocalModelStore: ObservableObject {
    @Published private(set) var installedVersions: [ModelVersion] = []
    @Published var activeModelId: String?

    /// The only store instance used across the app.
    static let defaultStore = LocalModelStore()

    private let fileManager = FileManager.default
    private var versionsDirectory: URL
    private var indexURL: URL

    private let signatureLock = NSLock()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let base = AppSettings.supportDirectory()
            .appendingPathComponent("Models", isDirectory: true)
        self.versionsDirectory = base.appendingPathComponent("Versions", isDirectory: true)
        self.indexURL = base.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)

        loadIndex()
        loadInstalled()
        seedBundledModelsIfNeeded()
    }

    /// Currently active model; falls back to the first installed version.
    var activeModel: ModelVersion? {
        let active = installedVersions.first { $0.id == activeModelId }
        return active ?? installedVersions.first
    }

    /// All signatures in the active model, evaluating higher priorities first.
    var activeSignatureRules: [FormatSignature] {
        guard let active = activeModel else { return [] }
        return active.signatures.sorted { $0.priority > $1.priority }
    }

    // MARK: - Persistence

    private struct Index: Codable {
        var activeModelId: String?
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        activeModelId = index.activeModelId
    }

    private func saveIndex() {
        let index = Index(activeModelId: activeModelId)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func persist(_ version: ModelVersion) {
        let manifest = ModelManifest(
            id: version.id,
            name: version.name,
            version: version.version,
            channel: version.channel,
            supportedBrands: version.supportedBrands,
            signatures: version.signatures
        )
        let url = versionsDirectory.appendingPathComponent(version.id).appendingPathExtension("json")
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadInstalled() {
        signatureLock.lock(); defer { signatureLock.unlock() }
        installedVersions = (try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" })?.compactMap { url -> ModelVersion? in
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else { return nil }
            // Reconstruct releaseDate from id (prefix contains date stamp) or fall back to file time.
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return ModelVersion(id: manifest.id,
                                name: manifest.name,
                                version: manifest.version,
                                channel: manifest.channel,
                                releaseDate: date,
                                supportedBrands: manifest.supportedBrands,
                                signatures: manifest.signatures,
                                changelog: "")
        }.sorted { $0.releaseDate > $1.releaseDate } ?? []
    }

    // MARK: - Seeding bundled models

    /// Installs the default (v1) model the first time the app runs.
    private func seedBundledModelsIfNeeded() {
        guard installedVersions.isEmpty else { return }
        let v1 = bundledDefaultModel()
        installedVersions = [v1]
        persist(v1)
        activeModelId = v1.id
        saveIndex()
    }

    /// The default signature database shipped with the app. Covers all
    /// supported brands with byte-level and XMP signatures.
    static func defaultSignatures() -> [FormatSignature] {
        [
            // JPEG — SOI marker (FF D8 FF) → Apple / most brands.
            .init(format: .jpeg, tag: "JPEG_SOI", offset: 0, patternHex: "FFD8FF", priority: 90, note: "JPEG start of image"),
            // PNG magic.
            .init(format: .png, tag: "PNG_MAGIC", offset: 0, patternHex: "89504E470D0A1A0A", priority: 90, note: "PNG signature"),
            // GIF89a.
            .init(format: .gif, tag: "GIF89A", offset: 0, patternHex: "474946383961", priority: 90, note: "GIF v89a"),
            // WebP: RIFF....WEBP.
            .init(format: .webp, tag: "RIFF_WEBP", offset: 0, patternHex: "52494646????????57454250", priority: 90, note: "RIFF + WebP magic"),
            // HEIC/HEIF: ftyp box. Supported brands: Apple, OPPO, Huawei, Samsung, vivo, Xiaomi.
            .init(format: .heic, tag: "FTYP_HEIC", offset: 4, patternHex: "66747970", priority: 85, note: "ISO BMFF 'ftyp' box"),
            .init(format: .heic, tag: "HEIC_BRAND", offset: 8, patternHex: "68656963", priority: 84, note: "'heic' compatible brand"),
            .init(format: .heic, tag: "HEIX_BRAND", offset: 8, patternHex: "68656978", priority: 84, note: "'heix' compatible brand"),
            // Live Photo: motion JPEG video container used by Apple when exported.
            .init(format: .livePhoto, tag: "MOV_LIVE", offset: 4, patternHex: "66747970", priority: 82, note: "QuickTime movie container (Live Photo video track)"),
            // HDR helpers: HEVC core usually found after ftyp.
            .init(format: .hdr, tag: "HVC1_TRACK", offset: 16, patternHex: "68766331", priority: 78, note: "'hvc1' sample entry (HDR HEVC)"),
            // Sony ARW: 'II*\0' (little endian TIFF) at offset 0.
            .init(format: .arw, tag: "TIFF_II", offset: 0, patternHex: "492A00", priority: 80, note: "Little-endian TIFF header (Sony ARW)"),
            // DNG: Adobe DNG uses TIFF header + a tag; detect via II*\0 too but lower priority.
            .init(format: .dng, tag: "TIFF_DNG", offset: 0, patternHex: "4D4D002A", priority: 79, note: "Big-endian TIFF (Adobe DNG)"),
            // Nikon NEF: 'II*\0' TIFF too; differentiate via Exif maker tag further in.
            .init(format: .nef, tag: "TIFF_NEF", offset: 0, patternHex: "492A00", priority: 78, note: "Nikon NEF TIFF wrapper"),
        ]
    }

    private func bundledDefaultModel() -> ModelVersion {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return ModelVersion(
            id: "model_\(Int64(Date().timeIntervalSince1970))",
            name: "PhotoTrans Base Model",
            version: "1.0.0",
            channel: "stable",
            releaseDate: formatter.date(from: "2024.01.01") ?? Date(),
            supportedBrands: [.oppo, .huawei, .samsung, .apple, .xiaomi, .vivo],
            signatures: Self.defaultSignatures(),
            changelog: "Initial release.\n• Byte-level signatures for JPEG/PNG/GIF/WebP\n• ftyp detection for HEIC/Live Photo\n• XMP metadata parsing hooks"
        )
    }

    // MARK: - Public operations

    /// Activate a specific installed model. Returns success/failure.
    @discardableResult
    func activate(modelID: String) -> Bool {
        guard installedVersions.contains(where: { $0.id == modelID }) else { return false }
        activeModelId = modelID
        saveIndex()
        return true
    }

    /// Install a model from a decoded manifest; returns the created version.
    @discardableResult
    func install(manifest: ModelManifest) -> ModelVersion? {
        let version = ModelVersion(id: manifest.id,
                                   name: manifest.name,
                                   version: manifest.version,
                                   channel: manifest.channel,
                                   releaseDate: Date(),
                                   supportedBrands: manifest.supportedBrands,
                                   signatures: manifest.signatures,
                                   changelog: "")
        guard !installedVersions.contains(where: { $0.id == version.id }) else {
            return installedVersions.first { $0.id == version.id }
        }
        installedVersions.append(version)
        persist(version)
        if activeModelId == nil { activeModelId = version.id; saveIndex() }
        return version
    }

    /// Delete an installed model. The active model cannot be deleted unless it
    /// is the only one (in which case defaults are re-seeded next launch).
    func delete(modelID: String) -> Bool {
        guard installedVersions.count > 1, installedVersions.contains(where: { $0.id == modelID }) else {
            // Refuse to delete the last remaining model.
            return false
        }
        installedVersions.removeAll { $0.id == modelID }
        let url = versionsDirectory.appendingPathComponent(modelID).appendingPathExtension("json")
        try? fileManager.removeItem(at: url)
        if activeModelId == modelID {
            activeModelId = installedVersions.first?.id
            saveIndex()
        }
        return true
    }

    /// Retrieve signatures for a foreign manifest (e.g. from a remote model
    /// download) without installing it.
    func signatures(for manifest: ModelManifest) -> [FormatSignature] { manifest.signatures }
}