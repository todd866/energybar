#import "chart.h"
#import "store.h"
#import <math.h>

const NSTimeInterval EBChartGapSeconds = 360.0;

static BOOL EBAppearanceIsDark(void) {
    NSAppearance *a = NSAppearance.currentDrawingAppearance;
    return [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
        == NSAppearanceNameDarkAqua;
}

NSColor *EBColorSurplus(void) {
    return EBAppearanceIsDark()
        ? [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.10 alpha:1.0]
        : [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.00 alpha:1.0];
}

NSColor *EBColorExport(void) {
    return EBAppearanceIsDark()
        ? [NSColor colorWithSRGBRed:0.30 green:0.82 blue:0.45 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.13 green:0.58 blue:0.26 alpha:1.0];
}

NSColor *EBColorCarOnSolar(void) {
    return EBAppearanceIsDark()
        ? [NSColor colorWithSRGBRed:0.25 green:0.60 blue:1.00 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.15 green:0.45 blue:0.95 alpha:1.0];
}

NSColor *EBColorCarOnGrid(void) {
    return EBAppearanceIsDark()
        ? [NSColor colorWithSRGBRed:0.95 green:0.30 blue:0.28 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.88 green:0.18 blue:0.15 alpha:1.0];
}

static NSColor *EBInk(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            == NSAppearanceNameDarkAqua;
        return dark ? [NSColor colorWithSRGBRed:dr green:dg blue:db alpha:1]
                    : [NSColor colorWithSRGBRed:lr green:lg blue:lb alpha:1];
    }];
}
NSColor *EBInkSurplus(void) { return EBInk(0.70, 0.36, 0.00, 1.00, 0.62, 0.20); }
NSColor *EBInkExport(void) { return EBInk(0.05, 0.40, 0.14, 0.45, 0.90, 0.55); }
NSColor *EBInkCarOnSolar(void) { return EBInk(0.10, 0.36, 0.85, 0.40, 0.68, 1.00); }
NSColor *EBInkCarOnGrid(void) { return EBInk(0.78, 0.12, 0.10, 1.00, 0.47, 0.45); }
NSColor *EBInkBattery(void) { return EBInk(0.10, 0.50, 0.20, 0.30, 0.82, 0.40); }
NSColor *EBInkStale(void) { return EBInk(0.52, 0.36, 0.00, 1.00, 0.78, 0.35); }
NSColor *EBInkSecondary(void) { return EBInk(0.32, 0.32, 0.32, 0.70, 0.70, 0.70); }

static NSColor *EBColorHome(void) {
    return EBAppearanceIsDark()
        ? [NSColor colorWithSRGBRed:0.56 green:0.56 blue:0.58 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.62 green:0.62 blue:0.64 alpha:1.0];
}

static NSDictionary *EBChartLabelAttrs(void) {
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: EBInkSecondary(),
    };
}

@implementation EBChartLegend
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"Solar use above the line, grid import below in red (solid for the car, light for the home). Blue car, grey home, green export.";
    }
    return self;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    __block NSArray *items = nil;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        // These are the three destinations above zero. Import is labelled
        // directly on the red half of the axis, rather than repeated here.
        items = @[@[EBColorCarOnSolar(), @"Car"],
                  @[EBColorHome(), @"Home"],
                  @[EBColorExport(), @"Export"]];
    }];
    NSDictionary *attrs = EBChartLabelAttrs();
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:self.bounds] addClip];
    CGFloat x = 0, mid = NSMidY(self.bounds);
    for (NSArray *it in items) {
        [(NSColor *)it[0] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, mid - 4, 8, 8) xRadius:2 yRadius:2] fill];
        NSString *name = it[1];
        NSSize sz = [name sizeWithAttributes:attrs];
        [name drawAtPoint:NSMakePoint(x + 12, mid - sz.height / 2) withAttributes:attrs];
        x += 12 + sz.width + 10;
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

typedef struct {
    BOOL known;
    double carSolar, homeSolar, export_, carGrid, homeGrid, solar;
} EBBar;

EBChartScale EBChartMakeScale(double solarPeakW, double importPeakW) {
    double up = isfinite(solarPeakW) ? fmax(0, solarPeakW) : 0;
    double down = isfinite(importPeakW) ? fmax(0, importPeakW) : 0;
    // Round to familiar values, without magnifying a few watts of standby.
    double target = fmax(1000, up + down) / 5;
    double decade = pow(10, floor(log10(target)));
    double relative = target / decade;
    double step = decade * (relative >= 5 ? 5 : (relative >= 2 ? 2 : 1));
    double largest = fmax(up, down);
    up = fmax(500, fmax(up, largest * 0.40));
    down = fmax(500, fmax(down, largest * 0.40));
    return (EBChartScale){ceil(up / step) * step, ceil(down / step) * step, step};
}

@implementation EBChartView {
    EBBar *_bars;
    NSInteger _nBars;
    double _upMax, _downMax, _step;
    NSRect _plot;
    CGFloat _zeroY;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _windowSeconds = 12 * 3600;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
    }
    return self;
}

- (void)dealloc { free(_bars); }

- (BOOL)isFlipped { return NO; }

- (void)setSamples:(NSArray<NSDictionary *> *)samples {
    _samples = [samples copy];
    [self rebuild];
}

- (void)setWindowSeconds:(NSTimeInterval)windowSeconds {
    _windowSeconds = windowSeconds > 0 ? windowSeconds : 12 * 3600;
    [self rebuild];
}

- (void)setReferenceDate:(NSDate *)referenceDate {
    _referenceDate = [referenceDate copy];
    [self rebuild];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self rebuild];
}

/// 15-minute bars over 12 h, 45-minute bars over 48 h.
- (NSInteger)barCount { return self.windowSeconds > 24 * 3600 ? 64 : 48; }

- (NSRect)plotRect {
    NSRect b = self.bounds;
    // Gutter fits a single "10.5 kW" label. The time axis keeps the bottom 16pt.
    CGFloat axisH = 16, gutter = 52;
    // Half a label above the plot lets the top value sit on its actual gridline.
    return NSMakeRect(b.origin.x + gutter, b.origin.y + axisH, b.size.width - gutter, b.size.height - axisH - 8);
}

- (void)rebuild {
    free(_bars);
    _nBars = [self barCount];
    _bars = calloc((size_t)_nBars, sizeof(EBBar));
    [self removeAllToolTips];
    _upMax = _downMax = 0;
    if (!_bars) { _nBars = 0; return; }
    NSDate *now = self.referenceDate ?: [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-self.windowSeconds];
    NSTimeInterval barSec = self.windowSeconds / _nBars;
    NSMutableArray<NSMutableArray *> *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)_nBars];
    for (NSInteger i = 0; i < _nBars; i++) [rows addObject:[NSMutableArray array]];
    for (NSDictionary *row in self.samples) {
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class]) continue;
        NSTimeInterval off = [t timeIntervalSinceDate:start];
        if (off < 0 || off >= self.windowSeconds) continue;
        [rows[(NSUInteger)MIN(_nBars - 1, (NSInteger)(off / barSec))] addObject:row];
    }
    for (NSInteger i = 0; i < _nBars; i++) {
        EBChartSeriesAverages v = EBStoreChartSeriesAverages(rows[(NSUInteger)i]);
        if (v.supplySampleCount == 0) continue;
        EBBar *bar = &_bars[i];
        bar->known = YES;
        bar->carSolar = v.carSolarW;
        bar->homeSolar = v.homeSolarW;
        bar->export_ = v.unusedSurplusW;
        bar->carGrid = v.carGridW;
        bar->homeGrid = v.homeGridW;
        bar->solar = v.pvSampleCount ? v.solarW : -1;
        _upMax = fmax(_upMax, bar->carSolar + bar->homeSolar + bar->export_);
        _downMax = fmax(_downMax, bar->carGrid + bar->homeGrid);
    }
    EBChartScale scale = EBChartMakeScale(_upMax, _downMax);
    _upMax = scale.solarW;
    _downMax = scale.importW;
    _step = scale.stepW;
    _plot = [self plotRect];
    double total = _upMax + _downMax;
    _zeroY = _plot.origin.y + (CGFloat)(_downMax / total) * _plot.size.height;
    BOOL anyKnown = NO;
    for (NSInteger i = 0; i < _nBars; i++) anyKnown = anyKnown || _bars[i].known;
    self.accessibilityLabel = anyKnown
        ? [NSString stringWithFormat:@"%.0f-hour power history. Solar above zero, grid import below zero. Shared scale: %.1f kW solar to minus %.1f kW import. Hatched areas have no data.",
           self.windowSeconds / 3600, _upMax / 1000, _downMax / 1000]
        : @"No power history yet";
    CGFloat slot = _plot.size.width / _nBars;
    for (NSInteger i = 0; i < _nBars; i++) {
        if (!_bars[i].known && !anyKnown) continue;
        [self addToolTipRect:NSMakeRect(_plot.origin.x + i * slot, _plot.origin.y, slot, _plot.size.height)
                       owner:self userData:(void *)(intptr_t)i];
    }
    self.needsDisplay = YES;
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view; (void)tag; (void)point;
    NSInteger i = (NSInteger)(intptr_t)data;
    if (i < 0 || i >= _nBars) return nil;
    NSDate *now = self.referenceDate ?: [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-self.windowSeconds];
    NSTimeInterval barSec = self.windowSeconds / _nBars;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = self.windowSeconds > 24 * 3600 ? @"EEE d MMM HH:mm" : @"HH:mm";
    NSString *span = [NSString stringWithFormat:@"%@–%@",
                      [df stringFromDate:[start dateByAddingTimeInterval:i * barSec]],
                      [df stringFromDate:[start dateByAddingTimeInterval:(i + 1) * barSec]]];
    if (!_bars[i].known) return [NSString stringWithFormat:@"%@\nno data", span];
    EBBar b = _bars[i];
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:span, @"Average power · kW", nil];
    if (b.solar >= 0) [lines addObject:[NSString stringWithFormat:@"Solar %.1f kW", b.solar / 1000]];
    [lines addObject:[NSString stringWithFormat:@"Car %.1f kW (solar %.1f · grid %.1f)",
                      (b.carSolar + b.carGrid) / 1000, b.carSolar / 1000, b.carGrid / 1000]];
    [lines addObject:[NSString stringWithFormat:@"Home %.1f kW (solar %.1f · grid %.1f)",
                      (b.homeSolar + b.homeGrid) / 1000, b.homeSolar / 1000, b.homeGrid / 1000]];
    [lines addObject:[NSString stringWithFormat:@"Export %.1f kW", b.export_ / 1000]];
    [lines addObject:[NSString stringWithFormat:@"Import %.1f kW", (b.carGrid + b.homeGrid) / 1000]];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSDictionary *lab = EBChartLabelAttrs();
    NSRect plot = _plot;
    __block NSColor *carSolar = nil, *carGrid = nil, *exportCol = nil, *home = nil;
    __block NSColor *solarInk = nil, *importInk = nil, *homeImport = nil;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        carSolar = EBColorCarOnSolar();
        carGrid = EBColorCarOnGrid();
        homeImport = [carGrid colorWithAlphaComponent:0.45];
        exportCol = EBColorExport();
        home = EBColorHome();
        solarInk = EBInkSurplus();
        importInk = EBInkCarOnGrid();
    }];
    BOOL any = NO;
    for (NSInteger i = 0; i < _nBars; i++) any = any || _bars[i].known;

    double total = _upMax + _downMax;
    CGFloat (^h)(double) = ^CGFloat(double w) { return (CGFloat)(w / total) * plot.size.height; };

    // Recessive gridlines at round kW steps on the shared scale.
    double step = _step;
    // Recessive: NSRectFill copies and would drop the alpha, so composite over.
    [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
    if (any) {
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, NSMaxY(plot) - 0.5, plot.size.width, 0.5),
                                 NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, NSMinY(plot), plot.size.width, 0.5),
                                 NSCompositingOperationSourceOver);
    }
    for (double kw = step; any && kw < _upMax; kw += step)
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, _zeroY + h(kw), plot.size.width, 1),
                                 NSCompositingOperationSourceOver);
    for (double kw = step; any && kw < _downMax; kw += step)
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, _zeroY - h(kw), plot.size.width, 1),
                                 NSCompositingOperationSourceOver);

    CGFloat slot = plot.size.width / MAX(1, _nBars);
    CGFloat barW = MAX(1, slot - 1);
    for (NSInteger i = 0; i < _nBars; i++) {
        EBBar b = _bars[i];
        CGFloat x = plot.origin.x + i * slot;
        if (!b.known) {
            if (!any) continue;
            NSRect band = NSMakeRect(x, plot.origin.y, barW, plot.size.height);
            [[NSColor.labelColor colorWithAlphaComponent:0.05] setFill];
            NSRectFillUsingOperation(band, NSCompositingOperationSourceOver);
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithRect:band] addClip];
            NSBezierPath *hatch = [NSBezierPath bezierPath];
            hatch.lineWidth = 1;
            [[NSColor.labelColor colorWithAlphaComponent:0.16] setStroke];
            for (CGFloat d = -band.size.height; d < band.size.width + band.size.height; d += 5) {
                [hatch moveToPoint:NSMakePoint(NSMinX(band) + d, NSMinY(band))];
                [hatch lineToPoint:NSMakePoint(NSMinX(band) + d + band.size.height, NSMaxY(band))];
            }
            [hatch stroke];
            [NSGraphicsContext restoreGraphicsState];
            continue;
        }
        CGFloat y = _zeroY + 0.5;
        // Up: where the solar went (car nearest the line, then home, then export).
        for (int k = 0; k < 3; k++) {
            double w = k == 0 ? b.carSolar : (k == 1 ? b.homeSolar : b.export_);
            NSColor *c = k == 0 ? carSolar : (k == 1 ? home : exportCol);
            CGFloat hh = h(w);
            if (hh < 0.5) continue;
            [c setFill];
            NSRectFill(NSMakeRect(x, y, barW, hh));
            y += hh;
        }
        // Down: everything here is grid import, so it is red (shared spec). The car's share is
        // solid nearest the line, the home's the same red at reduced weight; the tooltip splits it.
        y = _zeroY - 0.5;
        for (int k = 0; k < 2; k++) {
            double w = k == 0 ? b.carGrid : b.homeGrid;
            CGFloat hh = h(w);
            if (hh < 0.5) continue;
            [(k == 0 ? carGrid : homeImport) setFill];
            NSRectFillUsingOperation(NSMakeRect(x, y - hh, barW, hh), NSCompositingOperationSourceOver);
            y -= hh;
        }
    }

    if (any) {
        [NSColor.labelColor setFill];
        NSRectFill(NSMakeRect(plot.origin.x, _zeroY - 0.5, plot.size.width, 1));
    }

    // The gutter names both halves. Signed, rounded limits and an explicit zero
    // distinguish the scale from a measured peak without another legend row.
    CGFloat gx = plot.origin.x - 6;
    void (^right)(NSString *, CGFloat, NSColor *) = ^(NSString *t, CGFloat y, NSColor *ink) {
        NSDictionary *attrs = @{
            NSFontAttributeName: lab[NSFontAttributeName],
            NSForegroundColorAttributeName: ink ?: lab[NSForegroundColorAttributeName],
        };
        NSSize sz = [t sizeWithAttributes:attrs];
        [t drawAtPoint:NSMakePoint(gx - sz.width, y) withAttributes:attrs];
    };
    if (any) {
        NSString *(^kw)(double) = ^NSString *(double watts) {
            return [NSString stringWithFormat:fmod(watts, 1000) < 0.01 ? @"%.0f kW" : @"%.1f kW", watts / 1000];
        };
        right(kw(_upMax), NSMaxY(plot) - 6, solarInk);
        right(@"Solar", NSMaxY(plot) - 25, solarInk);
        right(@"0", _zeroY - 6, EBInkSecondary());
        right(@"Import", plot.origin.y + 13, importInk);
        right([@"−" stringByAppendingString:kw(_downMax)], plot.origin.y - 6, importInk);
    } else {
        NSString *msg = @"no history yet";
        NSSize sz = [msg sizeWithAttributes:lab];
        [msg drawAtPoint:NSMakePoint(NSMidX(plot) - sz.width / 2, NSMidY(plot)) withAttributes:lab];
    }

    // Hour labels every 3 h (12 h window) or 12 h (48 h window).
    NSDate *now = self.referenceDate ?: [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-self.windowSeconds];
    NSInteger stepHours = self.windowSeconds > 24 * 3600 ? 12 : 3;
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDateComponents *comps = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour
                                     fromDate:start];
    comps.hour = (comps.hour / stepHours) * stepHours;
    NSDate *tick = [cal dateFromComponents:comps];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm";
    NSDateFormatter *dayF = [NSDateFormatter new];
    dayF.dateFormat = @"EEE";
    while (tick && [tick compare:now] == NSOrderedAscending) {
        NSTimeInterval off = [tick timeIntervalSinceDate:start];
        if (off >= 0 && any) {
            CGFloat x = plot.origin.x + (CGFloat)(off / self.windowSeconds) * plot.size.width;
            // 48 h: midnight names the day, noon says 12:00, so neighbours never collide.
            BOOL midnight = [cal component:NSCalendarUnitHour fromDate:tick] == 0;
            NSString *t = (stepHours == 12 && midnight) ? [dayF stringFromDate:tick] : [df stringFromDate:tick];
            NSSize sz = [t sizeWithAttributes:lab];
            CGFloat tx = MIN(NSMaxX(plot) - sz.width, MAX(plot.origin.x, x - sz.width / 2));
            [t drawAtPoint:NSMakePoint(tx, self.bounds.origin.y) withAttributes:lab];
            [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
            NSRectFillUsingOperation(NSMakeRect(x, plot.origin.y, 1, plot.size.height),
                                     NSCompositingOperationSourceOver);
        }
        tick = [cal dateByAddingUnit:NSCalendarUnitHour value:stepHours toDate:tick options:0];
    }
}

@end
