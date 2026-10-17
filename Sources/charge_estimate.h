#import <Foundation/Foundation.h>
#import "pure.h"

NS_ASSUME_NONNULL_BEGIN
/// Read-only current-rate projection. No PV/grid watts or charger controls enter this model.
@interface EBChargeInput : NSObject
@property(strong) NSDate *now;
@property BOOL hasSOC, socEstimated;
@property double soc, capacityWh, efficiency;
@property(copy, nullable) NSDate *socAt;
/// Zero means unknown vehicle limit: show a hypothetical full-pack projection.
@property double targetPercent;
@property EBChargerState state;
@property(copy, nullable) NSDate *statusAt;
@property BOOL meterAvailable, meterStale;
@property double wallW;
@property(copy, nullable) NSDate *meterAt;
@property(copy, nullable) NSString *vehicleIssue;
@end

@interface EBChargeEstimate : NSObject
@property(copy) NSString *state, *label, *detail;
@property double targetPercent, seconds, packW;
@property BOOL available, targetKnown, variablePower;
- (NSDictionary *)dictionaryValue;
@end

EBChargeEstimate *EBEstimateCharge(EBChargeInput *input, NSArray<NSDictionary *> *samples);
NSString *EBChargeDuration(double seconds);
NS_ASSUME_NONNULL_END
