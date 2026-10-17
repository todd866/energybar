#import <Cocoa/Cocoa.h>
#import "statistics.h"

NS_ASSUME_NONNULL_BEGIN
/// Standard Day/Week selector, previous/next navigation and four metric rows.
/// The report is precomputed; opening and navigation perform no I/O.
@interface EBStatisticsView : NSView
@property(strong) EBStatisticsReport *report;
@property(readonly) NSSegmentedControl *periodControl;
@property(readonly) NSButton *previousButton;
@property(readonly) NSButton *nextButton;
@property(readonly) NSArray<NSTextField *> *values;
@property(readonly) NSArray<NSTextField *> *coverages;
- (instancetype)initWithReport:(EBStatisticsReport *)report;
@end
NSAlert *EBBuildStatisticsAlert(EBStatisticsReport *report);
NS_ASSUME_NONNULL_END
