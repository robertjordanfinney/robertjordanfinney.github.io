import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Quick Look preview (Space bar / Finder column view / Get Info) for .R3D files.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let preview = try R3DClipPreview.load(url: url, maxFrames: 4, maxDimension: 1280)

        var attachments: [String: QLPreviewReplyAttachment] = [:]
        var frameNames: [String] = []
        for (i, frame) in preview.frames.enumerated() {
            guard let jpeg = frame.encoded(as: .jpeg) else { continue }
            let name = "frame\(i).jpg"
            attachments[name] = QLPreviewReplyAttachment(data: jpeg, contentType: .jpeg)
            frameNames.append(name)
        }

        var posterName: String?
        if frameNames.isEmpty, let poster = R3DPosterRenderer.placeholderImage(info: preview.info)?.encoded(as: .png) {
            posterName = "poster.png"
            attachments["poster.png"] = QLPreviewReplyAttachment(data: poster, contentType: .png)
        }

        let html = PreviewHTML.render(preview: preview, frameNames: frameNames, posterName: posterName)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 760)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = attachments
            return Data(html.utf8)
        }
        reply.title = url.lastPathComponent
        return reply
    }
}
