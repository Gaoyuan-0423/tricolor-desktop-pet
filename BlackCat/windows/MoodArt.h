// Register the three-by-two expression sheet to the existing seated portrait.
// Pixel coordinates refer to a 512 × 512 source cell and the 600 × 540 idle art.
#import <Cocoa/Cocoa.h>
#include <math.h>

typedef struct {
    double lx, ly, rx, ry, mx, my;
} MoodFaceMarks;

static void stampMoodFeature(NSBitmapImageRep *out, NSBitmapImageRep *sheet, int cell,
                             NSPoint source, NSPoint target, double width, double height,
                             double scale, double slope, double upperLid, double oldLid,
                             const double skin[3], const double tint[3], BOOL eye) {
    int ox=(cell%3)*512, oy=(cell/3)*512;
    const double cs=cos(slope), sn=sin(slope);
    for (int y=(int)(target.y-height)-4; y<=target.y+height+4; y++) {
        for (int x=(int)(target.x-width)-3; x<=target.x+width+3; x++) {
            double dx=x-target.x, dy=y-target.y;
            double u=cs*dx+sn*dy, v=-sn*dx+cs*dy;
            double edge=hypot(u/width, v/height);
            if (edge>=1) continue;
            double weight=fmin(1,(1-edge)*7);
            uint8_t *dest=out.bitmapData+y*out.bytesPerRow+4*x;
            double sx=source.x+u/scale+ox, sy=source.y+v/scale+oy;
            int ix=(int)floor(sx), iy=(int)floor(sy);
            double fx=sx-ix, fy=sy-iy;
            double rgb[3];
            for (int k=0; k<3; k++) {
                const uint8_t *p=sheet.bitmapData + iy*sheet.bytesPerRow+ix*4+k;
                double a=p[0]*(1-fx)+p[4]*fx;
                double b=p[sheet.bytesPerRow]*(1-fx)+p[sheet.bytesPerRow+4]*fx;
                rgb[k]=a*(1-fy)+b*fy;
            }
            // Match skin and cheek highlights to the lighting of the seated art.
            double skinMix=fmin(1,fmax(0,(rgb[0]-180)/50.))*fmin(1,fmax(0,(rgb[0]-rgb[2])/12.));
            for (int k=0;k<3;k++) rgb[k]=fmin(255,fmax(0,rgb[k]+tint[k]*skinMix));
            // The source bangs have a different contour. Fade above the
            // expression's upper lid onto the original forehead, replacing
            // the old open lashes with skin when the eye closes.
            if (eye) {
                double newEdge = upperLid+.011*u*u-3;
                double oldEdge = oldLid+.012*u*u-2;
                double useSource=fmin(1,fmax(0,(v-newEdge)/3.));
                double clearLid=fmin(1,fmax(0,(v-oldEdge)/2.));
                for (int k=0;k<3;k++) {
                    double under=dest[k]*(1-clearLid)+skin[k]*clearLid;
                    rgb[k]=under*(1-useSource)+rgb[k]*useSource;
                }
            }
            for (int k=0; k<3; k++) {
                dest[k]=(uint8_t)lround(dest[k]*(1-weight)+rgb[k]*weight);
            }
        }
    }
}

typedef struct {
    NSPoint location;
    double radiusX, radiusY;
} MoodFeature;

typedef struct {
    MoodFeature eyes[2], mouth;
    double scale, slope, oldLid, skin[3], tint[3];
} MoodTarget;

static void exportMoods(NSURL *art, NSURL *directory, NSUInteger role) {
    // Each original character has its own eye spacing, tilt, and skin tone.
    static const MoodTarget targets[] = {
        {{{{264.4,192.8},26.5,20.5},{{333.8,184.7},25.8,20.0}},{{305.3,223.8},18.5,13},.452,-.11,-17,{254,230,220},{0,0,0}},
        {{{{261.1,157.8},24.0,17.4},{{325.4,148.8},24.2,18.3}},{{298.9,187.9},17.0,12},.431,-.125,-14,{253,226,212},{-1,-6,-10}},
        {{{{273.2,179.4},23.3,16.5},{{332.1,172.2},22.8,16.8}},{{306.2,206.8},16.0,12},.431,-.11,-13,{251,231,227},{0,1,3}}
    };
    // Centers of the eye opening (irrespective of iris direction) and mouth.
    static const MoodFaceMarks marks[][6] = {
        {{201,319,333,318,265,395},{194,320,329,311,267,395},{188,320,322,317,256,389},
         {202,329,333,325,274,397},{191,321,324,315,263,397},{186,322,325,317,256,388}},
        {{199,298,330,293,273,361},{196,291,328,283,273,357},{195,279,331,274,270,359}},
        {{206,286,333,277,275,366},{205,286,334,280,276,363},{201,305,335,289,277,371}}
    };
    static const double lids[][6]={{-17,-14,-9,1,-15,-9},{-7,0,-16},{-15,-13,1}};
    NSURL *sheetURL=[art URLByAppendingPathComponent:role==0 ? @"blue-moods.png" : @"amber-frost-moods.png"];
    NSBitmapImageRep *sheet=[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfURL:sheetURL]];
    NSData *idle=[NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"idle0.png"]];
    if (role>=3 || sheet.pixelsWide!=1536 || sheet.pixelsHigh!=1024 || sheet.bitsPerSample!=8 ||
        sheet.samplesPerPixel!=4 || sheet.isPlanar || !idle) {
        fprintf(stderr,"Cannot register expressions from %s\n",sheetURL.path.UTF8String);
        exit(1);
    }
    MoodTarget t=targets[role];
    for (int i=0; i<(role==0 ? 6 : 3); i++) @autoreleasepool {
        NSBitmapImageRep *out=[[NSBitmapImageRep alloc] initWithData:idle];
        MoodFaceMarks m=marks[role][i];
        const NSPoint from[]={NSMakePoint(m.lx,m.ly),NSMakePoint(m.rx,m.ry),NSMakePoint(m.mx,m.my)};
        const MoodFeature to[]={t.eyes[0],t.eyes[1],t.mouth};
        int cell=role==2 ? i+3 : i;
        for (int k=0;k<3;k++) {
            double scale=(role==0 && k==2) ? .45 : t.scale;
            stampMoodFeature(out,sheet,cell,from[k],to[k].location,to[k].radiusX,to[k].radiusY,
                             scale,t.slope,lids[role][i],t.oldLid,t.skin,t.tint,k<2);
        }
        NSURL *url=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"mood%d.png",i+1]];
        NSData *png=[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToURL:url atomically:YES]) {
            fprintf(stderr,"Cannot export expression: %s\n",url.path.UTF8String);
            exit(1);
        }
    }
}
