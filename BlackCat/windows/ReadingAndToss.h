// Landmarks are registered separately for the shoulder motion in the four
// reading poses and the raised hand which tosses the cloud. All target
// coordinates are measured in the 600 × 540 neutral desk canvas.
static void drawReadingPose(NSBitmapImageRep *art, int i) {
    static const double spineX[]={326,317,342,323}, shoulderY[]={224,226,213,205};
    static const double scale[]={.372,.367,.362,.36};
    static const int leftSleeveEnd[]={214,144,0,188},rightSleeveStart[]={463,500,521,464};
    NSRect tile=NSMakeRect(i%2*661,i/2*595,661,595);
    drawActivityPart(art,tile,NSMakePoint(spineX[i],shoulderY[i]),NSMakePoint(300,305),scale[i],0,13,251,
        ^BOOL(int x,int y) {
            BOOL shoulder=(x<leftSleeveEnd[i] || x>rightSleeveStart[i]) && y>=shoulderY[i]-25;
            if (!shoulder) return YES;
            // Slip the cut ends of the painted sleeves beneath the original
            // embroidered cape. The book and the page-turning hand stay in front.
            double X=300+(x-spineX[i])*scale[i],Y=305+(y-shoulderY[i])*scale[i];
            double offset=X-(X<300?219:381);
            return Y>321-.0105*offset*offset;
        });
}

static void drawTossPose(NSBitmapImageRep *art,int i) {
    NSRect tile=NSMakeRect(i%2*656,i/2*599,656,599);
    drawActivityPart(art,tile,NSMakePoint(410,145),NSMakePoint(365,245),.445,0,13,251,
        ^BOOL(int x,int y) { return x>=310; });
}
static void keepTossShoulder(NSBitmapImageRep *out, NSBitmapImageRep *idle) {
    // The reference pose includes a rounded cut at the shoulder. Keep the
    // pet's natural shoulder and the strands of hair in front of it.
    for (int y=202;y<287;y++) for (int x=322;x<401;x++) {
        double keep=(1-ease((y-262)/23.))*(1-ease((x-384)/16.));
        size_t p=y*out.bytesPerRow+4*x;
        for (int c=0;c<4;c++) {
            double fixed=idle?keep*idle.bitmapData[p+c]:0;
            out.bitmapData[p+c]=lrint(fixed+(1-keep)*out.bitmapData[p+c]);
        }
    }
}
static void exportReadingOrToss(NSURL *dir,NSURL *artDir,PoseTexture *idle,Palette palette,int role) {
    BOOL reading=role==1;
    NSBitmapImageRep *art=sheet([artDir URLByAppendingPathComponent:reading?@"amber-book.png":@"frost-toss.png"]);
    if (art.pixelsWide!=(reading?1322:1312) || art.pixelsHigh!=(reading?1190:1199) ||
        art.bitsPerSample!=8 || art.samplesPerPixel!=4 || art.isPlanar ||
        art.bitmapFormat!=NSBitmapFormatAlphaNonpremultiplied) fail(@"阅读或抛接动作图格式不符");
    NSBitmapImageRep *background=activityBackground(idle,palette,role,reading);
    const int w=(int)background.pixelsWide,h=(int)background.pixelsHigh;
    if (!reading) {
        keepTossShoulder(background,idle.neutralFrame);
        writeBitmap(background,[dir URLByAppendingPathComponent:@"tossDesk.png"]);
    }
    for (int i=0;i<4;i++) @autoreleasepool {
        NSBitmapImageRep *out=bitmap(w,h);
        memcpy(out.bitmapData,background.bitmapData,background.bytesPerRow*h);
        if (reading) {
            begin(out);
            drawReadingPose(art,i);
            [NSGraphicsContext restoreGraphicsState];
        } else {
            NSBitmapImageRep *arm=bitmap(w,h);
            begin(arm);
            drawTossPose(art,i);
            [NSGraphicsContext restoreGraphicsState];
            keepTossShoulder(arm,nil);
            if (i!=2) writeBitmap(arm,[dir URLByAppendingPathComponent:
                [NSString stringWithFormat:@"tossArm%d.png",i+1]]);
            begin(out);
            CGContextDrawImage(NSGraphicsContext.currentContext.CGContext,CGRectMake(0,0,w,h),arm.CGImage);
            [NSGraphicsContext restoreGraphicsState];
        }
        NSString *name=[NSString stringWithFormat:@"%@%d.png",reading?@"book":@"toss",i+1];
        writeBitmap(out,[dir URLByAppendingPathComponent:name]);
    }
    if (!reading) {
        NSBitmapImageRep *cloud=sheet([artDir URLByAppendingPathComponent:@"frost-toy.png"]);
        if (cloud.pixelsWide!=1262 || cloud.pixelsHigh!=1246 || cloud.bitsPerSample!=8 ||
            cloud.samplesPerPixel!=4 || cloud.isPlanar ||
            cloud.bitmapFormat!=NSBitmapFormatAlphaNonpremultiplied) fail(@"云朵玩偶原画格式不符");
        NSBitmapImageRep *toy=bitmap(w,h);
        begin(toy);
        drawActivityPart(cloud,NSMakeRect(0,0,1262,1246),NSMakePoint(626,633),NSMakePoint(300,270),
                         56./690.,0,15,250,nil);
        [NSGraphicsContext restoreGraphicsState];
        writeBitmap(toy,[dir URLByAppendingPathComponent:@"toy.png"]);
    }
}
