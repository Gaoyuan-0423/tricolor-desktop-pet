// The sitting illustrations have different silhouettes. These coordinates are
// in the 600 × 540 exported idle pose, measured from its upper left corner.
#import <Cocoa/Cocoa.h>
#include <math.h>

static double restEase(double t) {
    t = fmin(1, fmax(0, t));
    return t*t*(3-2*t);
}

// Separate the free end of the dragon tail from the shoulder and wing.
// The cut follows transparent gaps until the last few rows at the fixed root.
static BOOL restTailPixel(int x, int y) {
    if (y < 310 || y >= 408 || x >= 493) return NO;
    double left = y < 343 ? 434 : fmin(444, 434 + (y-343)*0.52);
    double right = y < 338 ? 461 + (y-310)*0.83 : 493;
    return x >= left && x < right;
}

// Sample in premultiplied color so thin hair and tail edges stay transparent.
static void restSample(NSBitmapImageRep *image, BOOL tailOnly,
                       double x, double y, double sample[4]) {
    int x0 = (int)floor(x), y0 = (int)floor(y);
    double fx = x-x0, fy = y-y0;
    for (int j=0; j<2; j++) for (int i=0; i<2; i++) {
        int sx = x0+i, sy = y0+j;
        if (tailOnly && !restTailPixel(sx, sy)) continue;
        const uint8_t *p = image.bitmapData + sy*image.bytesPerRow + 4*sx;
        double weight = (i ? fx : 1-fx)*(j ? fy : 1-fy)*p[3]/255.;
        sample[3] += weight;
        for (int c=0; c<3; c++) sample[c] += weight*p[c];
    }
}

static void restComposite(uint8_t *pixel, const double sample[4], BOOL keepBase) {
    double baseAlpha = keepBase ? pixel[3]/255.*(1-sample[3]) : 0;
    double alpha = sample[3]+baseAlpha;
    for (int c=0; c<3; c++)
        pixel[c] = alpha > 0 ? (uint8_t)lround((sample[c]+baseAlpha*pixel[c])/alpha) : 0;
    pixel[3] = (uint8_t)lround(fmin(1,alpha)*255);
}

static void restLowerTail(NSBitmapImageRep *source, NSBitmapImageRep *out, double progress) {
    // Twist around the attached base. Radius is invariant, so this bend has
    // an exact inverse and preserves the painted scales and antialiased edge.
    const double cx = 443, cy = 397;
    const double angle = 1.31*progress;
    for (int y=310; y<430; y++) for (int x=420; x<536; x++) {
        double rx=x-cx, ry=y-cy;
        double radius=hypot(rx,ry);
        double bend=angle*restEase((radius-26)/27.);
        if (bend == 0) continue;
        double c=cos(bend), s=sin(bend);
        double sample[4]={0};
        restSample(source, YES, cx+c*rx+s*ry, cy-s*rx+c*ry, sample);
        uint8_t *pixel=out.bitmapData+y*out.bytesPerRow+4*x;
        if (restTailPixel(x,y)) {
            restComposite(pixel,sample,NO);
        } else if (sample[3]>0 && pixel[3]<255) {
            // The sleeve, wing and desk occlude the tail as it settles.
            double foreground=pixel[3]/255.;
            double alpha=foreground+sample[3]*(1-foreground);
            for (int k=0; k<3; k++)
                pixel[k]=(uint8_t)lround((pixel[k]*foreground+sample[k]*(1-foreground))/alpha);
            pixel[3]=(uint8_t)lround(alpha*255);
        }
    }
}

static void restSettleHair(NSBitmapImageRep *source, NSBitmapImageRep *out, double progress) {
    for (int y=300; y<410; y++) for (int x=426; x<512; x++) {
        double height = restEase((y-300)/40.)*restEase((410-y)/28.);
        double weight = progress*height*restEase((x-426)/48.)*restEase((512-x)/20.);
        if (weight <= 0) continue;
        double sample[4] = {0};
        restSample(source, NO, x+8*weight, y-5*weight, sample);
        restComposite(out.bitmapData+y*out.bytesPerRow+4*x, sample, NO);
    }
}

static void exportRestPoses(NSURL *directory, NSUInteger roleIndex) {
    NSData *idle = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"idle0.png"]];
    NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithData:idle];
    if (source.pixelsWide != 600 || source.pixelsHigh != 540 || source.isPlanar ||
        source.bitsPerSample != 8 || source.samplesPerPixel != 4 ||
        source.bitmapFormat != NSBitmapFormatAlphaNonpremultiplied || roleIndex > 2) {
        fprintf(stderr,"Unexpected idle pose format: %s\n", directory.path.UTF8String);
        exit(1);
    }
    for (int step=1; step<=4; step++) @autoreleasepool {
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:idle];
        if (roleIndex == 1) restSettleHair(source, out, step/4.);
        else if (roleIndex == 2) restLowerTail(source, out, step/4.);
        NSString *name=[NSString stringWithFormat:@"rest%d.png",step];
        NSURL *url=[directory URLByAppendingPathComponent:name];
        NSData *png = roleIndex == 0 ? idle : [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToURL:url atomically:YES]) {
            fprintf(stderr,"Cannot write rest pose: %s\n", url.path.UTF8String);
            exit(1);
        }
    }
}
