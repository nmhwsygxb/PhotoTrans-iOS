import Foundation
import UniformTypeIdentifiers

/// Performs best-effort photo format detection using XMP metadata, HEIC/ISOBMFF
/// box parsing and binary magic-number signatures.
///
/// The detector is *model-driven*: it consults the signatures installed in
/// `LocalModelStore` (the active model version). It also applies a set of
/// immutable built-in rules for the universally recognised formats so that the
/// app works even with an empty model store.
struct FormatDetector: Sendable {

    /// Combined result of inspecting a file.
    struct DetectionResult: Sendable {
        var format: PhotoFormat
        var confidence: Double
        var matchedSignatures: [String]
        var clues: [String]

        var description: String {
            "\(format.displayName) (\(String(format: "%.0f", confidence * 100))%)"
        }
    }

    // MARK: - Detection entry point

    /// Detect the format of a file on disk.
    func detect(url: URL) -> DetectionResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return DetectionResult(format: .unknown, confidence: 0, matchedSignatures: [], clues: ["Unreadable file"])
        }
        return detect(data: data, fileExtension: url.pathExtension)
    }

    /// Detect the format from an in-memory data snapshot (head of file).
    func detect(data: Data, fileExtension: String? = nil) -> DetectionResult {
        var clues: [String] = []
        var signatures: [FormatSignature] = []

        // 1) Model-driven signatures from the active model store.
        signatures.append(contentsOf: LocalModelStore.defaultStore.activeSignatureRules)

        // 2) Built-in immutable rules for the magic-number incontrovertible cases.
        signatures.append(contentsOf: Self.builtinHardSignatures)

        // 3) Extension based fallback hint.
        let extClue: PhotoFormat? = (fileExtension.map(Self.formatFromExtension) ?? nil).flatMap { $0 }
        if let ext = fileExtension, !ext.isEmpty {
            clues.append("extension .\(ext)")
        }

        // Evaluate rules; higher priority wins. Accumulate matched tags.
        var bestFormat: PhotoFormat?
        var bestPriority = Int.min
        var bestConfidence = 0.0
        var matchedTags: [String] = []

        for signature in signatures {
            guard Self.matches(signature: signature, in: data) else { continue }
            matchedTags.append(signature.tag)
            let confidence = Self.confidence(for: signature)
            if signature.priority > bestPriority ||
               (signature.priority == bestPriority && confidence > bestConfidence) {
                bestFormat = signature.format
                bestPriority = signature.priority
                bestConfidence = confidence
            }
        }

        // Overlay XMP parsing which can surface HDR cues and brand metadata.
        let xmp = detectXMP(in: data)
        if let xmpFormat = xmp.format {
            clues.append(xmp.device.map { "XMP: \($0)" } ?? "XMP metadata")
            if xmpFormat == .hdr {
                // Explicit HDR marker outranks a generic container match.
                bestFormat = .hdr
                bestConfidence = max(bestConfidence, 0.7)
            }
        }
        if let device = xmp.device {
            clues.append("camera \(device)")
        }

        let format: PhotoFormat
        if let bestFormat {
            format = bestFormat
        } else {
            format = extClue ?? .unknown
            if format != .unknown && bestConfidence == 0 {
                bestConfidence = 0.5
            }
        }

        return DetectionResult(
            format: format,
            confidence: min(bestConfidence, 1.0),
            matchedSignatures: matchedTags,
            clues: clues
        )
    }

    // MARK: - Signature matcher

    private static func matches(signature: FormatSignature, in data: Data) -> Bool {
        let start = signature.offset
        let pattern = signature.patternHex
        if pattern.isEmpty { return false }

        // Parse hex with '??' wildcard support.
        guard let bytes = hexToBytes(pattern) else { return false }
        let end = start + bytes.count
        guard end <= data.count else { return false }
        let slice = data[start..<end]
        return slice.elementsEqual(bytes) { d, b in b == nil || d == b }
    }

    private static func hexToBytes(_ hex: String) -> [UInt8?]? {
        var result: [UInt8?] = []
        var iterator = hex.makeIterator()
        var pending: Character?
        while let char = iterator.next() {
            if char == "?" {
                // Wildcard: consumed two chars as one '?' pair.
                _ = iterator.next()
                result.append(nil)
                continue
            }
            let second = iterator.next()
            guard let secondChar = second,
                  let hi = nibble(char),
                  let lo = nibble(secondChar) else {
                return nil
            }
            result.append((hi << 4) | lo)
        }
        return result
    }

    private static func nibble(_ c: Character) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(c.asciiValue! - Character("a").asciiValue! + 10)
        case "A"..."F": return UInt8(c.asciiValue! - Character("A").asciiValue! + 10)
        default: return nil
        }
    }

    // MARK: - Confidence heuristic

    private static func confidence(for signature: FormatSignature) -> Double {
        switch signature.patternHex.count {
        case ..<12:  return 0.6 + min(Double(signature.patternHex.count) * 0.02, 0.2)
        case 12..<20: return 0.85
        default:      return 0.95
        }
    }

    // MARK: - Built-in hard signatures

    /// Format signatures that never change and cover the homonymous formats.
    private static let builtinHardSignatures: [FormatSignature] = [
        .init(format: .jpeg, tag: "JPEG_SOI", offset: 0, patternHex: "FFD8FF", priority: 99, note: ""),
        .init(format: .png, tag: "PNG_MAGIC", offset: 0, patternHex: "89504E470D0A1A0A", priority: 99, note: ""),
        .init(format: .gif, tag: "GIF89A", offset: 0, patternHex: "474946383961", priority: 99, note: ""),
        .init(format: .gif, tag: "GIF87A", offset: 0, patternHex: "474946383761", priority: 99, note: ""),
        .init(format: .webp, tag: "RIFF_WEBP", offset: 0, patternHex: "52494646????????57454250", priority: 99, note: ""),
        .init(format: .heic, tag: "FTYP_BRAND", offset: 4, patternHex: "66747970", priority: 95, note: ""),
        .init(format: .heic, tag: "HEIC", offset: 0, patternHex: "00000018667479707069????6D696631", priority: 93, note: "ftyp: pi[?]mif1" ),
        .init(format: .arw, tag: "ARW_MKNOTE", offset: 8, patternHex: "4D4D", priority: 90, note: "Sony maker note"),
        .init(format: .dng, tag: "DNG_TAG", offset: 0, patternHex: "492A00", priority: 88, note: "TIFF littlendian"),
        .init(format: .nef, tag: "NEF_MAKER", offset: 0, patternHex: "4D4D002A", priority: 88, note: "TIFF bigendian"),
        .init(format: .livePhoto, tag: "MOV_FTYP_QT", offset: 4, patternHex: "667479707174202020", priority: 92, note: "QuickTime movie"),
    ]

    // MARK: - Extension- and UTI fallback

    private static func formatFromExtension(_ ext: String) -> PhotoFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png":         return .png
        case "gif":         return .gif
        case "webp":        return .webp
        case "heic", "heif", "heics", "hif": return .heic
        case "avif":        return .heic
        case "arw":         return .arw
        case "dng":         return .dng
        case "nef":         return .nef
        case "raw":         return .raw
        case "mov", "mp4":  return .livePhoto
        default:            return nil
        }
    }

    // MARK: - XMP parsing

    private struct XMPResult {
        var format: PhotoFormat?
        var device: String?
        var date: Date?
        var dateString: String?
    }

    /// Scans the first chunk of the file for XMP packets (often embedded in
    /// JPEG or raw files) and extracts camera / software tags that identify
    /// the brand.
    private func detectXMP(in data: Data) -> XMPResult {
        // XMP is textual XML; only look at a head slice.
        let head = min(data.count, 256 * 1024)
        guard head > 0, let xml = String(data: data.prefix(head), encoding: .utf8) else {
            return XMPResult()
        }
        guard xml.contains("xmpmeta") || xml.contains("adobe:ns:meta") else {
            return XMPResult()
        }

        var result = XMPResult()
        // Camera maker from XMP:dc:creator, tiff:Make or exif:MakerNote.
        var device: String?
        for key in ["tiff:Make>", "xmp:Make>", "tiff:Model>", "aux:DeviceMan>"] {
            if let range = xml.range(of: key),
               let close = xml[range.upperBound...].range(of: "<") {
                let value = String(xml[range.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { device = value; break }
            }
        }
        result.device = device

        // Capture date.
        if let range = xml.range(of: "photoshop:DateCreated>") ?? xml.range(of: "exif:DateTimeOriginal>"),
           let close = xml[range.upperBound...].range(of: "<") {
            let value = String(xml[range.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.dateString = value
        }

        // Infer brand from the camera name region.
        if let device {
            let lower = device.lowercased()
            if lower.contains("samsung") { result.format = nil }
        }
        // Format inference from XMP 'getM:' software tag when compressed image
        // is not encoded in a standard container.
        if xml.contains("GDepth") || xml.contains("GPano") || xml.contains("GImage") {
            result.format = .hdr
        }
        // An XMP packet inside a container usually just refines container;
        // we intentionally return nil for format here except HDR cues.
        return result
    }
}

/// UTI helper used elsewhere when the detector is not directly available.
extension PhotoFormat {
    var preferredUTType: UTType {
        switch self {
        case .jpeg:      return .jpeg
        case .png:       return .png
        case .gif:       return .gif
        case .heic:      return .heic
        case .heic as PhotoFormat: return .heic
        default:         return .data
        }
    }
}