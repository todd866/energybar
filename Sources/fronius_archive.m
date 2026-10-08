#import "fronius_archive.h"

#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const EBFroniusArchiveErrorDomain = @"Energybar.FroniusArchive";
const NSTimeInterval EBFroniusArchiveRetentionSeconds = 48.0 * 3600.0;

static const NSInteger EBFroniusArchiveCacheVersion = 1;
static const NSUInteger EBFroniusArchiveMaximumValuesPerDevice = 4096;

@interface EBFroniusPVInterval ()
@property(nonatomic, readwrite, copy) NSString *deviceID;
@property(nonatomic, readwrite, copy, nullable) NSNumber *deviceType;
@property(nonatomic, readwrite, copy) NSDate *anchor;
@property(nonatomic, readwrite) NSTimeInterval spanSeconds;
@property(nonatomic, readwrite) double energyWh;
@end

@implementation EBFroniusPVInterval

- (instancetype)initWithDeviceID:(NSString *)deviceID
                       deviceType:(NSNumber *)deviceType
                           anchor:(NSDate *)anchor
                      spanSeconds:(NSTimeInterval)spanSeconds
                         energyWh:(double)energyWh {
    if (!deviceID.length || !anchor || !isfinite(spanSeconds) || spanSeconds <= 0 ||
        spanSeconds > EBFroniusArchiveRetentionSeconds || !isfinite(energyWh) || energyWh < 0) {
        return nil;
    }
    if (deviceType) {
        double value = deviceType.doubleValue;
        if (!isfinite(value) || value < 0 || trunc(value) != value) return nil;
    }
    self = [super init];
    if (self) {
        _deviceID = [deviceID copy];
        _deviceType = [deviceType copy];
        _anchor = [anchor copy];
        _spanSeconds = spanSeconds;
        _energyWh = energyWh;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:EBFroniusPVInterval.class]) return NO;
    EBFroniusPVInterval *other = object;
    BOOL sameType = (!self.deviceType && !other.deviceType) ||
                    [self.deviceType isEqualToNumber:other.deviceType];
    return sameType && [self.deviceID isEqualToString:other.deviceID] &&
        [self.anchor isEqualToDate:other.anchor] && self.spanSeconds == other.spanSeconds &&
        self.energyWh == other.energyWh;
}

- (NSUInteger)hash {
    return self.deviceID.hash ^ self.anchor.hash;
}

@end

static NSError *EBArchiveError(EBFroniusArchiveErrorCode code,
                               NSString *description,
                               NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:
        description ?: @"Fronius archive error" forKey:NSLocalizedDescriptionKey];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:EBFroniusArchiveErrorDomain code:code userInfo:info];
}

static NSDictionary *EBDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *EBArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *EBString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSNumber *EBFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static NSNumber *EBNonnegativeInteger(id value) {
    NSNumber *number = EBFiniteNumber(value);
    if (!number) return nil;
    double d = number.doubleValue;
    return d >= 0 && trunc(d) == d ? number : nil;
}

static NSISO8601DateFormatter *EBArchiveISO(BOOL fractional) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        (fractional ? NSISO8601DateFormatWithFractionalSeconds : 0);
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return formatter;
}

static NSDate *EBArchiveParseDate(id value) {
    NSString *string = EBString(value);
    if (!string.length) return nil;
    NSDate *date = [EBArchiveISO(YES) dateFromString:string];
    return date ?: [EBArchiveISO(NO) dateFromString:string];
}

static NSString *EBArchiveDateString(NSDate *date) {
    return [EBArchiveISO(YES) stringFromDate:date];
}

static BOOL EBArchiveParseOffset(id key, NSTimeInterval *outOffset) {
    NSString *string = [EBString(key) stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!string.length) return NO;
    unsigned long long value = 0;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
        unsigned digit = (unsigned)(c - '0');
        if (value > (ULLONG_MAX - digit) / 10) return NO;
        value = value * 10 + digit;
    }
    if (value > (unsigned long long)LLONG_MAX) return NO;
    if (outOffset) *outOffset = (NSTimeInterval)value;
    return YES;
}

static NSString *EBArchiveIdentity(EBFroniusPVInterval *interval) {
    return [NSString stringWithFormat:@"%lu:%@%@", (unsigned long)interval.deviceID.length,
            interval.deviceID, EBArchiveDateString(interval.anchor)];
}

static NSComparisonResult EBArchiveCompare(EBFroniusPVInterval *a,
                                           EBFroniusPVInterval *b) {
    NSComparisonResult time = [a.anchor compare:b.anchor];
    if (time != NSOrderedSame) return time;
    return [a.deviceID compare:b.deviceID options:NSLiteralSearch];
}

static NSArray<EBFroniusPVInterval *> *EBArchiveNormalize(
    NSArray<EBFroniusPVInterval *> *intervals,
    EBFroniusArchiveErrorCode errorCode,
    NSError **error) {
    NSMutableDictionary<NSString *, EBFroniusPVInterval *> *byIdentity =
        [NSMutableDictionary dictionary];
    for (id value in intervals) {
        if (![value isKindOfClass:EBFroniusPVInterval.class]) {
            if (error) *error = EBArchiveError(errorCode,
                @"Fronius archive contains an invalid interval object", nil);
            return nil;
        }
        EBFroniusPVInterval *interval = value;
        NSString *identity = EBArchiveIdentity(interval);
        EBFroniusPVInterval *prior = byIdentity[identity];
        if (prior && ![prior isEqual:interval]) {
            if (error) *error = EBArchiveError(errorCode,
                @"Fronius archive contains conflicting duplicate intervals", nil);
            return nil;
        }
        byIdentity[identity] = interval;
    }
    return [[byIdentity allValues] sortedArrayUsingComparator:
        ^NSComparisonResult(EBFroniusPVInterval *a, EBFroniusPVInterval *b) {
            return EBArchiveCompare(a, b);
        }];
}

NSArray<EBFroniusPVInterval *> *EBFroniusArchiveParsePVIntervals(
    NSDictionary *response, NSError **error) {
    if (error) *error = nil;
    NSDictionary *root = EBDictionary(response);
    NSDictionary *head = EBDictionary(root[@"Head"]);
    NSDictionary *status = EBDictionary(head[@"Status"]);
    NSDictionary *arguments = EBDictionary(head[@"RequestArguments"]);
    NSNumber *statusCode = EBNonnegativeInteger(status[@"Code"]);
    if (!root || !head || !status || !statusCode) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
            @"Fronius archive response is missing Head.Status.Code", nil);
        return nil;
    }
    if (statusCode.integerValue != 0) {
        NSString *reason = EBString(status[@"UserMessage"]);
        if (!reason.length) reason = EBString(status[@"Reason"]);
        NSString *description = reason.length
            ? [NSString stringWithFormat:@"Fronius archive rejected the request: %@", reason]
            : [NSString stringWithFormat:@"Fronius archive rejected the request (status %@)",
               statusCode];
        EBFroniusArchiveErrorCode code = statusCode.integerValue == 11
            ? EBFroniusArchiveErrorUnsupported : EBFroniusArchiveErrorDeviceStatus;
        if (error) *error = EBArchiveError(code,
                                           description, nil);
        return nil;
    }
    if (![EBString(arguments[@"SeriesType"]) isEqualToString:@"Detail"]) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
            @"Fronius archive response is not a Detail series", nil);
        return nil;
    }

    NSDictionary *body = EBDictionary(root[@"Body"]);
    NSDictionary *devices = EBDictionary(body[@"Data"]);
    if (!body || !devices) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
            @"Fronius archive response is missing Body.Data", nil);
        return nil;
    }

    NSMutableArray<EBFroniusPVInterval *> *parsed = [NSMutableArray array];
    NSArray<NSString *> *deviceKeys = [[devices allKeys] sortedArrayUsingSelector:
                                      @selector(compare:)];
    for (id rawDeviceID in deviceKeys) {
        NSString *deviceID = EBString(rawDeviceID);
        if (![[deviceID lowercaseString] hasPrefix:@"inverter/"]) continue;
        NSDictionary *device = EBDictionary(devices[deviceID]);
        NSDictionary *channels = EBDictionary(device[@"Data"]);
        NSDictionary *energyChannel = EBDictionary(channels[@"EnergyReal_WAC_Sum_Produced"]);
        NSDictionary *spanChannel = EBDictionary(channels[@"TimeSpanInSec"]);
        if (!device || !channels || !energyChannel || !spanChannel) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
                [NSString stringWithFormat:@"Fronius archive is missing PV channels for %@",
                 deviceID], nil);
            return nil;
        }
        if (![EBString(energyChannel[@"Unit"]) isEqualToString:@"Wh"] ||
            ![EBString(spanChannel[@"Unit"]) isEqualToString:@"sec"]) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
                [NSString stringWithFormat:@"Fronius archive has unexpected PV units for %@",
                 deviceID], nil);
            return nil;
        }
        NSDictionary *energyValues = EBDictionary(energyChannel[@"Values"]);
        NSDictionary *spanValues = EBDictionary(spanChannel[@"Values"]);
        NSDate *start = EBArchiveParseDate(device[@"Start"]);
        NSDate *end = EBArchiveParseDate(device[@"End"]);
        if (!energyValues || !spanValues || !start || !end ||
            [end compare:start] == NSOrderedAscending) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
                [NSString stringWithFormat:@"Fronius archive has invalid series metadata for %@",
                 deviceID], nil);
            return nil;
        }
        if (energyValues.count > EBFroniusArchiveMaximumValuesPerDevice) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidResponse,
                [NSString stringWithFormat:@"Fronius archive returned too many PV values for %@",
                 deviceID], nil);
            return nil;
        }
        NSNumber *deviceType = nil;
        if (device[@"DeviceType"] && device[@"DeviceType"] != NSNull.null) {
            deviceType = EBNonnegativeInteger(device[@"DeviceType"]);
            if (!deviceType) {
                if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                    [NSString stringWithFormat:@"Fronius archive has invalid DeviceType for %@",
                     deviceID], nil);
                return nil;
            }
        }
        if (deviceType.integerValue == 1) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorUnsupported,
                @"This Fronius platform does not provide archive history", nil);
            return nil;
        }

        for (id rawOffset in energyValues) {
            NSTimeInterval offset = 0;
            if (!EBArchiveParseOffset(rawOffset, &offset)) {
                if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                    [NSString stringWithFormat:@"Fronius archive has an invalid offset for %@",
                     deviceID], nil);
                return nil;
            }
            NSDate *anchor = [start dateByAddingTimeInterval:offset];
            if ([anchor compare:start] == NSOrderedAscending ||
                [anchor timeIntervalSinceDate:end] > 1.0) {
                if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                    [NSString stringWithFormat:@"Fronius archive has an out-of-range offset for %@",
                     deviceID], nil);
                return nil;
            }
            id rawEnergy = energyValues[rawOffset];
            if (rawEnergy == NSNull.null) continue;
            NSNumber *energy = EBFiniteNumber(rawEnergy);
            NSNumber *span = EBFiniteNumber(spanValues[rawOffset]);
            if (!energy || energy.doubleValue < 0 || !span || span.doubleValue <= 0 ||
                span.doubleValue > EBFroniusArchiveRetentionSeconds) {
                if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                    [NSString stringWithFormat:@"Fronius archive has an invalid PV interval for %@",
                     deviceID], nil);
                return nil;
            }
            EBFroniusPVInterval *interval = [[EBFroniusPVInterval alloc]
                initWithDeviceID:deviceID deviceType:deviceType anchor:anchor
                spanSeconds:span.doubleValue energyWh:energy.doubleValue];
            if (!interval) {
                if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                    [NSString stringWithFormat:@"Fronius archive has an invalid PV value for %@",
                     deviceID], nil);
                return nil;
            }
            [parsed addObject:interval];
        }
    }
    return EBArchiveNormalize(parsed, EBFroniusArchiveErrorInvalidRecord, error);
}

static NSDictionary *EBArchiveJSONObject(EBFroniusPVInterval *interval) {
    NSMutableDictionary *json = [@{
        @"device": interval.deviceID,
        @"at": EBArchiveDateString(interval.anchor),
        @"spanS": @(interval.spanSeconds),
        @"pvWh": @(interval.energyWh),
    } mutableCopy];
    if (interval.deviceType) json[@"deviceType"] = interval.deviceType;
    return json;
}

static BOOL EBArchivePathIsSymbolicLink(NSString *path) {
    struct stat info;
    const char *fileSystemPath = path.fileSystemRepresentation;
    return fileSystemPath && lstat(fileSystemPath, &info) == 0 && S_ISLNK(info.st_mode);
}

static NSArray<EBFroniusPVInterval *> *EBArchiveDecodeCache(NSString *path,
                                                            NSString *sourceID,
                                                            NSError **error) {
    BOOL isDirectory = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) return @[];
    if (isDirectory || EBArchivePathIsSymbolicLink(path)) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache path is not a regular file", nil);
        return nil;
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache could not be read", readError);
        return nil;
    }
    NSError *jsonError = nil;
    NSDictionary *root = EBDictionary([NSJSONSerialization JSONObjectWithData:data
        options:0 error:&jsonError]);
    NSNumber *version = EBNonnegativeInteger(root[@"version"]);
    NSString *storedSourceID = EBString(root[@"source"]);
    NSArray *rows = EBArray(root[@"intervals"]);
    if (!root || !version || version.integerValue != EBFroniusArchiveCacheVersion ||
        !storedSourceID.length || !rows) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCorruptCache,
            @"Fronius archive cache has an unsupported or malformed schema", jsonError);
        return nil;
    }
    if (![storedSourceID isEqualToString:sourceID]) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorSourceMismatch,
            @"Fronius archive cache belongs to a different source", nil);
        return nil;
    }

    NSMutableArray<EBFroniusPVInterval *> *intervals =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (id value in rows) {
        NSDictionary *row = EBDictionary(value);
        NSString *deviceID = EBString(row[@"device"]);
        NSDate *anchor = EBArchiveParseDate(row[@"at"]);
        NSNumber *span = EBFiniteNumber(row[@"spanS"]);
        NSNumber *energy = EBFiniteNumber(row[@"pvWh"]);
        NSNumber *deviceType = nil;
        if (row[@"deviceType"] && row[@"deviceType"] != NSNull.null)
            deviceType = EBNonnegativeInteger(row[@"deviceType"]);
        EBFroniusPVInterval *interval = nil;
        if (row && deviceID.length && anchor && span && energy &&
            (!row[@"deviceType"] || row[@"deviceType"] == NSNull.null || deviceType)) {
            interval = [[EBFroniusPVInterval alloc] initWithDeviceID:deviceID
                deviceType:deviceType anchor:anchor spanSeconds:span.doubleValue
                energyWh:energy.doubleValue];
        }
        if (!interval) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorCorruptCache,
                @"Fronius archive cache contains an invalid interval", nil);
            return nil;
        }
        [intervals addObject:interval];
    }
    return EBArchiveNormalize(intervals, EBFroniusArchiveErrorCorruptCache, error);
}

static NSArray<EBFroniusPVInterval *> *EBArchiveRetained(
    NSArray<EBFroniusPVInterval *> *intervals, NSDate *now) {
    NSDate *cutoff = [now dateByAddingTimeInterval:-EBFroniusArchiveRetentionSeconds];
    NSMutableArray<EBFroniusPVInterval *> *retained = [NSMutableArray array];
    for (EBFroniusPVInterval *interval in intervals) {
        if ([interval.anchor compare:cutoff] == NSOrderedAscending) continue;
        if ([interval.anchor compare:now] == NSOrderedDescending) continue;
        [retained addObject:interval];
    }
    return retained;
}

NSArray<EBFroniusPVInterval *> *EBFroniusArchiveLoadPVCache(NSString *path,
                                                            NSString *sourceID,
                                                            NSDate *now,
                                                            NSError **error) {
    if (error) *error = nil;
    if (!path.length || !sourceID.length || !now) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache requires a path, source, and reference date", nil);
        return nil;
    }
    NSArray *decoded = EBArchiveDecodeCache(path, sourceID, error);
    return decoded ? EBArchiveRetained(decoded, now) : nil;
}

static NSError *EBArchivePOSIXError(int code, NSString *operation, NSString *path) {
    NSString *reason = [NSString stringWithUTF8String:strerror(code)] ?: @"POSIX error";
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: reason,
        NSFilePathErrorKey: path ?: @"",
    }];
    return EBArchiveError(EBFroniusArchiveErrorCacheIO,
        [NSString stringWithFormat:@"Could not %@ Fronius archive cache", operation], underlying);
}

static BOOL EBArchiveEnsurePrivateDirectory(NSString *directory, NSError **error) {
    NSString *path = directory.length ? directory : @".";
    BOOL isDirectory = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path isDirectory:&isDirectory] &&
        EBArchivePathIsSymbolicLink(path)) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache directory is a symbolic link", nil);
        return NO;
    }
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:&createError]) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
                @"Could not create Fronius archive cache directory", createError);
            return NO;
        }
        isDirectory = YES;
    }
    if (!isDirectory) {
        if (error) *error = EBArchivePOSIXError(ENOTDIR, @"prepare", path);
        return NO;
    }
    if (chmod(path.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = EBArchivePOSIXError(errno, @"secure directory for", path);
        return NO;
    }
    return YES;
}

static BOOL EBArchiveWritePrivate(NSString *path, NSData *data, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    if (!EBArchiveEnsurePrivateDirectory(directory, error)) return NO;
    if (EBArchivePathIsSymbolicLink(path)) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache path is a symbolic link", nil);
        return NO;
    }

    NSString *leaf = path.lastPathComponent.length ? path.lastPathComponent : @"fronius-archive";
    NSString *templatePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.XXXXXX", leaf]];
    const char *templateFileSystem = templatePath.fileSystemRepresentation;
    if (!templateFileSystem) {
        if (error) *error = EBArchivePOSIXError(EINVAL, @"prepare", path);
        return NO;
    }
    char *temporary = strdup(templateFileSystem);
    if (!temporary) {
        if (error) *error = EBArchivePOSIXError(ENOMEM, @"allocate temporary path for", path);
        return NO;
    }
    int fd = mkstemp(temporary);
    if (fd < 0) {
        int code = errno;
        free(temporary);
        if (error) *error = EBArchivePOSIXError(code, @"create temporary file for", path);
        return NO;
    }

    BOOL ok = YES;
    int failure = 0;
    if (fchmod(fd, 0600) != 0) {
        ok = NO;
        failure = errno;
    }
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            ok = NO;
            failure = written < 0 ? errno : EIO;
            break;
        }
        cursor += written;
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
    if (!ok) {
        if (error) *error = EBArchivePOSIXError(failure ?: EIO, @"write", path);
        return NO;
    }

    int directoryFD = open(directory.fileSystemRepresentation, O_RDONLY);
    if (directoryFD < 0) {
        if (error) *error = EBArchivePOSIXError(errno, @"open directory for", path);
        return NO;
    }
    BOOL directorySynced = fsync(directoryFD) == 0;
    int syncFailure = directorySynced ? 0 : errno;
    if (close(directoryFD) != 0 && directorySynced) {
        directorySynced = NO;
        syncFailure = errno;
    }
    if (!directorySynced) {
        if (error) *error = EBArchivePOSIXError(syncFailure ?: EIO,
                                                @"sync directory for", path);
        return NO;
    }
    return YES;
}

static BOOL EBArchiveQuarantineMismatchedCache(NSString *path, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    NSString *backup = [path stringByAppendingFormat:@".source-mismatch-%@",
                        NSUUID.UUID.UUIDString.lowercaseString];
    if (rename(path.fileSystemRepresentation, backup.fileSystemRepresentation) != 0) {
        if (error) *error = EBArchivePOSIXError(errno, @"preserve mismatched", path);
        return NO;
    }
    if (chmod(backup.fileSystemRepresentation, 0600) != 0) {
        if (error) *error = EBArchivePOSIXError(errno, @"secure preserved", backup);
        return NO;
    }
    int directoryFD = open(directory.fileSystemRepresentation, O_RDONLY);
    if (directoryFD < 0) {
        if (error) *error = EBArchivePOSIXError(errno, @"open directory for", path);
        return NO;
    }
    BOOL synced = fsync(directoryFD) == 0;
    int failure = synced ? 0 : errno;
    if (close(directoryFD) != 0 && synced) {
        synced = NO;
        failure = errno;
    }
    if (!synced) {
        if (error) *error = EBArchivePOSIXError(failure ?: EIO,
                                                @"sync preserved source for", path);
        return NO;
    }
    return YES;
}

NSArray<EBFroniusPVInterval *> *EBFroniusArchiveMergePVCache(
    NSString *path,
    NSString *sourceID,
    NSArray<EBFroniusPVInterval *> *intervals,
    NSDate *now,
    NSError **error) {
    if (error) *error = nil;
    if (!path.length || !sourceID.length || !now ||
        ![intervals isKindOfClass:NSArray.class]) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive merge requires a path, source, intervals, and reference date", nil);
        return nil;
    }
    NSArray *incoming = EBArchiveNormalize(intervals,
                                           EBFroniusArchiveErrorInvalidRecord, error);
    if (!incoming) return nil;
    for (EBFroniusPVInterval *interval in incoming) {
        if ([interval.anchor compare:now] == NSOrderedDescending) {
            if (error) *error = EBArchiveError(EBFroniusArchiveErrorInvalidRecord,
                @"Fronius archive contains a future interval", nil);
            return nil;
        }
    }

    NSError *decodeError = nil;
    NSArray *existing = EBArchiveDecodeCache(path, sourceID, &decodeError);
    if (!existing && [decodeError.domain isEqualToString:EBFroniusArchiveErrorDomain] &&
        decodeError.code == EBFroniusArchiveErrorSourceMismatch) {
        if (!EBArchiveQuarantineMismatchedCache(path, error)) return nil;
        existing = @[];
    } else if (!existing) {
        if (error) *error = decodeError;
        return nil;
    }
    NSMutableDictionary<NSString *, EBFroniusPVInterval *> *merged =
        [NSMutableDictionary dictionary];
    for (EBFroniusPVInterval *interval in EBArchiveRetained(existing, now))
        merged[EBArchiveIdentity(interval)] = interval;
    NSDate *cutoff = [now dateByAddingTimeInterval:-EBFroniusArchiveRetentionSeconds];
    for (EBFroniusPVInterval *interval in incoming) {
        if ([interval.anchor compare:cutoff] == NSOrderedAscending) continue;
        merged[EBArchiveIdentity(interval)] = interval;
    }
    NSArray *sorted = [[merged allValues] sortedArrayUsingComparator:
        ^NSComparisonResult(EBFroniusPVInterval *a, EBFroniusPVInterval *b) {
            return EBArchiveCompare(a, b);
        }];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:sorted.count];
    for (EBFroniusPVInterval *interval in sorted)
        [rows addObject:EBArchiveJSONObject(interval)];
    NSDictionary *document = @{
        @"version": @(EBFroniusArchiveCacheVersion),
        @"source": sourceID,
        @"intervals": rows,
    };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document
        options:NSJSONWritingSortedKeys error:&jsonError];
    if (!data) {
        if (error) *error = EBArchiveError(EBFroniusArchiveErrorCacheIO,
            @"Fronius archive cache could not be encoded", jsonError);
        return nil;
    }
    if (!EBArchiveWritePrivate(path, data, error)) return nil;
    return sorted;
}

EBFroniusPVArchiveSummary EBFroniusArchiveSummarizePV(
    NSArray<EBFroniusPVInterval *> *intervals, NSDate *start, NSDate *end) {
    EBFroniusPVArchiveSummary summary = (EBFroniusPVArchiveSummary){0};
    if (!start || !end || [end compare:start] != NSOrderedDescending) return summary;
    NSMutableDictionary<NSString *, EBFroniusPVInterval *> *deduplicated =
        [NSMutableDictionary dictionary];
    for (id value in intervals) {
        if (![value isKindOfClass:EBFroniusPVInterval.class]) continue;
        EBFroniusPVInterval *interval = value;
        NSDate *possibleStart = [interval.anchor dateByAddingTimeInterval:-interval.spanSeconds];
        NSDate *possibleEnd = [interval.anchor dateByAddingTimeInterval:interval.spanSeconds];
        if ([possibleStart compare:start] == NSOrderedAscending ||
            [possibleEnd compare:end] == NSOrderedDescending) continue;
        deduplicated[EBArchiveIdentity(interval)] = interval;
    }
    NSMutableSet<NSString *> *devices = [NSMutableSet set];
    for (EBFroniusPVInterval *interval in deduplicated.allValues) {
        summary.energyWh += interval.energyWh;
        summary.recordedDeviceSeconds += interval.spanSeconds;
        summary.intervalCount++;
        [devices addObject:interval.deviceID];
    }
    summary.deviceCount = devices.count;
    summary.hasData = summary.intervalCount > 0;
    return summary;
}
