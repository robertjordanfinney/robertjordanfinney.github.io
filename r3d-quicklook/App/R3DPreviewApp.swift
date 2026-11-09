import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct R3DPreviewApp: App {
    var body: some Scene {
        WindowGroup("R3D Preview") {
            ContentView()
        }
        .defaultSize(width: 860, height: 720)
    }
}

@MainActor
final class ClipModel: ObservableObject {
    @Published var preview: R3DClipPreview?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var statusMessage: String?

    func load(_ url: URL) {
        isLoading = true
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try R3DClipPreview.load(url: url, maxFrames: 4, maxDimension: 1280) }
            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let preview): self.preview = preview
                case .failure(let error):
                    self.preview = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Clears Quick Look's generator registry and thumbnail cache so new previews appear immediately.
    func reloadQuickLook() {
        for arguments in [["-r"], ["-r", "cache"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        statusMessage = "Quick Look reloaded. Re-open the Finder window to see new thumbnails."
    }
}

struct ContentView: View {
    @StateObject private var model = ClipModel()
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            setupPanel
            Divider()
            clipArea
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 600)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.r3d, .data]) { result in
            if case .success(let url) = result { model.load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onOpenURL { model.load($0) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("R3D")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: R3DPosterRenderer.accent)))
            VStack(alignment: .leading, spacing: 2) {
                Text("R3D Preview").font(.title2.weight(.semibold))
                Text("Quick Look previews and thumbnails for RED .R3D clips in Finder.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Finder previews are installed. Select an .R3D file and press Space, or switch Finder to Gallery/Column view.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Label {
                Text(R3DSDKClip.sdkStatus)
            } icon: {
                Image(systemName: R3DSDKClip.isSDKAvailable ? "film.fill" : "info.circle")
                    .foregroundStyle(R3DSDKClip.isSDKAvailable ? .green : .orange)
            }
            HStack {
                Button("Reload Quick Look") { model.reloadQuickLook() }
                Button("Extension Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Open Clip…") { showImporter = true }
                    .keyboardShortcut("o")
            }
            if let status = model.statusMessage {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var clipArea: some View {
        if model.isLoading {
            ProgressView("Reading clip…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview {
            ScrollView { ClipDetailView(preview: preview) }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Drop an .R3D clip here to test the preview").font(.headline)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
        }
    }
}

struct ClipDetailView: View {
    let preview: R3DClipPreview

    var body: some View {
        let info = preview.info
        VStack(alignment: .leading, spacing: 14) {
            if let hero = preview.frames.first ?? R3DPosterRenderer.placeholderImage(info: info) {
                Image(decorative: hero, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if preview.frames.count > 1 {
                HStack(spacing: 8) {
                    ForEach(1..<preview.frames.count, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Image(decorative: preview.frames[i], scale: 1).resizable().aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("Frame \(preview.frameIndices[i] + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(info.fileName).font(.title3.weight(.semibold)).textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Resolution", [info.resolutionClass, info.resolutionText].compactMap { $0 }.joined(separator: "  "))
                row("Frame rate", info.frameRateText.map { "\($0) fps" })
                row("Frames", info.frameCount.map(String.init))
                row("Duration", info.durationText)
                row("Audio channels", info.audioChannels.map(String.init))
                row("Segment", info.segmentNumber.map(String.init))
                row("Recorded as", info.originalFileName)
                row("Container", [info.container, info.formatVersion.map { "v\($0)" }].compactMap { $0 }.joined(separator: " "))
                row("File size", info.fileSizeText)
                ForEach(preview.cameraMetadata, id: \.key) { item in
                    row(item.key, item.value)
                }
            }
            if let note = preview.decoderNote, preview.frames.isEmpty {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
