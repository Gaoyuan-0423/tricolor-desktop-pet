#import "PetFrameAtlas.h"
#import <ImageIO/ImageIO.h>
#import <zlib.h>

static const NSUInteger frameWidth = 600;
static const NSUInteger fullHeight = 540;
static const NSUInteger patchHeight = 250;
static const NSUInteger maxFrames = 290;
static const CGBitmapInfo pixelFormat = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;

static uint16_t uint16LE(const uint8_t *p) {
    uint16_t value;
    memcpy(&value, p, sizeof(value));
    return CFSwapInt16LittleToHost(value);
}

static uint32_t uint32LE(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return CFSwapInt32LittleToHost(value);
}

static NSData *inflateManifest(NSData *compressed) {
    if (!compressed.length || compressed.length > UINT_MAX) return nil;
    z_stream stream = {0};
    stream.next_in = (Bytef *)compressed.bytes;
    stream.avail_in = (uInt)compressed.length;
    if (inflateInit(&stream) != Z_OK) return nil;
    // Largest possible map uses 1-pixel tiles for every full-size frame.
    const NSUInteger limit = 14 + maxFrames * (258 + frameWidth * fullHeight * sizeof(uint32_t));
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[32768];
    int status;
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger bytes = sizeof(buffer) - stream.avail_out;
        if (bytes > limit - output.length) { status = Z_DATA_ERROR; break; }
        [output appendBytes:buffer length:bytes];
    } while (status == Z_OK);
    BOOL valid = status == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream);
    return valid ? output : nil;
}

NSData *PetRGBAData(CGImageRef image) {
    if (!image) return nil;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!width || !height || width > SIZE_MAX/4/height) return nil;
    NSMutableData *pixels = [NSMutableData dataWithLength:width*height*4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width*4, space, pixelFormat);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return pixels;
}

CGImageRef PetImageFromRGBA(NSData *pixels, size_t width, size_t height) {
    if (!width || !height || width > SIZE_MAX/4/height || pixels.length != width*height*4) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result = CGImageCreate(width, height, 8, 32, width*4, space,
                                      pixelFormat, provider, NULL, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return result;
}

@implementation PetFrameAtlas {
    NSData *_manifest;
    NSDictionary<NSString *, NSNumber *> *_frameOffsets;
    NSData *_atlasPixels;
    NSUInteger _tileSize, _atlasColumns, _atlasWidth;
}

- (instancetype)initWithDirectory:(NSURL *)directory {
    if (!(self = [super init])) return nil;
    NSData *compressed = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"frames.z"]];
    _manifest = inflateManifest(compressed);
    const NSUInteger length = _manifest.length;
    const uint8_t *data = _manifest.bytes;
    if (length < 14 || memcmp(data, "TPK1", 4)) return nil;
    _tileSize = uint16LE(data+4);
    _atlasColumns = uint16LE(data+6);
    NSUInteger tileCount = uint32LE(data+8);
    NSUInteger frameCount = uint16LE(data+12);
    if (!_tileSize || !_atlasColumns || !tileCount || !frameCount || frameCount > maxFrames) return nil;
    NSUInteger tilesAcross = (frameWidth + _tileSize-1) / _tileSize;
    NSMutableDictionary *offsets = [NSMutableDictionary dictionaryWithCapacity:frameCount];
    NSUInteger pos = 14;
    for (NSUInteger i = 0; i < frameCount; i++) {
        if (pos == length) return nil;
        NSUInteger nameLength = data[pos++];
        if (!nameLength || length-pos < nameLength+2) return nil;
        NSString *name = [[NSString alloc] initWithBytes:data+pos length:nameLength encoding:NSASCIIStringEncoding];
        if (!name || offsets[name]) return nil;
        pos += nameLength;
        offsets[name] = @(pos);
        NSUInteger height = uint16LE(data+pos);
        pos += 2;
        if (height != fullHeight && height != patchHeight) return nil;
        NSUInteger references = tilesAcross * ((height+_tileSize-1) / _tileSize);
        if (references > (length-pos)/sizeof(uint32_t)) return nil;
        for (NSUInteger j = 0; j < references; j++, pos += sizeof(uint32_t)) {
            if (uint32LE(data+pos) >= tileCount) return nil;
        }
    }
    if (pos != length) return nil;
    _frameOffsets = offsets;

    NSURL *url = [directory URLByAppendingPathComponent:@"atlas.png"];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    CGImageRef atlas = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!atlas) return nil;
    _atlasWidth = CGImageGetWidth(atlas);
    NSUInteger expectedWidth = _atlasColumns*_tileSize;
    NSUInteger expectedHeight = ((tileCount+_atlasColumns-1)/_atlasColumns)*_tileSize;
    if (_atlasWidth == expectedWidth && CGImageGetHeight(atlas) == expectedHeight)
        _atlasPixels = PetRGBAData(atlas);
    CGImageRelease(atlas);
    if (!_atlasPixels) return nil;
    return self;
}

- (NSUInteger)frameCount { return _frameOffsets.count; }

- (CGImageRef)copyImageForFrame:(NSString *)name {
    NSNumber *offset = _frameOffsets[name];
    if (!offset) return NULL;
    const uint8_t *indices = (const uint8_t *)_manifest.bytes + offset.unsignedIntegerValue;
    NSUInteger height = uint16LE(indices);
    indices += 2;
    NSMutableData *pixels = [NSMutableData dataWithLength:frameWidth*height*4];
    const uint8_t *atlas = _atlasPixels.bytes;
    uint8_t *destination = pixels.mutableBytes;
    for (NSUInteger y = 0; y < height; y += _tileSize) {
        NSUInteger rows = MIN(_tileSize, height-y);
        for (NSUInteger x = 0; x < frameWidth; x += _tileSize, indices += sizeof(uint32_t)) {
            NSUInteger index = uint32LE(indices);
            NSUInteger atlasX = (index % _atlasColumns) * _tileSize;
            NSUInteger atlasY = (index / _atlasColumns) * _tileSize;
            const uint8_t *from = atlas + (atlasY*_atlasWidth+atlasX)*4;
            uint8_t *to = destination + (y*frameWidth+x)*4;
            NSUInteger bytes = MIN(_tileSize, frameWidth-x)*4;
            for (NSUInteger row = 0; row < rows; row++)
                memcpy(to + row*frameWidth*4, from + row*_atlasWidth*4, bytes);
        }
    }
    return PetImageFromRGBA(pixels, frameWidth, height);
}
@end
