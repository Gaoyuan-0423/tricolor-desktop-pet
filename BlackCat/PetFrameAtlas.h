#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface PetFrameAtlas : NSObject
@property(nonatomic, readonly) NSUInteger frameCount;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (CGImageRef)copyImageForFrame:(NSString *)name CF_RETURNS_RETAINED;
@end

// Top-to-bottom rows in the same premultiplied sRGB RGBA format used for rendering.
FOUNDATION_EXPORT NSData *PetRGBAData(CGImageRef image);

FOUNDATION_EXPORT CGImageRef PetImageFromRGBA(NSData *pixels, size_t width, size_t height) CF_RETURNS_RETAINED;
