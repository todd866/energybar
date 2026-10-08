#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sanitized Evnex session record keys. Dates are NSDate instances in memory;
/// the private cache serializes them as ISO-8601 strings.
extern NSString * const EBSessionIDKey;
extern NSString * const EBSessionChargeStartKey;
extern NSString * const EBSessionChargeEndKey;
extern NSString * const EBSessionEnergyWhKey;
extern NSString * const EBSessionDisconnectedAtKey;
extern NSString * const EBSessionActiveKey;

@interface EBSessionHistory : NSObject
@property(copy) NSArray<NSDictionary *> *sessions;
@property(copy, nullable) NSDate *fetchedAt;
/// Charge-point identity that supplied this complete list.
@property(copy, nullable) NSString *sourceID;
/// NO when a malformed in-retention row means an absent session cannot safely
/// be interpreted as zero energy.
@property BOOL complete;
/// YES only when the session-list endpoint supplied this complete snapshot.
/// A cache loaded from disk remains available but is stale until refreshed.
@property BOOL current;
@end

/// Parse the residential Evnex `GET /charge-points/{id}/sessions` response.
/// Malformed sessions are dropped field-by-field: a trustworthy disconnect can
/// survive an unusable energy total, and vice versa. Returned rows are sorted.
NSArray<NSDictionary *> *EBParseEvnexSessions(NSDictionary *document,
                                               NSDate *fetchedAt,
                                               NSTimeInterval maxAgeSeconds,
                                               BOOL * _Nullable complete);

/// Atomically persist/load a sanitized private cache (0600 file; a newly-created
/// parent is 0700). Cache writes replace the complete server snapshot and are
/// therefore naturally idempotent.
BOOL EBSessionCacheSave(NSString *path, EBSessionHistory *history,
                        NSError * _Nullable * _Nullable error);
EBSessionHistory *EBSessionCacheLoad(NSString *path, NSString *sourceID,
                                     NSTimeInterval maxAgeSeconds,
                                     NSError * _Nullable * _Nullable error);
BOOL EBSessionCacheSecureExistingFile(NSString *path);

typedef struct {
    double energyWh;
    NSUInteger sessionCount;
    /// NO when a session crosses a window boundary or lacks trustworthy energy.
    BOOL exact;
} EBSessionEnergySummary;

/// Sum exact session-register deltas wholly contained in [since, through].
/// Callers choose `through` (normally the history fetchedAt), so stale cached
/// totals are never presented as current. No power curve is synthesized.
EBSessionEnergySummary EBSessionEnergyInWindow(NSArray<NSDictionary *> *sessions,
                                                NSDate *since, NSDate *through);

NS_ASSUME_NONNULL_END
