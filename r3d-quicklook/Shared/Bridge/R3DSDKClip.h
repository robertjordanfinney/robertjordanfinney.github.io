#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const R3DSDKClipErrorDomain;

/// Thin Objective-C wrapper around the RED R3D SDK, used to decode real frames.
///
/// The RED SDK is not redistributable in source form, so it is optional. When the project is
/// built without it (see scripts/install-r3dsdk.sh), `isSDKAvailable` is NO and
/// `-initWithURL:error:` always fails; the extensions then fall back to header-only previews.
@interface R3DSDKClip : NSObject

/// YES when the SDK was compiled in and its runtime libraries loaded successfully.
@property (class, nonatomic, readonly) BOOL isSDKAvailable;
/// Human-readable decoder status, suitable for showing in UI.
@property (class, nonatomic, readonly, copy) NSString *sdkStatus;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger frameCount;
@property (nonatomic, readonly) double frameRate;
/// Camera / clip metadata reported by the SDK (camera model, ISO, lens, timecode, …).
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *metadata;

/// Decodes one frame to an 8-bit sRGB image whose long side is at least `maxDimension`
/// (choosing the cheapest SDK decode resolution that satisfies it).
- (nullable CGImageRef)copyFrameAtIndex:(NSInteger)index
                           maxDimension:(NSInteger)maxDimension CF_RETURNS_RETAINED
    NS_SWIFT_NAME(copyFrame(at:maxDimension:));

@end

NS_ASSUME_NONNULL_END
