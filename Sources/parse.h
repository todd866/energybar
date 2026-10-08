#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parse Fronius GetPowerFlowRealtimeData JSON. Returns YES if Site.P_PV present.
BOOL EBParseFroniusPowerFlow(NSDictionary * _Nullable json,
                             double * _Nullable outPvW,
                             double * _Nullable outEDayWh);

/// Availability-preserving variant. `outHaveEDay` is NO when PV is valid but
/// the optional cumulative-day field is absent or malformed.
BOOL EBParseFroniusPowerFlowFields(NSDictionary * _Nullable json,
                                   double * _Nullable outPvW,
                                   double * _Nullable outEDayWh,
                                   BOOL * _Nullable outHaveEDay);

@interface EBEvnexParsed : NSObject
@property BOOL ok;
@property BOOL statusOK;
@property BOOL meterOK;
@property BOOL detailOK;
@property double supplyW;
@property double chargeW;
@property(copy, nullable) NSString *ocppStatus;
@property(copy, nullable) NSString *chargingLogic;
@property(copy, nullable) NSString *chargingCurrentControl;
@property BOOL chargeNow;
@property BOOL haveChargeNow;
@property BOOL haveOcppStatus;
@property(copy, nullable) NSString *scheduleBehaviour;
@property(copy, nullable) NSString *orgId;
@end

/// Parse independent get-status + meter (+ optional detail/override) documents.
/// `statusOK` and `meterOK` remain independent so one useful source is not
/// discarded when the other changes shape or is unavailable.
BOOL EBParseEvnexBundle(NSDictionary * _Nullable statusJSON,
                        NSDictionary * _Nullable meterJSON,
                        NSDictionary * _Nullable detailJSON,
                        NSDictionary * _Nullable overrideJSON,
                        EBEvnexParsed *out);

/// Parse live meter telemetry embedded in the regular charge-point detail
/// document. `meter.updatedDate` is the sole freshness clock; older connector
/// or document timestamps are intentionally ignored. When `now` is nonnull the
/// sample must be no older than `maxAge` and no more than 60 seconds in the
/// future. Some chargers retain a positive meter power after disconnect, so car
/// power is reported as zero unless that same connector is OCPP `CHARGING`.
/// Passing `now == nil` validates shape and timestamp without applying an age
/// bound, which is useful only for sanitized fixture projection.
BOOL EBParseEvnexDetailMeter(NSDictionary * _Nullable detailJSON,
                             NSDate * _Nullable now,
                             NSTimeInterval maxAge,
                             double * _Nullable outSupplyW,
                             double * _Nullable outChargeW,
                             NSDate * _Nullable * _Nullable outUpdatedAt);

NS_ASSUME_NONNULL_END
