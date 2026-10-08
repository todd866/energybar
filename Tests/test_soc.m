#import <Foundation/Foundation.h>
#import "soc.h"
#import "pure.h"
#import "store.h"

#define expect(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); \
        exit(1); \
    } \
} while (0)

static NSDictionary *Row(NSDate *t, double chargeW, NSInteger st) {
    return @{ @"t": t, @"chargeW": @(chargeW), @"st": @(st) };
}

static NSArray<NSDictionary *> *ChargeHour(NSDate *start, double chargeW, NSInteger st) {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:13];
    for (NSInteger i = 0; i <= 12; i++)
        [rows addObject:Row([start dateByAddingTimeInterval:i * 5 * 60], chargeW, st)];
    return rows;
}

int main(void) {
    @autoreleasepool {
        NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1700000000];

        // 1. No anchor → not known.
        {
            EBSoCEstimate e = EBInferSoC(@[], -1, nil, EBSoCSourceNone, 60000, 0.90, t0);
            expect(!e.known, @"no anchor → unknown");
        }

        // 2. Anchor 40% + 3.6 kWh AC into a 60 kWh pack @ 0.90 → 45.4%.
        {
            NSArray *samples = ChargeHour(t0, 3600, EBChargerStateSolar);
            EBSoCEstimate e = EBInferSoC(samples, 40, t0, EBSoCSourceManual,
                                         60000, 0.90, [t0 dateByAddingTimeInterval:3600]);
            expect(e.known, @"known with anchor");
            expect(fabs(e.percent - 45.4) < 0.2, @"40% + 3.6 kWh @0.9 into 60 kWh → ~45.4%");
            expect(fabs(e.addedWh - 3600) < 1, @"addedWh is AC energy");
            expect(e.source == EBSoCSourceManual, @"source is anchor provenance");
        }

        // 3. Clamps at 100 when arithmetic overshoots.
        {
            NSArray *samples = ChargeHour(t0, 20000, EBChargerStateCharging);
            EBSoCEstimate e = EBInferSoC(samples, 90, t0, EBSoCSourceManual,
                                         60000, 0.90, [t0 dateByAddingTimeInterval:3600]);
            expect(e.known && e.percent == 100.0, @"clamps at 100");
        }

        // 4. Unplug after anchor → known = NO even if charge energy follows.
        {
            NSArray *samples = @[
                Row(t0, 3000, EBChargerStateSolar),
                Row([t0 dateByAddingTimeInterval:600], 0, EBChargerStateUnplugged),
                Row([t0 dateByAddingTimeInterval:1200], 3000, EBChargerStateSolar),
            ];
            EBSoCEstimate e = EBInferSoC(samples, 40, t0, EBSoCSourceManual,
                                         60000, 0.90, [t0 dateByAddingTimeInterval:1200]);
            expect(!e.known, @"unplug invalidates");
        }

        // 5. capacityWh = 0 → known = NO.
        {
            NSArray *samples = @[
                Row(t0, 1000, EBChargerStateSolar),
                Row([t0 dateByAddingTimeInterval:60], 1000, EBChargerStateSolar),
            ];
            EBSoCEstimate e = EBInferSoC(samples, 40, t0, EBSoCSourceManual,
                                         0, 0.90, [t0 dateByAddingTimeInterval:60]);
            expect(!e.known, @"zero capacity → unknown");
        }

        // 6. Legacy guessed-full anchors are rejected. A solar pause is not proof
        // that the vehicle reached 100%.
        {
            NSArray *samples = @[
                Row(t0, 2000, EBChargerStateSolar),
                Row([t0 dateByAddingTimeInterval:600], 0, EBChargerStateSolar),
                Row([t0 dateByAddingTimeInterval:1800], 0, EBChargerStateSolar),
            ];
            EBSoCEstimate e = EBInferSoC(samples, 100, t0,
                                         EBSoCSourceFullCharge, 60000, 0.90,
                                         [t0 dateByAddingTimeInterval:1800]);
            expect(!e.known, @"legacy guessed-full anchor is rejected");
        }

        // 7. A 3-hour gap is not integrated or presented as continuous.
        {
            NSArray *samples = @[
                Row(t0, 3600, EBChargerStateSolar),
                Row([t0 dateByAddingTimeInterval:3 * 3600], 3600, EBChargerStateSolar),
            ];
            EBSoCEstimate e = EBInferSoC(samples, 40, t0, EBSoCSourceManual,
                                         60000, 0.90, [t0 dateByAddingTimeInterval:3 * 3600]);
            expect(!e.known && e.continuityUnknown,
                   @"long unbridged telemetry gap makes SoC unknown");
            expect(e.unknownReason == EBSoCUnknownReasonTelemetryGap,
                   @"unknown reason identifies telemetry continuity");
            expect(fabs(e.addedWh) < 1, @"3h gap skipped → no added Wh");
            expect(e.continuityGapSeconds > 2 * 3600,
                   @"gap metadata records the unsupported interval");
        }

        // 8. Exact session energy replaces, rather than adds to, local
        // integration over the same bounded interval.
        {
            NSArray *samples = ChargeHour(t0, 3600, EBChargerStateCharging);
            NSArray *sessions = @[@{
                @"id": @"session-a",
                @"chargeStart": [t0 dateByAddingTimeInterval:15 * 60],
                @"chargeEnd": [t0 dateByAddingTimeInterval:45 * 60],
                @"energyWh": @3000,
            }];
            EBSoCEstimate e = EBInferSoCWithSessions(
                samples, sessions, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:3600]);
            expect(e.known, @"bounded exact session preserves inference");
            expect(fabs(e.addedWh - 4800) < 1,
                   @"3 kWh exact plus 1.8 kWh outside session, no double count");
            expect(e.usedExactSessionEnergy && fabs(e.exactSessionWh - 3000) < 1,
                   @"estimate records exact session provenance");
        }

        // 9. A session that began before the anchor cannot be apportioned from
        // its cumulative total, so local telemetry remains authoritative.
        {
            NSArray *samples = ChargeHour(t0, 3600, EBChargerStateCharging);
            NSArray *sessions = @[@{
                @"id": @"crosses-anchor",
                @"chargeStart": [t0 dateByAddingTimeInterval:-60],
                @"chargeEnd": [t0 dateByAddingTimeInterval:30 * 60],
                @"energyWh": @9000,
            }];
            EBSoCEstimate e = EBInferSoCWithSessions(
                samples, sessions, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:3600]);
            expect(e.known && fabs(e.addedWh - 3600) < 1,
                   @"pre-anchor session total is ignored without double counting");
            expect(!e.usedExactSessionEnergy, @"ignored session is not marked exact");
        }

        // 10. Repeated snapshots of one active session use only the latest
        // bounded cumulative total.
        {
            NSArray *samples = ChargeHour(t0, 3600, EBChargerStateCharging);
            NSArray *sessions = @[
                @{
                    @"id": @"active",
                    @"chargeStart": t0,
                    @"chargeEnd": [t0 dateByAddingTimeInterval:30 * 60],
                    @"energyWh": @1800,
                },
                @{
                    @"id": @"active",
                    @"chargeStart": t0,
                    @"chargeEnd": [t0 dateByAddingTimeInterval:3600],
                    @"energyWh": @3600,
                },
            ];
            EBSoCEstimate e = EBInferSoCWithSessions(
                samples, sessions, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:3600]);
            expect(e.known && fabs(e.addedWh - 3600) < 1,
                   @"duplicate active-session snapshots are not accumulated");
        }

        // 11. Different session ids may not claim overlapping exact intervals.
        // Ambiguous exact records fail closed to the existing local telemetry.
        {
            NSArray *samples = ChargeHour(t0, 3600, EBChargerStateCharging);
            NSArray *sessions = @[
                @{
                    @"id": @"overlap-a",
                    @"chargeStart": t0,
                    @"chargeEnd": [t0 dateByAddingTimeInterval:40 * 60],
                    @"energyWh": @2400,
                },
                @{
                    @"id": @"overlap-b",
                    @"chargeStart": [t0 dateByAddingTimeInterval:20 * 60],
                    @"chargeEnd": [t0 dateByAddingTimeInterval:3600],
                    @"energyWh": @2400,
                },
            ];
            EBSoCEstimate e = EBInferSoCWithSessions(
                samples, sessions, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:3600]);
            expect(e.known && fabs(e.addedWh - 3600) < 1,
                   @"overlapping ids fall back to local integration");
            expect(!e.usedExactSessionEnergy,
                   @"ambiguous overlap is not presented as exact energy");
        }

        // 12. Session disconnect evidence independently invalidates SoC. It is
        // useful even when the record has no valid id or energy total.
        {
            NSDate *disconnected = [t0 dateByAddingTimeInterval:60];
            EBSoCEstimate e = EBInferSoCWithSessions(
                @[], @[@{@"disconnectedAt": disconnected}], 40, t0,
                EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:120]);
            expect(!e.known, @"post-anchor session disconnect invalidates");
            EBSoCEstimate simultaneous = EBInferSoCWithSessions(
                @[], @[@{@"disconnectedAt": t0}], 40, t0,
                EBSoCSourceManual, 60000, 0.90, [t0 dateByAddingTimeInterval:120]);
            expect(!simultaneous.known,
                   @"equal anchor/disconnect timestamps fail closed");
            expect([EBLatestSessionDisconnection(
                @[@{@"disconnectedAt": [t0 dateByAddingTimeInterval:-1]},
                  @{@"disconnectedAt": disconnected}], t0,
                [t0 dateByAddingTimeInterval:120]) isEqualToDate:disconnected],
                @"latest disconnect helper enforces the requested time window");

            EBSoCEstimate before = EBInferSoCWithSessions(
                @[], @[@{@"disconnectedAt": [t0 dateByAddingTimeInterval:-1]}],
                40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:120]);
            expect(before.known && fabs(before.percent - 40) < 0.1,
                   @"pre-anchor disconnect does not invalidate a newer anchor");
        }

        // 13. Edge gaps up to the integration threshold remain usable; one
        // second beyond it fails closed, including through the legacy API.
        {
            EBSoCEstimate edge = EBInferSoC(
                @[], 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:EBStoreIntegrationGapSeconds]);
            expect(edge.known && !edge.continuityUnknown,
                   @"edge gap exactly at threshold is accepted");
            EBSoCEstimate beyond = EBInferSoC(
                @[], 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:EBStoreIntegrationGapSeconds + 1]);
            expect(!beyond.known && beyond.continuityUnknown,
                   @"edge gap beyond threshold is unknown");
        }

        // Live status checkpoints are retained separately from power history,
        // so a connected waiting car remains continuous without fabricating W.
        {
            NSDate *now = [t0 dateByAddingTimeInterval:15 * 60];
            NSMutableArray *live = [NSMutableArray array];
            for (NSInteger minute = 0; minute <= 15; minute += 5) {
                [live addObject:@{
                    @"t": [t0 dateByAddingTimeInterval:minute * 60],
                    @"st": @(EBChargerStateWaiting),
                    @"statusOnly": @YES,
                }];
            }
            NSArray *merged = EBStoreMergeSamples(@[], live, now, 48 * 3600);
            EBSoCEstimate waiting = EBInferSoC(
                merged, 40, t0, EBSoCSourceManual, 60000, 0.90, now);
            expect(waiting.known && !waiting.continuityUnknown && waiting.addedWh == 0,
                   @"retained status ring bridges waiting continuity without energy");

            NSArray *charging = EBStoreMergeSamples(@[
                @{@"t": t0, @"chargeW": @1000},
                @{@"t": [t0 dateByAddingTimeInterval:300], @"chargeW": @1000},
            ], @[@{
                @"t": [t0 dateByAddingTimeInterval:150],
                @"st": @(EBChargerStateWaiting),
                @"statusOnly": @YES,
            }], [t0 dateByAddingTimeInterval:300], 48 * 3600);
            EBSoCEstimate withCheckpoint = EBInferSoC(
                charging, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:300]);
            expect(fabs(withCheckpoint.addedWh - (1000.0 / 12.0)) < 0.1,
                   @"status-only evidence does not split meter energy adjacency");

            NSArray *withFailure = EBStoreMergeSamples(@[
                @{@"t": t0, @"chargeW": @1000},
                @{@"t": [t0 dateByAddingTimeInterval:150],
                  @"st": @(EBChargerStateUnknown)},
                @{@"t": [t0 dateByAddingTimeInterval:300], @"chargeW": @1000},
            ], @[
                @{@"t": t0, @"st": @(EBChargerStateWaiting), @"statusOnly": @YES},
                @{@"t": [t0 dateByAddingTimeInterval:300],
                  @"st": @(EBChargerStateWaiting), @"statusOnly": @YES},
            ], [t0 dateByAddingTimeInterval:300], 48 * 3600);
            EBSoCEstimate failedOpportunity = EBInferSoC(
                withFailure, 40, t0, EBSoCSourceManual, 60000, 0.90,
                [t0 dateByAddingTimeInterval:300]);
            expect(failedOpportunity.known && failedOpportunity.addedWh == 0,
                   @"unmarked meter-failure row still breaks energy adjacency");
        }

        // 14. An exact session can bridge a long shutdown while tolerating only
        // short observation edges around its bounded register interval.
        {
            NSDate *now = [t0 dateByAddingTimeInterval:3600];
            NSArray *sessions = @[@{
                @"id": @"shutdown-bridge",
                @"chargeStart": [t0 dateByAddingTimeInterval:5 * 60],
                @"chargeEnd": [t0 dateByAddingTimeInterval:55 * 60],
                @"energyWh": @3000,
            }];
            EBSoCEstimate bridged = EBInferSoCWithSessions(
                @[], sessions, 40, t0, EBSoCSourceManual, 60000, 0.90, now);
            expect(bridged.known && !bridged.continuityUnknown,
                   @"exact session bridges shutdown with short edges");
            expect(fabs(bridged.addedWh - 3000) < 1,
                   @"bridged estimate uses exact session energy");

            NSMutableDictionary *missingEnergy = [sessions.firstObject mutableCopy];
            [missingEnergy removeObjectForKey:@"energyWh"];
            EBSoCEstimate untrusted = EBInferSoCWithSessions(
                @[], @[missingEnergy], 40, t0, EBSoCSourceManual,
                60000, 0.90, now);
            expect(!untrusted.known && untrusted.continuityUnknown,
                   @"session without exact energy cannot bridge telemetry");
        }

        // 15. Failed/unknown status rows do not manufacture continuity. Positive
        // charger power remains independent proof of a connected vehicle.
        {
            NSDate *now = [t0 dateByAddingTimeInterval:20 * 60];
            NSArray *unknownRows = @[
                Row([t0 dateByAddingTimeInterval:5 * 60], 0, EBChargerStateUnknown),
                Row([t0 dateByAddingTimeInterval:10 * 60], 0, EBChargerStateUnknown),
                Row([t0 dateByAddingTimeInterval:15 * 60], 0, EBChargerStateUnknown),
            ];
            EBSoCEstimate unknown = EBInferSoC(
                unknownRows, 40, t0, EBSoCSourceManual, 60000, 0.90, now);
            expect(!unknown.known && unknown.continuityUnknown,
                   @"unknown poll rows do not hide an API outage");

            NSArray *poweredRows = @[
                Row([t0 dateByAddingTimeInterval:5 * 60], 1000, EBChargerStateUnknown),
                Row([t0 dateByAddingTimeInterval:10 * 60], 1000, EBChargerStateUnknown),
                Row([t0 dateByAddingTimeInterval:15 * 60], 1000, EBChargerStateUnknown),
            ];
            EBSoCEstimate powered = EBInferSoC(
                poweredRows, 40, t0, EBSoCSourceManual, 60000, 0.90, now);
            expect(powered.known && !powered.continuityUnknown,
                   @"positive charging power bridges independent status failures");
        }

        puts("ok: soc inference");
    }
    return 0;
}
