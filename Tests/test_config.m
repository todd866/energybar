#import <Foundation/Foundation.h>
#import <math.h>
#import <unistd.h>
#import "config.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"energybar-config-%d", getpid()]];
        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        expect([[NSFileManager defaultManager] createDirectoryAtPath:root
                                          withIntermediateDirectories:YES
                                                           attributes:nil error:nil], @"create fixture root");
        NSString *path = [root stringByAppendingPathComponent:@"parser.env"];
        NSString *fixture = @"# copied template\n"
                             " FRONIUS_LOCAL_IP = 192.168.1.50  # local inverter\n"
                             "FRONIUS_SOLAR_API=      # optional\n"
                             "EVNEX_CHARGE_POINT_ID='cp-123' # ignored after quote\n"
                             "URL=https://example.test/path#fragment\n"
                             "export EV_BATTERY_KWH=60\n"
                             "BAD KEY=value\n";
        expect([fixture writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],
               @"write env fixture");
        NSDictionary *values = EBParseEnvFile(path);
        expect([values[@"FRONIUS_LOCAL_IP"] isEqualToString:@"192.168.1.50"], @"trim value");
        expect([values[@"FRONIUS_SOLAR_API"] isEqualToString:@""], @"blank before comment");
        expect([values[@"EVNEX_CHARGE_POINT_ID"] isEqualToString:@"cp-123"], @"quoted value");
        expect([values[@"URL"] isEqualToString:@"https://example.test/path#fragment"], @"URL fragment");
        expect([values[@"EV_BATTERY_KWH"] isEqualToString:@"60"], @"export prefix");
        expect(values[@"BAD KEY"] == nil, @"reject invalid key");
        EBConfig *tokens = [EBConfig new];
        tokens.tokenCachePath = [root stringByAppendingPathComponent:@"private/tokens.json"];
        tokens.refreshToken = @"existing-refresh";
        NSError *error = nil;
        expect(EBConfigSaveTokens(tokens, @{ @"AuthenticationResult": @{
                    @"AccessToken": @"new-access", @"ExpiresIn": @3600 } }, &error),
               @"refresh response may reuse existing refresh token");
        NSDictionary *dirAttrs = [NSFileManager.defaultManager
                                   attributesOfItemAtPath:tokens.tokenCachePath.stringByDeletingLastPathComponent
                                   error:nil];
        NSDictionary *fileAttrs = [NSFileManager.defaultManager
                                    attributesOfItemAtPath:tokens.tokenCachePath error:nil];
        expect(([dirAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700,
               @"token directory is private");
        expect(([fileAttrs[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600,
               @"token file is private");
        expect(!EBConfigSaveTokens(tokens, @{ @"AuthenticationResult": @{
                    @"AccessToken": NSNull.null } }, &error),
               @"malformed refresh cannot reuse stale access token");
        expect(!EBConfigSaveTokens(tokens, @{ @"AuthenticationResult": @{
                    @"AccessToken": @"unsafe-access", @"ExpiresIn": @(INFINITY) } }, &error),
               @"non-finite token expiry is rejected");
        expect([tokens.accessToken isEqualToString:@"new-access"],
               @"failed token persistence leaves the live config unchanged");

        NSString *homeConfig = [root stringByAppendingPathComponent:@".config/energybar"];
        expect([NSFileManager.defaultManager createDirectoryAtPath:homeConfig
                                        withIntermediateDirectories:YES attributes:nil error:nil],
               @"create home config");
        NSString *homeEnv = [homeConfig stringByAppendingPathComponent:@".env"];
        expect([@"FRONIUS_LOCAL_IP=10.0.0.5\nENERGYBAR_BAR_TEXT=false\n"
                writeToFile:homeEnv atomically:YES encoding:NSUTF8StringEncoding error:nil],
               @"write home env");
        setenv("ENERGYBAR_HOME", root.UTF8String, 1);
        EBConfig *loaded = EBLoadConfig();
        expect([loaded.froniusAPI isEqualToString:@"http://10.0.0.5/solar_api"],
               @"local IP expands to API URL");
        expect(!loaded.barText, @"explicit false overrides defaults");
        expect(loaded.tariff == nil && loaded.tariffError == nil,
               @"missing tariff is unavailable, not a zero-price default");
        NSString *tariffPath = [homeConfig stringByAppendingPathComponent:@"tariff.json"];
        expect([loaded.tariffPath isEqualToString:tariffPath], @"tariff follows configured home");
        expect([@"{broken" writeToFile:tariffPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
               @"write malformed tariff");
        EBConfig *badTariff = EBLoadConfig();
        expect(badTariff.tariff == nil && badTariff.tariffError.length > 0,
               @"invalid tariff is surfaced without breaking meter configuration");
        [[NSFileManager defaultManager] removeItemAtPath:tariffPath error:nil];
        expect([loaded.sessionsPath isEqualToString:
                [root stringByAppendingPathComponent:@".cache/energybar/sessions.json"]],
               @"session backfill cache follows configured home");
        expect([loaded.froniusArchivePath isEqualToString:
                [root stringByAppendingPathComponent:@".cache/energybar/fronius-pv.json"]],
               @"Fronius archive cache follows configured home");
        setenv("EV_BATTERY_KWH", "nan", 1);
        setenv("EV_CHARGE_EFFICIENCY", "0.9junk", 1);
        setenv("OBD_MAX_AGE_SECONDS", "inf", 1);
        EBConfig *invalidNumbers = EBLoadConfig();
        expect(invalidNumbers.evBatteryWh == 0, @"non-finite capacity is rejected");
        expect(invalidNumbers.evChargeEfficiency == 0.90,
               @"partially numeric efficiency is rejected");
        expect(invalidNumbers.obdMaxAgeSeconds == 900,
               @"non-finite cache age is rejected");
        unsetenv("EV_BATTERY_KWH");
        unsetenv("EV_CHARGE_EFFICIENCY");
        unsetenv("OBD_MAX_AGE_SECONDS");
        unsetenv("ENERGYBAR_HOME");

        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        puts("ok: config parsing");
    }
    return 0;
}
