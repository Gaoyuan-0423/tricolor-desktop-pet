#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>
#import "PetFrameAtlas.h"
#import "PetGazeMap.h"
#import "PetMotion.h"
#import "PetLoginItem.h"

static const CGFloat frameWidth = 300;
static const CGFloat frameHeight = 270;
static const size_t rasterWidth = 600, rasterHeight = 540, keyPatchHeight = 250;
static const CGFloat previewControlsHeight = 48;
static NSArray<NSNumber *> *scaleOptions;
static NSArray<NSString *> *roleIDs;
static NSArray<NSString *> *roleNames;

// Physical macOS key codes mapped to the shared frame names. The period uses
// 1046 so its filename stays distinct from the Windows Delete key convention.
static const unsigned short keySymbols[] = {
    [18]='1', [19]='2', [20]='3', [21]='4', [23]='5', [22]='6', [26]='7',
    [28]='8', [25]='9', [29]='0', [27]='-', [24]='=',
    [12]='Q', [13]='W', [14]='E', [15]='R', [17]='T', [16]='Y', [32]='U',
    [34]='I', [31]='O', [35]='P', [33]='[', [30]=']',
    [0]='A', [1]='S', [2]='D', [3]='F', [5]='G', [4]='H', [38]='J',
    [40]='K', [37]='L', [41]=';', [39]='\'',
    [6]='Z', [7]='X', [8]='C', [9]='V', [11]='B', [45]='N', [46]='M',
    [43]=',', [47]=1046, [44]='/', [49]=32, [51]=8, [117]=127
};

static int symbolForCode(unsigned int code) {
    return code < sizeof(keySymbols) / sizeof(*keySymbols) ? keySymbols[code] : 0;
}

// Coordinates use the 300×270 artwork with its origin at the top left.
static NSPoint logicalCursorInScreenRect(NSPoint point, NSRect artwork) {
    if (NSIsEmptyRect(artwork)) return NSMakePoint(-1,-1);
    return NSMakePoint((point.x-NSMinX(artwork))*frameWidth/NSWidth(artwork),
                       (NSMaxY(artwork)-point.y)*frameHeight/NSHeight(artwork));
}

static NSPoint gazeTarget(NSPoint logicalCursor) {
    return NSMakePoint(tanh((logicalCursor.x-150)/170), tanh((logicalCursor.y-77)/125));
}

static NSPoint advanceGaze(NSPoint current, NSPoint target, NSTimeInterval elapsed, NSTimeInterval response) {
    double factor = -expm1(-elapsed/response);
    return NSMakePoint(current.x + (target.x-current.x)*factor,
                       current.y + (target.y-current.y)*factor);
}

static BOOL hitsHead(NSPoint point) {
    CGFloat x = (point.x - 150) / 43, y = (point.y - 77) / 52;
    return x*x + y*y <= 1;
}

static BOOL inNuzzleArea(NSPoint p) {
    return hitsHead(NSMakePoint(150+(p.x-150)/1.15,77+(p.y-77)/1.15));
}

typedef struct {
    BOOL active, horizontal;
    NSInteger started, lastSample;
    NSPoint anchor;
    CGFloat peak;
    int direction;
} HeadStroke;

static BOOL sampleStroke(HeadStroke *stroke, NSPoint point, NSInteger now) {
    if (!stroke->active || now - stroke->started > 900 || now - stroke->lastSample > 350) {
        *stroke = (HeadStroke){ .active = YES, .started = now, .lastSample = now, .anchor = point };
        return NO;
    }
    stroke->lastSample = now;
    if (!stroke->direction) {
        CGFloat dx = point.x - stroke->anchor.x, dy = point.y - stroke->anchor.y;
        if (MAX(fabs(dx), fabs(dy)) < 7) return NO;
        stroke->horizontal = fabs(dx) >= fabs(dy);
        stroke->direction = (stroke->horizontal ? dx : dy) > 0 ? 1 : -1;
        stroke->peak = stroke->horizontal ? point.x : point.y;
        return NO;
    }
    CGFloat position = stroke->horizontal ? point.x : point.y;
    CGFloat change = (position - stroke->peak) * stroke->direction;
    if (change > 0) stroke->peak = position;
    if (change > -7) return NO;
    stroke->active = NO;
    return YES;
}

static NSInteger milliseconds(void) {
    return (NSInteger)(NSProcessInfo.processInfo.systemUptime * 1000);
}

static PetHobby hobbyForRole(NSString *role) {
    if ([role isEqualToString:@"blue"]) return PetRice;
    return [role isEqualToString:@"frost"] ? PetCloud : PetReading;
}

static NSUInteger countForRole(NSString *role) {
    return [role isEqualToString:@"blue"] ? 288 : [role isEqualToString:@"frost"] ? 290 : 285;
}

static PetFrameAtlas *atlasForRole(NSString *role) {
    NSURL *directory = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:role isDirectory:YES];
    PetFrameAtlas *atlas=[[PetFrameAtlas alloc] initWithDirectory:directory];
    return atlas.frameCount==countForRole(role) ? atlas : nil;
}

static PetGazeMap *gazeMapForRole(NSString *role) {
    NSURL *url = [NSBundle.mainBundle URLForResource:role withExtension:@"gaze" subdirectory:@"gaze"];
    return [[PetGazeMap alloc] initWithURL:url];
}

static CGImageRef copyFrameImage(NSURL *url) CF_RETURNS_RETAINED {
    if (!url) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NULL;
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

static CGImageRef copyPatchedFrame(CGImageRef idle, CGImageRef patch) CF_RETURNS_RETAINED {
    if (!idle || !patch) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, rasterWidth, rasterHeight, 8, rasterWidth*4,
                                                space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return NULL;
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationNone);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, rasterWidth, rasterHeight), idle);
    // Quartz places y=0 at the bottom. Copy also replaces transparent patch pixels.
    CGContextDrawImage(bitmap, CGRectMake(0, 0, rasterWidth, keyPatchHeight), patch);
    CGImageRef result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return result;
}

// Copy or cross-fade only the exported face and heart rectangles in premultiplied sRGB.
static NSData *faceOnHands(NSData *hands, NSData *half, NSData *full, NSData *hearts, PetExpression face) {
    if (!hands || (face.level == 0 && face.heart < 0)) return hands;
    NSMutableData *pixels = [hands mutableCopy];
    uint8_t *out = pixels.mutableBytes;
    if (face.level > 0 && half.length == hands.length && full.length == hands.length) {
        const uint8_t *a = face.level <= 64 ? hands.bytes : half.bytes;
        const uint8_t *b = face.level <= 64 ? half.bytes : full.bytes;
        int blend = face.level <= 64 ? face.level : face.level-64;
        for (int y=108; y<254; y++) {
            size_t offset = (y*rasterWidth+208)*4, bytes = (389-208)*4;
            if (blend == 64) memcpy(out+offset,b+offset,bytes);
            else for (size_t k=offset; k<offset+bytes; k++)
                out[k] = ((64-blend)*a[k]+blend*b[k]+32)/64;
        }
    }
    if (face.heart >= 0 && hearts.length == hands.length) {
        const uint8_t *src = hearts.bytes;
        for (int y=39; y<162; y++) {
            size_t offset = (y*rasterWidth+420)*4;
            memcpy(out+offset,src+offset,(496-420)*4);
        }
    }
    return pixels;
}

// The pointer layer contains the whole mouse-side arm and shell. Its shoulder is
// fixed while its fingers and the shell use exactly the same displacement.
static NSData *pointerOnDesk(NSData *base, NSData *idle, NSData *desk, NSData *pointer, int dx8, int dy8) {
    NSUInteger size = rasterWidth*rasterHeight*4;
    if (base.length!=size || idle.length!=size || desk.length!=size || pointer.length!=size) return base;
    NSMutableData *composite = [base mutableCopy];
    uint8_t *out=composite.mutableBytes;
    const uint8_t *neutral=idle.bytes, *bare=desk.bytes, *layer=pointer.bytes;
    for (int y=290; y<540; y++) {
        double t=fmin(1,fmax(0,(y-312)/78.0)), f=t*t*(3-2*t);
        // Fixed-point offsets preserve subpixel motion and premultiplied alpha.
        int sxShift=(int)lround(-dx8*32*f), syShift=(int)lround(-dy8*32*f);
        for (int x=0; x<314; x++) {
            size_t offset=(600*y+x)*4;
            if (base==idle || !memcmp(out+offset,neutral+offset,4)) memcpy(out+offset,bare+offset,4);
            int sx=x*256+sxShift, sy=y*256+syShift;
            if (sx<0 || sy<0 || sx>=(600-1)*256 || sy>=(540-1)*256) continue;
            const uint8_t *a=layer+((sy/256)*600+sx/256)*4, *b=a+4, *c=a+2400, *d=c+4;
            if (!(a[3]|b[3]|c[3]|d[3])) continue;
            int fx=sx%256,fy=sy%256;
            int fg[4];
            for (int k=0; k<4; k++)
                fg[k]=((256-fy)*((256-fx)*a[k]+fx*b[k])+fy*((256-fx)*c[k]+fx*d[k])+32768)/65536;
            for (int k=0; k<4; k++) out[offset+k]=fg[k]+(out[offset+k]*(255-fg[3])+127)/255;
        }
    }
    return composite;
}

// Returning tail and hair pixels sit behind hands, cuffs and active keyboard highlights.
static NSData *recoverAccessories(NSData *base, NSData *idle, NSData *lower, NSData *upper, int fraction) {
    if (!base || base.length!=idle.length || base.length!=lower.length || base.length!=upper.length) return base;
    NSMutableData *out=[base mutableCopy];
    uint8_t *p=out.mutableBytes;
    const uint8_t *neutral=idle.bytes,*a=lower.bytes,*b=upper.bytes;
    for (int y=300;y<430;y++) for (int x=426;x<600;x++) {
        size_t off=(y*600+x)*4;
        if (memcmp(p+off,neutral+off,4)) continue;
        for (int k=0;k<4;k++) p[off+k]=((64-fraction)*a[off+k]+fraction*b[off+k]+32)/64;
    }
    return out;
}

static NSData *paintFace(NSData *base, NSData *idle, NSData *painting, int amount, BOOL preserveFood) {
    if (amount<=0 || base.length!=painting.length || (preserveFood && base.length!=idle.length)) return base;
    NSMutableData *result=[base mutableCopy];
    uint8_t *out=result.mutableBytes;
    const uint8_t *neutral=idle.bytes,*source=painting.bytes;
    for (int y=123;y<243;y++) for (int x=230;x<374;x++) {
        size_t off=(y*600+x)*4;
        if (preserveFood && memcmp(out+off,neutral+off,4)) continue;
        for (int k=0;k<4;k++) out[off+k]=((64-amount)*out[off+k]+amount*source[off+k]+32)/64;
    }
    return result;
}

static NSRect alphaBounds(NSData *toy) {
    if (toy.length!=600*540*4) return NSZeroRect;
    const uint8_t *p=toy.bytes;
    int left=600,top=540,right=0,bottom=0;
    for (int y=0;y<540;y++) for (int x=0;x<600;x++) if (p[(600*y+x)*4+3]) {
        left=MIN(left,x); top=MIN(top,y); right=MAX(right,x+1); bottom=MAX(bottom,y+1);
    }
    return right>left ? NSMakeRect(left,top,right-left,bottom-top) : NSZeroRect;
}

static NSPoint cloudPalm(int arm) {
    switch (arm) {
        case 2: return NSMakePoint(436,207);
        case 4: return NSMakePoint(437,291);
        default: return NSMakePoint(433,247);
    }
}

static NSPoint cloudCenter(PetMood mood) {
    if (mood.armFrom) {
        NSPoint a=cloudPalm(mood.armFrom),b=cloudPalm(mood.armTo);
        double t=mood.armBlend/256.0;
        return NSMakePoint(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t);
    }
    if (mood.hobbyPose==1) return cloudPalm(1);
    double t=mood.flight, u=1-t;
    return NSMakePoint(u*u*436+2*u*t*501.5+t*t*437, u*u*207+2*u*t*(-39)+t*t*291);
}

static void sampleArm(const uint8_t *src,int x256,int y256,int color[4]) {
    if (x256<0 || y256<0 || x256>=599*256 || y256>=539*256) {
        memset(color,0,4*sizeof(*color)); return;
    }
    const uint8_t *a=src+((y256/256)*600+x256/256)*4,*b=a+4,*c=a+2400,*d=c+4;
    int fx=x256%256,fy=y256%256;
    for (int k=0;k<4;k++)
        color[k]=((256-fy)*((256-fx)*a[k]+fx*b[k])+fy*((256-fx)*c[k]+fx*d[k])+32768)/65536;
}

// Align the two drawn palms before interpolating their translucent sleeves.
// The shoulder anchor and every wing and hair pixel on the background stay fixed.
static NSData *cloudArmsOnDesk(NSData *desk,NSData *armA,NSData *armB,NSRect armBounds,PetMood m) {
    if (desk.length!=600*540*4 || armA.length!=desk.length || armB.length!=desk.length) return desk;
    NSPoint center=cloudCenter(m),a=cloudPalm(m.armFrom),b=cloudPalm(m.armTo);
    NSRect region=NSIntersectionRect(NSInsetRect(armBounds,-6,-46),NSMakeRect(0,0,600,540));
    NSMutableData *result=[desk mutableCopy]; uint8_t *dst=result.mutableBytes;
    const uint8_t *pixelsA=armA.bytes,*pixelsB=armB.bytes;
    for (int x=(int)NSMinX(region);x<(int)NSMaxX(region);x++) {
        double f=fmin(1,fmax(0,(x-365)/56.0)); f=f*f*(3-2*f);
        int ax=x*256+(int)lround((a.x-center.x)*256*f),ay=(int)lround((a.y-center.y)*256*f);
        int bx=x*256+(int)lround((b.x-center.x)*256*f),by=(int)lround((b.y-center.y)*256*f);
        for (int y=(int)NSMinY(region);y<(int)NSMaxY(region);y++) {
            int ca[4],cb[4],fg[4];
            sampleArm(pixelsA,ax,y*256+ay,ca);
            sampleArm(pixelsB,bx,y*256+by,cb);
            if (!(ca[3]|cb[3])) continue;
            for (int k=0;k<4;k++) fg[k]=((256-m.armBlend)*ca[k]+m.armBlend*cb[k]+128)/256;
            uint8_t *out=dst+(y*600+x)*4;
            for (int k=0;k<4;k++) out[k]=fg[k]+(out[k]*(255-fg[3])+127)/255;
        }
    }
    return result;
}

static NSData *drawCloud(NSData *base, NSData *toy, NSRect box, NSPoint center) {
    if (!base || !toy || NSIsEmptyRect(box)) return base;
    int dx=(int)lround(center.x)-300,dy=(int)lround(center.y)-270;
    int x0=MAX(0,(int)NSMinX(box)+dx),x1=MIN(600,(int)NSMaxX(box)+dx);
    int y0=MAX(0,(int)NSMinY(box)+dy),y1=MIN(540,(int)NSMaxY(box)+dy);
    NSMutableData *result=[base mutableCopy]; uint8_t *dst=result.mutableBytes;
    const uint8_t *p=toy.bytes;
    for (int y=y0;y<y1;y++) for (int x=x0;x<x1;x++) {
        const uint8_t *src=p+((y-dy)*600+x-dx)*4;
        if (!src[3]) continue;
        uint8_t *out=dst+(y*600+x)*4;
        for (int k=0;k<4;k++) out[k]=src[k]+(out[k]*(255-src[3])+127)/255;
    }
    return result;
}

// Apply head/iris movement to the sitter alone. Book edges, hands and any
// foreground pixels drawn for this pose keep their original positions.
static NSData *gazeBehindProps(NSData *scene, NSData *pose, NSData *idle, NSData *gazed) {
    if (!gazed || scene.length!=pose.length || pose.length!=idle.length || idle.length!=gazed.length) return scene;
    NSMutableData *result=[scene mutableCopy]; uint8_t *dst=result.mutableBytes;
    const uint8_t *frame=pose.bytes,*neutral=idle.bytes,*portrait=gazed.bytes;
    for (int k=0;k<600*290*4;k+=4) {
        if (!memcmp(frame+k,neutral+k,4)) memcpy(dst+k,portrait+k,4);
    }
    return result;
}

static NSRect constrainToScreen(NSRect frame, NSScreen *screen) {
    if (screen) {
        NSRect visible = screen.visibleFrame;
        frame.origin.x = MAX(NSMinX(visible), MIN(frame.origin.x, NSMaxX(visible)-frame.size.width));
        frame.origin.y = MAX(NSMinY(visible), MIN(frame.origin.y, NSMaxY(visible)-frame.size.height));
    }
    return frame;
}

static NSURL *soundURL(int kind) {
    return [NSBundle.mainBundle URLForResource:[NSString stringWithFormat:@"%d", kind]
                                 withExtension:@"wav"];
}

@interface PetView : NSView
@property(nonatomic) BOOL muted;
@property(nonatomic) BOOL draggable;
@property(nonatomic, copy) NSString *role;
- (void)pressKey:(unsigned int)code;
- (void)pressKey:(unsigned int)code atTime:(NSInteger)eventTime;
- (void)mouseActivity:(NSEventType)eventType;
- (void)notePhysicalActivity;
- (void)tick;
@end

@implementation PetView {
    NSCache<NSString *, NSData *> *_framePixels;
    NSString *_shownFrame;
    NSImage *_currentImage;
    CGImageRef _idleReference;
    PetFrameAtlas *_atlas;
    PetGazeMap *_gazeMap;
    PetGazePose _pose, _shownPose;
    NSData *_neutralPixels, *_hobbyPortrait, *_hobbyPose, *_hobbyIdle;
    NSArray<NSSound *> *_sounds;
    NSInteger _started, _lastGazeSample;
    NSTimer *_contactTimer;
    PetHands _hands;
    PetPats _pats;
    PetInteraction _interaction;
    PetMood _mood;
    PetExpression _shownExpression;
    PetPaintedFace _shownPainting;
    NSPoint _eyeDirection, _headDirection, _shownToy;
    NSRect _toyBounds, _armBounds;
    int _shownArmFrom, _shownArmBlend;
    NSPoint _downPoint, _windowAtPress, _holdPoint, _lastPointer, _deskTarget, _deskPosition;
    NSInteger _downAt, _lastDeskSample;
    int _shownPointerX, _shownPointerY, _shownZ, _shownRest;
    BOOL _pressed, _canPat, _dragged, _holding, _hasPointer, _shownGrip;
    HeadStroke _stroke;
}

- (instancetype)initWithFrame:(NSRect)rect {
    if ((self = [super initWithFrame:rect])) {
        _framePixels = [NSCache new];
        _framePixels.totalCostLimit = 32 * 1024 * 1024;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
        _muted = [NSUserDefaults.standardUserDefaults boolForKey:@"soundMuted"];
        _started = milliseconds();
        PetInteractionInit(&_interaction,_started);
        _shownZ=-1;
        PetHandsInit(&_hands);
        PetPatsInit(&_pats);
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"selectedRole"];
        _role = [roleIDs containsObject:saved ?: @""] ? saved : roleIDs.firstObject;
        _interaction.hobby=hobbyForRole(_role);
        _atlas = atlasForRole(_role);
        _gazeMap = gazeMapForRole(_role);
        [self tick];
    }
    return self;
}

- (NSString *)accessibilityLabel {
    NSUInteger index = [roleIDs indexOfObject:_role];
    return index < roleNames.count ? roleNames[index] : @"三色桌宠";
}

- (void)setRole:(NSString *)role {
    if (![roleIDs containsObject:role] || [_role isEqualToString:role]) return;
    PetFrameAtlas *atlas = atlasForRole(role);
    PetGazeMap *gazeMap = gazeMapForRole(role);
    if (!atlas || !gazeMap) return;
    _atlas = atlas;
    _gazeMap = gazeMap;
    _role = [role copy];
    _interaction.hobby=hobbyForRole(role);
    _interaction.nextExpression=-1; _interaction.expressionEnds=-1; _interaction.previousExpression=0; _interaction.mealActivity=-1;
    _shownFrame = nil;
    _toyBounds=NSZeroRect; _armBounds=NSZeroRect;
    PetPatsInit(&_pats);
    _stroke.active = NO;
    [_framePixels removeAllObjects];
    if (_idleReference) {
        CGImageRelease(_idleReference);
        _idleReference = NULL;
    }
    [NSUserDefaults.standardUserDefaults setObject:_role forKey:@"selectedRole"];
    [self tick];
    NSAccessibilityPostNotification(self, NSAccessibilityTitleChangedNotification);
}

- (void)dealloc {
    [_contactTimer invalidate];
    if (_idleReference) CGImageRelease(_idleReference);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSString *)accessibilityValue {
    if (_mood.sleeping) return @"睡着";
    if (_mood.hobbyPose) return _interaction.hobby==PetRice ? @"吃白饭" : _interaction.hobby==PetReading ? @"看书" : @"抛接云玩偶";
    if (_holding) return @"蹭头";
    if (_mood.drowsy) return @"困倦";
    if (_shownExpression.smiling) return @"微笑";
    if ([_shownFrame hasPrefix:@"wrist"]) return @"抬腕";
    if ([_shownFrame hasPrefix:@"key"]) return @"敲键盘";
    if ([_shownFrame hasPrefix:@"mouse"]) return @"使用鼠标";
    return @"待机";
}

- (NSPoint)logicalPointAtScreenPoint:(NSPoint)screen {
    NSRect windowRect = [self convertRect:self.bounds toView:nil];
    return logicalCursorInScreenRect(screen, [self.window convertRectToScreen:windowRect]);
}

- (void)smile {
    NSInteger now=milliseconds();
    PetNoteActivity(&_interaction,now);
    PetPat(&_pats,now);
    _stroke.active = NO;
    [self tick];
}

- (void)mouseDown:(NSEvent *)event {
    _downAt=milliseconds();
    PetNoteActivity(&_interaction,_downAt);
    if (_holding) PetEndHold(&_interaction,_downAt);
    _downPoint = [self.window convertPointToScreen:event.locationInWindow];
    _windowAtPress = self.window.frame.origin;
    _pressed = YES;
    _dragged = NO;
    _stroke.active = NO;
    _holdPoint=[self logicalPointAtScreenPoint:_downPoint];
    _canPat=hitsHead(_holdPoint);
    _holding=NO;
    [self tick];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pressed) return;
    NSPoint screen = [self.window convertPointToScreen:event.locationInWindow];
    NSInteger now=milliseconds();
    PetNoteActivity(&_interaction,now);
    if (_canPat && !_holding && !_dragged && now-_downAt>=350) {
        PetStartHold(&_interaction,_downAt+350); _holding=YES;
    }
    NSPoint head=[self logicalPointAtScreenPoint:screen];
    if (_holding && !inNuzzleArea(head)) {
        PetEndHold(&_interaction,now);
        _holding=NO; _dragged=YES; _canPat=NO;
        _downPoint=screen;
        _windowAtPress=self.window.frame.origin;
    }
    if (_holding) { _holdPoint=head; [self tick]; return; }
    CGFloat dx = screen.x - _downPoint.x, dy = screen.y - _downPoint.y;
    if (hypot(dx, dy) >= 3) { _dragged=YES; _canPat=NO; }
    if (_dragged && self.draggable) {
        NSScreen *target = self.window.screen;
        for (NSScreen *display in NSScreen.screens) {
            if (NSPointInRect(screen, display.frame)) { target = display; break; }
        }
        NSRect frame = self.window.frame;
        frame.origin = NSMakePoint(_windowAtPress.x + dx, _windowAtPress.y + dy);
        [self.window setFrameOrigin:constrainToScreen(frame, target).origin];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint screen = [self.window convertPointToScreen:event.locationInWindow];
    NSInteger now=milliseconds();
    BOOL tap = _pressed && _canPat && !_holding && !_dragged && now-_downAt<350 &&
        hypot(screen.x-_downPoint.x, screen.y-_downPoint.y)<3;
    PetNoteActivity(&_interaction,now);
    if (_holding) PetEndHold(&_interaction,now);
    _holding=NO; _pressed=NO; _canPat=NO;
    if (tap && hitsHead([self logicalPointAtScreenPoint:screen])) [self smile];
    else [self tick];
}

- (void)cancelOperation:(id)sender {
    if (_holding) PetEndHold(&_interaction,milliseconds());
    _holding=NO; _pressed=NO; _canPat=NO; _stroke.active=NO;
    [self tick];
}

- (void)notePhysicalActivity { PetNoteActivity(&_interaction,milliseconds()); [self tick]; }

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    [NSUserDefaults.standardUserDefaults setBool:muted forKey:@"soundMuted"];
    if (muted) for (NSSound *sound in _sounds) [sound stop];
}

- (void)playKey:(int)symbol {
    if (self.muted) return;
    if (!_sounds) {
        NSMutableArray<NSSound *> *sounds = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            NSURL *url = soundURL(i);
            NSSound *sound = url ? [[NSSound alloc] initWithContentsOfURL:url byReference:NO] : nil;
            if (!sound) return;
            sound.volume = .42;
            [sounds addObject:sound];
        }
        _sounds = sounds;
    }
    int kind = symbol == 32 ? 1 : symbol == 8 || symbol == 127 ? 2 : 0;
    NSSound *sound = _sounds[kind];
    [sound stop];
    [sound play];
}

- (void)pressKey:(unsigned int)code {
    [self pressKey:code atTime:milliseconds()];
}

- (void)pressKey:(unsigned int)code atTime:(NSInteger)eventTime {
    NSInteger now=milliseconds();
    PetNoteActivity(&_interaction,now);
    int symbol = symbolForCode(code);
    if (!symbol) { [self tick]; return; }
    NSInteger start = MAX(MAX(_hands.lastMouse,_hands.lastKey),MAX(now-25,MIN(now,eventTime)));
    [_contactTimer invalidate];
    _contactTimer = nil;
    PetPress(&_hands,symbol,start);
    [self tick];
    if (_hands.style == PetRapidKey) {
        [self displayIfNeeded];
    } else {
        // A 60 ms key interval leaves one refresh for contact. Schedule that frame
        // at its own deadline so it cannot fall between two animation timer ticks.
        NSInteger contact = start + (_hands.style == PetKeyFromMouse ? 44 : 42);
        __weak PetView *weakSelf = self;
        _contactTimer = [NSTimer timerWithTimeInterval:MAX(0,contact-milliseconds())/1000.0
            repeats:NO block:^(NSTimer *timer) {
                PetView *view = weakSelf;
                [view tick];
                [view displayIfNeeded];
            }];
        [NSRunLoop.mainRunLoop addTimer:_contactTimer forMode:NSRunLoopCommonModes];
        [self pixelsForFrame:[NSString stringWithFormat:@"key%d-3",symbol]];
    }
    [self playKey:symbol];
}

- (void)mouseActivity:(NSEventType)eventType {
    if (!self.window) return;
    NSRect bounds = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    NSPoint p = NSEvent.mouseLocation;
    int quadrant = (p.x > NSMidX(bounds) ? 1 : 0) + (p.y > NSMidY(bounds) ? 2 : 0);
    NSInteger now = milliseconds();
    BOOL moving=eventType==NSEventTypeMouseMoved || eventType==NSEventTypeLeftMouseDragged ||
                eventType==NSEventTypeRightMouseDragged || eventType==NSEventTypeOtherMouseDragged;
    if (moving && _hasPointer && NSEqualPoints(p,_lastPointer)) return;
    PetNoteActivity(&_interaction,now);
    if (moving && _hasPointer) {
        CGFloat scale=frameWidth/MAX(1,NSWidth(bounds));
        if (now-_hands.lastMouse>=850) _deskTarget=NSZeroPoint;
        _deskTarget.x=fmax(-12,fmin(12,_deskTarget.x+(p.x-_lastPointer.x)*scale*.16));
        _deskTarget.y=fmax(-8,fmin(8,_deskTarget.y-(p.y-_lastPointer.y)*scale*.16));
    }
    _lastPointer=p; _hasPointer=YES;
    NSPoint point = [self logicalPointAtScreenPoint:p];
    if (eventType == NSEventTypeMouseMoved && !_pressed && !NSEvent.pressedMouseButtons && hitsHead(point)) {
        if (sampleStroke(&_stroke, point, now)) [self smile];
    } else {
        _stroke.active = NO;
    }
    PetMove(&_hands,quadrant,now);
    [self tick];
}

- (void)trackCursor:(NSInteger)now {
    if (!self.window || NSIsEmptyRect(self.bounds)) return;
    NSTimeInterval dt = _lastGazeSample ? MIN((now-_lastGazeSample)/1000.0, .12) : 1.0/60;
    _lastGazeSample = now;
    NSPoint target = gazeTarget([self logicalPointAtScreenPoint:NSEvent.mouseLocation]);
    _eyeDirection = advanceGaze(_eyeDirection, target, dt, .065);
    _headDirection = advanceGaze(_headDirection, target, dt, .135);
    _pose=(PetGazePose){(int)lround(_headDirection.x*64),(int)lround(_headDirection.y*64),
                       (int)lround(_eyeDirection.x*64),(int)lround(_eyeDirection.y*64)};
}

- (NSData *)pixelsForFrame:(NSString *)frame {
    NSData *pixels = [_framePixels objectForKey:frame];
    if (pixels) return pixels;
    CGImageRef bitmap = [_atlas copyImageForFrame:frame];
    if ([frame hasPrefix:@"key"] && bitmap) {
        if (!_idleReference) _idleReference = [_atlas copyImageForFrame:@"idle0"];
        CGImageRef full = copyPatchedFrame(_idleReference, bitmap);
        CGImageRelease(bitmap);
        bitmap = full;
    }
    if (bitmap) {
        pixels = PetRGBAData(bitmap);
        CGImageRelease(bitmap);
        if (pixels) [_framePixels setObject:pixels forKey:frame cost:pixels.length];
    }
    return pixels;
}

- (void)tick {
    NSInteger now=milliseconds(), elapsed=now-_started;
    if (_pressed && _canPat && !_dragged && !_holding && now-_downAt>=350) {
        PetStartHold(&_interaction,_downAt+350);
        _holding=YES;
    }
    _mood=PetMoodAt(&_interaction,now,(_holdPoint.x-150)/43,(_holdPoint.y-77)/52);
    [self trackCursor:now];
    NSString *hands=PetHandFrame(&_hands,now,elapsed);
    if (_mood.hobbyPose) {
        NSString *name=_interaction.hobby==PetRice ? @"rice" : _interaction.hobby==PetReading ? @"book" : @"toss";
        hands=[NSString stringWithFormat:@"%@%d",name,_mood.hobbyPose];
    } else if (_interaction.hobby!=PetRice && _mood.drowsy && [hands hasPrefix:@"idle"]) {
        int stage=MIN(4,1+(int)((now-_interaction.lastActivity-57000)/750));
        hands=[NSString stringWithFormat:@"rest%d",stage];
    }
    PetExpression face=_mood.hobbyPose ? (PetExpression){.heart=-1} : PetFace(&_pats,now,elapsed);
    if (!face.smiling && (_mood.drowsy || _mood.lids>0)) face.level=_mood.lids;
    if (_mood.nuzzleWeight>0) {
        face=(PetExpression){.level=(int)lround(84*_mood.nuzzleWeight),.heart=_mood.heart,.smiling=YES};
    }
    PetPaintedFace painting=PetPickFace(&_interaction,_mood,now,
        [hands hasPrefix:@"idle"] && !face.smiling && !_pressed);
    double dt=_lastDeskSample ? MIN(.12,(now-_lastDeskSample)/1000.0) : 0;
    _lastDeskSample=now;
    _deskPosition=advanceGaze(_deskPosition,_deskTarget,dt,.065);
    int level=PetMouseLevel(&_hands,now);
    BOOL leftKey=[hands hasPrefix:@"key"] && PetOffHandKey(_hands.symbol);
    BOOL dynamicGrip=level==3 && ([hands hasPrefix:@"mouse"] || leftKey);
    NSString *reach=leftKey && level>0 && level<3 ?
        [NSString stringWithFormat:@"mouse%d%d",level,_hands.quadrant] : nil;
    NSInteger bridgeAge=now-_hands.bridgeAt;
    if (leftKey && _hands.mouseRequested && _hands.bridgeToMouse && now-_hands.lastMouse<850 &&
        bridgeAge>=0 && bridgeAge<40)
        reach=[NSString stringWithFormat:@"wrist%ld",(long)(3-bridgeAge/10)];
    NSInteger stableAt=_hands.bridgeAt+(_hands.bridgeToMouse ? 40 : 95);
    double fade=fmax(0,fmin(1,(now-stableAt)/35.0))*fmax(0,fmin(1,(690-(now-_hands.lastMouse))/65.0));
    int dx8=dynamicGrip ? (int)lround(_deskPosition.x*fade*8) : 0;
    int dy8=dynamicGrip ? (int)lround(_deskPosition.y*fade*8) : 0;
    NSString *frameKey=reach ? [NSString stringWithFormat:@"%@+%@",hands,reach] : hands;
    BOOL changed=![_shownFrame isEqualToString:frameKey] || dynamicGrip!=_shownGrip || _shownRest!=_mood.restRecovery ||
        painting.blend!=_shownPainting.blend || painting.number!=_shownPainting.number ||
        _mood.armFrom!=_shownArmFrom || (_mood.armFrom && _mood.armBlend!=_shownArmBlend) ||
        dx8!=_shownPointerX || dy8!=_shownPointerY || face.level!=_shownExpression.level ||
        face.heart!=_shownExpression.heart || face.smiling!=_shownExpression.smiling;
    BOOL reading=_mood.hobbyPose && _interaction.hobby==PetReading;
    BOOL playing=_mood.hobbyPose && _interaction.hobby==PetCloud;
    if (changed) {
        NSData *idle=(dynamicGrip || reach) ? [self pixelsForFrame:@"idle0"] : nil;
        NSData *base=dynamicGrip && !leftKey ? idle : [self pixelsForFrame:hands];
        if (dynamicGrip)
            base=pointerOnDesk(base,idle,[self pixelsForFrame:@"deskFree"],[self pixelsForFrame:@"pointer"],dx8,dy8);
        else if (reach && idle) {
            NSData *arm=[self pixelsForFrame:reach];
            NSMutableData *combined=[base mutableCopy];
            if (arm.length==base.length && idle.length==base.length) {
                uint8_t *dst=combined.mutableBytes;
                const uint8_t *src=arm.bytes,*neutral=idle.bytes;
                for (int y=290;y<540;y++) for (int x=0;x<314;x++) {
                    size_t off=(y*600+x)*4;
                    if (!memcmp(dst+off,neutral+off,4)) memcpy(dst+off,src+off,4);
                }
            }
            base=combined;
        }
        if (_mood.restRecovery>0) {
            if (!idle) idle=[self pixelsForFrame:@"idle0"];
            int upper=(_mood.restRecovery+63)/64;
            NSData *lo=upper==1 ? idle : [self pixelsForFrame:[NSString stringWithFormat:@"rest%d",upper-1]];
            NSData *hi=[self pixelsForFrame:[NSString stringWithFormat:@"rest%d",upper]];
            base=recoverAccessories(base,idle,lo,hi,_mood.restRecovery-(upper-1)*64);
        }
        if (_mood.armFrom) {
            NSData *armA=[self pixelsForFrame:[NSString stringWithFormat:@"tossArm%d",_mood.armFrom]];
            NSData *armB=[self pixelsForFrame:[NSString stringWithFormat:@"tossArm%d",_mood.armTo]];
            if (NSIsEmptyRect(_armBounds)) {
                _armBounds=NSUnionRect(alphaBounds([self pixelsForFrame:@"tossArm1"]),alphaBounds([self pixelsForFrame:@"tossArm2"]));
                _armBounds=NSUnionRect(_armBounds,alphaBounds([self pixelsForFrame:@"tossArm4"]));
            }
            base=cloudArmsOnDesk([self pixelsForFrame:@"tossDesk"],armA,armB,_armBounds,_mood);
        }
        _hobbyPose=(reading || playing) ? base : nil;
        _hobbyIdle=(reading || playing) ? [self pixelsForFrame:@"idle0"] : nil;
        _hobbyPortrait=_hobbyIdle;
        if (painting.blend) {
            if (!idle && _mood.hobbyPose) idle=[self pixelsForFrame:@"idle0"];
            NSData *source=[self pixelsForFrame:[NSString stringWithFormat:@"mood%d",painting.number]];
            base=paintFace(base,idle,source,painting.blend,_mood.hobbyPose!=0);
            if (_hobbyIdle) _hobbyPortrait=paintFace(_hobbyIdle,nil,source,painting.blend,NO);
        }
        NSData *half=face.level ? [self pixelsForFrame:face.smiling ? @"smileHalf" : @"blinkHalf"] : nil;
        NSData *full=face.level ? [self pixelsForFrame:face.smiling ? @"smile0" : @"idle7"] : nil;
        NSData *hearts=face.heart<0 ? nil : [self pixelsForFrame:[NSString stringWithFormat:@"smile%d",face.heart]];
        _neutralPixels=faceOnHands(base,half,full,hearts,face);
        _shownFrame=frameKey; _shownGrip=dynamicGrip; _shownRest=_mood.restRecovery;
        _shownPointerX=dx8; _shownPointerY=dy8;
        _shownExpression=face; _shownPainting=painting;
        _shownArmFrom=_mood.armFrom; _shownArmBlend=_mood.armBlend;
    }
    PetGazePose effective=_pose;
    effective.headX=(int)lround(fmax(-64,fmin(64,_pose.headX*_mood.gazeGain+64*_mood.headX)));
    effective.headY=(int)lround(fmax(-64,fmin(64,_pose.headY*_mood.gazeGain+64*_mood.headY)));
    double eyeGain=PetIrisGain(face.level)*_mood.gazeGain*(64-painting.blend)/(192.0*64);
    effective.eyeX=(int)lround(effective.eyeX*eyeGain);
    effective.eyeY=(int)lround(effective.eyeY*eyeGain);
    NSPoint toy=playing ? cloudCenter(_mood) : NSZeroPoint;
    if (reading) {
        double sweep=sin(2*M_PI*(now-_interaction.lastActivity-45000)/1600.0);
        effective=(PetGazePose){(int)lround(64*.04*sweep),8,(int)lround(64*.14*sweep),22};
        eyeGain=1;
    } else if (playing) {
        double u=fmax(-1,fmin(1,(toy.x-300)/175.0)), v=fmax(-1,fmin(1,(toy.y-160)/130.0));
        effective=(PetGazePose){(int)lround(64*.14*u),(int)lround(64*.14*v),
                                (int)lround(64*.38*u),(int)lround(64*.45*v)};
        eyeGain=1;
    }
    if ((reading && painting.number==2) || (playing && painting.number==3)) {
        effective.eyeX=0; effective.eyeY=0; eyeGain=0;
    }
    toy=NSMakePoint(round(toy.x),round(toy.y));
    if (!NSEqualPoints(toy,_shownToy)) { changed=YES; _shownToy=toy; }
    int z=_mood.zPhase;
    if (z!=_shownZ) { _shownZ=z; [self setNeedsDisplay:YES]; }
    if (!changed && !memcmp(&effective,&_shownPose,sizeof(effective))) return;
    _shownPose=effective;
    NSData *pixels=[_gazeMap pixelsForSource:_hobbyPortrait ?: _neutralPixels pose:effective openEyes:eyeGain>0];
    if (_hobbyPose) pixels=gazeBehindProps(_neutralPixels,_hobbyPose,_hobbyIdle,pixels);
    if (playing) {
        NSData *cloud=[self pixelsForFrame:@"toy"];
        if (NSIsEmptyRect(_toyBounds)) _toyBounds=alphaBounds(cloud);
        pixels=drawCloud(pixels,cloud,_toyBounds,toy);
    }
    CGImageRef image=PetImageFromRGBA(pixels,rasterWidth,rasterHeight);
    _currentImage=image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(frameWidth,frameHeight)] : nil;
    _currentImage.cacheMode=NSImageCacheNever;
    if (image) CGImageRelease(image);
    [self setNeedsDisplay:YES];
}

- (void)drawSleepMarksInRect:(NSRect)rect scale:(CGFloat)scale {
    if (_shownZ<0) return;
    for (int i=0;i<3;i++) {
        NSInteger t=(_shownZ*80-360*i+2000)%2000;
        if (t>=1100) continue;
        CGFloat opacity=(190/255.0)*MIN(1,MIN(t/180.0,(1100-t)/280.0));
        CGFloat x=NSMinX(rect)+(216+13*i)*scale, y=NSMaxY(rect)-(82-15*i-6*t/1100.0)*scale;
        CGFloat side=(5+2*i)*scale;
        NSBezierPath *z=[NSBezierPath bezierPath];
        [z moveToPoint:NSMakePoint(x,y)];
        [z lineToPoint:NSMakePoint(x+side,y)];
        [z lineToPoint:NSMakePoint(x,y-side)];
        [z lineToPoint:NSMakePoint(x+side,y-side)];
        z.lineJoinStyle=NSLineJoinStyleRound; z.lineCapStyle=NSLineCapStyleRound;
        [[NSColor colorWithWhite:1 alpha:opacity] setStroke]; z.lineWidth=3.1*scale; [z stroke];
        [[NSColor colorWithSRGBRed:.30 green:.36 blue:.53 alpha:opacity] setStroke]; z.lineWidth=1.35*scale; [z stroke];
    }
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor setFill];
    NSRectFillUsingOperation(dirty, NSCompositingOperationCopy);
    NSSize available = self.bounds.size;
    CGFloat scale = MIN(available.width / frameWidth, available.height / frameHeight);
    NSRect dest = NSMakeRect((available.width - frameWidth*scale)/2,
                             (available.height - frameHeight*scale)/2,
                             frameWidth*scale, frameHeight*scale);
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [_currentImage drawInRect:dest fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                     fraction:1 respectFlipped:YES hints:nil];
    [self drawSleepMarksInRect:dest scale:scale];
}
@end

@interface PetApplication : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@property(nonatomic) BOOL preview;
@property(nonatomic, strong) PetView *pet;
- (void)checkKeyboard;
@end

static CGEventRef observeKey(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context);

@implementation PetApplication {
    NSWindow *_window;
    NSStatusItem *_statusItem;
    NSSegmentedControl *_roleControl;
    NSButton *_muteControl;
    NSMenuItem *_muteItem, *_keyboardStatus, *_controlsItem;
    NSMenuItem *_loginItem, *_loginSettings;
    NSArray<NSMenuItem *> *_roleItems, *_sizeItems;
    NSInteger _scalePercent;
    id _localMonitor, _globalMonitor;
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
}

- (void)selectRole:(id)sender {
    NSInteger index = sender == _roleControl ? _roleControl.selectedSegment : [sender tag];
    if (index < 0 || index >= (NSInteger)roleIDs.count) return;
    self.pet.role = roleIDs[index];
    _roleControl.selectedSegment = index;
    [self updateMenu];
}

- (void)toggleMute:(id)sender {
    self.pet.muted = !self.pet.muted;
    [self updateMenu];
}

- (void)layoutPet {
    NSRect oldFrame = _window.frame;
    NSScreen *screen = _window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    BOOL controls = self.preview && !_roleControl.hidden;
    CGFloat controlsHeight = controls ? previewControlsHeight : 0;
    NSSize options = _roleControl.frame.size, mute = _muteControl.frame.size;
    CGFloat controlsWidth = controls ? options.width + mute.width + 40 : 0;
    CGFloat chrome = oldFrame.size.height - [_window contentRectForFrameRect:oldFrame].size.height;
    CGFloat scale = _scalePercent / 100.0;
    if (screen) scale = MIN(scale, MIN(visible.size.width / frameWidth,
                                       (visible.size.height - chrome - controlsHeight) / frameHeight));
    CGFloat artWidth = frameWidth*scale, artHeight = frameHeight*scale;
    CGFloat width = MAX(artWidth, controlsWidth);
    NSRect content = NSMakeRect(0, 0, width, artHeight + controlsHeight);
    NSRect next = [_window frameRectForContentRect:content];
    next.origin.x = NSMidX(oldFrame) - next.size.width/2;
    next.origin.y = self.preview ? NSMaxY(oldFrame) - next.size.height : NSMinY(oldFrame);
    next = constrainToScreen(next, screen);
    if (!NSEqualRects(oldFrame, next)) [_window setFrame:next display:YES];
    self.pet.frame = NSMakeRect((width-artWidth)/2, 0, artWidth, artHeight);
    if (controls) {
        CGFloat left = (width-options.width-mute.width-16)/2;
        _roleControl.frameOrigin = NSMakePoint(left, artHeight+(controlsHeight-options.height)/2);
        _muteControl.frameOrigin = NSMakePoint(left+options.width+16, artHeight+(controlsHeight-mute.height)/2);
    }
    [self.pet setNeedsDisplay:YES];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    if (self.pet && _scalePercent) [self layoutPet];
}

- (void)selectScale:(NSMenuItem *)sender {
    _scalePercent = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:_scalePercent forKey:@"petScalePercent"];
    [self layoutPet];
    [self updateMenu];
}

- (void)togglePreviewControls:(id)sender {
    BOOL visible = _roleControl.hidden;
    _roleControl.hidden = !visible;
    _muteControl.hidden = !visible;
    [NSUserDefaults.standardUserDefaults setBool:visible forKey:@"showsPreviewControls"];
    [self layoutPet];
    [self updateMenu];
}

- (void)updateMenu {
    NSUInteger i = [roleIDs indexOfObject:self.pet.role];
    for (NSMenuItem *item in _roleItems)
        item.state = item.tag == (NSInteger)i ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *item in _sizeItems)
        item.state = item.tag == _scalePercent ? NSControlStateValueOn : NSControlStateValueOff;
    NSControlStateValue muteState = self.pet.muted ? NSControlStateValueOn : NSControlStateValueOff;
    _muteItem.state = muteState;
    _muteControl.state = muteState;
    _controlsItem.state = _roleControl.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    _statusItem.button.toolTip = [NSString stringWithFormat:@"三色桌宠 · %@", roleNames[i]];
}

- (void)refreshLoginItem {
    PetLoginStatus status = PetLoginItemStatus();
    _loginItem.title = status == PetLoginNeedsApproval ? @"登录时启动（等待系统允许）" :
                       status == PetLoginUnavailable ? @"登录时启动（状态不可用）" : @"登录时启动";
    _loginItem.state = status == PetLoginOn ? NSControlStateValueOn :
                       status == PetLoginOff ? NSControlStateValueOff : NSControlStateValueMixed;
    _loginSettings.hidden = status != PetLoginNeedsApproval;
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self refreshLoginItem]; }

- (void)openLoginSettings:(id)sender { PetOpenLoginItemSettings(); }

- (void)toggleLoginItem:(id)sender {
    PetLoginStatus current = PetLoginItemStatus();
    BOOL enable = current != PetLoginOn && current != PetLoginNeedsApproval;
    NSError *error = nil;
    if (!PetSetLoginItemEnabled(enable,&error)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = enable ? @"无法开启登录时启动" : @"无法关闭登录时启动";
        alert.informativeText = error.localizedDescription ?: @"请在系统的登录项设置中检查当前状态。";
        [alert runModal];
    } else if (enable && PetLoginItemStatus() == PetLoginNeedsApproval) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"登录时启动需要系统允许";
        alert.informativeText = @"请在“系统设置”的“登录项”中允许三色桌宠。";
        [alert addButtonWithTitle:@"打开登录项设置"];
        [alert addButtonWithTitle:@"稍后"];
        if ([alert runModal] == NSAlertFirstButtonReturn) PetOpenLoginItemSettings();
    }
    [self refreshLoginItem];
}

- (NSMenu *)makeMenu {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < roleIDs.count; i++) {
        NSMenuItem *item = [menu addItemWithTitle:roleNames[i] action:@selector(selectRole:) keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        [items addObject:item];
    }
    _roleItems = items;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenu *sizes = [[NSMenu alloc] initWithTitle:@"大小"];
    for (NSNumber *percent in scaleOptions) {
        NSString *title = [NSString stringWithFormat:@"%@%%", percent];
        NSMenuItem *choice = [sizes addItemWithTitle:title action:@selector(selectScale:) keyEquivalent:@""];
        choice.tag = percent.integerValue;
        choice.target = self;
    }
    _sizeItems = sizes.itemArray;
    [menu addItemWithTitle:@"大小" action:nil keyEquivalent:@""].submenu = sizes;
    _muteItem = [menu addItemWithTitle:@"静音" action:@selector(toggleMute:) keyEquivalent:@""];
    _muteItem.target = self;
    if (self.preview) {
        _controlsItem = [menu addItemWithTitle:@"显示顶部控件" action:@selector(togglePreviewControls:) keyEquivalent:@""];
        _controlsItem.target = self;
    } else {
        _keyboardStatus = [menu addItemWithTitle:@"正在检查键盘权限" action:nil keyEquivalent:@""];
        _keyboardStatus.enabled = NO;
        [menu addItemWithTitle:@"开启输入监控…" action:@selector(openInputSettings:) keyEquivalent:@""].target = self;
    }
    [menu addItem:NSMenuItem.separatorItem];
    _loginItem = [menu addItemWithTitle:@"登录时启动" action:@selector(toggleLoginItem:) keyEquivalent:@""];
    _loginItem.target = self;
    _loginSettings = [menu addItemWithTitle:@"打开登录项设置…" action:@selector(openLoginSettings:) keyEquivalent:@""];
    _loginSettings.target = self;
    [self refreshLoginItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"退出三色桌宠" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    [self updateMenu];
    return menu;
}

- (void)openInputSettings:(id)sender {
    CGRequestListenEventAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)stopListening {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    if (_tap) {
        CFMachPortInvalidate(_tap);
        CFRelease(_tap);
        _tap = NULL;
    }
}

- (void)checkKeyboard {
    BOOL allowed = CGPreflightListenEventAccess();
    if (!allowed && _tap) [self stopListening];
    if (allowed && !_tap) {
        _tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap,
                                kCGEventTapOptionListenOnly, CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|CGEventMaskBit(kCGEventFlagsChanged),
                                observeKey, (__bridge void *)self);
        if (_tap) {
            _source = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
            if (_source) CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
            else [self stopListening];
        }
    }
    if (_tap && !CGEventTapIsEnabled(_tap)) CGEventTapEnable(_tap, true);
    _keyboardStatus.title = !allowed ? @"键盘 · 尚未授权" : _tap ? @"键盘 · 已连接" : @"键盘 · 等待连接";
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:@"petScalePercent"];
    _scalePercent = [scaleOptions containsObject:@(saved)] ? saved : 100;
    BOOL controlsVisible = self.preview && [NSUserDefaults.standardUserDefaults boolForKey:@"showsPreviewControls"];
    NSRect rect = NSMakeRect(30, 60, frameWidth, frameHeight);
    NSWindowStyleMask style = self.preview ? NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           : NSWindowStyleMaskBorderless;
    _window = [[NSWindow alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _window.acceptsMouseMovedEvents = YES;
    self.pet = [[PetView alloc] initWithFrame:_window.contentView.bounds];
    self.pet.draggable = !self.preview;
    [_window.contentView addSubview:self.pet];
    if (self.preview) {
        _window.title = @"三色桌宠 · 动作预览";
        _roleControl = [NSSegmentedControl segmentedControlWithLabels:roleNames
            trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectRole:)];
        [_roleControl sizeToFit];
        _muteControl = [NSButton checkboxWithTitle:@"静音" target:self action:@selector(toggleMute:)];
        [_muteControl sizeToFit];
        _roleControl.selectedSegment = [roleIDs indexOfObject:self.pet.role];
        _roleControl.hidden = !controlsVisible;
        _muteControl.hidden = !controlsVisible;
        self.pet.toolTip = @"右键切换角色、静音或显示顶部控件";
        [_window.contentView addSubview:_roleControl];
        [_window.contentView addSubview:_muteControl];

    } else {
        _window.opaque = NO;
        _window.backgroundColor = NSColor.clearColor;
        _window.hasShadow = NO;
        _window.level = NSFloatingWindowLevel;
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        _statusItem.button.title = @"三色";
    }
    [self layoutPet];
    _window.delegate = self;
    if (self.preview) {
        [_window center];
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    } else {
        [_window orderFrontRegardless];
    }
    NSMenu *menu = [self makeMenu];
    self.pet.menu = menu;
    _statusItem.menu = menu;
    NSEventMask mouse = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
        NSEventMaskOtherMouseDragged | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
        NSEventMaskOtherMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp |
        NSEventMaskOtherMouseUp | NSEventMaskScrollWheel;
    __weak PetApplication *weakSelf = self;
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(self.preview ? mouse|NSEventMaskKeyDown|NSEventMaskKeyUp|NSEventMaskFlagsChanged : mouse)
        handler:^NSEvent *(NSEvent *e) {
            PetApplication *owner = weakSelf;
            if (e.type==NSEventTypeScrollWheel && e.momentumPhase!=NSEventPhaseNone) return e;
            if (owner && e.window == owner->_window) {
                if (e.type == NSEventTypeKeyDown) {
                    if (!(e.modifierFlags & NSEventModifierFlagCommand) && symbolForCode(e.keyCode)) {
                        [owner.pet pressKey:e.keyCode atTime:(NSInteger)(e.timestamp*1000)];
                        return nil;
                    }
                    [owner.pet notePhysicalActivity];
                } else if (e.type==NSEventTypeKeyUp || e.type==NSEventTypeFlagsChanged)
                    [owner.pet notePhysicalActivity];
                else [owner.pet mouseActivity:e.type];
            }
            return e;
        }];
    if (!self.preview) {
        _globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mouse
            handler:^(NSEvent *e) {
                if (e.type!=NSEventTypeScrollWheel || e.momentumPhase==NSEventPhaseNone)
                    [weakSelf.pet mouseActivity:e.type];
            }];
        [self checkKeyboard];
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            [weakSelf checkKeyboard];
        }];
        if (!CGPreflightListenEventAccess()) CGRequestListenEventAccess();
    }
    NSTimer *animation = [NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf.pet tick];
    }];
    [NSRunLoop.mainRunLoop addTimer:animation forMode:NSRunLoopCommonModes];
}

- (void)windowDidResignKey:(NSNotification *)notification { [self.pet cancelOperation:nil]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return self.preview; }

- (void)applicationWillTerminate:(NSNotification *)note {
    if (_localMonitor) [NSEvent removeMonitor:_localMonitor];
    if (_globalMonitor) [NSEvent removeMonitor:_globalMonitor];
    [self stopListening];
}
@end

static CGEventRef observeKey(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    PetApplication *app = (__bridge PetApplication *)context;
    if (type == kCGEventKeyDown)
        [app.pet pressKey:(unsigned int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)
                   atTime:(NSInteger)(CGEventGetTimestamp(event)/1000000)];
    else if (type==kCGEventKeyUp || type==kCGEventFlagsChanged) [app.pet notePhysicalActivity];
    else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput)
        [app checkKeyboard];
    return event;
}

static BOOL checkFastTyping(BOOL initiallyGripping) {
    // All possible 16ms display offsets must show contact for all three 60ms-spaced keys.
    for (NSInteger offset=0; offset<16; offset++) {
        PetHands hands;
        PetHandsInit(&hands);
        if (initiallyGripping) PetMove(&hands,0,800);
        BOOL saw[3] = {NO,NO,NO};
        for (NSInteger t=0; t<180; t++) {
            const int symbols[] = {'D','F','J'};
            int current = (int)(t/60);
            if (t%60 == 0) PetPress(&hands,symbols[current],1000+t);
            if (t%16 != offset) continue;
            NSString *expected = [NSString stringWithFormat:@"key%d-3",symbols[current]];
            if ([PetHandFrame(&hands,1000+t,t) isEqualToString:expected]) saw[current] = YES;
        }
        if (!saw[0] || !saw[1] || !saw[2]) return NO;
    }
    return YES;
}

static BOOL checkPaintedTiming(void) {
    PetInteraction s;
    PetInteractionInit(&s,0); s.hobby=PetRice; s.randomState=1234567;
    int previous=0, seen=0;
    for (int i=0;i<35;i++) {
        NSInteger start=i*100000;
        PetNoteActivity(&s,start);
        PetPickFace(&s,PetMoodAt(&s,start+1000,0,0),start+1000,YES);
        if (s.nextExpression<start+4000 || s.nextExpression>start+8000) return NO;
        NSInteger at=s.nextExpression;
        PetPaintedFace enter=PetPickFace(&s,PetMoodAt(&s,at,0,0),at,YES);
        PetPaintedFace full=PetPickFace(&s,PetMoodAt(&s,at+150,0,0),at+150,YES);
        if (enter.blend || full.blend!=64 || full.number<1 || full.number>5 || full.number==previous ||
            s.expressionEnds-at<1200 || s.expressionEnds-at>2000) return NO;
        previous=full.number;
        seen|=1<<full.number;
        PetPaintedFace ready=PetPickFace(&s,PetMoodAt(&s,start+46000,0,0),start+46000,NO);
        PetPaintedFace chew=PetPickFace(&s,PetMoodAt(&s,start+49500,0,0),start+49500,NO);
        PetPaintedFace ready2=PetPickFace(&s,PetMoodAt(&s,start+51500,0,0),start+51500,NO);
        PetPaintedFace chew2=PetPickFace(&s,PetMoodAt(&s,start+53500,0,0),start+53500,NO);
        if ((ready.number!=1 && ready.number!=5) || ready.number+ready2.number!=6 ||
            (chew.number!=4 && chew.number!=6) || chew.number+chew2.number!=10 ||
            PetPickFace(&s,PetMoodAt(&s,start+48800,0,0),start+48800,NO).blend) return NO;
    }
    return seen==62;
}

static BOOL checkMotion(void) {
    if (!checkFastTyping(NO) || !checkFastTyping(YES) || !checkPaintedTiming()) return NO;
    PetHands hands;
    PetHandsInit(&hands);
    PetPress(&hands,'J',1000);
    const NSInteger at[] = {0,17,18,41,42,99,100,149,150,219};
    for (int i=0; i<10; i++)
        if (![PetHandFrame(&hands,1000+at[i],at[i]) isEqualToString:
              [NSString stringWithFormat:@"key74-%d",1+i/2]]) return NO;
    PetPress(&hands,'J',1030);
    if (![PetHandFrame(&hands,1030,30) isEqualToString:@"key74-3"] ||
        ![PetHandFrame(&hands,1046,46) isEqualToString:@"key74-4"]) return NO;
    PetMove(&hands,3,1048);
    if (![PetHandFrame(&hands,1075,75) isEqualToString:@"wrist3"] ||
        ![PetHandFrame(&hands,1106,106) isEqualToString:@"wrist0"] ||
        ![PetHandFrame(&hands,1115,115) isEqualToString:@"mouse33"]) return NO;
    PetHands interrupted = hands;
    PetPress(&interrupted,'F',1080);
    if (![PetHandFrame(&interrupted,1080,80) isEqualToString:@"key70-3"]) return NO;
    PetPress(&hands,'J',1200);
    if (![PetHandFrame(&hands,1200,200) isEqualToString:@"wrist0"] ||
        ![PetHandFrame(&hands,1248,248) isEqualToString:@"key74-3"]) return NO;
    PetHandsInit(&hands);
    PetMove(&hands,2,2000);
    const int independentKeys[]={'D','F',32};
    for (int i=0;i<3;i++) {
        int symbol=independentKeys[i];
        NSInteger start=2200+20*i;
        PetPress(&hands,symbol,start);
        if (PetMouseLevel(&hands,start)!=3 ||
            ![PetHandFrame(&hands,start+44,0) isEqualToString:[NSString stringWithFormat:@"key%d-3",symbol]]) return NO;
    }
    PetPress(&hands,'J',2280);
    if (![PetHandFrame(&hands,2280,0) isEqualToString:@"wrist0"] ||
        ![PetHandFrame(&hands,2324,0) isEqualToString:@"key74-3"] || PetMouseLevel(&hands,2324)!=0 ||
        ![PetHandFrame(&hands,2495,0) hasPrefix:@"wrist"] || PetMouseLevel(&hands,2525)!=3) return NO;
    for (int symbol=1;symbol<=127;symbol++) {
        BOOL allowed=strchr("12345QWERTASDFGZXCVB ",symbol)!=NULL;
        if (PetOffHandKey(symbol)!=allowed) return NO;
    }
    PetInteraction interaction;
    PetInteractionInit(&interaction,1000);
    if (PetMoodAt(&interaction,57999,0,0).drowsy || !PetMoodAt(&interaction,58000,0,0).drowsy ||
        PetMoodAt(&interaction,59500,0,0).lids!=32 || PetMoodAt(&interaction,60999,0,0).sleeping ||
        !PetMoodAt(&interaction,61000,0,0).sleeping || PetMoodAt(&interaction,61700,0,0).lids!=128) return NO;
    PetNoteActivity(&interaction,62000);
    if (PetMoodAt(&interaction,62000,0,0).sleeping || PetMoodAt(&interaction,62000,0,0).lids!=128 || PetMoodAt(&interaction,62000,0,0).restRecovery!=256 ||
        PetMoodAt(&interaction,62150,0,0).restRecovery!=128 || PetMoodAt(&interaction,62300,0,0).restRecovery!=0 ||
        PetMoodAt(&interaction,62060,0,0).headX<.4 || PetMoodAt(&interaction,62180,0,0).lids!=0) return NO;
    PetNoteActivity(&interaction,62130);
    if (interaction.wakeAt!=62000) return NO;
    PetStartHold(&interaction,63000);
    PetMood hold=PetMoodAt(&interaction,63180,.9,0);
    if (hold.nuzzleWeight!=1 || hold.headX<.4 || hold.heart<0 || PetMoodAt(&interaction,130000,0,0).sleeping)
        return NO;
    PetNoteActivity(&interaction,130000);
    PetEndHold(&interaction,130000);
    if (fabs(PetMoodAt(&interaction,130110,0,0).nuzzleWeight-.5)>.001 ||
        PetMoodAt(&interaction,130220,0,0).nuzzleWeight!=0 || !inNuzzleArea(NSMakePoint(197,77))) return NO;
    PetPats pats;
    PetPatsInit(&pats);
    if (PetFace(&pats,1000,1000).level != 0 || PetFace(&pats,4750,4750).level != 64 ||
        PetFace(&pats,4790,4790).level != 128 || PetFace(&pats,4864,4864).level >= 64) return NO;
    PetPat(&pats,5000);
    if (PetFace(&pats,5060,5060).level != 64 || PetFace(&pats,5200,5200).level != 128 ||
        !PetFace(&pats,5240,5240).smiling) return NO;
    PetPat(&pats,5520);
    if (PetFace(&pats,5530,5530).level != 128 || pats.first != 5000) return NO;
    int fading = PetFace(&pats,6300,6300).level;
    PetPat(&pats,6300);
    if (PetFace(&pats,6300,6300).level != fading || PetFace(&pats,6380,6380).level != 128 ||
        PetFace(&pats,7200,7200).smiling || PetIrisGain(64)!=64 || PetIrisGain(128)!=0) return NO;
    PetInteractionInit(&interaction,0);
    interaction.hobby=PetRice;
    const NSInteger sample[]={44999,45000,47400,48550,49400,50500,51200,52250,53100,54500,55200,55950,56550};
    const int meals[]={0,1,2,3,4,3,2,3,4,3,2,1,0};
    for (size_t i=0;i<sizeof(meals)/sizeof(*meals);i++) {
        PetMood m=PetMoodAt(&interaction,sample[i],0,0);
        if (m.hobbyPose!=meals[i] || m.drowsy || m.lids || (m.hobbyPose && m.gazeGain)) return NO;
    }
    PetNoteActivity(&interaction,49000);
    if (PetMoodAt(&interaction,49000,0,0).hobbyPose || interaction.wakeAt==49000) return NO;
    if (!PetMoodAt(&interaction,106000,0,0).drowsy || PetMoodAt(&interaction,107500,0,0).lids!=32 ||
        !PetMoodAt(&interaction,109000,0,0).sleeping) return NO;
    PetNoteActivity(&interaction,110000);
    if (PetMoodAt(&interaction,110001,0,0).restRecovery) return NO;
    for (int h=0;h<2;h++) {
        PetInteractionInit(&interaction,0); interaction.hobby=h ? PetCloud : PetReading;
        const NSInteger times[]={44999,45000,47000,49000,51500,53000,55800,56550};
        const int reading[]={0,1,2,3,2,3,4,0};
        const int cloud[]={0,1,3,1,1,3,1,0};
        for (int i=0;i<8;i++) {
            PetMood at=PetMoodAt(&interaction,times[i],0,0);
            if (at.hobbyPose!=(h?cloud[i]:reading[i]) || at.drowsy) return NO;
            PetPaintedFace painted=PetPickFace(&interaction,at,times[i],NO);
            if (at.hobbyPose && (painted.number<1 || painted.number>3 || painted.blend!=64)) return NO;
        }
        PetNoteActivity(&interaction,51500);
        if (PetMoodAt(&interaction,51500,0,0).hobbyPose || interaction.wakeAt==51500) return NO;
    }
    PetInteractionInit(&interaction,0);interaction.hobby=PetCloud;
    PetMood launch=PetMoodAt(&interaction,46580,0,0), apex=PetMoodAt(&interaction,47225,0,0);
    PetMood caught=PetMoodAt(&interaction,47870,0,0);
    if (launch.hobbyPose!=2 || apex.hobbyPose!=3 || caught.hobbyPose!=4 ||
        launch.flight!=0 || fabs(apex.flight-.5)>.001 || caught.flight!=1 ||
        cloudCenter(apex).y>=MIN(cloudCenter(launch).y,cloudCenter(caught).y)-70) return NO;
    NSPoint prev=cloudPalm(1);
    for (NSInteger ms=46200;ms<49200;ms++) {
        PetMood m=PetMoodAt(&interaction,ms,0,0); NSPoint spot=cloudCenter(m);
        if (hypot(spot.x-prev.x,spot.y-prev.y)>.7) return NO;
        prev=spot;
    }
    if (!NSEqualPoints(cloudCenter(launch),cloudPalm(2)) ||
        !NSEqualPoints(cloudCenter(apex),NSMakePoint(469,105)) ||
        !NSEqualPoints(cloudCenter(caught),cloudPalm(4))) return NO;
    HeadStroke stroke = {0};
    return !sampleStroke(&stroke,NSMakePoint(140,60),1000) &&
           !sampleStroke(&stroke,NSMakePoint(150,60),1100) &&
           !sampleStroke(&stroke,NSMakePoint(157,60),1150) &&
           sampleStroke(&stroke,NSMakePoint(147,60),1230) &&
           hitsHead(NSMakePoint(150,77)) && hitsHead(NSMakePoint(193,77)) &&
           !hitsHead(NSMakePoint(194,77)) && !hitsHead(NSMakePoint(150,215));
}

static BOOL samePixels(CGImageRef a, CGImageRef b) {
    if (!a || !b || CGImageGetWidth(a) != CGImageGetWidth(b) || CGImageGetHeight(a) != CGImageGetHeight(b))
        return NO;
    NSData *left = PetRGBAData(a), *right = PetRGBAData(b);
    return left && [left isEqualToData:right];
}

static NSData *pixelsFromAtlas(PetFrameAtlas *atlas, NSString *name) {
    CGImageRef frame = [atlas copyImageForFrame:name];
    if (!frame) return nil;
    NSData *pixels = PetRGBAData(frame);
    CGImageRelease(frame);
    return pixels;
}

static BOOL checkPointerLayer(PetFrameAtlas *atlas) {
    NSData *idle=pixelsFromAtlas(atlas,@"idle0"), *desk=pixelsFromAtlas(atlas,@"deskFree");
    NSData *arm=pixelsFromAtlas(atlas,@"pointer");
    if (!idle || !desk || !arm) return NO;
    NSData *still=pointerOnDesk(idle,idle,desk,arm,0,0);
    NSData *moved=pointerOnDesk(idle,idle,desk,arm,96,64);
    if ([still isEqualToData:moved] || memcmp(still.bytes,moved.bytes,312*rasterWidth*4)) return NO;
    const uint8_t *pointer=arm.bytes, *result=moved.bytes;
    NSUInteger opaque=0;
    for (int y=399;y<530;y++) for (int x=13;x<314;x++) {
        const uint8_t *source=pointer+((y-8)*600+x-12)*4;
        if (source[3]==255) {
            if (memcmp(source,result+(y*600+x)*4,4)) return NO;
            opaque++;
        }
    }
    if (opaque<250) return NO;
    for (NSString *name in @[@"key68-3",@"key32-3"]) {
        NSData *patch=pixelsFromAtlas(atlas,name);
        if (patch.length!=600*250*4) return NO;
        NSMutableData *base=[idle mutableCopy];
        [base replaceBytesInRange:NSMakeRange(idle.length-patch.length,patch.length) withBytes:patch.bytes];
        NSData *both=pointerOnDesk(base,idle,desk,arm,96,64);
        for (int y=290;y<540;y++) {
            size_t offset=(y*600+314)*4;
            if (memcmp((const uint8_t *)base.bytes+offset,(const uint8_t *)both.bytes+offset,(600-314)*4)) return NO;
        }
        if ([both isEqualToData:base] || [both isEqualToData:moved]) return NO;
    }
    return YES;
}

static BOOL checkBlueMeal(PetFrameAtlas *atlas) {
    NSData *idle=pixelsFromAtlas(atlas,@"idle0");
    if (!idle) return NO;
    NSMutableSet *poses=[NSMutableSet setWithObject:idle];
    for (int i=1;i<=4;i++) {
        NSData *rest=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"rest%d",i]);
        NSData *rice=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"rice%d",i]);
        if (![idle isEqualToData:rest] || !rice || [poses containsObject:rice]) return NO;
        [poses addObject:rice];
    }
    NSData *rice=pixelsFromAtlas(atlas,@"rice2");
    NSMutableSet *paintings=[NSMutableSet set];
    for (int i=1;i<=6;i++) {
        NSData *mood=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"mood%d",i]);
        if (!mood) return NO;
        NSData *portrait=paintFace(idle,nil,mood,64,NO);
        if ([portrait isEqualToData:idle] || [paintings containsObject:portrait]) return NO;
        [paintings addObject:portrait];
        NSData *meal=paintFace(rice,idle,mood,64,YES);
        const uint8_t *src=rice.bytes,*neutral=idle.bytes,*art=mood.bytes,*dst=meal.bytes;
        for (int y=0;y<540;y++) for (int x=0;x<600;x++) {
            size_t offset=(600*y+x)*4;
            BOOL face=x>=230 && x<374 && y>=123 && y<243;
            const uint8_t *expected=face && !memcmp(src+offset,neutral+offset,4) ? art : src;
            if (memcmp(dst+offset,expected+offset,4)) return NO;
        }
    }
    return YES;
}

static BOOL checkBookOrCloud(PetFrameAtlas *atlas, BOOL reading) {
    NSData *idle=pixelsFromAtlas(atlas,@"idle0"), *pose=pixelsFromAtlas(atlas,reading ? @"book2" : @"toss3");
    if (!idle || !pose) return NO;
    NSMutableSet *faces=[NSMutableSet set];
    for (int i=1;i<=3;i++) {
        NSData *expression=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"mood%d",i]);
        if (!expression) return NO;
        NSData *portrait=paintFace(idle,nil,expression,64,NO);
        NSData *inScene=paintFace(pose,idle,expression,64,YES);
        if ([portrait isEqualToData:idle] || [faces containsObject:portrait] || [inScene isEqualToData:pose]) return NO;
        [faces addObject:portrait];
        const uint8_t *src=pose.bytes,*neutral=idle.bytes,*dst=inScene.bytes;
        for (int y=0;y<540;y++) for (int x=0;x<600;x++) {
            size_t off=(y*600+x)*4;
            if ((x<230 || x>=374 || y<123 || y>=243 || memcmp(src+off,neutral+off,4)) && memcmp(dst+off,src+off,4))
                return NO;
        }
    }
    if (!reading) {
        NSData *toy=pixelsFromAtlas(atlas,@"toy");
        NSRect bounds=alphaBounds(toy);
        if (NSIsEmptyRect(bounds) || fabs(NSMidX(bounds)-300)>2 || fabs(NSMidY(bounds)-270)>2) return NO;
        PetMood hold={.hobbyPose=1}, midair={.hobbyPose=3,.flight=.5};
        NSData *low=drawCloud(pose,toy,bounds,cloudCenter(hold));
        NSData *high=drawCloud(pose,toy,bounds,cloudCenter(midair));
        if ([low isEqualToData:pose] || [high isEqualToData:low]) return NO;
        NSData *desk=pixelsFromAtlas(atlas,@"tossDesk");
        for (NSNumber *from in @[@1,@4]) {
            int a=from.intValue,b=a==1 ? 2 : 1;
            NSData *armA=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"tossArm%d",a]);
            NSData *armB=pixelsFromAtlas(atlas,[NSString stringWithFormat:@"tossArm%d",b]);
            NSRect armRegion=NSUnionRect(alphaBounds(armA),alphaBounds(armB));
            if (!desk || NSIsEmptyRect(armRegion)) return NO;
            for (int step=0;step<=256;step+=32) {
                PetMood motion={.hobbyPose=1,.armFrom=a,.armTo=b,.armBlend=step};
                NSData *lift=cloudArmsOnDesk(desk,armA,armB,armRegion,motion);
                NSPoint hand=cloudCenter(motion); int contactPixels=0;
                for (int y=(int)hand.y+10;y<(int)hand.y+43;y++)
                    for (int x=(int)hand.x-24;x<(int)hand.x+24;x++) {
                        size_t off=(y*600+x)*4;
                        if (memcmp((const uint8_t *)lift.bytes+off,(const uint8_t *)desk.bytes+off,4)) contactPixels++;
                    }
                if (contactPixels<40) return NO;
            }
        }
    }
    return YES;
}

static BOOL checkRestRecovery(PetFrameAtlas *atlas) {
    NSData *idle=pixelsFromAtlas(atlas,@"idle0"), *rest3=pixelsFromAtlas(atlas,@"rest3");
    NSData *rest4=pixelsFromAtlas(atlas,@"rest4"), *patch=pixelsFromAtlas(atlas,@"key68-3");
    if (!idle || !rest3 || !rest4 || patch.length!=600*250*4 || [idle isEqualToData:rest4]) return NO;
    if (![recoverAccessories(idle,idle,rest3,rest4,64) isEqualToData:rest4]) return NO;
    NSMutableData *contact=[idle mutableCopy];
    [contact replaceBytesInRange:NSMakeRange(idle.length-patch.length,patch.length) withBytes:patch.bytes];
    NSData *opening=recoverAccessories(contact,idle,rest3,rest4,32);
    const uint8_t *p=opening.bytes, *hands=contact.bytes, *neutral=idle.bytes, *a=rest3.bytes,*b=rest4.bytes;
    for (int y=0;y<540;y++) for (int x=0;x<600;x++) {
        size_t off=(y*600+x)*4;
        BOOL accessory=x>=426 && y>=300 && y<430 && !memcmp(neutral+off,hands+off,4);
        for (int k=0;k<4;k++) {
            int wanted=accessory ? (a[off+k]+b[off+k]+1)/2 : hands[off+k];
            if (p[off+k]!=wanted) return NO;
        }
    }
    return YES;
}

static BOOL checkExpressionLayers(PetFrameAtlas *atlas) {
    NSData *half = pixelsFromAtlas(atlas,@"smileHalf"), *full = pixelsFromAtlas(atlas,@"smile0");
    NSData *heart = pixelsFromAtlas(atlas,@"smile3");
    if (!half || !full || !heart) return NO;
    for (NSString *name in @[@"mouse30",@"wrist2",@"key68-3"]) @autoreleasepool {
        NSData *base = pixelsFromAtlas(atlas,name);
        if ([name hasPrefix:@"key"]) {
            NSMutableData *combined = [pixelsFromAtlas(atlas,@"idle0") mutableCopy];
            if (base.length != rasterWidth*keyPatchHeight*4 || !combined) return NO;
            [combined replaceBytesInRange:NSMakeRange(combined.length-base.length,base.length)
                                withBytes:base.bytes];
            base = combined;
        }
        if (base.length != rasterWidth*rasterHeight*4) return NO;
        for (NSNumber *amount in @[@32,@64,@128]) {
            int level = amount.intValue;
            NSData *output = faceOnHands(base,half,full,heart,(PetExpression){level,3,YES});
            if (output.length != base.length || [output isEqualToData:base]) return NO;
            const uint8_t *a = base.bytes, *b = half.bytes, *c = full.bytes, *h = heart.bytes, *out = output.bytes;
            for (size_t y=0; y<rasterHeight; y++) for (size_t x=0; x<rasterWidth; x++) {
                for (size_t k=(y*rasterWidth+x)*4, stop=k+4; k<stop; k++) {
                    int expected = a[k];
                    if (y>=108 && y<254 && x>=208 && x<389)
                        expected = level==128 ? c[k] : level==64 ? b[k] : (a[k]+b[k]+1)/2;
                    else if (y>=39 && y<162 && x>=420 && x<496) expected = h[k];
                    if (out[k]!=expected) return NO;
                }
            }
        }
    }
    return YES;
}

static BOOL checkRole(PetFrameAtlas *atlas, NSString *role, NSSet<NSString *> *frames, NSURL *references) {
    if (atlas.frameCount != frames.count) return NO;
    NSURL *directory = [references URLByAppendingPathComponent:role isDirectory:YES];
    CGImageRef idle = [atlas copyImageForFrame:@"idle0"];
    CGImageRef originalIdle = directory ? copyFrameImage([directory URLByAppendingPathComponent:@"idle0.png"]) : NULL;
    BOOL valid = YES;
    for (NSString *frame in frames) @autoreleasepool {
        BOOL key = [frame hasPrefix:@"key"];
        size_t expectedHeight = key ? keyPatchHeight : rasterHeight;
        CGImageRef image = [atlas copyImageForFrame:frame];
        valid = image && CGImageGetWidth(image) == rasterWidth && CGImageGetHeight(image) == expectedHeight;
        CGImageRef original = NULL;
        if (valid && directory) {
            NSURL *file = [directory URLByAppendingPathComponent:[frame stringByAppendingPathExtension:@"png"]];
            original = copyFrameImage(file);
            valid = samePixels(original, image);
        }
        if (valid && key && (directory || [frame isEqualToString:@"key65-3"])) {
            CGImageRef combined = copyPatchedFrame(idle, image);
            valid = combined && CGImageGetHeight(combined) == rasterHeight;
            if (valid && directory) {
                CGImageRef baseline = copyPatchedFrame(originalIdle, original);
                valid = samePixels(baseline, combined);
                if (baseline) CGImageRelease(baseline);
            }
            if (combined) CGImageRelease(combined);
        }
        if (original) CGImageRelease(original);
        if (image) CGImageRelease(image);
        if (!valid) {
            fprintf(stderr, "动作帧检查失败：%s/%s\n", role.UTF8String, frame.UTF8String);
            break;
        }
    }
    if (originalIdle) CGImageRelease(originalIdle);
    if (idle) CGImageRelease(idle);
    return valid;
}

static BOOL checkGaze(PetFrameAtlas *atlas, NSString *role) {
    NSRect translated = NSMakeRect(-1800,730,600,540);
    NSPoint center = logicalCursorInScreenRect(NSMakePoint(-1500,1116), translated);
    if (!NSEqualPoints(center, NSMakePoint(150,77)) ||
        !NSEqualPoints(logicalCursorInScreenRect(NSMakePoint(-1960,1330), translated), NSMakePoint(-80,-30)))
        return NO;
    NSPoint zero = gazeTarget(center);
    NSPoint edge = gazeTarget(NSMakePoint(-10000,10000));
    NSPoint head = advanceGaze(zero, edge, .065, .135), eyes = advanceGaze(zero, edge, .065, .065);
    if (!NSEqualPoints(zero, NSZeroPoint) || edge.x > -.99 || edge.y < .99 ||
        !(eyes.x < head.x && eyes.y > head.y && fabs(eyes.y-.63212) < .0001)) return NO;
    PetGazeMap *map = gazeMapForRole(role);
    CGImageRef idle = [atlas copyImageForFrame:@"idle0"];
    if (!map || !idle) { if (idle) CGImageRelease(idle); return NO; }
    NSData *baseline = PetRGBAData(idle);
    CGImageRelease(idle);
    NSData *neutral = [map pixelsForSource:baseline pose:(PetGazePose){0} openEyes:YES];
    NSData *headOnly = [map pixelsForSource:baseline pose:(PetGazePose){64,-64,0,0} openEyes:YES];
    NSData *eyeOnly = [map pixelsForSource:baseline pose:(PetGazePose){0,0,64,-64} openEyes:YES];
    NSData *both = [map pixelsForSource:baseline pose:(PetGazePose){64,-64,64,-64} openEyes:YES];
    NSData *closed = [map pixelsForSource:baseline pose:(PetGazePose){64,-64,64,-64} openEyes:NO];
    if (!baseline || !both || ![baseline isEqualToData:neutral] || [baseline isEqualToData:headOnly] ||
        [baseline isEqualToData:eyeOnly] || [headOnly isEqualToData:both] || ![closed isEqualToData:headOnly])
        return NO;
    size_t start = (rasterHeight-keyPatchHeight)*rasterWidth*4;
    return !memcmp((const uint8_t *)baseline.bytes+start, (const uint8_t *)both.bytes+start, baseline.length-start);
}

static int checkBundle(NSURL *references) {
    NSMutableSet<NSString *> *frames = [NSMutableSet set];
    for (int i = 0; i < 8; i++) [frames addObject:[NSString stringWithFormat:@"idle%d", i]];
    for (int i = 0; i < 6; i++) [frames addObject:[NSString stringWithFormat:@"smile%d", i]];
    for (int i = 0; i < 4; i++) [frames addObject:[NSString stringWithFormat:@"wrist%d", i]];
    [frames addObjectsFromArray:@[@"blinkHalf",@"smileHalf",@"deskFree",@"pointer",@"rest1",@"rest2",@"rest3",@"rest4"]];
    for (int level = 1; level <= 3; level++)
        for (int q = 0; q < 4; q++) [frames addObject:[NSString stringWithFormat:@"mouse%d%d", level, q]];
    for (unsigned int code = 0; code < sizeof(keySymbols) / sizeof(*keySymbols); code++) {
        int sym = symbolForCode(code);
        if (sym) for (int depth = 1; depth <= 5; depth++)
            [frames addObject:[NSString stringWithFormat:@"key%d-%d", sym, depth]];
    }
    if (frames.count != 278 || symbolForCode(1) != 'S' || symbolForCode(47) != 1046 ||
        symbolForCode(51) != 8 || symbolForCode(117) != 127 || symbolForCode(65535) != 0 ||
        !checkMotion()) {
        fprintf(stderr, "输入映射或动作时序检查失败\n");
        return 1;
    }
    for (NSString *role in roleIDs) @autoreleasepool {
        PetFrameAtlas *atlas = atlasForRole(role);
        NSMutableSet *expected=[frames mutableCopy];
        BOOL blue=[role isEqualToString:@"blue"];
        [expected addObjectsFromArray:@[@"mood1",@"mood2",@"mood3"]];
        if (blue) [expected addObjectsFromArray:@[@"rice1",@"rice2",@"rice3",@"rice4",@"mood4",@"mood5",@"mood6"]];
        else if ([role isEqualToString:@"amber"]) [expected addObjectsFromArray:@[@"book1",@"book2",@"book3",@"book4"]];
        else [expected addObjectsFromArray:@[@"toss1",@"toss2",@"toss3",@"toss4",@"toy",
            @"tossDesk",@"tossArm1",@"tossArm2",@"tossArm4"]];
        if (!checkRole(atlas, role, expected, references)) {
            fprintf(stderr, "角色图集无效：%s\n", role.UTF8String);
            return 1;
        }
        BOOL scenes=blue ? checkBlueMeal(atlas) :
            checkRestRecovery(atlas) && checkBookOrCloud(atlas,[role isEqualToString:@"amber"]);
        if (!scenes || !checkPointerLayer(atlas) ||
            !checkExpressionLayers(atlas) || !checkGaze(atlas, role)) {
            fprintf(stderr, "表情分层、视线位移图或合成检查失败：%s\n", role.UTF8String);
            return 1;
        }
        printf("%s · %d 帧 600×540 · 240 个按键补丁 600×250\n",role.UTF8String,(int)expected.count-240);
    }
    if (references) puts("863 个还原帧和 720 个合成按键帧与原 PNG 的预乘 sRGB RGBA 逐像素一致");
    for (int i = 0; i < 3; i++) {
        NSURL *url = soundURL(i);
        if (!url || ![[NSSound alloc] initWithContentsOfURL:url byReference:NO]) return 1;
    }
    puts("双手与桌鼠、连续触底、抬腕、睡醒、长按轻蹭、表情、头眼视线与 3 个音效检查通过");
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        scaleOptions = @[@50, @75, @100, @125, @150, @200];
        roleIDs = @[@"blue", @"amber", @"frost"];
        roleNames = @[@"DeepSeek", @"Claude", @"Codex"];
        if (argc >= 2 && !strcmp(argv[1], "--check")) {
            if (argc > 3) return 2;
            NSURL *references = argc == 3 ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES] : nil;
            return checkBundle(references);
        }
        NSApplication *app = NSApplication.sharedApplication;
        __attribute__((objc_precise_lifetime)) PetApplication *delegate = [PetApplication new];
        delegate.preview = argc >= 2 && !strcmp(argv[1], "--preview");
        [app setActivationPolicy:delegate.preview ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
