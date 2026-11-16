#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import "climate.h"
#import "vehicle.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

static mode_t PermissionsAtPath(NSString *path) {
    struct stat info = {0};
    if (stat(path.fileSystemRepresentation, &info) != 0) return 0;
    return info.st_mode & 0777;
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"energybar-climate-%d", getpid()]];
        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        NSString *configDir = [root stringByAppendingPathComponent:@"config/energybar"];
        expect([[NSFileManager defaultManager] createDirectoryAtPath:configDir
                                        withIntermediateDirectories:YES attributes:nil error:nil],
               @"fixture directory");
        NSString *configPath = [configDir stringByAppendingPathComponent:@"climate.json"];

        NSDictionary *defaults = EBClimateDefaultConfig();
        expect([defaults[@"version"] isEqual:@1], @"default version");
        expect([[defaults[@"departure"][@"time"] description] isEqualToString:@"07:45"], @"default departure");
        expect([defaults[@"allDay"][@"dailyCapKWh"] doubleValue] == 1.5, @"default cap");

        NSDictionary *loaded = EBClimateLoadConfig(@"/no/such/file");
        expect([loaded[@"assumedKW"] doubleValue] == 2.0, @"missing file uses defaults");

        NSError *error = nil;
        NSMutableDictionary *custom = [EBClimateLoadConfig(configPath) mutableCopy];
        custom[@"experimentalFlag"] = @YES;
        custom[@"departure"] = [@{@"enabled": @YES, @"time": @"06:30", @"days": @[@1, @3, @5], @"targetC": @22} mutableCopy];
        expect(EBClimateSaveConfig(configPath, custom, &error) && error == nil, @"save custom config");
        expect(PermissionsAtPath(configPath) == 0600, @"climate.json is private");
        expect(PermissionsAtPath(configDir) == 0700, @"config directory is private");

        NSDictionary *roundTrip = EBClimateLoadConfig(configPath);
        expect([roundTrip[@"experimentalFlag"] boolValue], @"unknown keys preserved");
        expect([roundTrip[@"departure"][@"enabled"] boolValue], @"departure enabled round trip");
        expect([roundTrip[@"departure"][@"time"] isEqualToString:@"06:30"], @"departure time");
        expect([roundTrip[@"departure"][@"targetC"] doubleValue] == 22, @"departure target");

        NSDictionary *parsed = EBParseVehicleCloudClimate(@{
            @"interiorC": @"39.3",
            @"exteriorC": @"35.0",
            @"climateActive": @"true",
        });
        expect(fabs([parsed[@"interiorC"] doubleValue] - 39.3) < 0.001, @"interior string");
        expect(fabs([parsed[@"exteriorC"] doubleValue] - 35.0) < 0.001, @"exterior string");
        expect([parsed[@"climateActive"] boolValue], @"climate active string");

        NSDictionary *state = @{
            @"version": @1,
            @"todayKWh": @0.4,
            @"blocked": NSNull.null,
            @"next": @{@"at": @"2026-08-08T06:30:00+08:00", @"reason": @"departure"},
        };
        NSString *line = EBClimateStatusLine(state, roundTrip);
        expect([line containsString:@"0.4 of 1.5 kWh today"], @"status includes usage");
        expect([line containsString:@"departure"], @"status includes next reason");

        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        puts("ok: climate config");
    }
    return 0;
}