import AppKit
import QuickLookThumbnailing

/// Finder icon / gallery / column-view thumbnails for .R3D files.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let info = try? R3DParser.parse(url: url)
        let pixelBudget = Int(max(request.maximumSize.width, request.maximumSize.height) * request.scale)

        var frame: CGImage?
        if let clip = try? R3DSDKClip(url: url) {
            frame = clip.copyFrame(at: 0, maxDimension: pixelBudget)
        }

        guard info != nil || frame != nil else {
            handler(nil, R3DParserError.notR3D)
            return
        }

        let aspect: CGFloat = frame.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
            ?? R3DPosterRenderer.aspectRatio(for: info)
        let size = R3DPosterRenderer.fit(aspect: aspect, in: request.maximumSize)

        let reply = QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            let rect = CGRect(origin: .zero, size: size)
            if let frame {
                R3DPosterRenderer.drawFrame(frame, in: rect)
            } else {
                R3DPosterRenderer.drawPlaceholder(info: info, in: rect)
            }
            return true
        })
        reply.extensionBadge = "R3D"
        handler(reply, nil)
    }
}
