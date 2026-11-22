// Registered poses from the original transparent two-by-two arm and rice sheet.
// Coordinates in the sheet cells and the final 600×540 canvas start at top left.
typedef enum { BothMealArms, ChopstickArm, BowlArm } MealPart;

static double mealDivider(int pose,int row) {
    // Through transparent space between the chopsticks and the bowl. Pose 3
    // has a rice ball high above the hand and must keep it attached to the tips.
    if (pose==2) return 393-130*clamp((row-205)/55.);
    return row<425 ? 300-22*clamp((row-345)/80.) : 278+62*clamp((row-425)/115.);
}

static void drawMealPart(NSBitmapImageRep *art,int pose,MealPart part,NSPoint sourceShoulder,
                         NSPoint shoulder,double scale,double degrees) {
    int w=(int)art.pixelsWide/2,h=(int)art.pixelsHigh/2;
    NSRect tile=NSMakeRect(pose%2*w,pose/2*h,w,h);
    drawActivityPart(art,tile,sourceShoulder,shoulder,scale,degrees,14,250,^BOOL(int x,int y) {
        return part==BothMealArms || ((x<=mealDivider(pose,y))==(part==ChopstickArm));
    });
}

static void exportBlueRice(NSURL *dir,NSURL *artDir,PoseTexture *idle,Palette palette) {
    NSBitmapImageRep *art=sheet([artDir URLByAppendingPathComponent:@"blue-rice.png"]);
    if (art.pixelsWide!=1321 || art.pixelsHigh!=1191 ||
        art.bitsPerSample!=8 || art.samplesPerPixel!=4 || art.isPlanar ||
        art.bitmapFormat!=NSBitmapFormatAlphaNonpremultiplied) fail(@"蓝鲸吃饭动作图格式不符");
    NSBitmapImageRep *background=activityBackground(idle,palette,0,YES);
    NSBitmapImageRep *openMouth=sheet([dir URLByAppendingPathComponent:@"smileHalf.png"]);
    CGRect mouthRect=CGRectMake(283,204,42,38);
    CGImageRef lips=CGImageCreateWithImageInRect(openMouth.CGImage,mouthRect);
    for (int i=0;i<4;i++) @autoreleasepool {
        NSBitmapImageRep *out=bitmap(background.pixelsWide,background.pixelsHigh);
        memcpy(out.bitmapData,background.bitmapData,background.bytesPerRow*background.pixelsHigh);
        begin(out);
        if (i==2) CGContextDrawImage(NSGraphicsContext.currentContext.CGContext,
            CGRectMake(mouthRect.origin.x,H*density-CGRectGetMaxY(mouthRect),mouthRect.size.width,mouthRect.size.height),lips);
        double sourceY=i<2?132:93;
        NSPoint sourceLeft=NSMakePoint(i==0?157:158,sourceY);
        NSPoint targetLeft=NSMakePoint(i==2?242:244,274);
        if (i==0 || i==2) {
            drawMealPart(art,i,BowlArm,NSMakePoint(499,sourceY),NSMakePoint(370,274),i==0?.343:.367,0);
            drawMealPart(art,i,ChopstickArm,sourceLeft,targetLeft,i==0?.330:.403,i==0?-8:-47);
        } else {
            // Preserve the painted contact between the chopsticks and rice.
            drawMealPart(art,i,BothMealArms,sourceLeft,targetLeft,i==1?.361:.367,0);
        }
        [NSGraphicsContext restoreGraphicsState];
        writeBitmap(out,[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"rice%d.png",i+1]]);
    }
    CGImageRelease(lips);
}
