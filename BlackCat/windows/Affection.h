#pragma once

#import <Cocoa/Cocoa.h>

// Draw in the exporter's 300 × 270, bottom-origin AppKit canvas. Each heart's
// position is given relative to the top edge so the motion reads as a rise.
static void affectionHeart(CGFloat x, CGFloat top, CGFloat radius, CGFloat angle,
                           CGFloat opacity, NSColor *fill, NSColor *edge) {
    if (opacity <= 0) return;
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:x yBy:270-top];
    [transform rotateByDegrees:angle];
    [transform scaleBy:radius];
    [transform concat];

    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0,-0.93)];
    [p curveToPoint:NSMakePoint(-0.96,0.42)
      controlPoint1:NSMakePoint(-0.25,-0.70) controlPoint2:NSMakePoint(-1.06,-0.12)];
    [p curveToPoint:NSMakePoint(0,0.58)
      controlPoint1:NSMakePoint(-0.89,0.96) controlPoint2:NSMakePoint(-0.30,1.12)];
    [p curveToPoint:NSMakePoint(0.96,0.42)
      controlPoint1:NSMakePoint(0.32,1.13) controlPoint2:NSMakePoint(0.92,0.95)];
    [p curveToPoint:NSMakePoint(0,-0.93)
      controlPoint1:NSMakePoint(1.06,-0.12) controlPoint2:NSMakePoint(0.27,-0.72)];
    [p closePath];
    [[fill colorWithAlphaComponent:opacity] setFill];
    [p fill];
    p.lineWidth = 0.8 / radius;
    p.lineJoinStyle = NSLineJoinStyleRound;
    [[edge colorWithAlphaComponent:opacity] setStroke];
    [p stroke];

    NSBezierPath *shine = [NSBezierPath bezierPath];
    [shine moveToPoint:NSMakePoint(-0.60,0.36)];
    [shine curveToPoint:NSMakePoint(-0.35,0.57)
          controlPoint1:NSMakePoint(-0.57,0.47) controlPoint2:NSMakePoint(-0.45,0.56)];
    shine.lineWidth = 0.16;
    shine.lineCapStyle = NSLineCapStyleRound;
    [[NSColor.whiteColor colorWithAlphaComponent:opacity*0.88] setStroke];
    [shine stroke];
    [NSGraphicsContext restoreGraphicsState];
}

static void drawAffection(int phase, int theme) {
    if (phase < 0 || phase > 5 || theme < 0 || theme > 2) return;
    // Main heart and two smaller echoes appear in sequence before dissolving.
    static const CGFloat alpha[] = {.74, 1, 1, .89, .58, .20};
    static const CGFloat size[]  = {.72, 1, 1.06, 1.02, .91, .75};
    static const CGFloat lift[]  = {0, 4, 10, 17, 25, 33};
    static const CGFloat drift[] = {0, 1, 2.5, 4.5, 7, 10};
    static const CGFloat palettes[][6] = {
        {.98, .55, .67,  .51, .29, .49},   // rose with a cool berry edge
        {1.0, .61, .45,  .58, .28, .23},   // apricot with a copper edge
        {.84, .64, .94,  .45, .33, .57}    // lilac with a plum edge
    };
    const CGFloat *c = palettes[theme];
    NSColor *fill = [NSColor colorWithSRGBRed:c[0] green:c[1] blue:c[2] alpha:1];
    NSColor *edge = [NSColor colorWithSRGBRed:c[3] green:c[4] blue:c[5] alpha:1];
    NSColor *blush = [fill blendedColorWithFraction:.38 ofColor:NSColor.whiteColor];
    affectionHeart(220+drift[phase], 71-lift[phase], 6.8*size[phase],
                   -17+phase, alpha[phase], fill, edge);
    if (phase >= 1) {
        affectionHeart(231+drift[phase]*.8, 77-lift[phase]*.92, 4.1*size[phase],
                       16-phase, alpha[phase]*(phase == 1 ? .70 : .90), blush, edge);
    }
    if (phase >= 2) {
        affectionHeart(218+drift[phase]*.50, 53-lift[phase]*.78, 2.65*size[phase],
                       12, alpha[phase]*(phase == 2 ? .72 : .90), fill, edge);
    }
}
