#import <Foundation/Foundation.h>
#import <math.h>
#import "pure.h"
#import "parse.h"
#import "store.h"

#define expect(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); \
        exit(1); \
    } \
} while (0)

#define expect_eq_int(a, b, msg) expect((a) == (b), msg)
#define expect_eq_str(a, b, msg) expect([(a) isEqualToString:(b)], msg)

static NSDictionary *LoadFixture(NSString *name) {
    NSString *here = @(__FILE__).stringByDeletingLastPathComponent;
    NSString *path = [here stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fixtures/%@", name]];
    NSData *d = [NSData dataWithContentsOfFile:path];
    expect(d != nil, @"missing fixture");
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

int main(void) {
    @autoreleasepool {
        // Bar state
        expect_eq_int(EBComputeBarState(YES, YES, YES, @"CHARGING", @"Transfer", @"SolarControl", NO, -100),
                      EBBarStateOK, @"solar ok");
        expect_eq_int(EBComputeBarState(YES, YES, YES, @"CHARGING", @"Transfer", @"WaitingSolar", NO, -100),
                      EBBarStateWarn, @"waiting solar");
        expect_eq_int(EBComputeBarState(YES, YES, YES, @"CHARGING", @"Transfer", @"FullPower", YES, 2000),
                      EBBarStateWarn, @"charge now importing");
        expect_eq_int(EBComputeBarState(NO, NO, NO, nil, nil, nil, NO, 0),
                      EBBarStateError, @"both down");
        expect_eq_int(EBComputeBarState(YES, YES, YES, @"FAULTED", @"Fault", @"", NO, 0),
                      EBBarStateError, @"fault");
        expect_eq_int(EBComputeBarState(NO, YES, YES, @"AVAILABLE", @"NoVehicle", @"", NO, 0),
                      EBBarStateWarn, @"fronius down");

        expect([EBBarGlyphName(YES, 3000, YES, -800, YES, 0, 12) isEqualToString:@"sun.max.fill"], @"sun export");
        expect([EBBarGlyphName(YES, 3000, YES, 200, YES, 0, 12) isEqualToString:@"cloud.fill"], @"cloud no surplus");
        expect([EBBarGlyphName(YES, 0, YES, 0, YES, 0, 22) isEqualToString:@"moon.fill"], @"moon night");
        expect([EBBarGlyphName(YES, 0, YES, 200, YES, 0, 18) isEqualToString:@"moon.fill"], @"moon once the inverter sleeps, even before 19:00");
        expect([EBBarGlyphName(NO, 0, YES, 200, YES, 0, 12) isEqualToString:@"cloud.fill"], @"unknown solar falls back to the clock");
        expect([EBBarGlyphName(YES, 500, YES, 0, YES, 2000, 12) isEqualToString:@"bolt.fill"], @"bolt charging");

        // --- v1.2: unknown OCPP is not "unplugged" ---
        expect_eq_int(EBComputeChargerState(nil, @"Transfer", nil, NO, NO),
                      EBChargerStateUnknown, @"no ocpp → unknown");
        expect_eq_int(EBComputeChargerState(nil, @"Transfer", @"SolarControl", NO, NO),
                      EBChargerStateSolar, @"live control survives absent detail");
        expect_eq_str(EBChargerWordForState(EBComputeChargerState(nil, @"Transfer", nil, NO, NO)),
                      @"?", @"unknown renders as ?");
        expect_eq_int(EBComputeChargerState(@"AVAILABLE", @"NoVehicle", @"", NO, YES),
                      EBChargerStateUnplugged, @"available + no vehicle → unplugged");
        expect_eq_int(EBComputeChargerState(@"CHARGING", @"Transfer", @"SolarControl", NO, YES),
                      EBChargerStateSolar, @"solar control");
        expect_eq_int(EBComputeChargerState(@"CHARGING", @"Transfer", @"FullPower", YES, YES),
                      EBChargerStateCharging, @"charge now");
        expect_eq_int(EBComputeChargerState(@"SUSPENDED_EV", @"Transfer", @"WaitingSolar", NO, YES),
                      EBChargerStateWaiting, @"waiting for solar");
        expect_eq_int(EBComputeChargerState(@"FAULTED", @"Fault", @"", NO, YES),
                      EBChargerStateFault, @"faulted");
        expect(EBChargePowerForLiveStatus(1800, YES, @"NoVehicle", nil, NO) == 0,
               @"fresh unplug status suppresses retained connector power");
        expect(EBChargePowerForLiveStatus(1800, YES, @"Transfer", @"WaitingSolar", NO) == 0,
               @"fresh waiting status suppresses retained connector power");
        expect(EBChargePowerForLiveStatus(1800, YES, @"Transfer", @"SolarControl", NO) == 1800,
               @"solar control may still be actively transferring power");
        expect(EBChargePowerForLiveStatus(1800, NO, nil, nil, NO) == 1800,
               @"missing status does not fabricate zero car power");
        expect_eq_int(EBComputeBarState(YES, YES, YES, nil, @"Transfer", nil, NO, -100),
                      EBBarStateWarn, @"unknown ocpp is a warning, not OK");
        EBEvnexParsed *e2 = [EBEvnexParsed new];
        expect(EBParseEvnexBundle(LoadFixture(@"evnex_status.json"),
                                  @{@"data": @{@"supplyActivePower": @-18,
                                                @"chargingActivePower": @2619}},
                                  nil, nil, e2), @"parses without detail");
        expect(e2.haveOcppStatus == NO, @"detail absent → haveOcppStatus NO");

        // --- v1.2: backoff ladder ---
        expect(EBNextPollInterval(30, YES) == 30,  @"success stays at base");
        expect(EBNextPollInterval(30, NO)  == 60,  @"first failure doubles");
        expect(EBNextPollInterval(60, NO)  == 120, @"second failure doubles");
        expect(EBNextPollInterval(240, NO) == 300, @"caps at 300");
        expect(EBNextPollInterval(300, NO) == 300, @"stays capped");
        expect(EBNextPollInterval(300, YES) == 30, @"success resets to base");
        expect(!EBShouldBackoffEvnex(YES, NO),
               @"healthy status keeps unplug polling prompt independently of detail");
        expect(EBShouldBackoffEvnex(NO, NO), @"missing status backs off");
        expect(EBShouldBackoffEvnex(YES, YES), @"explicit rate limit backs off");
        expect(EBNextDetailPollInterval(0) == 300,
               @"new source sample keeps the normal detail cadence");
        expect(EBNextDetailPollInterval(246) == 69,
               @"late-cycle source sample aligns the next detail request");
        expect(EBNextDetailPollInterval(295) == 30,
               @"detail catch-up never spins faster than status polling");
        expect(EBNextDetailPollInterval(421) == 300,
               @"stale source clock falls back instead of being hammered");
        BOOL detailCurrent = EBDetailCurrentState(YES, YES, NO);
        expect(!detailCurrent, @"failed detail request becomes stale");
        detailCurrent = EBDetailCurrentState(detailCurrent, NO, NO);
        expect(!detailCurrent, @"not-due cycle preserves the stale result");
        detailCurrent = EBDetailCurrentState(detailCurrent, YES, YES);
        expect(detailCurrent, @"successful detail request restores current state");
        expect(EBShouldUseLastMeterFallback(NO, YES),
               @"missing snapshot meter uses the last known fallback");
        expect(!EBShouldUseLastMeterFallback(YES, YES),
               @"parsed stale snapshot meter preserves live status reconciliation");
        expect(!EBShouldPersistPoll(NO),
               @"status/Fronius-only refresh does not split shared meter history");
        expect(EBShouldPersistPoll(YES),
               @"attempted meter failure records an explicit series gap");

        // --- v1.2: coverage honesty ---
        expect(EBCoverageNote(3600, 3600) == nil,  @"full coverage needs no caveat");
        expect(EBCoverageNote(3500, 3600) == nil,  @"97% is close enough");
        expect_eq_str(EBCoverageNote(1800, 3600), @"partial", @"half a day is partial");
        expect_eq_str(EBCoverageNote(0, 3600),    @"no data", @"nothing measured");
        expect(EBCoverageNote(0, 0) == nil,       @"zero span is not an error");

        // Fronius parse
        double pv = 0, day = 0;
        expect(EBParseFroniusPowerFlow(LoadFixture(@"fronius_powerflow.json"), &pv, &day), @"fronius parse");
        expect(fabs(pv - 3837) < 0.1, @"pv");
        expect(fabs(day - 6360) < 0.1, @"eday");

        // Evnex parse
        EBEvnexParsed *e = [EBEvnexParsed new];
        expect(EBParseEvnexBundle(LoadFixture(@"evnex_status.json"),
                                  nil,
                                  LoadFixture(@"evnex_detail.json"),
                                  nil, e), @"evnex parse");
        expect(e.ok, @"ok");
        double detailSupply = 0, detailCharge = 0;
        NSDate *detailAt = nil;
        expect(EBParseEvnexDetailMeter(LoadFixture(@"evnex_detail.json"), nil, 0,
                                        &detailSupply, &detailCharge, &detailAt),
               @"fresh detail meter seam parses");
        expect(fabs(detailSupply - (-18)) < 0.1, @"detail supply");
        expect(fabs(detailCharge - 2619) < 0.1, @"detail charge");
        expect(detailAt != nil, @"detail meter preserves its own timestamp");
        expect_eq_str(e.chargingCurrentControl, @"SolarControl", @"ctrl");
        expect_eq_str(e.ocppStatus, @"CHARGING", @"ocpp");
        expect_eq_str(e.scheduleBehaviour, @"Solar", @"sched");
        expect(e.orgId.length > 0, @"nonempty org id parsed");

        // Store
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"energybar-store-%d", getpid()]];
        [manager removeItemAtPath:tmpRoot error:nil];
        NSString *tmp = [tmpRoot stringByAppendingPathComponent:@"samples.jsonl"];
        NSDate *now = [NSDate date];
        expect(EBStoreAppend(tmp, [now dateByAddingTimeInterval:-60],
                             @1000, @(-200), @500, nil, 48 * 3600), @"first append succeeds");
        expect(EBStoreAppend(tmp, [now dateByAddingTimeInterval:-(50 * 3600)],
                             @9, @9, @9, nil, 48 * 3600), @"historical append succeeds");
        expect(EBStoreAppend(tmp, now, @2000, @(-100), @800, nil, 48 * 3600),
               @"fresh append succeeds");
        NSArray *rows = EBStoreLoad(tmp, 48 * 3600);
        expect(rows.count == 2, @"two fresh samples");
        NSArray *ds = EBStoreDownsample(rows, 1);
        expect(ds.count == 1, @"downsample");
        expect([ds[0][@"t"] isEqualToDate:rows.lastObject[@"t"]],
               @"one-point downsample keeps the freshest sample");
        NSDictionary *dirAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tmpRoot error:nil];
        NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tmp error:nil];
        expect(([dirAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700,
               @"store directory is private");
        expect(([fileAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600,
               @"store file is private");
        expect([manager setAttributes:@{NSFilePosixPermissions: @0755}
                               ofItemAtPath:tmpRoot error:nil], @"loosen old store directory");
        expect([manager setAttributes:@{NSFilePosixPermissions: @0644}
                               ofItemAtPath:tmp error:nil], @"loosen old store file");
        expect(EBStoreSecureExistingFile(tmp), @"upgrade old store permissions");
        dirAttrs = [manager attributesOfItemAtPath:tmpRoot error:nil];
        fileAttrs = [manager attributesOfItemAtPath:tmp error:nil];
        expect(([dirAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700,
               @"upgrade makes store directory private");
        expect(([fileAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600,
               @"upgrade makes existing store file private");
        NSString *existingDir = [tmpRoot stringByAppendingPathComponent:@"existing"];
        expect([[NSFileManager defaultManager] createDirectoryAtPath:existingDir
                                          withIntermediateDirectories:NO
                                                           attributes:@{NSFilePosixPermissions: @0755}
                                                                error:nil], @"existing directory fixture created");
        NSString *existingDirFile = [existingDir stringByAppendingPathComponent:@"samples.jsonl"];
        expect(EBStoreAppend(existingDirFile, now, @1, nil, nil, nil, 60),
               @"append in an existing directory succeeds");
        NSDictionary *existingDirAttrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:existingDir error:nil];
        NSDictionary *existingFileAttrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:existingDirFile error:nil];
        expect(([existingDirAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0755,
               @"existing directory permissions are not mutated");
        expect(([existingFileAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600,
               @"file is private even in an existing directory");
        expect(!EBStoreAppend(@"", now, @1, nil, nil, nil, 60),
               @"append reports invalid paths");
        expect(!EBStoreAppend([tmpRoot stringByAppendingPathComponent:@"bad-number.jsonl"],
                              now, @YES, nil, nil, nil, 60),
               @"boolean telemetry cannot masquerade as numeric history");
        NSString *unreadable = [tmpRoot stringByAppendingPathComponent:@"invalid-utf8.jsonl"];
        const unsigned char invalidBytes[] = {0xff, 0xfe, 0xfd};
        NSData *invalidData = [NSData dataWithBytes:invalidBytes length:sizeof(invalidBytes)];
        expect([invalidData writeToFile:unreadable atomically:YES], @"write corrupt store fixture");
        expect(!EBStoreAppend(unreadable, now, @1, nil, nil, nil, 60),
               @"append never overwrites unreadable existing history");
        expect([NSData dataWithContentsOfFile:unreadable].length == sizeof(invalidBytes),
               @"unreadable history is preserved for recovery");

        NSString *unordered = [tmpRoot stringByAppendingPathComponent:@"unordered.jsonl"];
        NSDate *older = [now dateByAddingTimeInterval:-120];
        NSDate *newer = [now dateByAddingTimeInterval:-60];
        expect(EBStoreAppend(unordered, newer, nil, @200, @20, nil, 3600),
               @"newer out-of-order sample written first");
        expect(EBStoreAppend(unordered, older, nil, @100, @10, nil, 3600),
               @"older source-timestamp sample can arrive later");
        expect(EBStoreAppend(unordered, older, nil, @150, @15, nil, 3600),
               @"repeated source timestamp can be replaced");
        NSArray *ordered = EBStoreLoad(unordered, 3600);
        expect(ordered.count == 2 &&
               [ordered[0][@"t"] compare:ordered[1][@"t"]] == NSOrderedAscending,
               @"loaded history is chronological despite arrival order");
        expect([ordered[0][@"supplyW"] doubleValue] == 150,
               @"latest row wins when a source timestamp repeats");

        NSString *statusHistory = [tmpRoot stringByAppendingPathComponent:@"status.jsonl"];
        NSDate *statusStart = [NSDate dateWithTimeIntervalSince1970:
            floor(now.timeIntervalSince1970) - 600];
        NSDate *statusEnd = [statusStart dateByAddingTimeInterval:300];
        expect(EBStoreAppend(statusHistory, statusStart, nil, @-500, @1000, nil, 3600),
               @"source-time power checkpoint persists");
        expect(EBStoreAppendStatus(statusHistory, statusStart,
                                   @(EBChargerStateWaiting), 3600),
               @"equal-time status checkpoint persists separately");
        expect(EBStoreAppend(statusHistory, statusEnd, nil, @-500, @1000, nil, 3600),
               @"next source-time power checkpoint persists");
        NSArray *statusRows = EBStoreLoad(statusHistory, 3600);
        NSUInteger statusOnlyCount = 0;
        NSDictionary *statusOnlyRow = nil;
        for (NSDictionary *row in statusRows)
            if ([row[@"statusOnly"] isEqual:@YES]) {
                statusOnlyCount++;
                statusOnlyRow = row;
            }
        expect(statusRows.count == 3 && statusOnlyCount == 1,
               @"equal-time power and status-only roles both survive load");
        NSArray *mergedStatusRows = EBStoreMergeSamples(
            statusRows, statusOnlyRow ? @[statusOnlyRow] : @[], statusEnd, 3600);
        expect(mergedStatusRows.count == 3,
               @"persisted and live copies of one status checkpoint deduplicate");
        EBDayTotals statusTotals = EBStoreIntegrateSince(
            statusRows, statusStart, statusEnd);
        expect(statusTotals.gridCoverage == 300 && statusTotals.chargeCoverage == 300,
               @"status-only checkpoint never splits power integration");

        // --- v1.2: nil series are omitted, not zeroed ---
        NSString *tmp2 = [tmpRoot stringByAppendingPathComponent:@"null.jsonl"];
        NSDate *n2 = [NSDate date];
        expect(EBStoreAppend(tmp2, [n2 dateByAddingTimeInterval:-60],
                             @1000, nil, nil, nil, 48 * 3600), @"partial append succeeds");
        NSArray *r2 = EBStoreLoad(tmp2, 48 * 3600);
        expect(r2.count == 1, @"one row written");
        expect(r2[0][@"pvW"] != nil, @"pv present");
        expect(r2[0][@"supplyW"] == nil, @"supply absent, not zero");
        expect(r2[0][@"chargeW"] == nil, @"charge absent, not zero");
        NSString *rawLine = [NSString stringWithContentsOfFile:tmp2
                                                      encoding:NSUTF8StringEncoding error:nil];
        expect([rawLine rangeOfString:@"supplyW"].location == NSNotFound,
               @"supplyW key not serialised at all");

        // --- v1.3: optional charger state `st` ---
        NSString *tmp3 = [tmpRoot stringByAppendingPathComponent:@"st.jsonl"];
        NSDate *n3 = [NSDate date];
        expect(EBStoreAppend(tmp3, n3, @500, @(-100), @200, @(2) /* Solar */, 48 * 3600),
               @"state append succeeds");
        NSString *raw3 = [NSString stringWithContentsOfFile:tmp3 encoding:NSUTF8StringEncoding error:nil];
        expect([raw3 rangeOfString:@"\"st\""].location != NSNotFound, @"st key present when set");
        NSArray *r3 = EBStoreLoad(tmp3, 48 * 3600);
        expect([r3[0][@"st"] isEqualToNumber:@(2)], @"st round-trips");
        NSString *tmp4 = [tmpRoot stringByAppendingPathComponent:@"nost.jsonl"];
        expect(EBStoreAppend(tmp4, n3, @500, nil, nil, nil, 48 * 3600),
               @"no-state append succeeds");
        NSString *raw4 = [NSString stringWithContentsOfFile:tmp4 encoding:NSUTF8StringEncoding error:nil];
        expect([raw4 rangeOfString:@"\"st\""].location == NSNotFound, @"st omitted when nil");

        // --- v1.2: an outage is a gap in the total, not a zero ---
        NSDate *u0 = [NSDate dateWithTimeIntervalSince1970:1700000000];
        NSArray *outage = @[
            @{@"t": u0,                                @"pvW": @1000, @"supplyW": @(-1000)},
            @{@"t": [u0 dateByAddingTimeInterval:60],   @"pvW": @1000},
            @{@"t": [u0 dateByAddingTimeInterval:120],  @"pvW": @1000, @"supplyW": @(-1000)},
        ];
        EBDayTotals tot = EBStoreIntegrateSince(outage, u0, [u0 dateByAddingTimeInterval:120]);
        expect(fabs(tot.pvWh - (1000.0 / 30.0)) < 1, @"pv integrates across the grid outage");
        expect(fabs(tot.exportWh) < 1, @"no export invented across the gap");
        expect(fabs(tot.gridCoverage) < 1, @"grid coverage is zero, not 3600");
        expect(fabs(tot.pvCoverage - 120) < 1, @"pv coverage is full");
        expect(fabs(tot.span - 120) < 1, @"span is the requested window");

        // Integrate: 1 kW for 1 hour → 1000 Wh
        NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1700000000];
        NSMutableArray *synth = [NSMutableArray array];
        for (NSUInteger i = 0; i <= 12; i++) {
            [synth addObject:@{@"t": [t0 dateByAddingTimeInterval:i * 300],
                               @"pvW": @1000, @"supplyW": @-500, @"chargeW": @200}];
        }
        EBDayTotals st = EBStoreIntegrateSince(synth, t0, [t0 dateByAddingTimeInterval:3600]);
        expect(fabs(st.pvWh - 1000) < 1, @"integrate pv 1kWh");
        expect(fabs(st.exportWh - 500) < 1, @"integrate export");
        expect(fabs(st.chargeWh - 200) < 1, @"integrate charge");

        EBDayTotals crossing = EBStoreIntegrateSince(@[
            @{@"t": t0, @"supplyW": @1000},
            @{@"t": [t0 dateByAddingTimeInterval:300], @"supplyW": @-1000}],
            t0, [t0 dateByAddingTimeInterval:300]);
        expect(fabs(crossing.importWh - 1000.0 / 48) < .001 &&
               fabs(crossing.exportWh - 1000.0 / 48) < .001,
               @"sign crossing keeps gross import and export instead of cancelling them");

        NSArray *atBoundary = @[
            @{@"t": t0, @"pvW": @1000},
            @{@"t": [t0 dateByAddingTimeInterval:EBStoreIntegrationGapSeconds], @"pvW": @1000},
        ];
        EBDayTotals boundary = EBStoreIntegrateSince(atBoundary, t0,
            [t0 dateByAddingTimeInterval:EBStoreIntegrationGapSeconds]);
        expect(fabs(boundary.pvCoverage - EBStoreIntegrationGapSeconds) < 0.1,
               @"seven-minute boundary is continuous");
        expect(fabs(boundary.pvWh - (1000 * EBStoreIntegrationGapSeconds / 3600.0)) < 0.1,
               @"boundary interval integrates");
        for (NSNumber *gap in @[@(EBStoreIntegrationGapSeconds + 1), @600, @1800, @5400]) {
            NSDate *gapEnd = [t0 dateByAddingTimeInterval:gap.doubleValue];
            NSArray *gapped = @[@{@"t": t0, @"pvW": @1000},
                                 @{@"t": gapEnd, @"pvW": @1000}];
            EBDayTotals skipped = EBStoreIntegrateSince(gapped, t0, gapEnd);
            NSString *gapMessage = [NSString stringWithFormat:@"%@-second gap is skipped", gap];
            expect(skipped.pvCoverage == 0 && skipped.pvWh == 0,
                   gapMessage);
        }

        NSDate *cadenceEnd = [t0 dateByAddingTimeInterval:300];
        NSArray *gatedCadence = @[
            @{@"t": t0, @"pvW": @1000, @"supplyW": @-600, @"chargeW": @300},
            @{@"t": cadenceEnd, @"pvW": @1000, @"supplyW": @-600, @"chargeW": @300},
        ];
        EBDayTotals cadence = EBStoreIntegrateSince(gatedCadence, t0, cadenceEnd);
        expect(cadence.gridCoverage == 300 && cadence.chargeCoverage == 300,
               @"gated five-minute meter cadence remains continuous");
        expect(fabs(cadence.exportWh - 50) < 0.01 && fabs(cadence.chargeWh - 25) < 0.01,
               @"gated cadence integrates expected grid and charge energy");
        NSArray *attemptedFailure = @[
            gatedCadence.firstObject,
            @{@"t": [t0 dateByAddingTimeInterval:150],
              @"st": @(EBChargerStateUnknown)},
            gatedCadence.lastObject,
        ];
        EBDayTotals broken = EBStoreIntegrateSince(attemptedFailure, t0, cadenceEnd);
        expect(broken.gridCoverage == 0 && broken.chargeCoverage == 0 &&
               broken.exportWh == 0 && broken.chargeWh == 0,
               @"attempted partial row explicitly breaks meter continuity");
        expect(broken.pvCoverage == 0,
               @"total attempted outage breaks every shared series");
        expect([EBFmtGridDay(1200, 200) isEqualToString:@"↑1.0 kWh"], @"grid day export");
        expect([EBFmtKWh(6360) isEqualToString:@"6.4 kWh"], @"fmt kwh");

        [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];

        puts("ok: v11 pure/parse/store");
    }
    return 0;
}
