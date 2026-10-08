#import <Foundation/Foundation.h>
#import "parse.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

int main(void) {
    @autoreleasepool {
        double pv = -1, day = -1;
        expect(!EBParseFroniusPowerFlow(@{@"Body": NSNull.null}, &pv, &day),
               @"Fronius null container rejected");
        expect(!EBParseFroniusPowerFlow(@{@"Body": @{@"Data": @{@"Site": @{@"P_PV": NSNull.null}}}},
                                        &pv, &day), @"Fronius null number rejected");
        // Captured 2026-10-06 21:38: inverter asleep after sunset.
        NSDictionary *night = @{@"Head": @{@"Status": @{@"Code": @0}},
            @"Body": @{@"Data": @{@"Inverters": @{@"1": @{@"P": @0, @"E_Day": @25401}},
                                  @"Site": @{@"P_PV": NSNull.null, @"E_Day": @25401}}}};
        BOOL nightDay = NO;
        expect(EBParseFroniusPowerFlowFields(night, &pv, &day, &nightDay) && pv == 0 &&
               day == 25401 && nightDay, @"sleeping inverter reads 0 W with its day total");
        NSMutableDictionary *badNight = [night mutableCopy];
        badNight[@"Head"] = @{@"Status": @{@"Code": @255}};
        expect(!EBParseFroniusPowerFlow(badNight, &pv, &day), @"error status is not 0 W");
        NSDictionary *noInverterP = @{@"Head": @{@"Status": @{@"Code": @0}},
            @"Body": @{@"Data": @{@"Inverters": @{@"1": @{@"P": NSNull.null}},
                                  @"Site": @{@"P_PV": NSNull.null}}}};
        expect(!EBParseFroniusPowerFlow(noInverterP, &pv, &day), @"unknown inverter power stays unavailable");
        BOOL haveDay = YES;
        expect(EBParseFroniusPowerFlowFields(
                   @{@"Body": @{@"Data": @{@"Site": @{@"P_PV": @1200}}}},
                   &pv, &day, &haveDay), @"Fronius optional day");
        expect(pv == 1200 && day == 0, @"Fronius values parsed");
        expect(!haveDay, @"missing cumulative day stays unavailable");
        expect(!EBParseFroniusPowerFlow(
                   @{@"Body": @{@"Data": @{@"Site": @{@"P_PV": @YES}}}},
                   &pv, &day), @"boolean PV is not accepted as one watt");
        expect(!EBParseFroniusPowerFlow(
                   @{@"Body": @{@"Data": @{@"Site": @{@"P_PV": @(INFINITY)}}}},
                   &pv, &day), @"non-finite PV is rejected");

        EBEvnexParsed *partial = [EBEvnexParsed new];
        NSDictionary *meter = @{@"data": @{@"supplyActivePower": @-200,
                                             @"chargingActivePower": @800}};
        expect(EBParseEvnexBundle(@{@"data": NSNull.null}, meter, nil, nil, partial),
               @"valid meter survives invalid status");
        expect(!partial.statusOK && partial.meterOK && partial.supplyW == -200,
               @"partial availability exposed");

        EBEvnexParsed *override = [EBEvnexParsed new];
        NSDictionary *status = @{@"data": @{@"chargePointStatus": @{@"chargeNow": @YES}}};
        expect(EBParseEvnexBundle(status, nil, nil, @{@"chargeNow": @NO}, override),
               @"status parses");
        expect(!override.chargeNow, @"explicit false override replaces stale true");
        expect(override.haveChargeNow, @"explicit false retains boolean provenance");

        EBEvnexParsed *missingBoolean = [EBEvnexParsed new];
        expect(EBParseEvnexBundle(@{@"data": @{@"chargePointStatus": @{
                    @"chargingLogic": @"Transfer"}}}, nil, nil, nil, missingBoolean),
               @"status can be partially available");
        expect(!missingBoolean.haveChargeNow,
               @"missing chargeNow stays unavailable rather than false");
        EBEvnexParsed *wrongBoolean = [EBEvnexParsed new];
        expect(EBParseEvnexBundle(@{@"data": @{@"chargePointStatus": @{
                    @"chargeNow": @1}}}, nil, nil, nil, wrongBoolean),
               @"status remains partially available with malformed boolean");
        expect(!wrongBoolean.haveChargeNow,
               @"numeric chargeNow is not treated as a trustworthy boolean");

        EBEvnexParsed *badMeterNumber = [EBEvnexParsed new];
        expect(!EBParseEvnexBundle(nil, @{@"data": @{
                    @"supplyActivePower": @YES, @"chargingActivePower": @800}},
                                   nil, nil, badMeterNumber),
               @"boolean meter values are rejected");

        NSDate *detailNow = [NSDate dateWithTimeIntervalSince1970:1700000000];
        NSDictionary *(^detailMeter)(NSString *, NSString *, id, id) =
            ^NSDictionary *(NSString *meterDate, NSString *ocpp, id supply, id power) {
                NSMutableDictionary *meterFields = [@{
                    @"supplyActivePower": supply,
                    @"power": power,
                } mutableCopy];
                if (meterDate) meterFields[@"updatedDate"] = meterDate;
                return @{@"data": @{@"attributes": @{
                    @"updatedDate": @"2020-01-01T00:00:00Z",
                    @"connectors": @[@{
                        @"updatedDate": @"2020-01-01T00:00:00Z",
                        @"ocppStatus": ocpp,
                        @"meter": meterFields,
                    }],
                }}};
            };
        double detailSupply = 0, detailCharge = 0;
        NSDate *detailAt = nil;
        NSDictionary *freshDetail = detailMeter(
            @"2023-11-14T22:12:50.000Z", @"CHARGING", @-250, @1800);
        expect(EBParseEvnexDetailMeter(freshDetail, detailNow, 90,
                                        &detailSupply, &detailCharge, &detailAt),
               @"fresh detail meter is accepted");
        expect(detailSupply == -250 && detailCharge == 1800 && detailAt != nil,
               @"detail meter preserves watt units and meter timestamp");
        expect(!EBParseEvnexDetailMeter(
                   detailMeter(@"2023-11-14T22:10:00.000Z", @"CHARGING", @-250, @1800),
                   detailNow, 90, nil, nil, nil),
               @"stale detail meter is rejected using meter.updatedDate");
        expect(!EBParseEvnexDetailMeter(
                   detailMeter(@"2023-11-14T22:15:00.000Z", @"CHARGING", @-250, @1800),
                   detailNow, 90, nil, nil, nil),
               @"implausibly future detail meter is rejected");
        expect(!EBParseEvnexDetailMeter(
                   detailMeter(nil, @"CHARGING", @-250, @1800),
                   detailNow, 90, nil, nil, nil),
               @"missing meter timestamp cannot borrow stale container timestamps");
        expect(!EBParseEvnexDetailMeter(
                   detailMeter(@"2023-11-14T22:12:50.000Z", @"CHARGING", @YES, @1800),
                   detailNow, 90, nil, nil, nil),
               @"boolean detail meter values are rejected");
        NSDictionary *waitingDetail = detailMeter(
            @"2023-11-14T22:12:50.000Z", @"SUSPENDED_EV", @400, @1800);
        expect(EBParseEvnexDetailMeter(waitingDetail, detailNow, 90,
                                        &detailSupply, &detailCharge, nil) &&
               detailSupply == 400 && detailCharge == 0,
               @"lingering car power is zero unless connector is charging");
        expect(EBParseEvnexDetailMeter(
                   detailMeter(@"2023-11-14T22:12:50.000Z", @"", @400, @1800),
                   detailNow, 90, &detailSupply, &detailCharge, nil) &&
               detailCharge == 0,
               @"missing OCPP charging proof cannot expose lingering car power");

        EBEvnexParsed *malformed = [EBEvnexParsed new];
        expect(!EBParseEvnexBundle(@{@"data": @[]}, @{@"data": @{@"supplyActivePower": NSNull.null,
                                                                   @"chargingActivePower": @1}},
                                   @{@"data": @{@"attributes": @{@"connectors": @[NSNull.null]}}},
                                   nil, malformed), @"malformed bundle rejected without exception");
        puts("ok: parser hardening");
    }
    return 0;
}
