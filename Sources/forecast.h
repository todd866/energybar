#import <Foundation/Foundation.h>
#import "charge_estimate.h"

NS_ASSUME_NONNULL_BEGIN
@interface EBPowerForecastInput : NSObject
@property(strong) NSDate *now;
@property(copy) NSArray<NSDictionary *> *solarSamples;
@property(copy) NSArray<NSDictionary *> *meterSamples;
@property(copy, nullable) NSDictionary *weather;
@property double inverterW, chargerW;
@property EBChargerState chargerState;
@property(copy, nullable) NSDate *chargerStatusAt;
@property(strong) EBChargeEstimate *chargeEstimate;
@end
@interface EBPowerForecast : NSObject
@property(copy) NSArray<NSDictionary *> *rows;
@property(copy) NSString *detail;
@property(copy, nullable) NSDate *asOf, *weatherFetchedAt, *carFinishesAt;
@property BOOL available;
@end
/// No I/O. Hourly radiation means cover the preceding hour; no future data becomes actual.
EBPowerForecast *EBBuildPowerForecast(EBPowerForecastInput *input);
/// Power averaged over the exact overlap with the current-rate charging interval.
double EBForecastCarMeanW(double chargerW, NSDate *now, NSDate *finish, NSDate *start, NSDate *end);
/// Every output conserves PV + import = home excluding car + car + export.
NSDictionary * _Nullable EBForecastBalance(double pvW, double homeW, double carW);
/// Weighted average of complete forecast coverage only; partial/missing means unavailable.
NSDictionary * _Nullable EBForecastAverage(NSArray<NSDictionary *> *rows, NSDate *start, NSDate *end);
NS_ASSUME_NONNULL_END

/// Fixed-provider, rounded-location request. Nil unless explicit ongoing consent is present.
NSURL * _Nullable EBForecastRequestURL(NSDictionary * _Nullable settings);
