#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Format watts as compact kW string with one decimal, e.g. 4116 → @"4.1"
NSString *EBFmtKW(double watts);

/// Grid arrow segment: supplyActivePower from Evnex CT (negative = export).
NSString *EBGridSegment(double supplyActivePowerW);

/// Charger glance word from Evnex status fields.
NSString *EBChargerWord(NSString * _Nullable ocppStatus,
                        NSString * _Nullable chargingLogic,
                        NSString * _Nullable chargingCurrentControl,
                        BOOL chargeNow);

typedef NS_ENUM(NSInteger, EBChargerState) {
    EBChargerStateUnknown = 0,
    EBChargerStateUnplugged,
    EBChargerStateWaiting,
    EBChargerStateSolar,
    EBChargerStateCharging,
    EBChargerStateFault,
};

/// `haveOcpp` is NO when the detail fetch failed and ocppStatus is therefore unknown.
EBChargerState EBComputeChargerState(NSString * _Nullable ocppStatus,
                                     NSString * _Nullable chargingLogic,
                                     NSString * _Nullable chargingCurrentControl,
                                     BOOL chargeNow,
                                     BOOL haveOcpp);

/// Reconcile a slower connector-meter value with the fresher status endpoint.
/// Definitive unplugged, waiting, or fault states suppress retained car power;
/// an unavailable or ambiguous status never invents zero.
double EBChargePowerForLiveStatus(double detailChargeW, BOOL statusOK,
                                  NSString * _Nullable chargingLogic,
                                  NSString * _Nullable chargingCurrentControl,
                                  BOOL chargeNow);

NSString *EBChargerWordForState(EBChargerState state);
NSString *EBChargerLabelForState(EBChargerState state);

/// Poll interval ladder. success → base 30. failure → double, capped at 300.
NSTimeInterval EBNextPollInterval(NSTimeInterval current, BOOL success);

/// Back off the live-status scheduler when status is unavailable or rate-limited.
/// Detail/session health must not be folded into this status decision.
BOOL EBShouldBackoffEvnex(BOOL statusOK, BOOL rateLimited);

/// Align the next charge-point detail request to a roughly five-minute source
/// clock. A valid late-cycle sample is revisited promptly, while invalid or
/// already stale ages fall back to the normal five-minute request interval.
NSTimeInterval EBNextDetailPollInterval(NSTimeInterval meterAgeSeconds);

/// A skipped/not-due cycle preserves the last detail health result. Only an
/// actual request can transition it to current or failed.
BOOL EBDetailCurrentState(BOOL wasCurrent, BOOL attempted, BOOL successful);

/// Use the controller's older fallback only when this refresh has no parsed
/// timestamped meter value of its own.
BOOL EBShouldUseLastMeterFallback(BOOL snapshotHasMeter, BOOL haveLastMeter);

/// The shared history row represents a meter sampling opportunity. Status-only
/// and Fronius-only refreshes between those opportunities must not create false
/// power-series gaps; an attempted meter failure must still record one.
BOOL EBShouldPersistPoll(BOOL meterAttempted);

/// Full glance string for --dump / popover header (not shown in menu bar in v1.1).
NSString *EBGlanceString(BOOL pvOK, double pvWatts,
                         BOOL gridOK, double supplyActivePowerW,
                         BOOL chargerOK,
                         NSString * _Nullable ocppStatus,
                         NSString * _Nullable chargingLogic,
                         NSString * _Nullable chargingCurrentControl,
                         BOOL chargeNow);

typedef NS_ENUM(NSInteger, EBBarState) {
    EBBarStateOK = 0,
    EBBarStateWarn = 1,
    EBBarStateError = 2,
};

/// Menu-bar tint state (icon-only UI).
EBBarState EBComputeBarState(BOOL pvOK, BOOL gridOK, BOOL chargerOK,
                             NSString * _Nullable ocppStatus,
                             NSString * _Nullable chargingLogic,
                             NSString * _Nullable chargingCurrentControl,
                             BOOL chargeNow,
                             double supplyActivePowerW);

/// Format kWh with one decimal, e.g. 6360 Wh → @"6.4 kWh"
NSString *EBFmtKWh(double wattHours);

/// Instantaneous grid balance label, e.g. @"↑0.9 kW" / @"↓0.5 kW" / @"·0.0 kW"
NSString *EBFmtGridNow(double supplyActivePowerW);

/// Day net grid from export/import Wh: @"↑1.2 kWh" net export, @"↓0.4 kWh" net import.
NSString *EBFmtGridDay(double exportWh, double importWh);

/// Menu-bar SF Symbol: bolt (charging), sun (surplus), cloud (day, no surplus), moon (night).
/// `hour` is local 0–23; pass -1 to ignore clock and infer day only from PV.
NSString *EBBarGlyphName(BOOL pvOK, double pvW,
                         BOOL gridOK, double supplyW,
                         BOOL chargerOK, double chargeW,
                         NSInteger hour);

/// Error and unknown states are encoded in shape as well as tint.
NSString *EBBarGlyphNameForState(EBBarState state, BOOL chargerStateKnown,
                                 BOOL pvOK, double pvW,
                                 BOOL gridOK, double supplyW,
                                 BOOL chargerOK, double chargeW,
                                 NSInteger hour);

/// Qualifier for a "today" figure. nil = fine; @"partial" / @"no data".
NSString * _Nullable EBCoverageNote(NSTimeInterval coverageSeconds, NSTimeInterval spanSeconds);

/// Primary popover question: is surplus going to the car, or being wasted / bought?
typedef NS_ENUM(NSInteger, EBMatchState) {
    EBMatchOffline = 0,
    EBMatchMatchingSolar,
    EBMatchChargingFromGrid,
    EBMatchSurplusUnused,
    EBMatchIdle,
    EBMatchUnknown,
};

/// `supplyW` is Evnex CT (negative = export). Vehicle fields optional — pass has*=NO to ignore.
EBMatchState EBComputeMatchState(BOOL gridOK, double supplyW,
                                 BOOL chargerOK, double chargeW,
                                 BOOL vehicleHasReady, BOOL vehicleReady,
                                 BOOL vehicleHasSOC, double vehicleSOC);

NSString *EBMatchLabel(EBMatchState state);

/// Menu-bar-style severity for match pill colour (OK / Warn / Error).
EBBarState EBBarStateForMatch(EBMatchState state);

NS_ASSUME_NONNULL_END
