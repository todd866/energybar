#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Append one sample. Pass nil for any series that was not successfully read;
/// nil series are omitted from the JSON line entirely (never written as 0).
/// `chargerState` is an optional `EBChargerState` integer (`st` key).
/// Returns YES only when the row was atomically persisted as a 0600 file. A newly
/// created containing directory is secured to 0700; existing directories are not
/// mutated.
BOOL EBStoreAppend(NSString *path, NSDate *t,
                   NSNumber * _Nullable pvW,
                   NSNumber * _Nullable supplyW,
                   NSNumber * _Nullable chargeW,
                   NSNumber * _Nullable chargerState,
                   NSTimeInterval maxAgeSeconds);

/// Persist charger-state evidence at its own observation time without treating
/// it as a power-series sample. Power integration skips these rows; vehicle
/// continuity and unplug detection still consume `st`.
BOOL EBStoreAppendStatus(NSString *path, NSDate *t, NSNumber *chargerState,
                         NSTimeInterval maxAgeSeconds);

/// Upgrade an existing history file and its dedicated parent directory to
/// 0600/0700. Missing paths are fine; other failures return NO.
BOOL EBStoreSecureExistingFile(NSString *path);

/// Load samples within maxAgeSeconds. Each dict: t (NSDate); pvW/supplyW/chargeW/st
/// only present when known; statusOnly is preserved only when explicitly true.
NSArray<NSDictionary *> *EBStoreLoad(NSString *path, NSTimeInterval maxAgeSeconds);

/// Merge persisted and transient samples into chronological, latest-wins rows.
/// This lets live charger-state evidence participate in vehicle inference
/// without writing status-only rows into the power-series store.
NSArray<NSDictionary *> *EBStoreMergeSamples(NSArray<NSDictionary *> *persisted,
                                               NSArray<NSDictionary *> *transient,
                                               NSDate *now,
                                               NSTimeInterval maxAgeSeconds);

/// Downsample to at most maxPoints (evenly spaced).
NSArray<NSDictionary *> *EBStoreDownsample(NSArray<NSDictionary *> *samples, NSUInteger maxPoints);

/// Day totals plus how much of the window each series actually covered.
typedef struct {
    double pvWh;
    double exportWh;
    double importWh;
    double chargeWh;
    /// Car energy drawn from the grid: min(charge, max(0, supply)), the chart's grid-first split.
    double chargeGridWh;
    NSTimeInterval pvCoverage;
    NSTimeInterval gridCoverage;
    NSTimeInterval chargeCoverage;
    NSTimeInterval span;
} EBDayTotals;

/// The largest interval considered continuous. Seven minutes tolerates the
/// bounded five-minute retry plus worst-case request duration and timer jitter.
/// Explicit attempted-failure rows still break unavailable series immediately.
extern const NSTimeInterval EBStoreIntegrationGapSeconds;

/// Gross directional energy for a linearly changing grid reading. An interval
/// that crosses zero contains both import and export; they must not cancel.
typedef struct { double importWh, exportWh; } EBGridEnergy;
EBGridEnergy EBGridEnergyForInterval(double firstW, double lastW, NSTimeInterval seconds);

/// Trapezoidal integration; skips intervals where either endpoint lacks that series,
/// and gaps longer than EBStoreIntegrationGapSeconds.
EBDayTotals EBStoreIntegrateSince(NSArray<NSDictionary *> *samples,
                                  NSDate *since, NSDate * _Nullable now);

/// Local calendar midnight for `now`.
NSDate *EBStartOfLocalDay(NSDate *now);

/// Bucket samples into equal *time* slices; preserves independent supply and charge
/// extrema used by the chart. PV does not influence chart downsampling.
NSArray<NSDictionary *> *EBStoreBucket(NSArray<NSDictionary *> *samples,
                                       NSDate *since, NSDate *now,
                                       NSUInteger buckets);

/// Coverage-aware values for one chart bar. Solar/grid car components are
/// time-weighted parts of mean known charge, so their sum remains mean car load.
/// Car energy is grid-first: car-from-grid = min(charge, import), the rest of the
/// car load is solar. That never overclaims solar and needs no PV reading.
/// Home parts are what remains of import (grid) and of PV (solar); homeSolarW
/// is zero when no PV sample is present rather than guessed.
typedef struct {
    double carSolarW;
    double carGridW;
    double unusedSurplusW;
    double importW;
    double homeGridW;
    double homeSolarW;
    double solarW;
    NSUInteger chargeSampleCount;
    NSUInteger supplySampleCount;
    NSUInteger pvSampleCount;
} EBChartSeriesAverages;

/// Aggregate one bar without treating absent series as zero. Charge samples whose
/// matching supply value is absent are intentionally unclassified and omitted.
EBChartSeriesAverages EBStoreChartSeriesAverages(NSArray<NSDictionary *> *samples);

NS_ASSUME_NONNULL_END
