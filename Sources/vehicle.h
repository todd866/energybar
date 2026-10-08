#import <Foundation/Foundation.h>
#import "soc.h"

NS_ASSUME_NONNULL_BEGIN

/// Vehicle battery / charge-readiness. Real SoC: OBD (preferred) or a
/// manufacturer API; otherwise inferred + manual.
@protocol EBVehicleProvider <NSObject>
- (BOOL)available;           // any user- or live-supplied fields
- (BOOL)hasSOC;
- (double)socPercent;        // 0…100 when hasSOC
- (BOOL)socIsEstimate;       // YES only when charge telemetry was integrated from an anchor
- (nullable NSDate *)socUpdatedAt;     // anchor/measurement time; required for unplug invalidation
- (nullable NSDate *)socInvalidatedAt; // latest known unplug tombstone, if any
- (BOOL)hasReady;
- (BOOL)readyToCharge;       // meaningful when hasReady
- (nullable NSDate *)readyUpdatedAt;
- (NSString *)statusLine;    // one-line for gear / dump — never a bare percentage alone when estimated
- (NSDictionary *)dictionaryValue; // for --dump --json
@end

/// Resolves SoC and readiness independently, taking the first provider with each
/// field in chain order. SoC values at/before the latest unplug tombstone are
/// ignored. A provider's continuity cutoff likewise suppresses older SoC without
/// suppressing readiness; a newer direct reading may establish a fresh anchor.
/// Returns a stub only when neither field is available; never returns nil.
id<EBVehicleProvider> EBResolveVehicle(NSArray<id<EBVehicleProvider>> *chain);

/// Persists SOC + ready flag to a JSON file (default ~/.config/energybar/vehicle.json).
@interface EBVehicleManualProvider : NSObject <EBVehicleProvider>
- (instancetype)initWithPath:(NSString *)path;
- (void)reload;
- (BOOL)setSOC:(double)percent; // clamps finite values to 0…100; rejects NaN/Inf
- (BOOL)setReady:(BOOL)ready;
/// Persist an unplug tombstone and remove only an older/undated SoC field.
/// Charge readiness is intentionally preserved. The safe in-memory invalidation
/// remains effective when persistence fails and is retried on a later mutation.
- (BOOL)invalidateSOCAt:(NSDate *)at;
- (BOOL)clear;
@property(readonly, copy, nullable) NSError *persistenceError;
@end

/// Anchor + charge integration. Persists anchors and unplug tombstones to
/// ~/.cache/energybar/vehicle.json. Anchors must come from manual, OBD, or live
/// readings; a solar pause is never treated as proof of a full battery.
/// Unavailable when EV_BATTERY_KWH is unset/zero, or when unplugged since the anchor.
@interface EBVehicleInferredProvider : NSObject <EBVehicleProvider>
- (instancetype)initWithPath:(NSString *)path
                  capacityWh:(double)capacityWh
                  efficiency:(double)efficiency;
- (BOOL)updateWithSamples:(NSArray<NSDictionary *> *)samples now:(NSDate *)now;
/// Session-aware update. See EBInferSoCWithSessions for the accepted record
/// fields. Session disconnect evidence is persisted as the same durable SoC
/// tombstone as a live unplug sample.
- (BOOL)updateWithSamples:(NSArray<NSDictionary *> *)samples
                 sessions:(NSArray<NSDictionary *> * _Nullable)sessions
                      now:(NSDate *)now;
/// Seed / replace the persisted anchor (e.g. after a manual entry while plugged).
/// EBSoCSourceNone and the legacy EBSoCSourceFullCharge are rejected.
- (BOOL)setAnchorPercent:(double)percent at:(NSDate *)at source:(EBSoCSource)source;
- (BOOL)clearAnchor;
/// Clear the inferred anchor and unplug tombstone, while retaining a private
/// history high-water mark so old samples cannot recreate the cleared state.
/// Use only after the manual store has been cleared, so a partial failure cannot
/// resurrect manual SoC.
- (BOOL)clearAllState;
@property(readonly) EBSoCEstimate estimate;
@property(readonly, copy, nullable) NSError *persistenceError;
@end

/// Seam for OBD-II / sidecar SoC. See docs/obd-dongle.md.
/// Cache: ~/.cache/energybar/obd.json mode 0600 —
/// `{ "soc", "at", "pid", "adapter" }`.
/// TODO(obd): parse cache + freshness (OBD_MAX_AGE_SECONDS); available when fresh.
/// TODO(obd): sidecar BLE/ELM poller writing that file; PID once Car Scanner proves SoC.
/// TODO(obd): poll only while Evnex reports plugged — never overnight idle.
/// A direct reading written by a local helper (an OBD dongle sidecar, or a vehicle-cloud
/// helper): JSON `{ "soc": 0…100, "at": ISO-8601 reading time, "checkedAt": ISO-8601 helper
/// run, "source": "cloud", "rangeKm": n, "error": "…" }`. Available only when `soc` is
/// present and the helper checked within maxAge; never invents a level from a stale file.
@interface EBVehicleOBDProvider : NSObject <EBVehicleProvider>
- (instancetype)initWithCachePath:(NSString *)path maxAgeSeconds:(NSTimeInterval)maxAge;
- (instancetype)initWithCachePath:(NSString *)path maxAgeSeconds:(NSTimeInterval)maxAge
                            label:(NSString *)label;
@property(readonly, nullable) NSString *lastError;
@property(readonly) double rangeKm;   // 0 = not reported
@end

/// Seam for a future manufacturer API client. available == NO until
/// VEHICLE_TOKEN_CACHE parses.
/// Token cache: ~/.cache/energybar/vehicle-token.json
/// `{ "access_token", "refresh_token", "expires_at", "vin" }` mode 0600.
@interface EBVehicleLiveProvider : NSObject <EBVehicleProvider>
- (instancetype)initWithTokenPath:(NSString *)path;
/// Live polls: ≤1 / 15 min, only while plugged; back off to 60 min on non-200;
/// stop after three consecutive failures until the next plug-in. Each status request
/// wakes the telematics unit — polling a parked car flattens the 12 V battery.
@end

/// Empty provider for tests that do not want persistence.
@interface EBVehicleStubProvider : NSObject <EBVehicleProvider>
@end

NS_ASSUME_NONNULL_END
