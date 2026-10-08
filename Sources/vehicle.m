#import "vehicle.h"
#import "pure.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *EBDateString(NSDate *date) {
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime
        | NSISO8601DateFormatWithFractionalSeconds;
    return [f stringFromDate:date];
}

static NSDate *EBDateFromValue(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime
        | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [f dateFromString:value];
    if (!date) {
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [f dateFromString:value];
    }
    return date;
}

static NSDate *EBLaterDate(NSDate *a, NSDate *b) {
    if (!a) return b;
    if (!b) return a;
    return [a compare:b] == NSOrderedAscending ? b : a;
}

static NSNumber *EBFiniteStateNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static NSNumber *EBBooleanStateValue(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? value : nil;
}

static NSError *EBPOSIXError(int code, NSString *operation, NSString *path) {
    NSString *reason = [NSString stringWithUTF8String:strerror(code)] ?: @"POSIX error";
    NSString *description = [NSString stringWithFormat:@"%@ %@: %@",
                              operation, path ?: @"", reason];
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description,
        NSFilePathErrorKey: path ?: @"",
    }];
}

static BOOL EBEnsurePrivateDirectory(NSString *directory, NSError **error) {
    NSString *dir = directory.length ? directory : @".";
    BOOL isDirectory = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:dir isDirectory:&isDirectory]) {
        NSDictionary *attributes = @{ NSFilePosixPermissions: @0700 };
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:dir
           withIntermediateDirectories:YES
                            attributes:attributes
                                 error:&createError]) {
            if (error) *error = createError;
            return NO;
        }
        isDirectory = YES;
    }
    if (!isDirectory) {
        if (error) *error = EBPOSIXError(ENOTDIR, @"prepare directory", dir);
        return NO;
    }
    if (chmod(dir.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = EBPOSIXError(errno, @"secure directory", dir);
        return NO;
    }
    return YES;
}

static BOOL EBWritePrivateJSON(NSString *path, NSDictionary *object, NSError **error) {
    if (!path.length) {
        if (error) *error = EBPOSIXError(EINVAL, @"write", path);
        return NO;
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&jsonError];
    if (!data) {
        if (error) *error = jsonError;
        return NO;
    }

    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    NSError *directoryError = nil;
    if (!EBEnsurePrivateDirectory(directory, &directoryError)) {
        if (error) *error = directoryError;
        return NO;
    }

    NSString *leaf = path.lastPathComponent.length ? path.lastPathComponent : @"state";
    NSString *templatePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.XXXXXX", leaf]];
    char *temporary = strdup(templatePath.fileSystemRepresentation);
    if (!temporary) {
        if (error) *error = EBPOSIXError(ENOMEM, @"allocate temporary path", path);
        return NO;
    }

    int fd = mkstemp(temporary);
    if (fd < 0) {
        int code = errno;
        free(temporary);
        if (error) *error = EBPOSIXError(code, @"create temporary file for", path);
        return NO;
    }

    BOOL ok = YES;
    int failure = 0;
    if (fchmod(fd, 0600) != 0) {
        ok = NO;
        failure = errno;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            ok = NO;
            failure = written < 0 ? errno : EIO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) {
        ok = NO;
        failure = errno;
    }
    if (close(fd) != 0 && ok) {
        ok = NO;
        failure = errno;
    }

    if (ok && rename(temporary, path.fileSystemRepresentation) != 0) {
        ok = NO;
        failure = errno;
    }
    if (!ok) unlink(temporary);
    free(temporary);

    if (!ok && error)
        *error = EBPOSIXError(failure ?: EIO, @"persist", path);
    return ok;
}

static BOOL EBRemovePersistedFile(NSString *path, NSError **error) {
    if (!path.length) {
        if (error) *error = EBPOSIXError(EINVAL, @"delete", path);
        return NO;
    }
    if (unlink(path.fileSystemRepresentation) == 0 || errno == ENOENT)
        return YES;
    if (error) *error = EBPOSIXError(errno, @"delete", path);
    return NO;
}

static NSString *EBProviderSource(id<EBVehicleProvider> provider) {
    id source = provider.dictionaryValue[@"source"];
    return [source isKindOfClass:NSString.class] ? source : @"none";
}

@interface EBVehicleResolvedProvider : NSObject <EBVehicleProvider>
@property(strong, nullable) id<EBVehicleProvider> socProvider;
@property(strong, nullable) id<EBVehicleProvider> readyProvider;
@property(copy, nullable) NSDate *latestInvalidation;
@property(copy, nullable) NSDate *continuityUnknownAt;
@property(copy, nullable) NSString *continuityUnknownReason;
@property NSTimeInterval continuityGapSeconds;
@end

@implementation EBVehicleResolvedProvider
- (BOOL)available { return self.hasSOC || self.hasReady; }
- (BOOL)hasSOC { return self.socProvider != nil; }
- (double)socPercent { return self.socProvider ? self.socProvider.socPercent : 0; }
- (BOOL)socIsEstimate {
    return self.socProvider ? self.socProvider.socIsEstimate : NO;
}
- (NSDate *)socUpdatedAt { return self.socProvider.socUpdatedAt; }
- (NSDate *)socInvalidatedAt { return self.latestInvalidation; }
- (BOOL)hasReady { return self.readyProvider != nil; }
- (BOOL)readyToCharge {
    return self.readyProvider ? self.readyProvider.readyToCharge : NO;
}
- (NSDate *)readyUpdatedAt { return self.readyProvider.readyUpdatedAt; }

- (NSString *)statusLine {
    if (self.socProvider && self.readyProvider == self.socProvider)
        return self.socProvider.statusLine;
    if (self.socProvider && self.readyProvider) {
        return [NSString stringWithFormat:@"%@ · %@", self.socProvider.statusLine,
                self.readyProvider.readyToCharge ? @"ready" : @"not ready"];
    }
    if (self.socProvider) return self.socProvider.statusLine;
    if (self.latestInvalidation) {
        NSString *status = @"Battery unknown · cleared after unplug";
        if (self.readyProvider) {
            status = [status stringByAppendingFormat:@" · %@",
                      self.readyProvider.readyToCharge ? @"ready" : @"not ready"];
        }
        return status;
    }
    if (self.continuityUnknownAt) {
        NSString *status = @"Battery unknown · telemetry gap";
        if (self.readyProvider) {
            status = [status stringByAppendingFormat:@" · %@",
                      self.readyProvider.readyToCharge ? @"ready" : @"not ready"];
        }
        return status;
    }
    if (self.readyProvider)
        return self.readyProvider.readyToCharge ? @"ready" : @"not ready";
    return @"Not linked — AU API unavailable";
}

- (NSDictionary *)dictionaryValue {
    NSMutableDictionary *d = [@{
        @"available": @(self.available),
        @"statusLine": self.statusLine,
        @"source": @"none",
        @"socSource": @"none",
        @"estimated": @(self.socIsEstimate),
        @"continuityUnknown": @(self.continuityUnknownAt != nil),
    } mutableCopy];
    if (self.socProvider) {
        NSDictionary *soc = self.socProvider.dictionaryValue;
        NSString *source = EBProviderSource(self.socProvider);
        d[@"source"] = source;
        d[@"socSource"] = source;
        d[@"socPercent"] = @(self.socProvider.socPercent);
        for (NSString *key in @[@"anchorSource", @"anchorAgeSeconds", @"addedWh",
                                  @"sessionEnergyExact", @"sessionEnergyWh"])
            if (soc[key]) d[key] = soc[key];
        if (self.socUpdatedAt) d[@"socUpdatedAt"] = EBDateString(self.socUpdatedAt);
    }
    if (self.readyProvider) {
        d[@"readyToCharge"] = @(self.readyProvider.readyToCharge);
        d[@"readySource"] = EBProviderSource(self.readyProvider);
        if (self.readyUpdatedAt)
            d[@"readyUpdatedAt"] = EBDateString(self.readyUpdatedAt);
    }
    if (self.latestInvalidation)
        d[@"socInvalidatedAt"] = EBDateString(self.latestInvalidation);
    if (self.continuityUnknownAt) {
        d[@"unknownReason"] = self.continuityUnknownReason ?: @"telemetry-gap";
        d[@"continuityUnknownAt"] = EBDateString(self.continuityUnknownAt);
        d[@"continuityGapSeconds"] = @(lround(self.continuityGapSeconds));
    }
    return d;
}
@end

id<EBVehicleProvider> EBResolveVehicle(NSArray<id<EBVehicleProvider>> *chain) {
    NSDate *latestInvalidation = nil;
    NSDate *latestContinuityUnknownAt = nil;
    NSString *latestContinuityReason = nil;
    NSTimeInterval latestContinuityGap = 0;
    for (id<EBVehicleProvider> provider in chain) {
        latestInvalidation = EBLaterDate(latestInvalidation, provider.socInvalidatedAt);
        NSDictionary *state = provider.dictionaryValue;
        if (![state[@"continuityUnknown"] boolValue]) continue;
        NSDate *unknownAt = EBDateFromValue(state[@"continuityUnknownAt"]);
        if (!unknownAt) continue;
        if (!latestContinuityUnknownAt ||
            [unknownAt compare:latestContinuityUnknownAt] == NSOrderedDescending) {
            latestContinuityUnknownAt = unknownAt;
            latestContinuityReason = [state[@"unknownReason"] isKindOfClass:NSString.class]
                ? state[@"unknownReason"] : @"telemetry-gap";
            NSNumber *gap = EBFiniteStateNumber(state[@"continuityGapSeconds"]);
            latestContinuityGap = gap ? fmax(0, gap.doubleValue) : 0;
        }
    }

    // The inference state lives under ~/.cache, while manual state lives under
    // ~/.config. Mirror unplug tombstones into the durable manual store so
    // clearing caches cannot resurrect a pre-drive percentage.
    if (latestInvalidation) {
        for (id<EBVehicleProvider> provider in chain) {
            if ([provider isKindOfClass:EBVehicleManualProvider.class])
                [(EBVehicleManualProvider *)provider invalidateSOCAt:latestInvalidation];
        }
    }

    id<EBVehicleProvider> socProvider = nil;
    id<EBVehicleProvider> readyProvider = nil;
    for (id<EBVehicleProvider> provider in chain) {
        if (provider.hasSOC) {
            NSDate *updated = provider.socUpdatedAt;
            BOOL survivesInvalidation = !latestInvalidation
                || (updated && [updated compare:latestInvalidation] == NSOrderedDescending);
            BOOL survivesContinuity = !latestContinuityUnknownAt
                || (updated &&
                    [updated compare:latestContinuityUnknownAt] == NSOrderedDescending);
            if (survivesInvalidation && survivesContinuity) {
                if (!socProvider) {
                    socProvider = provider;
                } else if (socProvider.socIsEstimate && !provider.socIsEstimate) {
                    // Chain order normally wins, but a newer direct reading is
                    // more trustworthy than an older inferred anchor. This also
                    // keeps a successfully-saved manual edit visible if updating
                    // the secondary inference cache fails.
                    NSDate *current = socProvider.socUpdatedAt;
                    if (updated && (!current ||
                        [updated compare:current] == NSOrderedDescending))
                        socProvider = provider;
                }
            }
        }
        if (!readyProvider && provider.hasReady) readyProvider = provider;
    }
    if (!socProvider && !readyProvider && !latestInvalidation
        && !latestContinuityUnknownAt)
        return [EBVehicleStubProvider new];
    EBVehicleResolvedProvider *resolved = [EBVehicleResolvedProvider new];
    resolved.socProvider = socProvider;
    resolved.readyProvider = readyProvider;
    resolved.latestInvalidation = latestInvalidation;
    // A newer direct reading re-establishes SoC even if an older inferred
    // provider still reports the historical gap (for example after a secondary
    // anchor-cache write failure).
    if (!socProvider && latestContinuityUnknownAt) {
        resolved.continuityUnknownAt = latestContinuityUnknownAt;
        resolved.continuityUnknownReason = latestContinuityReason;
        resolved.continuityGapSeconds = latestContinuityGap;
    }
    return resolved;
}

static NSString *EBSoCSourceKey(EBSoCSource s) {
    switch (s) {
        case EBSoCSourceManual: return @"manual";
        case EBSoCSourceFullCharge: return @"full-charge-anchor";
        case EBSoCSourceLive: return @"live";
        case EBSoCSourceOBD: return @"obd";
        case EBSoCSourceNone: break;
    }
    return @"none";
}

static EBSoCSource EBSoCSourceFromKey(NSString *k) {
    if ([k isEqualToString:@"manual"]) return EBSoCSourceManual;
    if ([k isEqualToString:@"full"] || [k isEqualToString:@"full-charge-anchor"])
        return EBSoCSourceFullCharge;
    if ([k isEqualToString:@"live"]) return EBSoCSourceLive;
    if ([k isEqualToString:@"obd"]) return EBSoCSourceOBD;
    return EBSoCSourceNone;
}

static NSString *EBAgePhrase(NSTimeInterval age) {
    if (age < 90) return @"just now";
    if (age < 3600) return [NSString stringWithFormat:@"%.0fm ago", age / 60.0];
    if (age < 48 * 3600) return [NSString stringWithFormat:@"%.0fh ago", age / 3600.0];
    return [NSString stringWithFormat:@"%.0fd ago", age / 86400.0];
}

#pragma mark - Stub

@implementation EBVehicleStubProvider
- (BOOL)available { return NO; }
- (BOOL)hasSOC { return NO; }
- (double)socPercent { return 0; }
- (BOOL)socIsEstimate { return NO; }
- (NSDate *)socUpdatedAt { return nil; }
- (NSDate *)socInvalidatedAt { return nil; }
- (BOOL)hasReady { return NO; }
- (BOOL)readyToCharge { return NO; }
- (NSDate *)readyUpdatedAt { return nil; }
- (NSString *)statusLine {
    return @"Not linked — AU API unavailable";
}
- (NSDictionary *)dictionaryValue {
    return @{
        @"available": @NO,
        @"source": @"none",
        @"socSource": @"none",
        @"estimated": @NO,
        @"statusLine": self.statusLine,
    };
}
@end

#pragma mark - OBD seam

@interface EBVehicleOBDProvider ()
@property(copy) NSString *cachePath;
@property NSTimeInterval maxAgeSeconds;
@end

@implementation EBVehicleOBDProvider
- (instancetype)initWithCachePath:(NSString *)path maxAgeSeconds:(NSTimeInterval)maxAge {
    self = [super init];
    if (self) {
        _cachePath = [path copy];
        _maxAgeSeconds = maxAge > 0 ? maxAge : 900;
        // TODO(obd): call reload / parse ~/.cache/energybar/obd.json here.
        // TODO(obd): available when soc present and at within maxAgeSeconds.
        // TODO(obd): sidecar writes the file; do not invent SoC if missing/stale.
        (void)_cachePath;
        (void)_maxAgeSeconds;
    }
    return self;
}
// Seam only — never report SoC until cache parsing + freshness land.
- (BOOL)available { return NO; }
- (BOOL)hasSOC { return NO; }
- (double)socPercent { return 0; }
- (BOOL)socIsEstimate { return NO; }
- (NSDate *)socUpdatedAt { return nil; }
- (NSDate *)socInvalidatedAt { return nil; }
- (BOOL)hasReady { return NO; }
- (BOOL)readyToCharge { return NO; }
- (NSDate *)readyUpdatedAt { return nil; }
- (NSString *)statusLine {
    return @"OBD — not linked (see docs/obd-dongle.md)";
}
- (NSDictionary *)dictionaryValue {
    return @{
        @"available": @NO,
        @"source": @"obd",
        @"estimated": @NO,
        @"statusLine": self.statusLine,
        @"cachePath": self.cachePath ?: @"",
        @"maxAgeSeconds": @(self.maxAgeSeconds),
    };
}
@end

#pragma mark - Live seam

@interface EBVehicleLiveProvider ()
@property(copy) NSString *tokenPath;
@property BOOL tokenOK;
@end

@implementation EBVehicleLiveProvider
- (instancetype)initWithTokenPath:(NSString *)path {
    self = [super init];
    if (self) {
        _tokenPath = [path copy];
        [self reload];
    }
    return self;
}
- (void)reload {
    self.tokenOK = NO;
    NSData *data = [NSData dataWithContentsOfFile:self.tokenPath];
    if (!data) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) return;
    NSString *access = j[@"access_token"];
    NSString *vin = j[@"vin"];
    if ([access isKindOfClass:NSString.class] && access.length
        && [vin isKindOfClass:NSString.class] && vin.length)
        self.tokenOK = YES;
}
// No API client yet — capture pending. available stays NO even with a token file
// until endpoints exist; tokenOK only gates future work.
- (BOOL)available { return NO; }
- (BOOL)hasSOC { return NO; }
- (double)socPercent { return 0; }
- (BOOL)socIsEstimate { return NO; }
- (NSDate *)socUpdatedAt { return nil; }
- (NSDate *)socInvalidatedAt { return nil; }
- (BOOL)hasReady { return NO; }
- (BOOL)readyToCharge { return NO; }
- (NSDate *)readyUpdatedAt { return nil; }
- (NSString *)statusLine {
    return self.tokenOK
        ? @"Live token present — API client not wired"
        : @"Live — not linked";
}
- (NSDictionary *)dictionaryValue {
    return @{
        @"available": @NO,
        @"source": @"live",
        @"estimated": @NO,
        @"statusLine": self.statusLine,
        @"tokenPresent": @(self.tokenOK),
    };
}
@end

#pragma mark - Manual

@interface EBVehicleManualProvider ()
@property(copy) NSString *path;
@property BOOL hasSOCValue;
@property double soc;
@property BOOL hasReadyValue;
@property BOOL readyFlag;
@property(copy, nullable) NSDate *socAt;
@property(copy, nullable) NSDate *readyAt;
@property(copy, nullable) NSDate *manualInvalidatedAt;
@property(copy, nullable, readwrite) NSError *persistenceError;
- (BOOL)persist;
@end

@implementation EBVehicleManualProvider

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        [self reload];
    }
    return self;
}

- (BOOL)available {
    return self.hasSOCValue || self.hasReadyValue;
}

- (BOOL)hasSOC { return self.hasSOCValue; }
- (double)socPercent { return self.soc; }
- (BOOL)socIsEstimate { return NO; }
- (NSDate *)socUpdatedAt { return self.socAt; }
- (NSDate *)socInvalidatedAt { return self.manualInvalidatedAt; }
- (BOOL)hasReady { return self.hasReadyValue; }
- (BOOL)readyToCharge { return self.readyFlag; }
- (NSDate *)readyUpdatedAt { return self.readyAt; }

- (NSString *)statusLine {
    if (!self.available)
        return @"Set SOC in ⚙ — AU API unavailable";
    NSMutableArray *parts = [NSMutableArray array];
    if (self.hasSOCValue)
        [parts addObject:[NSString stringWithFormat:@"%.0f%%", self.soc]];
    if (self.hasReadyValue)
        [parts addObject:self.readyFlag ? @"ready" : @"not ready"];
    return [parts componentsJoinedByString:@" · "];
}

- (NSDictionary *)dictionaryValue {
    NSMutableDictionary *d = [@{
        @"available": @(self.available),
        @"statusLine": self.statusLine,
        @"source": @"manual",
        @"estimated": @NO,
    } mutableCopy];
    if (self.hasSOCValue) {
        d[@"socPercent"] = @(self.soc);
        if (self.socAt) d[@"socUpdatedAt"] = EBDateString(self.socAt);
    }
    if (self.hasReadyValue) {
        d[@"readyToCharge"] = @(self.readyFlag);
        if (self.readyAt) d[@"readyUpdatedAt"] = EBDateString(self.readyAt);
    }
    NSDate *latest = EBLaterDate(self.socAt, self.readyAt);
    if (latest) d[@"updatedAt"] = EBDateString(latest); // compatibility
    if (self.manualInvalidatedAt)
        d[@"socInvalidatedAt"] = EBDateString(self.manualInvalidatedAt);
    return d;
}

- (void)reload {
    self.persistenceError = nil;
    self.hasSOCValue = NO;
    self.soc = 0;
    self.hasReadyValue = NO;
    self.readyFlag = NO;
    self.socAt = nil;
    self.readyAt = nil;
    self.manualInvalidatedAt = nil;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:self.path options:0 error:&readError];
    if (!data) {
        if ([NSFileManager.defaultManager fileExistsAtPath:self.path])
            self.persistenceError = readError;
        return;
    }
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:NSDictionary.class]) {
        self.persistenceError = jsonError ?: [NSError errorWithDomain:NSCocoaErrorDomain
            code:NSFileReadCorruptFileError userInfo:@{
                NSLocalizedDescriptionKey: @"Manual vehicle state is not a JSON object",
                NSFilePathErrorKey: self.path ?: @"",
            }];
        return;
    }
    NSDictionary *j = root;
    NSNumber *soc = EBFiniteStateNumber(j[@"soc"]);
    if (soc) {
        double value = [soc doubleValue];
        self.hasSOCValue = YES;
        self.soc = fmin(100.0, fmax(0.0, value));
    }
    NSNumber *ready = EBBooleanStateValue(j[@"ready"]);
    if (ready) {
        self.hasReadyValue = YES;
        self.readyFlag = [ready boolValue];
    }
    NSDate *legacyAt = EBDateFromValue(j[@"updatedAt"]);
    self.socAt = EBDateFromValue(j[@"socUpdatedAt"]);
    self.readyAt = EBDateFromValue(j[@"readyUpdatedAt"]);
    self.manualInvalidatedAt = EBDateFromValue(j[@"socInvalidatedAt"]);
    if (self.hasSOCValue && !self.socAt) self.socAt = legacyAt;
    if (self.hasReadyValue && !self.readyAt) self.readyAt = legacyAt;
    if (self.hasSOCValue && self.manualInvalidatedAt
        && (!self.socAt
            || [self.socAt compare:self.manualInvalidatedAt] != NSOrderedDescending)) {
        self.hasSOCValue = NO;
        self.soc = 0;
        self.socAt = nil;
        (void)[self persist];
    }
}

- (BOOL)persist {
    NSMutableDictionary *j = [NSMutableDictionary dictionary];
    if (self.hasSOCValue) {
        j[@"soc"] = @(lround(self.soc));
        if (self.socAt) j[@"socUpdatedAt"] = EBDateString(self.socAt);
    }
    if (self.hasReadyValue) {
        j[@"ready"] = @(self.readyFlag);
        if (self.readyAt) j[@"readyUpdatedAt"] = EBDateString(self.readyAt);
    }
    NSDate *latest = EBLaterDate(self.socAt, self.readyAt);
    if (latest) j[@"updatedAt"] = EBDateString(latest); // compatibility
    if (self.manualInvalidatedAt)
        j[@"socInvalidatedAt"] = EBDateString(self.manualInvalidatedAt);
    NSError *error = nil;
    BOOL written = EBWritePrivateJSON(self.path, j, &error);
    self.persistenceError = written ? nil : error;
    return written;
}

- (BOOL)setSOC:(double)percent {
    if (!isfinite(percent)) return NO;
    BOOL oldHasSOC = self.hasSOCValue;
    double oldSOC = self.soc;
    NSDate *oldAt = self.socAt;
    self.hasSOCValue = YES;
    self.soc = fmin(100.0, fmax(0.0, percent));
    self.socAt = [NSDate date];
    if ([self persist]) return YES;
    self.hasSOCValue = oldHasSOC;
    self.soc = oldSOC;
    self.socAt = oldAt;
    return NO;
}

- (BOOL)setReady:(BOOL)ready {
    BOOL oldHasReady = self.hasReadyValue;
    BOOL oldReady = self.readyFlag;
    NSDate *oldAt = self.readyAt;
    self.hasReadyValue = YES;
    self.readyFlag = ready;
    self.readyAt = [NSDate date];
    if ([self persist]) return YES;
    self.hasReadyValue = oldHasReady;
    self.readyFlag = oldReady;
    self.readyAt = oldAt;
    return NO;
}

- (BOOL)invalidateSOCAt:(NSDate *)at {
    if (!at) return NO;
    BOOL advances = !self.manualInvalidatedAt
        || [at compare:self.manualInvalidatedAt] == NSOrderedDescending;
    BOOL invalidatesSOC = self.hasSOCValue
        && (!self.socAt || [self.socAt compare:at] != NSOrderedDescending);
    if (!advances && !invalidatesSOC)
        return self.persistenceError ? [self persist] : YES;
    if (advances) self.manualInvalidatedAt = at;
    if (invalidatesSOC) {
        self.hasSOCValue = NO;
        self.soc = 0;
        self.socAt = nil;
    }
    // Unplug invalidation is fail-safe: never restore an unsafe percentage just
    // because durable storage is temporarily unavailable. A later identical
    // invalidation retries while persistenceError remains set.
    return [self persist];
}

- (BOOL)clear {
    NSError *error = nil;
    if (!EBRemovePersistedFile(self.path, &error)) {
        self.persistenceError = error;
        return NO;
    }
    self.hasSOCValue = NO;
    self.soc = 0;
    self.hasReadyValue = NO;
    self.readyFlag = NO;
    self.socAt = nil;
    self.readyAt = nil;
    self.manualInvalidatedAt = nil;
    self.persistenceError = nil;
    return YES;
}

@end

#pragma mark - Inferred

@interface EBVehicleInferredProvider ()
@property(copy) NSString *path;
@property double capacityWh;
@property double efficiency;
@property double anchorPct;
@property(copy, nullable) NSDate *anchorAt;
@property EBSoCSource anchorSource;
@property(copy, nullable) NSDate *invalidatedAt;
@property(copy, nullable) NSDate *historyClearedAt;
@property EBSoCEstimate estimate;
@property(copy, nullable, readwrite) NSError *persistenceError;
- (void)loadState;
- (BOOL)persistState;
@end

@implementation EBVehicleInferredProvider

- (instancetype)initWithPath:(NSString *)path
                  capacityWh:(double)capacityWh
                  efficiency:(double)efficiency {
    self = [super init];
    if (self) {
        _path = [path copy];
        BOOL finiteConfiguration = isfinite(capacityWh) && isfinite(efficiency);
        _capacityWh = finiteConfiguration && capacityWh > 0 ? capacityWh : 0;
        _efficiency = finiteConfiguration && efficiency > 0 ? efficiency : 0.90;
        _anchorPct = -1;
        _anchorSource = EBSoCSourceNone;
        _estimate = (EBSoCEstimate){0};
        [self loadState];
        // Fail closed before the first network refresh. Cached samples/sessions
        // may reconcile this initial edge gap moments later, but an old manual
        // fallback must never flash as trustworthy during startup.
        _estimate = EBInferSoCWithSessions(
            @[], nil, _anchorPct, _anchorAt, _anchorSource,
            _capacityWh, _efficiency, [NSDate date]);
    }
    return self;
}

- (void)loadState {
    self.persistenceError = nil;
    self.anchorPct = -1;
    self.anchorAt = nil;
    self.anchorSource = EBSoCSourceNone;
    self.invalidatedAt = nil;
    self.historyClearedAt = nil;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:self.path options:0 error:&readError];
    if (!data) {
        if ([NSFileManager.defaultManager fileExistsAtPath:self.path])
            self.persistenceError = readError;
        return;
    }
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:NSDictionary.class]) {
        self.persistenceError = jsonError ?: [NSError errorWithDomain:NSCocoaErrorDomain
            code:NSFileReadCorruptFileError userInfo:@{
                NSLocalizedDescriptionKey: @"Inferred vehicle state is not a JSON object",
                NSFilePathErrorKey: self.path ?: @"",
            }];
        return;
    }
    NSDictionary *j = root;
    self.invalidatedAt = EBDateFromValue(j[@"invalidatedAt"]);
    self.historyClearedAt = EBDateFromValue(j[@"historyClearedAt"]);
    NSNumber *soc = EBFiniteStateNumber(j[@"soc"]);
    id at = j[@"at"];
    NSString *src = j[@"source"];
    if (!soc || ![at isKindOfClass:NSString.class]) return;
    double percent = [soc doubleValue];
    NSDate *when = EBDateFromValue(at);
    if (!when) {
        (void)[self persistState];
        return;
    }
    EBSoCSource source = EBSoCSourceFromKey(
        [src isKindOfClass:NSString.class] ? src : @"manual");
    // Old versions persisted a guessed 100% after any 15-minute solar pause.
    // Never revive that unsafe anchor.
    if (source == EBSoCSourceNone || source == EBSoCSourceFullCharge) {
        (void)[self persistState];
        return;
    }
    self.anchorPct = fmin(100.0, fmax(0.0, percent));
    self.anchorAt = when;
    self.anchorSource = source;
    if (self.invalidatedAt
        && [self.anchorAt compare:self.invalidatedAt] != NSOrderedDescending) {
        self.anchorPct = -1;
        self.anchorAt = nil;
        self.anchorSource = EBSoCSourceNone;
        (void)[self persistState];
    }
}

- (BOOL)persistState {
    NSMutableDictionary *j = [NSMutableDictionary dictionary];
    if (self.anchorAt && self.anchorPct >= 0
        && self.anchorSource != EBSoCSourceNone
        && self.anchorSource != EBSoCSourceFullCharge) {
        j[@"soc"] = @(self.anchorPct);
        j[@"at"] = EBDateString(self.anchorAt);
        j[@"source"] = EBSoCSourceKey(self.anchorSource);
    }
    if (self.invalidatedAt)
        j[@"invalidatedAt"] = EBDateString(self.invalidatedAt);
    if (self.historyClearedAt)
        j[@"historyClearedAt"] = EBDateString(self.historyClearedAt);
    NSError *error = nil;
    if (!j.count) {
        BOOL removed = EBRemovePersistedFile(self.path, &error);
        self.persistenceError = removed ? nil : error;
        return removed;
    }
    BOOL written = EBWritePrivateJSON(self.path, j, &error);
    self.persistenceError = written ? nil : error;
    return written;
}

- (BOOL)setAnchorPercent:(double)percent at:(NSDate *)at source:(EBSoCSource)source {
    if (!isfinite(percent)
        || source == EBSoCSourceNone || source == EBSoCSourceFullCharge) return NO;
    NSDate *when = at ?: [NSDate date];
    if (self.invalidatedAt
        && [when compare:self.invalidatedAt] != NSOrderedDescending) return NO;
    if (self.historyClearedAt
        && [when compare:self.historyClearedAt] != NSOrderedDescending) return NO;
    double oldPercent = self.anchorPct;
    NSDate *oldAt = self.anchorAt;
    EBSoCSource oldSource = self.anchorSource;
    self.anchorPct = fmin(100.0, fmax(0.0, percent));
    self.anchorAt = when;
    self.anchorSource = source;
    if ([self persistState]) return YES;
    self.anchorPct = oldPercent;
    self.anchorAt = oldAt;
    self.anchorSource = oldSource;
    return NO;
}

- (BOOL)clearAnchor {
    double oldPercent = self.anchorPct;
    NSDate *oldAt = self.anchorAt;
    EBSoCSource oldSource = self.anchorSource;
    EBSoCEstimate oldEstimate = self.estimate;
    self.anchorPct = -1;
    self.anchorAt = nil;
    self.anchorSource = EBSoCSourceNone;
    self.estimate = (EBSoCEstimate){0};
    if ([self persistState]) return YES;
    self.anchorPct = oldPercent;
    self.anchorAt = oldAt;
    self.anchorSource = oldSource;
    self.estimate = oldEstimate;
    return NO;
}

- (BOOL)clearAllState {
    double oldPercent = self.anchorPct;
    NSDate *oldAt = self.anchorAt;
    EBSoCSource oldSource = self.anchorSource;
    NSDate *oldInvalidatedAt = self.invalidatedAt;
    NSDate *oldHistoryClearedAt = self.historyClearedAt;
    EBSoCEstimate oldEstimate = self.estimate;
    self.anchorPct = -1;
    self.anchorAt = nil;
    self.anchorSource = EBSoCSourceNone;
    self.invalidatedAt = nil;
    // Keep a small durable high-water mark so the 48-hour history cannot
    // immediately recreate a tombstone the user explicitly cleared.
    // ISO-8601 persistence may round sub-second precision. Advance the marker
    // slightly beyond the cleared tombstone so that same-row history cannot
    // compare newer after a save/reload round trip.
    NSDate *clearedThrough = oldInvalidatedAt
        ? [oldInvalidatedAt dateByAddingTimeInterval:1.0] : nil;
    self.historyClearedAt = EBLaterDate([NSDate date], clearedThrough);
    self.estimate = (EBSoCEstimate){0};
    if ([self persistState]) return YES;
    self.anchorPct = oldPercent;
    self.anchorAt = oldAt;
    self.anchorSource = oldSource;
    self.invalidatedAt = oldInvalidatedAt;
    self.historyClearedAt = oldHistoryClearedAt;
    self.estimate = oldEstimate;
    return NO;
}

- (BOOL)updateWithSamples:(NSArray<NSDictionary *> *)samples now:(NSDate *)now {
    return [self updateWithSamples:samples sessions:nil now:now];
}

- (BOOL)updateWithSamples:(NSArray<NSDictionary *> *)samples
                 sessions:(NSArray<NSDictionary *> *)sessions
                      now:(NSDate *)now {
    NSDate *eval = now ?: [NSDate date];
    NSDate *latestUnplug = self.invalidatedAt;
    for (NSDictionary *row in samples) {
        NSDate *t = row[@"t"];
        NSNumber *state = EBFiniteStateNumber(row[@"st"]);
        if (![t isKindOfClass:NSDate.class] || !state ||
            trunc(state.doubleValue) != state.doubleValue)
            continue;
        if ([t compare:eval] == NSOrderedDescending) continue;
        if (self.historyClearedAt
            && [t compare:self.historyClearedAt] != NSOrderedDescending) continue;
        if ([state integerValue] == EBChargerStateUnplugged)
            latestUnplug = EBLaterDate(latestUnplug, t);
    }
    NSDate *sessionDisconnect = EBLatestSessionDisconnection(
        sessions, self.historyClearedAt, eval);
    latestUnplug = EBLaterDate(latestUnplug, sessionDisconnect);
    BOOL stateChanged = latestUnplug != self.invalidatedAt;
    self.invalidatedAt = latestUnplug;
    if (self.anchorAt && self.invalidatedAt
        && [self.anchorAt compare:self.invalidatedAt] != NSOrderedDescending) {
        self.anchorPct = -1;
        self.anchorAt = nil;
        self.anchorSource = EBSoCSourceNone;
        stateChanged = YES;
    }
    BOOL persisted = YES;
    if (stateChanged || self.persistenceError)
        persisted = [self persistState];
    self.estimate = EBInferSoCWithSessions(
        samples, sessions, self.anchorPct, self.anchorAt, self.anchorSource,
        self.capacityWh, self.efficiency, eval);
    return persisted;
}

- (BOOL)available { return self.estimate.known; }
- (BOOL)hasSOC { return self.estimate.known; }
- (double)socPercent { return self.estimate.percent; }
- (BOOL)socIsEstimate { return self.estimate.known; }
- (NSDate *)socUpdatedAt { return self.anchorAt; }
- (NSDate *)socInvalidatedAt { return self.invalidatedAt; }
- (BOOL)hasReady { return NO; }
- (BOOL)readyToCharge { return NO; }
- (NSDate *)readyUpdatedAt { return nil; }

- (NSString *)statusLine {
    if (self.capacityWh <= 0)
        return @"Not linked — set EV_BATTERY_KWH";
    if (self.estimate.continuityUnknown)
        return @"Battery unknown · telemetry gap";
    if (!self.estimate.known)
        return @"Not linked — no anchor";
    NSString *from = EBSoCSourceKey(self.estimate.source);
    return [NSString stringWithFormat:@"%.0f%% · est. from %@ %@",
            self.estimate.percent, from, EBAgePhrase(self.estimate.anchorAge)];
}

- (NSDictionary *)dictionaryValue {
    NSMutableDictionary *d = [@{
        @"available": @(self.available),
        @"statusLine": self.statusLine,
        @"source": self.estimate.known
            ? [@"inferred-" stringByAppendingString:EBSoCSourceKey(self.estimate.source)]
            : @"none",
        @"estimated": @(self.socIsEstimate),
        @"continuityUnknown": @(self.estimate.continuityUnknown),
    } mutableCopy];
    if (self.estimate.known) {
        d[@"socPercent"] = @(self.estimate.percent);
        d[@"anchorSource"] = EBSoCSourceKey(self.estimate.source);
        if (self.anchorAt) d[@"socUpdatedAt"] = EBDateString(self.anchorAt);
        d[@"anchorAgeSeconds"] = @(lround(self.estimate.anchorAge));
        d[@"addedWh"] = @(self.estimate.addedWh);
        if (self.estimate.usedExactSessionEnergy) {
            d[@"sessionEnergyExact"] = @YES;
            d[@"sessionEnergyWh"] = @(self.estimate.exactSessionWh);
        }
    } else if (self.estimate.continuityUnknown) {
        d[@"unknownReason"] = @"telemetry-gap";
        NSDate *unknownAt = [NSDate dateWithTimeIntervalSince1970:
                             self.estimate.continuityUnknownAt];
        d[@"continuityUnknownAt"] = EBDateString(unknownAt);
        d[@"continuityGapSeconds"] = @(lround(self.estimate.continuityGapSeconds));
        d[@"anchorSource"] = EBSoCSourceKey(self.estimate.source);
        if (self.anchorAt) d[@"socUpdatedAt"] = EBDateString(self.anchorAt);
        d[@"anchorAgeSeconds"] = @(lround(self.estimate.anchorAge));
    }
    if (self.invalidatedAt)
        d[@"socInvalidatedAt"] = EBDateString(self.invalidatedAt);
    return d;
}

@end
