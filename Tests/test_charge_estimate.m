#import <Foundation/Foundation.h>
#import "charge_estimate.h"
#import <math.h>
#define expect(c,m) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",m); return 1; } } while(0)

int main(void) { @autoreleasepool {
    NSDate *now = [NSDate date];
    EBChargeInput *i = [EBChargeInput new];
    i.now = now; i.statusAt = now; i.meterAt = now; i.socAt = now;
    i.state = EBChargerStateSolar; i.meterAvailable = YES;
    i.hasSOC = YES; i.soc = 50; i.capacityWh = 24000; i.efficiency = .9; i.wallW = 3200;
    EBChargeEstimate *r = EBEstimateCharge(i, @[]);
    expect(r.available && r.label.length, "startup needs no history to show a fresh active rate");
    expect(fabs(r.seconds - 12000 / (3200 * .9) * 3600) < .01, "AC losses applied exactly once");
    expect(!r.targetKnown && [r.detail containsString:@"limit unknown"], "full projection does not invent a charge cap");
    i.targetPercent = 90;
    r = EBEstimateCharge(i, @[]);
    expect(r.targetKnown && fabs(r.seconds - 9600 / (3200 * .9) * 3600) < .01, "configured target, never laptop 80 percent");
    i.soc = 89.9;
    expect([EBEstimateCharge(i, @[]).label isEqual:@"<5m"], "near target cannot round to zero or complete");
    i.soc = 90;
    expect([EBEstimateCharge(i, @[]).state isEqual:@"target-reached"], "direct target reached");
    i.socEstimated = YES;
    expect([EBEstimateCharge(i, @[]).state isEqual:@"near-target"], "inferred clamp never claims confirmed completion");
    i.soc = 50; i.socEstimated = NO;
    i.state = EBChargerStateWaiting;
    expect(!EBEstimateCharge(i, @[]).available, "paused status rejects lingering positive meter power");
    i.state = EBChargerStateUnplugged;
    expect([EBEstimateCharge(i, @[]).state isEqual:@"unplugged"], "disconnected hides projection");
    i.state = EBChargerStateSolar; i.wallW = 0;
    expect([EBEstimateCharge(i, @[]).state isEqual:@"paused"], "zero rate is paused, never full");
    i.wallW = 3200; i.meterStale = YES;
    expect(!EBEstimateCharge(i, @[]).available, "stale fallback never supplies ETA");
    i.meterStale = NO; i.meterAt = [now dateByAddingTimeInterval:-421];
    expect(!EBEstimateCharge(i, @[]).available, "meter freshness ages even without a new failed poll");
    i.meterAt = now; i.statusAt = [now dateByAddingTimeInterval:-151];
    expect(!EBEstimateCharge(i, @[]).available, "status expires independently of meter");
    i.statusAt = now; i.socAt = [now dateByAddingTimeInterval:-1801];
    expect(!EBEstimateCharge(i, @[]).available, "old direct SoC cannot supply ETA");
    i.socAt = [now dateByAddingTimeInterval:120];
    expect(!EBEstimateCharge(i, @[]).available, "future timestamps rejected");
    i.socAt = now; i.hasSOC = NO; i.vehicleIssue = @"vehicle cloud: signed out";
    r = EBEstimateCharge(i, @[]);
    expect([r.detail containsString:@"signed out"] && !r.available, "live observed missing-SoC failure is explained");
    i.hasSOC = YES; i.capacityWh = 0;
    expect(!EBEstimateCharge(i, @[]).available, "no hardcoded pack capacity");
    i.capacityWh = 24000; i.efficiency = NAN;
    expect(!EBEstimateCharge(i, @[]).available, "invalid efficiency rejected");
    i.efficiency = .9;
    NSArray *changing = @[@{@"t":[now dateByAddingTimeInterval:-300], @"chargeW":@1400},
                         @{@"t":now, @"supplyW":@9000, @"pvW":@20000}];
    r = EBEstimateCharge(i, changing);
    expect(r.available && r.variablePower && fabs(r.packW - 2880) < .01,
           "changing rate annotated; house/grid/PV power never used as car power");
    i.wallW = 1000;
    expect(EBEstimateCharge(i, changing).seconds > r.seconds * 3, "taper immediately lengthens estimate at latest rate");
    expect([EBChargeDuration(60) isEqual:@"<5m"] && [EBChargeDuration(2600) isEqual:@"~45m"] &&
           [EBChargeDuration(5400) isEqual:@"~1.5h"] && [EBChargeDuration(INFINITY) isEqual:@""], "compact conservative formatting");
    puts("ok: charge estimate startup, target, pause, freshness, variability and provenance");
} return 0; }
