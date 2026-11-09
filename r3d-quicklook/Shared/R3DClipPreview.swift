import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    /// Declared (imported) by the host app's Info.plist for the `.r3d` extension.
    static let r3d = UTType(importedAs: "com.red.r3d")
}

/// Everything a preview needs: header facts, optional decoded frames, optional SDK metadata.
struct R3DClipPreview {
    var info: R3DClipInfo
    var frames: [CGImage] = []
    var frameIndices: [Int] = []
    var cameraMetadata: [(key: String, value: String)] = []
    /// Why frames are missing, if they are.
    var decoderNote: String?

    /// Reads the header, then (if the RED SDK is available) decodes up to `maxFrames` frames
    /// spread across the clip.
    static func load(url: URL, maxFrames: Int, maxDimension: Int) throws -> R3DClipPreview {
        var headerError: Error?
        var info: R3DClipInfo
        do {
            info = try R3DParser.parse(url: url)
        } catch {
            headerError = error
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            info = R3DClipInfo(container: "R3D", fileName: url.lastPathComponent, fileSize: Int64(size))
        }

        var preview = R3DClipPreview(info: info)
        do {
            let clip = try R3DSDKClip(url: url)
            if clip.width > 0, clip.height > 0 {
                preview.info.width = clip.width
                preview.info.height = clip.height
            }
            if clip.frameCount > 0 { preview.info.frameCount = clip.frameCount }
            if clip.frameRate > 0 { preview.info.frameRate = clip.frameRate }
            preview.cameraMetadata = clip.metadata
                .map { (key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

            for index in posterFrameIndices(frameCount: clip.frameCount, maxFrames: maxFrames) {
                if let image = clip.copyFrame(at: index, maxDimension: maxDimension) {
                    preview.frames.append(image)
                    preview.frameIndices.append(index)
                }
            }
            if preview.frames.isEmpty { preview.decoderNote = "The RED SDK opened the clip but couldn't decode a frame." }
        } catch {
            if let headerError { throw headerError }
            preview.decoderNote = error.localizedDescription
        }
        return preview
    }

    /// First frame, then evenly spaced frames through the clip.
    static func posterFrameIndices(frameCount: Int, maxFrames: Int) -> [Int] {
        guard frameCount > 0, maxFrames > 0 else { return [] }
        let n = min(frameCount, maxFrames)
        var result: [Int] = []
        for i in 0..<n {
            let index = i * frameCount / n
            if result.last != index { result.append(index) }
        }
        return result
    }
}

extension CGImage {
    func encoded(as type: UTType, quality: CGFloat = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, self,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
