#import "popover.h"
#import "pure.h"
#import "vehicle.h"

@implementation EBSnapshotView
@end

@implementation EBPopoverViews
@end

static NSString *EBTimeHM(NSDate *d) {
    if (!d) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm";
    return [f stringFromDate:d];
}

static NSString *EBAgeNote(NSDate *d, NSDate *referenceDate) {
    if (!d) return nil;
    NSTimeInterval a = [referenceDate timeIntervalSinceDate:d];
    a = MAX(0, a);
    if (a < 60) return @"just now";
    if (a < 3600) return [NSString stringWithFormat:@"%.0fm ago", a / 60.0];
    return [NSString stringWithFormat:@"%.0fh ago", a / 3600.0];
}

/// Palette colour that follows a live Light/Dark switch.
static NSColor *EBDyn(NSColor *(^make)(void)) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        __block NSColor *c = nil;
        [a performAsCurrentDrawingAppearance:^{ c = make(); }];
        return c;
    }];
}

/// Flipped page that paints the popover fill in drawRect:, so it follows Light/Dark.
@interface EBPanelView : NSView
@end
@implementation EBPanelView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
}
@end

static const CGFloat kChartH = 150, kToggleH = 28, kToggleGap = 6;

static NSFont *EBDatumFont(void) {
    return [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
}
static BOOL EBTextFits(NSString *text, NSFont *font, CGFloat column) {
    if (!text.length) return YES;
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.font = font;
    tf.maximumNumberOfLines = 1;
    tf.lineBreakMode = NSLineBreakByClipping;
    return tf.intrinsicContentSize.width <= column + 0.5;
}
/// First option that fits the column. Later options are the shorter fallbacks.
static NSString *EBPickFitting(NSArray<NSString *> *options, NSFont *font, CGFloat column) {
    NSString *last = @"";
    for (NSString *s in options) {
        if (!s.length) continue;
        last = s;
        if (EBTextFits(s, font, column)) return s;
    }
    return last;
}
static NSBox *EBDivider(void) {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(EBPad, 0, EBPanelW - 2 * EBPad, 1)];
    b.boxType = NSBoxSeparator;
    return b;
}

/// Lay out visible rows top-down and size the page. Rows hide; nothing reflows by constraint.
static void EBLayout(EBPopoverViews *v) {
    CGFloat y = 8;
    if (!v.faultRow.hidden) {
        [v.faultRow setFrameOrigin:NSMakePoint(0, y)];
        y += NSHeight(v.faultRow.frame);
    }
    CGFloat datumX = EBPanelW - EBPad - EBDatumColumnW;
    v.nowCaption.frame = NSMakeRect(datumX - 6 - EBValueColumnW, y, EBValueColumnW, 14);
    v.todayCaption.frame = NSMakeRect(datumX, y, EBDatumColumnW, 14);
    y += 14;
    v.totalsDivider.frame = NSMakeRect(datumX - 3, y + 3, 1, 3 * EBRowH - 6);
    NSArray *rows = @[v.solarRow, v.gridRow, v.carRow, v.batteryRow];
    for (NSView *row in rows) {
        if (row.hidden) continue;
        [row setFrameOrigin:NSMakePoint(0, y)];
        y += NSHeight(row.frame);
    }
    NSBox *div1 = v.chartDivider, *div2 = v.footerDivider;
    y += 6;
    [div1 setFrameOrigin:NSMakePoint(EBPad, y)];
    y += 8;
    NSSize seg = v.windowSeg.frame.size;
    v.windowSeg.frame = NSMakeRect(EBPanelW - EBPad - seg.width, y, seg.width, seg.height);
    v.legend.frame = NSMakeRect(EBPad, y, NSMinX(v.windowSeg.frame) - EBPad - 8, seg.height);
    y += seg.height + 10;
    v.chart.frame = NSMakeRect(EBPad, y, EBPanelW - 2 * EBPad, kChartH);
    y += kChartH + 8;
    [div2 setFrameOrigin:NSMakePoint(EBPad, y)];
    y += 7;
    v.modeControl.frame = NSMakeRect(EBPad, y, NSWidth(v.modeControl.frame), kToggleH);
    CGFloat stopW = ceil(v.stopButton.intrinsicContentSize.width) + 16;
    v.stopButton.frame = NSMakeRect(NSMaxX(v.modeControl.frame) + kToggleGap, y, stopW, kToggleH);
    v.moreButton.frame = NSMakeRect(EBPanelW - EBPad - kToggleH, y, kToggleH, kToggleH);
    y += kToggleH + 10;
    // Size only. NSPopover positions the content view inside its arrow and border
    // insets; resetting the origin on a live refresh shoved the panel under them.
    [v.root setFrameSize:NSMakeSize(EBPanelW, y)];
}

EBPopoverViews *EBBuildPopover(id target) {
    EBPopoverViews *v = [EBPopoverViews new];
    EBPanelView *root = [[EBPanelView alloc] initWithFrame:NSMakeRect(0, 0, EBPanelW, 400)];
    v.root = root;

    // Fault row: the one place a sentence is allowed, and only while something is wrong.
    NSView *fault = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, EBPanelW, EBRowH)];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:22
                                                                                      weight:NSFontWeightRegular];
    NSImageView *warn = [NSImageView imageViewWithImage:
        [[NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:nil]
         imageWithSymbolConfiguration:cfg]];
    warn.frame = NSMakeRect(EBPad, (EBRowH - 22) / 2, 28, 22);
    warn.contentTintColor = EBInkCarOnGrid();
    v.faultLabel = [NSTextField labelWithString:@""];
    v.faultLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    v.faultLabel.textColor = EBInkCarOnGrid();
    v.faultLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    v.faultLabel.frame = NSMakeRect(48, (EBRowH - 16) / 2, EBPanelW - 48 - EBPad, 16);
    [fault addSubview:warn];
    [fault addSubview:v.faultLabel];
    fault.hidden = YES;
    v.faultRow = fault;

    v.solarRow = [[EBInstrumentRow alloc] initWithFrame:NSZeroRect];
    v.gridRow = [[EBInstrumentRow alloc] initWithFrame:NSZeroRect];
    v.carRow = [[EBInstrumentRow alloc] initWithFrame:NSZeroRect];
    v.batteryRow = [[EBInstrumentRow alloc] initWithFrame:NSZeroRect];
    v.batteryRow.hidden = YES;
    for (EBInstrumentRow *row in @[v.solarRow, v.gridRow, v.carRow]) row.dailyTotal = YES;
    v.nowCaption = [NSTextField labelWithString:@"Now"];
    v.todayCaption = [NSTextField labelWithString:@"Today"];
    for (NSTextField *caption in @[v.nowCaption, v.todayCaption]) {
        caption.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        caption.textColor = EBInkSecondary();
        caption.accessibilityElement = NO;
    }
    v.nowCaption.alignment = NSTextAlignmentRight;
    v.nowCaption.toolTip = @"kW now";
    v.todayCaption.toolTip = @"Since midnight";
    v.totalsDivider = EBDivider();
    v.chartDivider = EBDivider();
    v.footerDivider = EBDivider();

    v.legend = [[EBChartLegend alloc] initWithFrame:NSZeroRect];
    v.windowSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"12h", @"48h"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:target
                                                          action:@selector(changeWindow:)];
    v.windowSeg.controlSize = NSControlSizeSmall;
    v.windowSeg.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    v.windowSeg.selectedSegment = 0;
    v.windowSeg.toolTip = @"History window";
    [v.windowSeg sizeToFit];
    v.chart = [[EBChartView alloc] initWithFrame:NSMakeRect(0, 0, EBPanelW - 2 * EBPad, kChartH)];

    v.modeControl = [EBChargeModeControl controlWithTarget:target
                                              solarAction:@selector(doSolar:)
                                             chargeAction:@selector(doChargeNow:)];
    v.solarButton = v.modeControl.solarButton;
    v.chargeNowButton = v.modeControl.chargeNowButton;
    v.solarButton.toolTip = @"Charge from surplus solar";
    v.chargeNowButton.toolTip = @"Full rate, grid when solar is short";
    v.stopButton = [NSButton buttonWithTitle:@"Stop" target:target action:@selector(doStop:)];
    v.stopButton.bezelStyle = NSBezelStyleRounded;
    v.stopButton.bordered = YES;
    v.stopButton.imagePosition = NSImageLeft;
    v.stopButton.imageScaling = NSImageScaleProportionallyDown;
    v.stopButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSImageSymbolConfiguration *stopCfg = [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                                          weight:NSFontWeightMedium];
    v.stopButton.image = [[NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:nil]
                          imageWithSymbolConfiguration:stopCfg];
    v.stopButton.accessibilityLabel = @"Stop";

    NSImageSymbolConfiguration *moreCfg = [NSImageSymbolConfiguration configurationWithPointSize:22
                                                                                          weight:NSFontWeightRegular];
    v.moreButton = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"ellipsis.circle"
                                                        accessibilityDescription:@"More"]
                                              imageWithSymbolConfiguration:moreCfg]
                                      target:target action:@selector(showGearMenu:)];
    v.moreButton.title = @"";
    v.moreButton.bordered = NO;
    v.moreButton.imagePosition = NSImageOnly;
    v.moreButton.imageScaling = NSImageScaleProportionallyDown;
    v.moreButton.contentTintColor = NSColor.secondaryLabelColor;

    for (NSView *sub in @[fault, v.nowCaption, v.todayCaption, v.totalsDivider,
                          v.solarRow, v.gridRow, v.carRow, v.batteryRow, v.chartDivider,
                          v.legend, v.windowSeg, v.chart, v.footerDivider,
                          v.modeControl, v.stopButton, v.moreButton])
        [root addSubview:sub];

    // ⋯ menu (built once; target handles actions). Vehicle submenu is refreshed in EBApplySnapshot.
    v.gearMenu = [NSMenu new];
    [v.gearMenu addItemWithTitle:@"Refresh now" action:@selector(refreshNow:) keyEquivalent:@""];
    [v.gearMenu addItemWithTitle:@"Open samples folder" action:@selector(openSamples:) keyEquivalent:@""];
    [v.gearMenu addItemWithTitle:@"Copy diagnostics" action:@selector(copyDiagnostics:) keyEquivalent:@""];
    [v.gearMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *electricity = [[NSMenuItem alloc] initWithTitle:@"Electricity" action:nil keyEquivalent:@""];
    electricity.tag = 9003;
    electricity.submenu = [NSMenu new];
    [v.gearMenu addItem:electricity];
    NSMenuItem *vehicle = [[NSMenuItem alloc] initWithTitle:@"Vehicle" action:nil keyEquivalent:@""];
    vehicle.submenu = [NSMenu new];
    vehicle.tag = 9001;
    [v.gearMenu addItem:vehicle];
    [v.gearMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                   action:@selector(toggleLaunchAtLogin:)
                                            keyEquivalent:@""];
    login.tag = 9002;
    [v.gearMenu addItem:login];
    [v.gearMenu addItem:[NSMenuItem separatorItem]];
    [v.gearMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    for (NSMenuItem *it in v.gearMenu.itemArray) {
        if (it.action == @selector(terminate:)) it.target = NSApp;
        else if (it.action) it.target = target;
    }

    EBSetChargeMode(v, -1);
    EBLayout(v);
    return v;
}

void EBSetChargeMode(EBPopoverViews *v, NSInteger mode) {
    v.modeControl.mode = mode;
    v.solarButton.accessibilityLabel = [NSString stringWithFormat:@"Solar only — %@", mode == 0 ? @"on" : @"off"];
    v.chargeNowButton.accessibilityLabel = [NSString stringWithFormat:@"Charge now — %@", mode == 1 ? @"on" : @"off"];
}

void EBSetCommandsEnabled(EBPopoverViews *v, BOOL enabled, BOOL canStop) {
    v.solarButton.enabled = enabled;
    v.chargeNowButton.enabled = enabled;
    v.stopButton.enabled = enabled && canStop;
    [v.modeControl refreshChrome];
}

static NSString *EBStale(NSDate *d, NSDate *ref) {
    NSString *age = EBAgeNote(d, ref);
    if (!age || [age isEqualToString:@"just now"]) return @"stale";
    return [@"stale " stringByAppendingString:[age stringByReplacingOccurrencesOfString:@" ago" withString:@""]];
}

static double EBMoneyCents(double amount) {
    // Round each gross amount once; the displayed net must reconcile to those
    // two displayed amounts. The tiny tolerance avoids binary half-cent drift.
    return round(amount * 100.0 + 1e-7);
}

static NSString *EBMoney(double amount, EBTariff *tariff) {
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterCurrencyStyle;
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_AU"];
    f.currencyCode = tariff.currency;
    f.minimumFractionDigits = f.maximumFractionDigits = 2;
    return [f stringFromNumber:@(EBMoneyCents(amount) / 100.0)];
}

static NSString *EBBalanceMoney(double amount, EBTariff *tariff, NSString *sign, NSString *suffix) {
    NSString *money = [sign stringByAppendingString:EBMoney(amount, tariff)];
    NSFont *font = EBDatumFont();
    if (EBTextFits([money stringByAppendingString:suffix], font, EBDatumColumnW)) return money;
    // Exceptional amounts keep one-line geometry; the tooltip retains cents.
    // Never turn an ordinary charge into a misleading rounded "$0k".
    if (amount < 1000) return @"…";
    double scale = amount >= 1e9 ? 1e9 : (amount >= 1e6 ? 1e6 : 1e3);
    NSString *magnitude = scale == 1e9 ? @"B" : (scale == 1e6 ? @"M" : @"k");
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterCurrencyStyle;
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_AU"];
    f.currencyCode = tariff.currency;
    for (NSInteger precision = 1; precision >= 0; precision--) {
        f.minimumFractionDigits = f.maximumFractionDigits = precision;
        NSString *compact = [NSString stringWithFormat:@"%@%@%@", sign, [f stringFromNumber:@(amount / scale)], magnitude];
        if (EBTextFits([compact stringByAppendingString:suffix], font, EBDatumColumnW)) return compact;
    }
    return @"…";
}

static BOOL EBCostIsPartial(EBGridCostTotals totals) {
    // Allow ordinary meter latency, not the energy-only display's 10% tolerance.
    return totals.coverage + fmin(EBStoreIntegrationGapSeconds, totals.span * 0.01) < totals.span;
}

/// The lower-bound mark belongs to each gross amount, never to a net bill.
static NSString *EBGridDayAmount(EBSnapshotView *s, BOOL importing, BOOL compact) {
    BOOL priced = s.tariff && s.gridCostToday.coverage > 0;
    double wh = priced ? (importing ? s.gridCostToday.importWh : s.gridCostToday.exportWh)
                       : (importing ? s.today.importWh : s.today.exportWh);
    NSTimeInterval coverage = priced ? s.gridCostToday.coverage : s.today.gridCoverage;
    NSTimeInterval span = priced ? s.gridCostToday.span : s.today.span;
    if (coverage <= 0) return @"—";
    BOOL partial = priced ? EBCostIsPartial(s.gridCostToday) : EBCoverageNote(coverage, span).length > 0;
    NSString *lower = partial ? @"≥" : @"";
    NSString *energy = [lower stringByAppendingString:EBFmtKWh(wh)];
    if (!priced || compact) return [energy stringByAppendingString:@" today"];
    double amount = importing ? s.gridCostToday.importCost : s.gridCostToday.exportCredit;
    NSString *money = EBMoney(amount, s.tariff);
    return [NSString stringWithFormat:@"%@ · %@%@ %@", energy, lower, money,
            importing ? @"cost" : @"credit"];
}

/// Window peak, so the three kW gauges share one scale and compare directly.
static double EBGaugeScale(NSArray<NSDictionary *> *samples, NSDate *since, EBSnapshotView *s) {
    double peak = 1000;
    for (NSDictionary *row in samples) {
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class] || [t compare:since] == NSOrderedAscending) continue;
        for (NSString *k in @[@"pvW", @"supplyW", @"chargeW"]) {
            NSNumber *n = [row[k] isKindOfClass:NSNumber.class] ? row[k] : nil;
            if (n) peak = fmax(peak, fabs(n.doubleValue));
        }
    }
    if (s.pvOK) peak = fmax(peak, s.pvW);
    if (s.gridOK || s.gridStale) peak = fmax(peak, fmax(fabs(s.supplyW), s.chargeW));
    return peak;
}

void EBApplySnapshot(EBPopoverViews *v, EBSnapshotView *s, NSArray<NSDictionary *> *samples) {
    if (!v || !s) return;
    NSDate *referenceDate = s.referenceDate ?: [NSDate date];
    EBDayTotals tot = s.today;
    NSColor *orange = EBDyn(^{ return EBColorSurplus(); });
    NSColor *green = EBDyn(^{ return EBColorExport(); });
    NSColor *blue = EBDyn(^{ return EBColorCarOnSolar(); });
    NSColor *red = EBDyn(^{ return EBColorCarOnGrid(); });
    NSColor *amber = EBDyn(^{ return NSColor.systemYellowColor; });
    NSTimeInterval win = v.chart.windowSeconds > 0 ? v.chart.windowSeconds : 12 * 3600;
    double scale = EBGaugeScale(samples ?: @[], [referenceDate dateByAddingTimeInterval:-12 * 3600], s);
    BOOL meter = s.gridOK || s.gridStale;

    // Verdict, computed as before; it drives colour and tooltips, not a header.
    EBMatchState match;
    if (s.gridStale || (!s.gridOK && s.chargerOK))
        match = EBMatchUnknown;
    else if (!s.chargerOK && !s.gridOK)
        match = EBMatchOffline;
    else
        // The Evnex meter independently measures both grid flow and car load.
        // Fresh meter-only data can therefore classify the physical energy match
        // even when the separate charger-status command is unavailable.
        match = EBComputeMatchState(s.gridOK, s.supplyW,
                                   s.gridOK, s.chargeW,
                                   s.vehicleHasReady, s.vehicleReady,
                                   s.vehicleHasSOC, s.vehicleSOC);
    BOOL evnexFault = !s.chargerOK && s.evnexError.length && match == EBMatchOffline;
    if (s.vehicleError.length) v.statusLabel = @"Vehicle state not saved";
    else if (evnexFault) v.statusLabel = s.evnexError;
    else v.statusLabel = EBMatchLabel(match);

    NSString *fault = nil, *faultTip = nil;
    if (s.vehicleError.length) { fault = @"Vehicle state not saved"; faultTip = s.vehicleError; }
    else if (evnexFault) { fault = s.evnexError; faultTip = @"Evnex grid, car and charger readings are unavailable."; }
    else if (s.storageError.length) { fault = @"History not saved"; faultTip = s.storageError; }
    v.faultRow.hidden = fault == nil;
    v.faultLabel.stringValue = fault ?: @"";
    v.faultRow.toolTip = faultTip;
    v.faultRow.accessibilityLabel = fault;

    // Solar
    EBInstrumentRow *sol = v.solarRow;
    sol.title = @"Solar";
    sol.symbolName = @"sun.max.fill";
    BOOL producing = s.pvOK && s.pvW > 50;
    sol.tint = producing ? orange : nil;
    sol.valueInk = producing ? EBInkSurplus() : nil;
    sol.datumInk = nil;
    // Full at the inverter's capacity when known: the bar then reads "how hard is it working".
    double solarScale = s.inverterW > 0 ? s.inverterW : scale;
    sol.gaugeFraction = s.pvOK ? MIN(1.0, s.pvW / solarScale) : -1;
    NSMutableArray<NSString *> *solarNotes = [NSMutableArray arrayWithObject:
        @"Power now (kW) is the current rate. Energy today (kWh) is the total generated since midnight."];
    if (s.pvOK) {
        sol.value = EBFmtKW(s.pvW);
        sol.unit = @"kW";
        if (s.eDayWh > 0)
            sol.subline = [NSString stringWithFormat:@"%@ today", EBFmtKWh(s.eDayWh)];
        else if (s.pvArchiveAvailable)
            sol.subline = [NSString stringWithFormat:@"≥%@ today", EBFmtKWh(s.pvArchiveWh)];
        else {
            NSString *n = EBCoverageNote(tot.pvCoverage, tot.span);
            sol.subline = [n isEqualToString:@"no data"] ? @"—" :
                [NSString stringWithFormat:@"%@%@ today", n.length ? @"≥" : @"", EBFmtKWh(tot.pvWh)];
            if (n.length && ![n isEqualToString:@"no data"])
                [solarNotes addObject:@"Partial coverage today: a lower bound."];
        }
    } else {
        sol.value = @"—";
        sol.unit = @"";
        if (s.pvArchiveAvailable) {
            sol.subline = [NSString stringWithFormat:@"≥%@ today", EBFmtKWh(s.pvArchiveWh)];
        } else {
            sol.subline = @"offline";
            sol.datumInk = EBInkCarOnGrid();
        }
        if (s.pvError.length) [solarNotes addObject:s.pvError];
    }
    if (s.pvArchiveAvailable)
        [solarNotes addObject:@"Fronius supplied exact archived solar-energy intervals, which can include periods when Energybar was closed. Boundary intervals are omitted from the displayed lower bound."];
    if (s.pvArchiveError.length) [solarNotes addObject:s.pvArchiveError];
    if (s.pvAt) [solarNotes addObject:[NSString stringWithFormat:@"Fronius read %@", EBTimeHM(s.pvAt)]];
    // Tooltips are terse: figures the row doesn't show, errors, nothing else.
    NSMutableArray *solTip = [NSMutableArray array];
    if (s.pvError.length) [solTip addObject:s.pvError];
    if (s.pvArchiveError.length) [solTip addObject:s.pvArchiveError];
    if ([sol.subline hasPrefix:@"≥"]) [solTip addObject:@"partial day: a lower bound"];
    sol.toolTip = solTip.count ? [solTip componentsJoinedByString:@" · "] : nil;
    (void)solarNotes;
    [sol reload];

    // Grid: live direction and kW stay numeric; the single gauge shows the daily cost offset when priced.
    EBInstrumentRow *grid = v.gridRow;
    NSMutableArray<NSString *> *gridNotes = [NSMutableArray arrayWithObject:@"import from grid · export to grid"];
    BOOL importing = meter && s.supplyW > 50, exporting = meter && s.supplyW < -50;
    NSString *direction = importing ? @"import" : (exporting ? @"export" : nil);
    grid.title = importing ? @"Import" : (exporting ? @"Export" : @"Grid");
    grid.spokenDetail = nil;
    grid.symbolName = s.gridStale ? @"clock.fill" : @"powerplug";
    grid.tint = s.gridStale ? amber : (importing ? red : (exporting ? green : nil));
    grid.valueInk = s.gridStale ? EBInkStale() : (importing ? EBInkCarOnGrid() : (exporting ? EBInkExport() : nil));
    grid.datumInk = s.gridStale ? EBInkStale() : nil;
    // Magnitude from the left, like every other bar; the row's name (Import / Export) and
    // its colour carry the direction. Centre-zero read as a lone dot for small flows.
    grid.gaugeFromCenter = NO;
    grid.gaugeFraction = meter ? MIN(1.0, fabs(s.supplyW) / scale) : -1;
    // Same window peak as the other rows. The snapshot has no inverter nameplate.
    double signedFlow = (!meter || (!importing && !exporting)) ? 0 : -s.supplyW / scale;
    grid.gaugeSigned = MIN(1.0, MAX(-1.0, signedFlow));
    grid.gaugeColor = exporting ? green : (importing ? red : nil);
    grid.gaugeNegativeColor = red;
    if (meter) {
        grid.value = EBFmtKW(s.supplyW);
        grid.unit = @"kW";
        if (s.gridStale) {
            grid.subline = EBStale(s.gridAsOf, referenceDate);
        } else {
            if (direction) {
                NSString *amount = EBGridDayAmount(s, importing, YES);
                grid.subline = EBPickFitting(@[amount, [amount stringByReplacingOccurrencesOfString:@" today" withString:@""]],
                                            EBDatumFont(), EBDatumColumnW);
                grid.spokenDetail = @"Today's energy";
            } else {
                // No live direction: do not silently relabel a daily total as current flow.
                grid.subline = @"balanced";
            }
        }
    } else {
        grid.gaugeFromCenter = NO;
        grid.gaugeFraction = -1;
        grid.value = @"—";
        grid.unit = @"";
        grid.subline = evnexFault ? @"offline" : @"unknown";
        grid.datumInk = evnexFault ? EBInkCarOnGrid() : EBInkStale();
        grid.tint = evnexFault ? red : amber;
        grid.symbolName = evnexFault ? @"powerplug" : @"clock.fill";
        if (s.evnexError.length) [gridNotes addObject:s.evnexError];
    }
    NSString *importDay = EBGridDayAmount(s, YES, NO), *exportDay = EBGridDayAmount(s, NO, NO);
    [gridNotes addObject:[NSString stringWithFormat:@"Today: import %@\nToday: export %@", importDay, exportDay]];
    BOOL priced = s.tariff && s.gridCostToday.coverage > 0;
    BOOL partialCost = priced && EBCostIsPartial(s.gridCostToday);
    EBGridBalanceGauge *balance = grid.balanceGauge;
    balance.hidden = !s.tariff && !s.tariffError.length;
    if (!balance.hidden) {
        // Finance replaces the daily energy label, but must not hide the live
        // meter's stale/offline status from the spoken row or its tooltip.
        grid.spokenDetail = s.gridStale || !meter ? grid.subline : nil;
        if (grid.spokenDetail.length) [gridNotes addObject:grid.spokenDetail];
    }
    balance.partial = partialCost;
    balance.amountsAvailable = priced;
    balance.importAmount = balance.exportAmount = 0;
    balance.period = partialCost ? @"Recorded" : @"Today";
    balance.importValue = balance.exportValue = balance.netValue = @"—";
    balance.netInk = nil;
    NSString *netDetail = @"Net today: unavailable";
    NSMutableArray<NSString *> *balanceNotes = [NSMutableArray array];
    NSMutableArray<NSString *> *balanceSpoken = [NSMutableArray array];
    if (priced) {
        double debit = EBMoneyCents(s.gridCostToday.importCost) / 100;
        double credit = EBMoneyCents(s.gridCostToday.exportCredit) / 100;
        double netCents = EBMoneyCents(s.gridCostToday.exportCredit) - EBMoneyCents(s.gridCostToday.importCost);
        NSString *sign = netCents < 0 ? @"−" : (netCents > 0 ? @"+" : @"");
        balance.importAmount = debit;
        balance.exportAmount = credit;
        balance.importValue = EBMoney(debit, s.tariff);
        balance.exportValue = EBMoney(credit, s.tariff);
        NSString *suffix = partialCost ? @" net partial" : @" net today";
        balance.netValue = EBBalanceMoney(fabs(netCents) / 100, s.tariff, sign, suffix);
        balance.netInk = netCents < 0 ? EBInkCarOnGrid() : (netCents > 0 ? EBInkExport() : NSColor.labelColor);
        netDetail = [NSString stringWithFormat:@"%@ today: %@ %@",
                     partialCost ? @"Net recorded" : @"Net", EBMoney(fabs(netCents) / 100, s.tariff),
                     netCents < 0 ? @"cost" : (netCents > 0 ? @"credit" : @"balanced")];
        [gridNotes addObject:netDetail];
        [gridNotes addObject:@"Net = export credit − import cost. Negative is cost; positive is credit."];
        [gridNotes addObject:@"The bar compares today's import cost and export credit. The kW number is power now, on a different scale."];
        [balanceNotes addObjectsFromArray:@[
            partialCost ? @"Recorded today (partial history)" : @"Today",
            [NSString stringWithFormat:@"Import: %@ · %@ cost", EBFmtKWh(s.gridCostToday.importWh), EBMoney(debit, s.tariff)],
            [NSString stringWithFormat:@"Export: %@ · %@ credit", EBFmtKWh(s.gridCostToday.exportWh), EBMoney(credit, s.tariff)],
            netDetail, @"Net = export credit − import cost. Negative is cost; positive is credit.",
            @"One bar: pale green is the amount offset by exports. The bright remainder is unpaid import cost (red) or surplus credit (green)."]];
        [balanceSpoken addObjectsFromArray:@[
            partialCost ? @"Recorded today, partial history" : @"Today",
            [NSString stringWithFormat:@"Import cost %@", EBMoney(debit, s.tariff)],
            [NSString stringWithFormat:@"Export credit %@", EBMoney(credit, s.tariff)], netDetail]];
        if (partialCost) {
            NSString *coverage = [NSString stringWithFormat:
                @"Amounts recorded today cover %.1f of %.1f elapsed hours. The recorded net is not a lower bound; missing readings can change it in either direction.",
                s.gridCostToday.coverage / 3600, s.gridCostToday.span / 3600];
            [gridNotes addObject:coverage];
            [balanceNotes addObject:coverage];
            [balanceSpoken addObject:coverage];
        }
        NSString *estimate = @"Estimated energy charges; daily supply charges excluded.";
        [balanceNotes addObject:estimate];
        [balanceSpoken addObject:estimate];
    } else if (s.tariff) {
        NSString *unavailable = @"No priced grid readings today; the balance is unavailable.";
        [gridNotes addObject:unavailable];
        [balanceNotes addObject:unavailable];
        [balanceSpoken addObject:unavailable];
    } else {
        NSString *unavailable = s.tariffError.length
            ? [@"Tariff unavailable: " stringByAppendingString:s.tariffError]
            : @"Electricity rates not set; today's balance is unavailable.";
        [balanceNotes addObject:unavailable];
        [balanceSpoken addObject:unavailable];
    }
    if (s.tariff) {
        [balanceNotes addObject:[NSString stringWithFormat:@"%@ · %@", s.tariff.name, s.tariff.currency]];
        [balanceSpoken addObject:s.tariff.currency];
        if (s.tariff.sourceURL.length) [balanceNotes addObject:[@"Rates source: " stringByAppendingString:s.tariff.sourceURL]];
    }
    if ((s.gridCostToday.coverage > 0 && EBCostIsPartial(s.gridCostToday)) ||
        (s.today.gridCoverage > 0 && EBCoverageNote(s.today.gridCoverage, s.today.span).length))
        [gridNotes addObject:@"Partial history: these are recorded amounts, not a complete day's bill."];
    double importRate = 0, exportRate = 0;
    BOOL activeRate = [s.tariff ratesAtDate:referenceDate importCents:&importRate exportCents:&exportRate];
    if (s.tariff) {
        [gridNotes addObject:[NSString stringWithFormat:@"%@ · %@\nEstimated energy charges; daily supply charges excluded.",
                              s.tariff.name, s.tariff.currency]];
        if (s.gridOK && !s.gridStale && activeRate && direction) {
            double rate = importing ? importRate : exportRate;
            [gridNotes addObject:[NSString stringWithFormat:@"Now: %@ per hour %@ at %.4g¢/kWh",
                                  EBMoney(fabs(s.supplyW) / 1000 * rate / 100, s.tariff),
                                  importing ? @"cost" : @"credit", rate]];
        }
        if (!activeRate) [gridNotes addObject:@"Tariff is outside its effective dates; current cost unavailable."];
        if (s.tariff.sourceURL.length) [gridNotes addObject:[@"Rates source: " stringByAppendingString:s.tariff.sourceURL]];
    } else {
        [gridNotes addObject:s.tariffError.length ? [@"Tariff unavailable: " stringByAppendingString:s.tariffError]
                                                  : @"Electricity rates not set; costs unavailable."];
    }
    if (s.evnexAt) [gridNotes addObject:[NSString stringWithFormat:@"Evnex meter read %@", EBTimeHM(s.evnexAt)]];
    NSMutableArray *gridTip = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"in %@ · out %@", importDay, exportDay]];
    if (partialCost) [gridTip addObject:@"partial"];   // the day amounts already carry cost and credit
    if (s.tariff && activeRate && s.gridOK && !s.gridStale && direction) {
        double rate = importing ? importRate : exportRate;
        [gridTip addObject:[NSString stringWithFormat:@"now %@/h %@", EBMoney(fabs(s.supplyW) / 1000 * rate / 100, s.tariff),
                            importing ? @"cost" : @"credit"]];
    }
    if (s.gridStale) [gridTip addObject:@"stale"];
    if (s.evnexError.length) [gridTip addObject:s.evnexError];
    if (s.tariffError.length) [gridTip addObject:@"tariff unavailable"];
    grid.toolTip = [gridTip componentsJoinedByString:@" · "];
    balance.toolTip = grid.toolTip;
    (void)gridNotes; (void)balanceNotes;
    balance.accessibilityLabel = [balanceSpoken componentsJoinedByString:@". "];
    [balance reload];
    [grid reload];

    NSMenuItem *electricity = [v.gearMenu itemWithTag:9003];
    NSMenu *ratesMenu = [NSMenu new];
    NSMutableArray<NSString *> *rateLines = [NSMutableArray arrayWithArray:@[
        [NSString stringWithFormat:@"Import today: %@", importDay],
        [NSString stringWithFormat:@"Export today: %@", exportDay]]];
    if (priced) [rateLines addObject:netDetail];
    if (s.tariff) {
        [rateLines addObject:s.tariff.name];
        if (activeRate) {
            [rateLines addObject:[NSString stringWithFormat:@"Import now: %.4g¢/kWh", importRate]];
            [rateLines addObject:[NSString stringWithFormat:@"Export now: %.4g¢/kWh", exportRate]];
        } else [rateLines addObject:@"Current rates unavailable"];
        [rateLines addObject:@"Estimates · supply charges excluded"];
    } else [rateLines addObject:s.tariffError.length ? @"Tariff unavailable" : @"Electricity rates not set"];
    for (NSString *line in rateLines) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line action:nil keyEquivalent:@""];
        item.enabled = NO;
        [ratesMenu addItem:item];
    }
    electricity.submenu = ratesMenu;

    // Car: the symbol gains a bolt while charging. The car is always blue (shared spec: one
    // meaning per colour); drawing from the grid is said in words here and shown in red on the
    // Grid row and the chart's import bars.
    EBInstrumentRow *car = v.carRow;
    car.title = @"Car";
    BOOL charging = meter && s.chargeW >= 100;
    car.symbolName = charging ? @"bolt.car.fill" : @"car.fill";
    car.tint = charging ? blue : nil;
    car.valueInk = s.gridStale ? EBInkSecondary() : (charging ? EBInkCarOnSolar() : nil);
    car.datumInk = nil;
    // Quantity plus flow, as Glancebar's battery: with a known state of charge the bar is the
    // pack and a trend arrow rides on it to where it will be in an hour at this charging rate.
    double carSOC = s.vehicleHasSOC ? MIN(100, MAX(0, s.vehicleSOC)) / 100.0 : -1;
    car.trendFrom = car.trendTo = -1;
    if (carSOC >= 0) {
        NSColor *packInk = carSOC >= 0.5 ? green : (carSOC >= 0.2 ? amber : red);
        car.gaugeFraction = carSOC;
        car.gaugeColor = s.vehicleSOCIsEstimate ? [packInk colorWithAlphaComponent:0.5] : packInk;
        if (charging && s.vehicleCapacityWh > 0) {
            double eff = s.vehicleChargeEfficiency > 0 ? s.vehicleChargeEfficiency : 1.0;
            car.trendFrom = carSOC;
            car.trendTo = MIN(1.0, carSOC + s.chargeW * eff / s.vehicleCapacityWh);
        }
    } else {
        car.gaugeFraction = meter ? s.chargeW / scale : -1;
        car.gaugeColor = nil;
    }
    NSString *carEnergy = nil;
    if (s.carDayAvailable) {
        NSString *asOf = s.carDayStale ? EBTimeHM(s.carDayAsOf) : nil;
        carEnergy = asOf.length
            ? [NSString stringWithFormat:@"%@ @%@", EBFmtKWh(s.carDayWh), asOf]
            : [NSString stringWithFormat:@"%@ exact", EBFmtKWh(s.carDayWh)];
    } else {
        NSString *cNote = EBCoverageNote(tot.chargeCoverage, tot.span);
        carEnergy = [cNote isEqualToString:@"no data"] ? nil :
            [NSString stringWithFormat:@"%@%@ today", cNote.length ? @"≥" : @"", EBFmtKWh(tot.chargeWh)];
    }
    if (meter) {
        car.value = EBFmtKW(s.chargeW);
        car.unit = @"kW";
        car.subline = carEnergy ?: @"—";
    } else {
        car.value = @"—";
        car.unit = @"";
        car.subline = carEnergy ?: (s.chargerOK ? @"no meter" : @"offline");
        if (!carEnergy) car.datumInk = s.chargerOK ? EBInkStale() : EBInkCarOnGrid();
    }
    NSMutableArray<NSString *> *carNotes = [NSMutableArray arrayWithObject:v.statusLabel];
    [carNotes addObject:@"Power now (kW) is the charging rate. Energy today (kWh) is the total delivered since midnight."];
    if (carEnergy && tot.chargeGridWh >= 50)
        [carNotes addObject:[NSString stringWithFormat:@"Today %@, of which %@ from the grid",
                             [carEnergy stringByReplacingOccurrencesOfString:@" today" withString:@""],
                             EBFmtKWh(tot.chargeGridWh)]];
    if (s.carDayAvailable)
        [carNotes addObject:@"Evnex session energy can include charging recorded while Energybar was closed; chart gaps remain gaps."];
    if (s.sessionError.length) [carNotes addObject:s.sessionError];
    if (s.vehicleError.length) [carNotes addObject:s.vehicleError];
    if (carSOC >= 0) {
        [carNotes insertObject:[NSString stringWithFormat:@"Battery %.0f%%%@%@", carSOC * 100,
                                s.vehicleSOCIsEstimate ? @" (estimated)" : @"",
                                s.vehicleHasReady ? (s.vehicleReady ? @" · ready" : @" · not ready") : @""] atIndex:0];
        [carNotes addObject:car.trendTo >= 0 ? @"Bar: battery level. Arrow: where it will be in an hour at this rate."
                                             : @"Bar: battery level."];
    }
    NSMutableArray *carTip = [NSMutableArray array];
    if (carSOC >= 0) [carTip addObject:[NSString stringWithFormat:@"battery %.0f%%%@%@", carSOC * 100,
        s.vehicleSOCIsEstimate ? @" est." : @"", s.vehicleHasReady ? (s.vehicleReady ? @" · ready" : @" · not ready") : @""]];
    if (carEnergy && tot.chargeGridWh >= 50) [carTip addObject:[NSString stringWithFormat:@"%@ from the grid", EBFmtKWh(tot.chargeGridWh)]];
    if (s.sessionError.length) [carTip addObject:s.sessionError];
    if (s.vehicleError.length) [carTip addObject:s.vehicleError];
    car.toolTip = carTip.count ? [carTip componentsJoinedByString:@" · "] : nil;
    (void)carNotes;
    car.spokenDetail = carSOC >= 0
        ? [NSString stringWithFormat:@"%@, battery %.0f%%%@", v.statusLabel, carSOC * 100, s.vehicleSOCIsEstimate ? @" estimated" : @""]
        : v.statusLabel;
    [car reload];

    // Car battery: only when vehicle state is known.
    EBInstrumentRow *bat = v.batteryRow;
    bat.hidden = !s.vehicleError.length;   // the level now rides on the Car row
    bat.title = @"Battery";
    double soc = s.vehicleHasSOC ? s.vehicleSOC : -1;
    bat.symbolName = soc < 0 ? @"battery.0" : soc >= 88 ? @"battery.100" : soc >= 63 ? @"battery.75"
        : soc >= 38 ? @"battery.50" : soc >= 13 ? @"battery.25" : @"battery.0";
    NSColor *pack = soc >= 50 ? green : (soc >= 20 ? amber : red);
    bat.tint = soc < 0 ? nil : (s.vehicleSOCIsEstimate ? [pack colorWithAlphaComponent:0.5] : pack);
    bat.gaugeFromCenter = NO;
    bat.valueInk = EBInkBattery();
    bat.gaugeFraction = soc < 0 ? -1 : soc / 100.0;
    bat.value = soc < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", soc];
    bat.unit = @"";
    NSMutableArray *batBits = [NSMutableArray array];
    if (s.vehicleHasSOC && s.vehicleSOCIsEstimate) [batBits addObject:@"est."];
    if (s.vehicleHasReady) [batBits addObject:s.vehicleReady ? @"ready" : @"not ready"];
    bat.datumInk = nil;
    if (s.vehicleError.length) { batBits = [NSMutableArray arrayWithObject:@"not saved"]; bat.datumInk = EBInkCarOnGrid(); }
    bat.subline = batBits.count ? [batBits componentsJoinedByString:@" · "] : nil;
    bat.spokenDetail = s.vehicleHasSOC && s.vehicleSOCIsEstimate ? @"estimated" : nil;
    NSMutableArray *batNotes = [NSMutableArray array];
    if (s.vehicleLine.length) [batNotes addObject:s.vehicleLine];
    if (s.vehicleError.length) [batNotes addObject:s.vehicleError];
    bat.toolTip = batNotes.count ? [batNotes componentsJoinedByString:@"\n"] : nil;
    [bat reload];

    // Footer
    EBChargerState cs = EBComputeChargerState(s.ocppStatus, s.chargingLogic, s.chargingCurrentControl,
                                              s.chargeNow, s.haveOcpp);
    if (cs == EBChargerStateCharging) EBSetChargeMode(v, 1);
    else if (cs == EBChargerStateSolar || cs == EBChargerStateWaiting ||
             cs == EBChargerStateUnplugged) EBSetChargeMode(v, 0);
    else EBSetChargeMode(v, -1);
    v.stopButton.enabled = s.orgId.length > 0;
    v.stopButton.toolTip = s.orgId.length ? @"Stop charging now" : @"Organisation ID not yet known";
    NSString *checked = [NSString stringWithFormat:@"Checked: Fronius %@ · Evnex %@",
                         EBTimeHM(s.pvAt) ?: @"—", EBTimeHM(s.evnexAt) ?: @"—"];
    v.moreButton.toolTip = [NSString stringWithFormat:@"Refresh, vehicle, settings and Quit\n%@\n%@",
                            v.statusLabel, checked];

    v.chart.referenceDate = referenceDate;
    NSDate *since = [referenceDate dateByAddingTimeInterval:-win];
    NSMutableArray *windowRows = [NSMutableArray array];
    for (NSDictionary *row in samples ?: @[]) {
        NSDate *t = row[@"t"];
        if ([t isKindOfClass:NSDate.class] && [t compare:since] != NSOrderedAscending) [windowRows addObject:row];
    }
    v.chart.samples = windowRows;

    EBLayout(v);

    NSMenuItem *vehicle = [v.gearMenu itemWithTag:9001];
    if (vehicle) {
        NSString *line = s.vehicleLine.length ? s.vehicleLine : @"Not set";
        vehicle.title = [NSString stringWithFormat:@"Vehicle · %@", line];
        NSMenu *sub = [NSMenu new];
        NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:line action:nil keyEquivalent:@""];
        status.enabled = NO;
        [sub addItem:status];
        if (s.vehicleError.length) {
            NSMenuItem *storage = [[NSMenuItem alloc] initWithTitle:s.vehicleError
                                                            action:nil
                                                     keyEquivalent:@""];
            storage.enabled = NO;
            [sub addItem:storage];
        }
        [sub addItem:[NSMenuItem separatorItem]];
        NSMenuItem *setSOC = [[NSMenuItem alloc] initWithTitle:@"Set battery %…"
                                                        action:@selector(vehicleSetSOC:)
                                                 keyEquivalent:@""];
        NSMenuItem *ready = [[NSMenuItem alloc] initWithTitle:@"Ready to accept charge"
                                                       action:@selector(vehicleToggleReady:)
                                                keyEquivalent:@""];
        ready.state = (s.vehicleHasReady && s.vehicleReady) ? NSControlStateValueOn : NSControlStateValueOff;
        NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear vehicle data"
                                                       action:@selector(vehicleClear:)
                                                keyEquivalent:@""];
        clear.enabled = s.vehicleHasStoredState;
        for (NSMenuItem *it in @[setSOC, ready, clear])
            [sub addItem:it];
        id tgt = nil;
        for (NSMenuItem *it in v.gearMenu.itemArray) {
            if (it.action == @selector(refreshNow:)) { tgt = it.target; break; }
        }
        for (NSMenuItem *it in sub.itemArray) {
            if (it.action) it.target = tgt;
        }
        vehicle.submenu = sub;
    }

    [v.root layoutSubtreeIfNeeded];
}
