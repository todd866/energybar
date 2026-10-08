#import <Cocoa/Cocoa.h>
#import "chart.h"
#import "tiles.h"
#import "store.h"
#import "tariff.h"

NS_ASSUME_NONNULL_BEGIN

/// Plain value object for popover presentation (no I/O).
@interface EBSnapshotView : NSObject
/// Evaluation clock for relative labels and chart bounds. Nil uses the current time at runtime.
@property(copy, nullable) NSDate *referenceDate;
@property BOOL pvOK;
@property double pvW;
@property double eDayWh;
@property BOOL gridOK;
@property BOOL gridStale;
@property(copy, nullable) NSDate *gridAsOf;
@property double supplyW;
@property double chargeW;
@property BOOL chargerOK;
@property BOOL haveOcpp;
@property(copy, nullable) NSString *ocppStatus;
@property(copy, nullable) NSString *chargingLogic;
@property(copy, nullable) NSString *chargingCurrentControl;
@property BOOL chargeNow;
@property(copy, nullable) NSString *pvError;
@property(copy, nullable) NSString *evnexError;
@property(copy, nullable) NSString *storageError;
@property(copy, nullable) NSString *vehicleError;
@property(copy, nullable) NSDate *pvAt;
@property(copy, nullable) NSDate *evnexAt;
@property EBDayTotals today;
@property(strong, nullable) EBTariff *tariff;
@property(copy, nullable) NSString *tariffError;
@property EBGridCostTotals gridCostToday;
/// Exact Evnex session-register total through carDayAsOf. This can recover
/// charging while Energybar was not running without inventing a power curve.
@property BOOL carDayAvailable;
@property double carDayWh;
@property NSUInteger carDaySessionCount;
@property BOOL carDayStale;
@property(copy, nullable) NSDate *carDayAsOf;
@property(copy, nullable) NSString *sessionError;
@property BOOL pvArchiveAvailable;
@property double pvArchiveWh;
@property NSUInteger pvArchiveIntervalCount;
@property(copy, nullable) NSString *pvArchiveError;
@property(copy, nullable) NSString *orgId;
@property(copy, nullable) NSString *vehicleLine;
@property BOOL vehicleHasSOC;
@property double vehicleSOC;
@property BOOL vehicleSOCIsEstimate;
/// Usable pack (Wh) and charge efficiency, for the Car row's one-hour trend arrow; 0 = unknown.
@property double vehicleCapacityWh;
@property double vehicleChargeEfficiency;
/// Inverter capacity (W) from INVERTER_KW; the Solar bar's full scale. 0 = unknown.
@property double inverterW;
@property BOOL vehicleHasReady;
@property BOOL vehicleReady;
/// Any vehicle state that the user can explicitly clear, including an unplug tombstone.
@property BOOL vehicleHasStoredState;
@end

@interface EBPopoverViews : NSObject
@property(strong) NSView *root;
/// Shown only when something needs action (a failed source login, unsaved state).
@property(strong) NSView *faultRow;
@property(strong) NSTextField *faultLabel;
@property(strong) EBInstrumentRow *solarRow;
@property(strong) EBInstrumentRow *gridRow;
@property(strong) EBInstrumentRow *carRow;
/// Vehicle state of charge; hidden when no vehicle state is known.
@property(strong) EBInstrumentRow *batteryRow;
@property(strong) NSTextField *nowCaption;
@property(strong) NSTextField *todayCaption;
@property(strong) NSBox *totalsDivider;
@property(strong) NSBox *chartDivider;
@property(strong) NSBox *footerDivider;
/// The energy-match verdict ("Matching solar"). Carried by colour on screen;
/// the words are in the car row and ⋯ tooltips.
@property(copy) NSString *statusLabel;
@property(strong) EBChartLegend *legend;
@property(strong) EBChartView *chart;
@property(strong) NSSegmentedControl *windowSeg;
@property(strong) EBChargeModeControl *modeControl;
@property(strong) NSButton *solarButton;
@property(strong) NSButton *chargeNowButton;
@property(strong) NSButton *stopButton;
@property(strong) NSButton *moreButton;
@property(strong) NSMenu *gearMenu;
@end

/// Build the popover hierarchy. `target` receives control actions; pass nil for tests.
EBPopoverViews *EBBuildPopover(id _Nullable target);

/// Populate an already-built hierarchy from a snapshot. Pure presentation — no I/O.
/// `samples` are raw store rows; the chart and gauges use the current window.
void EBApplySnapshot(EBPopoverViews *v, EBSnapshotView *snap, NSArray<NSDictionary *> *samples);

/// Charge-mode selection: 0 solar, 1 charge now, -1 neither (unknown or stopped).
void EBSetChargeMode(EBPopoverViews *v, NSInteger mode);
void EBSetCommandsEnabled(EBPopoverViews *v, BOOL enabled, BOOL canStop);

NS_ASSUME_NONNULL_END
