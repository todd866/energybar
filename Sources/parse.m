#import "parse.h"
#import <math.h>

@implementation EBEvnexParsed
@end

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

static NSNumber *EBBoolean(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? value : nil;
}

static NSDate *EBISODate(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *whole;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                   NSISO8601DateFormatWithFractionalSeconds;
        whole = [NSISO8601DateFormatter new];
        whole.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fractional dateFromString:value] ?: [whole dateFromString:value];
}

BOOL EBParseFroniusPowerFlowFields(NSDictionary *json, double *outPvW,
                                   double *outEDayWh, BOOL *outHaveEDay) {
    NSDictionary *root = EBDictionary(json);
    NSDictionary *body = EBDictionary(root[@"Body"]);
    NSDictionary *data = EBDictionary(body[@"Data"]);
    NSDictionary *site = EBDictionary(data[@"Site"]);
    NSNumber *pv = EBFiniteNumber(site[@"P_PV"]);
    // A sleeping inverter (night) answers Status 0 with P_PV null but each inverter's P = 0.
    // P_PV is the inverters' sum, so take it from them; a bare null is still unavailable.
    NSDictionary *inverters = EBDictionary(data[@"Inverters"]);
    NSNumber *code = EBFiniteNumber(EBDictionary(EBDictionary(root[@"Head"])[@"Status"])[@"Code"]);
    if (!pv && inverters.count && code && code.doubleValue == 0) {
        double sum = 0;
        for (id inv in inverters.allValues) {
            NSNumber *p = EBFiniteNumber(EBDictionary(inv)[@"P"]);
            if (!p) { sum = NAN; break; }
            sum += p.doubleValue;
        }
        if (isfinite(sum)) pv = @(sum);
    }
    if (!pv) return NO;
    NSNumber *day = EBFiniteNumber(site[@"E_Day"]);
    if (outPvW) *outPvW = pv.doubleValue;
    if (outEDayWh) *outEDayWh = day ? day.doubleValue : 0;
    if (outHaveEDay) *outHaveEDay = day != nil;
    return YES;
}

BOOL EBParseFroniusPowerFlow(NSDictionary *json, double *outPvW, double *outEDayWh) {
    return EBParseFroniusPowerFlowFields(json, outPvW, outEDayWh, nil);
}

BOOL EBParseEvnexBundle(NSDictionary *statusJSON,
                        NSDictionary *meterJSON,
                        NSDictionary *detailJSON,
                        NSDictionary *overrideJSON,
                        EBEvnexParsed *out) {
    if (!out) return NO;
    out.ok = NO;
    out.statusOK = NO;
    out.meterOK = NO;
    out.detailOK = NO;
    out.haveOcppStatus = NO;
    out.ocppStatus = nil;
    out.chargingLogic = nil;
    out.chargingCurrentControl = nil;
    out.scheduleBehaviour = nil;
    out.orgId = nil;
    out.chargeNow = NO;
    out.haveChargeNow = NO;

    NSDictionary *statusRoot = EBDictionary(statusJSON);
    NSDictionary *statusData = EBDictionary(statusRoot[@"data"]);
    NSDictionary *cps = EBDictionary(statusData[@"chargePointStatus"]);
    if (cps) {
        out.statusOK = YES;
        out.chargingLogic = EBString(cps[@"chargingLogic"]);
        out.chargingCurrentControl = EBString(cps[@"chargingCurrentControl"]);
        NSNumber *chargeNow = EBBoolean(cps[@"chargeNow"]);
        if (chargeNow) {
            out.chargeNow = chargeNow.boolValue;
            out.haveChargeNow = YES;
        }
    }

    NSDictionary *overrideRoot = EBDictionary(overrideJSON);
    NSNumber *overrideChargeNow = EBBoolean(overrideRoot[@"chargeNow"]);
    if (overrideChargeNow) {
        out.chargeNow = overrideChargeNow.boolValue;
        out.haveChargeNow = YES;
    }

    NSDictionary *meterRoot = EBDictionary(meterJSON);
    NSDictionary *meter = EBDictionary(meterRoot[@"data"]);
    NSNumber *supply = EBFiniteNumber(meter[@"supplyActivePower"]);
    NSNumber *charge = EBFiniteNumber(meter[@"chargingActivePower"]);
    if (supply && charge) {
        out.meterOK = YES;
        out.supplyW = supply.doubleValue;
        out.chargeW = charge.doubleValue;
    }

    NSDictionary *detailRoot = EBDictionary(detailJSON);
    NSDictionary *detailData = EBDictionary(detailRoot[@"data"]);
    NSDictionary *attributes = EBDictionary(detailData[@"attributes"]);
    if (attributes) out.detailOK = YES;
    NSArray *connectors = EBArray(attributes[@"connectors"]);
    if (connectors.count) {
        NSDictionary *connector = EBDictionary(connectors.firstObject);
        NSString *status = EBString(connector[@"ocppStatus"]);
        if (status.length) {
            out.ocppStatus = status;
            out.haveOcppStatus = YES;
        }
    }
    NSDictionary *configuration = EBDictionary(attributes[@"chargingConfiguration"]);
    NSDictionary *periods = EBDictionary(configuration[@"periods"]);
    NSArray *day = EBArray(periods[@"day"]);
    NSDictionary *firstPeriod = day.count ? EBDictionary(day.firstObject) : nil;
    NSDictionary *behaviour = EBDictionary(firstPeriod[@"behaviour"]);
    out.scheduleBehaviour = EBString(behaviour[@"type"]);

    NSDictionary *relationships = EBDictionary(detailData[@"relationships"]);
    NSDictionary *organisation = EBDictionary(relationships[@"organisation"]);
    NSDictionary *organisationData = EBDictionary(organisation[@"data"]);
    out.orgId = EBString(organisationData[@"id"]);

    out.ok = out.statusOK || out.meterOK;
    return out.ok;
}

BOOL EBParseEvnexDetailMeter(NSDictionary *detailJSON,
                             NSDate *now,
                             NSTimeInterval maxAge,
                             double *outSupplyW,
                             double *outChargeW,
                             NSDate **outUpdatedAt) {
    if (now && (!isfinite(maxAge) || maxAge < 0)) return NO;
    NSDictionary *root = EBDictionary(detailJSON);
    NSDictionary *data = EBDictionary(root[@"data"]);
    NSDictionary *attributes = EBDictionary(data[@"attributes"]);
    NSArray *connectors = EBArray(attributes[@"connectors"]);
    for (id value in connectors) {
        NSDictionary *connector = EBDictionary(value);
        NSDictionary *meter = EBDictionary(connector[@"meter"]);
        NSNumber *supply = EBFiniteNumber(meter[@"supplyActivePower"]);
        NSNumber *power = EBFiniteNumber(meter[@"power"]);
        NSDate *updatedAt = EBISODate(meter[@"updatedDate"]);
        if (!supply || !power || !updatedAt) continue;
        if (now) {
            NSTimeInterval age = [now timeIntervalSinceDate:updatedAt];
            if (!isfinite(age) || age > maxAge || age < -60.0) continue;
        }
        NSString *ocpp = EBString(connector[@"ocppStatus"]);
        BOOL charging = ocpp.length &&
            [ocpp caseInsensitiveCompare:@"CHARGING"] == NSOrderedSame;
        if (outSupplyW) *outSupplyW = supply.doubleValue;
        if (outChargeW) *outChargeW = charging ? power.doubleValue : 0.0;
        if (outUpdatedAt) *outUpdatedAt = updatedAt;
        return YES;
    }
    return NO;
}
