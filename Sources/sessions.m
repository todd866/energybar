#import "sessions.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const EBSessionIDKey = @"id";
NSString * const EBSessionChargeStartKey = @"chargeStart";
NSString * const EBSessionChargeEndKey = @"chargeEnd";
NSString * const EBSessionEnergyWhKey = @"energyWh";
NSString * const EBSessionDisconnectedAtKey = @"disconnectedAt";
NSString * const EBSessionActiveKey = @"active";

@implementation EBSessionHistory
- (instancetype)init {
    self = [super init];
    if (self) { _sessions = @[]; _complete = NO; }
    return self;
}
@end

static NSError *EBSessionError(NSInteger code, NSString *message, NSString *path) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message ?: @"Session history error"}
                                  mutableCopy];
    if (path.length) info[NSFilePathErrorKey] = path;
    return [NSError errorWithDomain:@"Energybar.SessionHistory" code:code userInfo:info];
}

static NSISO8601DateFormatter *EBSessionISO(BOOL fractions) {
    static NSISO8601DateFormatter *withFractions;
    static NSISO8601DateFormatter *withoutFractions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        withFractions = [NSISO8601DateFormatter new];
        withFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                      NSISO8601DateFormatWithFractionalSeconds;
        withoutFractions = [NSISO8601DateFormatter new];
        withoutFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return fractions ? withFractions : withoutFractions;
}

static NSDate *EBSessionDate(id value) {
    if ([value isKindOfClass:NSDate.class]) return value;
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    return [EBSessionISO(YES) dateFromString:value] ?: [EBSessionISO(NO) dateFromString:value];
}

static NSString *EBSessionDateString(NSDate *date) {
    return date ? [EBSessionISO(YES) stringFromDate:date] : nil;
}

static NSNumber *EBSessionFiniteNonnegative(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 ? @(number) : nil;
}

static NSDictionary *EBSessionDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL EBSessionEnergyCandidatesAgree(NSArray<NSNumber *> *candidates) {
    if (candidates.count < 2) return YES;
    double low = DBL_MAX, high = -DBL_MAX;
    for (NSNumber *candidate in candidates) {
        low = fmin(low, candidate.doubleValue);
        high = fmax(high, candidate.doubleValue);
    }
    // Registers are integer Wh in current Evnex responses, while aggregate
    // fields may be rounded. Reject material disagreement rather than guessing.
    double tolerance = fmax(10.0, high * 0.01);
    return high - low <= tolerance;
}

static NSNumber *EBSessionEnergy(NSDictionary *attributes) {
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    NSNumber *powerUsage = EBSessionFiniteNonnegative(attributes[@"totalPowerUsage"]);
    if (powerUsage) [candidates addObject:powerUsage];
    NSNumber *usageTotal = EBSessionFiniteNonnegative(
        EBSessionDictionary(attributes[@"totalEnergyUsage"])[@"total"]);
    if (usageTotal) [candidates addObject:usageTotal];
    NSDictionary *transaction = EBSessionDictionary(attributes[@"transaction"]);
    NSNumber *meterStart = EBSessionFiniteNonnegative(transaction[@"meterStart"]);
    NSNumber *meterStop = EBSessionFiniteNonnegative(transaction[@"meterStop"]);
    // Evnex's aggregate fields carry no unit metadata. OCPP 1.6 defines the
    // Start/StopTransaction meter registers as integer Wh; require that delta
    // and at least one vendor aggregate to agree before treating the vendor's
    // nested transaction as that contract. See OCA Signed Meter Values §3.1.
    // https://openchargealliance.org/wp-content/uploads/2025/02/signed_meter_values-v10.pdf
    if (!meterStart || !meterStop || meterStop.doubleValue < meterStart.doubleValue)
        return nil;
    if (!candidates.count) return nil;
    NSNumber *registerDelta = @(meterStop.doubleValue - meterStart.doubleValue);
    [candidates addObject:registerDelta];
    return EBSessionEnergyCandidatesAgree(candidates) ? registerDelta : nil;
}

static BOOL EBSessionStringEquals(id value, NSString *expected) {
    return [value isKindOfClass:NSString.class] &&
           [(NSString *)value caseInsensitiveCompare:expected] == NSOrderedSame;
}

NSArray<NSDictionary *> *EBParseEvnexSessions(NSDictionary *document,
                                               NSDate *fetchedAt,
                                               NSTimeInterval maxAgeSeconds,
                                               BOOL *complete) {
    if (complete) *complete = NO;
    if (![document isKindOfClass:NSDictionary.class] || !fetchedAt) return @[];
    NSArray *data = [document[@"data"] isKindOfClass:NSArray.class] ? document[@"data"] : nil;
    if (!data) return @[];
    BOOL allUsable = YES;
    NSDate *cutoff = [fetchedAt dateByAddingTimeInterval:-fmax(0, maxAgeSeconds)];
    NSDate *futureLimit = [fetchedAt dateByAddingTimeInterval:5 * 60];
    NSMutableDictionary<NSString *, NSDictionary *> *byID = [NSMutableDictionary dictionary];

    for (id itemValue in data) {
        NSDictionary *item = EBSessionDictionary(itemValue);
        NSString *identifier = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : nil;
        NSDictionary *attributes = EBSessionDictionary(item[@"attributes"]);
        if (!identifier.length || !attributes) { allUsable = NO; continue; }

        NSString *status = [attributes[@"sessionStatus"] isKindOfClass:NSString.class]
            ? attributes[@"sessionStatus"] : nil;
        BOOL active = EBSessionStringEquals(status, @"Active");
        // Some invalid rows have no end date. Only an explicit Active status may
        // use fetchedAt as the rolling register checkpoint.
        NSDate *chargeStart = EBSessionDate(attributes[@"chargingStarted"]);
        NSDictionary *transaction = EBSessionDictionary(attributes[@"transaction"]);
        if (!chargeStart) chargeStart = EBSessionDate(transaction[@"startDate"]);
        if (!chargeStart) chargeStart = EBSessionDate(attributes[@"startDate"]);
        NSDate *chargeEnd = EBSessionDate(attributes[@"chargingStopped"]);
        if (!chargeEnd) chargeEnd = EBSessionDate(transaction[@"endDate"]);
        if (!chargeEnd) chargeEnd = EBSessionDate(attributes[@"endDate"]);
        if (!chargeEnd && active) chargeEnd = fetchedAt;

        NSDate *sessionEnd = EBSessionDate(transaction[@"endDate"]);
        if (!sessionEnd) sessionEnd = EBSessionDate(attributes[@"endDate"]);
        if (!sessionEnd) sessionEnd = EBSessionDate(attributes[@"chargingStopped"]);

        BOOL validInterval = chargeStart && chargeEnd &&
            [chargeStart compare:chargeEnd] != NSOrderedDescending &&
            [chargeStart compare:futureLimit] != NSOrderedDescending &&
            [chargeEnd compare:futureLimit] != NSOrderedDescending;
        BOOL inRetention = validInterval && [chargeEnd compare:cutoff] != NSOrderedAscending;

        BOOL disconnected = EBSessionStringEquals(transaction[@"reason"], @"EVDisconnected");
        NSDate *disconnectedAt = disconnected ? sessionEnd : nil;
        if (disconnectedAt && ([disconnectedAt compare:cutoff] == NSOrderedAscending ||
                               [disconnectedAt compare:futureLimit] == NSOrderedDescending))
            disconnectedAt = nil;

        NSNumber *energy = validInterval ? EBSessionEnergy(attributes) : nil;
        // A confirmed disconnect remains valuable safety evidence even when its
        // charging interval is malformed. It cannot, however, prove that the
        // retained window contains zero unaccounted energy.
        if (disconnectedAt && !inRetention) allUsable = NO;
        if (!inRetention && !disconnectedAt) {
            // Only a well-formed interval ending before retention proves this
            // row cannot hide energy inside the requested window. An old start
            // with a missing/future/invalid end is still potentially active.
            BOOL explicitlyInvalid = EBSessionStringEquals(status, @"Invalid");
            BOOL safelyExpired = (validInterval &&
                [chargeEnd compare:cutoff] == NSOrderedAscending) ||
                (explicitlyInvalid && chargeStart &&
                 [chargeStart compare:cutoff] == NSOrderedAscending);
            if (!safelyExpired) allUsable = NO;
            continue;
        }
        NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:identifier
                                                                          forKey:EBSessionIDKey];
        if (inRetention) {
            record[EBSessionChargeStartKey] = chargeStart;
            record[EBSessionChargeEndKey] = chargeEnd;
            record[EBSessionActiveKey] = @(active);
            if (energy) record[EBSessionEnergyWhKey] = energy;
        }
        if (disconnectedAt) record[EBSessionDisconnectedAtKey] = disconnectedAt;
        if (byID[identifier]) allUsable = NO;
        byID[identifier] = record;
    }

    NSArray *records = byID.allValues;
    NSArray *sorted = [records sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                    NSDictionary *b) {
        NSDate *aDate = a[EBSessionChargeStartKey] ?: a[EBSessionDisconnectedAtKey];
        NSDate *bDate = b[EBSessionChargeStartKey] ?: b[EBSessionDisconnectedAtKey];
        NSComparisonResult byDate = [aDate compare:bDate];
        if (byDate != NSOrderedSame) return byDate;
        return [a[EBSessionIDKey] compare:b[EBSessionIDKey]];
    }];
    if (complete) *complete = allUsable;
    return sorted;
}

static BOOL EBSessionEnsureDirectory(NSString *path, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    BOOL exists = [manager fileExistsAtPath:directory isDirectory:&isDirectory];
    if (exists && !isDirectory) {
        if (error) *error = EBSessionError(10, @"Session cache parent is not a directory", directory);
        return NO;
    }
    if (exists) return YES;
    NSError *directoryError = nil;
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                              attributes:@{NSFilePosixPermissions: @0700}
                                   error:&directoryError] ||
        ![manager setAttributes:@{NSFilePosixPermissions: @0700}
                   ofItemAtPath:directory error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }
    return YES;
}

static BOOL EBSessionAtomicWrite(NSString *path, NSData *data, NSError **error) {
    if (!EBSessionEnsureDirectory(path, error)) return NO;
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    NSString *name = path.lastPathComponent.length ? path.lastPathComponent : @"sessions.json";
    NSString *templatePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.XXXXXX", name]];
    char *temporary = strdup(templatePath.fileSystemRepresentation);
    if (!temporary) {
        if (error) *error = EBSessionError(11, @"Could not allocate session cache path", path);
        return NO;
    }
    int descriptor = mkstemp(temporary);
    if (descriptor < 0) {
        if (error) *error = EBSessionError(errno, @"Could not create session cache", path);
        free(temporary);
        return NO;
    }
    BOOL ok = fchmod(descriptor, S_IRUSR | S_IWUSR) == 0;
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        cursor += count;
        remaining -= (NSUInteger)count;
    }
    if (ok && fsync(descriptor) != 0) ok = NO;
    if (close(descriptor) != 0) ok = NO;
    if (!ok || rename(temporary, path.fileSystemRepresentation) != 0) {
        int saved = errno;
        unlink(temporary);
        if (error) *error = EBSessionError(saved, @"Could not save session history", path);
        free(temporary);
        return NO;
    }
    free(temporary);
    return YES;
}

BOOL EBSessionCacheSave(NSString *path, EBSessionHistory *history, NSError **error) {
    if (!path.length || !history.fetchedAt || !history.sourceID.length ||
        ![history.sessions isKindOfClass:NSArray.class]) {
        if (error) *error = EBSessionError(12, @"Invalid session cache input", path);
        return NO;
    }
    NSMutableArray *serialized = [NSMutableArray arrayWithCapacity:history.sessions.count];
    for (NSDictionary *record in history.sessions) {
        NSString *identifier = [record[EBSessionIDKey] isKindOfClass:NSString.class]
            ? record[EBSessionIDKey] : nil;
        if (!identifier.length) continue;
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:identifier
                                                                       forKey:EBSessionIDKey];
        NSDate *start = EBSessionDate(record[EBSessionChargeStartKey]);
        NSDate *end = EBSessionDate(record[EBSessionChargeEndKey]);
        NSDate *disconnected = EBSessionDate(record[EBSessionDisconnectedAtKey]);
        NSNumber *energy = EBSessionFiniteNonnegative(record[EBSessionEnergyWhKey]);
        if (start && end && [start compare:end] != NSOrderedDescending) {
            row[EBSessionChargeStartKey] = EBSessionDateString(start);
            row[EBSessionChargeEndKey] = EBSessionDateString(end);
            row[EBSessionActiveKey] = @([record[EBSessionActiveKey] boolValue]);
            if (energy) row[EBSessionEnergyWhKey] = energy;
        }
        if (disconnected) row[EBSessionDisconnectedAtKey] = EBSessionDateString(disconnected);
        if (row.count > 1) [serialized addObject:row];
    }
    NSDictionary *root = @{ @"schemaVersion": @1,
                            @"sourceID": history.sourceID,
                            @"complete": @(history.complete),
                            @"fetchedAt": EBSessionDateString(history.fetchedAt),
                            @"sessions": serialized };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!data) {
        if (error) *error = jsonError;
        return NO;
    }
    return EBSessionAtomicWrite(path, data, error);
}

EBSessionHistory *EBSessionCacheLoad(NSString *path, NSString *sourceID,
                                     NSTimeInterval maxAgeSeconds,
                                     NSError **error) {
    EBSessionHistory *history = [EBSessionHistory new];
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return history;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (error) *error = readError;
        return history;
    }
    NSError *jsonError = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![decoded isKindOfClass:NSDictionary.class]) {
        if (error) *error = jsonError ?: EBSessionError(13, @"Session cache is not a JSON object", path);
        return history;
    }
    NSDictionary *root = decoded;
    NSNumber *schemaVersion = [root[@"schemaVersion"] isKindOfClass:NSNumber.class]
        ? root[@"schemaVersion"] : nil;
    NSString *cachedSource = [root[@"sourceID"] isKindOfClass:NSString.class]
        ? root[@"sourceID"] : nil;
    if (!schemaVersion || schemaVersion.integerValue != 1) {
        if (error) *error = EBSessionError(16,
            @"Session cache has an unsupported schema", path);
        return history;
    }
    if (!sourceID.length || ![cachedSource isEqualToString:sourceID]) {
        if (error) *error = EBSessionError(15,
            @"Session cache belongs to a different charge point", path);
        return history;
    }
    NSDate *fetchedAt = EBSessionDate(root[@"fetchedAt"]);
    NSArray *rows = [root[@"sessions"] isKindOfClass:NSArray.class] ? root[@"sessions"] : nil;
    if (!fetchedAt || !rows) {
        if (error) *error = EBSessionError(14, @"Session cache is missing required fields", path);
        return history;
    }
    NSDate *cutoff = [[NSDate date] dateByAddingTimeInterval:-fmax(0, maxAgeSeconds)];
    NSMutableArray *loaded = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIDs = [NSMutableSet set];
    BOOL rowsValid = YES;
    BOOL canClaimComplete = YES;
    for (id rowValue in rows) {
        NSDictionary *row = EBSessionDictionary(rowValue);
        NSString *identifier = [row[EBSessionIDKey] isKindOfClass:NSString.class]
            ? row[EBSessionIDKey] : nil;
        if (!row || !identifier.length || [seenIDs containsObject:identifier]) {
            rowsValid = NO;
            break;
        }
        [seenIDs addObject:identifier];
        NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:identifier
                                                                          forKey:EBSessionIDKey];
        NSDate *start = EBSessionDate(row[EBSessionChargeStartKey]);
        NSDate *end = EBSessionDate(row[EBSessionChargeEndKey]);
        NSNumber *energy = EBSessionFiniteNonnegative(row[EBSessionEnergyWhKey]);
        BOOL hasIntervalField = row[EBSessionChargeStartKey] || row[EBSessionChargeEndKey];
        BOOL invalidInterval = hasIntervalField &&
            (!start || !end || [start compare:end] == NSOrderedDescending);
        if (invalidInterval || (row[EBSessionEnergyWhKey] && !energy) ||
            (energy && !hasIntervalField)) { rowsValid = NO; break; }
        if (start && end && [start compare:end] != NSOrderedDescending &&
            [end compare:cutoff] != NSOrderedAscending) {
            record[EBSessionChargeStartKey] = start;
            record[EBSessionChargeEndKey] = end;
            record[EBSessionActiveKey] = @([row[EBSessionActiveKey] boolValue]);
            if (energy) record[EBSessionEnergyWhKey] = energy;
        }
        NSDate *disconnected = EBSessionDate(row[EBSessionDisconnectedAtKey]);
        if (row[EBSessionDisconnectedAtKey] && !disconnected) {
            rowsValid = NO;
            break;
        }
        if (disconnected && [disconnected compare:cutoff] != NSOrderedAscending)
            record[EBSessionDisconnectedAtKey] = disconnected;
        if (record.count > 1) {
            if (record[EBSessionDisconnectedAtKey] && !record[EBSessionChargeStartKey])
                canClaimComplete = NO;
            [loaded addObject:record];
        } else if (!hasIntervalField && !disconnected) {
            rowsValid = NO;
            break;
        }
    }
    if (!rowsValid) {
        if (error) *error = EBSessionError(17,
            @"Session cache contains incomplete or malformed rows", path);
        return [EBSessionHistory new];
    }
    [loaded sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *aDate = a[EBSessionChargeStartKey] ?: a[EBSessionDisconnectedAtKey];
        NSDate *bDate = b[EBSessionChargeStartKey] ?: b[EBSessionDisconnectedAtKey];
        NSComparisonResult byDate = [aDate compare:bDate];
        return byDate != NSOrderedSame ? byDate : [a[EBSessionIDKey] compare:b[EBSessionIDKey]];
    }];
    history.sessions = loaded;
    history.fetchedAt = fetchedAt;
    history.sourceID = cachedSource;
    history.complete = canClaimComplete && [root[@"complete"] isKindOfClass:NSNumber.class] &&
                       [root[@"complete"] boolValue];
    history.current = NO;
    return history;
}

BOOL EBSessionCacheSecureExistingFile(NSString *path) {
    if (!path.length) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) return YES;
    return !isDirectory && chmod(path.fileSystemRepresentation, 0600) == 0;
}

EBSessionEnergySummary EBSessionEnergyInWindow(NSArray<NSDictionary *> *sessions,
                                                NSDate *since, NSDate *through) {
    EBSessionEnergySummary result = { .exact = YES };
    if (!since || !through || [through compare:since] == NSOrderedAscending) {
        result.exact = NO;
        return result;
    }
    for (NSDictionary *record in sessions) {
        NSDate *start = EBSessionDate(record[EBSessionChargeStartKey]);
        NSDate *end = EBSessionDate(record[EBSessionChargeEndKey]);
        if (!start || !end) continue; // disconnect-only evidence
        BOOL overlaps = [end compare:since] == NSOrderedDescending &&
                        [start compare:through] == NSOrderedAscending;
        if (!overlaps) continue;
        NSNumber *energy = EBSessionFiniteNonnegative(record[EBSessionEnergyWhKey]);
        BOOL contained = [start compare:since] != NSOrderedAscending &&
                         [end compare:through] != NSOrderedDescending;
        if (!contained || !energy) {
            result.exact = NO;
            continue;
        }
        result.energyWh += energy.doubleValue;
        result.sessionCount++;
    }
    return result;
}
