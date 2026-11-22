// Render one registered piece of a transparent pose in the 600×540 native
// canvas. Source and target anchors use top-left coordinates; the art rotates
// as one piece so books, fingers, chopsticks and plush toys retain their shape.
static void drawActivityPart(NSBitmapImageRep *art, NSRect tile, NSPoint sourcePin, NSPoint targetPin,
                             double scale, double degrees, int lowAlpha, int highAlpha,
                             BOOL (^contains)(int,int)) {
    int w=(int)tile.size.width,h=(int)tile.size.height;
    NSBitmapImageRep *piece=bitmap(w,h);
    for (int y=0;y<h;y++) {
        const uint8_t *src=art.bitmapData+((int)tile.origin.y+y)*art.bytesPerRow+4*(int)tile.origin.x;
        uint8_t *dst=piece.bitmapData+y*piece.bytesPerRow;
        for (int x=0;x<w;x++,src+=4,dst+=4) {
            if (contains && !contains(x,y)) continue;
            int alpha=(int)lrint(255*clamp(((int)src[3]-lowAlpha)/(double)(highAlpha-lowAlpha)));
            dst[3]=alpha;
            for (int c=0;c<3;c++) dst[c]=(src[c]*alpha+127)/255;
        }
    }
    CGContextRef cg=NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg,targetPin.x,H*density-targetPin.y);
    CGContextRotateCTM(cg,-degrees*M_PI/180);
    CGContextScaleCTM(cg,scale,scale);
    CGContextDrawImage(cg,CGRectMake(-sourcePin.x,sourcePin.y-h,w,h),piece.CGImage);
    CGContextRestoreGState(cg);
}
