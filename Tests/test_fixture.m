#import <Foundation/Foundation.h>
#import "fixture.h"
#import "parse.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

static BOOL Contains(NSDictionary *document, NSString *needle) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [json containsString:needle];
}

int main(void) {
    @autoreleasepool {
        NSDictionary *fronius = EBFixtureProjection(@"fronius_powerflow.json", @{
            @"Body": @{ @"Data": @{ @"Site": @{
                @"P_PV": @1234, @"E_Day": @5678, @"serial": @"private-serial",
            } } }, @"accessToken": @"private-token",
        });
        expect(fronius != nil && !Contains(fronius, @"private"),
               @"Fronius projection is allowlisted");
        NSDictionary *froniusWithoutDay = EBFixtureProjection(@"fronius_powerflow.json", @{
            @"Body": @{ @"Data": @{ @"Site": @{ @"P_PV": @1234 } } },
        });
        expect(froniusWithoutDay != nil && !Contains(froniusWithoutDay, @"E_Day"),
               @"missing Fronius day energy stays absent in projected fixtures");

        NSDictionary *status = EBFixtureProjection(@"evnex_status.json", @{
            @"data": @{ @"chargePointStatus": @{
                @"chargingLogic": @"Transfer", @"chargingCurrentControl": @"SolarControl",
                @"chargeNow": @NO, @"customerEmail": @"private@example.test",
            } },
        });
        NSDictionary *statusWithoutChargeNow = EBFixtureProjection(@"evnex_status.json", @{
            @"data": @{ @"chargePointStatus": @{ @"chargingLogic": @"Transfer" } },
        });
        expect(statusWithoutChargeNow != nil &&
               !Contains(statusWithoutChargeNow, @"chargeNow"),
               @"missing charge-now state stays absent in projected fixtures");
        NSDictionary *detail = EBFixtureProjection(@"evnex_detail.json", @{
            @"data": @{
                @"attributes": @{
                    @"connectors": @[@{ @"ocppStatus": @"CHARGING",
                                          @"meter": @{
                                              @"power": @900,
                                              @"supplyActivePower": @-100,
                                              @"updatedDate": @"2026-01-15T04:00:00.000Z",
                                              @"wifiPassword": @"private-password",
                                          },
                                          @"serialNumber": @"private-serial" }],
                    @"chargingConfiguration": @{ @"periods": @{ @"day": @[
                        @{ @"behaviour": @{ @"type": @"Solar" } }
                    ] } },
                },
                @"relationships": @{ @"organisation": @{ @"data": @{
                    @"id": @"private-org", @"name": @"Private Household",
                } } },
            },
        });
        for (NSDictionary *projection in @[status, detail])
            expect(projection != nil && !Contains(projection, @"private"),
                   @"Evnex projection drops all unapproved live values");
        expect(Contains(detail, @"fixture-redacted"), @"organisation ID is replaced");

        EBEvnexParsed *roundTrip = [EBEvnexParsed new];
        expect(EBParseEvnexBundle(status, nil, detail, nil, roundTrip),
               @"projected fixtures remain parseable");
        double supplyW = 0, chargeW = 0;
        NSDate *meterAt = nil;
        expect(EBParseEvnexDetailMeter(detail, nil, 0, &supplyW, &chargeW, &meterAt),
               @"projected detail preserves meter telemetry");
        expect(roundTrip.statusOK && roundTrip.haveOcppStatus &&
               supplyW == -100 && chargeW == 900 && meterAt != nil,
               @"projected fixture preserves telemetry fields");
        expect([roundTrip.orgId isEqualToString:@"fixture-redacted"],
               @"projected fixture preserves a non-sensitive organisation seam");
        expect(EBFixtureProjection(@"unknown.json", @{}) == nil,
               @"unknown fixture types are rejected");
        puts("ok: fixture projection");
    }
    return 0;
}
