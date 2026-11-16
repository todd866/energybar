#import "climate_view.h"
#import "climate.h"

static const CGFloat kPanelW = 448;
static const CGFloat kRow = 26;
static const CGFloat kGap = 4;
static const CGFloat kStepW = 19;
static const CGFloat kValW = 58;
static const CGFloat kParamX = 280;
static const CGFloat kParamW = 36;
static const CGFloat kValueRight = kPanelW - 6;
static const CGFloat kWeekdayW = 26;
static const CGFloat kWeekdayH = 22;

@interface EBClimateView ()
@property NSTextField *statusLabel;
@property NSMutableDictionary *config;
@property NSArray<NSButton *> *departureDays;
@property NSArray<NSButton *> *allDayDays;
@property NSArray<NSControl *> *departureControls;
@property NSArray<NSControl *> *allDayControls;
@end

@implementation EBClimateView

- (BOOL)isFlipped { return YES; }

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(double)size secondary:(BOOL)secondary {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame;
    field.font = [NSFont systemFontOfSize:size weight:secondary ? NSFontWeightRegular : NSFontWeightSemibold];
    field.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:field];
    return field;
}

- (void)placeValue:(NSTextField *)val stepper:(NSStepper *)step y:(CGFloat)y {
    CGFloat stepX = kValueRight - kStepW;
    step.frame = NSMakeRect(stepX, y + 2, kStepW, kRow - 4);
    val.frame = NSMakeRect(stepX - kValW - 2, y + 4, kValW, 18);
    val.alignment = NSTextAlignmentRight;
    val.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    val.lineBreakMode = NSLineBreakByClipping;
}

- (NSButton *)toggle:(NSString *)title frame:(NSRect)frame target:(id)target action:(SEL)action {
    NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
    b.frame = frame;
    b.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [self addSubview:b];
    return b;
}

- (NSButton *)weekdayButton:(NSString *)letter index:(NSUInteger)i x:(CGFloat)x y:(CGFloat)y
                    target:(id)target action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:letter target:target action:action];
    b.frame = NSMakeRect(x, y + (kRow - kWeekdayH) / 2, kWeekdayW, kWeekdayH);
    b.bezelStyle = NSBezelStyleSmallSquare;
    [b setButtonType:NSButtonTypePushOnPushOff];
    b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    NSButtonCell *cell = (NSButtonCell *)b.cell;
    cell.alignment = NSTextAlignmentCenter;
    cell.imagePosition = NSNoImage;
    cell.highlightsBy = NSNoCellMask;
    b.tag = (NSInteger)i + 1;
    b.toolTip = @[@"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday", @"Sunday"][i];
    b.accessibilityLabel = b.toolTip;
    [self addSubview:b];
    return b;
}

- (NSArray<NSButton *> *)weekdayRow:(CGFloat)y indent:(CGFloat)indent target:(id)target action:(SEL)action {
    NSArray *letters = @[@"M", @"T", @"W", @"T", @"F", @"S", @"S"];
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat x = indent;
    for (NSUInteger i = 0; i < letters.count; i++) {
        [buttons addObject:[self weekdayButton:letters[i] index:i x:x + i * (kWeekdayW + kGap) y:y
                                        target:target action:action]];
    }
    return buttons;
}

- (NSDate *)timeFromHM:(NSString *)hm {
    NSArray *parts = [hm componentsSeparatedByString:@":"];
    if (parts.count != 2) return [NSDate date];
    NSInteger h = [parts[0] integerValue], m = [parts[1] integerValue];
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDateComponents *c = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:[NSDate date]];
    c.hour = h; c.minute = m;
    return [cal dateFromComponents:c];
}

- (NSString *)hmFromDate:(NSDate *)date {
  NSDateFormatter *f = [NSDateFormatter new];
  f.dateFormat = @"HH:mm";
  return [f stringFromDate:date];
}

- (void)updateEnabledState {
    BOOL depOn = [(NSButton *)[self viewWithTag:1] state] == NSControlStateValueOn;
    BOOL allOn = [(NSButton *)[self viewWithTag:10] state] == NSControlStateValueOn;
    BOOL today = [(NSButton *)[self viewWithTag:11] state] == NSControlStateValueOn;
    for (NSControl *v in self.departureControls) v.enabled = depOn;
    for (NSButton *b in self.departureDays) b.enabled = depOn;
    for (NSControl *v in self.allDayControls) v.enabled = allOn;
    for (NSButton *b in self.allDayDays) {
        b.enabled = allOn && !today;
        b.alphaValue = (allOn && !today) ? 1.0 : 0.45;
    }
}

- (instancetype)initWithConfigPath:(NSString *)configPath statePath:(NSString *)statePath {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kPanelW, 260)])) return nil;
    _configPath = [configPath copy];
    _statePath = [statePath copy];
    _config = [EBClimateLoadConfig(configPath) mutableCopy];
    NSMutableArray *depControls = [NSMutableArray array];
    NSMutableArray *allControls = [NSMutableArray array];
    CGFloat y = 0;

    NSButton *departureOn = [self toggle:@"Departure" frame:NSMakeRect(0, y, 112, kRow) target:self action:@selector(change:)];
    departureOn.toolTip = @"Pre-cool before departure";
    NSDatePicker *departureTime = [NSDatePicker new];
    departureTime.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    departureTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    departureTime.frame = NSMakeRect(116, y, 96, kRow);
    departureTime.target = self;
    departureTime.action = @selector(change:);
    departureTime.toolTip = @"Departure time";
    [self addSubview:departureTime];
    [depControls addObject:departureTime];
    [self label:@"target" frame:NSMakeRect(kParamX, y + 4, kParamW, 18) size:11 secondary:YES];
    NSStepper *departureTarget = [NSStepper new];
    departureTarget.minValue = 16; departureTarget.maxValue = 32; departureTarget.increment = 1;
    departureTarget.target = self; departureTarget.action = @selector(change:);
    departureTarget.toolTip = @"Target cabin °C";
    NSTextField *departureTargetVal = [self label:@"24 °C" frame:NSZeroRect size:12 secondary:NO];
    [self placeValue:departureTargetVal stepper:departureTarget y:y];
    [self addSubview:departureTarget];
    [depControls addObject:departureTarget];
    [depControls addObject:departureTargetVal];
    y += kRow + kGap;

    self.departureDays = [self weekdayRow:y indent:20 target:self action:@selector(change:)];
    y += kRow + kGap + 4;

    NSBox *div1 = [NSBox new]; div1.boxType = NSBoxSeparator; div1.frame = NSMakeRect(0, y, kPanelW, 1); [self addSubview:div1];
    y += 9;

    NSButton *allDayOn = [self toggle:@"All day" frame:NSMakeRect(0, y, 76, kRow) target:self action:@selector(change:)];
    allDayOn.toolTip = @"Overheat protection during set hours";
    NSButton *todayOnly = [self toggle:@"Today only" frame:NSMakeRect(80, y, 108, kRow) target:self action:@selector(change:)];
    todayOnly.toolTip = @"Enable for today's date only";
    [allControls addObject:todayOnly];
    y += kRow + kGap;

    self.allDayDays = [self weekdayRow:y indent:20 target:self action:@selector(change:)];
    y += kRow + kGap;

    [self label:@"from" frame:NSMakeRect(0, y + 4, 32, 18) size:11 secondary:YES];
    NSDatePicker *fromTime = [NSDatePicker new];
    fromTime.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    fromTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    fromTime.frame = NSMakeRect(32, y, 96, kRow);
    fromTime.target = self; fromTime.action = @selector(change:);
    [self label:@"until" frame:NSMakeRect(132, y + 4, 36, 18) size:11 secondary:YES];
    NSDatePicker *untilTime = [NSDatePicker new];
    untilTime.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    untilTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    untilTime.frame = NSMakeRect(170, y, 92, kRow);
    untilTime.target = self; untilTime.action = @selector(change:);
    [self addSubview:fromTime]; [self addSubview:untilTime];
    [allControls addObject:fromTime];
    [allControls addObject:untilTime];
    [self label:@"limit" frame:NSMakeRect(kParamX, y + 4, kParamW, 18) size:11 secondary:YES];
    NSStepper *limitStep = [NSStepper new];
    limitStep.minValue = 20; limitStep.maxValue = 45; limitStep.increment = 1;
    limitStep.target = self; limitStep.action = @selector(change:);
    limitStep.toolTip = @"Cabin limit °C";
    NSTextField *limitVal = [self label:@"35 °C" frame:NSZeroRect size:12 secondary:NO];
    [self placeValue:limitVal stepper:limitStep y:y];
    [self addSubview:limitStep];
    [allControls addObject:limitStep];
    [allControls addObject:limitVal];
    y += kRow + kGap;

    NSButton *solarOnly = [self toggle:@"Solar only" frame:NSMakeRect(0, y, 100, kRow) target:self action:@selector(change:)];
    solarOnly.toolTip = @"Only run when home has solar surplus";
    [self label:@"cap" frame:NSMakeRect(104, y + 4, 24, 18) size:11 secondary:YES];
    NSStepper *capStep = [NSStepper new];
    capStep.frame = NSMakeRect(196, y + 2, kStepW, kRow - 4);
    capStep.minValue = 0.5; capStep.maxValue = 10; capStep.increment = 0.5;
    capStep.target = self; capStep.action = @selector(change:);
    capStep.toolTip = @"Daily energy cap kWh";
    NSTextField *capVal = [self label:@"1.5 kWh" frame:NSMakeRect(136, y + 4, 56, 18) size:12 secondary:NO];
    capVal.alignment = NSTextAlignmentRight;
    capVal.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    [self addSubview:capStep];
    [allControls addObject:solarOnly];
    [allControls addObject:capStep];
    [allControls addObject:capVal];
    [self label:@"min" frame:NSMakeRect(kParamX, y + 4, kParamW, 18) size:11 secondary:YES];
    NSStepper *socStep = [NSStepper new];
    socStep.minValue = 10; socStep.maxValue = 90; socStep.increment = 5;
    socStep.target = self; socStep.action = @selector(change:);
    socStep.toolTip = @"Minimum traction battery %";
    NSTextField *socVal = [self label:@"50 %" frame:NSZeroRect size:12 secondary:NO];
    [self placeValue:socVal stepper:socStep y:y];
    [self addSubview:socStep];
    [allControls addObject:socStep];
    [allControls addObject:socVal];
    y += kRow + kGap + 4;

    NSButton *coolNow = [NSButton buttonWithTitle:@"Cool now" target:self action:@selector(coolNow:)];
    coolNow.bezelStyle = NSBezelStyleRounded;
    coolNow.frame = NSMakeRect(0, y, 96, kRow);
    coolNow.toolTip = @"Run cabin cooling immediately";
    [self addSubview:coolNow];
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.frame = NSMakeRect(104, y + 2, kPanelW - 104, kRow + 14);
    _statusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _statusLabel.maximumNumberOfLines = 2;
    _statusLabel.usesSingleLineMode = NO;
    _statusLabel.cell.wraps = YES;
    [self addSubview:_statusLabel];

    [self setFrameSize:NSMakeSize(kPanelW, y + kRow + 18)];

    self.departureControls = depControls;
    self.allDayControls = allControls;

    departureOn.tag = 1; departureTime.tag = 2; departureTarget.tag = 3; departureTargetVal.tag = 4;
    allDayOn.tag = 10; todayOnly.tag = 11; fromTime.tag = 12; untilTime.tag = 13;
    limitStep.tag = 14; limitVal.tag = 15; solarOnly.tag = 16; capStep.tag = 17; capVal.tag = 18;
    socStep.tag = 19; socVal.tag = 20;
    [self applyToControls];
    [self reloadState];
    return self;
}

- (NSArray *)selectedDays:(NSArray<NSButton *> *)buttons {
    NSMutableArray *days = [NSMutableArray array];
    for (NSButton *b in buttons) if (b.state == NSControlStateValueOn) [days addObject:@(b.tag)];
    return days;
}

- (void)setDayButtons:(NSArray<NSButton *> *)buttons days:(NSArray *)days {
    NSSet *set = [NSSet setWithArray:days];
    for (NSButton *b in buttons) b.state = [set containsObject:@(b.tag)] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)applyToControls {
    NSDictionary *dep = self.config[@"departure"];
    NSDictionary *all = self.config[@"allDay"];
    [(NSButton *)[self viewWithTag:1] setState:[dep[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    [(NSDatePicker *)[self viewWithTag:2] setDateValue:[self timeFromHM:dep[@"time"]]];
    double target = [dep[@"targetC"] doubleValue];
    [(NSStepper *)[self viewWithTag:3] setDoubleValue:target];
    [(NSTextField *)[self viewWithTag:4] setStringValue:[NSString stringWithFormat:@"%.0f °C", target]];
    [self setDayButtons:self.departureDays days:dep[@"days"]];
    [(NSButton *)[self viewWithTag:10] setState:[all[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    id onDate = all[@"onDate"];
    BOOL today = onDate != nil && onDate != NSNull.null && [onDate isKindOfClass:NSString.class] && [onDate length];
    [(NSButton *)[self viewWithTag:11] setState:today ? NSControlStateValueOn : NSControlStateValueOff];
    [self setDayButtons:self.allDayDays days:all[@"days"]];
    [(NSDatePicker *)[self viewWithTag:12] setDateValue:[self timeFromHM:all[@"from"]]];
    [(NSDatePicker *)[self viewWithTag:13] setDateValue:[self timeFromHM:all[@"until"]]];
    double limit = [all[@"limitC"] doubleValue];
    [(NSStepper *)[self viewWithTag:14] setDoubleValue:limit];
    [(NSTextField *)[self viewWithTag:15] setStringValue:[NSString stringWithFormat:@"%.0f °C", limit]];
    [(NSButton *)[self viewWithTag:16] setState:[all[@"solarOnlyAtHome"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
    double cap = [all[@"dailyCapKWh"] doubleValue];
    [(NSStepper *)[self viewWithTag:17] setDoubleValue:cap];
    [(NSTextField *)[self viewWithTag:18] setStringValue:[NSString stringWithFormat:@"%.1f kWh", cap]];
    double soc = [all[@"minSocPct"] doubleValue];
    [(NSStepper *)[self viewWithTag:19] setDoubleValue:soc];
    [(NSTextField *)[self viewWithTag:20] setStringValue:[NSString stringWithFormat:@"%.0f %%", soc]];
    [self updateEnabledState];
}

- (void)commitFromControls {
    NSMutableDictionary *dep = [self.config[@"departure"] mutableCopy];
    dep[@"enabled"] = @([(NSButton *)[self viewWithTag:1] state] == NSControlStateValueOn);
    dep[@"time"] = [self hmFromDate:[(NSDatePicker *)[self viewWithTag:2] dateValue]];
    dep[@"targetC"] = @([(NSStepper *)[self viewWithTag:3] doubleValue]);
    dep[@"days"] = [self selectedDays:self.departureDays];
    NSMutableDictionary *all = [self.config[@"allDay"] mutableCopy];
    all[@"enabled"] = @([(NSButton *)[self viewWithTag:10] state] == NSControlStateValueOn);
    BOOL today = [(NSButton *)[self viewWithTag:11] state] == NSControlStateValueOn;
    if (today) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd";
        f.timeZone = NSTimeZone.localTimeZone;
        all[@"onDate"] = [f stringFromDate:[NSDate date]];
        all[@"days"] = @[];
    } else {
        all[@"onDate"] = NSNull.null;
        all[@"days"] = [self selectedDays:self.allDayDays];
    }
    all[@"from"] = [self hmFromDate:[(NSDatePicker *)[self viewWithTag:12] dateValue]];
    all[@"until"] = [self hmFromDate:[(NSDatePicker *)[self viewWithTag:13] dateValue]];
    all[@"limitC"] = @([(NSStepper *)[self viewWithTag:14] doubleValue]);
    all[@"solarOnlyAtHome"] = @([(NSButton *)[self viewWithTag:16] state] == NSControlStateValueOn);
    all[@"dailyCapKWh"] = @([(NSStepper *)[self viewWithTag:17] doubleValue]);
    all[@"minSocPct"] = @([(NSStepper *)[self viewWithTag:19] doubleValue]);
    self.config[@"departure"] = dep;
    self.config[@"allDay"] = all;
    [(NSTextField *)[self viewWithTag:4] setStringValue:
        [NSString stringWithFormat:@"%.0f °C", [dep[@"targetC"] doubleValue]]];
    [(NSTextField *)[self viewWithTag:15] setStringValue:
        [NSString stringWithFormat:@"%.0f °C", [all[@"limitC"] doubleValue]]];
    [(NSTextField *)[self viewWithTag:18] setStringValue:
        [NSString stringWithFormat:@"%.1f kWh", [all[@"dailyCapKWh"] doubleValue]]];
    [(NSTextField *)[self viewWithTag:20] setStringValue:
        [NSString stringWithFormat:@"%.0f %%", [all[@"minSocPct"] doubleValue]]];
    [self updateEnabledState];
}

- (void)change:(id)sender {
    (void)sender;
    [self commitFromControls];
    (void)EBClimateSaveConfig(self.configPath, self.config, nil);
    [self reloadState];
}

- (void)flushToDisk {
    [self commitFromControls];
    (void)EBClimateSaveConfig(self.configPath, self.config, nil);
}

- (void)reloadState {
    NSDictionary *state = EBClimateLoadState(self.statePath);
    self.statusLabel.stringValue = EBClimateStatusLine(state, self.config);
}

- (void)coolNow:(id)sender {
    (void)sender;
    NSAlert *a = [NSAlert new];
    a.messageText = @"Cool cabin now?";
    a.informativeText = @"Runs cabin cooling until the controller stops it.";
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Cool now"];
    if ([a runModal] != NSAlertSecondButtonReturn) return;
    if (![self.delegate respondsToSelector:@selector(climateViewRequestCoolNow:completion:)]) return;
    __weak typeof(self) weak = self;
    [self.delegate climateViewRequestCoolNow:self completion:^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error.length) weak.statusLabel.stringValue = error;
            else [weak reloadState];
        });
    }];
}

@end

NSAlert *EBBuildClimateAlert(EBClimateView *view) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Climate";
    alert.icon = [NSImage imageWithSystemSymbolName:@"snowflake" accessibilityDescription:@"Climate"];
    alert.accessoryView = view;
    [alert addButtonWithTitle:@"Close"];
    return alert;
}