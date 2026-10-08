#import <Foundation/Foundation.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

#import "fronius_archive.h"

#define expect(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); \
        exit(1); \
    } \
} while (0)

static NSDate *Date(NSString *string) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:string];
    if (date) return date;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:string];
}

static NSMutableDictionary *MutableJSONCopy(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingMutableContainers
                                             error:nil];
}

static NSDictionary *ArchiveResponse(void) {
    return @{
        @"Head": @{
            @"RequestArguments": @{
                @"Scope": @"System",
                @"SeriesType": @"Detail",
                @"Channel": @[@"TimeSpanInSec", @"EnergyReal_WAC_Sum_Produced",
                               @"PowerReal_PAC_Sum"],
            },
            @"Status": @{@"Code": @0, @"Reason": @"", @"UserMessage": @""},
            @"Timestamp": @"2026-01-15T23:59:59Z",
        },
        @"Body": @{
            @"Data": @{
                @"meter:123": @{
                    @"Start": @"2026-01-15T00:00:00Z",
                    @"End": @"2026-01-15T23:59:59Z",
                    @"Data": @{@"EnergyReal_WAC_Plus_Absolute": @{
                        @"Unit": @"Wh", @"Values": @{@"0": @1234},
                    }},
                },
                @"inverter/1": @{
                    @"DeviceType": @999,
                    @"Start": @"2026-01-15T00:00:00Z",
                    @"End": @"2026-01-15T23:59:59Z",
                    @"Data": @{
                        @"EnergyReal_WAC_Sum_Produced": @{
                            @"Unit": @"Wh",
                            // Deliberately lexical and cumulative-looking: these
                            // are exact interval energies and must sum to 210 Wh.
                            @"Values": @{
                                @"0": @100,
                                @"1200": @110,
                                @"300": NSNull.null,
                                @"600": @0,
                            },
                        },
                        @"PowerReal_PAC_Sum": @{
                            @"Unit": @"W",
                            @"Values": @{@"0": @1200, @"1200": @1320, @"600": @0},
                        },
                        @"TimeSpanInSec": @{
                            @"Unit": @"sec",
                            @"Values": @{
                                @"0": @300,
                                @"1200": @300,
                                @"300": @300,
                                @"600": @300,
                            },
                        },
                    },
                },
            },
        },
    };
}

static NSMutableDictionary *MutableInverter(NSMutableDictionary *response) {
    return response[@"Body"][@"Data"][@"inverter/1"];
}

static EBFroniusPVInterval *Interval(NSString *device, NSDate *anchor,
                                     double span, double energy) {
    return [[EBFroniusPVInterval alloc] initWithDeviceID:device
                                              deviceType:@999
                                                  anchor:anchor
                                             spanSeconds:span
                                                energyWh:energy];
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSArray<EBFroniusPVInterval *> *parsed =
            EBFroniusArchiveParsePVIntervals(ArchiveResponse(), &error);
        expect(parsed != nil && error == nil, @"valid Detail archive parses");
        expect(parsed.count == 3, @"explicit null energy is omitted, zero energy is retained");
        expect([parsed[0].deviceID isEqualToString:@"inverter/1"], @"only inverter PV is parsed");
        expect(parsed[0].deviceType.integerValue == 999, @"synthetic device type is preserved");
        expect([parsed[0].anchor isEqualToDate:Date(@"2026-01-15T00:00:00Z")],
               @"offset zero uses the device Start anchor");
        expect([parsed[1].anchor isEqualToDate:Date(@"2026-01-15T00:10:00Z")],
               @"numeric 600-second offset sorts before 1200");
        expect([parsed[2].anchor isEqualToDate:Date(@"2026-01-15T00:20:00Z")],
               @"numeric 1200-second offset sorts last");

        EBFroniusPVArchiveSummary all = EBFroniusArchiveSummarizePV(
            parsed, [parsed.firstObject.anchor dateByAddingTimeInterval:-300],
            [parsed.lastObject.anchor dateByAddingTimeInterval:300]);
        expect(all.hasData && all.intervalCount == 3 && all.deviceCount == 1,
               @"summary distinguishes known data and counts the device");
        expect(fabs(all.energyWh - 210) < 0.0001,
               @"archive energies are summed directly, never differenced");
        expect(fabs(all.recordedDeviceSeconds - 900) < 0.0001,
               @"summary preserves exact logger spans");

        EBFroniusPVArchiveSummary halfOpen = EBFroniusArchiveSummarizePV(
            parsed, parsed.firstObject.anchor, parsed.lastObject.anchor);
        expect(halfOpen.intervalCount == 1 && fabs(halfOpen.energyWh) < 0.0001,
               @"summary omits intervals that could cross either window boundary");
        EBFroniusPVArchiveSummary empty = EBFroniusArchiveSummarizePV(
            parsed, parsed.lastObject.anchor, parsed.lastObject.anchor);
        expect(!empty.hasData && empty.energyWh == 0,
               @"empty window is unavailable rather than an exact measured zero");

        NSMutableDictionary *daily = MutableJSONCopy(ArchiveResponse());
        daily[@"Head"][@"RequestArguments"][@"SeriesType"] = @"DailySum";
        expect(EBFroniusArchiveParsePVIntervals(daily, &error) == nil &&
               error.code == EBFroniusArchiveErrorInvalidResponse,
               @"DailySum is rejected");

        NSMutableDictionary *nonzero = MutableJSONCopy(ArchiveResponse());
        nonzero[@"Head"][@"Status"][@"Code"] = @11;
        expect(EBFroniusArchiveParsePVIntervals(nonzero, &error) == nil &&
               error.code == EBFroniusArchiveErrorUnsupported,
               @"device status NotSupported is stable unsupported evidence");

        NSMutableDictionary *booleanStatus = MutableJSONCopy(ArchiveResponse());
        booleanStatus[@"Head"][@"Status"][@"Code"] = @YES;
        expect(EBFroniusArchiveParsePVIntervals(booleanStatus, &error) == nil,
               @"boolean status cannot masquerade as numeric zero");

        NSMutableDictionary *wrongUnit = MutableJSONCopy(ArchiveResponse());
        MutableInverter(wrongUnit)[@"Data"][@"EnergyReal_WAC_Sum_Produced"][@"Unit"] = @"kWh";
        expect(EBFroniusArchiveParsePVIntervals(wrongUnit, &error) == nil,
               @"unexpected energy unit is rejected");

        NSMutableDictionary *missingSpan = MutableJSONCopy(ArchiveResponse());
        [MutableInverter(missingSpan)[@"Data"][@"TimeSpanInSec"][@"Values"]
            removeObjectForKey:@"1200"];
        expect(EBFroniusArchiveParsePVIntervals(missingSpan, &error) == nil &&
               error.code == EBFroniusArchiveErrorInvalidRecord,
               @"known energy without a matching exact span fails closed");

        NSMutableDictionary *badOffset = MutableJSONCopy(ArchiveResponse());
        NSMutableDictionary *badEnergyValues =
            MutableInverter(badOffset)[@"Data"][@"EnergyReal_WAC_Sum_Produced"][@"Values"];
        badEnergyValues[@"1e3"] = @1;
        MutableInverter(badOffset)[@"Data"][@"TimeSpanInSec"][@"Values"][@"1e3"] = @300;
        expect(EBFroniusArchiveParsePVIntervals(badOffset, &error) == nil,
               @"non-decimal offset is rejected");

        NSMutableDictionary *conflict = MutableJSONCopy(ArchiveResponse());
        MutableInverter(conflict)[@"Data"][@"EnergyReal_WAC_Sum_Produced"][@"Values"][
            @"0600"] = @1;
        MutableInverter(conflict)[@"Data"][@"TimeSpanInSec"][@"Values"][
            @"0600"] = @300;
        expect(EBFroniusArchiveParsePVIntervals(conflict, &error) == nil,
               @"conflicting aliases for one device anchor are rejected");

        NSMutableDictionary *gen24 = MutableJSONCopy(ArchiveResponse());
        MutableInverter(gen24)[@"DeviceType"] = @1;
        expect(EBFroniusArchiveParsePVIntervals(gen24, &error) == nil &&
               error.code == EBFroniusArchiveErrorUnsupported,
               @"GEN24/Tauro/Verto device type is explicitly unsupported");

        NSMutableDictionary *emptyResponse = MutableJSONCopy(ArchiveResponse());
        emptyResponse[@"Body"][@"Data"] = @{};
        NSArray *none = EBFroniusArchiveParsePVIntervals(emptyResponse, &error);
        expect(none != nil && none.count == 0 && error == nil,
               @"valid empty response stays distinct from parse failure");

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"energybar-fronius-archive-%d", getpid()]];
        [fm removeItemAtPath:root error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"private/pv.json"];
        NSString *source = @"fronius-source-a";
        NSDate *now = Date(@"2026-08-09T12:00:00Z");
        NSDate *cutoff = [now dateByAddingTimeInterval:-EBFroniusArchiveRetentionSeconds];
        EBFroniusPVInterval *atCutoff = Interval(@"inverter/1", cutoff, 300, 10);
        EBFroniusPVInterval *tooOld = Interval(
            @"inverter/1", [cutoff dateByAddingTimeInterval:-1], 300, 99);
        EBFroniusPVInterval *fresh = Interval(
            @"inverter/1", [now dateByAddingTimeInterval:-3600], 297, 20);
        NSArray<EBFroniusPVInterval *> *merged = EBFroniusArchiveMergePVCache(
            path, source, @[fresh, tooOld, atCutoff], now, &error);
        expect(merged.count == 2 && error == nil, @"merge applies exact 48-hour retention");
        expect([merged.firstObject.anchor isEqualToDate:cutoff],
               @"record exactly on retention cutoff is kept and rows are sorted");

        NSDictionary *dirAttributes = [fm attributesOfItemAtPath:
            path.stringByDeletingLastPathComponent error:nil];
        NSDictionary *fileAttributes = [fm attributesOfItemAtPath:path error:nil];
        expect(([dirAttributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700,
               @"cache directory is private");
        expect(([fileAttributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600,
               @"cache file is private");

        NSData *firstBytes = [NSData dataWithContentsOfFile:path];
        NSArray<EBFroniusPVInterval *> *again = EBFroniusArchiveMergePVCache(
            path, source, @[atCutoff, fresh], now, &error);
        NSData *secondBytes = [NSData dataWithContentsOfFile:path];
        expect(again.count == 2 && [firstBytes isEqualToData:secondBytes],
               @"repeating the same merge is byte-stable and idempotent");

        EBFroniusPVInterval *corrected = Interval(
            @"inverter/1", fresh.anchor, fresh.spanSeconds, 25);
        NSArray<EBFroniusPVInterval *> *replaced = EBFroniusArchiveMergePVCache(
            path, source, @[corrected], now, &error);
        expect(replaced.count == 2 && fabs(replaced.lastObject.energyWh - 25) < 0.0001,
               @"later fetch replaces the same device and anchor");

        NSArray<EBFroniusPVInterval *> *loaded =
            EBFroniusArchiveLoadPVCache(path, source, now, &error);
        expect(loaded.count == 2 && error == nil, @"private cache round-trips");
        NSData *beforeWrongSource = [NSData dataWithContentsOfFile:path];
        expect(EBFroniusArchiveLoadPVCache(path, @"fronius-source-b", now, &error) == nil &&
               error.code == EBFroniusArchiveErrorSourceMismatch,
               @"cache cannot be reused for a different Fronius source");
        expect([[NSData dataWithContentsOfFile:path] isEqualToData:beforeWrongSource],
               @"source mismatch leaves cache bytes untouched");

        NSString *changedSourcePath = [root stringByAppendingPathComponent:
            @"private/changed-source.json"];
        expect([beforeWrongSource writeToFile:changedSourcePath atomically:YES],
               @"changed-source fixture writes");
        NSArray *changedSource = EBFroniusArchiveMergePVCache(
            changedSourcePath, @"fronius-source-b", @[fresh], now, &error);
        expect(changedSource.count == 1 && error == nil,
               @"a configured source change starts a fresh canonical cache");
        NSArray *changedLoaded = EBFroniusArchiveLoadPVCache(
            changedSourcePath, @"fronius-source-b", now, &error);
        expect(changedLoaded.count == 1 && error == nil,
               @"fresh source cache loads under its own identity");
        NSArray<NSString *> *privateFiles = [fm contentsOfDirectoryAtPath:
            changedSourcePath.stringByDeletingLastPathComponent error:nil];
        NSPredicate *preservedName = [NSPredicate predicateWithBlock:
            ^BOOL(NSString *name, NSDictionary *bindings) {
                (void)bindings;
                return [name hasPrefix:@"changed-source.json.source-mismatch-"];
            }];
        NSArray<NSString *> *preserved = [privateFiles filteredArrayUsingPredicate:preservedName];
        expect(preserved.count == 1 &&
               [[[NSData dataWithContentsOfFile:[changedSourcePath.stringByDeletingLastPathComponent
                    stringByAppendingPathComponent:preserved.firstObject]] copy]
                    isEqualToData:beforeWrongSource],
               @"source change preserves the previous private cache bytes");

        EBFroniusPVInterval *future = Interval(
            @"inverter/1", [now dateByAddingTimeInterval:1], 300, 1);
        NSData *beforeFuture = [NSData dataWithContentsOfFile:path];
        expect(EBFroniusArchiveMergePVCache(path, source, @[future], now, &error) == nil &&
               error.code == EBFroniusArchiveErrorInvalidRecord,
               @"future interval is rejected");
        expect([[NSData dataWithContentsOfFile:path] isEqualToData:beforeFuture],
               @"rejected future merge preserves cache");

        EBFroniusPVInterval *conflictA = Interval(
            @"inverter/2", [now dateByAddingTimeInterval:-1800], 300, 1);
        EBFroniusPVInterval *conflictB = Interval(
            @"inverter/2", conflictA.anchor, 300, 2);
        expect(EBFroniusArchiveMergePVCache(
            path, source, @[conflictA, conflictB], now, &error) == nil,
            @"conflicting duplicates inside one merge fail closed");

        NSString *corrupt = [root stringByAppendingPathComponent:@"corrupt.json"];
        NSData *corruptBytes = [@"not json" dataUsingEncoding:NSUTF8StringEncoding];
        expect([corruptBytes writeToFile:corrupt atomically:YES], @"corrupt fixture writes");
        expect(EBFroniusArchiveMergePVCache(
            corrupt, source, @[fresh], now, &error) == nil &&
            error.code == EBFroniusArchiveErrorCorruptCache,
            @"malformed existing cache blocks merge");
        expect([[NSData dataWithContentsOfFile:corrupt] isEqualToData:corruptBytes],
               @"malformed existing cache is never overwritten");

        NSString *missing = [root stringByAppendingPathComponent:@"missing.json"];
        NSArray *missingRows = EBFroniusArchiveLoadPVCache(missing, source, now, &error);
        expect(missingRows.count == 0 && error == nil, @"missing cache loads as empty");

        [fm removeItemAtPath:root error:nil];
        puts("ok: fronius archive");
    }
    return 0;
}
