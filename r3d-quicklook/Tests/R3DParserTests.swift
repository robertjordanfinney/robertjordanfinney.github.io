import XCTest

final class R3DParserTests: XCTestCase {
    // MARK: Synthetic clip builder (layout per FFmpeg's libavformat/r3d.c)

    private func appendBE32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                                 UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func appendBE16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func makeClip(tag: String = "RED1",
                          width: UInt32 = 4096, height: UInt32 = 2160,
                          fpsNum: UInt16 = 24000, fpsDen: UInt16 = 1001,
                          frames: Int = 48, writeIndex: Bool = true,
                          trailerTag: String = "REOS") -> Data {
        var data = Data()
        // Header atom
        appendBE32(0x43 + 257, to: &data)
        data.append(contentsOf: Array(tag.utf8))
        data.append(contentsOf: [1, 0])               // version 1.0
        appendBE16(0, to: &data)                        // unknown
        appendBE32(24000, to: &data)                    // timescale
        appendBE32(1, to: &data)                        // segment number
        data.append(Data(count: 32))                    // unknown
        appendBE32(width, to: &data)
        appendBE32(height, to: &data)
        appendBE16(0, to: &data)                        // unknown
        appendBE16(fpsNum, to: &data)
        appendBE16(fpsDen, to: &data)
        data.append(2)                                  // audio channels
        var name = Data("A001_C002_0101AB_001.R3D".utf8)
        name.append(Data(count: 257 - name.count))
        data.append(name)
        XCTAssertEqual(data.count, 0x43 + 257)

        // Pretend frame payload
        data.append(Data(repeating: 0xAB, count: 1024))

        // RDVO frame index: `frames` non-zero offsets followed by zero padding.
        let rdvoOffset = UInt32(data.count)
        if writeIndex {
            appendBE32(UInt32(8 + 4 * (frames + 2)), to: &data)
            data.append(contentsOf: Array("RDVO".utf8))
            for i in 0..<frames { appendBE32(UInt32(0x200 + i * 16), to: &data) }
            appendBE32(0, to: &data)
            appendBE32(0, to: &data)
        }

        // 56-byte end atom
        appendBE32(56, to: &data)
        data.append(contentsOf: Array(trailerTag.utf8))
        appendBE32(writeIndex ? rdvoOffset : 0, to: &data)
        appendBE32(0, to: &data)                        // rdvs
        appendBE32(0, to: &data)                        // rdao
        appendBE32(0, to: &data)                        // rdas
        appendBE32(UInt32(frames), to: &data)           // video chunks
        appendBE32(0, to: &data)                        // audio chunks
        data.append(Data(count: 24))
        return data
    }

    // MARK: Tests

    func testParsesRED1Header() throws {
        let info = try R3DParser.parse(data: makeClip(), fileName: "clip.R3D")
        XCTAssertEqual(info.container, "RED1")
        XCTAssertEqual(info.formatVersion, "1.0")
        XCTAssertEqual(info.width, 4096)
        XCTAssertEqual(info.height, 2160)
        XCTAssertEqual(info.frameRate!, 23.976, accuracy: 0.001)
        XCTAssertEqual(info.timescale, 24000)
        XCTAssertEqual(info.segmentNumber, 1)
        XCTAssertEqual(info.audioChannels, 2)
        XCTAssertEqual(info.originalFileName, "A001_C002_0101AB_001.R3D")
    }

    func testFrameCountFromIndex() throws {
        let info = try R3DParser.parse(data: makeClip(frames: 120), fileName: "clip.R3D")
        XCTAssertEqual(info.frameCount, 120)
    }

    func testFrameCountFallsBackToTrailerChunkCount() throws {
        let info = try R3DParser.parse(data: makeClip(frames: 77, writeIndex: false, trailerTag: "REOB"),
                                       fileName: "clip.R3D")
        XCTAssertEqual(info.frameCount, 77)
    }

    func testRED2HeaderIsAccepted() throws {
        let info = try R3DParser.parse(data: makeClip(tag: "RED2", width: 8192, height: 4320, fpsNum: 25, fpsDen: 1),
                                       fileName: "clip.R3D")
        XCTAssertEqual(info.container, "RED2")
        XCTAssertEqual(info.resolutionClass, "8K")
        XCTAssertEqual(info.frameRateText, "25")
    }

    func testImplausibleFieldsAreDropped() throws {
        let info = try R3DParser.parse(data: makeClip(width: 0, height: 9_000_000, fpsNum: 0), fileName: "clip.R3D")
        XCTAssertNil(info.width)
        XCTAssertNil(info.height)
        XCTAssertNil(info.frameRate)
    }

    func testRejectsNonR3DData() {
        XCTAssertThrowsError(try R3DParser.parse(data: Data("not a red file at all".utf8), fileName: "x.R3D"))
        XCTAssertThrowsError(try R3DParser.parse(data: Data(), fileName: "x.R3D"))
    }

    func testParsesFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).R3D")
        try makeClip(frames: 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try R3DParser.parse(url: url)
        XCTAssertEqual(info.fileName, url.lastPathComponent)
        XCTAssertEqual(info.frameCount, 10)
        XCTAssertEqual(info.width, 4096)
    }

    func testFormatting() throws {
        let info = try R3DParser.parse(data: makeClip(frames: 48), fileName: "clip.R3D")
        XCTAssertEqual(info.resolutionText, "4096 × 2160")
        XCTAssertEqual(info.resolutionClass, "4K")
        XCTAssertEqual(info.frameRateText, "23.976")
        XCTAssertEqual(info.durationText, "00:00:02:00")
        XCTAssertEqual(R3DClipInfo.formatFrameRate(29.97002997), "29.97")
        XCTAssertEqual(R3DClipInfo.formatFrameRate(59.94005994), "59.94")

        var odd = info
        odd.width = 4608
        XCTAssertEqual(odd.resolutionClass, "4.5K")
    }

    func testPosterFrameIndices() {
        XCTAssertEqual(R3DClipPreview.posterFrameIndices(frameCount: 100, maxFrames: 4), [0, 25, 50, 75])
        XCTAssertEqual(R3DClipPreview.posterFrameIndices(frameCount: 2, maxFrames: 4), [0, 1])
        XCTAssertEqual(R3DClipPreview.posterFrameIndices(frameCount: 0, maxFrames: 4), [])
    }

    func testPlaceholderRendersAndPreviewHTMLEscapes() throws {
        var info = try R3DParser.parse(data: makeClip(), fileName: "<clip>&.R3D")
        info.originalFileName = "A\"B"
        let image = try XCTUnwrap(R3DPosterRenderer.placeholderImage(info: info, width: 320))
        XCTAssertEqual(image.width, 640) // 2x scale
        XCTAssertNotNil(image.encoded(as: .png))

        let html = PreviewHTML.render(preview: R3DClipPreview(info: info), frameNames: [], posterName: "poster.png")
        XCTAssertTrue(html.contains("&lt;clip&gt;&amp;.R3D"))
        XCTAssertTrue(html.contains("A&quot;B"))
        XCTAssertTrue(html.contains("cid:poster.png"))
        XCTAssertTrue(html.contains("4096 × 2160"))
    }

    func testSDKClipFailsGracefullyWithoutSDK() throws {
        try XCTSkipIf(R3DSDKClip.isSDKAvailable, "RED SDK is installed")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).R3D")
        try makeClip().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try R3DSDKClip(url: url))

        let preview = try R3DClipPreview.load(url: url, maxFrames: 4, maxDimension: 512)
        XCTAssertTrue(preview.frames.isEmpty)
        XCTAssertNotNil(preview.decoderNote)
        XCTAssertEqual(preview.info.width, 4096)
    }
}
