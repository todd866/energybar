#import "config.h"
#import "tariff.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation EBConfig
@end

NSString *EBHome(void) {
    const char *override = getenv("ENERGYBAR_HOME");
    if (override && override[0])
        return [NSString stringWithUTF8String:override].stringByStandardizingPath;
    return NSHomeDirectory();
}

static BOOL EBValidEnvKey(NSString *key) {
    if (!key.length) return NO;
    NSCharacterSet *head = [NSCharacterSet characterSetWithCharactersInString:
                            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"];
    NSCharacterSet *tail = [NSCharacterSet characterSetWithCharactersInString:
                            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789"];
    if (![head characterIsMember:[key characterAtIndex:0]]) return NO;
    for (NSUInteger i = 1; i < key.length; i++)
        if (![tail characterIsMember:[key characterAtIndex:i]]) return NO;
    return YES;
}

static NSString *EBParseEnvValue(NSString *raw) {
    NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!value.length) return @"";

    unichar quote = [value characterAtIndex:0];
    if (quote == '\'' || quote == '"') {
        NSMutableString *out = [NSMutableString string];
        BOOL escaped = NO;
        for (NSUInteger i = 1; i < value.length; i++) {
            unichar c = [value characterAtIndex:i];
            if (escaped) {
                [out appendFormat:@"%C", c];
                escaped = NO;
            } else if (c == '\\' && quote == '"') {
                escaped = YES;
            } else if (c == quote) {
                return out;
            } else {
                [out appendFormat:@"%C", c];
            }
        }
        return out;
    }

    for (NSUInteger i = 0; i < value.length; i++) {
        if ([value characterAtIndex:i] != '#') continue;
        if (i == 0 || [NSCharacterSet.whitespaceCharacterSet
                       characterIsMember:[value characterAtIndex:i - 1]]) {
            value = [value substringToIndex:i];
            break;
        }
    }
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSDictionary<NSString *, NSString *> *EBParseEnvFile(NSString *path) {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    NSString *raw = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!raw) return values;
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:
                             NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length || [trimmed hasPrefix:@"#"]) continue;
        if ([trimmed hasPrefix:@"export "])
            trimmed = [[trimmed substringFromIndex:7]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange equals = [trimmed rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:equals.location]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!EBValidEnvKey(key)) continue;
        values[key] = EBParseEnvValue([trimmed substringFromIndex:equals.location + 1]);
    }
    return values;
}

static NSString *EBConfigString(NSDictionary<NSString *, NSString *> *file,
                                NSString *key) {
    const char *environment = getenv(key.UTF8String);
    if (environment) return [NSString stringWithUTF8String:environment];
    return file[key] ?: @"";
}

static BOOL EBConfigContains(NSDictionary<NSString *, NSString *> *file, NSString *key) {
    return getenv(key.UTF8String) != NULL || file[key] != nil;
}

static NSDate *EBParseISODate(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return nil;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date) return date;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

static BOOL EBParseFiniteDouble(NSString *text, double *outValue) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:trimmed];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value)) return NO;
    if (outValue) *outValue = value;
    return YES;
}

static NSNumber *EBJSONFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

EBConfig *EBLoadConfig(void) {
    EBConfig *config = [EBConfig new];
    NSString *envPath = [EBHome() stringByAppendingPathComponent:@".config/energybar/.env"];
    NSDictionary<NSString *, NSString *> *file = EBParseEnvFile(envPath);

    NSString *api = EBConfigString(file, @"FRONIUS_SOLAR_API");
    NSString *ip = EBConfigString(file, @"FRONIUS_LOCAL_IP");
    if (!api.length && ip.length)
        api = [NSString stringWithFormat:@"http://%@/solar_api", ip];
    config.froniusAPI = api ?: @"";
    config.chargePointId = EBConfigString(file, @"EVNEX_CHARGE_POINT_ID");
    config.orgId = EBConfigString(file, @"EVNEX_ORG_ID");
    config.tokenCachePath = [EBHome() stringByAppendingPathComponent:@".cache/evnex/tokens.json"];
    config.samplesPath = [EBHome() stringByAppendingPathComponent:@".cache/energybar/samples.jsonl"];
    config.sessionsPath = [EBHome() stringByAppendingPathComponent:@".cache/energybar/sessions.json"];
    config.froniusArchivePath = [EBHome() stringByAppendingPathComponent:@".cache/energybar/fronius-pv.json"];
    NSString *tariffPath = EBConfigString(file, @"ENERGYBAR_TARIFF_PATH");
    config.tariffPath = tariffPath.length ? tariffPath.stringByExpandingTildeInPath.stringByStandardizingPath
        : [EBHome() stringByAppendingPathComponent:@".config/energybar/tariff.json"];
    NSError *tariffError = nil;
    config.tariff = EBTariffLoad(config.tariffPath, &tariffError);
    config.tariffError = tariffError.localizedDescription;

    NSString *capacity = EBConfigString(file, @"EV_BATTERY_KWH");
    double capacityKWh = 0;
    config.evBatteryWh = EBParseFiniteDouble(capacity, &capacityKWh) && capacityKWh > 0
        ? capacityKWh * 1000.0 : 0;
    NSString *inverter = EBConfigString(file, @"INVERTER_KW");
    double inverterKW = 0;
    config.inverterW = EBParseFiniteDouble(inverter, &inverterKW) && inverterKW > 0 ? inverterKW * 1000.0 : 0;
    NSString *efficiency = EBConfigString(file, @"EV_CHARGE_EFFICIENCY");
    double efficiencyValue = 0;
    config.evChargeEfficiency = EBParseFiniteDouble(efficiency, &efficiencyValue)
        ? efficiencyValue : 0.90;
    if (config.evChargeEfficiency <= 0 || config.evChargeEfficiency > 1.0)
        config.evChargeEfficiency = 0.90;

    NSString *obdPath = EBConfigString(file, @"OBD_CACHE_PATH");
    config.obdCachePath = obdPath.length
        ? obdPath.stringByExpandingTildeInPath.stringByStandardizingPath
        : [EBHome() stringByAppendingPathComponent:@".cache/energybar/obd.json"];
    NSString *obdAge = EBConfigString(file, @"OBD_MAX_AGE_SECONDS");
    double obdAgeValue = 0;
    config.obdMaxAgeSeconds = EBParseFiniteDouble(obdAge, &obdAgeValue) ? obdAgeValue : 900;
    if (config.obdMaxAgeSeconds <= 0) config.obdMaxAgeSeconds = 900;

    NSString *barText = EBConfigString(file, @"ENERGYBAR_BAR_TEXT").lowercaseString;
    BOOL textEnabled = [barText isEqualToString:@"1"] || [barText isEqualToString:@"true"] ||
                       [barText isEqualToString:@"yes"];
    config.barText = EBConfigContains(file, @"ENERGYBAR_BAR_TEXT")
        ? textEnabled
        : [NSUserDefaults.standardUserDefaults boolForKey:@"EBBarText"];

    config.accessToken = @"";
    config.refreshToken = @"";
    NSData *tokenData = [NSData dataWithContentsOfFile:config.tokenCachePath];
    id decoded = tokenData
        ? [NSJSONSerialization JSONObjectWithData:tokenData options:0 error:nil]
        : nil;
    if ([decoded isKindOfClass:NSDictionary.class]) {
        NSDictionary *token = decoded;
        id access = token[@"access_token"];
        id refresh = token[@"refresh_token"];
        id expiry = token[@"expires_at"];
        if ([access isKindOfClass:NSString.class]) config.accessToken = access;
        if ([refresh isKindOfClass:NSString.class]) config.refreshToken = refresh;
        if ([expiry isKindOfClass:NSString.class]) config.expiresAt = EBParseISODate(expiry);
    }
    return config;
}

static BOOL EBEnsurePrivateDirectory(NSString *directory, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *attributes = @{NSFilePosixPermissions: @0700};
    if (![manager createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:attributes
                                  error:error]) return NO;
    if (chmod(directory.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                 code:errno
                                             userInfo:@{NSFilePathErrorKey: directory}];
        return NO;
    }
    return YES;
}

static void EBConfigSetPOSIXError(NSError **error, NSString *path, int code) {
    if (!error) return;
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                              userInfo:@{NSFilePathErrorKey: path ?: @""}];
}

static BOOL EBWritePrivateFile(NSString *path, NSData *data, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSString *name = path.lastPathComponent;
    if (!directory.length || !name.length) {
        EBConfigSetPOSIXError(error, path, EINVAL);
        return NO;
    }
    NSString *templatePath = [directory stringByAppendingPathComponent:
                              [NSString stringWithFormat:@".%@.XXXXXX", name]];
    const char *templateFS = templatePath.fileSystemRepresentation;
    char *temporaryFS = templateFS ? strdup(templateFS) : NULL;
    if (!temporaryFS) {
        EBConfigSetPOSIXError(error, path, ENOMEM);
        return NO;
    }
    int fd = mkstemp(temporaryFS);
    if (fd < 0) {
        int code = errno;
        free(temporaryFS);
        EBConfigSetPOSIXError(error, path, code);
        return NO;
    }

    BOOL ok = fchmod(fd, S_IRUSR | S_IWUSR) == 0;
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        cursor += written;
        remaining -= (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    int failure = ok ? 0 : errno;
    if (close(fd) != 0 && ok) { ok = NO; failure = errno; }

    const char *destinationFS = path.fileSystemRepresentation;
    if (ok && destinationFS && rename(temporaryFS, destinationFS) == 0) {
        free(temporaryFS);
        return YES;
    }
    if (ok) failure = destinationFS ? errno : EINVAL;
    unlink(temporaryFS);
    free(temporaryFS);
    EBConfigSetPOSIXError(error, path, failure ? failure : EIO);
    return NO;
}

BOOL EBConfigSaveTokens(EBConfig *config, NSDictionary *response, NSError **error) {
    if (error) *error = nil;
    id authValue = response[@"AuthenticationResult"];
    if (![authValue isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"Energybar.Config" code:1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"Token response did not include AuthenticationResult"}];
        return NO;
    }
    NSDictionary *auth = authValue;
    id access = auth[@"AccessToken"];
    id refresh = auth[@"RefreshToken"];
    id idToken = auth[@"IdToken"];
    id expiresIn = auth[@"ExpiresIn"];
    if (![access isKindOfClass:NSString.class] || ![access length]) {
        if (error) *error = [NSError errorWithDomain:@"Energybar.Config" code:2
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"Token response was missing an access token"}];
        return NO;
    }
    NSString *newAccess = access;
    NSString *newRefresh = [refresh isKindOfClass:NSString.class] ? refresh : config.refreshToken;
    NSNumber *validExpiresIn = EBJSONFiniteNumber(expiresIn);
    if (!validExpiresIn || validExpiresIn.doubleValue <= 0) {
        if (error) *error = [NSError errorWithDomain:@"Energybar.Config" code:4
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"Token response had an invalid expiry"}];
        return NO;
    }
    NSDate *newExpiresAt = [NSDate dateWithTimeIntervalSinceNow:
                            MAX(0, validExpiresIn.doubleValue - 60)];
    if (!newRefresh.length) {
        if (error) *error = [NSError errorWithDomain:@"Energybar.Config" code:3
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"No refresh token is available to persist"}];
        return NO;
    }

    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    NSDictionary *output = @{
        @"access_token": newAccess,
        @"id_token": [idToken isKindOfClass:NSString.class] ? idToken : @"",
        @"refresh_token": newRefresh,
        @"expires_at": newExpiresAt ? [formatter stringFromDate:newExpiresAt] : @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    NSString *directory = config.tokenCachePath.stringByDeletingLastPathComponent;
    if (!EBEnsurePrivateDirectory(directory, error)) return NO;
    if (!EBWritePrivateFile(config.tokenCachePath, data, error)) return NO;
    config.accessToken = newAccess;
    config.refreshToken = newRefresh;
    config.expiresAt = newExpiresAt;
    return YES;
}
