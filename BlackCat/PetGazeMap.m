#import "PetGazeMap.h"
#import <zlib.h>

static const int width = 600, height = 540;
static const int unit = 512; // 64 direction steps × 8 displacement steps per pixel.

static uint16_t little16(const uint8_t *p) {
    uint16_t n;
    memcpy(&n, p, 2);
    return CFSwapInt16LittleToHost(n);
}

@implementation PetGazeMap {
    NSData *_data;
    int _left, _top, _width, _height;
}

- (instancetype)initWithURL:(NSURL *)url {
    if (!(self = [super init]) || !url) return nil;
    NSData *compressed = [NSData dataWithContentsOfURL:url];
    if (!compressed.length) return nil;
    uLongf length = 12 + width*height*6;
    uLong sourceLength = compressed.length;
    NSMutableData *raw = [NSMutableData dataWithLength:length];
    int status = uncompress2(raw.mutableBytes, &length, compressed.bytes, &sourceLength);
    if (status != Z_OK || sourceLength != compressed.length || length < 12) return nil;
    const uint8_t *header = raw.bytes;
    if (memcmp(header, "GAZ1", 4)) return nil;
    _left = little16(header+4); _top = little16(header+6);
    _width = little16(header+8); _height = little16(header+10);
    if (!_width || !_height || _left+_width > width || _top+_height > height ||
        length != 12 + (uLong)_width*_height*6) return nil;
    raw.length = length;
    _data = raw;
    return self;
}

- (NSData *)pixelsForSource:(NSData *)source pose:(PetGazePose)pose openEyes:(BOOL)open {
    if (source.length != (NSUInteger)width*height*4) return nil;
    if (!open) { pose.eyeX = 0; pose.eyeY = 0; }
    if (!(pose.headX || pose.headY || pose.eyeX || pose.eyeY)) return source;

    // The neutral frame is always the sampling source, including for successive animation ticks.
    NSMutableData *result = [source mutableCopy];
    const uint8_t *input = source.bytes;
    uint8_t *output = result.mutableBytes;
    const int8_t *field = (const int8_t *)_data.bytes + 12;
    for (int y = _top; y < _top+_height; y++) {
        const int8_t *c = field + (y-_top)*_width*6;
        for (int x = _left; x < _left+_width; x++, c += 6) {
            int dx = pose.headX*c[0] + pose.headY*c[2];
            int dy = pose.headX*c[1] + pose.headY*c[3];
            if (!dx && !dy) {
                dx = pose.eyeX*c[4];
                dy = pose.eyeY*c[5];
            } else if (pose.eyeX || pose.eyeY) {
                // Evaluate the iris mask in the head's neutral coordinates so it follows the face.
                int eyeX = (x-_left)*unit + dx + unit/2;
                int eyeY = (y-_top)*unit + dy + unit/2;
                if ((unsigned)eyeX < (unsigned)(_width*unit) && (unsigned)eyeY < (unsigned)(_height*unit)) {
                    const int8_t *eye = field + ((eyeY/unit)*_width+eyeX/unit)*6;
                    dx += pose.eyeX * eye[4];
                    dy += pose.eyeY * eye[5];
                }
            }
            if (!dx && !dy) continue;
            int sx = MAX(0, MIN((width-1)*unit, x*unit+dx));
            int sy = MAX(0, MIN((height-1)*unit, y*unit+dy));
            int ix = sx/unit, iy = sy/unit;
            const uint8_t *a = input+(iy*width+ix)*4;
            const uint8_t *b = ix < width-1 ? a+4 : a;
            const uint8_t *c0 = iy < height-1 ? a+width*4 : a;
            const uint8_t *d = ix < width-1 ? c0+4 : c0;
            int fx = sx%unit, fy = sy%unit;
            uint8_t *pixel = output+(y*width+x)*4;
            for (int k=0; k<4; k++) {
                int upper = (unit-fx)*a[k] + fx*b[k];
                int lower = (unit-fx)*c0[k] + fx*d[k];
                pixel[k] = ((unit-fy)*upper + fy*lower + unit*unit/2)/(unit*unit);
            }
        }
    }
    return result;
}
@end
