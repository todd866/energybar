#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EBSoCSource) {
    EBSoCSourceNone = 0,   // no valid anchor — we do not know
    EBSoCSourceManual,     // user typed it
    EBSoCSourceFullCharge, // legacy persisted value; no longer accepted as an anchor
    EBSoCSourceLive,       // from the vehicle API (not produced by this function)
    EBSoCSourceOBD,        // from OBD-II dongle / sidecar cache (not produced by EBInferSoC)
};

typedef NS_ENUM(NSInteger, EBSoCUnknownReason) {
    EBSoCUnknownReasonNone = 0,
    /// Charger observations did not continuously cover anchor → evaluation time.
    EBSoCUnknownReasonTelemetryGap,
};

typedef struct {
    BOOL known;
    double percent;          // 0…100, valid only when known
    EBSoCSource source;      // provenance of the ANCHOR, not of the estimate
    NSTimeInterval anchorAge; // seconds since the anchor was established
    double addedWh;          // energy delivered since the anchor
    double exactSessionWh;   // part of addedWh supplied by exact session totals
    BOOL usedExactSessionEnergy;
    BOOL continuityUnknown;
    EBSoCUnknownReason unknownReason;
    /// Conservative cutoff after which a fresh direct reading may recover SoC,
    /// expressed as Unix epoch seconds.
    NSTimeInterval continuityUnknownAt;
    /// Actual unsupported duration from the evidence frontier through the
    /// evaluation time. The recovery cutoff above may be later than the
    /// frontier so a stale direct reading cannot hide a recent outage.
    NSTimeInterval continuityGapSeconds;
} EBSoCEstimate;

/// Infer SoC from charge telemetry.
///   samples      — from EBStoreLoad, ascending, may carry optional pvW/supplyW/chargeW/st
///   anchorPct    — last known good percentage, or < 0 for none
///   anchorAt     — when that anchor was true, or nil for none
///   anchorSource — provenance of that anchor
///   capacityWh   — usable pack capacity in Wh (> 0, else `known` is NO)
///   efficiency   — AC-to-pack efficiency, typically 0.90
///   now          — evaluation time
///
/// Returns known = NO when there is no anchor, capacity is unset, the car has
/// been UNPLUGGED since the anchor, or charger observations contain a continuity
/// gap longer than EBStoreIntegrationGapSeconds. Driving consumes an unknown
/// amount of energy, so an unplug event invalidates the estimate permanently
/// until a new anchor; a continuity gap is soft and may later be reconciled by
/// session-aware inference.
EBSoCEstimate EBInferSoC(NSArray<NSDictionary *> *samples,
                         double anchorPct, NSDate * _Nullable anchorAt,
                         EBSoCSource anchorSource,
                         double capacityWh, double efficiency, NSDate *now);

/// Session-aware inference. Each session dictionary may contain:
///   id              — stable non-empty string identifying one charge session
///   chargeStart     — NSDate at which its energy total begins
///   chargeEnd       — NSDate through which its energy total is exact; active
///                     sessions use the fetch time
///   energyWh        — optional finite, non-negative exact AC energy total
///   disconnectedAt  — optional NSDate proving the vehicle disconnected
///
/// Exact energy is used only when the complete [chargeStart, chargeEnd] interval
/// is at/after the anchor and at/before `now`. It replaces local trapezoidal
/// integration over that interval, so the same energy is never counted twice.
/// Duplicate ids use their latest bounded snapshot. Different ids with
/// overlapping intervals are treated as ambiguous and fall back to local
/// telemetry. A disconnectedAt at or after the anchor invalidates the result
/// even when the record has no usable energy total; treating equal timestamps
/// as ordered conservatively avoids precision-dependent resurrection.
///
/// Continuity is evaluated from the anchor to `now`. Trusted connected-state
/// samples advance the evidence frontier by EBStoreIntegrationGapSeconds, while
/// an accepted exact session covers its whole interval. An unresolved gap makes
/// `known` NO with `continuityUnknown` and `unknownReason` set; it does not erase
/// the anchor and may be reconciled by later exact session evidence.
EBSoCEstimate EBInferSoCWithSessions(
    NSArray<NSDictionary *> *samples,
    NSArray<NSDictionary *> * _Nullable sessions,
    double anchorPct, NSDate * _Nullable anchorAt,
    EBSoCSource anchorSource,
    double capacityWh, double efficiency, NSDate *now);

/// Latest valid `disconnectedAt` in (after, through]. `after == nil` accepts any
/// past disconnection. This helper lets persistence layers durably mirror the
/// same safety evidence used by EBInferSoCWithSessions.
NSDate * _Nullable EBLatestSessionDisconnection(
    NSArray<NSDictionary *> * _Nullable sessions,
    NSDate * _Nullable after,
    NSDate *through);

NS_ASSUME_NONNULL_END
