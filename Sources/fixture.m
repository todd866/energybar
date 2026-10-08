#import "fixture.h"
#import "parse.h"

static NSDictionary *EBFroniusFixture(NSDictionary *document) {
    double pvW = 0, eDayWh = 0;
    BOOL haveEDay = NO;
    if (!EBParseFroniusPowerFlowFields(document, &pvW, &eDayWh, &haveEDay)) return nil;
    NSMutableDictionary *site = [@{ @"P_PV": @(pvW) } mutableCopy];
    if (haveEDay) site[@"E_Day"] = @(eDayWh);
    return @{ @"Body": @{ @"Data": @{ @"Site": site } } };
}

static NSDictionary *EBStatusFixture(NSDictionary *document) {
    EBEvnexParsed *parsed = [EBEvnexParsed new];
    EBParseEvnexBundle(document, nil, nil, nil, parsed);
    if (!parsed.statusOK) return nil;
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    if (parsed.haveChargeNow) status[@"chargeNow"] = @(parsed.chargeNow);
    if (parsed.chargingLogic.length) status[@"chargingLogic"] = parsed.chargingLogic;
    if (parsed.chargingCurrentControl.length)
        status[@"chargingCurrentControl"] = parsed.chargingCurrentControl;
    return @{ @"data": @{ @"chargePointStatus": status } };
}

static NSDictionary *EBDetailFixture(NSDictionary *document) {
    EBEvnexParsed *parsed = [EBEvnexParsed new];
    EBParseEvnexBundle(nil, nil, document, nil, parsed);
    double supplyW = 0, chargeW = 0;
    NSDate *meterAt = nil;
    BOOL haveMeter = EBParseEvnexDetailMeter(
        document, nil, 0, &supplyW, &chargeW, &meterAt);
    if (!parsed.detailOK && !parsed.orgId.length && !haveMeter) return nil;

    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSMutableDictionary *connector = [NSMutableDictionary dictionary];
    if (parsed.haveOcppStatus) connector[@"ocppStatus"] = parsed.ocppStatus;
    if (haveMeter) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                  NSISO8601DateFormatWithFractionalSeconds;
        connector[@"meter"] = @{
            @"power": @(chargeW),
            @"supplyActivePower": @(supplyW),
            @"updatedDate": [formatter stringFromDate:meterAt],
        };
    }
    if (connector.count) attributes[@"connectors"] = @[connector];
    if (parsed.scheduleBehaviour.length) {
        attributes[@"chargingConfiguration"] = @{
            @"periods": @{ @"day": @[@{ @"behaviour": @{
                @"type": parsed.scheduleBehaviour,
            } }] },
        };
    }
    if (attributes.count) data[@"attributes"] = attributes;
    if (parsed.orgId.length) {
        data[@"relationships"] = @{
            @"organisation": @{ @"data": @{ @"id": @"fixture-redacted" } },
        };
    }
    return @{ @"data": data };
}

NSDictionary *EBFixtureProjection(NSString *name, NSDictionary *document) {
    if (![document isKindOfClass:NSDictionary.class]) return nil;
    if ([name isEqualToString:@"fronius_powerflow.json"]) return EBFroniusFixture(document);
    if ([name isEqualToString:@"evnex_status.json"]) return EBStatusFixture(document);
    if ([name isEqualToString:@"evnex_detail.json"]) return EBDetailFixture(document);
    return nil;
}
