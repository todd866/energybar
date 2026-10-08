#import <Foundation/Foundation.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>
#import "sessions.h"

static int fails = 0;
static void expect(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        fails++;
    }
}

static NSDate *Date(NSString *value) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

static NSDictionary *Session(NSString *identifier, NSString *status,
                             NSString *start, NSString *end,
                             NSNumber *energy, NSString *reason,
                             NSNumber *meterStart, NSNumber *meterStop) {
    NSMutableDictionary *transaction = [NSMutableDictionary dictionary];
    if (start) transaction[@"startDate"] = start;
    if (end) transaction[@"endDate"] = end;
    if (reason) transaction[@"reason"] = reason;
    if (meterStart) transaction[@"meterStart"] = meterStart;
    if (meterStop) transaction[@"meterStop"] = meterStop;
    NSMutableDictionary *attributes = [@{
        @"sessionStatus": status ?: @"",
        @"transaction": transaction,
    } mutableCopy];
    if (start) attributes[@"chargingStarted"] = start;
    if (end) attributes[@"chargingStopped"] = end;
    if (energy) {
        attributes[@"totalPowerUsage"] = energy;
        attributes[@"totalEnergyUsage"] = @{ @"total": energy };
    }
    return @{ @"id": identifier, @"type": @"session", @"attributes": attributes };
}

int main(void) {
    @autoreleasepool {
        NSDate *fetched = Date(@"2026-08-08T06:00:00Z");
        NSDictionary *completed = Session(@"completed", @"Completed",
            @"2026-08-08T01:00:00Z", @"2026-08-08T02:00:00Z",
            @3600, @"EVDisconnected", @1000, @4600);
        NSDictionary *active = Session(@"active", @"Active",
            @"2026-08-08T03:00:00Z", nil, @900, nil, @4600, @5500);
        NSDictionary *invalidOpen = Session(@"invalid", @"Invalid",
            @"2026-08-08T04:00:00Z", nil, @100, nil, @5500, @5600);
        NSDictionary *disagree = Session(@"disagree", @"Completed",
            @"2026-08-08T04:00:00Z", @"2026-08-08T04:10:00Z",
            @1000, @"EVDisconnected", @5600, @5700);
        BOOL complete = YES;
        NSArray *parsed = EBParseEvnexSessions(@{ @"data": @[
            active, invalidOpen, disagree, completed
        ] }, fetched, 48 * 3600, &complete);
        expect(!complete, @"recent malformed row marks session snapshot incomplete");
        expect(parsed.count == 3, @"invalid open row is not treated as an active session");
        expect([parsed[0][EBSessionIDKey] isEqualToString:@"completed"], @"sessions sorted by start");
        expect(fabs([parsed[0][EBSessionEnergyWhKey] doubleValue] - 3600) < 0.1,
               @"physical meter delta parsed as Wh");
        expect([parsed[0][EBSessionDisconnectedAtKey] isEqual:Date(@"2026-08-08T02:00:00Z")],
               @"confirmed EV disconnect retained");
        expect([parsed[1][EBSessionIDKey] isEqualToString:@"active"] &&
               [parsed[1][EBSessionActiveKey] boolValue], @"explicit active row retained");
        expect([parsed[1][EBSessionChargeEndKey] isEqual:fetched],
               @"active register checkpoint ends at fetch time");
        expect(parsed[2][EBSessionEnergyWhKey] == nil,
               @"materially conflicting energy fields are not trusted");
        expect(parsed[2][EBSessionDisconnectedAtKey] != nil,
               @"disconnect evidence survives unusable energy total");

        NSDictionary *disconnectOnly = Session(@"disconnect-only", @"Completed",
            nil, @"2026-08-08T05:00:00Z", nil, @"EVDisconnected", nil, nil);
        BOOL disconnectOnlyComplete = YES;
        NSArray *disconnectOnlyParsed = EBParseEvnexSessions(
            @{ @"data": @[disconnectOnly] }, fetched, 48 * 3600,
            &disconnectOnlyComplete);
        expect(disconnectOnlyParsed.count == 1 &&
               disconnectOnlyParsed[0][EBSessionDisconnectedAtKey] != nil,
               @"disconnect-only row retains confirmed safety evidence");
        expect(!disconnectOnlyComplete,
               @"disconnect-only row cannot make an exact-zero energy claim");

        BOOL datelessComplete = YES;
        NSArray *dateless = EBParseEvnexSessions(@{ @"data": @[
            Session(@"dateless", @"Completed", nil, nil, nil, nil, nil, nil)
        ] }, fetched, 48 * 3600, &datelessComplete);
        expect(dateless.count == 0 && !datelessComplete,
               @"date-less row cannot be assumed outside the retained window");

        BOOL oldOpenComplete = YES;
        EBParseEvnexSessions(@{ @"data": @[
            Session(@"old-open", @"Completed", @"2026-08-01T00:00:00Z",
                    nil, nil, nil, nil, nil)
        ] }, fetched, 48 * 3600, &oldOpenComplete);
        expect(!oldOpenComplete,
               @"old start with no trustworthy end may still overlap retention");
        BOOL futureEndComplete = YES;
        EBParseEvnexSessions(@{ @"data": @[
            Session(@"future-end", @"Completed", @"2026-08-01T00:00:00Z",
                    @"2026-08-09T00:00:00Z", nil, nil, nil, nil)
        ] }, fetched, 48 * 3600, &futureEndComplete);
        expect(!futureEndComplete,
               @"future end cannot make an old-start row safely expired");
        BOOL oldInvalidComplete = NO;
        NSArray *oldInvalid = EBParseEvnexSessions(@{ @"data": @[
            Session(@"old-invalid", @"Invalid", @"2026-08-01T00:00:00Z",
                    nil, nil, nil, nil, nil)
        ] }, fetched, 48 * 3600, &oldInvalidComplete);
        expect(oldInvalid.count == 0 && oldInvalidComplete,
               @"explicitly invalid row wholly before retention does not poison current totals");

        BOOL duplicateComplete = YES;
        NSArray *duplicateParsed = EBParseEvnexSessions(
            @{ @"data": @[completed, completed] }, fetched, 48 * 3600,
            &duplicateComplete);
        expect(duplicateParsed.count == 1 && !duplicateComplete,
               @"duplicate response IDs cannot retain complete/exact provenance");

        NSDictionary *aggregateOnly = Session(@"aggregate-only", @"Completed",
            @"2026-08-08T04:00:00Z", @"2026-08-08T04:30:00Z",
            @500, nil, nil, nil);
        NSArray *aggregateOnlyParsed = EBParseEvnexSessions(
            @{ @"data": @[aggregateOnly] }, fetched, 48 * 3600, nil);
        expect(aggregateOnlyParsed.count == 1 &&
               aggregateOnlyParsed[0][EBSessionEnergyWhKey] == nil,
               @"unitless aggregate fields cannot replace a physical register delta");
        NSDictionary *registerOnly = Session(@"register-only", @"Completed",
            @"2026-08-08T04:00:00Z", @"2026-08-08T04:30:00Z",
            nil, nil, @1000, @1500);
        NSArray *registerOnlyParsed = EBParseEvnexSessions(
            @{ @"data": @[registerOnly] }, fetched, 48 * 3600, nil);
        expect(registerOnlyParsed.count == 1 &&
               registerOnlyParsed[0][EBSessionEnergyWhKey] == nil,
               @"register delta requires an agreeing vendor aggregate contract");

        EBSessionEnergySummary exact = EBSessionEnergyInWindow(parsed,
            Date(@"2026-08-08T00:00:00Z"), fetched);
        expect(!exact.exact && exact.sessionCount == 2 && fabs(exact.energyWh - 4500) < 0.1,
               @"known sessions sum exactly while missing energy marks window partial");
        EBSessionEnergySummary first = EBSessionEnergyInWindow(@[parsed[0]],
            Date(@"2026-08-08T00:00:00Z"), Date(@"2026-08-08T03:00:00Z"));
        expect(first.exact && first.sessionCount == 1 && fabs(first.energyWh - 3600) < 0.1,
               @"fully contained session yields exact energy");
        EBSessionEnergySummary crossing = EBSessionEnergyInWindow(@[parsed[0]],
            Date(@"2026-08-08T01:30:00Z"), Date(@"2026-08-08T03:00:00Z"));
        expect(!crossing.exact && crossing.sessionCount == 0 && crossing.energyWh == 0,
               @"session crossing window boundary is not proportionally invented");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"energybar-sessions-%@", NSUUID.UUID.UUIDString]];
        NSString *path = [root stringByAppendingPathComponent:@"cache/sessions.json"];
        EBSessionHistory *history = [EBSessionHistory new];
        history.sessions = parsed;
        history.fetchedAt = fetched;
        history.sourceID = @"charger-test";
        history.current = YES;
        history.complete = complete;
        NSError *saveError = nil;
        expect(EBSessionCacheSave(path, history, &saveError),
               [NSString stringWithFormat:@"cache save: %@", saveError]);
        struct stat fileStat = {0};
        expect(stat(path.fileSystemRepresentation, &fileStat) == 0 &&
               (fileStat.st_mode & 0777) == 0600, @"session cache is private");
        EBSessionHistory *loaded = EBSessionCacheLoad(path, @"charger-test",
                                                      365 * 24 * 3600, nil);
        expect(loaded.sessions.count == parsed.count && [loaded.fetchedAt isEqual:fetched],
               @"cache round trip preserves sanitized history");
        expect(!loaded.current, @"disk cache is explicitly stale until refreshed");
        expect(!loaded.complete, @"cache preserves endpoint completeness provenance");

        NSString *malformedPath = [root stringByAppendingPathComponent:@"cache/malformed.json"];
        NSDictionary *malformedCache = @{
            @"schemaVersion": @1,
            @"sourceID": @"charger-test",
            @"complete": @YES,
            @"fetchedAt": @"2026-08-08T06:00:00Z",
            @"sessions": @[ @{ @"id": @"silently-incomplete" } ],
        };
        NSData *malformedData = [NSJSONSerialization dataWithJSONObject:malformedCache
                                                                 options:0 error:nil];
        expect([malformedData writeToFile:malformedPath atomically:YES],
               @"malformed cache fixture writes");
        NSError *malformedError = nil;
        EBSessionHistory *malformedLoaded = EBSessionCacheLoad(
            malformedPath, @"charger-test", 365 * 24 * 3600, &malformedError);
        expect(!malformedLoaded.fetchedAt && malformedError != nil,
               @"malformed cached rows cannot retain complete/exact provenance");

        NSString *duplicatePath = [root stringByAppendingPathComponent:@"cache/duplicate.json"];
        NSMutableDictionary *duplicateCache = [malformedCache mutableCopy];
        duplicateCache[@"sessions"] = @[
            @{ @"id": @"same", @"chargeStart": @"2026-08-08T01:00:00Z",
               @"chargeEnd": @"2026-08-08T02:00:00Z", @"energyWh": @10 },
            @{ @"id": @"same", @"chargeStart": @"2026-08-08T03:00:00Z",
               @"chargeEnd": @"2026-08-08T04:00:00Z", @"energyWh": @20 },
        ];
        NSData *duplicateData = [NSJSONSerialization dataWithJSONObject:duplicateCache
                                                                 options:0 error:nil];
        expect([duplicateData writeToFile:duplicatePath atomically:YES],
               @"duplicate cache fixture writes");
        NSError *duplicateError = nil;
        EBSessionHistory *duplicateLoaded = EBSessionCacheLoad(
            duplicatePath, @"charger-test", 365 * 24 * 3600, &duplicateError);
        expect(!duplicateLoaded.fetchedAt && duplicateError != nil,
               @"duplicate cached IDs cannot be summed twice as exact energy");
        NSError *wrongSourceError = nil;
        EBSessionHistory *wrongSource = EBSessionCacheLoad(path, @"another-charger",
                                                           365 * 24 * 3600,
                                                           &wrongSourceError);
        expect(wrongSource.sessions.count == 0 && wrongSourceError != nil,
               @"cache cannot leak totals across a changed charge point");
        NSData *before = [NSData dataWithContentsOfFile:path];
        expect(EBSessionCacheSave(path, history, nil), @"repeated complete snapshot save succeeds");
        NSData *after = [NSData dataWithContentsOfFile:path];
        expect([before isEqual:after], @"repeated save is byte-for-byte idempotent");

        chmod(path.fileSystemRepresentation, 0644);
        expect(EBSessionCacheSecureExistingFile(path), @"existing cache permissions migrated");
        expect(stat(path.fileSystemRepresentation, &fileStat) == 0 &&
               (fileStat.st_mode & 0777) == 0600, @"migration sets cache to 0600");

        NSString *badParent = [root stringByAppendingPathComponent:@"not-a-directory"];
        [@"x" writeToFile:badParent atomically:YES encoding:NSUTF8StringEncoding error:nil];
        expect(!EBSessionCacheSave([badParent stringByAppendingPathComponent:@"sessions.json"],
                                   history, nil), @"cache write fails safely under a file parent");

        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    }
    if (fails) return 1;
    printf("ok\n");
    return 0;
}
