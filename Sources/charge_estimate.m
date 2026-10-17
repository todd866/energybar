#import "charge_estimate.h"
#import <math.h>

@implementation EBChargeInput
- (instancetype)init { if ((self = [super init])) _now = [NSDate date]; return self; }
@end
@implementation EBChargeEstimate
- (NSDictionary *)dictionaryValue {
    return @{@"state": self.state, @"available": @(self.available),
        @"label": self.label, @"detail": self.detail,
        @"targetPercent": @(self.targetPercent), @"targetKnown": @(self.targetKnown),
        @"secondsAtCurrentRate": self.available ? @(self.seconds) : NSNull.null,
        @"estimatedPackW": self.available ? @(self.packW) : NSNull.null,
        @"powerSource": @"charger AC × configured efficiency", @"variablePower": @(self.variablePower),
        @"oemRemainingTimeAvailable": @NO, @"taperModelAvailable": @NO};
}
@end

static BOOL EBFresh(NSDate *date, NSDate *now, double maxAge) {
    if (!date) return NO;
    double age = [now timeIntervalSinceDate:date];
    return isfinite(age) && age >= -60 && age <= maxAge;
}

NSString *EBChargeDuration(double seconds) {
    if (!isfinite(seconds) || seconds <= 0) return @"";
    if (seconds < 300) return @"<5m";
    if (seconds < 3600) return [NSString stringWithFormat:@"~%.0fm", ceil(seconds / 300) * 5];
    if (seconds < 36 * 3600) return [NSString stringWithFormat:@"~%.1fh", ceil(seconds / 360) / 10];
    return @">36h";
}

EBChargeEstimate *EBEstimateCharge(EBChargeInput *i, NSArray<NSDictionary *> *samples) {
    EBChargeEstimate *r = [EBChargeEstimate new];
    r.targetKnown = isfinite(i.targetPercent) && i.targetPercent > 0 && i.targetPercent <= 100;
    r.targetPercent = r.targetKnown ? i.targetPercent : 100;
    r.state = @"unavailable"; r.label = @""; r.detail = @"ETA unavailable";
    NSString *destination = r.targetKnown
        ? [NSString stringWithFormat:@"to %.0f%%", r.targetPercent] : @"to full · limit unknown";
    if (!EBFresh(i.statusAt, i.now, 150) || i.state == EBChargerStateUnknown) {
        r.state = @"stale-status"; r.detail = @"ETA unavailable · charger status stale"; return r;
    }
    if (i.state == EBChargerStateUnplugged || i.state == EBChargerStateFault) {
        r.state = i.state == EBChargerStateUnplugged ? @"unplugged" : @"fault";
        r.detail = [@"ETA unavailable · " stringByAppendingString:r.state]; return r;
    }
    if (!i.hasSOC || !isfinite(i.soc) || i.soc < 0 || i.soc > 100) {
        r.state = @"battery-unavailable";
        r.detail = i.vehicleIssue.length ? [@"ETA unavailable · " stringByAppendingString:i.vehicleIssue]
                                        : @"ETA unavailable · battery level unknown";
        return r;
    }
    // Inferred SoC has already passed the integration continuity check through now.
    // A fresh helper check must not make an old direct vehicle measurement fresh.
    if (!i.socEstimated && !EBFresh(i.socAt, i.now, 1800)) {
        r.state = @"stale-battery"; r.detail = @"ETA unavailable · battery reading stale"; return r;
    }
    if (i.soc >= r.targetPercent) {
        r.state = i.socEstimated ? @"near-target" : @"target-reached";
        r.label = i.socEstimated ? @"≈full" : @"✓";
        if (r.targetPercent < 100 && i.socEstimated) r.label = @"≈target";
        r.detail = i.socEstimated ? @"Estimated target reached · awaiting vehicle confirmation"
                                  : [NSString stringWithFormat:@"%.0f%% reached", r.targetPercent];
        return r;
    }
    if (i.state == EBChargerStateWaiting) {
        r.state = @"paused"; r.detail = @"ETA paused · waiting for charge"; return r;
    }
    if (!i.meterAvailable || i.meterStale || !EBFresh(i.meterAt, i.now, 420)) {
        r.state = @"stale-meter"; r.detail = @"ETA unavailable · charger meter stale"; return r;
    }
    if (!isfinite(i.wallW) || i.wallW < 100) {
        r.state = @"paused"; r.detail = @"ETA paused · no charging power"; return r;
    }
    if (!isfinite(i.capacityWh) || i.capacityWh <= 0 || !isfinite(i.efficiency) ||
        i.efficiency <= 0 || i.efficiency > 1) {
        r.state = @"capacity-unavailable"; r.detail = @"ETA unavailable · usable capacity or efficiency unknown"; return r;
    }
    r.packW = i.wallW * i.efficiency;
    r.seconds = (r.targetPercent - i.soc) / 100 * i.capacityWh / r.packW * 3600;
    if (!isfinite(r.seconds) || r.seconds <= 0) return r;
    // Use the latest rate even at startup. Historical variability annotates the estimate;
    // it never gates the first reading or averages through a pause/taper.
    for (NSDictionary *row in samples) {
        NSDate *t = row[@"t"];
        id p = row[@"chargeW"];
        if (![t isKindOfClass:NSDate.class] || !EBFresh(t, i.now, 900) ||
            ![p isKindOfClass:NSNumber.class] || !isfinite([p doubleValue])) continue;
        if (fabs([p doubleValue] - i.wallW) > i.wallW * .2) r.variablePower = YES;
    }
    r.available = YES; r.state = @"charging"; r.label = EBChargeDuration(r.seconds);
    NSDate *finishAt = [i.now dateByAddingTimeInterval:ceil(r.seconds / 300) * 300];
    NSDateFormatter *clock = [NSDateFormatter new];
    clock.dateFormat = [NSCalendar.currentCalendar isDate:i.now inSameDayAsDate:finishAt] ? @"HH:mm" : @"EEE HH:mm";
    NSString *finish = [clock stringFromDate:finishAt];
    r.detail = [NSString stringWithFormat:@"%@ · ~%@ at this rate · %.0f%% AC→pack%@%@", destination,
        finish, i.efficiency * 100, r.variablePower ? @" · variable power" : @"",
        r.targetPercent == 100 ? @" · taper may extend" : @""];
    return r;
}
