#import <Foundation/Foundation.h>
#import <math.h>
#import "store.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

int main(void) {
    @autoreleasepool {
        NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1700000000];
        NSDate *t1 = [t0 dateByAddingTimeInterval:3600];
        NSDictionary *lowCharge = @{@"t": t0,
                                     @"pvW": @100,
                                     @"supplyW": @(-100),
                                     @"chargeW": @100};
        NSDictionary *pvSpike = @{@"t": [t0 dateByAddingTimeInterval:60],
                                   @"pvW": @999999,
                                   @"supplyW": @(-200),
                                   @"chargeW": @200};
        NSDictionary *exportSpike = @{@"t": [t0 dateByAddingTimeInterval:120],
                                       @"pvW": @100,
                                       @"supplyW": @(-5000),
                                       @"chargeW": @300};
        NSDictionary *chargeSpike = @{@"t": [t0 dateByAddingTimeInterval:180],
                                       @"pvW": @100,
                                       @"supplyW": @1000,
                                       @"chargeW": @6000};
        NSArray *rows = @[lowCharge, pvSpike, exportSpike, chargeSpike];
        NSArray *b = EBStoreBucket(rows, t0, t1, 4);
        expect([b containsObject:lowCharge], @"minimum charge preserved");
        expect([b containsObject:exportSpike], @"maximum export preserved");
        expect([b containsObject:chargeSpike], @"import and charge spikes preserved");
        expect(![b containsObject:pvSpike], @"PV extrema do not drive a non-PV chart");
        for (NSDictionary *r in b) {
            NSTimeInterval off = [r[@"t"] timeIntervalSinceDate:t0];
            expect(off <= 180, @"no bucket invented in the empty part of the window");
        }
        NSArray *pvOnly = @[@{@"t": t0, @"pvW": @5000}];
        expect(EBStoreBucket(pvOnly, t0, t1, 4).count == 0,
               @"PV-only samples do not populate the grid/car chart");
        expect(EBStoreBucket(@[], t0, t1, 4).count == 0, @"empty in, empty out");

        EBChartSeriesAverages unknownGrid = EBStoreChartSeriesAverages(@[
            @{@"chargeW": @700},
        ]);
        expect(unknownGrid.chargeSampleCount == 0,
               @"unknown-grid charge is omitted rather than called solar");
        expect(unknownGrid.carSolarW == 0 && unknownGrid.carGridW == 0,
               @"unknown-grid charge draws no classified car bar");

        EBChartSeriesAverages netExport = EBStoreChartSeriesAverages(@[
            @{@"supplyW": @(-600), @"chargeW": @400},
        ]);
        expect(fabs(netExport.carSolarW - 400) < 0.1, @"exporting car load is solar");
        expect(fabs(netExport.unusedSurplusW - 600) < 0.1,
               @"net export is already unused surplus and is not reduced by car load");

        EBChartSeriesAverages missingCharge = EBStoreChartSeriesAverages(@[
            @{@"supplyW": @(-600), @"chargeW": @400},
            @{@"supplyW": @(-600)},
        ]);
        expect(fabs(missingCharge.carSolarW - 400) < 0.1,
               @"missing charge does not dilute known charge as zero");
        expect(fabs(missingCharge.unusedSurplusW - 600) < 0.1,
               @"supply uses its own independent coverage count");

        EBChartSeriesAverages mixed = EBStoreChartSeriesAverages(@[
            @{@"supplyW": @(-100), @"chargeW": @1000},
            @{@"supplyW": @500, @"chargeW": @1000},
        ]);
        // Grid-first: the 500 W import covers half of the second sample's 1 kW car load.
        expect(fabs(mixed.carSolarW - 750) < 0.1 && fabs(mixed.carGridW - 250) < 0.1,
               @"mixed classifications are time-weighted without doubling mean car load");

        EBChartSeriesAverages full = EBStoreChartSeriesAverages(@[
            @{@"pvW": @5000, @"supplyW": @2000, @"chargeW": @7000},
        ]);
        expect(fabs(full.carGridW - 2000) < 0.1 && fabs(full.carSolarW - 5000) < 0.1,
               @"partial import splits car load instead of calling it all grid");
        expect(full.homeGridW < 0.1 && full.homeSolarW < 0.1, @"all load was the car");

        EBChartSeriesAverages home = EBStoreChartSeriesAverages(@[
            @{@"pvW": @3000, @"supplyW": @(-1000), @"chargeW": @0},
            @{@"pvW": @0, @"supplyW": @800, @"chargeW": @0},
        ]);
        expect(fabs(home.solarW - 1500) < 0.1 && fabs(home.unusedSurplusW - 500) < 0.1,
               @"solar and export average independently");
        expect(fabs(home.homeSolarW - 1000) < 0.1 && fabs(home.homeGridW - 400) < 0.1,
               @"home load is split into solar and grid parts");

        EBChartSeriesAverages noPV = EBStoreChartSeriesAverages(@[
            @{@"supplyW": @(-1000), @"chargeW": @0},
        ]);
        expect(noPV.homeSolarW == 0 && noPV.pvSampleCount == 0,
               @"home solar is not guessed without a PV reading");
        puts("ok: ui/bucket");
    }
    return 0;
}
