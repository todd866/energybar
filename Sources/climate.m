#import "climate.h"
#import "config.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "vehicle.h"

static NSNumber *EBFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static BOOL EBBooleanValue(id value, BOOL *out) {
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        if (out) *out = [value boolValue];
        return YES;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = [value lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"1"]) { if (out) *out = YES; return YES; }
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"0"]) { if (out) *out = NO; return YES; }
    }
    return NO;
}

static NSArray *EBWeekdayArray(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *days = [NSMutableArray array];
    for (id day in value) {
        if (![day isKindOfClass:NSNumber.class]) continue;
        NSInteger n = [day integerValue];
        if (n >= 1 && n <= 7) [days addObject:@(n)];
    }
    return days;
}

NSDictionary *EBClimateDefaultConfig(void) {
    return @{
        @"version": @1,
        @"departure": @{
            @"enabled": @NO,
            @"time": @"07:45",
            @"days": @[@1, @2, @3, @4, @5],
            @"targetC": @24,
        },
        @"allDay": @{
            @"enabled": @NO,
            @"days": @[],
            @"onDate": NSNull.null,
            @"from": @"09:00",
            @"until": @"17:00",
            @"limitC": @35,
            @"solarOnlyAtHome": @YES,
            @"dailyCapKWh": @1.5,
            @"minSocPct": @50,
        },
        @"assumedKW": @2.0,
    };
}

static NSDictionary *EBMergeSection(NSDictionary *defaults, NSDictionary *file) {
    if (![file isKindOfClass:NSDictionary.class]) return defaults;
    NSMutableDictionary *merged = [defaults mutableCopy];
    for (NSString *key in file) {
        id value = file[key];
        if ([value isEqual:NSNull.null]) value = nil;
        if (!value) continue;
        if ([key isEqualToString:@"days"] && [value isKindOfClass:NSArray.class]) {
            merged[key] = EBWeekdayArray(value);
        } else if ([key isEqualToString:@"enabled"] || [key isEqualToString:@"solarOnlyAtHome"]) {
            BOOL b = NO;
            if (EBBooleanValue(value, &b)) merged[key] = @(b);
        } else if ([key isEqualToString:@"time"] || [key isEqualToString:@"from"] || [key isEqualToString:@"until"]) {
            if ([value isKindOfClass:NSString.class] && [value length] == 5) merged[key] = value;
        } else if ([key isEqualToString:@"onDate"]) {
            if ([value isKindOfClass:NSString.class]) merged[key] = value;
            else if (value == nil) merged[key] = NSNull.null;
        } else if ([key isEqualToString:@"targetC"] || [key isEqualToString:@"limitC"] ||
                   [key isEqualToString:@"dailyCapKWh"] || [key isEqualToString:@"minSocPct"]) {
            NSNumber *n = EBFiniteNumber(value);
            if (n) merged[key] = n;
        }
    }
    return merged;
}

NSDictionary *EBClimateLoadConfig(NSString *path) {
    NSMutableDictionary *config = [EBClimateDefaultConfig() mutableCopy];
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class]) return config;
    for (NSString *key in root) {
        if ([key isEqualToString:@"departure"] || [key isEqualToString:@"allDay"]) {
            NSDictionary *defaults = config[key];
            config[key] = EBMergeSection(defaults, root[key]);
        } else if ([key isEqualToString:@"version"]) {
            NSNumber *v = EBFiniteNumber(root[key]);
            if (v) config[key] = @((NSInteger)v.doubleValue);
        } else if ([key isEqualToString:@"assumedKW"]) {
            NSNumber *n = EBFiniteNumber(root[key]);
            if (n && n.doubleValue > 0) config[@"assumedKW"] = n;
        } else {
            config[key] = root[key];
        }
    }
    return config;
}

static BOOL EBEnsurePrivateDirectory(NSString *directory, NSError **error) {
    NSString *dir = directory.length ? directory : @".";
    BOOL isDirectory = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:dir isDirectory:&isDirectory]) {
        NSDictionary *attributes = @{ NSFilePosixPermissions: @0700 };
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:attributes error:&createError]) {
            if (error) *error = createError;
            return NO;
        }
        isDirectory = YES;
    }
    if (!isDirectory) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:@{NSFilePathErrorKey: dir}];
        return NO;
    }
    if (chmod(dir.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSFilePathErrorKey: dir}];
        return NO;
    }
    return YES;
}

BOOL EBClimateSaveConfig(NSString *path, NSDictionary *config, NSError **error) {
    if (!path.length || ![config isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    NSMutableDictionary *output = [EBClimateLoadConfig(path) mutableCopy];
    for (NSString *key in config) {
        if ([key isEqualToString:@"departure"] || [key isEqualToString:@"allDay"]) {
            if ([config[key] isKindOfClass:NSDictionary.class]) output[key] = config[key];
        } else if ([key isEqualToString:@"assumedKW"]) {
            NSNumber *n = EBFiniteNumber(config[key]);
            if (n && n.doubleValue > 0) output[key] = n;
        } else if ([key isEqualToString:@"version"]) {
            output[key] = config[key];
        } else {
            output[key] = config[key];
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *dirError = nil;
    if (!EBEnsurePrivateDirectory(directory, &dirError)) {
        if (error) *error = dirError;
        return NO;
    }
    NSString *leaf = path.lastPathComponent.length ? path.lastPathComponent : @"climate.json";
    NSString *templatePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.XXXXXX", leaf]];
    char *temporary = strdup(templatePath.fileSystemRepresentation);
    if (!temporary) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        return NO;
    }
    int fd = mkstemp(temporary);
    if (fd < 0) {
        int code = errno;
        free(temporary);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSFilePathErrorKey: path}];
        return NO;
    }
    BOOL ok = fchmod(fd, 0600) == 0;
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0 && ok) ok = NO;
    if (ok && rename(temporary, path.fileSystemRepresentation) != 0) ok = NO;
    if (!ok) unlink(temporary);
    free(temporary);
    if (!ok && error && !*error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{NSFilePathErrorKey: path}];
    return ok;
}

NSDictionary *EBClimateLoadState(NSString *path) {
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [root isKindOfClass:NSDictionary.class] ? root : @{};
}

static NSString *EBShortClock(NSDate *date) {
    if (!date) return @"—";
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"EEE HH:mm";
    return [f stringFromDate:date];
}

NSString *EBClimateStatusLine(NSDictionary *state, NSDictionary *config) {
    NSDictionary *allDay = [config[@"allDay"] isKindOfClass:NSDictionary.class] ? config[@"allDay"] : @{};
    double cap = EBFiniteNumber(allDay[@"dailyCapKWh"]) ? [allDay[@"dailyCapKWh"] doubleValue] : 1.5;
    double used = EBFiniteNumber(state[@"todayKWh"]) ? [state[@"todayKWh"] doubleValue] : 0;
    NSString *usage = [NSString stringWithFormat:@"%.1f of %.1f kWh today", used, cap];
    NSString *blocked = [state[@"blocked"] isKindOfClass:NSString.class] ? state[@"blocked"] : nil;
    if (blocked.length) return [NSString stringWithFormat:@"%@ · %@", blocked, usage];
    NSDictionary *next = [state[@"next"] isKindOfClass:NSDictionary.class] ? state[@"next"] : nil;
    NSString *reason = [next[@"reason"] isKindOfClass:NSString.class] ? next[@"reason"] : nil;
    NSDate *at = nil;
    if ([next[@"at"] isKindOfClass:NSString.class]) {
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        at = [iso dateFromString:next[@"at"]];
        if (!at) {
            iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            at = [iso dateFromString:next[@"at"]];
        }
    }
    if (reason.length && at)
        return [NSString stringWithFormat:@"%@ %@ · %@", EBShortClock(at), reason, usage];
    if (reason.length) return [NSString stringWithFormat:@"%@ · %@", reason, usage];
    return usage;
}