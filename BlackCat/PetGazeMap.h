#import <Foundation/Foundation.h>

typedef struct {
    int headX, headY, eyeX, eyeY; // Signed steps from -64 to 64.
} PetGazePose;

@interface PetGazeMap : NSObject
- (instancetype)initWithURL:(NSURL *)url;
- (NSData *)pixelsForSource:(NSData *)source pose:(PetGazePose)pose openEyes:(BOOL)open;
@end
