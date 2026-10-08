#import <Foundation/Foundation.h>
#import <math.h>
#import "tariff.h"

#define expect(c, m) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", m); return 1; } } while (0)

static NSDictionary *Flat(void) {
    return @{ @"name": @"Test", @"currency": @"AUD", @"timeZone": @"Australia/Perth",
              @"bands": @[ @{ @"startMinute": @0, @"endMinute": @1440,
                               @"importCents": @30, @"exportCents": @5 } ] };
}
static NSDate *UTC(NSString *text) {
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; f.dateFormat = @"yyyy-MM-dd HH:mm";
    return [f dateFromString:text];
}
static NSDictionary *Sample(NSDate *t, double w) { return @{ @"t": t, @"supplyW": @(w) }; }
static NSArray *ConstantSamples(NSDate *start, NSUInteger count, NSTimeInterval step, double w) {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count + 1];
    for (NSUInteger i = 0; i <= count; i++) [rows addObject:Sample([start dateByAddingTimeInterval:i * step], w)];
    return rows;
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        EBTariff *flat = [EBTariff fromDictionary:Flat() error:&error];
        expect(flat && !error, "flat tariff parses");
        double inRate = 0, outRate = 0;
        expect([flat ratesAtDate:UTC(@"2026-10-07 12:00") importCents:&inRate exportCents:&outRate] && inRate == 30 && outRate == 5,
               "flat rate lookup");
        NSDate *flatStart = UTC(@"2026-10-07 12:00");
        EBGridCostTotals c = EBTariffIntegrate(ConstantSamples(flatStart, 12, 300, 1000), flatStart, UTC(@"2026-10-07 13:00"), flat);
        expect(fabs(c.importWh - 1000) < .01 && fabs(c.importCost - .30) < .0001 && fabs(c.coverage - 3600) < .01,
               "flat import energy and cost");
        c = EBTariffIntegrate(ConstantSamples(flatStart, 12, 300, -1000), flatStart, UTC(@"2026-10-07 13:00"), flat);
        expect(fabs(c.exportWh - 1000) < .01 && fabs(c.exportCredit - .05) < .0001 && c.importCost == 0,
               "flat export credit stays separate");
        c = EBTariffIntegrate(@[Sample(UTC(@"2026-10-07 12:00"), 1000), Sample(UTC(@"2026-10-07 12:06"), -1000)], UTC(@"2026-10-07 12:00"), UTC(@"2026-10-07 12:06"), flat);
        expect(fabs(c.importWh - 25) < .01 && fabs(c.exportWh - 25) < .01, "sign crossing is gross import/export");

        NSMutableDictionary *tou = [Flat() mutableCopy];
        tou[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @60, @"importCents": @10, @"exportCents": @2 },
                           @{ @"startMinute": @60, @"endMinute": @1440, @"importCents": @40, @"exportCents": @8 } ];
        EBTariff *timeOfUse = [EBTariff fromDictionary:tou error:&error]; expect(timeOfUse, "TOU tariff parses");
        c = EBTariffIntegrate(@[Sample(UTC(@"2026-10-06 16:59"), 1000), Sample(UTC(@"2026-10-06 17:01"), 1000)], UTC(@"2026-10-06 16:59"), UTC(@"2026-10-06 17:01"), timeOfUse);
        expect(fabs(c.importCost - (10.0/100.0/60.0 + 40.0/100.0/60.0)) < .0001, "TOU boundary splits interval");
        c = EBTariffIntegrate(@[Sample(UTC(@"2026-10-06 16:57"), 1000), Sample(UTC(@"2026-10-06 17:03"), 1000)], UTC(@"2026-10-06 16:59"), UTC(@"2026-10-06 17:01"), timeOfUse);
        expect(fabs(c.importWh - (2000.0/60.0)) < .01 && fabs(c.coverage - 120) < .01, "requested window clips intervals");

        NSDictionary *badOverlap = @{ @"name": @"x", @"currency": @"AUD", @"timeZone": @"Australia/Perth", @"bands": @[
            @{ @"startMinute": @0, @"endMinute": @100, @"importCents": @1, @"exportCents": @1 },
            @{ @"startMinute": @90, @"endMinute": @1440, @"importCents": @1, @"exportCents": @1 }] };
        expect(![EBTariff fromDictionary:badOverlap error:&error], "overlap rejected");
        NSMutableDictionary *incomplete = [Flat() mutableCopy]; incomplete[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @100, @"importCents": @1, @"exportCents": @1 } ];
        expect(![EBTariff fromDictionary:incomplete error:&error], "incomplete coverage rejected");
        NSMutableDictionary *negative = [Flat() mutableCopy]; negative[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @1440, @"importCents": @-1, @"exportCents": @0 } ];
        expect(![EBTariff fromDictionary:negative error:&error], "negative rate rejected");
        NSMutableDictionary *boolRate = [Flat() mutableCopy]; boolRate[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @1440, @"importCents": @YES, @"exportCents": @0 } ];
        expect(![EBTariff fromDictionary:boolRate error:&error], "boolean rate rejected");
        NSMutableDictionary *free = [Flat() mutableCopy]; free[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @1440, @"importCents": @0, @"exportCents": @0 } ];
        EBTariff *freeTariff = [EBTariff fromDictionary:free error:&error]; expect(freeTariff, "zero rates are valid");
        c = EBTariffIntegrate(ConstantSamples(flatStart, 1, 300, 1000), flatStart, [flatStart dateByAddingTimeInterval:300], freeTariff);
        expect(fabs(c.coverage - 300) < .01 && c.importCost == 0, "zero rate still prices coverage");
        NSMutableDictionary *weekend = [Flat() mutableCopy]; weekend[@"bands"] = @[ @{ @"startMinute": @0, @"endMinute": @1440, @"importCents": @10, @"exportCents": @1, @"weekdays": @[@1,@7] },
                                                                                       @{ @"startMinute": @0, @"endMinute": @1440, @"importCents": @20, @"exportCents": @2, @"weekdays": @[@2,@3,@4,@5,@6] } ];
        EBTariff *weekendTariff = [EBTariff fromDictionary:weekend error:&error]; expect(weekendTariff, "weekday override parses");
        expect([weekendTariff ratesAtDate:UTC(@"2026-10-04 12:00") importCents:&inRate exportCents:&outRate] && inRate == 10,
               "Sunday rate selected");
        expect([weekendTariff ratesAtDate:UTC(@"2026-10-05 12:00") importCents:&inRate exportCents:&outRate] && inRate == 20,
               "weekday rate selected");
        NSMutableDictionary *dated = [Flat() mutableCopy]; dated[@"validFrom"] = @"2026-10-08"; dated[@"validUntil"] = @"2026-10-10";
        EBTariff *datedTariff = [EBTariff fromDictionary:dated error:&error]; expect(datedTariff, "validity dates parse");
        double ignoredImport = 0, ignoredExport = 0;
        expect(![datedTariff ratesAtDate:UTC(@"2026-10-07 15:59") importCents:&ignoredImport exportCents:&ignoredExport] &&
               [datedTariff ratesAtDate:UTC(@"2026-10-07 16:00") importCents:&ignoredImport exportCents:&ignoredExport] &&
               ![datedTariff ratesAtDate:UTC(@"2026-10-09 16:00") importCents:&ignoredImport exportCents:&ignoredExport], "validity bounds enforced");
        c = EBTariffIntegrate(ConstantSamples(flatStart, 12, 300, 1000), flatStart, UTC(@"2026-10-07 13:00"), datedTariff);
        expect(c.coverage == 0 && c.importCost == 0, "out of validity is unpriced");
        NSDate *gapStart = UTC(@"2026-10-07 12:00");
        NSArray *gapRows = @[Sample(gapStart, 1000), @{ @"t": [gapStart dateByAddingTimeInterval:60] }, Sample([gapStart dateByAddingTimeInterval:120], 1000)];
        c = EBTariffIntegrate(gapRows, gapStart, [gapStart dateByAddingTimeInterval:120], flat);
        expect(c.coverage == 0, "missing supply endpoint breaks pricing");
        c = EBTariffIntegrate(@[Sample(gapStart, 1000), Sample([gapStart dateByAddingTimeInterval:421], 1000)],
                              gapStart, [gapStart dateByAddingTimeInterval:421], flat);
        expect(c.coverage == 0, "long unobserved intervals stay unpriced");
        NSArray *statusRows = @[Sample(gapStart, 1000), @{ @"t": [gapStart dateByAddingTimeInterval:60], @"statusOnly": @YES }, Sample([gapStart dateByAddingTimeInterval:120], 1000)];
        c = EBTariffIntegrate(statusRows, gapStart, [gapStart dateByAddingTimeInterval:120], flat);
        expect(fabs(c.coverage - 120) < .01, "status-only rows do not break power intervals");
        NSMutableDictionary *dst = [Flat() mutableCopy]; dst[@"timeZone"] = @"America/New_York";
        EBTariff *dstTariff = [EBTariff fromDictionary:dst error:&error]; expect(dstTariff, "DST timezone parses");
        expect([dstTariff ratesAtDate:UTC(@"2026-11-01 05:30") importCents:&inRate exportCents:&outRate] &&
               [dstTariff ratesAtDate:UTC(@"2026-11-01 07:30") importCents:&inRate exportCents:&outRate], "DST repeated local hour resolves");
        c = EBTariffIntegrate(@[Sample(UTC(@"2026-11-01 05:59"), 1000), Sample(UTC(@"2026-11-01 06:01"), 1000)],
                              UTC(@"2026-11-01 05:59"), UTC(@"2026-11-01 06:01"), dstTariff);
        expect(fabs(c.coverage - 120) < .01 && fabs(c.importWh - (2000.0/60.0)) < .01, "DST interval remains continuous");
        dst[@"bands"] = tou[@"bands"];
        // 01:59 EDT -> 01:00 EST repeats the 01:00 tariff boundary.
        dst[@"bands"] = @[@{@"startMinute": @0, @"endMinute": @90, @"importCents": @10, @"exportCents": @2},
                          @{@"startMinute": @90, @"endMinute": @1440, @"importCents": @40, @"exportCents": @8}];
        dstTariff = [EBTariff fromDictionary:dst error:&error];
        c = EBTariffIntegrate(@[Sample(UTC(@"2026-11-01 05:59"), 1000), Sample(UTC(@"2026-11-01 06:01"), 1000)],
                              UTC(@"2026-11-01 05:59"), UTC(@"2026-11-01 06:01"), dstTariff);
        expect(fabs(c.importCost - .50 / 60) < .00001, "repeated hour switches from late-hour back to early-hour rate");
        for (id bad in @[@(INFINITY), @(NAN), @1001, @YES]) {
            NSMutableDictionary *malformed = [Flat() mutableCopy];
            malformed[@"bands"] = @[@{@"startMinute": @0, @"endMinute": @1440, @"importCents": bad, @"exportCents": @5}];
            expect(![EBTariff fromDictionary:malformed error:&error], "nonfinite, boolean and excessive rates rejected");
        }
        NSMutableDictionary *badDate = [Flat() mutableCopy]; badDate[@"validFrom"] = @"2026-02-30";
        expect(![EBTariff fromDictionary:badDate error:&error], "invalid calendar date rejected");
        NSMutableDictionary *hugeMinute = [Flat() mutableCopy];
        hugeMinute[@"bands"] = @[@{@"startMinute": @0, @"endMinute": @9223372036854775808.0,
                                   @"importCents": @30, @"exportCents": @5}];
        expect(![EBTariff fromDictionary:hugeMinute error:&error], "huge integers rejected before conversion");
        NSMutableDictionary *badCurrency = [Flat() mutableCopy]; badCurrency[@"currency"] = @"ZZZ";
        expect(![EBTariff fromDictionary:badCurrency error:&error], "unknown currency rejected");
        error = nil;
        expect(!EBTariffLoad(@"/unlikely-energybar-missing-tariff/file.json", &error) && !error,
               "missing file is unavailable without a parse error");
        puts("ok: tariff");
    }
    return 0;
}
