#import <Cocoa/Cocoa.h>
#import <math.h>
#import "popover.h"
#import "pure.h"
#import "store.h"
#import "chart.h"

@interface EBChartView (ToolTipTesting)
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data;
@end

static int gFails = 0;
static BOOL gAccept = NO;
static BOOL gCompareSnapshots = YES;

static NSDate *EBFixedDate(void) {
    // 2026-08-08 04:00:00 UTC. Tests set the process time zone to UTC below.
    return [NSDate dateWithTimeIntervalSince1970:1786161600];
}

#define EBFail(fmt, ...) do { \
    fprintf(stderr, "FAIL: " fmt "\n", ##__VA_ARGS__); \
    gFails++; \
} while (0)

#define EBExpect(cond, msg) do { if (!(cond)) EBFail("%s", (msg)); } while (0)

static NSString *EBRepoRoot(void) {
    return @(__FILE__).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

static NSArray *EBSynthSamples(void) {
    NSMutableArray *rows = [NSMutableArray array];
    NSDate *now = EBFixedDate();
    NSDate *start = [now dateByAddingTimeInterval:-12 * 3600];
    for (int i = 0; i < 240; i++) {
        NSDate *t = [start dateByAddingTimeInterval:i * 180];
        // Deliberate 40-minute gap mid-day
        if (i >= 80 && i < 93) continue;
        double phase = (double)i / 240.0 * M_PI;
        double pv = fmax(0, sin(phase) * 4500);
        double supply = (i > 100 && i < 140) ? 800 : -600; // import then export
        double charge = (i > 110 && i < 200) ? 2200 : 0;
        [rows addObject:@{@"t": t, @"pvW": @(pv), @"supplyW": @(supply), @"chargeW": @(charge)}];
    }
    return rows;
}

static NSArray *EBDaylightSamples(NSDate *now, NSTimeInterval window) {
    NSMutableArray *rows = [NSMutableArray array];
    NSDate *start = [now dateByAddingTimeInterval:-window];
    for (NSTimeInterval offset = 0; offset < window; offset += 180) {
        NSDate *t = [start dateByAddingTimeInterval:offset];
        double hour = fmod(t.timeIntervalSince1970, 86400) / 3600;
        double pv = hour > 6 && hour < 18 ? 4500 * sin((hour - 6) / 12 * M_PI) : 0;
        double car = hour > 8.5 && hour < 10 ? 1300 : 0;
        double home = 700 + 200 * sin(hour * 3);
        [rows addObject:@{@"t": t, @"pvW": @(pv), @"chargeW": @(car),
                          @"supplyW": @(home + car - pv)}];
    }
    return rows;
}

static EBSnapshotView *EBState(NSString *name) {
    EBSnapshotView *s = [EBSnapshotView new];
    s.referenceDate = EBFixedDate();
    s.vehicleLine = @"Not linked — AU API unavailable";
    s.orgId = @"org-test";
    s.pvAt = s.referenceDate;
    s.evnexAt = s.referenceDate;
    EBDayTotals tod = {0};
    tod.span = 12 * 3600;
    if ([name isEqualToString:@"sunny-export"]) {
        s.pvOK = YES; s.pvW = 4100; s.eDayWh = 24700;
        s.gridOK = YES; s.supplyW = -700; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        s.chargingCurrentControl = @"SolarControl";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span; tod.exportWh = 16900;
    } else if ([name isEqualToString:@"solar-charging"]) {
        s.pvOK = YES; s.pvW = 4800; s.eDayWh = 8200; s.inverterW = 5000;
        s.gridOK = YES; s.supplyW = -100; s.chargeW = 2600;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"SolarControl";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span;
        tod.chargeCoverage = tod.span; tod.chargeWh = 1900;
    } else if ([name isEqualToString:@"charge-now-importing"]) {
        s.pvOK = YES; s.pvW = 500; s.eDayWh = 3000;
        s.gridOK = YES; s.supplyW = 3000; s.chargeW = 7000;
        s.chargerOK = YES; s.haveOcpp = YES; s.chargeNow = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"FullPower";
        tod.gridCoverage = tod.span; tod.importWh = 4000;
        tod.chargeCoverage = tod.span; tod.chargeWh = 5000; tod.chargeGridWh = 4000;
    } else if ([name isEqualToString:@"evening"] || [name isEqualToString:@"history-48h"] ||
               [name isEqualToString:@"high-power"] || [name hasPrefix:@"tariff-"]) {
        s.referenceDate = [EBFixedDate() dateByAddingTimeInterval:14.3 * 3600];
        s.pvAt = s.evnexAt = s.referenceDate;
        s.pvOK = YES; s.pvW = 0; s.eDayWh = 24900;
        s.gridOK = YES; s.supplyW = 1000; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        s.chargingCurrentControl = @"SolarControl";
        tod.pvCoverage = tod.gridCoverage = tod.chargeCoverage = tod.span;
        tod.importWh = 2200; tod.exportWh = 13900; tod.chargeWh = 1900;
        if ([name isEqualToString:@"high-power"]) {
            s.pvW = 10500; s.supplyW = 10500; s.chargeW = 10500;
            s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
            s.chargeNow = YES; s.chargingCurrentControl = @"FullPower";
            tod.importWh = 13000; tod.chargeWh = 14000;
        }
        if ([name hasPrefix:@"tariff-"]) {
            // Synthetic rates test the display; never installed as the owner's tariff.
            BOOL zero = [name isEqualToString:@"tariff-zero"];
            BOOL invalid = [name isEqualToString:@"tariff-invalid"];
            BOOL unpriced = [name isEqualToString:@"tariff-unpriced"];
            s.tariff = invalid ? nil : [EBTariff fromDictionary:@{@"name": @"Test rates", @"currency": @"AUD",
                @"timeZone": @"Australia/Perth", @"bands": @[@{@"startMinute": @0, @"endMinute": @1440,
                    @"importCents": zero ? @0 : @33.2621, @"exportCents": zero ? @0 : @7.135}]} error:nil];
            if (invalid) s.tariffError = @"invalid tariff";
            s.supplyW = 900;
            tod.importWh = 6100;
            s.gridCostToday = (EBGridCostTotals){.importWh=6100, .exportWh=13900,
                .importCost=zero ? 0 : 2.03, .exportCredit=zero ? 0 : .99,
                .coverage=tod.span, .span=tod.span};
            if ([name isEqualToString:@"tariff-export"]) { s.pvW = 4100; s.supplyW = -2100; }
            if ([name isEqualToString:@"tariff-credit"]) {
                s.pvW = 4100; s.supplyW = -2100;
                EBGridCostTotals credit = s.gridCostToday;
                credit.importCost = .99;
                credit.exportCredit = 2.03;
                s.gridCostToday = credit;
            }
            if ([name isEqualToString:@"tariff-credit-import"]) {
                EBGridCostTotals credit = s.gridCostToday;
                credit.importCost = .99;
                credit.exportCredit = 2.03;
                s.gridCostToday = credit;
            }
            if ([name isEqualToString:@"tariff-cost-export"]) {
                s.pvW = 4100; s.supplyW = -2100;
            }
            if ([name isEqualToString:@"tariff-rounding"]) {
                EBGridCostTotals rounded = s.gridCostToday;
                rounded.importCost = 1.005;
                rounded.exportCredit = .004;
                s.gridCostToday = rounded;
            }
            if ([name isEqualToString:@"tariff-balanced"]) {
                EBGridCostTotals balanced = s.gridCostToday;
                balanced.importCost = 1.00;
                balanced.exportCredit = 1.00;
                s.gridCostToday = balanced;
            }
            if ([name isEqualToString:@"tariff-large"]) {
                EBGridCostTotals large = s.gridCostToday;
                large.importCost = 123456.78;
                large.exportCredit = 1234.56;
                s.gridCostToday = large;
            }
            if ([name isEqualToString:@"tariff-partial"]) {
                EBGridCostTotals cost = s.gridCostToday;
                cost.coverage = cost.span * 0.95;
                s.gridCostToday = cost;
            }
            if (unpriced) s.gridCostToday = (EBGridCostTotals){0};
            if ([name isEqualToString:@"tariff-stale"]) {
                s.gridOK = NO; s.gridStale = YES;
                s.gridAsOf = [s.referenceDate dateByAddingTimeInterval:-240];
            }
        }
    } else if ([name isEqualToString:@"night"]) {
        s.pvOK = YES; s.pvW = 0; s.eDayWh = 9000;
        s.gridOK = YES; s.supplyW = 200; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
    } else if ([name isEqualToString:@"evnex-down"]) {
        s.pvOK = YES; s.pvW = 3200; s.eDayWh = 5000;
        s.gridOK = NO; s.chargerOK = NO;
        s.evnexError = @"Evnex auth failed";
    } else if ([name isEqualToString:@"meter-stale"]) {
        s.pvOK = YES; s.pvW = 2800; s.eDayWh = 4500;
        s.gridOK = NO; s.gridStale = YES;
        s.gridAsOf = [s.referenceDate dateByAddingTimeInterval:-240];
        s.supplyW = -400; s.chargeW = 1500;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"SolarControl";
    } else if ([name isEqualToString:@"unknown-ocpp"]) {
        s.pvOK = YES; s.pvW = 3000; s.eDayWh = 4000;
        s.gridOK = YES; s.supplyW = -200; s.chargeW = 1800;
        s.chargerOK = YES; s.haveOcpp = NO;
        s.chargingLogic = @"Transfer"; s.chargingCurrentControl = nil;
    } else if ([name isEqualToString:@"meter-only"]) {
        s.pvOK = YES; s.pvW = 3600; s.eDayWh = 5200;
        s.gridOK = YES; s.supplyW = -300; s.chargeW = 1800;
        s.chargerOK = NO; s.haveOcpp = NO;
        s.evnexError = @"Status unavailable (HTTP 503)";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span;
        tod.chargeCoverage = tod.span; tod.chargeWh = 1400;
    } else if ([name isEqualToString:@"history-down"]) {
        s.pvOK = YES; s.pvW = 4100; s.eDayWh = 24700;
        s.gridOK = YES; s.supplyW = -700; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        s.storageError = @"History unavailable — sample store is not writable";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span; tod.exportWh = 1200;
    } else if ([name isEqualToString:@"vehicle-store-down"]) {
        s.pvOK = YES; s.pvW = 4100; s.eDayWh = 24700;
        s.gridOK = YES; s.supplyW = -700; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        s.vehicleError = @"Vehicle state not saved — permission denied";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span; tod.exportWh = 1200;
    } else if ([name isEqualToString:@"cold-start"]) {
        s.pvOK = YES; s.pvW = 1000; s.eDayWh = 100;
        s.gridOK = YES; s.supplyW = -50; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        tod.span = 3600;
    } else if ([name isEqualToString:@"partial-day"]) {
        s.pvOK = YES; s.pvW = 3500; s.eDayWh = 2000;
        s.gridOK = YES; s.supplyW = -300; s.chargeW = 1000;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"SolarControl";
        tod.span = 15 * 3600;
        tod.pvCoverage = 90 * 60; tod.gridCoverage = 90 * 60; tod.chargeCoverage = 90 * 60;
        tod.exportWh = 200; tod.chargeWh = 150;
    } else if ([name isEqualToString:@"recovered-session"]) {
        s.pvOK = YES; s.pvW = 3300; s.eDayWh = 6100;
        s.gridOK = YES; s.supplyW = -250; s.chargeW = 1400;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"SolarControl";
        s.carDayAvailable = YES; s.carDayWh = 2907; s.carDaySessionCount = 1;
        s.carDayAsOf = s.referenceDate;
        s.pvArchiveAvailable = YES; s.pvArchiveWh = 6030;
        s.pvArchiveIntervalCount = 172;
        tod.span = 15 * 3600;
        tod.gridCoverage = 45 * 60; tod.chargeCoverage = 45 * 60;
        tod.exportWh = 120; tod.chargeWh = 80;
    } else if ([name isEqualToString:@"recovered-offline"]) {
        s.pvOK = NO; s.pvError = @"Fronius unreachable";
        s.gridOK = NO; s.chargerOK = NO; s.evnexError = @"Evnex offline";
        s.carDayAvailable = YES; s.carDayWh = 12907; s.carDaySessionCount = 1;
        s.carDayAsOf = [s.referenceDate dateByAddingTimeInterval:-15 * 60];
        s.carDayStale = YES;
        s.pvArchiveAvailable = YES; s.pvArchiveWh = 26030;
        s.pvArchiveIntervalCount = 172;
        tod.span = 15 * 3600;
    } else if ([name isEqualToString:@"soc-estimated"]) {
        s.pvOK = YES; s.pvW = 4200; s.eDayWh = 7000;
        s.gridOK = YES; s.supplyW = -200; s.chargeW = 2400;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"CHARGING"; s.chargingLogic = @"Transfer";
        s.chargingCurrentControl = @"SolarControl";
        s.vehicleHasSOC = YES; s.vehicleSOC = 58; s.vehicleSOCIsEstimate = YES;
        s.vehicleCapacityWh = 60000; s.vehicleChargeEfficiency = 0.9;
        s.vehicleLine = @"58% · est. from manual 2h ago";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span;
        tod.chargeCoverage = tod.span; tod.chargeWh = 1900;
    } else if ([name isEqualToString:@"soc-after-drive"]) {
        s.pvOK = YES; s.pvW = 3800; s.eDayWh = 6500;
        s.gridOK = YES; s.supplyW = -500; s.chargeW = 0;
        s.chargerOK = YES; s.haveOcpp = YES;
        s.ocppStatus = @"AVAILABLE"; s.chargingLogic = @"NoVehicle";
        s.chargingCurrentControl = @"SolarControl";
        s.vehicleHasSOC = NO; s.vehicleSOCIsEstimate = NO;
        s.vehicleHasStoredState = YES;
        s.vehicleLine = @"Not linked — no anchor";
        tod.pvCoverage = tod.span; tod.gridCoverage = tod.span; tod.exportWh = 800;
    }
    s.today = tod;
    return s;
}

static void EBAssertLayout(NSView *v, const char *state) {
    if (v.hasAmbiguousLayout)
        EBFail("%s: ambiguous layout in %s", state, v.className.UTF8String);
    for (NSView *c in v.subviews) EBAssertLayout(c, state);
}

static void EBAssertNoOverlap(NSView *parent, const char *state) {
    NSArray *kids = parent.subviews;
    for (NSUInteger i = 0; i < kids.count; i++) {
        NSView *a = kids[i];
        if (a.isHidden || NSIsEmptyRect(a.frame)) continue;
        for (NSUInteger j = i + 1; j < kids.count; j++) {
            NSView *b = kids[j];
            if (b.isHidden || NSIsEmptyRect(b.frame)) continue;
            // The trend arrow rides on its gauge by design.
            if ([a.className isEqualToString:@"EBTrendArrow"] || [b.className isEqualToString:@"EBTrendArrow"]) continue;
            NSRect inter = NSIntersectionRect(a.frame, b.frame);
            if (inter.size.width > 1 && inter.size.height > 1)
                EBFail("%s: sibling overlap %s ∩ %s", state, a.className.UTF8String, b.className.UTF8String);
        }
        EBAssertNoOverlap(a, state);
    }
}

static void EBAssertContained(NSView *v, const char *state) {
    for (NSView *c in v.subviews) {
        if (c.isHidden) continue;
        NSRect f = c.frame;
        // Auto Layout text fields often report intrinsic width before compression;
        // allow a few points of overhang and rely on clipsToBounds on cards.
        CGFloat slop = 8;
        if (f.origin.x < -slop || f.origin.y < -slop ||
            NSMaxX(f) > v.bounds.size.width + slop ||
            NSMaxY(f) > v.bounds.size.height + slop)
            EBFail("%s: %s escapes parent", state, c.className.UTF8String);
        EBAssertContained(c, state);
    }
}

static NSUInteger EBCountFonts(NSView *v, NSMutableSet *sizes) {
    if ([v isKindOfClass:NSTextField.class]) {
        NSTextField *tf = (NSTextField *)v;
        if (tf.font) [sizes addObject:@(tf.font.pointSize)];
    }
    for (NSView *c in v.subviews) EBCountFonts(c, sizes);
    return sizes.count;
}

static NSUInteger EBControlWidthCheck(NSView *v, CGFloat maxW, const char *state) {
    NSUInteger bad = 0;
    if ([v isKindOfClass:NSControl.class] && ![v isKindOfClass:NSTextField.class] &&
        v.frame.size.width > maxW * 0.70 + 1)
        { EBFail("%s: control wider than 70%% (%.0f)", state, v.frame.size.width); bad++; }
    for (NSView *c in v.subviews) bad += EBControlWidthCheck(c, maxW, state);
    return bad;
}

static NSBitmapImageRep *EBRender(NSView *root, BOOL dark) {
    [root layoutSubtreeIfNeeded];
    NSSize sz = root.fittingSize;
    if (sz.width < 10) sz = root.frame.size;
    if (sz.height < 10) sz.height = 420;
    root.frame = NSMakeRect(0, 0, sz.width, sz.height);
    [root layoutSubtreeIfNeeded];

    NSAppearance *appearance =
        [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:root.frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.appearance = appearance;

    // Offscreen has no NSPopover chrome — paint an opaque stage so dark labelColor
    // doesn't composite onto an unpainted (white) page and vanish.
    NSView *stage = [[NSView alloc] initWithFrame:root.frame];
    stage.wantsLayer = YES;
    w.contentView = stage;
    root.frame = stage.bounds;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [stage addSubview:root];
    [w orderFront:nil];
    [root layoutSubtreeIfNeeded];

    __block NSBitmapImageRep *rep = nil;
    [appearance performAsCurrentDrawingAppearance:^{
        NSColor *page = NSColor.windowBackgroundColor;
        stage.layer.backgroundColor = page.CGColor;
        root.wantsLayer = YES;
        root.layer.backgroundColor = page.CGColor;
        w.backgroundColor = page;

        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            NSView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v respondsToSelector:@selector(viewDidChangeEffectiveAppearance)])
                [v viewDidChangeEffectiveAppearance];
            if ([v respondsToSelector:@selector(reload)])
                [(id)v reload];
            for (NSView *c in v.subviews) [stack addObject:c];
        }
        [stage layoutSubtreeIfNeeded];
        [stage displayIfNeeded];
        NSInteger pixelsWide = (NSInteger)ceil(NSWidth(stage.bounds) * 2.0);
        NSInteger pixelsHigh = (NSInteger)ceil(NSHeight(stage.bounds) * 2.0);
        rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                     pixelsWide:pixelsWide
                                                     pixelsHigh:pixelsHigh
                                                  bitsPerSample:8
                                                samplesPerPixel:4
                                                       hasAlpha:YES
                                                       isPlanar:NO
                                                 colorSpaceName:NSDeviceRGBColorSpace
                                                    bytesPerRow:0
                                                   bitsPerPixel:0];
        rep.size = stage.bounds.size;
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = context;
        [stage displayRectIgnoringOpacity:stage.bounds inContext:context];
        [context flushGraphics];
        [NSGraphicsContext restoreGraphicsState];
    }];
    [w orderOut:nil];
    return rep;
}

static NSRect EBPixelRect(NSRect viewRect, NSView *root, NSBitmapImageRep *rep) {
    CGFloat sx = (CGFloat)rep.pixelsWide / MAX(1.0, root.bounds.size.width);
    CGFloat sy = (CGFloat)rep.pixelsHigh / MAX(1.0, root.bounds.size.height);
    // cacheDisplay bitmaps: colorAtX:y: origin is top-left; view coords are bottom-left
    CGFloat top = root.isFlipped ? viewRect.origin.y : root.bounds.size.height - NSMaxY(viewRect);
    return NSMakeRect(viewRect.origin.x * sx, top * sy,
                      viewRect.size.width * sx, viewRect.size.height * sy);
}

static double EBRelLuminance(NSColor *c) {
    c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c) return 0;
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    double (^lin)(double) = ^double(double v) {
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

static double EBContrastRatio(NSColor *a, NSColor *b) {
    double L1 = EBRelLuminance(a), L2 = EBRelLuminance(b);
    double hi = fmax(L1, L2), lo = fmin(L1, L2);
    return (hi + 0.05) / (lo + 0.05);
}

static NSColor *EBSampleAvg(NSBitmapImageRep *rep, NSInteger x0, NSInteger y0, NSInteger w, NSInteger h) {
    double sr = 0, sg = 0, sb = 0;
    NSInteger n = 0;
    NSInteger x1 = MIN(rep.pixelsWide, x0 + w);
    NSInteger y1 = MIN(rep.pixelsHigh, y0 + h);
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    for (NSInteger y = y0; y < y1; y++) {
        for (NSInteger x = x0; x < x1; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!c) continue;
            CGFloat r, g, b, a;
            [c getRed:&r green:&g blue:&b alpha:&a];
            sr += r; sg += g; sb += b; n++;
        }
    }
    if (!n) return [NSColor colorWithSRGBRed:0.5 green:0.5 blue:0.5 alpha:1];
    return [NSColor colorWithSRGBRed:sr / n green:sg / n blue:sb / n alpha:1];
}

/// Ink = pixel in the text rect farthest (RGB) from the backdrop sample.
static NSColor *EBSampleInk(NSBitmapImageRep *rep, NSRect textPx, NSColor *bg) {
    CGFloat br, bg_, bb, ba;
    [bg getRed:&br green:&bg_ blue:&bb alpha:&ba];
    double best = -1;
    CGFloat ir = br, ig = bg_, ib = bb;
    NSInteger x0 = MAX(0, (NSInteger)textPx.origin.x);
    NSInteger y0 = MAX(0, (NSInteger)textPx.origin.y);
    NSInteger x1 = MIN(rep.pixelsWide, (NSInteger)NSMaxX(textPx));
    NSInteger y1 = MIN(rep.pixelsHigh, (NSInteger)NSMaxY(textPx));
    for (NSInteger y = y0; y < y1; y += 1) {
        for (NSInteger x = x0; x < x1; x += 1) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!c) continue;
            CGFloat r, g, b, a;
            [c getRed:&r green:&g blue:&b alpha:&a];
            double d = fabs(r - br) + fabs(g - bg_) + fabs(b - bb);
            if (d > best) { best = d; ir = r; ig = g; ib = b; }
        }
    }
    return [NSColor colorWithSRGBRed:ir green:ig blue:ib alpha:1];
}

static void EBAssertTextContrast(NSView *v, NSBitmapImageRep *rep, NSView *root,
                                 NSAppearance *appearance, const char *state) {
    (void)appearance;
    if ([v isKindOfClass:NSTextField.class]) {
        NSTextField *tf = (NSTextField *)v;
        if (!tf.hiddenOrHasHiddenAncestor && tf.stringValue.length > 0 && tf.frame.size.width > 2 && tf.frame.size.height > 2) {
            NSRect vf = [tf convertRect:tf.bounds toView:root];
            NSRect px = EBPixelRect(vf, root, rep);
            NSView *parent = tf.superview ?: root;
            NSRect parentF = [parent convertRect:parent.bounds toView:root];
            NSRect parentPx = EBPixelRect(parentF, root, rep);
            // Backdrop: top-right padding of parent (avoids accent rule + glyphs)
            NSInteger bx = (NSInteger)(NSMaxX(parentPx) - 8);
            NSInteger by = (NSInteger)(parentPx.origin.y + 4);
            NSColor *bg = EBSampleAvg(rep, bx - 2, by, 4, 4);
            NSColor *ink = EBSampleInk(rep, px, bg);
            double ratio = EBContrastRatio(ink, bg);
            // Ignore near-empty fields (no ink found → ratio ~1)
            CGFloat br, bg_, bb, ba, ir, ig, ib, ia;
            [bg getRed:&br green:&bg_ blue:&bb alpha:&ba];
            [ink getRed:&ir green:&ig blue:&ib alpha:&ia];
            double inkDelta = fabs(ir - br) + fabs(ig - bg_) + fabs(ib - bb);
            if (inkDelta < 0.08)
                EBFail("%s: no visible ink for \"%s\"", state, tf.stringValue.UTF8String);
            else if (ratio < 4.5)
                EBFail("%s: contrast %.1f:1 for \"%s\"", state, ratio,
                       tf.stringValue.UTF8String);
        }
    }
    for (NSView *c in v.subviews)
        EBAssertTextContrast(c, rep, root, appearance, state);
}

static void EBAssertNoTruncate(NSView *v, const char *state) {
    if ([v isKindOfClass:NSTextField.class]) {
        NSTextField *tf = (NSTextField *)v;
        if (!tf.hidden && tf.stringValue.length > 0 && tf.frame.size.width > 1) {
            BOOL wraps = (tf.maximumNumberOfLines == 0 || tf.maximumNumberOfLines > 1);
            if (wraps) {
                NSSize fit = [tf sizeThatFits:NSMakeSize(tf.frame.size.width, 400)];
                if (fit.height > tf.frame.size.height + 1.0)
                    EBFail("%s: '%s' height-clipped", state, tf.stringValue.UTF8String);
            } else {
                CGFloat want = tf.intrinsicContentSize.width;
                if (want > tf.frame.size.width + 0.5)
                    EBFail("%s: '%s' truncated (want %.0f have %.0f)", state,
                           tf.stringValue.UTF8String, want, tf.frame.size.width);
            }
        }
    }
    if ([v isKindOfClass:NSButton.class]) {
        NSButton *b = (NSButton *)v;
        if (!b.hidden && b.title.length > 0 && b.image == nil && b.frame.size.width > 1) {
            CGFloat want = b.intrinsicContentSize.width;
            if (want > b.frame.size.width + 1.0)
                EBFail("%s: button '%s' truncated", state, b.title.UTF8String);
        }
    }
    for (NSView *c in v.subviews) EBAssertNoTruncate(c, state);
}

static int EBDistinctHues(NSBitmapImageRep *rep, NSRect r, double minSat) {
    NSMutableSet *buckets = [NSMutableSet set];
    NSInteger x0 = (NSInteger)r.origin.x, y0 = (NSInteger)r.origin.y;
    NSInteger x1 = (NSInteger)NSMaxX(r), y1 = (NSInteger)NSMaxY(r);
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    x1 = MIN(rep.pixelsWide, x1); y1 = MIN(rep.pixelsHigh, y1);
    for (NSInteger y = y0; y < y1; y += 2) {
        for (NSInteger x = x0; x < x1; x += 2) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            if (!c) continue;
            CGFloat h, s, b, a;
            [c getHue:&h saturation:&s brightness:&b alpha:&a];
            if (s < minSat || b < 0.15 || a < 0.5) continue;
            [buckets addObject:@((int)(h * 12))];
        }
    }
    return (int)buckets.count;
}

static BOOL EBRectHasTint(NSBitmapImageRep *rep, NSRect r, BOOL red) {
    NSInteger x0 = MAX(0, (NSInteger)r.origin.x), y0 = MAX(0, (NSInteger)r.origin.y);
    NSInteger x1 = MIN(rep.pixelsWide, (NSInteger)NSMaxX(r)), y1 = MIN(rep.pixelsHigh, (NSInteger)NSMaxY(r));
    for (NSInteger y = y0; y < y1; y += 1) {
        for (NSInteger x = x0; x < x1; x += 1) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat h, sat, bri, alpha;
            [c getHue:&h saturation:&sat brightness:&bri alpha:&alpha];
            if (sat < 0.25 || bri < 0.2 || alpha < 0.5) continue;
            if (red ? (h < 0.08 || h > 0.94) : (h > 0.20 && h < 0.48)) return YES;
        }
    }
    return NO;
}

static NSUInteger EBVisibleGridGauges(EBInstrumentRow *row) {
    NSUInteger count = 0;
    for (NSView *sub in row.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if (([name isEqualToString:@"EBGauge"] || [name isEqualToString:@"EBGridBalanceGauge"]) &&
            !sub.hidden) count++;
    }
    return count;
}

static BOOL EBViewContainsText(NSView *view, NSString *needle) {
    if (view.hidden) return NO;
    if ([view isKindOfClass:NSTextField.class] &&
        [((NSTextField *)view).stringValue containsString:needle]) return YES;
    for (NSView *sub in view.subviews)
        if (EBViewContainsText(sub, needle)) return YES;
    return NO;
}

static double EBInkCoverage(NSBitmapImageRep *rep, NSRect r) {
    NSInteger x0 = MAX(0, (NSInteger)r.origin.x), y0 = MAX(0, (NSInteger)r.origin.y);
    NSInteger x1 = MIN(rep.pixelsWide, (NSInteger)NSMaxX(r));
    NSInteger y1 = MIN(rep.pixelsHigh, (NSInteger)NSMaxY(r));
    if (x1 <= x0 || y1 <= y0) return 0;
    // Modal approx: sample centre
    NSColor *bg = [[rep colorAtX:(x0+x1)/2 y:(y0+y1)/2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    CGFloat br, bgG, bb, ba;
    [bg getRed:&br green:&bgG blue:&bb alpha:&ba];
    NSInteger ink = 0, tot = 0;
    for (NSInteger y = y0; y < y1; y += 2) {
        for (NSInteger x = x0; x < x1; x += 2) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            CGFloat r1, g1, b1, a1;
            [c getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
            double d = fabs(r1-br)+fabs(g1-bgG)+fabs(b1-bb);
            if (d > 0.15) ink++;
            tot++;
        }
    }
    return tot ? (double)ink / tot : 0;
}

static void EBWritePNG(NSBitmapImageRep *rep, NSString *path) {
    NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:YES];
}

static double EBPixelDiff(NSBitmapImageRep *a, NSBitmapImageRep *b) {
    if (a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh) return 1.0;
    NSInteger diff = 0, tot = 0;
    for (NSInteger y = 0; y < a.pixelsHigh; y += 2) {
        for (NSInteger x = 0; x < a.pixelsWide; x += 2) {
            NSColor *ca = [[a colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            NSColor *cb = [[b colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            CGFloat ar, ag, ab, aa, br, bg, bb, ba;
            [ca getRed:&ar green:&ag blue:&ab alpha:&aa];
            [cb getRed:&br green:&bg blue:&bb alpha:&ba];
            if (fabs(ar-br)+fabs(ag-bg)+fabs(ab-bb) > 0.08) diff++;
            tot++;
        }
    }
    return tot ? (double)diff / tot : 0;
}

static void EBCompositeContact(NSArray<NSString *> *paths, NSString *outPath) {
    if (paths.count == 0) return;
    NSMutableArray *imgs = [NSMutableArray array];
    CGFloat maxW = 0, maxH = 0;
    for (NSString *p in paths) {
        NSImage *im = [[NSImage alloc] initWithContentsOfFile:p];
        if (!im) continue;
        [imgs addObject:im];
        maxW = MAX(maxW, im.size.width);
        maxH = MAX(maxH, im.size.height);
    }
    NSInteger cols = 3;
    NSInteger rows = (imgs.count + cols - 1) / cols;
    NSImage *sheet = [[NSImage alloc] initWithSize:NSMakeSize(maxW * cols, maxH * rows)];
    [sheet lockFocus];
    [[NSColor blackColor] setFill];
    NSRectFill(NSMakeRect(0, 0, sheet.size.width, sheet.size.height));
    for (NSUInteger i = 0; i < imgs.count; i++) {
        NSInteger col = i % cols, row = i / cols;
        NSImage *im = imgs[i];
        [im drawInRect:NSMakeRect(col * maxW, (rows - 1 - row) * maxH, im.size.width, im.size.height)
              fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    }
    [sheet unlockFocus];
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:sheet.TIFFRepresentation];
    EBWritePNG(rep, outPath);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++)
            if (strcmp(argv[i], "--accept-snapshots") == 0) gAccept = YES;
            else if (strcmp(argv[i], "--skip-pixel-snapshots") == 0) gCompareSnapshots = NO;

        [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [NSApplication sharedApplication];
        {
            EBChartView *chart = [[EBChartView alloc] initWithFrame:NSMakeRect(0, 0, 368, 150)];
            chart.referenceDate = EBFixedDate();
            chart.windowSeconds = 48 * 3600;
            chart.samples = @[@{@"t": [EBFixedDate() dateByAddingTimeInterval:-60],
                                  @"pvW": @0, @"supplyW": @800, @"chargeW": @300}];
            NSString *tip = [chart view:chart stringForToolTip:0 point:NSZeroPoint userData:(void *)(intptr_t)63];
            EBExpect([tip containsString:@"Import 0.8 kW"], "hover gives the whole import stack without mental addition");
            EBExpect([tip containsString:@"Aug"], "long-window hover includes a calendar date");
            EBExpect([chart.accessibilityLabel containsString:@"grid import below zero"],
                     "chart direction and scale are accessible");
            chart.samples = @[];
            EBExpect([chart.accessibilityLabel isEqualToString:@"No power history yet"],
                     "empty history is not announced as a zero reading");
        }
        {
            EBChartScale scale = EBChartMakeScale(4500, 1600);
            EBExpect(scale.solarW == 5000 && scale.importW == 2000 && scale.stepW == 1000,
                     "day chart rounds its limits to readable kW values");
            double pairs[][2] = {{0, 0}, {0, 200}, {0, 10500}, {10500, 0}, {200, 4500}, {NAN, INFINITY}};
            for (NSUInteger i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
                scale = EBChartMakeScale(pairs[i][0], pairs[i][1]);
                EBExpect(isfinite(scale.solarW) && isfinite(scale.importW) && scale.stepW > 0,
                         "quiet, import-only and invalid inputs keep a finite scale");
                EBExpect(scale.solarW >= 500 && scale.importW >= 500,
                         "quiet chart does not magnify standby power");
                double total = scale.solarW + scale.importW;
                EBExpect(fmin(scale.solarW, scale.importW) / total * 126 >= 32,
                         "both direction labels stay clear of zero on an asymmetric scale");
                if (isfinite(pairs[i][0]) && isfinite(pairs[i][1]))
                    EBExpect(scale.solarW >= pairs[i][0] && scale.importW >= pairs[i][1],
                             "rounded limits contain every bar");
            }
        }
        NSArray *states = @[@"sunny-export", @"solar-charging", @"charge-now-importing", @"night",
                            @"evnex-down", @"meter-stale", @"unknown-ocpp", @"meter-only",
                            @"history-down", @"vehicle-store-down", @"cold-start",
                            @"partial-day", @"recovered-session", @"recovered-offline", @"soc-estimated",
                            @"soc-after-drive", @"evening", @"history-48h", @"high-power",
                            @"tariff-import", @"tariff-export", @"tariff-credit", @"tariff-credit-import",
                            @"tariff-cost-export", @"tariff-rounding", @"tariff-balanced", @"tariff-large",
                            @"tariff-partial", @"tariff-stale", @"tariff-zero", @"tariff-invalid", @"tariff-unpriced",
                            @"tariff-history-48h"];
        NSString *renderDir = [EBRepoRoot() stringByAppendingPathComponent:@"build/render"];
        NSString *snapDir = [EBRepoRoot() stringByAppendingPathComponent:@"Tests/snapshots"];
        [[NSFileManager defaultManager] createDirectoryAtPath:renderDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:snapDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSArray *samples = EBSynthSamples();
        NSMutableArray *pngs = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *baselineWrites = [NSMutableArray array];

        for (NSString *name in states) {
            for (int dark = 0; dark < 2; dark++) {
                EBPopoverViews *pv = EBBuildPopover(nil);
                EBSnapshotView *snap = EBState(name);
                NSArray *samp = [name isEqualToString:@"cold-start"] ? @[] : samples;
                if ([name isEqualToString:@"evening"] || [name isEqualToString:@"high-power"] ||
                    [name isEqualToString:@"history-48h"] || [name hasPrefix:@"tariff-"]) {
                    BOOL longWindow = [name isEqualToString:@"history-48h"] || [name isEqualToString:@"tariff-history-48h"];
                    pv.windowSeg.selectedSegment = longWindow ? 1 : 0;
                    pv.chart.windowSeconds = (longWindow ? 48 : 12) * 3600;
                    samp = EBDaylightSamples(snap.referenceDate, pv.chart.windowSeconds);
                }
                // NSPopover insets its content view; a refresh must not move it.
                [pv.root setFrameOrigin:NSMakePoint(7, 13)];
                EBApplySnapshot(pv, snap, samp);
                EBExpect(NSEqualPoints(pv.root.frame.origin, NSMakePoint(7, 13)),
                         "refresh keeps the popover's content origin");
                [pv.root setFrameOrigin:NSZeroPoint];
                [pv.root layoutSubtreeIfNeeded];

                const char *st = [[NSString stringWithFormat:@"%@-%@", name, dark ? @"dark" : @"light"] UTF8String];
                EBAssertLayout(pv.root, st);
                EBAssertNoOverlap(pv.root, st);
                EBAssertContained(pv.root, st);
                EBAssertNoTruncate(pv.root, st);

                // Restraint: arranged subviews on root stack
                if ([pv.root isKindOfClass:NSStackView.class]) {
                    NSStackView *sv = (NSStackView *)pv.root;
                    EBExpect(sv.arrangedSubviews.count <= 5, "root has ≤5 arranged subviews");
                }
                NSMutableSet *fonts = [NSMutableSet set];
                EBCountFonts(pv.root, fonts);
                EBExpect(fonts.count <= 5, "≤5 font sizes");
                EBControlWidthCheck(pv.root, 400, st);

                if ([name isEqualToString:@"tariff-import"]) {
                    EBExpect([pv.gridRow.title isEqualToString:@"Import"], "live import has an explicit instrument name");
                    EBExpect([pv.gridRow.subline isEqualToString:@"6.1 kWh today"], "import row keeps the recorded energy datum");
                    EBExpect([pv.gridRow.toolTip containsString:@"out 13.9 kWh"] && [pv.gridRow.toolTip containsString:@"$0.99 credit"], "both directional totals remain available together");
                    EBExpect([pv.gridRow.toolTip containsString:@"now $0.30/h cost"], "live hourly cost uses the active import rate");
                    EBExpect([pv.gridRow.balanceGauge.period isEqualToString:@"Today"], "balance period is explicit");
                    EBExpect([pv.gridRow.balanceGauge.importValue isEqualToString:@"$2.03"], "balance shows import cost");
                    EBExpect([pv.gridRow.balanceGauge.exportValue isEqualToString:@"$0.99"], "balance shows export credit");
                    EBExpect([pv.gridRow.balanceGauge.netValue isEqualToString:@"−$1.04"], "balance shows signed net cost");
                    EBExpect([pv.gridRow.balanceGauge.displayText isEqualToString:@"−$1.04 net today"],
                             "integrated datum names the signed daily net");
                    EBExpect(!pv.gridRow.balanceGauge.partial, "complete pricing has an unqualified today period");
                    EBExpect(fabs(pv.gridRow.balanceGauge.importAmount - 2.03) < 0.001 &&
                             fabs(pv.gridRow.balanceGauge.exportAmount - 0.99) < 0.001 && pv.gridRow.balanceGauge.amountsAvailable,
                             "balance exposes rounded gross major-unit amounts");
                    NSRect bar = pv.gridRow.balanceGauge.barRect;
                    EBExpect(fabs(bar.origin.x) < 0.5 && fabs(bar.origin.y) < 0.5 &&
                             fabs(bar.size.width - 68) < 0.5 && fabs(bar.size.height - 8) < 0.5,
                             "balance bar uses the existing gauge geometry");
                    EBExpect(fabs(pv.gridRow.balanceGauge.offsetRect.size.width / bar.size.width - 0.99 / 2.03) < 0.01 &&
                             fabs(pv.gridRow.balanceGauge.remainderRect.size.width / bar.size.width - 1.04 / 2.03) < 0.01,
                             "offset bar uses the larger gross amount as denominator");
                    // The Grid bar is the live flow; the day's money is a figure in Today, not a bar.
                    EBExpect(pv.gridRow.balanceGauge.superview == nil && EBVisibleGridGauges(pv.gridRow) == 1 &&
                             fabs(pv.solarRow.frame.size.height - 30) < 0.5 &&
                             fabs(pv.gridRow.frame.size.height - 30) < 0.5 &&
                             fabs(pv.carRow.frame.size.height - 30) < 0.5 &&
                             fabs(NSMinY(pv.gridRow.frame) - NSMaxY(pv.solarRow.frame)) < 0.5 &&
                             fabs(NSMinY(pv.carRow.frame) - NSMaxY(pv.gridRow.frame)) < 0.5,
                             "the Grid row shows one live-flow bar; the money is not drawn as a bar");
                    EBExpect(pv.solarButton.action == @selector(doSolar:) &&
                             [pv.solarButton.toolTip isEqualToString:@"Charge from surplus solar"] &&
                             [pv.solarButton.accessibilityLabel containsString:@"Solar only"] &&
                             pv.chargeNowButton.action == @selector(doChargeNow:),
                             "footer controls retain explicit remote actions");
                    EBExpect(fabs(pv.nowCaption.frame.origin.y - pv.todayCaption.frame.origin.y) < 0.5 &&
                             fabs(NSMaxX(pv.nowCaption.frame) - pv.todayCaption.frame.origin.x + 6) < 0.5 &&
                             fabs(pv.todayCaption.frame.origin.x - (EBPanelW - EBPad - EBDatumColumnW)) < 0.5 &&
                             pv.totalsDivider.frame.size.width <= 1.5,
                             "Now and Today captions align to the existing value and datum columns");
                    EBExpect(EBViewContainsText(pv.solarRow, @"24.9 kWh") &&
                             !EBViewContainsText(pv.solarRow, @"today") &&
                             EBViewContainsText(pv.solarRow, @"0.0 kW") &&
                             EBViewContainsText(pv.gridRow, @"−$1.04") &&
                             !EBViewContainsText(pv.gridRow, @" net"),
                             "rendered daily columns show compact totals beside power-now values");
                }
                if ([name isEqualToString:@"tariff-export"]) {
                    EBExpect([pv.gridRow.title isEqualToString:@"Export"], "live export has an explicit instrument name");
                    EBExpect([pv.gridRow.subline isEqualToString:@"13.9 kWh today"], "export row keeps the recorded energy datum");
                    EBExpect([pv.gridRow.toolTip containsString:@"/h credit"], "export hourly value is named credit");
                }
                if ([name isEqualToString:@"tariff-credit"])
                    EBExpect([pv.gridRow.balanceGauge.netValue isEqualToString:@"+$1.04"] &&
                             fabs(pv.gridRow.balanceGauge.offsetRect.size.width / pv.gridRow.balanceGauge.barRect.size.width - 0.99 / 2.03) < 0.01 &&
                             fabs(pv.gridRow.balanceGauge.remainderRect.size.width / pv.gridRow.balanceGauge.barRect.size.width - 1.04 / 2.03) < 0.01,
                             "positive net reverses the tail colour without changing bar geometry");
                if ([name isEqualToString:@"tariff-credit-import"])
                    EBExpect([pv.gridRow.title isEqualToString:@"Import"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"+$1.04"],
                             "positive net is a credit even while current direction is import");
                if ([name isEqualToString:@"tariff-cost-export"])
                    EBExpect([pv.gridRow.title isEqualToString:@"Export"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"−$1.04"],
                             "negative net is a cost even while current direction is export");
                if ([name isEqualToString:@"tariff-rounding"])
                    EBExpect([pv.gridRow.balanceGauge.importValue isEqualToString:@"$1.01"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"$0.00"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"−$1.01"],
                             "net uses cent-rounded gross amounts");
                if ([name isEqualToString:@"tariff-balanced"])
                    EBExpect([pv.gridRow.balanceGauge.importValue isEqualToString:@"$1.00"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"$1.00"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"$0.00"] &&
                             pv.gridRow.balanceGauge.offsetRect.size.width > pv.gridRow.balanceGauge.barRect.size.width * .99 &&
                             pv.gridRow.balanceGauge.remainderRect.size.width < 0.5 &&
                             ![pv.gridRow.balanceGauge.netValue containsString:@"+"],
                             "nonzero balanced gross values have no net sign");
                if ([name isEqualToString:@"tariff-large"]) {
                    EBExpect([pv.gridRow.balanceGauge.importValue containsString:@"$123,456.78"] &&
                             [pv.gridRow.balanceGauge.exportValue containsString:@"$1,234.56"] &&
                             [pv.gridRow.balanceGauge.netValue containsString:@"k"],
                             "gross labels retain full money while large net compacts");
                    EBExpect([pv.gridRow.balanceGauge.toolTip containsString:@"$123,456.78"] &&
                             [pv.gridRow.balanceGauge.accessibilityLabel containsString:@"$123,456.78"],
                             "compacted money retains full cents in tooltip and accessibility");
                    EBPopoverViews *extreme = EBBuildPopover(nil);
                    EBSnapshotView *huge = EBState(@"tariff-large");
                    EBGridCostTotals totals = huge.gridCostToday;
                    totals.importCost = 1e16;
                    huge.gridCostToday = totals;
                    EBApplySnapshot(extreme, huge, samp);
                    EBExpect([extreme.gridRow.balanceGauge.netValue isEqualToString:@"…"],
                             "unrepresentable net uses an explicit overflow mark instead of clipping");
                    EBAssertNoTruncate(extreme.gridRow, "extreme-money");
                }
                if ([name isEqualToString:@"tariff-history-48h"])
                    EBExpect([pv.gridRow.balanceGauge.period isEqualToString:@"Today"] &&
                             [pv.gridRow.balanceGauge.importValue isEqualToString:@"$2.03"],
                             "48-hour chart keeps the balance period as today");
                if ([name isEqualToString:@"tariff-partial"]) {
                    EBExpect([pv.gridRow.subline isEqualToString:@"≥6.1 kWh today"] &&
                             [pv.gridRow.balanceGauge.period isEqualToString:@"Recorded"] &&
                             [pv.gridRow.balanceGauge.importValue isEqualToString:@"$2.03"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"$0.99"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"−$1.04"] &&
                             [pv.gridRow.balanceGauge.displayText isEqualToString:@"−$1.04 net partial"] &&
                             pv.gridRow.balanceGauge.partial &&
                             [pv.gridRow.balanceGauge.toolTip containsString:@"partial"],
                             "partial pricing shows exact recorded gross values and a signed recorded net");
                    EBExpect(pv.gridRow.balanceGauge.partial && pv.gridRow.balanceGauge.offsetRect.size.width > 0 &&
                             pv.gridRow.balanceGauge.remainderRect.size.width > 0,
                             "partial history retains the recorded offset geometry");
                }
                if ([name isEqualToString:@"tariff-partial"])
                    EBExpect(![pv.gridRow.balanceGauge.accessibilityLabel containsString:@"≥"] &&
                             [pv.gridRow.balanceGauge.accessibilityLabel containsString:@"Import cost $2.03"] &&
                             [pv.gridRow.balanceGauge.accessibilityLabel containsString:@"Recorded today, partial history"],
                             "spoken balance uses the same recorded amounts and partial meaning");
                if ([name isEqualToString:@"tariff-stale"])
                    EBExpect([pv.gridRow.subline containsString:@"stale"] &&
                             [pv.gridRow.accessibilityLabel containsString:@"stale"] &&
                             [pv.gridRow.toolTip containsString:@"stale"] &&
                             ![pv.gridRow.toolTip containsString:@"/h "] &&
                             !pv.gridRow.balanceGauge.hidden &&
                             [pv.gridRow.balanceGauge.importValue isEqualToString:@"$2.03"],
                             "stale live meter cannot claim current hourly cost while daily finance survives");
                if ([name isEqualToString:@"tariff-zero"])
                    EBExpect([pv.gridRow.balanceGauge.importValue isEqualToString:@"$0.00"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"$0.00"] &&
                             [pv.gridRow.balanceGauge.netValue isEqualToString:@"$0.00"], "configured zero rate remains a real free reading");
                if ([name isEqualToString:@"evening"])
                    EBExpect(pv.gridRow.balanceGauge.hidden && EBVisibleGridGauges(pv.gridRow) == 1 &&
                             ![pv.gridRow.subline containsString:@"$"],
                             "missing tariff falls back to one ordinary grid gauge without inventing a free rate");
                if ([name isEqualToString:@"tariff-invalid"])
                    EBExpect(!pv.gridRow.balanceGauge.hidden && [pv.gridRow.balanceGauge.importValue isEqualToString:@"—"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"—"] && [pv.gridRow.balanceGauge.netValue isEqualToString:@"—"] &&
                             EBVisibleGridGauges(pv.gridRow) == 1,
                             "invalid tariff shows unavailable balance values");
                if ([name isEqualToString:@"tariff-unpriced"])
                    EBExpect(!pv.gridRow.balanceGauge.hidden && [pv.gridRow.balanceGauge.importValue isEqualToString:@"—"] &&
                             [pv.gridRow.balanceGauge.exportValue isEqualToString:@"—"] && [pv.gridRow.balanceGauge.netValue isEqualToString:@"—"] &&
                             EBVisibleGridGauges(pv.gridRow) == 1,
                             "unpriced history shows unavailable balance values");
                if ([name isEqualToString:@"tariff-zero"] || [name isEqualToString:@"tariff-invalid"] ||
                    [name isEqualToString:@"tariff-unpriced"])
                    EBExpect(pv.gridRow.balanceGauge.offsetRect.size.width < 0.5 && pv.gridRow.balanceGauge.remainderRect.size.width < 0.5,
                             "zero or unavailable values do not paint a false bar fill");
                if ([name isEqualToString:@"tariff-unpriced"] || [name isEqualToString:@"tariff-invalid"])
                    EBExpect([pv.gridRow.balanceGauge.accessibilityLabel containsString:@"unavailable"] &&
                             ![pv.gridRow.balanceGauge.accessibilityLabel containsString:@"Estimated energy charges"],
                             "unavailable money is announced as unavailable rather than an estimate");

                if ([name isEqualToString:@"unknown-ocpp"])
                    EBExpect([pv.statusLabel isEqualToString:@"Matching solar"], "unknown ocpp still matching");
                if ([name isEqualToString:@"sunny-export"])
                    EBExpect([pv.statusLabel isEqualToString:@"Surplus unused"], "sunny export match pill");
                if ([name isEqualToString:@"solar-charging"])
                    EBExpect([pv.statusLabel isEqualToString:@"Matching solar"], "solar charging match pill");
                if ([name isEqualToString:@"charge-now-importing"])
                    EBExpect([pv.statusLabel isEqualToString:@"Charging from grid"] &&
                             [pv.carRow.subline isEqualToString:@"5.0 kWh today"] &&
                             EBViewContainsText(pv.carRow, @"5.0 kWh") &&
                             !EBViewContainsText(pv.carRow, @"from grid") &&
                             [pv.carRow.toolTip containsString:@"4.0 kWh from the grid"],
                             "car row keeps total daily energy while tooltip retains the grid portion");
                if ([name isEqualToString:@"partial-day"])
                    EBExpect([pv.gridRow.toolTip containsString:@"partial"] ||
                             [pv.carRow.subline hasPrefix:@"≥"], "partial day noted");
                if ([name isEqualToString:@"recovered-session"]) {
                    EBExpect([pv.carRow.subline containsString:@"2.9 kWh exact"],
                             "recovered session total is visibly metered");
                }
                if ([name isEqualToString:@"recovered-offline"]) {
                    EBExpect([pv.solarRow.subline containsString:@"≥26.0 kWh"],
                             "archive total survives a current Fronius outage");
                    EBExpect([pv.carRow.subline containsString:@"2.9 kWh @03:45"],
                             "session total remains visible with a truthful stale timestamp");
                }
                // Tooltips are terse: one line of figures, never a paragraph (Glancebar's rule).
                for (NSView *tipped in @[pv.solarRow, pv.gridRow, pv.carRow, pv.solarButton, pv.chargeNowButton,
                                         pv.nowCaption, pv.todayCaption])
                    if (tipped.toolTip.length > 90 || [tipped.toolTip containsString:@"\n"])
                        EBFail("%s: wordy tooltip: %s", st, tipped.toolTip.UTF8String);
                if ([name isEqualToString:@"solar-charging"])
                    EBExpect(fabs(pv.solarRow.gaugeFraction - 0.96) < 0.001, "solar bar is full at the inverter's 5 kW");
                if ([name isEqualToString:@"soc-estimated"]) {
                    // The pack level rides on the Car row (Glancebar's quantity-plus-flow language).
                    EBExpect(pv.batteryRow.hidden, "soc-estimated folds the battery into the Car row");
                    EBExpect(fabs(pv.carRow.gaugeFraction - 0.58) < 0.001, "car bar is the 58% pack level");
                    EBExpect(fabs(pv.carRow.trendTo - (0.58 + 2400 * 0.9 / 60000)) < 0.001,
                             "trend arrow runs to the level an hour of charging reaches");
                    EBExpect([pv.carRow.toolTip containsString:@"battery 58% est."],
                             "estimated provenance is on the Car row's tooltip");
                    EBExpect(![pv.carRow.subline containsString:@"est."], "no estimate word on the row itself");
                    EBExpect([pv.carRow.accessibilityLabel containsString:@"battery 58% estimated"],
                             "estimated SoC preserves accessibility provenance");
                }
                if ([name isEqualToString:@"soc-after-drive"]) {
                    EBExpect(pv.batteryRow.hidden && pv.carRow.trendTo < 0, "after drive SoC absent: no pack bar or arrow");
                    NSMenuItem *vehicle = [pv.gearMenu itemWithTag:9001];
                    NSMenuItem *clear = [vehicle.submenu itemWithTitle:@"Clear vehicle data"];
                    EBExpect(clear.enabled,
                             "tombstone-only vehicle state remains explicitly clearable");
                }
                if ([name isEqualToString:@"meter-only"]) {
                    EBExpect([pv.carRow.value isEqualToString:@"1.8"],
                             "meter-only power remains visible without status");
                    EBExpect([pv.statusLabel isEqualToString:@"Matching solar"],
                             "fresh independent meter data can classify the energy match");
                }
                if ([name isEqualToString:@"meter-stale"]) {
                    EBExpect([pv.statusLabel isEqualToString:@"Grid data unknown"],
                             "stale meter cannot claim a current energy match");
                }
                if ([name isEqualToString:@"history-down"]) {
                    EBExpect(!pv.faultRow.hidden && [pv.faultLabel.stringValue containsString:@"History"],
                             "history persistence failure is visible");
                }
                if ([name isEqualToString:@"vehicle-store-down"]) {
                    EBExpect([pv.statusLabel isEqualToString:@"Vehicle state not saved"] &&
                             !pv.faultRow.hidden, "vehicle persistence failure is prominent");
                    EBExpect([pv.carRow.toolTip containsString:@"permission denied"],
                             "vehicle persistence detail remains available");
                }

                NSAppearance *appearance =
                    [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
                NSBitmapImageRep *rep = EBRender(pv.root, dark);
                EBExpect(rep.pixelsWide == (NSInteger)ceil(NSWidth(pv.root.bounds) * 2.0) &&
                         rep.pixelsHigh == (NSInteger)ceil(NSHeight(pv.root.bounds) * 2.0),
                         "snapshot bitmap is exactly 2x");
                if ([name isEqualToString:@"tariff-import"] || [name isEqualToString:@"tariff-export"]) {
                    // Exporting with a net cost for the day must not paint a red bar: the bar is live flow.
                    NSView *flow = nil;
                    for (NSView *sub in pv.gridRow.subviews)
                        if ([NSStringFromClass(sub.class) isEqualToString:@"EBGauge"] && !sub.hidden) flow = sub;
                    NSRect fill = [flow convertRect:NSMakeRect(0, 0, 6, NSHeight(flow.bounds)) toView:pv.root];
                    EBExpect(flow && EBRectHasTint(rep, EBPixelRect(fill, pv.root, rep), [name isEqualToString:@"tariff-import"]),
                             "grid bar colour follows the live direction, not the day's money");
                }
                NSString *file = [NSString stringWithFormat:@"%@-%@.png", name, dark ? @"dark" : @"light"];
                NSString *outPath = [renderDir stringByAppendingPathComponent:file];
                EBWritePNG(rep, outPath);
                [pngs addObject:outPath];

                // Page must be painted: dark pass must not composite onto white.
                {
                    NSColor *corner = [[rep colorAtX:4 y:4] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    CGFloat r, g, b, a;
                    [corner getRed:&r green:&g blue:&b alpha:&a];
                    double L = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    if (dark)
                        EBExpect(L < 0.45, "dark page backdrop is not white");
                    else
                        EBExpect(L > 0.55, "light page backdrop is not black");
                }

                EBAssertTextContrast(pv.root, rep, pv.root, appearance, st);

                // Chart regions (view coords → pixels)
                NSRect chartF = [pv.chart convertRect:pv.chart.bounds toView:pv.root];
                NSRect chartPx = EBPixelRect(chartF, pv.root, rep);
                // Legend sits above the chart, beside the window control
                NSRect legendF = [pv.legend convertRect:pv.legend.bounds toView:pv.root];
                NSRect legendPx = EBPixelRect(legendF, pv.root, rep);
                // Time-axis gutter: bottom 16pt of the chart (root is flipped)
                NSRect axisF = NSMakeRect(NSMinX(chartF) + 40, NSMaxY(chartF) - 16,
                                          chartF.size.width - 40, 16);
                NSRect axisPx = EBPixelRect(axisF, pv.root, rep);

                if (samp.count >= 2) {
                    EBExpect(EBInkCoverage(rep, chartPx) > 0.02, "chart has drawn content");
                    EBExpect(EBDistinctHues(rep, legendPx, 0.25) >= 2,
                             "solar-destination legend has blue car and green export hues");
                    EBExpect(EBInkCoverage(rep, axisPx) > 0.005, "time axis gutter has ink");
                }

                NSString *snapPath = [snapDir stringByAppendingPathComponent:file];
                if (gAccept) {
                    [baselineWrites addObject:@{@"source": outPath, @"path": snapPath}];
                } else if (!gCompareSnapshots) {
                    // Cross-version AppKit rendering is not pixel-stable. Layout,
                    // copy, contrast, provenance, scale, and chart assertions above
                    // still run in CI; exact local baselines remain a same-OS gate.
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:snapPath]) {
                    NSData *d = [NSData dataWithContentsOfFile:snapPath];
                    NSData *renderedData = [NSData dataWithContentsOfFile:outPath];
                    NSBitmapImageRep *base = [NSBitmapImageRep imageRepWithData:d];
                    NSBitmapImageRep *rendered = [NSBitmapImageRep imageRepWithData:renderedData];
                    if (!base || !rendered) {
                        EBFail("%s: snapshot is unreadable", st);
                    } else {
                        double diff = EBPixelDiff(base, rendered);
                        if (diff > 0.02) {
                            EBFail("%s: snapshot diff %.1f%% > 2%%", st, diff * 100);
                            NSString *diffPath = [renderDir stringByAppendingPathComponent:
                                                  [NSString stringWithFormat:@"diff-%@", file]];
                            EBWritePNG(rep, diffPath);
                        }
                    }
                } else {
                    EBFail("%s: missing snapshot; review and run with --accept-snapshots", st);
                }
            }
        }
        {   // Evening after a net-export day: importing now, so the datum is today's import,
            // never "import · 13.0 kWh" built from the net export figure.
            EBPopoverViews *pv = EBBuildPopover(nil);
            EBSnapshotView *snap = EBState(@"night");
            snap.gridOK = YES; snap.gridStale = NO; snap.supplyW = 231;
            EBDayTotals t = snap.today;
            t.span = t.gridCoverage = 3600; t.exportWh = 14600; t.importWh = 1600;
            snap.today = t;
            EBApplySnapshot(pv, snap, samples);
            EBExpect([pv.gridRow.title isEqualToString:@"Import"] && [pv.gridRow.subline hasPrefix:@"1.6 kWh"],
                     "grid datum pairs the live direction with that direction's own total");
            EBExpect([pv.gridRow.toolTip containsString:@"out 14.6 kWh"], "grid tooltip keeps both totals");
            snap.supplyW = 0;
            EBApplySnapshot(pv, snap, samples);
            EBExpect([pv.gridRow.title isEqualToString:@"Grid"] && [pv.gridRow.subline isEqualToString:@"balanced"],
                     "balanced live flow is not labelled with an earlier daily direction");
        }
        EBCompositeContact(pngs, [renderDir stringByAppendingPathComponent:@"contact-sheet.png"]);
        if (gAccept) {
            if (gFails == 0) {
                NSUInteger accepted = 0;
                for (NSDictionary *write in baselineWrites) {
                    NSData *data = [NSData dataWithContentsOfFile:write[@"source"]];
                    if (data && [data writeToFile:write[@"path"] atomically:YES])
                        accepted++;
                    else
                        EBFail("could not update snapshot %s", [write[@"path"] UTF8String]);
                }
                printf("accepted %lu snapshots\n", (unsigned long)accepted);
            } else {
                fprintf(stderr, "snapshots not updated because visual assertions failed\n");
            }
        }
        printf("ok: render %lu images → build/render/contact-sheet.png\n", (unsigned long)pngs.count);
        if (gFails) {
            fprintf(stderr, "%d visual assertion(s) failed\n", gFails);
            return 1;
        }
    }
    return 0;
}
