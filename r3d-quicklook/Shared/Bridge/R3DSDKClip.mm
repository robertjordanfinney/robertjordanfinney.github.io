#import "R3DSDKClip.h"

#include <algorithm>
#include <cstdlib>
#include <string>

// HAVE_R3DSDK is defined by Config/R3DSDK.local.xcconfig, which scripts/install-r3dsdk.sh writes.
#if defined(HAVE_R3DSDK) && HAVE_R3DSDK && __has_include("R3DSDK.h")
#define R3D_SDK_ENABLED 1
#include "R3DSDK.h"
#else
#define R3D_SDK_ENABLED 0
#endif

NSErrorDomain const R3DSDKClipErrorDomain = @"R3DSDKClipErrorDomain";

static NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:R3DSDKClipErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#if R3D_SDK_ENABLED

static BOOL gSDKReady = NO;
static NSString *gSDKStatus = @"";

/// Loads the SDK's runtime libraries (REDR3D.dylib etc.) once per process. They are copied into
/// the host app's Contents/Frameworks at build time; extensions find them two levels up.
static void EnsureSDKInitialized(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = NSBundle.mainBundle;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if (bundle.privateFrameworksPath) {
            [candidates addObject:bundle.privateFrameworksPath];
        }
        // <App>.app/Contents/PlugIns/<Ext>.appex -> <App>.app/Contents/Frameworks
        NSURL *contents = bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        [candidates addObject:[contents URLByAppendingPathComponent:@"Frameworks"].path];

        int lastStatus = -1;
        for (NSString *dir in candidates) {
            R3DSDK::InitializeStatus status = R3DSDK::InitializeSdk(dir.fileSystemRepresentation, OPTION_RED_NONE);
            if (status == R3DSDK::ISInitializeOK) {
                gSDKReady = YES;
                gSDKStatus = @"RED R3D SDK loaded — full frame decoding enabled.";
                return;
            }
            lastStatus = (int)status;
        }
        gSDKStatus = [NSString stringWithFormat:
                      @"RED R3D SDK is compiled in, but its runtime libraries could not be loaded (status %d).",
                      lastStatus];
    });
}

static void ReleasePixels(void *info, const void *data, size_t size) {
    free((void *)data);
}

#endif

@implementation R3DSDKClip {
#if R3D_SDK_ENABLED
    R3DSDK::Clip *_clip;
#endif
}

+ (BOOL)isSDKAvailable {
#if R3D_SDK_ENABLED
    EnsureSDKInitialized();
    return gSDKReady;
#else
    return NO;
#endif
}

+ (NSString *)sdkStatus {
#if R3D_SDK_ENABLED
    EnsureSDKInitialized();
    return gSDKStatus;
#else
    return @"Built without the RED R3D SDK — previews show clip information only. "
           @"Run scripts/install-r3dsdk.sh to enable frame decoding.";
#endif
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
#if R3D_SDK_ENABLED
    if (!R3DSDKClip.isSDKAvailable) {
        if (error) *error = MakeError(1, R3DSDKClip.sdkStatus);
        return nil;
    }
    _clip = new R3DSDK::Clip(url.fileSystemRepresentation);
    if (_clip->Status() != R3DSDK::LSClipLoaded) {
        if (error) *error = MakeError(2, [NSString stringWithFormat:@"The RED SDK could not open this clip (status %d).",
                                          (int)_clip->Status()]);
        delete _clip;
        _clip = nullptr;
        return nil;
    }
    return self;
#else
    if (error) *error = MakeError(1, R3DSDKClip.sdkStatus);
    return nil;
#endif
}

- (void)dealloc {
#if R3D_SDK_ENABLED
    delete _clip;
#endif
}

- (NSInteger)width {
#if R3D_SDK_ENABLED
    return (NSInteger)_clip->Width();
#else
    return 0;
#endif
}

- (NSInteger)height {
#if R3D_SDK_ENABLED
    return (NSInteger)_clip->Height();
#else
    return 0;
#endif
}

- (NSInteger)frameCount {
#if R3D_SDK_ENABLED
    return (NSInteger)_clip->VideoFrameCount();
#else
    return 0;
#endif
}

- (double)frameRate {
#if R3D_SDK_ENABLED
    return (double)_clip->VideoAudioFramerate();
#else
    return 0;
#endif
}

- (NSDictionary<NSString *, NSString *> *)metadata {
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
#if R3D_SDK_ENABLED
    for (size_t i = 0; i < _clip->MetadataCount(); i++) {
        std::string key = _clip->MetadataItemKey(i);
        std::string value = _clip->MetadataItemAsString(i);
        NSString *k = [NSString stringWithUTF8String:key.c_str()];
        NSString *v = [NSString stringWithUTF8String:value.c_str()];
        if (k.length && v.length) result[k] = v;
    }
#endif
    return result;
}

- (CGImageRef)copyFrameAtIndex:(NSInteger)index maxDimension:(NSInteger)maxDimension {
#if R3D_SDK_ENABLED
    const size_t clipW = _clip->Width(), clipH = _clip->Height();
    const size_t frames = _clip->VideoFrameCount();
    if (clipW == 0 || clipH == 0 || frames == 0) return NULL;
    const size_t frame = (size_t)std::min<NSInteger>(std::max<NSInteger>(index, 0), (NSInteger)frames - 1);

    // Cheapest decode resolution whose long side still covers the requested size.
    struct Option { size_t divisor; R3DSDK::VideoDecodeMode mode; };
    const Option options[] = {
        {16, R3DSDK::DECODE_SIXTEENTH_RES_GOOD},
        {8,  R3DSDK::DECODE_EIGHT_RES_GOOD},
        {4,  R3DSDK::DECODE_QUARTER_RES_GOOD},
        {2,  R3DSDK::DECODE_HALF_RES_GOOD},
        {1,  R3DSDK::DECODE_FULL_RES_PREMIUM},
    };
    const size_t longSide = std::max(clipW, clipH);
    Option chosen = options[4];
    for (const Option &option : options) {
        if (longSide / option.divisor >= (size_t)std::max<NSInteger>(maxDimension, 1)) { chosen = option; break; }
    }

    const size_t w = clipW / chosen.divisor, h = clipH / chosen.divisor;
    const size_t pixels = w * h;
    const size_t bufferSize = pixels * 3 * sizeof(uint16_t);
    void *buffer = NULL;
    if (posix_memalign(&buffer, 64, bufferSize) != 0) return NULL;

    R3DSDK::VideoDecodeJob job;
    job.BytesPerRow = w * sizeof(uint16_t);
    job.OutputBuffer = buffer;
    job.OutputBufferSize = bufferSize;
    job.Mode = chosen.mode;
    job.PixelType = R3DSDK::PixelType_16Bit_RGB_Planar;

    // Ask for a display-referred Rec.709 image instead of the clip's (usually log) look.
    R3DSDK::ImageProcessingSettings ips;
    _clip->GetDefaultImageProcessingSettings(ips);
    ips.ColorSpace = R3DSDK::ImageColorREC709;
    ips.GammaCurve = (ips.Version == R3DSDK::ColorVersion3) ? R3DSDK::ImageGammaBT1886
                                                             : R3DSDK::ImageGammaREC709;
    job.ImageProcessing = &ips;

    R3DSDK::DecodeStatus status = _clip->DecodeVideoFrame(frame, job);
    if (status != R3DSDK::DSDecodeOK) {
        job.ImageProcessing = NULL;  // fall back to the clip's own look
        status = _clip->DecodeVideoFrame(frame, job);
    }
    if (status != R3DSDK::DSDecodeOK) { free(buffer); return NULL; }

    // Planar 16-bit RGB -> interleaved 8-bit RGBX.
    uint8_t *rgbx = (uint8_t *)malloc(pixels * 4);
    if (!rgbx) { free(buffer); return NULL; }
    const uint16_t *r = (const uint16_t *)buffer, *g = r + pixels, *b = g + pixels;
    for (size_t i = 0; i < pixels; i++) {
        rgbx[i * 4 + 0] = (uint8_t)(r[i] >> 8);
        rgbx[i * 4 + 1] = (uint8_t)(g[i] >> 8);
        rgbx[i * 4 + 2] = (uint8_t)(b[i] >> 8);
        rgbx[i * 4 + 3] = 0xFF;
    }
    free(buffer);

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, rgbx, pixels * 4, ReleasePixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, space,
                                     kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                     provider, NULL, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
#else
    return NULL;
#endif
}

@end
