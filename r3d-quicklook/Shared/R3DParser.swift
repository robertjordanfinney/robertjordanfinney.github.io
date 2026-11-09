import Foundation

/// Facts about an R3D clip that can be read straight from the file, without the RED SDK.
///
/// The container layout (atoms, `RED1` header, `RDVO` frame index, `REOS/REOB/REOF` trailer)
/// follows the reverse-engineered description used by FFmpeg's R3D demuxer
/// (libavformat/r3d.c). Newer `RED2` files share the atom structure; fields that don't pass a
/// sanity check are left `nil` rather than guessed.
public struct R3DClipInfo: Equatable {
    /// Header atom tag: "RED1", "RED2", or "R3D" when the header could not be read.
    public var container: String
    public var fileName: String
    public var fileSize: Int64
    public var formatVersion: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var timescale: Int?
    public var segmentNumber: Int?
    public var audioChannels: Int?
    public var originalFileName: String?
    public var frameCount: Int?

    public init(container: String, fileName: String, fileSize: Int64) {
        self.container = container
        self.fileName = fileName
        self.fileSize = fileSize
    }
}

public enum R3DParserError: LocalizedError {
    case unreadable(String)
    case notR3D

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "The file couldn't be read: \(reason)"
        case .notR3D: return "This doesn't look like a RED .R3D file."
        }
    }
}

public enum R3DParser {
    static let headerLength = 4096
    /// FFmpeg locates the end atom at `fileSize - 48 - 8`.
    static let trailerLength = 56
    /// Upper bound on how much of the RDVO frame index we are willing to read (≈1M frames).
    static let maxIndexBytes = 4 * 1024 * 1024

    /// Parses a clip on disk. Only the header, the trailer and the frame index are read, so this is
    /// fast even for multi-gigabyte segments.
    public static func parse(url: URL) throws -> R3DClipInfo {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw R3DParserError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { throw R3DParserError.unreadable(error.localizedDescription) }

        return try parse(fileName: url.lastPathComponent, fileSize: size) { offset, length in
            guard offset < size else { return nil }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: length) else { return nil }
                return [UInt8](data)
            } catch {
                return nil
            }
        }
    }

    /// Parses an in-memory clip (used by tests).
    public static func parse(data: Data, fileName: String) throws -> R3DClipInfo {
        let bytes = [UInt8](data)
        return try parse(fileName: fileName, fileSize: UInt64(bytes.count)) { offset, length in
            guard offset < UInt64(bytes.count) else { return nil }
            let start = Int(offset)
            return Array(bytes[start..<min(bytes.count, start + length)])
        }
    }

    static func parse(fileName: String, fileSize: UInt64, read: (UInt64, Int) -> [UInt8]?) throws -> R3DClipInfo {
        guard fileSize >= 8, let headerBytes = read(0, headerLength), headerBytes.count >= 8 else {
            throw R3DParserError.notR3D
        }
        let header = ByteReader(headerBytes)
        guard let tag = header.ascii(4, 4), tag == "RED1" || tag == "RED2" else {
            throw R3DParserError.notR3D
        }

        var info = R3DClipInfo(container: tag, fileName: fileName, fileSize: Int64(fileSize))

        // Header atom body (offsets from the start of the file, i.e. after the 8-byte atom header).
        if let major = header.u8(0x08), let minor = header.u8(0x09) {
            info.formatVersion = "\(major).\(minor)"
        }
        if let timescale = header.be32(0x0C), timescale > 0, timescale < 10_000_000 {
            info.timescale = Int(timescale)
        }
        if let segment = header.be32(0x10), segment < 100_000 {
            info.segmentNumber = Int(segment)
        }
        if let w = header.be32(0x34), let h = header.be32(0x38),
           (16...65_536).contains(w), (16...65_536).contains(h) {
            info.width = Int(w)
            info.height = Int(h)
        }
        if let num = header.be16(0x3E), let den = header.be16(0x40), num > 0, den > 0 {
            let fps = Double(num) / Double(den)
            if fps >= 1, fps <= 2_000 { info.frameRate = fps }
        }
        if let channels = header.u8(0x42), channels <= 64 {
            info.audioChannels = Int(channels)
        }
        info.originalFileName = header.cString(0x43, maxLength: 257)

        info.frameCount = readFrameCount(fileSize: fileSize, read: read)
        return info
    }

    private static func readFrameCount(fileSize: UInt64, read: (UInt64, Int) -> [UInt8]?) -> Int? {
        guard fileSize >= UInt64(trailerLength + 8),
              let trailerBytes = read(fileSize - UInt64(trailerLength), trailerLength),
              trailerBytes.count == trailerLength else { return nil }
        let trailer = ByteReader(trailerBytes)
        guard let tag = trailer.ascii(4, 4), ["REOB", "REOF", "REOS"].contains(tag) else { return nil }

        // Preferred: count the entries of the RDVO (video offset) atom.
        if let rdvo = trailer.be32(8), rdvo > 0, UInt64(rdvo) + 8 <= fileSize,
           let atomHeader = read(UInt64(rdvo), 8).map(ByteReader.init),
           atomHeader.ascii(4, 4) == "RDVO",
           let atomSize = atomHeader.be32(0), atomSize >= 8 {
            let indexBytes = min(Int(atomSize) - 8, maxIndexBytes)
            if indexBytes == 0 { return 0 }
            if let entries = read(UInt64(rdvo) + 8, indexBytes) {
                let index = ByteReader(entries)
                var count = 0
                while let offset = index.be32(count * 4), offset != 0 { count += 1 }
                return count
            }
        }

        // Fallback: the trailer's "number of video chunks".
        if let chunks = trailer.be32(24), chunks > 0, chunks < 10_000_000 {
            return Int(chunks)
        }
        return nil
    }
}

/// Bounds-checked big-endian reader over a byte array.
struct ByteReader {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func u8(_ offset: Int) -> UInt8? {
        offset >= 0 && offset < bytes.count ? bytes[offset] : nil
    }

    func be16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func be32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    func ascii(_ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, offset + length <= bytes.count else { return nil }
        return String(bytes: bytes[offset..<offset + length], encoding: .ascii)
    }

    /// A NUL-terminated, printable-ASCII string, or nil if the bytes don't look like text.
    func cString(_ offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let end = min(bytes.count, offset + maxLength)
        var chars: [UInt8] = []
        for byte in bytes[offset..<end] {
            if byte == 0 { break }
            guard byte >= 0x20, byte < 0x7F else { return nil }
            chars.append(byte)
        }
        guard !chars.isEmpty else { return nil }
        return String(bytes: chars, encoding: .ascii)
    }
}

// MARK: - Display helpers

extension R3DClipInfo {
    public var resolutionText: String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    /// RED-style resolution name derived from the width (4096 → "4K", 4608 → "4.5K", 8192 → "8K").
    public var resolutionClass: String? {
        guard let width else { return nil }
        let k = (Double(width) / 1024 * 2).rounded() / 2
        guard k >= 1 else { return nil }
        return k == k.rounded() ? "\(Int(k))K" : String(format: "%.1fK", k)
    }

    public var frameRateText: String? {
        guard let frameRate else { return nil }
        return Self.formatFrameRate(frameRate)
    }

    public var duration: TimeInterval? {
        guard let frameCount, let frameRate, frameRate > 0 else { return nil }
        return Double(frameCount) / frameRate
    }

    /// Duration as HH:MM:SS:FF (non-drop-frame, counting at the nominal integer rate).
    public var durationText: String? {
        guard let frameCount, let frameRate, frameRate > 0 else { return nil }
        let base = max(1, Int(frameRate.rounded()))
        let frames = frameCount % base
        let totalSeconds = frameCount / base
        return String(format: "%02d:%02d:%02d:%02d",
                      totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames)
    }

    public var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    static func formatFrameRate(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.0005 { return "\(Int(fps.rounded()))" }
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
