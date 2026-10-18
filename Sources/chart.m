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
    BOOL known, balanced;
    double carSolar, homeSolar, export_, carGrid, homeGrid, solar;
    double home, car;
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
    NSArray<NSDate *> *_barEdges;
    double _upMax, _downMax, _step;
    NSRect _plot;
    CGFloat _zeroY;
    BOOL _solarSuppressed, _homeSuppressed, _carSuppressed;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _windowSeconds = 24 * 3600;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityButtonRole;
        self.accessibilityHelp = @"Click an interval for its power readings. VoiceOver press opens the latest interval.";
    }
    return self;
}

- (void)dealloc { free(_bars); }

- (BOOL)isFlipped { return NO; }

- (void)setForecast:(EBPowerForecast *)forecast {
    _forecast = forecast; _solarSuppressed = _homeSuppressed = _carSuppressed = NO; [self rebuild];
}
- (void)suppressForecast { _solarSuppressed = _homeSuppressed = _carSuppressed = YES; self.needsDisplay = YES; }
- (void)suppressCarForecast { _carSuppressed = YES; self.needsDisplay = YES; }
- (void)expireForecastAt:(NSDate *)now {
    _solarSuppressed |= !self.forecast.solarValidUntil || [now compare:self.forecast.solarValidUntil] == NSOrderedDescending;
    _homeSuppressed |= !self.forecast.homeValidUntil || [now compare:self.forecast.homeValidUntil] == NSOrderedDescending;
    _carSuppressed |= !self.forecast.carValidUntil || [now compare:self.forecast.carValidUntil] == NSOrderedDescending;
    self.needsDisplay = YES;
}
// Preserve the future time axis even when every projected component is unavailable.
- (BOOL)hasForecast { return self.forecast.asOf != nil; }
- (NSDate *)observationDate { return self.referenceDate ?: self.forecast.asOf ?: [NSDate date]; }
- (NSDate *)displayEnd {
    NSDate *now = [self observationDate];
    if (self.windowSeconds <= 24*3600) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        return [calendar dateByAddingUnit:NSCalendarUnitDay value:1
                                  toDate:[calendar startOfDayForDate:now] options:0];
    }
    return [self hasForecast] ? [now dateByAddingTimeInterval:12*3600] : now;
}
- (NSDate *)displayStart {
    return self.windowSeconds <= 24*3600
        ? [NSCalendar.currentCalendar startOfDayForDate:[self observationDate]]
        : [[self displayEnd] dateByAddingTimeInterval:-self.windowSeconds];
}
- (NSTimeInterval)displayDuration { return [[self displayEnd] timeIntervalSinceDate:[self displayStart]]; }
- (NSInteger)barIndexForDate:(NSDate *)date {
    for (NSInteger i = 0; i < _nBars; i++)
        if ([date compare:_barEdges[i]] != NSOrderedAscending &&
            [date compare:_barEdges[i+1]] == NSOrderedAscending) return i;
    return NSNotFound;
}

- (void)setSamples:(NSArray<NSDictionary *> *)samples {
    _samples = [samples copy];
    [self rebuild];
}

- (void)setWindowSeconds:(NSTimeInterval)windowSeconds {
    _windowSeconds = windowSeconds > 0 ? windowSeconds : 24 * 3600;
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

/// Approximately half-hour bars for Today, 45-minute bars over 48 h.
/// Split the current interval at Now so a measured bar never extends into the future.
- (NSInteger)barCount { return self.windowSeconds > 24 * 3600 ? 64 : 48; }

- (NSRect)plotRect {
    NSRect b = self.bounds;
    // Gutter fits a single "10.5 kW" label. The time axis keeps the bottom 16pt.
    CGFloat axisH = 16, gutter = 52;
    // Reserve breathing room for the Now divider and the forecast-region label.
    return NSMakeRect(b.origin.x + gutter, b.origin.y + axisH, b.size.width - gutter, b.size.height - axisH - 18);
}

- (void)rebuild {
    free(_bars);
    NSDate *start = [self displayStart], *end = [self displayEnd], *observed = [self observationDate];
    NSInteger count = [self barCount];
    NSTimeInterval duration = [end timeIntervalSinceDate:start], barSec = duration / count;
    NSMutableArray *edges = [NSMutableArray arrayWithCapacity:(NSUInteger)count+2];
    for (NSInteger i = 0; i <= count; i++) {
        NSDate *edge = [start dateByAddingTimeInterval:i*barSec];
        if (i > 0 && [observed timeIntervalSinceDate:edges.lastObject] > 0.01 &&
            [edge timeIntervalSinceDate:observed] > 0.01) [edges addObject:observed];
        [edges addObject:edge];
    }
    _barEdges = edges; _nBars = (NSInteger)edges.count - 1;
    _bars = calloc((size_t)_nBars, sizeof(EBBar));
    [self removeAllToolTips];
    _upMax = _downMax = 0;
    if (!_bars) { _nBars = 0; return; }
    NSMutableArray<NSMutableArray *> *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)_nBars];
    for (NSInteger i = 0; i < _nBars; i++) [rows addObject:[NSMutableArray array]];
    for (NSDictionary *row in self.samples) {
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class]) continue;
        // Timestamped observations cannot fill any part of the future region.
        if ([t compare:observed] != NSOrderedAscending) continue;
        NSInteger index = [self barIndexForDate:t];
        if (index != NSNotFound) [rows[(NSUInteger)index] addObject:row];
    }
    for (NSInteger i = 0; i < _nBars; i++) {
        EBChartSeriesAverages v = EBStoreChartSeriesAverages(rows[(NSUInteger)i]);
        if (v.supplySampleCount == 0) continue;
        EBBar *bar = &_bars[i];
        bar->known = bar->balanced = YES;
        bar->carSolar = v.carSolarW;
        bar->homeSolar = v.homeSolarW;
        bar->export_ = v.unusedSurplusW;
        bar->carGrid = v.carGridW;
        bar->homeGrid = v.homeGridW;
        bar->solar = v.pvSampleCount ? v.solarW : -1;
        bar->home = v.homeSolarW + v.homeGridW;
        bar->car = v.carSolarW + v.carGridW;
        _upMax = fmax(_upMax, bar->carSolar + bar->homeSolar + bar->export_);
        _downMax = fmax(_downMax, bar->carGrid + bar->homeGrid);
    }
    if ([self hasForecast]) for (NSInteger i = 0; i < _nBars; i++) {
        NSDate *a = _barEdges[i], *b = _barEdges[i+1];
        if ([a compare:[self observationDate]] == NSOrderedAscending) continue;
        NSDictionary *v = EBForecastAverage(self.forecast.rows, a, b);
        if (!v) continue;
        EBBar *bar = &_bars[i]; bar->known = v.count > 0;
        bar->balanced = v[@"supplyW"] != nil;
        bar->carSolar = [v[@"carSolarW"] doubleValue]; bar->homeSolar = [v[@"homeSolarW"] doubleValue];
        bar->export_ = [v[@"exportW"] doubleValue]; bar->carGrid = [v[@"carGridW"] doubleValue];
        bar->homeGrid = [v[@"homeGridW"] doubleValue];
        bar->solar = v[@"pvW"] ? [v[@"pvW"] doubleValue] : -1;
        bar->home = v[@"homeW"] ? [v[@"homeW"] doubleValue] : -1;
        bar->car = v[@"chargeW"] ? [v[@"chargeW"] doubleValue] : -1;
        _upMax = fmax(_upMax, fmax(bar->solar, bar->carSolar + bar->homeSolar + bar->export_));
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
        ? [NSString stringWithFormat:@"%.0f-hour power %@. Solar above zero, grid import below zero. Shared scale: %.1f kW solar to minus %.1f kW import. Gaps have no data. %@",
           duration / 3600, [self hasForecast] ? @"history and forecast" : @"history", _upMax / 1000, _downMax / 1000,
           [self hasForecast] ? @"Solid bars are measured; softly filled bars after Now are forecasts. Partial forecasts show solar only; home and any known car load are in interval details." : @""]
        : ([self hasForecast] ? @"No power data. Forecast inputs unavailable; the future window remains after Now." : @"No power history yet");
    self.needsDisplay = YES;
}

- (NSString *)detailsForBar:(NSInteger)i {
    if (i < 0 || i >= _nBars) return nil;
    NSDate *barStart = _barEdges[i], *barEnd = _barEdges[i+1];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = self.windowSeconds > 24 * 3600 ? @"EEE d MMM HH:mm" : @"HH:mm";
    NSString *span = [NSString stringWithFormat:@"%@–%@",
                      [df stringFromDate:barStart], [df stringFromDate:barEnd]];
    BOOL projected = [self hasForecast] && [barStart compare:[self observationDate]] != NSOrderedAscending;
    if (projected) {
        EBBar b = _bars[i];
        BOOL solar = b.known && b.solar >= 0 && !_solarSuppressed;
        BOOL home = b.known && b.home >= 0 && !_homeSuppressed;
        BOOL car = b.known && b.car >= 0 && !_carSuppressed;
        BOOL grid = b.balanced && solar && home && car;
        NSMutableArray *lines = [NSMutableArray arrayWithObjects:@"Forecast", span, @"Average power · kW", nil];
        [lines addObject:solar ? [NSString stringWithFormat:@"Solar %.1f kW", b.solar / 1000] : @"Solar — unavailable"];
        [lines addObject:home ? [NSString stringWithFormat:@"Home %.1f kW", b.home / 1000] : @"Home — unavailable"];
        [lines addObject:car ? [NSString stringWithFormat:@"Car %.1f kW", b.car / 1000] : @"Car — unavailable"];
        [lines addObject:grid ? [NSString stringWithFormat:@"Export %.1f kW", b.export_ / 1000] : @"Export — unavailable"];
        [lines addObject:grid ? [NSString stringWithFormat:@"Import %.1f kW", (b.carGrid + b.homeGrid) / 1000] : @"Import — unavailable"];
        NSDictionary *r = EBForecastAverage(self.forecast.rows, barStart, barEnd);
        if (solar) [lines addObject:[NSString stringWithFormat:@"Solar scenario range %.1f–%.1f kW", [r[@"pvLowW"] doubleValue]/1000, [r[@"pvHighW"] doubleValue]/1000]];
        if (car && self.forecast.carFinishesAt) [lines addObject:[NSString stringWithFormat:@"Car stops at ~%@ at the current rate",[df stringFromDate:self.forecast.carFinishesAt]]];
        if (_solarSuppressed || _homeSuppressed || _carSuppressed) [lines addObject:@"Expired components are unavailable; other projections retain their own source clocks."];
        [lines addObject:self.forecast.detail];
        return [lines componentsJoinedByString:@"\n"];
    }
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

- (void)showBarDetails:(NSInteger)i {
    NSString *detail = [self detailsForBar:i];
    if (!detail.length) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Power readings";
    alert.informativeText = detail;
    [alert runModal];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, _plot) || _nBars <= 0) return;
    NSDate *date = [[self displayStart] dateByAddingTimeInterval:
        (p.x - _plot.origin.x) / _plot.size.width * [self displayDuration]];
    NSInteger i = [self barIndexForDate:date];
    if (i != NSNotFound) [self showBarDetails:i];
}

- (BOOL)accessibilityPerformPress {
    if (_nBars <= 0) return NO;
    [self showBarDetails:_nBars - 1];
    return YES;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSDictionary *lab = EBChartLabelAttrs();
    NSRect plot = _plot;
    __block NSColor *carSolar = nil, *carGrid = nil, *exportCol = nil, *home = nil;
    __block NSColor *solarInk = nil, *solarColor = nil, *importInk = nil, *homeImport = nil;
    __block CGFloat forecastOpacity = 0.42;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        forecastOpacity = EBAppearanceIsDark() ? 0.60 : 0.42;
        carSolar = EBColorCarOnSolar();
        carGrid = EBColorCarOnGrid();
        homeImport = [carGrid colorWithAlphaComponent:0.45];
        exportCol = EBColorExport();
        home = EBColorHome();
        solarInk = EBInkSurplus(); solarColor = EBColorSurplus();
        importInk = EBInkCarOnGrid();
    }];
    BOOL any = NO;
    for (NSInteger i = 0; i < _nBars; i++) any = any || _bars[i].known;

    double total = _upMax + _downMax;
    CGFloat (^h)(double) = ^CGFloat(double w) { return (CGFloat)(w / total) * plot.size.height; };

    CGFloat nowX = plot.origin.x + [[self observationDate] timeIntervalSinceDate:[self displayStart]]
        / [self displayDuration] * plot.size.width;
    nowX = fmax(NSMinX(plot), fmin(NSMaxX(plot), nowX));
    if ([self hasForecast]) {
        // One quiet field identifies future time without striping missing components.
        [[NSColor.labelColor colorWithAlphaComponent:0.025] setFill];
        NSRectFillUsingOperation(NSMakeRect(nowX, NSMinY(plot), NSMaxX(plot)-nowX, NSHeight(plot)),
                                 NSCompositingOperationSourceOver);
    }
    // At most two interior guides in either direction; the data carries the detail.
    double step = _step * fmax(1, ceil(fmax(_upMax, _downMax) / (_step * 3)));
    [[NSColor.labelColor colorWithAlphaComponent:0.055] setFill];
    if (any) {
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, NSMaxY(plot)-0.5, plot.size.width, 0.5), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, NSMinY(plot), plot.size.width, 0.5), NSCompositingOperationSourceOver);
    }
    for (double kw = step; any && kw < _upMax; kw += step)
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, _zeroY+h(kw), plot.size.width, 0.5), NSCompositingOperationSourceOver);
    for (double kw = step; any && kw < _downMax; kw += step)
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, _zeroY-h(kw), plot.size.width, 0.5), NSCompositingOperationSourceOver);

    void (^projectedBar)(NSRect, NSColor *, BOOL) = ^(NSRect rect, NSColor *color, BOOL upwards) {
        [[color colorWithAlphaComponent:color.alphaComponent * forecastOpacity] setFill];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
        // A small cap keeps forecast magnitude legible without boxing every bar.
        [[color colorWithAlphaComponent:color.alphaComponent * 0.75] setFill];
        CGFloat capHeight = fmin(0.75, NSHeight(rect));
        CGFloat capY = upwards ? NSMaxY(rect)-capHeight : NSMinY(rect);
        NSRectFillUsingOperation(NSMakeRect(NSMinX(rect), capY, NSWidth(rect), capHeight), NSCompositingOperationSourceOver);
    };

    NSDate *displayStart = [self displayStart];
    NSTimeInterval duration = [self displayDuration];
    for (NSInteger i = 0; i < _nBars; i++) {
        EBBar b = _bars[i];
        double barStart = _barEdges[i].timeIntervalSince1970;
        CGFloat slot = [_barEdges[i+1] timeIntervalSinceDate:_barEdges[i]] / duration * plot.size.width;
        CGFloat barW = fmax(0, slot - fmin(1, slot / 4));
        BOOL forecast = [self hasForecast] && barStart >= [self observationDate].timeIntervalSince1970 - 0.01;
        BOOL partial = forecast && (!b.balanced || _solarSuppressed || _homeSuppressed || _carSuppressed);
        if (partial) b.known = NO;
        CGFloat x = plot.origin.x + [_barEdges[i] timeIntervalSinceDate:displayStart] / duration * plot.size.width;
        if (!b.known) {
            if (!any && ![self hasForecast]) continue;
            // Missing history stays a faint gap. Future unknowns use the shared field,
            // never zero-height values or a fabricated balanced allocation.
            if (!forecast) {
                [[NSColor.labelColor colorWithAlphaComponent:0.025] setFill];
                NSRectFillUsingOperation(NSMakeRect(x, plot.origin.y, slot, plot.size.height), NSCompositingOperationSourceOver);
            }
            if (partial && _bars[i].known && b.solar >= 0 && !_solarSuppressed) {
                NSRect solarRect = NSMakeRect(x, _zeroY + 0.5, barW, h(b.solar));
                projectedBar(solarRect, solarColor, YES);
            }
            continue;
        }
        CGFloat y = _zeroY + 0.5;
        // Up: where the solar went (car nearest the line, then home, then export).
        for (int k = 0; k < 3; k++) {
            double w = k == 0 ? b.carSolar : (k == 1 ? b.homeSolar : b.export_);
            NSColor *c = k == 0 ? carSolar : (k == 1 ? home : exportCol);
            CGFloat hh = h(w);
            if (hh < 0.5) continue;
            NSRect rect = NSMakeRect(x, y, barW, hh);
            if (forecast) projectedBar(rect, c, YES);
            else { [c setFill]; NSRectFill(rect); }
            y += hh;
        }
        // Down: everything here is grid import, so it is red (shared spec). The car's share is
        // solid nearest the line, the home's the same red at reduced weight; the selected interval details split it.
        y = _zeroY - 0.5;
        for (int k = 0; k < 2; k++) {
            double w = k == 0 ? b.carGrid : b.homeGrid;
            CGFloat hh = h(w);
            if (hh < 0.5) continue;
            NSColor *color = k == 0 ? carGrid : homeImport;
            NSRect rect = NSMakeRect(x, y - hh, barW, hh);
            if (forecast) projectedBar(rect, color, NO);
            else {
                [color setFill];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
            }
            y -= hh;
        }
    }

    if (any) {
        [[NSColor.labelColor colorWithAlphaComponent:0.40] setFill];
        NSRectFillUsingOperation(NSMakeRect(plot.origin.x, _zeroY-0.375, plot.size.width, 0.75), NSCompositingOperationSourceOver);
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
        NSString *msg = [self hasForecast] ? @"no power data" : @"no history yet";
        NSSize sz = [msg sizeWithAttributes:lab];
        [msg drawAtPoint:NSMakePoint(NSMidX(plot) - sz.width / 2, NSMidY(plot)) withAttributes:lab];
    }

    // Six-hour labels keep Today legible; the 48-hour view labels every twelve hours.
    NSDate *now = [self displayEnd];
    NSDate *start = [self displayStart];
    NSInteger stepHours = self.windowSeconds > 24 * 3600 ? 12 : 6;
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
        if (off >= 0 && (any || [self hasForecast])) {
            CGFloat x = plot.origin.x + (CGFloat)(off / duration) * plot.size.width;
            // 48 h: midnight names the day, noon says 12:00, so neighbours never collide.
            BOOL midnight = [cal component:NSCalendarUnitHour fromDate:tick] == 0;
            NSString *t = (stepHours == 12 && midnight) ? [dayF stringFromDate:tick] : [df stringFromDate:tick];
            NSSize sz = [t sizeWithAttributes:lab];
            CGFloat tx = MIN(NSMaxX(plot) - sz.width, MAX(plot.origin.x, x - sz.width / 2));
            [t drawAtPoint:NSMakePoint(tx, self.bounds.origin.y) withAttributes:lab];
            [[NSColor.labelColor colorWithAlphaComponent:0.035] setFill];
            NSRectFillUsingOperation(NSMakeRect(x, plot.origin.y, 0.5, plot.size.height),
                                     NSCompositingOperationSourceOver);
        }
        if (self.windowSeconds <= 24*3600) {
            // Local-clock ticks stay at 00/06/12/18 across a DST transition.
            comps.hour += stepHours;
            tick = [cal dateFromComponents:comps];
        } else tick = [cal dateByAddingUnit:NSCalendarUnitHour value:stepHours toDate:tick options:0];
    }
    if (self.windowSeconds <= 24*3600 && (any || [self hasForecast])) {
        NSString *endLabel=@"24:00";
        [endLabel drawAtPoint:NSMakePoint(NSMaxX(plot)-[endLabel sizeWithAttributes:lab].width, self.bounds.origin.y) withAttributes:lab];
    }
    if ([self hasForecast]) {
        CGFloat nx = nowX;
        NSBezierPath *boundary = [NSBezierPath bezierPath];
        [boundary moveToPoint:NSMakePoint(nx, plot.origin.y)];
        [boundary lineToPoint:NSMakePoint(nx, NSMaxY(plot))];
        CGFloat dash[] = {2, 3}; [boundary setLineDash:dash count:2 phase:0];
        boundary.lineWidth = 0.75; [[NSColor.labelColor colorWithAlphaComponent:0.45] setStroke]; [boundary stroke];
        NSDictionary *small = @{NSFontAttributeName:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium],
                                NSForegroundColorAttributeName:EBInkSecondary()};
        NSString *label = @"Now";
        CGFloat nowWidth = [label sizeWithAttributes:small].width;
        CGFloat labelX = fmax(plot.origin.x, fmin(NSMaxX(plot)-nowWidth, nx-nowWidth/2));
        [label drawAtPoint:NSMakePoint(labelX, NSMaxY(plot)+5) withAttributes:small];
        CGFloat forecastWidth = [@"Forecast" sizeWithAttributes:small].width;
        CGFloat forecastX = (nx+NSMaxX(plot)-forecastWidth)/2;
        if (forecastX >= labelX+nowWidth+12 && forecastX+forecastWidth <= NSMaxX(plot))
            [@"Forecast" drawAtPoint:NSMakePoint(forecastX, NSMaxY(plot)+5) withAttributes:small];
    }

}

@end
