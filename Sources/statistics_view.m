#import "statistics_view.h"
#import "chart.h"

@interface EBStatisticsView ()
@property(readwrite) NSSegmentedControl *periodControl;
@property(readwrite) NSButton *previousButton;
@property(readwrite) NSButton *nextButton;
@property(readwrite) NSArray<NSTextField *> *values;
@property(readwrite) NSArray<NSTextField *> *coverages;
@property NSTextField *range;
@property NSTextField *asOfLabel;
@property NSInteger index;
@end

@implementation EBStatisticsView
- (BOOL)isFlipped { return YES; }
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(double)size {
    NSTextField *label=[NSTextField labelWithString:text]; label.frame=frame;
    label.font=[NSFont systemFontOfSize:size];label.lineBreakMode=NSLineBreakByTruncatingTail;
    [self addSubview:label];return label;
}
- (instancetype)initWithReport:(EBStatisticsReport *)report {
    if(!(self=[super initWithFrame:NSMakeRect(0,0,400,224)]))return nil;
    _report=report;
    _periodControl=[NSSegmentedControl segmentedControlWithLabels:@[@"Day",@"Week"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changePeriod:)];
    _periodControl.frame=NSMakeRect(0,0,110,28);_periodControl.selectedSegment=0;
    _periodControl.accessibilityLabel=@"Statistics period";[self addSubview:_periodControl];
    _previousButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Previous period"] target:self action:@selector(previous:)];
    _nextButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Next period"] target:self action:@selector(next:)];
    _previousButton.frame=NSMakeRect(118,0,28,28);_nextButton.frame=NSMakeRect(372,0,28,28);
    for(NSButton *button in @[_previousButton,_nextButton]){button.bezelStyle=NSBezelStyleRounded;[self addSubview:button];}
    _range=[self label:@"" frame:NSMakeRect(150,5,218,20) size:13];_range.alignment=NSTextAlignmentCenter;
    NSTextField *units=[self label:@"Recorded kWh" frame:NSMakeRect(128,37,126,16) size:12];units.alignment=NSTextAlignmentRight;
    NSTextField *coverage=[self label:@"Coverage" frame:NSMakeRect(266,37,134,16) size:12];coverage.alignment=NSTextAlignmentRight;
    units.textColor=coverage.textColor=NSColor.secondaryLabelColor;
    NSArray *names=@[@"Solar",@"Import",@"Export",@"Car"];
    NSArray *symbols=@[@"sun.max.fill",@"arrow.down",@"arrow.up",@"car.fill"];
    NSArray *inks=@[EBInkSurplus(),EBInkCarOnGrid(),EBInkExport(),EBInkCarOnSolar()];
    NSMutableArray *values=[NSMutableArray array],*coverages=[NSMutableArray array];
    for(NSUInteger i=0;i<names.count;i++){
        double y=57+i*32;
        NSImageView *icon=[[NSImageView alloc] initWithFrame:NSMakeRect(0,y+3,20,20)];
        icon.image=[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:names[i]];
        icon.contentTintColor=inks[i];[self addSubview:icon];
        NSTextField *name=[self label:names[i] frame:NSMakeRect(28,y+3,84,22) size:13];name.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        NSTextField *value=[self label:@"—" frame:NSMakeRect(120,y,134,25) size:15];
        value.font=[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];value.alignment=NSTextAlignmentRight;value.textColor=inks[i];[values addObject:value];
        NSTextField *cov=[self label:@"—" frame:NSMakeRect(264,y+3,136,22) size:12.5];
        cov.font=[NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];cov.alignment=NSTextAlignmentRight;cov.textColor=NSColor.secondaryLabelColor;[coverages addObject:cov];
    }
    _values=values;_coverages=coverages;
    _asOfLabel=[self label:@"" frame:NSMakeRect(0,199,310,20) size:11];_asOfLabel.textColor=NSColor.secondaryLabelColor;
    NSButton *details=[NSButton buttonWithTitle:@"Details…" target:self action:@selector(details:)];details.bezelStyle=NSBezelStyleRounded;details.frame=NSMakeRect(318,195,82,28);[self addSubview:details];
    [self refresh];return self;
}
- (NSArray *)periods {return self.periodControl.selectedSegment==1?self.report.weeks:self.report.days;}
- (void)changePeriod:(id)sender {(void)sender;self.index=0;[self refresh];}
- (void)previous:(id)sender {(void)sender;if(self.index+1<(NSInteger)self.periods.count)self.index++;[self refresh];}
- (void)next:(id)sender {(void)sender;if(self.index>0)self.index--;[self refresh];}
- (NSString *)date:(NSDate *)date format:(NSString *)format {
    NSDateFormatter *f=[NSDateFormatter new];f.timeZone=[NSTimeZone timeZoneWithName:self.report.timeZoneName];f.dateFormat=format;return [f stringFromDate:date];
}
- (void)refresh {
    NSArray *periods=self.periods;
    self.previousButton.enabled=self.index+1<(NSInteger)periods.count;self.nextButton.enabled=self.index>0;
    NSDictionary *p=self.index<(NSInteger)periods.count?periods[self.index]:nil;
    self.range.stringValue=p ? (self.periodControl.selectedSegment==0 ? [self date:p[@"start"] format:@"EEE d MMM yyyy"] :
        [NSString stringWithFormat:@"%@–%@",[self date:p[@"start"] format:@"d MMM"],[self date:[p[@"end"] dateByAddingTimeInterval:-1] format:@"d MMM yyyy"]]) : @"No history";
    NSArray *keys=@[@"solar",@"import",@"export",@"car"];
    for(NSUInteger i=0;i<keys.count;i++){
        NSDictionary *m=p[keys[i]];double known=[m[@"coverage"] doubleValue],span=[p[@"span"] doubleValue];
        NSString *prefix=[keys[i] isEqual:@"solar"]?@"≥":@"~";
        self.values[i].stringValue=known>0 ? [NSString stringWithFormat:@"%@%.1f",prefix,[m[@"wh"] doubleValue]/1000] : @"—";
        // Round coverage outward so a small missing interval cannot look complete.
        self.coverages[i].stringValue=p ? [NSString stringWithFormat:@"%.1f / %.1f h",floor(known/360+.000001)/10,ceil(span/360-.000001)/10] : @"—";
        self.values[i].accessibilityLabel=[NSString stringWithFormat:@"%@, %@ kilowatt hours, %@",keys[i],self.values[i].stringValue,[m[@"partial"] boolValue]?@"partial recorded total":@"integrated measured power"];
        self.coverages[i].accessibilityLabel=[NSString stringWithFormat:@"%@ coverage: %.0f seconds of %.0f elapsed seconds",keys[i],known,span];
    }
    self.asOfLabel.stringValue=self.report.error.length ? @"History unavailable · see Details" :
        [NSString stringWithFormat:@"Through %@ · recorded only",[self date:self.report.asOf format:@"d MMM HH:mm"]];
    self.asOfLabel.textColor=self.report.error.length?EBInkStale():NSColor.secondaryLabelColor;
}
- (void)details:(id)sender {
    (void)sender;NSAlert *a=[NSAlert new];a.messageText=@"Recorded energy";
    NSDictionary *p=self.index<(NSInteger)self.periods.count?self.periods[self.index]:nil;
    NSMutableArray *clocks=[NSMutableArray array];
    for(NSString *key in @[@"solar",@"import",@"export",@"car"]){
        double latest=[p[key][@"latest"] doubleValue];
        [clocks addObject:[NSString stringWithFormat:@"%@: %@",key,latest>0?[self date:[NSDate dateWithTimeIntervalSince1970:latest] format:@"d MMM yyyy HH:mm:ss z"]:@"no source reading"]];
    }
    a.informativeText=[NSString stringWithFormat:@"%@Grid and car: ~ marks approximate integration of measured power, with no bridging across missing readings or gaps over seven minutes. Coverage shows recorded hours out of elapsed hours, rounded outward; missing time is not zero. No forecasts are included.\n\nSolar: ≥ marks whole archive-register energy, a lower bound. Ambiguous day boundaries are omitted, and site completeness is not assumed. Coverage is averaged across observed inverter devices.\n\nLatest measurement used:\n%@\n\nWeeks start Monday in %@. Retention is 90 days, capped at 50,000 records per series. Data before collection or outside existing recovery caches is unavailable. Session totals are not added to power totals. Electricity prices remain in the existing Today view.",
        self.report.error.length?[self.report.error stringByAppendingString:@"\n\n"]:@"",[clocks componentsJoinedByString:@"\n"],self.report.timeZoneName];
    [a runModal];
}
@end

NSAlert *EBBuildStatisticsAlert(EBStatisticsReport *report) {
    NSAlert *alert=[NSAlert new];alert.messageText=@"Energy statistics";
    alert.icon=[NSImage imageWithSystemSymbolName:@"chart.bar.xaxis" accessibilityDescription:@"Energy statistics"];
    alert.accessoryView=[[EBStatisticsView alloc] initWithReport:report];[alert addButtonWithTitle:@"Close"];return alert;
}
