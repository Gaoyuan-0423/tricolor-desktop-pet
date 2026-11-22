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

static PetFrameAtlas *atlasForRole(NSString *role) {
    NSURL *directory = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:role isDirectory:YES];
    return [[PetFrameAtlas alloc] initWithDirectory:directory];
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
- (void)tick;
@end

@implementation PetView {
    NSCache<NSString *, NSData *> *_framePixels;
    NSString *_shownFrame;
    NSImage *_currentImage;
    CGImageRef _idleReference;
    PetFrameAtlas *_atlas;
    PetGazeMap *_gazeMap;
    PetGazePose _pose;
    NSData *_neutralPixels;
    NSArray<NSSound *> *_sounds;
    NSInteger _started, _lastGazeSample;
    NSTimer *_contactTimer;
    PetHands _hands;
    PetPats _pats;
    PetExpression _shownExpression;
    NSPoint _eyeDirection, _headDirection;
    NSPoint _downPoint, _windowAtPress;
    BOOL _pressed, _canPat, _dragged;
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
        PetHandsInit(&_hands);
        PetPatsInit(&_pats);
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"selectedRole"];
        _role = [roleIDs containsObject:saved ?: @""] ? saved : roleIDs.firstObject;
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
    _shownFrame = nil;
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
    PetPat(&_pats,milliseconds());
    _stroke.active = NO;
    [self tick];
}

- (void)mouseDown:(NSEvent *)event {
    _downPoint = [self.window convertPointToScreen:event.locationInWindow];
    _windowAtPress = self.window.frame.origin;
    _pressed = YES;
    _dragged = NO;
    _stroke.active = NO;
    _canPat = hitsHead([self logicalPointAtScreenPoint:_downPoint]);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pressed) return;
    NSPoint screen = [self.window convertPointToScreen:event.locationInWindow];
    CGFloat dx = screen.x - _downPoint.x, dy = screen.y - _downPoint.y;
    if (hypot(dx, dy) >= 3) _dragged = YES;
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
    BOOL tap = _pressed && _canPat && !_dragged && hypot(screen.x-_downPoint.x, screen.y-_downPoint.y) < 3;
    _pressed = NO;
    if (tap && hitsHead([self logicalPointAtScreenPoint:screen])) [self smile];
}

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
    int symbol = symbolForCode(code);
    if (!symbol) return;
    NSInteger now = milliseconds();
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
    NSPoint point = [self logicalPointAtScreenPoint:p];
    if (eventType == NSEventTypeMouseMoved && !NSEvent.pressedMouseButtons && hitsHead(point)) {
        if (sampleStroke(&_stroke, point, now)) [self smile];
    } else {
        _stroke.active = NO;
    }
    PetMove(&_hands,quadrant,now);
    [self tick];
}

- (BOOL)trackCursor:(NSInteger)now {
    if (!self.window || NSIsEmptyRect(self.bounds)) return NO;
    NSTimeInterval dt = _lastGazeSample ? MIN((now-_lastGazeSample)/1000.0, .12) : 1.0/60;
    _lastGazeSample = now;
    NSPoint target = gazeTarget([self logicalPointAtScreenPoint:NSEvent.mouseLocation]);
    _eyeDirection = advanceGaze(_eyeDirection, target, dt, .065);
    _headDirection = advanceGaze(_headDirection, target, dt, .135);
    PetGazePose next = {(int)lround(_headDirection.x*64), (int)lround(_headDirection.y*64),
                        (int)lround(_eyeDirection.x*64), (int)lround(_eyeDirection.y*64)};
    if (next.headX == _pose.headX && next.headY == _pose.headY &&
        next.eyeX == _pose.eyeX && next.eyeY == _pose.eyeY) return NO;
    _pose = next;
    return YES;
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
    NSInteger now = milliseconds(), elapsed = now-_started;
    PetGazePose previous = _pose;
    BOOL gazeChanged = [self trackCursor:now];
    NSString *frame = PetHandFrame(&_hands,now,elapsed);
    PetExpression face = PetFace(&_pats,now,elapsed);
    BOOL expressionChanged = face.level != _shownExpression.level || face.heart != _shownExpression.heart ||
                             face.smiling != _shownExpression.smiling;
    if (![_shownFrame isEqualToString:frame] || expressionChanged) {
        NSData *hands = [self pixelsForFrame:frame];
        NSData *half = face.level ? [self pixelsForFrame:face.smiling ? @"smileHalf" : @"blinkHalf"] : nil;
        NSData *full = face.level ? [self pixelsForFrame:face.smiling ? @"smile0" : @"idle7"] : nil;
        NSData *hearts = face.heart < 0 ? nil : [self pixelsForFrame:[NSString stringWithFormat:@"smile%d",face.heart]];
        _neutralPixels = faceOnHands(hands,half,full,hearts,face);
        _shownFrame = frame;
        _shownExpression = face;
    } else if (!gazeChanged || (face.level == 128 && previous.headX == _pose.headX && previous.headY == _pose.headY)) {
        return;
    }
    PetGazePose effective = _pose;
    int iris = PetIrisGain(face.level);
    effective.eyeX = (int)lround(effective.eyeX*iris/192.0);
    effective.eyeY = (int)lround(effective.eyeY*iris/192.0);
    NSData *pixels = [_gazeMap pixelsForSource:_neutralPixels pose:effective openEyes:iris>0];
    CGImageRef image = PetImageFromRGBA(pixels, rasterWidth, rasterHeight);
    _currentImage = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(frameWidth, frameHeight)] : nil;
    _currentImage.cacheMode = NSImageCacheNever;
    if (image) CGImageRelease(image);
    [self setNeedsDisplay:YES];
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
                                kCGEventTapOptionListenOnly, CGEventMaskBit(kCGEventKeyDown),
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
    NSEventMask mouse = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseDown;
    __weak PetApplication *weakSelf = self;
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(self.preview ? mouse|NSEventMaskKeyDown : mouse)
        handler:^NSEvent *(NSEvent *e) {
            PetApplication *owner = weakSelf;
            if (owner && e.window == owner->_window) {
                if (e.type == NSEventTypeKeyDown) {
                    if (!(e.modifierFlags & NSEventModifierFlagCommand) && symbolForCode(e.keyCode)) {
                        [owner.pet pressKey:e.keyCode atTime:(NSInteger)(e.timestamp*1000)];
                        return nil;
                    }
                } else [owner.pet mouseActivity:e.type];
            }
            return e;
        }];
    if (!self.preview) {
        _globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mouse
            handler:^(NSEvent *e) { [weakSelf.pet mouseActivity:e.type]; }];
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

static BOOL checkMotion(void) {
    if (!checkFastTyping(NO) || !checkFastTyping(YES)) return NO;
    PetHands hands;
    PetHandsInit(&hands);
    PetPress(&hands,'D',1000);
    const NSInteger at[] = {0,17,18,41,42,99,100,149,150,219};
    for (int i=0; i<10; i++)
        if (![PetHandFrame(&hands,1000+at[i],at[i]) isEqualToString:
              [NSString stringWithFormat:@"key68-%d",1+i/2]]) return NO;
    PetPress(&hands,'D',1030);
    if (![PetHandFrame(&hands,1030,30) isEqualToString:@"key68-3"] ||
        ![PetHandFrame(&hands,1046,46) isEqualToString:@"key68-4"]) return NO;
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
    [frames addObjectsFromArray:@[@"blinkHalf",@"smileHalf"]];
    for (int level = 1; level <= 3; level++)
        for (int q = 0; q < 4; q++) [frames addObject:[NSString stringWithFormat:@"mouse%d%d", level, q]];
    for (unsigned int code = 0; code < sizeof(keySymbols) / sizeof(*keySymbols); code++) {
        int sym = symbolForCode(code);
        if (sym) for (int depth = 1; depth <= 5; depth++)
            [frames addObject:[NSString stringWithFormat:@"key%d-%d", sym, depth]];
    }
    if (frames.count != 272 || symbolForCode(1) != 'S' || symbolForCode(47) != 1046 ||
        symbolForCode(51) != 8 || symbolForCode(117) != 127 || symbolForCode(65535) != 0 ||
        !checkMotion()) {
        fprintf(stderr, "输入映射或动作时序检查失败\n");
        return 1;
    }
    for (NSString *role in roleIDs) @autoreleasepool {
        PetFrameAtlas *atlas = atlasForRole(role);
        if (!checkRole(atlas, role, frames, references)) {
            fprintf(stderr, "角色图集无效：%s\n", role.UTF8String);
            return 1;
        }
        if (!checkExpressionLayers(atlas) || !checkGaze(atlas, role)) {
            fprintf(stderr, "表情分层、视线位移图或合成检查失败：%s\n", role.UTF8String);
            return 1;
        }
        printf("%s · 32 帧 600×540 · 240 个按键补丁 600×250\n", role.UTF8String);
    }
    if (references) puts("816 个还原帧和 720 个合成按键帧与原 PNG 的预乘 sRGB RGBA 逐像素一致");
    for (int i = 0; i < 3; i++) {
        NSURL *url = soundURL(i);
        if (!url || ![[NSSound alloc] initWithContentsOfURL:url byReference:NO]) return 1;
    }
    puts("键位、连续触底、抬腕、独立表情、头眼视线与 3 个音效检查通过");
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
