#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#import "Affection.h"

// The six cells are read left-to-right: neutral, blink, left/right typing, left/right gaze.
enum Pose { Idle, Blink, TypeLeft, TypeRight, LookLeft, LookRight, PoseCount };
typedef struct { unsigned shell, rim, keys, accent, ink, shadow; } Palette;
static const CGFloat W = 300, H = 270;
static NSString *const keyRows[] = {@"1234567890-=", @"QWERTYUIOP[]", @"ASDFGHJKL;'", @"ZXCVBNM,./"};
static void fail(NSString *message) {
    fprintf(stderr,"%s\n",message.UTF8String);
    exit(1);
}
static NSColor *color(unsigned rgb) {
    return [NSColor colorWithSRGBRed:(rgb >> 16)/255. green:((rgb >> 8) & 255)/255. blue:(rgb & 255)/255. alpha:1];
}
static NSRect box(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return NSMakeRect(x,H-y-h,w,h); }
static void roundBox(NSRect b, CGFloat radius, unsigned rgb) {
    [color(rgb) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:radius yRadius:radius] fill];
}
static void centered(NSString *s, NSRect b, CGFloat size, unsigned ink) {
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName:color(ink)};
    NSSize z=[s sizeWithAttributes:attrs];
    [s drawAtPoint:NSMakePoint(NSMidX(b)-z.width/2,NSMidY(b)-z.height/2) withAttributes:attrs];
}
static void keycap(NSRect b, NSString *legend, BOOL active, Palette p, CGFloat pressure) {
    roundBox(NSOffsetRect(b,0,-1.8), 2, active?p.accent:p.rim);
    if (active) b.origin.y-=1.7*pressure;
    roundBox(b,2,active?p.accent:p.keys);
    if (legend.length) {
        // Key legends are read by the seated character, across the desk from the viewer.
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *turn=[NSAffineTransform transform];
        [turn translateXBy:NSMidX(b) yBy:NSMidY(b)];
        [turn rotateByDegrees:180];
        [turn concat];
        centered(legend,NSMakeRect(-b.size.width/2,-b.size.height/2,b.size.width,b.size.height),
                 5.8, active?0xffffff:p.ink);
        [NSGraphicsContext restoreGraphicsState];
    }
}
static int symbolFor(unichar c) { return c=='.'?1046:c; }
static NSString *symbolLabel(int code) {
    if (code==8) return @"⌫";
    if (code==127) return @"⌦";
    if (code==32) return @"␣";
    return [NSString stringWithFormat:@"%C",(unichar)(code==1046?'.':code)];
}
static NSPoint at(CGFloat x,CGFloat y) { return NSMakePoint(x,H-y); }

// Coordinates are in the sitter's keyboard layout. Columns increase from the
// character's left and depth increases toward the distant number row.
static NSRect keyRect(CGFloat column,CGFloat units,int depth) {
    CGFloat deckWidth=191+4.1*depth, pitch=deckWidth/15;
    CGFloat right=169+deckWidth/2;
    return box(right-(column+units)*pitch,207+depth*(8.6+.23*depth),
               units*pitch-1.35,6.2+.48*depth);
}
static void keyDeck(CGFloat dy,unsigned rgb) {
    NSBezierPath *path=[NSBezierPath bezierPath];
    [path moveToPoint:at(75,203+dy)];
    [path lineToPoint:at(263,203+dy)];
    [path curveToPoint:at(269,207+dy) controlPoint1:at(266,203+dy) controlPoint2:at(268,205+dy)];
    [path lineToPoint:at(280,253+dy)];
    [path curveToPoint:at(274,259+dy) controlPoint1:at(281,257+dy) controlPoint2:at(279,259+dy)];
    [path lineToPoint:at(64,259+dy)];
    [path curveToPoint:at(58,253+dy) controlPoint1:at(59,259+dy) controlPoint2:at(57,257+dy)];
    [path lineToPoint:at(69,207+dy)];
    [path curveToPoint:at(75,203+dy) controlPoint1:at(70,205+dy) controlPoint2:at(72,203+dy)];
    [path closePath];
    [color(rgb) setFill]; [path fill];
}
static const CGFloat mouseX=61.5, mouseY=215, mouseAngle=-39;
// Convert a point on the shell to a top-origin character coordinate.
static NSPoint mouseButtonPoint(void) {
    CGFloat a=mouseAngle*M_PI/180, x=1.3, y=-9.6;
    return NSMakePoint(mouseX+x*cos(a)-y*sin(a),mouseY-x*sin(a)-y*cos(a));
}
static void drawMouse(Palette p,BOOL active) {
    // The rounded palm rest lies under the sitter's right palm (screen left).
    // The divided buttons and wheel are at the far end, toward the viewer.
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t=[NSAffineTransform transform];
    [t translateXBy:mouseX yBy:H-mouseY];
    [t rotateByDegrees:mouseAngle];
    [t concat];
    NSRect shell=NSMakeRect(-9,-15,18,30);
    roundBox(NSOffsetRect(shell,0,-1.35),6.3,p.shadow);
    roundBox(shell,6.3,p.rim);
    roundBox(NSInsetRect(shell,.85,.85),5.5,p.shell);
    NSBezierPath *split=[NSBezierPath bezierPath];
    [split moveToPoint:NSMakePoint(-7.9,0)];
    [split curveToPoint:NSMakePoint(7.9,0) controlPoint1:NSMakePoint(-3.5,-2.2) controlPoint2:NSMakePoint(3.5,-2.2)];
    [split moveToPoint:NSMakePoint(0,-1.65)]; [split lineToPoint:NSMakePoint(0,-14.1)];
    split.lineWidth=.75; [color(p.rim) setStroke]; [split stroke];
    roundBox(NSMakeRect(-1.45,-9.75,2.9,5.9),1.4,active?p.accent:p.ink);
    [NSGraphicsContext restoreGraphicsState];
}
static void keyboard(Palette p,int code,NSInteger side,CGFloat pressure) {
    keyDeck(4,p.shadow);
    keyDeck(1.8,p.rim);
    keyDeck(0,p.shell);
    const CGFloat starts[]={1.05,1.45,1.8,2.3};
    for (int r=0;r<4;r++) {
        int depth=4-r;
        for (NSUInteger k=0;k<keyRows[r].length;k++) {
            unichar c=[keyRows[r] characterAtIndex:k];
            keycap(keyRect(starts[r]+k,1,depth),[NSString stringWithFormat:@"%C",c],code==symbolFor(c),p,pressure);
        }
    }
    keycap(keyRect(0,1,4),@"`",NO,p,pressure);
    keycap(keyRect(13.1,1.9,4),@"⌫",code==8 || code==127,p,pressure);
    keycap(keyRect(0,1.4,3),@"⇥",NO,p,pressure);    keycap(keyRect(13.5,1.5,3),@"",NO,p,pressure);
    keycap(keyRect(0,1.75,2),@"⇪",NO,p,pressure);   keycap(keyRect(12.9,2.1,2),@"↵",NO,p,pressure);
    keycap(keyRect(0,2.25,1),@"⇧",NO,p,pressure);   keycap(keyRect(12.4,2.6,1),@"⇧",NO,p,pressure);
    keycap(keyRect(3.8,6.4,0),@"",code==32,p,pressure);
    for (int i=0;i<3;i++) keycap(keyRect(i*1.25,1.2,0),@"",NO,p,pressure);
    for (int i=0;i<4;i++) keycap(keyRect(10.25+i*1.19,1.14,0),@"",NO,p,pressure);
}
static void badge(Palette p,int code,NSInteger side,CGFloat pressure) {
    if (code>=0) {
        NSRect tag=box(side?238:34,178-pressure*3,27,19);
        roundBox(NSOffsetRect(tag,0,-1.5),6,p.shadow);
        roundBox(tag,6,p.accent);
        centered(symbolLabel(code),tag,12,0xffffff);
    }
}
static NSBitmapImageRep *bitmap(int w,int h) {
    return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
}
static void begin(NSBitmapImageRep *b) {
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:b];
    NSGraphicsContext.currentContext.imageInterpolation=NSImageInterpolationHigh;
}
static void writeBitmap(NSBitmapImageRep *bitmap, NSURL *url) {
    NSError *e=nil;
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png || ![png writeToURL:url options:NSDataWritingAtomic error:&e]) fail(e.localizedDescription ?: url.path);
}
static NSRect trim(NSBitmapImageRep *b, NSRect cell) {
    // Input/output in top-origin pixel coordinates. Ignore very faint antialias speckles.
    size_t left=NSMaxX(cell),top=NSMaxY(cell),right=0,bottom=0;
    for (int y=cell.origin.y;y<NSMaxY(cell);y++) {
        unsigned char *row=b.bitmapData+y*b.bytesPerRow;
        for (int x=cell.origin.x;x<NSMaxX(cell);x++) {
            if (row[4*x+3]<24) continue;
            left=MIN(left,(size_t)x); right=MAX(right,(size_t)x+1);
            top=MIN(top,(size_t)y); bottom=MAX(bottom,(size_t)y+1);
        }
    }
    if (right<=left || bottom<=top) fail(@"素材表中有空动作格");
    return NSMakeRect(left,top,right-left,bottom-top);
}
// Texture and landmarks use the original sheet's top-left pixel coordinates.
@interface PoseTexture : NSObject
@property(nonatomic,strong) NSBitmapImageRep *pixels;
@property(nonatomic,strong) NSBitmapImageRep *hands, *neutralFrame;
@property(nonatomic) NSRect bounds;
@property(nonatomic,copy) NSArray<PoseTexture *> *plates, *arms;
@property(nonatomic,strong) PoseTexture *mouseArm;
@property(nonatomic,copy) NSDictionary *rig;
@end
@implementation PoseTexture
@end

static NSPoint pointFrom(NSArray *numbers) {
    if (numbers.count!=2) fail(@"手部锚点缺失");
    return NSMakePoint([numbers[0] doubleValue],[numbers[1] doubleValue]);
}
static void fillOutline(NSArray *polygon,CGFloat h) {
    if (!polygon.count) return;
    NSBezierPath *path=[NSBezierPath bezierPath];
    for (NSUInteger i=0;i<polygon.count;i++) {
        NSPoint p=pointFrom(polygon[i]); p.y=h-p.y;
        if (i==0) [path moveToPoint:p]; else [path lineToPoint:p];
    }
    [path closePath]; [path fill];
}
// Low-strength sharpening of opaque ink and colour details in the source,
// before any scale or warping. Exclude alpha boundaries to avoid bright halos.
static void sharpenLinework(NSBitmapImageRep *b) {
    NSInteger stride=b.bytesPerRow, w=b.pixelsWide, h=b.pixelsHigh;
    NSData *copy=[NSData dataWithBytes:b.bitmapData length:stride*h];
    const uint8_t *src=copy.bytes;
    for (NSInteger y=1;y<h-1;y++) for (NSInteger x=1;x<w-1;x++) {
        NSInteger i=y*stride+4*x;
        if (src[i+3]<248 || src[i+7]<248 || src[i-1]<248 ||
            src[i-stride+3]<248 || src[i+stride+3]<248) continue;
        for (int c=0;c<3;c++) {
            NSInteger k=i+c;
            float detail=src[k]-.25f*(src[k-4]+src[k+4]+src[k-stride]+src[k+stride]);
            b.bitmapData[k]=lrintf(fmaxf(0,fminf(255,src[k]+fmaxf(-9,fminf(9,detail*.42f)))));
        }
    }
}
static PoseTexture *texture(CGImageRef sheet,NSRect cell,NSDictionary *rig,BOOL sharpen) {
    int w=cell.size.width,h=cell.size.height;
    PoseTexture *pose=[PoseTexture new];
    NSBitmapImageRep *pixels=bitmap(w,h);
    CGImageRef cut=CGImageCreateWithImageInRect(sheet,NSRectToCGRect(cell));
    begin(pixels);
    CGContextDrawImage(NSGraphicsContext.currentContext.CGContext,CGRectMake(0,0,w,h),cut);
    [NSGraphicsContext restoreGraphicsState]; CGImageRelease(cut);
    for (int y=0;y<h;y++) {
        uint8_t *row=pixels.bitmapData+y*pixels.bytesPerRow;
        for (int x=0;x<w;x++) if (row[4*x+3]<8) memset(row+4*x,0,4);
    }
    if (sharpen) sharpenLinework(pixels);
    pose.pixels=pixels; pose.bounds=trim(pixels,NSMakeRect(0,0,w,h)); pose.rig=rig;
    if (rig) {
        pose.hands=bitmap(w,h); begin(pose.hands);
        [NSColor.whiteColor setFill];
        for (NSString *side in @[@"left",@"right"]) {
            NSDictionary *hand=rig[side];
            if (!hand || [hand[@"outline"] count]<3) fail(@"手部轮廓缺失");
            fillOutline(hand[@"sleeve"],h); fillOutline(hand[@"outline"],h);
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    return pose;
}
static NSBitmapImageRep *sheet(NSURL *url) {
    NSBitmapImageRep *s=[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfURL:url]];
    if (!s || !s.hasAlpha) fail([@"需要透明动作图：" stringByAppendingString:url.path]);
    return s;
}
static PoseTexture *cell(NSBitmapImageRep *s,int columns,int rows,int n,NSDictionary *rig,BOOL sharp) {
    NSInteger x=s.pixelsWide*(n%columns)/columns, y=s.pixelsHigh*(n/columns)/rows;
    return texture(s.CGImage,NSMakeRect(x,y,s.pixelsWide*(n%columns+1)/columns-x,
                    s.pixelsHigh*(n/columns+1)/rows-y),rig,sharp);
}

// Register only the facial marks that change. Hair, shoulders and clothes
// are copied verbatim from the neutral cell during a blink or a head pat.
static PoseTexture *expression(PoseTexture *idle,PoseTexture *art,NSDictionary *registration) {
    NSArray *matrix=registration[@"sourceToIdle"], *ellipses=registration[@"ellipses"];
    if (matrix.count!=6 || !ellipses.count) fail(@"表情定位数据不全");
    double a=[matrix[0] doubleValue],b=[matrix[1] doubleValue],c=[matrix[2] doubleValue],
           d=[matrix[3] doubleValue],tx=[matrix[4] doubleValue],ty=[matrix[5] doubleValue];
    double det=a*d-b*c,feather=fmax(.5,[registration[@"feather"] doubleValue]);
    if (fabs(det)<1e-6) fail(@"无效表情变换");
    PoseTexture *result=[PoseTexture new];
    result.bounds=idle.bounds; result.hands=idle.hands; result.rig=idle.rig;
    NSInteger w=idle.pixels.pixelsWide,h=idle.pixels.pixelsHigh;
    result.pixels=bitmap((int)w,(int)h);
    NSInteger stride=result.pixels.bytesPerRow,ss=art.pixels.bytesPerRow;
    uint8_t *out=result.pixels.bitmapData, *base=idle.pixels.bitmapData, *src=art.pixels.bitmapData;
    memcpy(out,base,stride*h);
    for (NSArray *ellipse in ellipses) {
        double cx=[ellipse[0] doubleValue],cy=[ellipse[1] doubleValue],rx=[ellipse[2] doubleValue],ry=[ellipse[3] doubleValue];
        for (int y=fmax(0,floor(cy-ry));y<fmin(h,ceil(cy+ry));y++) for (int x=fmax(0,floor(cx-rx));x<fmin(w,ceil(cx+rx));x++) {
            double u=(x+.5-cx)/rx,v=(y+.5-cy)/ry;
            double mix=fmin(1,fmax(0,(1-sqrt(u*u+v*v))*fmin(rx,ry)/feather));
            if (mix==0) continue;
            mix=mix*mix*(3-2*mix);
            double X=x+.5-tx,Y=y+.5-ty,fx=(d*X-c*Y)/det-.5,fy=(-b*X+a*Y)/det-.5;
            if (fx<0 || fy<0 || fx>=art.pixels.pixelsWide-1 || fy>=art.pixels.pixelsHigh-1) continue;
            int ix=(int)fx,iy=(int)fy; fx-=ix; fy-=iy;
            const uint8_t *sample=src+iy*ss+ix*4;
            for (int k=0;k<4;k++) {
                double value=(sample[k]*(1-fx)+sample[k+4]*fx)*(1-fy)+(sample[ss+k]*(1-fx)+sample[ss+4+k]*fx)*fy;
                int n=y*(int)stride+4*x+k;
                out[n]=lrint(base[n]*(1-mix)+value*mix);
            }
        }
    }
    return result;
}

// Preserve the unstruck hand, hair and torso. The clean plate is revealed
// strictly beneath the moving sleeve, never used as a replacement portrait.
static void separateArms(PoseTexture *idle,PoseTexture *under,NSRect underRect) {
    int w=(int)idle.pixels.pixelsWide,h=(int)idle.pixels.pixelsHigh;
    NSBitmapImageRep *clothes=bitmap(w,h); begin(clothes);
    CGContextDrawImage(NSGraphicsContext.currentContext.CGContext,
        CGRectMake(underRect.origin.x,h-NSMaxY(underRect),underRect.size.width,underRect.size.height),under.pixels.CGImage);
    [NSGraphicsContext restoreGraphicsState];
    NSMutableArray *plates=[NSMutableArray array], *arms=[NSMutableArray array];
    for (NSString *side in @[@"left",@"right"]) {
        NSBitmapImageRep *mask=bitmap(w,h); begin(mask);
        [NSColor.whiteColor setFill];
        fillOutline(idle.rig[side][@"sleeve"],h);
        fillOutline(idle.rig[side][@"outline"],h);
        [NSGraphicsContext restoreGraphicsState];
        PoseTexture *body=[PoseTexture new], *arm=[PoseTexture new];
        body.pixels=bitmap(w,h); arm.pixels=bitmap(w,h); body.hands=bitmap(w,h);
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            int offset=y*(int)mask.bytesPerRow+4*x;
            double a=mask.bitmapData[offset+3]/255.;
            // Clear the old antialiased sleeve line as well as its interior.
            double clear=a;
            if (a<1) for (int oy=-2;oy<=2;oy++) for (int ox=-2;ox<=2;ox++) {
                if (ox*ox+oy*oy>5 || x+ox<0 || y+oy<0 || x+ox>=w || y+oy>=h) continue;
                clear=fmax(clear,mask.bitmapData[(y+oy)*mask.bytesPerRow+4*(x+ox)+3]/255.);
            }
            body.hands.bitmapData[offset+3]=(uint8_t)(idle.hands.bitmapData[offset+3]*(1-a));
            for (int k=0;k<4;k++) {
                int j=offset+k;
                arm.pixels.bitmapData[j]=lrint(idle.pixels.bitmapData[j]*a);
                body.pixels.bitmapData[j]=lrint(idle.pixels.bitmapData[j]*(1-clear)+clothes.bitmapData[j]*clear);
            }
        }
        [plates addObject:body]; [arms addObject:arm];
    }
    idle.plates=plates; idle.arms=arms;
}

static const int density=2, patchTop=145;
static const CGFloat boardX=20, boardY=205, boardSX=.85, boardSY=.72;
static NSPoint keyTarget(int r,int k) {
    const CGFloat starts[]={1.05,1.45,1.8,2.3};
    NSRect cap=r<4?keyRect(starts[r]+k,1,4-r):k==0?keyRect(3.8,6.4,0):keyRect(13.1,1.9,4);
    CGFloat x=(r==4 && k==0)?NSMinX(cap)+.35*cap.size.width:NSMidX(cap);
    return NSMakePoint(boardX+boardSX*x,boardY+boardSY*(H-NSMidY(cap)-203));
}
typedef struct {
    CGFloat scale, x, y;
    NSPoint tip,wrist,elbow;
    double dx,dy,press;
    BOOL moving;
    NSPoint shoulder,newElbow,newWrist,newTip;
    BOOL gripping;
    NSPoint sourceShoulder,sourceWrist;
    double gripCos,gripSin;
} Placement;
static NSPoint place(Placement p,NSPoint raw) {
    return NSMakePoint(p.x+p.scale*raw.x,p.y+p.scale*raw.y);
}
static double clamp(double t) { return fmin(1,fmax(0,t)); }
static double ease(double t) { t=clamp(t); return t*t*(3-2*t); }
static NSPoint between(NSPoint a,NSPoint b,double amount) {
    return NSMakePoint(a.x+(b.x-a.x)*amount,a.y+(b.y-a.y)*amount);
}

// Keep the drawn mouse grip, cuff and fingers on one rigid piece. The initial
// reach still uses the resting arm. During the approach, absorb the shortened
// reach in the sleeve between shoulder and wrist.
static PoseTexture *mouseArm(NSBitmapImageRep *sheetImage,int column,NSDictionary *hand) {
    PoseTexture *arm=cell(sheetImage,3,2,column,nil,NO);
    NSBitmapImageRep *mask=bitmap(arm.pixels.pixelsWide,arm.pixels.pixelsHigh);
    begin(mask);
    [NSColor.whiteColor setFill];
    fillOutline(hand[@"sleeve"],mask.pixelsHigh);
    fillOutline(hand[@"outline"],mask.pixelsHigh);
    [NSGraphicsContext restoreGraphicsState];
    for (int y=0;y<mask.pixelsHigh;y++) for (int x=0;x<mask.pixelsWide;x++) {
        uint8_t *pixel=arm.pixels.bitmapData+y*arm.pixels.bytesPerRow+4*x;
        uint8_t alpha=mask.bitmapData[y*mask.bytesPerRow+4*x+3];
        for (int k=0;k<4;k++) pixel[k]=(pixel[k]*alpha+127)/255;
    }
    arm.rig=hand;
    return arm;
}
// Map length along a bone while keeping its cross-section at its drawn width.
static NSPoint bone(NSPoint s,NSPoint a,NSPoint b,NSPoint destA,NSPoint destB) {
    double x=b.x-a.x,y=b.y-a.y,len=fmax(1,hypot(x,y));
    double u=((s.x-a.x)*x+(s.y-a.y)*y)/(len*len);
    double v=(-(s.x-a.x)*y+(s.y-a.y)*x)/len;
    double dx=destB.x-destA.x,dy=destB.y-destA.y,dl=fmax(1,hypot(dx,dy));
    return NSMakePoint(destA.x+u*dx-v*dy/dl,destA.y+u*dy+v*dx/dl);
}
static void solveArm(Placement *p,BOOL right,NSArray *sleeve) {
    double first=DBL_MAX,sum=0,count=0;
    for (NSArray *v in sleeve) first=fmin(first,pointFrom(v).y);
    for (NSArray *v in sleeve) if (pointFrom(v).y<first+9) { sum+=pointFrom(v).x; count++; }
    if (!count) fail(@"缺少前臂或衣袖的肩端标注");
    p->shoulder=place(*p,NSMakePoint(sum/count,first));
    p->shoulder.y=fmax(patchTop,p->shoulder.y);
    p->newTip=NSMakePoint(p->tip.x+p->dx,p->tip.y+p->dy);
    double ang=fmax(-.16,fmin(.16,-p->dx*.0027)),x=p->wrist.x-p->tip.x,y=p->wrist.y-p->tip.y;
    p->newWrist=NSMakePoint(p->newTip.x+x*cos(ang)-y*sin(ang),p->newTip.y+x*sin(ang)+y*cos(ang));
    double ux=p->newWrist.x-p->shoulder.x,uy=p->newWrist.y-p->shoulder.y,d=fmax(.01,hypot(ux,uy));
    double upper=hypot(p->elbow.x-p->shoulder.x,p->elbow.y-p->shoulder.y);
    double lower=hypot(p->wrist.x-p->elbow.x,p->wrist.y-p->elbow.y);
    double extend=fmax(1,(d+.4)/(upper+lower));
    upper*=extend; lower*=extend;
    double along=(upper*upper-lower*lower+d*d)/(2*d);
    double across=sqrt(fmax(0,upper*upper-along*along))*(right?-1:1);
    p->newElbow=NSMakePoint(p->shoulder.x+(along*ux-across*uy)/d,p->shoulder.y+(along*uy+across*ux)/d);
}
static NSPoint articulated(Placement p,NSPoint s) {
    NSPoint upper=bone(s,p.shoulder,p.elbow,p.shoulder,p.newElbow);
    NSPoint lower=bone(s,p.elbow,p.wrist,p.newElbow,p.newWrist);
    NSPoint hand=bone(s,p.wrist,p.tip,p.newWrist,p.newTip);
    NSPoint deformed=between(upper,lower,ease((s.y-p.elbow.y+4)/8));
    deformed=between(deformed,hand,ease((s.y-p.wrist.y+3.5)/7));
    // Curl the adjacent fingers slightly on impact, anchored at the striking fingertip.
    deformed.y-=1.5*p.press*ease(fabs(s.x-p.tip.x)/8)*ease((s.y-p.wrist.y)/8);
    return between(s,deformed,ease((s.y-p.shoulder.y)/9));
}
static NSPoint bend(Placement p,NSPoint raw) {
    if (p.gripping) {
        double x=raw.x-p.sourceShoulder.x, y=raw.y-p.sourceShoulder.y;
        double wx=p.sourceWrist.x-p.sourceShoulder.x, wy=p.sourceWrist.y-p.sourceShoulder.y;
        // The entire palm stays rigid, including its outer fingers and thumb.
        double sleeve=ease((x*wx+y*wy)/(.83*(wx*wx+wy*wy)));
        return NSMakePoint(p.shoulder.x+p.gripCos*x-p.gripSin*y+p.dx*sleeve,
                           p.shoulder.y+p.gripSin*x+p.gripCos*y+p.dy*sleeve);
    }
    NSPoint s=place(p,raw);
    return p.moving && s.y>patchTop ? articulated(p,s) : s;
}

static Placement mousePlacement(Placement rest,NSDictionary *hand,int stage,int quadrant) {
    Placement p={0};
    p.gripping=YES;
    p.shoulder=place(rest,pointFrom(hand[@"restAttachment"]));
    p.sourceShoulder=pointFrom(hand[@"attachment"]);
    p.sourceWrist=pointFrom(hand[@"wrist"]);
    NSPoint tip=pointFrom(hand[@"tip"]);
    double x=tip.x-p.sourceShoulder.x, y=tip.y-p.sourceShoulder.y;
    NSPoint button=mouseButtonPoint();
    double tx=button.x-p.shoulder.x, ty=button.y-p.shoulder.y;
    // One similarity transform aligns the drawn shoulder and fingertip to
    // the pet's shoulder and the mouse buttons, preserving hand proportions.
    double length2=x*x+y*y;
    p.gripCos=(tx*x+ty*y)/length2;
    p.gripSin=(ty*x-tx*y)/length2;
    p.dx=(stage==2?16:0)+(quadrant%2?.6:-.6);
    p.dy=(stage==2?-4:0)+(quadrant>=2?-.45:.45);
    return p;
}

typedef struct { double x,y,u,v; } Vertex;
typedef struct {
    uint8_t *src,*mask,*back,*front;
    NSInteger srcW,srcH,stride,maskStride;
    int outW,outH,outStride,frontStride;
} Raster;
static void triangle(Raster r,Vertex a,Vertex b,Vertex c) {
    double x1=b.x-a.x,y1=b.y-a.y,x2=c.x-a.x,y2=c.y-a.y,det=x1*y2-x2*y1;
    if (det<=.001) return;
    int xmin=fmax(0,floor(fmin(a.x,fmin(b.x,c.x)))), xmax=fmin(r.outW-1,ceil(fmax(a.x,fmax(b.x,c.x))));
    int ymin=fmax(0,floor(fmin(a.y,fmin(b.y,c.y)))), ymax=fmin(r.outH-1,ceil(fmax(a.y,fmax(b.y,c.y))));
    for (int y=ymin;y<=ymax;y++) {
        double v=y+.5-a.y, u=xmin+.5-a.x;
        double m=(u*y2-v*x2)/det,n=(x1*v-y1*u)/det;
        for (int x=xmin;x<=xmax;x++,m+=y2/det,n-=y1/det) {
            if (m<-.000001 || n<-.000001 || m+n>1.000001) continue;
            double tx=fmax(0,fmin(r.srcW-1.001,a.u+m*(b.u-a.u)+n*(c.u-a.u)-.5));
            double ty=fmax(0,fmin(r.srcH-1.001,a.v+m*(b.v-a.v)+n*(c.v-a.v)-.5));
            int ix=(int)tx,iy=(int)ty; double fx=tx-ix,fy=ty-iy;
            const uint8_t *s=r.src+iy*r.stride+4*ix;
            double w0=(1-fx)*(1-fy),w1=fx*(1-fy),w2=(1-fx)*fy,w3=fx*fy;
            uint8_t *pixel=r.back+y*r.outStride+4*x;
            for (int channel=0;channel<4;channel++)
                pixel[channel]=(uint8_t)(.5+s[channel]*w0+s[channel+4]*w1+s[r.stride+channel]*w2+s[r.stride+channel+4]*w3);
            if (r.mask) {
                const uint8_t *mask=r.mask+iy*r.maskStride+4*ix+3;
                double alpha=(mask[0]*w0+mask[4]*w1+mask[r.maskStride]*w2+mask[r.maskStride+4]*w3)/255.;
                uint8_t *front=r.front+y*r.frontStride+4*x;
                for (int k=0;k<4;k++) front[k]=(uint8_t)(pixel[k]*alpha+.5);
            }
        }
    }
}
// Rasterise the same triangle mesh for the character and its foreground cuffs.
// UV sampling is premultiplied; transparent hair edges stay clean at any scale.
static void layers(PoseTexture *pose,Placement p,int top,NSBitmapImageRep *back,NSBitmapImageRep *front) {
    NSBitmapImageRep *src=pose.pixels,*mask=pose.hands;
    Raster r={src.bitmapData,mask.bitmapData,back.bitmapData,front.bitmapData,
              src.pixelsWide,src.pixelsHigh,src.bytesPerRow,mask.bytesPerRow,
              (int)back.pixelsWide,(int)back.pixelsHigh,(int)back.bytesPerRow,(int)front.bytesPerRow};
    const int step=12, nx=ceil(src.pixelsWide/(double)step)+1,ny=ceil(src.pixelsHigh/(double)step)+1;
    Vertex *mesh=calloc(nx*ny,sizeof(Vertex));
    for (int j=0;j<ny;j++) for (int i=0;i<nx;i++) {
        double u=fmin(i*step,src.pixelsWide),v=fmin(j*step,src.pixelsHigh);
        NSPoint dest=bend(p,NSMakePoint(u,v));
        mesh[j*nx+i]=(Vertex){dest.x*density,(dest.y-top)*density,u,v};
    }
    for (int j=0;j<ny-1;j++) for (int i=0;i<nx-1;i++) {
        Vertex *v=mesh+j*nx+i;
        triangle(r,v[0],v[1],v[nx+1]); triangle(r,v[0],v[nx+1],v[nx]);
    }
    free(mesh);
}
static void render(NSURL *dir,NSString *name,PoseTexture *pose,Palette palette,int theme,
                   int code,BOOL right,int phase,NSPoint target,int mouseLevel,int quadrant,int smile) {
    BOOL key=code>=0,mouse=mouseLevel>0;
    int top=key?patchTop:0;
    int outW=W*density,outH=(H-top)*density;
    NSBitmapImageRep *back=bitmap(outW,outH), *front=bitmap(outW,outH), *output=bitmap(outW,outH);
    NSRect bounds=pose.bounds;
    Placement p={0};
    p.scale=fmin(251/bounds.size.width,202/bounds.size.height);
    p.x=150-NSMidX(bounds)*p.scale;
    p.y=211-NSMaxY(bounds)*p.scale;
    NSDictionary *hand=pose.rig[right?@"right":@"left"];
    double pressure=0;
    if (key || mouse) {
        p.tip=place(p,pointFrom(hand[@"tip"])); p.wrist=place(p,pointFrom(hand[@"wrist"]));
        p.elbow=place(p,pointFrom(hand[@"elbow"])); p.moving=YES;
        if (key) {
            const double reach[]={.09,.61,1,.77,.20}, lift[]={2.6,4.4,0,2,3.3};
            pressure=phase==3?1:phase==4?.25:0;
            p.dx=(target.x-p.tip.x)*reach[phase-1];
            p.dy=(target.y-p.tip.y)*reach[phase-1]-lift[phase-1];
            p.press=pressure;
        } else if (mouseLevel==1) {
            NSPoint button=mouseButtonPoint();
            p.dx=(button.x-p.tip.x)*.20;
            p.dy=(button.y-p.tip.y)*.20-3;
        }
    }
    NSBitmapImageRep *movingArm=nil;
    if (key || mouse) {
        Placement fixed=p; fixed.moving=NO;
        layers(pose.plates[right?1:0],fixed,top,back,front);
        movingArm=bitmap(outW,outH);
        if (mouseLevel>=2) {
            Placement grip=mousePlacement(fixed,pose.mouseArm.rig,mouseLevel,quadrant);
            layers(pose.mouseArm,grip,top,movingArm,nil);
        } else {
            solveArm(&p,right,hand[@"sleeve"]);
            layers(pose.arms[right?1:0],p,top,movingArm,nil);
        }
    } else {
        layers(pose,p,top,back,front);
    }
    begin(output);
    CGContextRef cg=NSGraphicsContext.currentContext.CGContext;
    CGContextDrawImage(cg,CGRectMake(0,0,outW,outH),back.CGImage);
    [NSGraphicsContext saveGraphicsState];
    CGContextScaleCTM(cg,density,density);
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t=[NSAffineTransform transform];
    [t translateXBy:boardX yBy:H-boardY-boardSY*(H-203)];
    [t scaleXBy:boardSX yBy:boardSY]; [t concat];
    keyboard(palette,code,right,pressure);
    [NSGraphicsContext restoreGraphicsState];
    drawMouse(palette,mouse);
    if (smile>=0) drawAffection(smile,theme);
    [NSGraphicsContext restoreGraphicsState];
    CGContextDrawImage(cg,CGRectMake(0,0,outW,outH),front.CGImage);
    if (movingArm) CGContextDrawImage(cg,CGRectMake(0,0,outW,outH),movingArm.CGImage);
    if (key) {
        CGContextScaleCTM(cg,density,density);
        badge(palette,code,right,pressure);
    }
    [NSGraphicsContext restoreGraphicsState];
    if (mouse) {
        if (!pose.neutralFrame) fail(@"缺少待机参考帧");
        memcpy(output.bitmapData,pose.neutralFrame.bitmapData,output.bytesPerRow*patchTop*density);
        // Keep the resting shoulder seam and the diagonal edge of the cape.
        // The two drawings meet inside the sleeve, away from the outer ink line.
        if (mouseLevel>=2) {
            for (int y=patchTop*density;y<375;y++) for (int x=150;x<304;x++) {
                double seam=theme==0?319:theme==1?319+.40*(x-202):311;
                double kept=1-ease((y-seam+10)/19);
                if (kept<=0) continue;
                int i=y*(int)output.bytesPerRow+4*x;
                for (int k=0;k<4;k++)
                    output.bitmapData[i+k]=lrint(output.bitmapData[i+k]*(1-kept)+pose.neutralFrame.bitmapData[i+k]*kept);
            }
        }
    } else if (!key && smile<0 && phase==0) {
        pose.neutralFrame=output;
    }
    writeBitmap(output,[dir URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]);
}
static void exportRole(NSString *role,int idx,Palette pal,NSURL *art,NSURL *assets,
                       NSBitmapImageRep *smiles,NSBitmapImageRep *underlay,NSDictionary *rig,NSDictionary *face) {
    NSURL *dir=[assets URLByAppendingPathComponent:role isDirectory:YES];
    NSError *e=nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&e]) fail(e.localizedDescription);
    NSBitmapImageRep *base=sheet([art URLByAppendingPathComponent:[role stringByAppendingPathExtension:@"png"]]);
    NSDictionary *neutralRig=rig[[role stringByAppendingString:@"-idle"]];
    if (!neutralRig) fail(@"找不到待机手部标注");
    PoseTexture *idle=cell(base,3,2,0,neutralRig,idx==0);
    NSDictionary *grip=rig[[role stringByAppendingString:@"-mouseLeft"]][@"left"];
    if (!grip[@"sleeve"] || !grip[@"attachment"] || !grip[@"restAttachment"])
        fail(@"缺少握鼠标手臂标注");
    idle.mouseArm=mouseArm(sheet([art URLByAppendingPathComponent:@"mouse.png"]),idx,grip);
    PoseTexture *under=cell(underlay,3,1,idx,nil,NO);
    separateArms(idle,under,NSMakeRect(0,0,idle.pixels.pixelsWide,idle.pixels.pixelsHigh));
    PoseTexture *blink=expression(idle,cell(base,3,2,1,nil,idx==0),face[role][@"blink"]);
    PoseTexture *smile=expression(idle,cell(smiles,3,1,idx,nil,idx==0),face[role][@"smile"]);
    for (int i=0;i<8;i++) @autoreleasepool {
        render(dir,[NSString stringWithFormat:@"idle%d",i],i==7?blink:idle,pal,idx,-1,NO,i,NSZeroPoint,0,0,-1);
    }
    for (int i=0;i<6;i++) @autoreleasepool {
        render(dir,[NSString stringWithFormat:@"smile%d",i],smile,pal,idx,-1,NO,0,NSZeroPoint,0,0,i);
    }
    for (int n=1;n<=3;n++) for (int q=0;q<4;q++) @autoreleasepool {
        render(dir,[NSString stringWithFormat:@"mouse%d%d",n,q],idle,pal,idx,-1,NO,0,NSZeroPoint,n,q,-1);
    }
    for (int r=0;r<5;r++) {
        NSUInteger count=r==4?3:keyRows[r].length;
        for (NSUInteger k=0;k<count;k++) for (int n=1;n<=5;n++) @autoreleasepool {
            int code=r==4?(int[]){32,8,127}[k]:symbolFor([keyRows[r] characterAtIndex:k]);
            render(dir,[NSString stringWithFormat:@"key%d-%d",code,n],idle,pal,idx,code,r<4&&k<5,
                   n,keyTarget(r,(int)k),0,0,-1);
        }
    }
    printf("%s: 26 full frames + 240 typing patches\n",role.UTF8String); fflush(stdout);
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc!=3) fail(@"用法：export <Artwork> <windows/assets>");
        NSURL *art=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *assets=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        NSData *data=[NSData dataWithContentsOfURL:[art URLByAppendingPathComponent:@"hand-rig.json"]];
        NSDictionary *rig=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if (![rig isKindOfClass:NSDictionary.class]) fail(@"缺少 hand-rig.json");
        NSData *faceData=[NSData dataWithContentsOfURL:[art URLByAppendingPathComponent:@"expression-rig.json"]];
        NSDictionary *face=faceData?[NSJSONSerialization JSONObjectWithData:faceData options:0 error:nil]:nil;
        if (!face) fail(@"缺少 expression-rig.json");
        NSBitmapImageRep *smiles=sheet([art URLByAppendingPathComponent:@"smile.png"]);
        NSBitmapImageRep *underlay=sheet([art URLByAppendingPathComponent:@"underlay.png"]);
        exportRole(@"blue",0,(Palette){0xb9d1ec,0x7288b6,0xf2f8ff,0x48669e,0x3d5176,0x404f75},art,assets,smiles,underlay,rig,face);
        exportRole(@"amber",1,(Palette){0xf1d2ab,0xcb976e,0xfff6e6,0xa34f25,0x694537,0x705146},art,assets,smiles,underlay,rig,face);
        exportRole(@"frost",2,(Palette){0xdad4ed,0xa49bc2,0xfbf8ff,0x79639e,0x615677,0x736a8b},art,assets,smiles,underlay,rig,face);
    }
}
