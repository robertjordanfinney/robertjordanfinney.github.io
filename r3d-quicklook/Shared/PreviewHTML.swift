import Foundation

/// Builds the HTML page shown when you press Space on an R3D file in Finder.
/// Images are referenced as `cid:<name>` and supplied as QLPreviewReply attachments.
enum PreviewHTML {
    static func render(preview: R3DClipPreview, frameNames: [String], posterName: String?) -> String {
        let info = preview.info
        var body = ""

        if let hero = frameNames.first ?? posterName {
            body += #"<figure class="hero"><img src="cid:\#(escape(hero))" alt=""></figure>"#
        }
        if frameNames.count > 1 {
            body += #"<div class="strip">"#
            for (name, index) in zip(frameNames.dropFirst(), preview.frameIndices.dropFirst()) {
                body += #"<figure><img src="cid:\#(escape(name))" alt=""><figcaption>Frame \#(index + 1)</figcaption></figure>"#
            }
            body += "</div>"
        }

        body += "<h1>\(escape(info.fileName))</h1>"
        let summary = [info.resolutionClass, info.frameRateText.map { "\($0) fps" }, info.durationText]
            .compactMap { $0 }.joined(separator: " · ")
        if !summary.isEmpty { body += #"<p class="summary">\#(escape(summary))</p>"# }

        var rows: [(String, String?)] = [
            ("Resolution", info.resolutionText),
            ("Frame rate", info.frameRateText.map { "\($0) fps" }),
            ("Frames", info.frameCount.map(String.init)),
            ("Duration", info.durationText),
            ("Audio channels", info.audioChannels.map(String.init)),
            ("Segment", info.segmentNumber.map(String.init)),
            ("Recorded as", info.originalFileName),
            ("Container", [info.container, info.formatVersion.map { "v\($0)" }].compactMap { $0 }.joined(separator: " ")),
            ("File size", info.fileSizeText),
        ]
        rows = rows.filter { $0.1 != nil && !($0.1!.isEmpty) }
        body += table(rows.map { ($0.0, $0.1!) })

        if !preview.cameraMetadata.isEmpty {
            body += "<details open><summary>Camera metadata</summary>"
            body += table(preview.cameraMetadata.map { ($0.key, $0.value) })
            body += "</details>"
        }
        if let note = preview.decoderNote, preview.frames.isEmpty {
            body += #"<p class="note">\#(escape(note))</p>"#
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }

    private static func table(_ rows: [(String, String)]) -> String {
        var html = "<table>"
        for (key, value) in rows {
            html += "<tr><th>\(escape(key))</th><td>\(escape(value))</td></tr>"
        }
        return html + "</table>"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --line:#d2d2d7; --bg:#fff; --accent:#d40f21; }
    @media (prefers-color-scheme: dark) { :root { --fg:#f5f5f7; --muted:#a1a1a6; --line:#3a3a3c; --bg:#1c1c1e; } }
    * { box-sizing: border-box; }
    body { margin:0; padding:20px 24px 28px; background:var(--bg); color:var(--fg);
           font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    figure { margin:0; }
    .hero img { display:block; width:100%; border-radius:8px; background:#000; }
    .strip { display:grid; grid-template-columns:repeat(3, 1fr); gap:8px; margin-top:8px; }
    .strip img { display:block; width:100%; border-radius:6px; background:#000; }
    figcaption { color:var(--muted); font-size:11px; margin-top:3px; font-variant-numeric:tabular-nums; }
    h1 { font-size:17px; margin:18px 0 2px; word-break:break-all; }
    .summary { margin:0 0 12px; color:var(--accent); font-weight:600; }
    table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
    th, td { text-align:left; padding:5px 0; border-bottom:1px solid var(--line); vertical-align:top; }
    th { width:34%; color:var(--muted); font-weight:500; padding-right:12px; }
    td { word-break:break-word; }
    details { margin-top:16px; }
    summary { font-weight:600; cursor:default; margin-bottom:6px; }
    .note { color:var(--muted); font-size:12px; margin-top:14px; }
    """
}
