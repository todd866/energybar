#import "tiles.h"
#import "chart.h"

const CGFloat EBPanelW = 400, EBPad = 16, EBRowH = 30;
const CGFloat EBValueColumnW = 74, EBDatumColumnW = 122;
static const CGFloat kLeadSymbol = 22, kLeadW = 28;
static const CGFloat kNameX = 48, kNameW = 56;
static const CGFloat kGaugeX = 110, kGaugeH = 8;
static const CGFloat kValueH = 19;
static const CGFloat kDatumH = 16, kDatumFont = 12.5;
static const CGFloat kFooterH = 28, kFooterSymbol = 16;

static NSTextField *EBLabel(NSFont *font, NSRect frame, NSTextAlignment align) {
    NSTextField *f = [NSTextField labelWithString:@""];
    f.drawsBackground = NO;
    f.font = font;
    f.alignment = align;
    f.frame = frame;
    f.maximumNumberOfLines = 1;
    f.lineBreakMode = NSLineBreakByClipping;
    return f;
}

@interface EBModeSegment : NSButton
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, copy) NSString *segmentLabel;
@property(nonatomic, strong) NSColor *ink;
@end
@implementation EBModeSegment
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const CGFloat icon = 18, gap = 6, pad = 10;
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kFooterSymbol
                                                                                      weight:NSFontWeightMedium];
    NSImageSymbolConfiguration *tint = [NSImageSymbolConfiguration configurationWithPaletteColors:@[self.ink ?: NSColor.labelColor]];
    NSImage *image = [[NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:nil]
                      imageWithSymbolConfiguration:[cfg configurationByApplyingConfiguration:tint]];
    NSRect iconRect = NSMakeRect(pad, (NSHeight(self.bounds) - icon) / 2.0, icon, icon);
    [image drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: self.ink ?: NSColor.labelColor,
    };
    NSString *text = self.segmentLabel ?: @"";
    NSSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(NSMaxX(iconRect) + gap, (NSHeight(self.bounds) - sz.height) / 2.0) withAttributes:attrs];
}
@end

@implementation EBGauge
- (void)setFraction:(double)fraction {
    _fraction = MIN(1.0, MAX(0.0, fraction));
    self.needsDisplay = YES;
}
- (void)setSignedFraction:(double)signedFraction {
    _signedFraction = MIN(1.0, MAX(-1.0, signedFraction));
    self.needsDisplay = YES;
}
- (void)setFromCenter:(BOOL)fromCenter { _fromCenter = fromCenter; self.needsDisplay = YES; }
- (void)setColor:(NSColor *)color { _color = color; self.needsDisplay = YES; }
- (void)setNegativeColor:(NSColor *)negativeColor { _negativeColor = negativeColor; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect r = self.bounds;
    CGFloat rad = r.size.height / 2;
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    if (self.fromCenter) {
        CGFloat mid = NSMidX(r);
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.85] setFill];
        NSRectFill(NSMakeRect(mid - 0.5, 0, 1, r.size.height));
        double mag = fabs(self.signedFraction);
        if (mag < 0.02) return;
        CGFloat reach = (r.size.width / 2.0) * (CGFloat)mag;
        // A short flow is a capsule on the active side of centre, not a dot at the left edge.
        CGFloat w = MAX(r.size.height, reach);
        NSRect f = self.signedFraction >= 0
            ? NSMakeRect(mid, r.origin.y, MIN(w, r.size.width / 2.0), r.size.height)
            : NSMakeRect(MAX(r.origin.x, mid - w), r.origin.y, MIN(w, r.size.width / 2.0), r.size.height);
        NSColor *ink = self.signedFraction >= 0 ? (self.color ?: NSColor.systemGreenColor)
                                                : (self.negativeColor ?: NSColor.systemRedColor);
        [ink setFill];
        [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
        return;
    }
    if (self.fraction <= 0) return;
    NSRect f = r;
    f.size.width = MAX(r.size.height, r.size.width * self.fraction);
    [(self.color ?: NSColor.secondaryLabelColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
}
@end

// Glancebar's TrendArrow: a line from the level to where it is heading, with a head; a thin
// halo in the panel colour keeps it legible over the fill and the track alike.
@interface EBTrendArrow : NSView
@property(nonatomic) double from, to;
@end
@implementation EBTrendArrow
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGFloat inset = 5, w = NSWidth(self.bounds) - 2 * inset, y = NSMidY(self.bounds);
    CGFloat a = inset + w * self.from, b = inset + w * self.to;
    if (fabs(b - a) < 1) return;
    BOOL up = b > a;
    CGFloat dir = up ? 1 : -1;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow appendBezierPathWithRect:NSMakeRect(MIN(a, b - dir), y - 1, fabs(b - dir - a), 2)];
    [arrow moveToPoint:NSMakePoint(b + dir * 4, y)];
    [arrow lineToPoint:NSMakePoint(b - dir * 1, y + 3.5)];
    [arrow lineToPoint:NSMakePoint(b - dir * 1, y - 3.5)];
    [arrow closePath];
    [NSGraphicsContext saveGraphicsState];
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.9] setStroke];
    arrow.lineWidth = 2; arrow.lineJoinStyle = NSLineJoinStyleRound; [arrow stroke];
    [NSGraphicsContext restoreGraphicsState];
    [(up ? NSColor.systemGreenColor : NSColor.systemOrangeColor) setFill];
    [arrow fill];
}
@end

@implementation EBInstrumentRow {
    NSImageView *_symbol;
    NSTextField *_nameL, *_valueL, *_datumL;
    EBGauge *_gauge;
    EBTrendArrow *_trend;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:NSMakeRect(frame.origin.x, frame.origin.y, EBPanelW, EBRowH)];
    if (!self) return self;
    _title = @""; _value = @"—"; _unit = @""; _symbolName = @"circle";
    _gaugeFraction = -1;
    _trendFrom = _trendTo = -1;
    CGFloat datumX = EBPanelW - EBPad - EBDatumColumnW;
    CGFloat valueX = datumX - 6 - EBValueColumnW;
    CGFloat gaugeW = valueX - 4 - kGaugeX;
    _symbol = [NSImageView new];
    _symbol.imageScaling = NSImageScaleProportionallyDown;
    _symbol.frame = NSMakeRect(EBPad, (EBRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    _nameL = EBLabel([NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                     NSMakeRect(kNameX, (EBRowH - 16) / 2, kNameW, 16), NSTextAlignmentLeft);
    _nameL.textColor = NSColor.labelColor;
    _gauge = [[EBGauge alloc] initWithFrame:NSMakeRect(kGaugeX, (EBRowH - kGaugeH) / 2, gaugeW, kGaugeH)];
    _valueL = EBLabel([NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold],
                      NSMakeRect(valueX, (EBRowH - kValueH) / 2, EBValueColumnW, kValueH), NSTextAlignmentRight);
    _datumL = EBLabel([NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular],
                      NSMakeRect(datumX, (EBRowH - kDatumH) / 2, EBDatumColumnW, kDatumH), NSTextAlignmentLeft);
    _balanceGauge = [[EBGridBalanceGauge alloc] initWithFrame:_gauge.frame];
    _balanceGauge.hidden = YES;
    _balanceGauge.accessibilityElement = NO;
    _trend = [[EBTrendArrow alloc] initWithFrame:NSInsetRect(_gauge.frame, -5, -1)];
    _trend.hidden = YES;
    // The daily money is a figure in the Today column, not a bar: a bar in the Now position
    // that showed today's net cost read as "importing" while the live flow was export.
    // _balanceGauge stays as the model for that figure and its tooltip; it is not drawn.
    for (NSView *v in @[_symbol, _nameL, _gauge, _trend, _valueL, _datumL]) [self addSubview:v];
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)reload {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kLeadSymbol
                                                                                      weight:NSFontWeightRegular];
    _symbol.image = [[NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:nil]
                     imageWithSymbolConfiguration:cfg];
    _symbol.contentTintColor = self.tint ?: EBInkSecondary();
    _nameL.stringValue = self.title ?: @"";
    _gauge.fromCenter = self.gaugeFromCenter;
    _gauge.negativeColor = self.gaugeNegativeColor;
    if (self.gaugeFromCenter) {
        _gauge.hidden = NO;
        _gauge.signedFraction = self.gaugeSigned;
        _gauge.color = self.gaugeColor ?: self.tint;
    } else {
        _gauge.hidden = self.gaugeFraction < 0;
        _gauge.fraction = MAX(0, self.gaugeFraction);
        _gauge.color = self.gaugeColor ?: self.tint;
    }
    _trend.hidden = _gauge.hidden || self.gaugeFromCenter || self.trendFrom < 0 || self.trendTo < 0 ||
                    fabs(self.trendTo - self.trendFrom) < 0.01;
    _trend.from = MAX(0, self.trendFrom); _trend.to = MAX(0, self.trendTo);
    _trend.needsDisplay = YES;
    BOOL known = self.value.length && ![self.value isEqualToString:@"—"];
    _valueL.stringValue = known && self.unit.length
        ? [NSString stringWithFormat:@"%@ %@", self.value, self.unit] : (self.value ?: @"—");
    _valueL.textColor = known ? (self.valueInk ?: NSColor.labelColor) : EBInkSecondary();
    NSString *money = self.balanceGauge.displayText;
    NSRange net = [money rangeOfString:@" net"];
    if (net.location != NSNotFound) money = [money substringToIndex:net.location];   // "−$0.85"; partial is on hover
    NSString *datum = self.balanceGauge.hidden ? (self.subline ?: @"") : money;
    if (self.dailyTotal) {
        datum = [datum stringByReplacingOccurrencesOfString:@" today" withString:@""];
        datum = [datum stringByReplacingOccurrencesOfString:@" exact" withString:@""];
    }
    _datumL.stringValue = datum;
    _datumL.textColor = self.balanceGauge.hidden ? (self.datumInk ?: EBInkSecondary())
        : (self.balanceGauge.netInk ?: EBInkSecondary());
    NSMutableArray *a11y = [NSMutableArray array];
    if (self.title.length) [a11y addObject:self.title];
    if (known && [self.unit isEqualToString:@"kW"]) [a11y addObject:@"power now"];
    if (known) [a11y addObject:_valueL.stringValue];
    if (self.spokenDetail.length) [a11y addObject:self.spokenDetail];
    if (!self.balanceGauge.hidden) {
        if (self.balanceGauge.accessibilityLabel.length) [a11y addObject:self.balanceGauge.accessibilityLabel];
    } else {
        if (self.subline.length) [a11y addObject:self.subline];
    }
    self.accessibilityLabel = [a11y componentsJoinedByString:@", "];
}
@end

@implementation EBGridBalanceGauge
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;
    _period = @"Today";
    _importValue = _exportValue = _netValue = @"—";
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSRect)barRect { return self.bounds; }
- (NSString *)displayText {
    return [NSString stringWithFormat:@"%@ net %@", self.netValue ?: @"—", self.partial ? @"partial" : @"today"];
}
- (BOOL)hasValidAmounts {
    return self.amountsAvailable && isfinite(self.importAmount) && isfinite(self.exportAmount) &&
           self.importAmount >= 0 && self.exportAmount >= 0;
}
- (NSRect)offsetRect {
    NSRect r = self.barRect;
    double maximum = fmax(self.importAmount, self.exportAmount);
    r.size.width = [self hasValidAmounts] && maximum > 0
        ? r.size.width * (fmin(self.importAmount, self.exportAmount) / maximum) : 0;
    return r;
}
- (NSRect)remainderRect {
    NSRect r = self.barRect;
    if (![self hasValidAmounts] || fmax(self.importAmount, self.exportAmount) <= 0) {
        r.size.width = 0;
        return r;
    }
    CGFloat offset = self.offsetRect.size.width;
    r.origin.x += offset;
    r.size.width -= offset;
    return r;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect r = self.barRect;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height / 2 yRadius:r.size.height / 2];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [track fill];
    if ([self hasValidAmounts]) {
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        // The two gross amounts overlap instead of being added. Only the
        // unmatched tail is a net cost/credit; the pale green part is offset.
        [[EBColorExport() colorWithAlphaComponent:0.32] setFill];
        NSRectFillUsingOperation(self.offsetRect, NSCompositingOperationSourceOver);
        [(self.importAmount > self.exportAmount ? EBColorCarOnGrid() : EBColorExport()) setFill];
        NSRectFillUsingOperation(self.remainderRect, NSCompositingOperationSourceOver);
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (void)reload {
    self.needsDisplay = YES;
}
@end

@implementation EBChargeModeControl
+ (instancetype)controlWithTarget:(id)target solarAction:(SEL)solarAction chargeAction:(SEL)chargeAction {
    EBChargeModeControl *c = [self new];
    NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    const CGFloat icon = 18, gap = 6, pad = 10;
    EBModeSegment *solar = [EBModeSegment buttonWithTitle:@"" target:target action:solarAction];
    EBModeSegment *charge = [EBModeSegment buttonWithTitle:@"" target:target action:chargeAction];
    solar.symbolName = @"sun.max.fill";
    solar.segmentLabel = @"Solar only";
    charge.symbolName = @"bolt.fill";
    charge.segmentLabel = @"Charge now";
    solar.toolTip = @"Turn off Charge now and return to the charger’s configured solar mode. It may wait for surplus; this does not start a session.";
    charge.toolTip = @"Charge at full rate, using grid power when solar is short";
    for (EBModeSegment *b in @[solar, charge]) {
        b.bordered = NO;
        b.image = nil;
        b.title = @"";
    }
    CGFloat solarText = ceil([solar.segmentLabel sizeWithAttributes:@{NSFontAttributeName: font}].width);
    CGFloat chargeText = ceil([charge.segmentLabel sizeWithAttributes:@{NSFontAttributeName: font}].width);
    CGFloat solarW = pad + icon + gap + solarText + pad;
    CGFloat chargeW = pad + icon + gap + chargeText + pad;
    solar.frame = NSMakeRect(0, 0, solarW, kFooterH);
    charge.frame = NSMakeRect(solarW, 0, chargeW, kFooterH);
    c.frame = NSMakeRect(0, 0, solarW + chargeW, kFooterH);
    c->_solarButton = solar;
    c->_chargeNowButton = charge;
    [c addSubview:solar];
    [c addSubview:charge];
    c->_mode = -1;
    [c refreshChrome];
    return c;
}
- (void)setMode:(NSInteger)mode {
    _mode = mode;
    [self refreshChrome];
}
- (void)refreshChrome {
    BOOL enabled = self.solarButton.enabled && self.chargeNowButton.enabled;
    NSColor *onInk = NSColor.blackColor;
    NSColor *offInk = enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    ((EBModeSegment *)self.solarButton).ink = (self.mode == 0 && enabled) ? onInk : offInk;
    ((EBModeSegment *)self.chargeNowButton).ink = (self.mode == 1 && enabled) ? onInk : offInk;
    self.solarButton.needsDisplay = YES;
    self.chargeNowButton.needsDisplay = YES;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:b xRadius:6 yRadius:6];
    [NSGraphicsContext saveGraphicsState];
    [outer addClip];
    CGFloat track = self.solarButton.isHighlighted || self.chargeNowButton.isHighlighted ? 0.16 : 0.08;
    [[NSColor.labelColor colorWithAlphaComponent:track] setFill];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    CGFloat split = NSMinX(self.chargeNowButton.frame);
    BOOL enabled = self.solarButton.enabled && self.chargeNowButton.enabled;
    if (self.mode == 0 || self.mode == 1) {
        __block NSColor *fill = nil;
        [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
            fill = self.mode == 0 ? EBColorSurplus() : EBColorExport();
        }];
        if (!enabled) fill = [fill colorWithAlphaComponent:0.40];
        [fill setFill];
        NSRect half = self.mode == 0
            ? NSMakeRect(0, 0, split, b.size.height)
            : NSMakeRect(split, 0, NSMaxX(b) - split, b.size.height);
        NSRectFillUsingOperation(half, NSCompositingOperationSourceOver);
    }
    [NSGraphicsContext restoreGraphicsState];
    // Like a native segmented control, no divider beside the selected segment.
    if (self.mode != 0 && self.mode != 1) {
        [[NSColor.separatorColor colorWithAlphaComponent:0.9] setFill];
        NSRectFillUsingOperation(NSMakeRect(split - 0.5, 5, 1, b.size.height - 10), NSCompositingOperationSourceOver);
    }
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end
