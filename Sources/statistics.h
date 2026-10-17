#import <Foundation/Foundation.h>
#import "fronius_archive.h"

NS_ASSUME_NONNULL_BEGIN

/// Local measured history only. No forecast, account, location or vehicle fields.
/// Retains 90 days and at most 50,000 records per source series (16 MiB file limit).
extern const NSTimeInterval EBStatisticsRetention;
extern const NSUInteger EBStatisticsRecordLimit;

@interface EBStatisticsReport : NSObject
@property(copy) NSArray<NSDictionary *> *days;
@property(copy) NSArray<NSDictionary *> *weeks;
@property(copy) NSDate *asOf;
@property(copy) NSString *timeZoneName;
@property(copy, nullable) NSString *error;
@end

/// Pure, idempotent merge. Samples use NSDate t and optional supplyW/chargeW;
/// missing fields break that series. Status-only checkpoints are excluded.
NSDictionary * _Nullable EBStatisticsMerge(NSDictionary * _Nullable previous,
    NSString *sourceID, NSArray<NSDictionary *> *samples,
    NSArray<EBFroniusPVInterval *> *solar, NSDate *now, NSError **error);

/// Serial background queue only. Invalid/mismatched history is preserved and
/// reported, never overwritten. Writes use 0600 + atomic rename and directory fsync.
NSDictionary * _Nullable EBStatisticsUpdate(NSString *path, NSString *sourceID,
    NSArray<NSDictionary *> *samples, NSArray<EBFroniusPVInterval *> *solar,
    NSDate *now, NSError **error);

/// All 90 calendar-day bins, newest first; ISO Monday weeks, also newest first.
/// Interval integration clips at local midnight (including DST), keeps gross
/// import/export separate, and never extends a reading past its final endpoint.
EBStatisticsReport *EBStatisticsSummarize(NSDictionary *document, NSDate *now,
                                         NSTimeZone *timeZone);
NS_ASSUME_NONNULL_END
