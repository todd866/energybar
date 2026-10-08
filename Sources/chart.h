#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern const NSTimeInterval EBChartGapSeconds; // 360

/// Shared product palette. One meaning each:
/// solar → orange; export / charging → green; import / error → red;
/// car → blue; home → grey; stale → amber.
NSColor *EBColorSurplus(void);
NSColor *EBColorExport(void);
NSColor *EBColorCarOnSolar(void);
NSColor *EBColorCarOnGrid(void);

/// Text inks: the palette darkened (light) or lifted (dark) to ≥4.5:1 on the
/// popover page. Dynamic, so they follow a live Light/Dark switch.
NSColor *EBInkSurplus(void);
NSColor *EBInkExport(void);
NSColor *EBInkCarOnSolar(void);
NSColor *EBInkCarOnGrid(void);
NSColor *EBInkBattery(void);
NSColor *EBInkStale(void);
NSColor *EBInkSecondary(void);

/// One-line swatch legend for the chart, drawn beside the window control.
@interface EBChartLegend : NSView
@end

/// Rounded extents on a single watts-per-point scale. Both halves retain room
/// for their direction labels, including an import-only night or an idle day.
typedef struct { double solarW, importW, stepW; } EBChartScale;
EBChartScale EBChartMakeScale(double solarPeakW, double importPeakW);

@interface EBChartView : NSView
@property(nonatomic, copy) NSArray<NSDictionary *> *samples;
@property(nonatomic) NSTimeInterval windowSeconds; // default 12h
/// Right edge of the chart window. Nil uses the current date.
@property(nonatomic, copy, nullable) NSDate *referenceDate;
@end

NS_ASSUME_NONNULL_END
