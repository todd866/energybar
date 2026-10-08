#import <Foundation/Foundation.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>
#import "vehicle.h"
#import "pure.h"

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

static NSString *ISODate(NSDate *date) {
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime
        | NSISO8601DateFormatWithFractionalSeconds;
    return [f stringFromDate:date];
}

static mode_t PermissionsAtPath(NSString *path) {
    struct stat info = {0};
    if (stat(path.fileSystemRepresentation, &info) != 0) return 0;
    return info.st_mode & 0777;
}

static void CreateBlocker(NSString *path) {
    expect([@"blocked" writeToFile:path atomically:NO
                           encoding:NSUTF8StringEncoding error:nil],
           @"create regular-file blocker");
}

static void SabotageDirectory(NSString *directory, NSString *backup) {
    expect([NSFileManager.defaultManager moveItemAtPath:directory
                                                 toPath:backup error:nil],
           @"move persistence directory aside");
    CreateBlocker(directory);
}

static void RestoreDirectory(NSString *directory, NSString *backup) {
    expect([NSFileManager.defaultManager removeItemAtPath:directory error:nil],
           @"remove regular-file blocker");
    expect([NSFileManager.defaultManager moveItemAtPath:backup
                                                 toPath:directory error:nil],
           @"restore persistence directory");
}

/// Test double: pretends to be a live OBD reading (seam is always unavailable today).
@interface EBFakeOBDAvailable : NSObject <EBVehicleProvider>
@property(copy, nullable) NSDate *measuredAt;
@end
@implementation EBFakeOBDAvailable
- (BOOL)available { return YES; }
- (BOOL)hasSOC { return YES; }
- (double)socPercent { return 71; }
- (BOOL)socIsEstimate { return NO; }
- (NSDate *)socUpdatedAt { return self.measuredAt ?: [NSDate distantFuture]; }
- (NSDate *)socInvalidatedAt { return nil; }
- (BOOL)hasReady { return NO; }
- (BOOL)readyToCharge { return NO; }
- (NSDate *)readyUpdatedAt { return nil; }
- (NSString *)statusLine { return @"71% · OBD"; }
- (NSDictionary *)dictionaryValue {
    return @{
        @"available": @YES,
        @"source": @"obd",
        @"socPercent": @71,
        @"estimated": @NO,
    };
}
@end

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"energybar-vehicle-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"vehicle.json"];

        EBVehicleManualProvider *g = [[EBVehicleManualProvider alloc] initWithPath:path];
        expect(!g.available, @"empty unavailable");
        expect([g.statusLine containsString:@"AU API"], @"empty status mentions API");

        expect([g setSOC:62], @"soc write succeeds");
        NSDate *socSetAt = g.socUpdatedAt;
        expect(g.hasSOC && g.socPercent == 62, @"soc set");
        expect(g.persistenceError == nil, @"successful write has no persistence error");
        expect(PermissionsAtPath(path) == 0600, @"manual state file is private");
        expect(PermissionsAtPath(dir) == 0700, @"manual state directory is private");
        expect(!g.socIsEstimate && socSetAt != nil, @"manual SoC is direct and timestamped");
        expect([g.statusLine isEqualToString:@"62%"], @"soc-only line");

        expect([g setReady:YES], @"ready write succeeds");
        expect(g.readyToCharge, @"ready");
        expect([g.socUpdatedAt isEqualToDate:socSetAt],
               @"changing readiness does not refresh SoC timestamp");
        expect(g.readyUpdatedAt != nil, @"readiness has its own timestamp");
        expect([g.statusLine isEqualToString:@"62% · ready"], @"combined line");

        EBVehicleManualProvider *g2 = [[EBVehicleManualProvider alloc] initWithPath:path];
        expect(g2.hasSOC && g2.socPercent == 62 && g2.readyToCharge, @"reload persists");

        expect([g2 setReady:NO], @"not-ready write succeeds");
        expect([g2.statusLine isEqualToString:@"62% · not ready"], @"not ready");

        expect([g2 setSOC:150], @"high SoC write succeeds");
        expect(g2.socPercent == 100, @"clamp high");
        expect([g2 setSOC:-5], @"low SoC write succeeds");
        expect(g2.socPercent == 0, @"clamp low");
        NSDate *finiteAt = g2.socUpdatedAt;
        expect(![g2 setSOC:NAN] && ![g2 setSOC:INFINITY], @"manual rejects non-finite SoC");
        expect(g2.hasSOC && g2.socPercent == 0
               && [g2.socUpdatedAt isEqualToDate:finiteAt],
               @"invalid SoC leaves prior in-memory value untouched");

        NSDictionary *d = g2.dictionaryValue;
        expect([d[@"source"] isEqualToString:@"manual"], @"dump source");
        expect([d[@"available"] boolValue], @"dump available");
        expect(![d[@"estimated"] boolValue], @"manual dump explicitly direct");
        expect(d[@"socUpdatedAt"] != nil && d[@"readyUpdatedAt"] != nil,
               @"dump has per-field timestamps");

        expect([g2 clear], @"manual clear succeeds");
        expect(!g2.available && ![[NSFileManager defaultManager] fileExistsAtPath:path], @"cleared");

        NSString *typedPath = [dir stringByAppendingPathComponent:@"typed.json"];
        NSData *typedData = [NSJSONSerialization dataWithJSONObject:@{
            @"soc": @YES, @"ready": @1,
        } options:0 error:nil];
        expect([typedData writeToFile:typedPath atomically:YES], @"write typed-state fixture");
        EBVehicleManualProvider *typed = [[EBVehicleManualProvider alloc] initWithPath:typedPath];
        expect(!typed.hasSOC && !typed.hasReady,
               @"JSON booleans and numbers cannot swap vehicle field types");

        EBVehicleStubProvider *stub = [EBVehicleStubProvider new];
        expect(!stub.available, @"stub");
        expect([stub.dictionaryValue[@"socSource"] isEqualToString:@"none"],
               @"stub JSON explicitly has no SoC source");

        // A regular file where the state directory should be is a deterministic
        // write failure even when tests run with broad filesystem privileges.
        NSString *manualBlocker = [dir stringByAppendingPathComponent:@"manual-blocker"];
        CreateBlocker(manualBlocker);
        EBVehicleManualProvider *blockedManual = [[EBVehicleManualProvider alloc]
            initWithPath:[manualBlocker stringByAppendingPathComponent:@"state.json"]];
        expect(![blockedManual setSOC:48] && !blockedManual.hasSOC,
               @"failed manual SoC write rolls back in-memory state");
        expect(blockedManual.persistenceError != nil,
               @"failed manual SoC write exposes persistence error");
        expect(![blockedManual setReady:YES] && !blockedManual.hasReady,
               @"failed readiness write rolls back in-memory state");

        // Explicit clear is transactional too: if deletion cannot be attempted,
        // callers see failure and the provider continues reporting its old state.
        NSString *manualClearDir = [dir stringByAppendingPathComponent:@"manual-clear"];
        NSString *manualClearPath = [manualClearDir stringByAppendingPathComponent:@"state.json"];
        NSString *manualClearBackup = [dir stringByAppendingPathComponent:@"manual-clear.saved"];
        EBVehicleManualProvider *manualClear = [[EBVehicleManualProvider alloc]
            initWithPath:manualClearPath];
        expect([manualClear setSOC:52] && [manualClear setReady:YES],
               @"seed manual state for clear failure");
        SabotageDirectory(manualClearDir, manualClearBackup);
        expect(![manualClear clear], @"manual clear reports delete failure");
        expect(manualClear.hasSOC && manualClear.hasReady && manualClear.readyToCharge,
               @"failed manual clear preserves in-memory state");
        expect(manualClear.persistenceError != nil,
               @"failed manual clear exposes persistence error");
        RestoreDirectory(manualClearDir, manualClearBackup);
        expect([manualClear clear] && manualClear.persistenceError == nil,
               @"manual clear succeeds after storage recovers");

        // Safety invalidation is deliberately fail-safe rather than transactional:
        // suppress SoC immediately, preserve readiness, and retry the tombstone.
        NSString *manualSafetyDir = [dir stringByAppendingPathComponent:@"manual-safety"];
        NSString *manualSafetyPath = [manualSafetyDir stringByAppendingPathComponent:@"state.json"];
        NSString *manualSafetyBackup = [dir stringByAppendingPathComponent:@"manual-safety.saved"];
        EBVehicleManualProvider *manualSafety = [[EBVehicleManualProvider alloc]
            initWithPath:manualSafetyPath];
        expect([manualSafety setSOC:64] && [manualSafety setReady:NO],
               @"seed manual state for invalidation failure");
        NSDate *manualUnplug = [manualSafety.socUpdatedAt dateByAddingTimeInterval:60];
        SabotageDirectory(manualSafetyDir, manualSafetyBackup);
        expect(![manualSafety invalidateSOCAt:manualUnplug],
               @"manual tombstone reports persistence failure");
        expect(!manualSafety.hasSOC && manualSafety.hasReady
               && !manualSafety.readyToCharge,
               @"failed tombstone remains safe in memory and preserves readiness");
        expect(manualSafety.persistenceError != nil,
               @"failed manual tombstone exposes persistence error");
        RestoreDirectory(manualSafetyDir, manualSafetyBackup);
        expect([manualSafety invalidateSOCAt:manualUnplug]
               && manualSafety.persistenceError == nil,
               @"identical manual tombstone retries after storage recovers");
        EBVehicleManualProvider *manualSafetyReload = [[EBVehicleManualProvider alloc]
            initWithPath:manualSafetyPath];
        expect(!manualSafetyReload.hasSOC && manualSafetyReload.hasReady,
               @"retried manual tombstone is durable and readiness survives");

        // --- OBD seam: default unavailable; dump source is obd ---
        EBVehicleOBDProvider *obd = [[EBVehicleOBDProvider alloc]
            initWithCachePath:[dir stringByAppendingPathComponent:@"obd.json"]
            maxAgeSeconds:900];
        expect(!obd.available, @"OBD seam unavailable until cache+freshness");
        expect(!obd.hasSOC, @"OBD seam has no SoC");
        NSDictionary *obdDump = obd.dictionaryValue;
        expect([obdDump[@"source"] isEqualToString:@"obd"], @"OBD dump source");
        // A helper's cache: a fresh reading is a direct (not estimated) level; a stale run or an
        // error never yields a number.
        {
            NSString *cachePath = [dir stringByAppendingPathComponent:@"cloud.json"];
            NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
            NSString *now = [iso stringFromDate:[NSDate date]];
            NSData *fresh = [NSJSONSerialization dataWithJSONObject:@{@"soc": @64, @"rangeKm": @51, @"at": now,
                                                                      @"checkedAt": now, @"source": @"cloud"} options:0 error:nil];
            [fresh writeToFile:cachePath atomically:YES];
            EBVehicleOBDProvider *cloud = [[EBVehicleOBDProvider alloc] initWithCachePath:cachePath
                                                                          maxAgeSeconds:1800 label:@"cloud"];
            expect(cloud.available && cloud.hasSOC && fabs(cloud.socPercent - 64) < 0.001 && !cloud.socIsEstimate,
                   @"cloud cache: fresh reading is a direct level");
            expect([cloud.statusLine containsString:@"64%"] && [cloud.statusLine containsString:@"51 km"],
                   @"cloud cache: status line names level and range");
            NSString *old = [iso stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-7200]];
            NSData *stale = [NSJSONSerialization dataWithJSONObject:@{@"soc": @64, @"at": old, @"checkedAt": old} options:0 error:nil];
            [NSThread sleepForTimeInterval:1.1];   // a new mtime, so the provider re-reads
            [stale writeToFile:cachePath atomically:YES];
            expect(!cloud.available && !cloud.hasSOC, @"cloud cache: a stale helper run shows no level");
            NSData *err = [NSJSONSerialization dataWithJSONObject:@{@"error": @"signed out", @"checkedAt": now} options:0 error:nil];
            [NSThread sleepForTimeInterval:1.1];
            [err writeToFile:cachePath atomically:YES];
            expect(!cloud.available && [cloud.lastError isEqualToString:@"signed out"],
                   @"cloud cache: an error is reported, not a number");
        }
        expect(![obdDump[@"available"] boolValue], @"OBD dump unavailable");
        expect(![obdDump[@"estimated"] boolValue], @"OBD dump explicitly direct");
        expect([obd.statusLine containsString:@"OBD"], @"OBD status mentions OBD");

        // --- Resolution chain: OBD → live → inferred → manual → stub ---
        NSString *veh = [dir stringByAppendingPathComponent:@"vehicle.json"];
        EBVehicleLiveProvider *live = [[EBVehicleLiveProvider alloc]
            initWithTokenPath:[dir stringByAppendingPathComponent:@"vehicle-live.json"]];
        EBVehicleInferredProvider *inf = [[EBVehicleInferredProvider alloc]
            initWithPath:veh capacityWh:60000 efficiency:0.90];
        EBVehicleManualProvider *man = [[EBVehicleManualProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"man.json"]];
        [man setSOC:40];
        NSDate *t0 = man.socUpdatedAt;
        [man setReady:NO];

        id<EBVehicleProvider> r0 = EBResolveVehicle(@[obd, live, inf, man, stub]);
        expect(r0.hasSOC && r0.socPercent == 40, @"manual SoC resolves initially");
        expect(!r0.socIsEstimate, @"direct manual reading is not estimated");
        expect(r0.hasReady && !r0.readyToCharge, @"manual readiness resolves independently");

        [inf setAnchorPercent:40 at:t0 source:EBSoCSourceManual];
        NSArray *samples = ChargeHour(t0, 3600, EBChargerStateSolar);
        [inf updateWithSamples:samples now:[t0 dateByAddingTimeInterval:3600]];
        expect(inf.available, @"inferred available after update");
        expect([inf.statusLine rangeOfString:@"est."].location != NSNotFound,
               @"inferred statusLine contains est.");
        expect([inf.statusLine rangeOfString:@"%"].location != NSNotFound, @"has percent");
        NSString *line = inf.statusLine;
        expect(line.length > 4, @"not bare");
        expect([line containsString:@"·"], @"has provenance separator");

        id<EBVehicleProvider> r2 = EBResolveVehicle(@[obd, live, inf, man, stub]);
        expect(r2.hasSOC && r2.socIsEstimate, @"inferred SoC beats direct manual anchor");
        expect(r2.hasReady && !r2.readyToCharge,
               @"manual readiness is preserved while inferred SoC wins");
        NSDictionary *resolvedDump = r2.dictionaryValue;
        expect([resolvedDump[@"estimated"] boolValue], @"resolved dump marks estimate");
        expect([resolvedDump[@"source"] isEqualToString:@"inferred-manual"],
               @"inferred-manual differs from direct manual source");
        expect([resolvedDump[@"anchorSource"] isEqualToString:@"manual"],
               @"resolved dump retains anchor provenance");
        expect([resolvedDump[@"readySource"] isEqualToString:@"manual"],
               @"resolved dump identifies independent readiness source");

        // Exact Evnex session totals replace overlapping local samples while
        // retaining explicit provenance in provider and resolved JSON.
        EBVehicleInferredProvider *sessionInf = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"session-energy.json"]
            capacityWh:60000 efficiency:0.90];
        expect([sessionInf setAnchorPercent:40 at:t0 source:EBSoCSourceManual],
               @"seed session-aware inferred anchor");
        NSArray *sessionRecords = @[@{
            @"id": @"session-a",
            @"chargeStart": [t0 dateByAddingTimeInterval:15 * 60],
            @"chargeEnd": [t0 dateByAddingTimeInterval:45 * 60],
            @"energyWh": @3000,
        }];
        expect([sessionInf updateWithSamples:samples sessions:sessionRecords
                                          now:[t0 dateByAddingTimeInterval:3600]],
               @"session-aware provider update succeeds");
        expect(sessionInf.hasSOC && fabs(sessionInf.estimate.addedWh - 4800) < 1,
               @"provider replaces overlapping local energy with exact session total");
        NSDictionary *sessionDump = EBResolveVehicle(@[sessionInf, man, stub]).dictionaryValue;
        expect([sessionDump[@"sessionEnergyExact"] boolValue]
               && fabs([sessionDump[@"sessionEnergyWh"] doubleValue] - 3000) < 1,
               @"resolved JSON exposes exact session-energy provenance");

        // A session-level EV disconnect follows the same durable invalidation
        // path as a live unplug row and remains effective after session data ages.
        EBVehicleManualProvider *sessionManual = [[EBVehicleManualProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"session-manual.json"]];
        expect([sessionManual setSOC:44] && [sessionManual setReady:YES],
               @"seed independent manual state for session disconnect");
        NSDate *sessionAnchorAt = sessionManual.socUpdatedAt;
        NSString *sessionTombstonePath =
            [dir stringByAppendingPathComponent:@"session-tombstone.json"];
        EBVehicleInferredProvider *sessionTombstone = [[EBVehicleInferredProvider alloc]
            initWithPath:sessionTombstonePath capacityWh:60000 efficiency:0.90];
        expect([sessionTombstone setAnchorPercent:44 at:sessionAnchorAt
                                          source:EBSoCSourceManual],
               @"seed inferred state for session disconnect");
        NSDate *sessionDisconnectedAt =
            [sessionAnchorAt dateByAddingTimeInterval:60];
        NSArray *disconnectedSession = @[@{
            @"id": @"departed",
            @"chargeStart": sessionAnchorAt,
            @"chargeEnd": sessionDisconnectedAt,
            @"energyWh": @0,
            @"disconnectedAt": sessionDisconnectedAt,
        }];
        expect([sessionTombstone updateWithSamples:@[] sessions:disconnectedSession
                                               now:sessionDisconnectedAt],
               @"session disconnect tombstone persists");
        id<EBVehicleProvider> sessionDeparted =
            EBResolveVehicle(@[sessionTombstone, sessionManual, stub]);
        expect(!sessionDeparted.hasSOC && sessionDeparted.hasReady
               && sessionDeparted.readyToCharge,
               @"session disconnect clears SoC and preserves readiness");
        EBVehicleInferredProvider *sessionTombstoneReload =
            [[EBVehicleInferredProvider alloc] initWithPath:sessionTombstonePath
                                                capacityWh:60000 efficiency:0.90];
        expect([sessionTombstoneReload updateWithSamples:@[] sessions:nil
                                                     now:[sessionDisconnectedAt
                                                          dateByAddingTimeInterval:86400]]
               && !sessionTombstoneReload.hasSOC
               && fabs([sessionTombstoneReload.socInvalidatedAt
                        timeIntervalSinceDate:sessionDisconnectedAt]) < 0.01,
               @"session disconnect remains durable after records disappear");

        // A telemetry gap is a soft uncertainty: suppress the old manual
        // fallback without deleting it or its independent readiness, explain
        // the reason in status/JSON, and recover when exact sessions bridge it.
        NSString *gapManualPath =
            [dir stringByAppendingPathComponent:@"gap-manual.json"];
        NSDate *gapAnchor = [NSDate dateWithTimeIntervalSinceNow:-3600];
        NSDictionary *oldManualState = @{
            @"soc": @50,
            @"socUpdatedAt": ISODate(gapAnchor),
            @"ready": @YES,
            @"readyUpdatedAt": ISODate(gapAnchor),
            @"updatedAt": ISODate(gapAnchor),
        };
        NSData *oldManualData = [NSJSONSerialization dataWithJSONObject:oldManualState
                                                                 options:0 error:nil];
        expect([oldManualData writeToFile:gapManualPath atomically:YES],
               @"seed old manual state for continuity gate");
        EBVehicleManualProvider *gapManual = [[EBVehicleManualProvider alloc]
            initWithPath:gapManualPath];
        NSDate *gapAnchorStored = gapManual.socUpdatedAt;
        EBVehicleInferredProvider *gapInf = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"gap-inferred.json"]
            capacityWh:60000 efficiency:0.90];
        expect([gapInf setAnchorPercent:50 at:gapAnchorStored source:EBSoCSourceManual],
               @"seed old inferred anchor for continuity gate");
        EBVehicleInferredProvider *gapStartup = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"gap-inferred.json"]
            capacityWh:60000 efficiency:0.90];
        id<EBVehicleProvider> startupResolved =
            EBResolveVehicle(@[gapStartup, gapManual, stub]);
        expect(gapStartup.estimate.continuityUnknown && !startupResolved.hasSOC,
               @"startup gate hides stale manual SoC before the first poll");
        NSDate *gapNow = [gapAnchorStored dateByAddingTimeInterval:3600];
        NSArray *gapSamples = @[
            Row(gapAnchorStored, 0, EBChargerStateWaiting),
            Row(gapNow, 0, EBChargerStateWaiting),
        ];
        expect([gapInf updateWithSamples:gapSamples sessions:nil now:gapNow]
               && gapInf.estimate.continuityUnknown,
               @"long unbridged poll gap makes inferred SoC unknown");
        id<EBVehicleProvider> gapResolved = EBResolveVehicle(@[gapInf, gapManual, stub]);
        expect(!gapResolved.hasSOC && gapResolved.hasReady
               && gapResolved.readyToCharge && gapManual.hasSOC,
               @"gap hides but does not delete manual SoC or readiness");
        expect([gapResolved.statusLine containsString:@"telemetry gap"],
               @"gap status distinguishes continuity from a missing anchor");
        NSDictionary *gapDump = gapResolved.dictionaryValue;
        expect([gapDump[@"continuityUnknown"] boolValue]
               && [gapDump[@"unknownReason"] isEqualToString:@"telemetry-gap"]
               && gapDump[@"continuityUnknownAt"] != nil
               && [gapDump[@"continuityGapSeconds"] doubleValue] > 0,
               @"gap JSON exposes flag, reason, time, and duration");
        expect([gapDump[@"socSource"] isEqualToString:@"none"]
               && gapDump[@"socPercent"] == nil,
               @"gap JSON does not leak the stale manual percentage");

        NSDate *gapCutoff = [NSDate dateWithTimeIntervalSince1970:
                             gapInf.estimate.continuityUnknownAt];
        EBFakeOBDAvailable *atGapCutoff = [EBFakeOBDAvailable new];
        atGapCutoff.measuredAt = gapCutoff;
        id<EBVehicleProvider> stillUnknown =
            EBResolveVehicle(@[atGapCutoff, gapInf, gapManual, stub]);
        expect(!stillUnknown.hasSOC
               && [stillUnknown.dictionaryValue[@"continuityUnknown"] boolValue],
               @"direct reading at the cutoff does not recover uncertainty");

        EBFakeOBDAvailable *postGapDirect = [EBFakeOBDAvailable new];
        postGapDirect.measuredAt = [gapCutoff dateByAddingTimeInterval:0.001];
        id<EBVehicleProvider> directRecovery =
            EBResolveVehicle(@[postGapDirect, gapInf, gapManual, stub]);
        expect(directRecovery.hasSOC && !directRecovery.socIsEstimate
               && directRecovery.socPercent == 71
               && ![directRecovery.dictionaryValue[@"continuityUnknown"] boolValue],
               @"newer direct reading recovers from soft continuity uncertainty");

        NSArray *gapBridge = @[@{
            @"id": @"gap-bridge",
            @"chargeStart": [gapAnchorStored dateByAddingTimeInterval:5 * 60],
            @"chargeEnd": [gapAnchorStored dateByAddingTimeInterval:55 * 60],
            @"energyWh": @3000,
        }];
        expect([gapInf updateWithSamples:gapSamples sessions:gapBridge now:gapNow]
               && gapInf.hasSOC && !gapInf.estimate.continuityUnknown,
               @"bounded exact session reconciles soft continuity uncertainty");
        id<EBVehicleProvider> bridgedResolved =
            EBResolveVehicle(@[gapInf, gapManual, stub]);
        expect(bridgedResolved.hasSOC && bridgedResolved.socIsEstimate,
               @"reconciled estimate resolves as estimated SoC");
        expect(bridgedResolved.hasReady && bridgedResolved.readyToCharge,
               @"reconciled estimate composes with preserved readiness");

        // A newer direct reading must beat an older estimate. This is also the
        // safe fallback when the manual save succeeds but refreshing the
        // secondary inferred-anchor file fails.
        EBVehicleInferredProvider *olderEstimate = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"older-estimate.json"]
            capacityWh:60000 efficiency:0.90];
        NSDate *olderAt = [t0 dateByAddingTimeInterval:-60];
        expect([olderEstimate setAnchorPercent:25 at:olderAt source:EBSoCSourceManual]
               && [olderEstimate updateWithSamples:@[] now:t0]
               && olderEstimate.hasSOC && olderEstimate.socIsEstimate,
               @"seed older estimate");
        EBVehicleManualProvider *newerManual = [[EBVehicleManualProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"newer-manual.json"]];
        expect([newerManual setSOC:80], @"save newer direct manual reading");
        id<EBVehicleProvider> newerDirect = EBResolveVehicle(@[olderEstimate, newerManual, stub]);
        expect(newerDirect.hasSOC && !newerDirect.socIsEstimate
               && fabs(newerDirect.socPercent - 80) < 0.1,
               @"newer direct reading beats older estimate");

        EBFakeOBDAvailable *obdLive = [EBFakeOBDAvailable new];
        id<EBVehicleProvider> rOBD = EBResolveVehicle(@[obdLive, live, inf, man, stub]);
        expect(rOBD.socPercent == 71, @"OBD SoC wins");
        expect(!rOBD.socIsEstimate, @"OBD SoC is direct");
        expect(rOBD.hasReady && !rOBD.readyToCharge,
               @"OBD SoC composes with manual readiness");

        // A normal solar pause must not create an automatic 100% anchor.
        EBVehicleInferredProvider *noAnchor = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"no-anchor.json"]
            capacityWh:60000 efficiency:0.90];
        NSArray *solarPause = @[
            Row(t0, 2000, EBChargerStateSolar),
            Row([t0 dateByAddingTimeInterval:600], 0, EBChargerStateSolar),
            Row([t0 dateByAddingTimeInterval:1800], 0, EBChargerStateSolar),
        ];
        [noAnchor updateWithSamples:solarPause now:[t0 dateByAddingTimeInterval:1800]];
        expect(!noAnchor.available, @"solar pause does not invent a full anchor");
        [noAnchor setAnchorPercent:100 at:t0 source:EBSoCSourceFullCharge];
        [noAnchor updateWithSamples:solarPause now:[t0 dateByAddingTimeInterval:1800]];
        expect(!noAnchor.available, @"legacy guessed-full source is rejected");

        // Manual set → inferred charging → unplug. The unplug tombstone must
        // suppress both the estimate and its old direct-manual fallback.
        NSDate *unplugAt = [t0 dateByAddingTimeInterval:3900];
        NSMutableArray *departedRows = [samples mutableCopy];
        [departedRows addObject:Row(unplugAt, 0, EBChargerStateUnplugged)];
        NSArray *departed = departedRows;
        [inf updateWithSamples:departed now:unplugAt];
        expect(!inf.hasSOC && inf.socInvalidatedAt != nil,
               @"unplug clears estimate and records tombstone");
        expect([[NSFileManager defaultManager] fileExistsAtPath:veh],
               @"unplug tombstone is persisted without an anchor");

        id<EBVehicleProvider> afterUnplug = EBResolveVehicle(@[obd, live, inf, man, stub]);
        expect(!afterUnplug.hasSOC, @"old manual SoC does not reappear after unplug");
        expect(!man.hasSOC, @"unplug removes old SoC from durable manual store");
        expect([afterUnplug.statusLine rangeOfString:@"%"].location == NSNotFound,
               @"invalidated manual percentage is absent from status text");
        expect([afterUnplug.statusLine containsString:@"Battery unknown"]
               && [afterUnplug.statusLine containsString:@"cleared after unplug"],
               @"tombstone status explains why battery SoC is unknown");
        expect(afterUnplug.hasReady && !afterUnplug.readyToCharge,
               @"manual readiness survives unplug invalidation");
        NSDictionary *afterDump = afterUnplug.dictionaryValue;
        expect(![afterDump[@"estimated"] boolValue],
               @"no-SoC dump explicitly says it is not an estimate");
        expect([afterDump[@"source"] isEqualToString:@"none"],
               @"no-SoC dump has honest source");
        expect(afterDump[@"socPercent"] == nil, @"no-SoC dump omits percentage");
        expect(afterDump[@"socInvalidatedAt"] != nil, @"dump exposes invalidation");
        expect([afterDump[@"readyToCharge"] isEqual:@NO], @"dump preserves readiness");

        // Once the unplug row ages out, a fresh provider still loads the durable
        // tombstone and keeps the old manual percentage suppressed.
        EBVehicleInferredProvider *reloaded = [[EBVehicleInferredProvider alloc]
            initWithPath:veh capacityWh:60000 efficiency:0.90];
        [reloaded updateWithSamples:@[] now:[unplugAt dateByAddingTimeInterval:86400]];
        id<EBVehicleProvider> afterAging = EBResolveVehicle(@[reloaded, man, stub]);
        expect(!afterAging.hasSOC, @"aged-out unplug cannot resurrect old anchor/manual SoC");
        [man setReady:YES];
        expect(!man.hasSOC && man.socUpdatedAt == nil,
               @"readiness update does not recreate cleared SoC");
        id<EBVehicleProvider> afterReadyEdit = EBResolveVehicle(@[reloaded, man, stub]);
        expect(!afterReadyEdit.hasSOC && afterReadyEdit.readyToCharge,
               @"readiness edit cannot revive invalidated manual SoC");

        // Losing the cache file must still be safe because the tombstone was
        // mirrored into the manual config store.
        EBVehicleManualProvider *manualReload = [[EBVehicleManualProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"man.json"]];
        expect(!manualReload.hasSOC && manualReload.readyToCharge,
               @"manual store reload retains readiness but no invalidated SoC");
        [[NSFileManager defaultManager] removeItemAtPath:veh error:nil];
        id<EBVehicleProvider> afterCacheLoss = EBResolveVehicle(@[manualReload, stub]);
        expect(!afterCacheLoss.hasSOC && afterCacheLoss.readyToCharge,
               @"cache loss cannot resurrect manual SoC");
        expect(afterCacheLoss.dictionaryValue[@"socInvalidatedAt"] != nil,
               @"manual store preserves tombstone in JSON after cache loss");

        // A genuinely newer direct anchor must recover normally after unplug.
        NSDate *freshAt = [unplugAt dateByAddingTimeInterval:60];
        EBVehicleInferredProvider *fresh = [[EBVehicleInferredProvider alloc]
            initWithPath:veh capacityWh:60000 efficiency:0.90];
        [fresh setAnchorPercent:55 at:freshAt source:EBSoCSourceManual];
        [fresh updateWithSamples:@[] now:freshAt];
        id<EBVehicleProvider> recovered = EBResolveVehicle(@[fresh, manualReload, stub]);
        expect(recovered.hasSOC && recovered.socIsEstimate
               && fabs(recovered.socPercent - 55) < 0.1,
               @"newer post-unplug anchor restores SoC");

        // Tombstone-only state remains observable in JSON rather than collapsing
        // to an indistinguishable plain stub.
        EBVehicleManualProvider *soloManual = [[EBVehicleManualProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"solo-manual.json"]];
        [soloManual setSOC:30];
        NSDate *soloAt = soloManual.socUpdatedAt;
        EBVehicleInferredProvider *soloInf = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"solo-vehicle.json"]
            capacityWh:60000 efficiency:0.90];
        [soloInf setAnchorPercent:30 at:soloAt source:EBSoCSourceManual];
        NSDate *soloUnplug = [soloAt dateByAddingTimeInterval:60];
        [soloInf updateWithSamples:@[Row(soloUnplug, 0, EBChargerStateUnplugged)]
                              now:soloUnplug];
        id<EBVehicleProvider> tombstoneOnly = EBResolveVehicle(@[soloInf, soloManual, stub]);
        expect(!tombstoneOnly.available && tombstoneOnly.socInvalidatedAt != nil,
               @"tombstone-only resolver stays unavailable but retains invalidation");
        expect(tombstoneOnly.dictionaryValue[@"socInvalidatedAt"] != nil,
               @"tombstone-only dump exposes invalidation");
        expect([soloManual clear] && [soloInf clearAllState],
               @"explicit vehicle clear removes manual and inferred state");
        expect(soloInf.socInvalidatedAt == nil,
               @"explicit vehicle clear removes the unplug tombstone too");
        expect([soloInf updateWithSamples:@[Row(soloUnplug, 0, EBChargerStateUnplugged)]
                                           now:[soloUnplug dateByAddingTimeInterval:60]]
               && soloInf.socInvalidatedAt == nil,
               @"cleared historical unplug cannot recreate the tombstone");
        EBVehicleInferredProvider *clearedReload = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"solo-vehicle.json"]
            capacityWh:60000 efficiency:0.90];
        expect([clearedReload updateWithSamples:@[Row(soloUnplug, 0, EBChargerStateUnplugged)]
                                               now:[soloUnplug dateByAddingTimeInterval:60]]
               && clearedReload.socInvalidatedAt == nil,
               @"history-clear high-water mark survives restart");
        NSDate *futureUnplug = [NSDate dateWithTimeIntervalSinceNow:120];
        expect([clearedReload updateWithSamples:@[Row(futureUnplug, 0, EBChargerStateUnplugged)]
                                               now:futureUnplug]
               && clearedReload.socInvalidatedAt != nil,
               @"a genuinely new unplug still creates a tombstone");
        id<EBVehicleProvider> fullyCleared = EBResolveVehicle(@[soloInf, soloManual, stub]);
        expect(!fullyCleared.available && fullyCleared.socInvalidatedAt == nil,
               @"clear vehicle data returns to a plain empty provider");

        // Migration: strip a legacy guessed-full anchor from disk while retaining
        // any genuine unplug tombstone in that same state file.
        NSString *legacyPath = [dir stringByAppendingPathComponent:@"legacy-full.json"];
        NSDate *legacyInvalidation = [t0 dateByAddingTimeInterval:-60];
        NSDictionary *legacyState = @{
            @"soc": @100,
            @"at": ISODate(t0),
            @"source": @"full",
            @"invalidatedAt": ISODate(legacyInvalidation),
        };
        NSData *legacyData = [NSJSONSerialization dataWithJSONObject:legacyState
                                                              options:0 error:nil];
        expect([legacyData writeToFile:legacyPath atomically:YES], @"seed legacy state");
        EBVehicleInferredProvider *legacy = [[EBVehicleInferredProvider alloc]
            initWithPath:legacyPath capacityWh:60000 efficiency:0.90];
        [legacy updateWithSamples:solarPause now:[t0 dateByAddingTimeInterval:1800]];
        expect(!legacy.hasSOC, @"persisted guessed-full anchor is rejected on load");
        NSDictionary *migrated = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:legacyPath] options:0 error:nil];
        expect(migrated[@"soc"] == nil && migrated[@"invalidatedAt"] != nil,
               @"migration strips guessed anchor but preserves tombstone");

        // User-supplied anchors reject non-finite percentages without touching
        // memory or disk.
        NSString *invalidAnchorPath = [dir stringByAppendingPathComponent:@"invalid-anchor.json"];
        EBVehicleInferredProvider *invalidAnchor = [[EBVehicleInferredProvider alloc]
            initWithPath:invalidAnchorPath capacityWh:60000 efficiency:0.90];
        expect(![invalidAnchor setAnchorPercent:NAN at:t0 source:EBSoCSourceManual]
               && ![invalidAnchor setAnchorPercent:INFINITY at:t0 source:EBSoCSourceManual],
               @"inferred provider rejects non-finite anchor SoC");
        expect([invalidAnchor updateWithSamples:@[] now:t0] && !invalidAnchor.hasSOC,
               @"rejected anchor cannot become an estimate");
        expect(![NSFileManager.defaultManager fileExistsAtPath:invalidAnchorPath],
               @"rejected anchor does not create state");

        // A blocked parent must make anchor persistence fail transactionally.
        NSString *anchorBlocker = [dir stringByAppendingPathComponent:@"anchor-blocker"];
        CreateBlocker(anchorBlocker);
        EBVehicleInferredProvider *blockedAnchor = [[EBVehicleInferredProvider alloc]
            initWithPath:[anchorBlocker stringByAppendingPathComponent:@"state.json"]
            capacityWh:60000 efficiency:0.90];
        expect(![blockedAnchor setAnchorPercent:45 at:t0 source:EBSoCSourceManual],
               @"anchor reports persistence failure");
        expect(blockedAnchor.persistenceError != nil && !blockedAnchor.hasSOC,
               @"failed anchor rolls back and exposes persistence error");
        expect([NSFileManager.defaultManager removeItemAtPath:anchorBlocker error:nil],
               @"remove inferred anchor blocker");
        expect([blockedAnchor updateWithSamples:@[] now:t0]
               && blockedAnchor.persistenceError == nil && !blockedAnchor.hasSOC,
               @"failed anchor state retries cleanly without resurrecting an anchor");

        // Explicit inferred clear is transactional on delete failure.
        NSString *inferredClearDir = [dir stringByAppendingPathComponent:@"inferred-clear"];
        NSString *inferredClearPath = [inferredClearDir stringByAppendingPathComponent:@"state.json"];
        NSString *inferredClearBackup = [dir stringByAppendingPathComponent:@"inferred-clear.saved"];
        EBVehicleInferredProvider *inferredClear = [[EBVehicleInferredProvider alloc]
            initWithPath:inferredClearPath capacityWh:60000 efficiency:0.90];
        expect([inferredClear setAnchorPercent:46 at:t0 source:EBSoCSourceManual]
               && [inferredClear updateWithSamples:@[] now:t0]
               && inferredClear.hasSOC,
               @"seed inferred state for clear failure");
        expect(PermissionsAtPath(inferredClearPath) == 0600,
               @"inferred state file is private");
        expect(PermissionsAtPath(inferredClearDir) == 0700,
               @"inferred state directory is private");
        SabotageDirectory(inferredClearDir, inferredClearBackup);
        expect(![inferredClear clearAllState], @"inferred clear reports delete failure");
        expect(inferredClear.hasSOC && inferredClear.persistenceError != nil,
               @"failed inferred clear preserves estimate and exposes error");
        RestoreDirectory(inferredClearDir, inferredClearBackup);
        expect([inferredClear clearAllState] && !inferredClear.hasSOC
               && inferredClear.persistenceError == nil,
               @"inferred clear succeeds after storage recovers");

        // Unplug invalidation stays effective in memory when the tombstone write
        // fails, then the same sample retries it after storage is restored.
        NSString *inferredSafetyDir = [dir stringByAppendingPathComponent:@"inferred-safety"];
        NSString *inferredSafetyPath = [inferredSafetyDir stringByAppendingPathComponent:@"state.json"];
        NSString *inferredSafetyBackup = [dir stringByAppendingPathComponent:@"inferred-safety.saved"];
        EBVehicleInferredProvider *inferredSafety = [[EBVehicleInferredProvider alloc]
            initWithPath:inferredSafetyPath capacityWh:60000 efficiency:0.90];
        expect([inferredSafety setAnchorPercent:47 at:t0 source:EBSoCSourceManual]
               && [inferredSafety updateWithSamples:@[] now:t0]
               && inferredSafety.hasSOC,
               @"seed inferred state for tombstone failure");
        NSDate *inferredUnplug = [t0 dateByAddingTimeInterval:60];
        NSArray *unplugSample = @[Row(inferredUnplug, 0, EBChargerStateUnplugged)];
        SabotageDirectory(inferredSafetyDir, inferredSafetyBackup);
        expect(![inferredSafety updateWithSamples:unplugSample now:inferredUnplug],
               @"inferred tombstone reports persistence failure");
        expect(!inferredSafety.hasSOC && inferredSafety.socInvalidatedAt != nil,
               @"failed inferred tombstone still suppresses SoC in memory");
        expect(inferredSafety.persistenceError != nil,
               @"failed inferred tombstone exposes persistence error");
        RestoreDirectory(inferredSafetyDir, inferredSafetyBackup);
        expect([inferredSafety updateWithSamples:unplugSample now:inferredUnplug]
               && inferredSafety.persistenceError == nil,
               @"identical unplug sample retries tombstone after recovery");
        EBVehicleInferredProvider *inferredSafetyReload = [[EBVehicleInferredProvider alloc]
            initWithPath:inferredSafetyPath capacityWh:60000 efficiency:0.90];
        expect([inferredSafetyReload updateWithSamples:@[]
                                                   now:[inferredUnplug dateByAddingTimeInterval:86400]]
               && !inferredSafetyReload.hasSOC
               && inferredSafetyReload.socInvalidatedAt != nil,
               @"retried inferred tombstone remains durable after samples age out");

        // Non-finite capacity or efficiency disables inference rather than
        // feeding invalid arithmetic into the estimator.
        EBVehicleInferredProvider *nanCapacity = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"nan-capacity.json"]
            capacityWh:NAN efficiency:0.90];
        EBVehicleInferredProvider *infiniteCapacity = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"infinite-capacity.json"]
            capacityWh:INFINITY efficiency:0.90];
        EBVehicleInferredProvider *nanEfficiency = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"nan-efficiency.json"]
            capacityWh:60000 efficiency:NAN];
        EBVehicleInferredProvider *infiniteEfficiency = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"infinite-efficiency.json"]
            capacityWh:60000 efficiency:INFINITY];
        for (EBVehicleInferredProvider *invalidConfiguration in
             @[nanCapacity, infiniteCapacity, nanEfficiency, infiniteEfficiency]) {
            expect([invalidConfiguration setAnchorPercent:50
                                                        at:t0 source:EBSoCSourceManual],
                   @"finite anchor still persists for disabled configuration");
            expect([invalidConfiguration updateWithSamples:samples now:t0]
                   && !invalidConfiguration.available,
                   @"non-finite inference configuration is rejected");
        }

        // Zero capacity → inferred unavailable
        EBVehicleInferredProvider *nocap = [[EBVehicleInferredProvider alloc]
            initWithPath:[dir stringByAppendingPathComponent:@"nocap.json"]
            capacityWh:0 efficiency:0.90];
        [nocap setAnchorPercent:50 at:t0 source:EBSoCSourceManual];
        [nocap updateWithSamples:samples now:[t0 dateByAddingTimeInterval:60]];
        expect(!nocap.available, @"no capacity → unavailable");
        expect([nocap.statusLine containsString:@"EV_BATTERY_KWH"], @"hints config");

        id<EBVehicleProvider> r3 = EBResolveVehicle(@[obd, live, nocap, stub]);
        expect([r3 isKindOfClass:EBVehicleStubProvider.class], @"falls to stub");
        expect(![r3.dictionaryValue[@"estimated"] boolValue],
               @"stub dump explicitly not estimated");

        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        printf("ok: vehicle manual provider\n");
    }
    return 0;
}
