#import <Foundation/Foundation.h>
#import "forecast.h"

NS_ASSUME_NONNULL_BEGIN
/// Private, bounded local learning ledger. All I/O belongs on EBStoreQueue.
/// Invalid/version/source-mismatched files are preserved, never silently reset.
NSDictionary * _Nullable EBLearningLoad(NSString *path, NSString *source, NSError **error);
BOOL EBLearningSave(NSString *path, NSDictionary *document, NSError **error);
NSDictionary * _Nullable EBLearningObserve(NSDictionary * _Nullable previous, NSString *source,
    NSArray<NSDictionary *> *measuredPV, NSArray<NSDictionary *> *sessions, NSDate *now, NSError **error);
/// Hourly measured means and independent coverage. Household residual uses only
/// overlapping measured PV/grid/charger intervals, never archive or forecast PV.
NSArray<NSDictionary *> *EBLearningHours(NSDictionary *statistics, NSDictionary *ledger, NSDate *now);
/// 28-day weekday/weekend-by-hour medians; 5 covered dates per bucket. Solar
/// calibration needs 12 previously issued, scored daylight hours on 3 dates.
NSDictionary *EBLearningModel(NSDictionary *statistics, NSDictionary *ledger, NSDate *now, NSTimeZone *zone);
/// Freeze the first next-full-hour vintage; append outcomes only after its end.
/// Existing predictions/outcomes are immutable. No retrospective weather backfill.
NSDictionary *EBLearningRecord(NSDictionary *ledger, NSDictionary *statistics,
    EBPowerForecast *forecast, NSDictionary *vehicleContext, NSDate *now);
NS_ASSUME_NONNULL_END
