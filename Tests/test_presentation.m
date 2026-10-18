// Exercise the real controller's presentation path without queries or hardware actions.
#define main EBEnergybarEntryPoint
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../Sources/main.m"
#pragma clang diagnostic pop
#undef main

@interface EBChartView (ForecastDetailsTesting)
- (NSString *)detailsForBar:(NSInteger)i;
- (NSInteger)barIndexForDate:(NSDate *)date;
@end

static int failures;
#define Expect(c, msg) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n", msg); failures++; } } while (0)
@interface EBTestPopover : NSPopover
@property BOOL visible;
@property NSUInteger shows, closes;
@end
@implementation EBTestPopover
- (BOOL)isShown { return self.visible; }
- (void)showRelativeToRect:(NSRect)r ofView:(NSView *)v preferredEdge:(NSRectEdge)e {
    (void)r; (void)v; (void)e; self.visible=YES; self.shows++;
}
- (void)performClose:(id)sender { (void)sender; self.visible=NO; self.closes++; }
@end
@interface EBTestApp : EBApp
@property NSUInteger refreshes, resolutions;
@end
@implementation EBTestApp
- (void)refresh { self.refreshes++; }
- (void)refreshForecastWeatherIfDue {}
- (void)resolveVehicleWithSamples:(NSArray *)samples sessions:(NSArray *)sessions {
    (void)samples; (void)sessions; self.resolutions++;
}
@end
static BOOL SpinUntil(BOOL (^condition)(void), double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return condition();
}
static EBSnapshot *Snapshot(double watts) {
    EBSnapshot *s=[EBSnapshot new];
    s.pvOK=YES; s.pvW=watts; s.pvAt=[NSDate date];
    s.gridOK=YES; s.gridAsOf=[NSDate date]; s.chargeW=3500;
    s.chargerOK=YES; s.haveOcpp=YES; s.ocppStatus=@"CHARGING";
    s.chargingLogic=@"Transfer"; s.chargingCurrentControl=@"SolarControl"; s.evnexAt=[NSDate date];
    return s;
}
static int Regression(void) {
    EBTestApp *app=[EBTestApp new]; app.config=[EBConfig new];
    app.config.samplesPath=@"/nonexistent-energybar-test/history.jsonl";
    app.config.statisticsPath=@""; // Presentation tests must never touch the owner's history.
    app.config.tariffPath=@"/nonexistent-energybar-test/tariff.json";
    app.config.orgId=@"test";
    [app preparePopover];
    Expect(app.views && app.popover, "startup must prepare a view before a status click");
    Expect(!app.popover.animates, "presentation animation must be disabled");
    Expect(!app.views.stopButton.enabled && !app.views.chargeNowButton.enabled,"startup must not enable commands before data");
    EBTestPopover *popover=[EBTestPopover new]; app.popover=popover;
    app.evnexPollInterval=30;
    // A held store queue proves opening doesn't wait for history/preparation.
    dispatch_semaphore_t entered=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0);
    dispatch_async(EBStoreQueue(), ^{ dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)); });
    Expect(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"store queue test barrier");
    app.snap=Snapshot(1000); [app updatePopoverBody];
    double start=NSProcessInfo.processInfo.systemUptime;
    [app togglePopover:nil];
    double openMS=(NSProcessInfo.processInfo.systemUptime-start)*1000;
    Expect(popover.shows==1 && app.presentationInFlight,"startup open must show while preparation is pending");
    Expect(openMS<100,"cached action should not block on delayed history");
    [app togglePopover:nil];
    Expect(popover.closes==1 && app.resolutions==0,"close must not load or resolve vehicle history");
    app.snap=Snapshot(4300); [app updatePopoverBody];
    dispatch_semaphore_signal(release);
    Expect(SpinUntil(^BOOL{ return !app.presentationInFlight; },3),"coalesced preparation must finish within bound");
    Expect(app.preparedViewModel.pvW==4300,"old completion must not overwrite newer snapshot");
    Expect(app.resolutions==1,"superseded preparation must not apply or resolve");
    Expect(app.views.stopButton.enabled && app.views.chargeNowButton.enabled,"commands must recover after startup preparation");
    Expect(!popover.shown && [app.views.solarRow.value isEqual:@"4.3"],"closed view must already contain newest data");
    EBSnapshotView *vm=app.preparedViewModel;
    vm.vehicleHasSOC=YES; vm.vehicleSOC=50; vm.vehicleSOCIsEstimate=YES;
    vm.vehicleCapacityWh=24000; vm.vehicleChargeEfficiency=.9; vm.vehicleSOCAt=[NSDate date];
    EBApplySnapshot(app.views,vm,@[]);
    NSString *eta=app.views.carRow.targetLabel;
    Expect(eta.length>0,"fresh charging should have ETA without history warmup");
    [app expirePreparedPresentationAt:vm.referenceDate];
    Expect([app.views.carRow.targetLabel isEqual:eta],"fresh cached estimate should remain");
    BOOL stopWasEnabled=app.views.stopButton.enabled;
    [app expirePreparedPresentationAt:[vm.referenceDate dateByAddingTimeInterval:500]];
    Expect(app.views.carRow.targetLabel.length==0 && app.views.carRow.trendFrom<0,"expired wake/open state must hide stale ETA and arrow");
    Expect(![app.views.detailsText containsString:eta],"Details must not retain expired ETA");
    Expect(app.views.stopButton.enabled==stopWasEnabled,"freshness guard must not change charger-control availability");
    vm.vehicleSOCIsEstimate=NO; vm.vehicleSOC=100; vm.vehicleSOCAt=vm.referenceDate;
    vm.gridStale=YES; EBApplySnapshot(app.views,vm,@[]);
    [app expirePreparedPresentationAt:vm.referenceDate];
    Expect(app.views.carRow.targetLabel.length==0 && app.views.carRow.targetFraction<0,
           "confirmed completion stays label-free after opening freshness guard");
    vm.vehicleSOCIsEstimate=YES;
    EBApplySnapshot(app.views,vm,@[]);
    [app expirePreparedPresentationAt:vm.referenceDate];
    Expect(app.views.carRow.targetLabel.length==0 && app.views.carRow.targetFraction<0,
           "inferred completion stays label-free after opening freshness guard");
    // Exercise the actual opening guard: an expired car does not expire fresh solar/home.
    EBPowerForecast *forecast=[EBPowerForecast new]; forecast.asOf=vm.referenceDate;
    forecast.available=forecast.solarAvailable=forecast.homeAvailable=forecast.carAvailable=forecast.gridAvailable=YES;
    forecast.solarValidUntil=[vm.referenceDate dateByAddingTimeInterval:600];
    forecast.homeValidUntil=[vm.referenceDate dateByAddingTimeInterval:3600];
    forecast.carValidUntil=[vm.referenceDate dateByAddingTimeInterval:150];
    NSMutableDictionary *row=[EBForecastBalance(4000,1000,3500) mutableCopy];
    row[@"pvLowW"]=@2400; row[@"pvHighW"]=@5000;
    row[@"start"]=vm.referenceDate; row[@"end"]=[vm.referenceDate dateByAddingTimeInterval:86400];
    forecast.rows=@[row]; vm.forecast=forecast;
    vm.gridStale=NO; vm.vehicleSOC=50; vm.vehicleSOCIsEstimate=NO;
    EBApplySnapshot(app.views,vm,@[]);
    [app expirePreparedPresentationAt:[vm.referenceDate dateByAddingTimeInterval:151]];
    NSString *projection=[app.views.chart detailsForBar:[app.views.chart barIndexForDate:vm.referenceDate]];
    Expect([projection containsString:@"Solar 4.0 kW"] && [projection containsString:@"Home 1.0 kW"] &&
           [projection containsString:@"Car — unavailable"] && [projection containsString:@"Import — unavailable"],
           "opening guard independently expires car and dependent grid without hiding solar/home");
    [app expirePreparedPresentationAt:[vm.referenceDate dateByAddingTimeInterval:601]];
    projection=[app.views.chart detailsForBar:[app.views.chart barIndexForDate:vm.referenceDate]];
    Expect([projection containsString:@"Solar — unavailable"] && [projection containsString:@"Home 1.0 kW"],
           "solar expiry retains independently current household baseline");
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    app.config.statisticsPath=[directory stringByAppendingPathComponent:@"statistics.json"];
    app.statisticsNextUpdateAt=nil;
    NSDate *observation=[NSDate date];
    app.learningPV=[@[@{@"t":[observation dateByAddingTimeInterval:-60],@"pvW":@1000},
                      @{@"t":observation,@"pvW":@1100}] mutableCopy];
    app.snap=Snapshot(1100);app.snap.chargingLogic=@"NoVehicle";
    [app updatePopoverBody];
    Expect(SpinUntil(^BOOL{ return !app.presentationInFlight; },3),"real learning preparation finishes off the opening path");
    NSString *learningPath=[directory stringByAppendingPathComponent:@"learning.json"];
    NSString *source=EBStableSourceID(@"statistics",@"0:/");NSError *error=nil;
    NSDictionary *ledger=EBLearningLoad(learningPath,source,&error);
    Expect(ledger && !error && [ledger[@"pv"] count]>=1,"real controller persists measured PV in private ledger");
    Expect([ledger[@"vintages"] count]==1 && [ledger[@"vintages"][0][@"prediction"][@"chargeW"] doubleValue]==0,
           "real controller freezes a future stopped-car scenario without inventing battery needs");
    Expect([ledger[@"vintages"][0][@"start"] doubleValue]>observation.timeIntervalSince1970,
           "controller vintage predates its target interval");
    NSData *unchanged=[NSData dataWithContentsOfFile:learningPath];[app updatePopoverBody];
    Expect(SpinUntil(^BOOL{ return !app.presentationInFlight; },3),"repeated prepared update completes");
    Expect([[NSData dataWithContentsOfFile:learningPath] isEqual:unchanged],"learning write cadence is bounded independently of UI updates");
    [@"corrupt" writeToFile:learningPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    app.statisticsNextUpdateAt=nil;[app updatePopoverBody];
    Expect(SpinUntil(^BOOL{ return !app.presentationInFlight; },3),"corrupt learning does not block preparation");
    Expect(app.preparedViewModel.forecast.learningError.length>0 && !app.learningModel,
           "controller exposes learning storage failure and stops using that model");
    Expect([[NSString stringWithContentsOfFile:learningPath encoding:NSUTF8StringEncoding error:nil] isEqual:@"corrupt"],
           "controller preserves corrupt learning history for recovery");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    printf("presentation regression: %s; opening with blocked history %.3f ms\n", failures?"FAILED":"ok",openMS);
    return failures?1:0;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication].activationPolicy=NSApplicationActivationPolicyProhibited;
        return Regression();
    }
}
