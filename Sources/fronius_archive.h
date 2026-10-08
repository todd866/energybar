#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EBFroniusArchiveErrorDomain;
FOUNDATION_EXPORT const NSTimeInterval EBFroniusArchiveRetentionSeconds;

typedef NS_ENUM(NSInteger, EBFroniusArchiveErrorCode) {
    EBFroniusArchiveErrorInvalidResponse = 1,
    EBFroniusArchiveErrorDeviceStatus = 2,
    EBFroniusArchiveErrorInvalidRecord = 3,
    EBFroniusArchiveErrorCacheIO = 4,
    EBFroniusArchiveErrorCorruptCache = 5,
    EBFroniusArchiveErrorUnsupported = 6,
    EBFroniusArchiveErrorSourceMismatch = 7,
};

/// One exact PV-energy record returned by GetArchiveData.cgi.
///
/// `anchor` is `Body.Data.<inverter>.Start` plus the numeric Values key. Fronius
/// documents the key as a timestamp offset but does not document whether the
/// energy interval precedes or follows that anchor, so no start/end timestamps
/// are invented here. `spanSeconds` and `energyWh` are the logger's exact
/// TimeSpanInSec and EnergyReal_WAC_Sum_Produced values.
@interface EBFroniusPVInterval : NSObject

- (nullable instancetype)initWithDeviceID:(NSString *)deviceID
                                deviceType:(nullable NSNumber *)deviceType
                                    anchor:(NSDate *)anchor
                               spanSeconds:(NSTimeInterval)spanSeconds
                                  energyWh:(double)energyWh NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly, copy) NSString *deviceID;
@property(nonatomic, readonly, copy, nullable) NSNumber *deviceType;
@property(nonatomic, readonly, copy) NSDate *anchor;
@property(nonatomic, readonly) NSTimeInterval spanSeconds;
@property(nonatomic, readonly) double energyWh;

@end

/// Sum of known per-device interval records whose anchors fall in a half-open
/// window. `recordedDeviceSeconds` deliberately counts device-interval seconds;
/// it is wall-clock coverage only for a single-inverter installation. Callers
/// must verify the expected inverter set before presenting a site-wide total.
typedef struct {
    double energyWh;
    NSTimeInterval recordedDeviceSeconds;
    NSUInteger intervalCount;
    NSUInteger deviceCount;
    BOOL hasData;
} EBFroniusPVArchiveSummary;

/// Parse a successful GetArchiveData.cgi response. Only inverter records from
/// EnergyReal_WAC_Sum_Produced + TimeSpanInSec are accepted. JSON null energy
/// values are unavailable datapoints and are omitted, never converted to zero.
/// HTTP success is not sufficient: Head.Status.Code must be zero and the
/// echoed Head.RequestArguments.SeriesType must be Detail.
FOUNDATION_EXPORT NSArray<EBFroniusPVInterval *> * _Nullable
EBFroniusArchiveParsePVIntervals(NSDictionary *response, NSError **error);

/// Load a source-scoped private cache. A missing file is an empty cache; an
/// existing malformed file or mismatched sourceID is an error and is never
/// silently discarded.
FOUNDATION_EXPORT NSArray<EBFroniusPVInterval *> * _Nullable
EBFroniusArchiveLoadPVCache(NSString *path,
                            NSString *sourceID,
                            NSDate *now,
                            NSError **error);

/// Atomically merge records into a source-scoped cache. sourceID must be an
/// opaque, stable identifier for the configured Fronius system; it is persisted
/// so a changed source cannot inherit another system's history. Identity within
/// that source is (deviceID, anchor); a later fetch replaces the same interval.
/// The canonical merged array is sorted, deduplicated, retained for exactly 48
/// hours by anchor, and written mode 0600 in a mode-0700 directory. Callers must
/// serialize operations for a given path.
FOUNDATION_EXPORT NSArray<EBFroniusPVInterval *> * _Nullable
EBFroniusArchiveMergePVCache(NSString *path,
                             NSString *sourceID,
                             NSArray<EBFroniusPVInterval *> *intervals,
                             NSDate *now,
                             NSError **error);

/// Sum only whole, exact archive intervals guaranteed to fall inside the window
/// whether Fronius's undocumented anchor is the interval start or end. Boundary
/// intervals are omitted rather than clipped or attributed to the wrong day, so
/// the result is a trustworthy lower bound for that window.
FOUNDATION_EXPORT EBFroniusPVArchiveSummary
EBFroniusArchiveSummarizePV(NSArray<EBFroniusPVInterval *> *intervals,
                            NSDate *start,
                            NSDate *end);

NS_ASSUME_NONNULL_END
