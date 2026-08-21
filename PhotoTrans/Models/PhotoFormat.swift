import Foundation

/// Known photo/transfer formats that PhotoTrans is able to identify.
///
/// These enum cases are the *stable* identifiers used throughout the app and
/// are persisted in the local model store. New versions of the detection
/// database map onto the same `PhotoFormat` cases so that existing device
/// records remain valid across model updates.
enum PhotoFormat: String, CaseIterable, Codable, Identifiable {
    case opus, heic, jpeg, png, gif, webp, arw, dng, nef, raw, livePhoto, hdr, unknown

    var id: String { rawValue }

    /// Human readable, user facing label.
    var displayName: String {
        switch self {
        case .opus:          return "OPUS Audio"
        case .heic:          return "HEIC"
        case .jpeg:          return "JPEG"
        case .png:          return "PNG"
        case .gif:          return "GIF"
        case .webp:         return "WebP"
        case .arw:          return "Sony ARW"
        case .dng:          return "Adobe DNG"
        case .nef:          return "Nikon NEF"
        case .raw:          return "RAW (Generic)"
        case .livePhoto:    return "Live Photo"
        case .hdr:          return "HDR Photo"
        case .unknown:      return "Unknown"
        }
    }

    /// The likely originating vendor. Most formats are used by multiple brands;
    /// this is a best-effort hint surfaced in the UI.
    var likelyOrigin: DeviceBrand? {
        switch self {
        case .heic: return .apple
        case .arw:  return .sony
        case .nef:  return .nikon
        default:    return nil
        }
    }

    /// Whether files of this type are treated as "photos" for the purposes of
    /// gallery-centric UI copy.
    var isPhotoLike: Bool {
        switch self {
        case .heic, .jpeg, .png, .gif, .webp, .arw, .dng, .nef, .raw, .livePhoto, .hdr:
            return true
        default:
            return false
        }
    }
}

/// Device brands that PhotoTrans models are trained to recognize.
enum DeviceBrand: String, Codable, CaseIterable, Identifiable, Equatable {
    case oppo, huawei, samsung, apple, xiaomi, vivo, sony, nikon, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oppo:    return "OPPO"
        case .huawei:  return "Huawei"
        case .samsung: return "Samsung"
        case .apple:   return "Apple"
        case .xiaomi:  return "Xiaomi"
        case .vivo:    return "vivo"
        case .sony:    return "Sony"
        case .nikon:   return "Nikon"
        case .other:   return "Other"
        }
    }
}

/// A classification result: the detected format plus the confidence and the
/// matching signatures (used for diagnostics / debugging).
struct FormatMatch: Sendable {
    let format: PhotoFormat
    let confidence: Double
    let matchedSignatures: [String]

    var formattedConfidence: String {
        String(format: "%.1f%%", confidence * 100)
    }
}

/// A single signature rule contributed by one model version.
struct FormatSignature: Codable, Identifiable, Sendable, Equatable {
    var id: String { "\(format.rawValue):\(priority).\(tag)" }

    let format: PhotoFormat
    /// Exposed by the code (e.g. "XMP", "HEIC", "JPEG_SOI").
    let tag: String
    /// Offset in bytes where the matcher looks for `pattern`.
    let offset: Int
    /// Hex string (may include wildcard '??' pairs) matched at `offset`.
    let patternHex: String
    /// Higher priorities are evaluated first and win on ties.
    let priority: Int
    /// Optional textual description shown in the management UI.
    let note: String
}