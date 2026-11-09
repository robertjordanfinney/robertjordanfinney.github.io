# R3D Preview: Finder previews for RED .R3D clips

A small macOS app that adds Quick Look support for RED `.R3D` files:

- **Thumbnails** in Finder icon, list, column and gallery views (badged `R3D`).
- **Space-bar previews** with the clip's resolution, frame rate, frame count, duration, audio
  channels, segment number and original file name.
- **Real frames** (a poster frame plus a strip of frames from across the clip) and full camera
  metadata (camera, ISO, white balance, lens, timecode…) once you add the free RED R3D SDK.

| Mode | Thumbnail | Space-bar preview |
| --- | --- | --- |
| Default build (no RED SDK) | Clip card: `R3D`, resolution, fps, duration | Clip info table |
| With RED SDK | Decoded first frame | 4 decoded frames + clip info + camera metadata |

Reading `.R3D` image data requires RED's proprietary decoder. RED's license doesn't allow it to
be committed here, so the default build only reads the container header, which works without the
SDK and is instant even on huge files. A one-line script switches on frame decoding.

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel)
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and install

```sh
cd r3d-quicklook
make install        # generates the Xcode project, builds Release, copies to /Applications
```

`make install` registers both extensions, resets Quick Look's cache and launches the app. Then
select any `.R3D` in Finder and press Space.

If you prefer Xcode: `make project`, open `R3DQuickLook.xcodeproj`, choose the **R3D Preview**
scheme and Run. Run the app once from `/Applications` (or anywhere else outside DerivedData) so
macOS registers its extensions.

### Turning on frame decoding (RED R3D SDK)

1. Download the **R3D SDK** for macOS from <https://www.red.com/developers> (free, needs a RED
   account) and unzip it.
2. Run:
   ```sh
   make sdk R3DSDK=~/Downloads/R3DSDKv8_x_y   # path to the unzipped SDK folder
   make install
   ```

The script copies the headers, the static loader library and the runtime `REDR3D*.dylib` into
`Vendor/R3DSDK` (git-ignored) and writes `Config/R3DSDK.local.xcconfig`. The build then embeds
the runtime libraries in `R3D Preview.app/Contents/Frameworks`, where both extensions load them.
The app window shows whether decoding is active.

Frames are decoded at the smallest RED decode resolution that's big enough (1/16 to 1/2), as
Rec.709 / BT.1886, so a thumbnail of an 8K clip only takes a fraction of a second.

## Signing

The project signs ad-hoc ("Sign to Run Locally") by default, so it builds without an Apple
account and runs on the Mac that built it. To sign with your team, or to give the app to other
people, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your team ID.
If you distribute outside your own Mac, use a Developer ID certificate with hardened runtime and
notarize the app.

The CI build (GitHub Actions → *R3D Quick Look* → artifact `R3D-Preview`) is ad-hoc signed. To
run it on another Mac, unzip it, move it to `/Applications`, and clear quarantine:
`xattr -dr com.apple.quarantine "/Applications/R3D Preview.app"`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Nothing happens on Space | Open the app and click **Reload Quick Look**. Check that both *R3D Preview* extensions are on in **System Settings → General → Login Items & Extensions → Quick Look**. |
| Old generic icons stick around | `make reset` (runs `qlmanage -r`, `qlmanage -r cache` and relaunches Finder). |
| Test a file from Terminal | `qlmanage -p clip.R3D` (preview) and `qlmanage -t -s 512 clip.R3D` (thumbnail). |
| Extensions not registered | `pluginkit -m -v -p com.apple.quicklook.preview \| grep r3d` should list `io.github.robertjordanfinney.r3dpreview.preview`. |
| Another app claims `.r3d` | Run `mdls -name kMDItemContentType clip.R3D`. If it isn't `com.red.r3d`, add that identifier to `QLSupportedContentTypes` in both extension `Info.plist`s and rebuild. |

## How it works

```
R3D Preview.app            SwiftUI host app: status, settings shortcuts, drop-a-clip tester
└─ Contents/PlugIns
   ├─ R3DPreviewExtension.appex     QLPreviewProvider → HTML page + JPEG frame attachments
   └─ R3DThumbnailExtension.appex   QLThumbnailProvider → decoded frame or clip card
Shared/
   R3DParser.swift          container parser: RED1/RED2 header, RDVO frame index, REOS/REOB trailer
   R3DClipPreview.swift     merges header info with SDK frames/metadata
   R3DPosterRenderer.swift  thumbnail drawing
   PreviewHTML.swift        Space-bar preview page (light/dark)
   Bridge/R3DSDKClip.mm     Objective-C++ wrapper over the RED SDK (a stub when the SDK isn't installed)
```

The parser reads only the first 4 KB, the last 56 bytes and the frame index, so previews of
multi-gigabyte segments open immediately. The container layout comes from the reverse-engineered
description in FFmpeg's R3D demuxer. Older `RED1` clips (RED ONE era) match it exactly. For newer
`RED2` clips (DSMC2, KOMODO, V-RAPTOR) the parser accepts the same fields only when they pass
sanity checks, and shows nothing for a field otherwise. With the SDK installed, the SDK's values
take precedence.

A multi-segment clip (`_001.R3D`, `_002.R3D`, … inside an `.RDC` folder) is previewed one
segment at a time. Frame count and duration are for the selected segment.

## Development

```sh
make test     # XCTest suite: parser (synthetic RED1/RED2 files), formatting, rendering, HTML
make clean
```
