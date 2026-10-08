#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Glancebar's instrument metrics, shared so the two apps read as one family:
/// [symbol] [name] [gauge] [value] [datum], fixed columns aligned down the panel.
/// Value and datum are wider than Glancebar's "100%" / "resets 21:00" so
/// "10.5 kW" and "12.9 kWh @03:45" are not clipped inside the 400pt panel;
/// the gauge takes the width that remains.
extern const CGFloat EBPanelW, EBPad, EBRowH, EBValueColumnW, EBDatumColumnW;

/// Capsule gauge (Glancebar's Gauge): track at 12% label colour, rounded fill.
/// `fromCenter` draws import to the left and export to the right.
@interface EBGauge : NSView
@property(nonatomic) double fraction;
@property(nonatomic) BOOL fromCenter;
/// −1 import … +1 export. Ignored unless `fromCenter`.
@property(nonatomic) double signedFraction;
@property(nonatomic, strong, nullable) NSColor *color;
@property(nonatomic, strong, nullable) NSColor *negativeColor;
@end

@class EBGridBalanceGauge;

/// One instrument row. Value and datum inks carry state; words live in the tooltip.
@interface EBInstrumentRow : NSView
/// Optional financial graphic replaces the ordinary gauge in its existing column.
@property(nonatomic, strong, readonly) EBGridBalanceGauge *balanceGauge;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *unit;
/// Short datum right of the value ("8.2 kWh today", "stale 4m").
@property(nonatomic, copy, nullable) NSString *subline;
/// The shared Today caption supplies this datum's period; keep it in spoken text.
@property(nonatomic) BOOL dailyTotal;
/// Symbol, gauge and value tint. Nil: secondary (idle / unknown).
@property(nonatomic, strong, nullable) NSColor *tint;
@property(nonatomic, strong, nullable) NSColor *valueInk;
@property(nonatomic, strong, nullable) NSColor *datumInk;
/// Negative hides the gauge. Ignored when `gaugeFromCenter` is set.
@property(nonatomic) double gaugeFraction;
/// Gauge fill when it should not follow `tint` (stale icon stays amber).
@property(nonatomic, strong, nullable) NSColor *gaugeColor;
/// Centred bidirectional gauge (import left, export right).
@property(nonatomic) BOOL gaugeFromCenter;
/// −1 … +1, positive toward export.
@property(nonatomic) double gaugeSigned;
@property(nonatomic, strong, nullable) NSColor *gaugeNegativeColor;
/// Trend arrow riding on the gauge, from the level to where it will be in an hour
/// (Glancebar's battery language). Negative: none.
@property(nonatomic) double trendFrom, trendTo;
/// Spoken extras appended to the accessibility label (e.g. "estimated").
@property(nonatomic, copy, nullable) NSString *spokenDetail;
- (void)reload;
@end

/// One offset bar: export earnings cover import cost; the bright remainder is net.
/// Positive net is credit; negative net is cost. Full amounts remain in the tooltip.
@interface EBGridBalanceGauge : NSView
@property(nonatomic, readonly) NSString *displayText;
@property(nonatomic, copy) NSString *period;
@property(nonatomic, copy) NSString *importValue;
@property(nonatomic, copy) NSString *exportValue;
@property(nonatomic, copy) NSString *netValue;
@property(nonatomic) BOOL partial;
@property(nonatomic) BOOL amountsAvailable;
@property(nonatomic) double importAmount;
@property(nonatomic) double exportAmount;
@property(nonatomic, readonly) NSRect barRect;
@property(nonatomic, readonly) NSRect offsetRect;
@property(nonatomic, readonly) NSRect remainderRect;
@property(nonatomic, strong, nullable) NSColor *netInk;
- (void)reload;
@end

/// Solar only | Charge now, one rounded control. `mode` is 0 solar, 1 charge now, −1 neither.
@interface EBChargeModeControl : NSView
@property(nonatomic, readonly) NSButton *solarButton;
@property(nonatomic, readonly) NSButton *chargeNowButton;
@property(nonatomic) NSInteger mode;
+ (instancetype)controlWithTarget:(nullable id)target
                      solarAction:(SEL)solarAction
                     chargeAction:(SEL)chargeAction;
- (void)refreshChrome;
@end

NS_ASSUME_NONNULL_END
