#import <Cocoa/Cocoa.h>
#import "statistics_view.h"

static int failures=0;
static void Check(BOOL ok,NSString *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);failures++;}}
static void Fit(NSView *view){
    for(NSView *child in view.subviews){
        Check(NSContainsRect(NSInsetRect(view.bounds,-1,-1),child.frame),@"statistics controls fit their parent");
        if([child isKindOfClass:NSTextField.class]){
            NSTextField *label=(NSTextField *)child;
            NSSize needed=[label.stringValue sizeWithAttributes:@{NSFontAttributeName:label.font}];
            Check(needed.width<=label.bounds.size.width-2,@"statistics label fits without truncation");
        }
    }
}
static void Render(NSView *root,BOOL dark,NSString *path){
    NSAppearance *appearance=[NSAppearance appearanceNamed:dark?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];
    NSWindow *w=[[NSWindow alloc] initWithContentRect:root.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.appearance=appearance;w.contentView=root;root.appearance=appearance;
    [root layoutSubtreeIfNeeded];[w displayIfNeeded];
    [appearance performAsCurrentDrawingAppearance:^{
        root.wantsLayer=YES;root.layer.backgroundColor=NSColor.windowBackgroundColor.CGColor;
        NSSize size=root.bounds.size;
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)size.width pixelsHigh:(NSInteger)size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size=size;NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=context;
        [root displayRectIgnoringOpacity:root.bounds inContext:context];[context flushGraphics];[NSGraphicsContext restoreGraphicsState];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    }];
    [w orderOut:nil];
}
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSDate *now=[[NSISO8601DateFormatter new] dateFromString:@"2026-01-08T12:00:00Z"];
    NSMutableArray *samples=[NSMutableArray array],*solar=[NSMutableArray array];
    for(int i=0;i<72;i++){
        NSDate *t=[now dateByAddingTimeInterval:-i*300-60];
        if(i>30&&i<35)continue;
        [samples addObject:@{@"t":t,@"supplyW":i%2?@1800:@-1200,@"chargeW":@3200}];
        [solar addObject:[[EBFroniusPVInterval alloc] initWithDeviceID:@"synthetic-inverter" deviceType:nil anchor:t spanSeconds:300 energyWh:250]];
    }
    NSDictionary *doc=EBStatisticsMerge(nil,@"synthetic-source",samples,solar,now,nil);
    EBStatisticsReport *report=EBStatisticsSummarize(doc,now,[NSTimeZone timeZoneForSecondsFromGMT:0]);
    [NSFileManager.defaultManager createDirectoryAtPath:@"build/statistics-render" withIntermediateDirectories:YES attributes:nil error:nil];
    for(NSNumber *d in @[@NO,@YES])for(NSString *state in @[@"day",@"week",@"empty",@"error"]){
        EBStatisticsReport *shown=report;
        if([state isEqual:@"empty"])shown=EBStatisticsSummarize(@{},now,[NSTimeZone timeZoneForSecondsFromGMT:0]);
        if([state isEqual:@"error"]){shown=[EBStatisticsReport new];shown.error=@"History was preserved after a read failure.";}
        NSAlert *alert=EBBuildStatisticsAlert(shown);[alert layout];
        EBStatisticsView *view=(EBStatisticsView *)alert.accessoryView;
        if([state isEqual:@"week"]){view.periodControl.selectedSegment=1;[view.periodControl sendAction:view.periodControl.action to:view.periodControl.target];}
        Check(view.values.count==4&&view.coverages.count==4,@"four aligned metrics");
        Check(!view.nextButton.enabled,@"cannot navigate into future");
        Fit(view);
        if([state isEqual:@"day"]){
            Check([view.values[0].stringValue hasPrefix:@"≥"],@"archive uses lower-bound marker");
            Check([view.values[1].stringValue hasPrefix:@"~"],@"power integration uses approximation marker");
            NSString *first=view.values[1].stringValue;
            [view.previousButton performClick:nil];Check(view.nextButton.enabled,@"previous day enables next");
            [view.nextButton performClick:nil];Check([view.values[1].stringValue isEqual:first],@"returning to day reuses prepared values");
        }
        if([state isEqual:@"empty"])Check([view.values[0].stringValue isEqual:@"—"],@"empty is unavailable not zero");
        NSString *path=[NSString stringWithFormat:@"build/statistics-render/%@-%@.png",state,d.boolValue?@"dark":@"light"];
        Render(alert.window.contentView,d.boolValue,path);
    }
    printf("statistics view: %s; eight offscreen renders\n",failures?"FAILED":"layout and navigation checks passed");
    return failures?1:0;
}}
