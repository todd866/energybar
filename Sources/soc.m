#import "soc.h"
#import "pure.h"
#import "store.h"
#import <math.h>

static NSNumber *EBSoCFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

NSDate *EBLatestSessionDisconnection(NSArray<NSDictionary *> *sessions,
                                     NSDate *after, NSDate *through) {
    if (!through) return nil;
    NSDate *latest = nil;
    for (id value in sessions ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDate *disconnectedAt = value[@"disconnectedAt"];
        if (![disconnectedAt isKindOfClass:NSDate.class]) continue;
        if (after && [disconnectedAt compare:after] != NSOrderedDescending) continue;
        if ([disconnectedAt compare:through] == NSOrderedDescending) continue;
        if (!latest || [disconnectedAt compare:latest] == NSOrderedDescending)
            latest = disconnectedAt;
    }
    return latest;
}

static NSArray<NSDictionary *> *EBExactSessions(NSArray<NSDictionary *> *sessions,
                                                 NSDate *anchorAt, NSDate *now) {
    NSMutableDictionary<NSString *, NSDictionary *> *latestByID =
        [NSMutableDictionary dictionary];
    for (id value in sessions ?: @[]) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *session = value;
        NSString *sessionID = session[@"id"];
        NSDate *start = session[@"chargeStart"];
        NSDate *end = session[@"chargeEnd"];
        NSNumber *energy = EBSoCFiniteNumber(session[@"energyWh"]);
        if (![sessionID isKindOfClass:NSString.class] || !sessionID.length ||
            ![start isKindOfClass:NSDate.class] || ![end isKindOfClass:NSDate.class] ||
            !energy || energy.doubleValue < 0) continue;
        if ([start compare:anchorAt] == NSOrderedAscending ||
            [end compare:now] == NSOrderedDescending ||
            [end compare:start] != NSOrderedDescending) continue;

        NSDictionary *candidate = @{
            @"id": sessionID,
            @"chargeStart": start,
            @"chargeEnd": end,
            @"energyWh": energy,
        };
        NSDictionary *previous = latestByID[sessionID];
        NSDate *previousEnd = previous[@"chargeEnd"];
        if (!previous || [end compare:previousEnd] != NSOrderedAscending)
            latestByID[sessionID] = candidate;
    }

    NSArray<NSDictionary *> *candidates = [latestByID.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult byStart = [a[@"chargeStart"] compare:b[@"chargeStart"]];
            if (byStart != NSOrderedSame) return byStart;
            return [a[@"chargeEnd"] compare:b[@"chargeEnd"]];
        }];

    // Overlap between different ids is inconsistent for this single-connector
    // estimator. Discard every record involved rather than risk double-counting.
    NSMutableIndexSet *ambiguous = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSDate *aEnd = candidates[i][@"chargeEnd"];
        for (NSUInteger j = i + 1; j < candidates.count; j++) {
            NSDate *bStart = candidates[j][@"chargeStart"];
            if ([bStart compare:aEnd] != NSOrderedAscending) break;
            [ambiguous addIndex:i];
            [ambiguous addIndex:j];
        }
    }

    NSMutableArray<NSDictionary *> *exact = [NSMutableArray array];
    [candidates enumerateObjectsUsingBlock:^(NSDictionary *candidate, NSUInteger idx,
                                              BOOL *stop) {
        (void)stop;
        if (![ambiguous containsIndex:idx]) [exact addObject:candidate];
    }];
    return exact;
}

typedef struct {
    BOOL unknown;
    NSTimeInterval unknownAt;
    NSTimeInterval gapSeconds;
} EBSoCContinuity;

static BOOL EBSoCSampleProvesContinuity(NSDictionary *row) {
    NSNumber *state = EBSoCFiniteNumber(row[@"st"]);
    if (state && trunc(state.doubleValue) == state.doubleValue) {
        switch ([state integerValue]) {
            case EBChargerStateWaiting:
            case EBChargerStateSolar:
            case EBChargerStateCharging:
                return YES;
            case EBChargerStateUnknown:
            case EBChargerStateUnplugged:
            case EBChargerStateFault:
                break;
        }
    }
    // Positive charger power is itself evidence that the vehicle was connected,
    // even if the independent status request failed for this poll.
    NSNumber *charge = EBSoCFiniteNumber(row[@"chargeW"]);
    return charge && charge.doubleValue > 0;
}

static EBSoCContinuity EBSoCCheckContinuity(
    NSArray<NSDictionary *> *samples, NSDate *anchorAt, NSDate *now,
    NSArray<NSDictionary *> *exactSessions) {
    EBSoCContinuity result = {0};
    if ([now compare:anchorAt] != NSOrderedDescending) return result;

    NSMutableArray<NSDictionary *> *evidence = [NSMutableArray array];
    for (id value in samples) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = value;
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class] || !EBSoCSampleProvesContinuity(row)) continue;
        if ([t compare:anchorAt] == NSOrderedAscending ||
            [t compare:now] == NSOrderedDescending) continue;
        [evidence addObject:@{@"start": t, @"end": t}];
    }
    for (NSDictionary *session in exactSessions) {
        [evidence addObject:@{
            @"start": session[@"chargeStart"],
            @"end": session[@"chargeEnd"],
        }];
    }
    [evidence sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byStart = [a[@"start"] compare:b[@"start"]];
        if (byStart != NSOrderedSame) return byStart;
        // Longer evidence first is deterministic and reaches the furthest frontier.
        return [b[@"end"] compare:a[@"end"]];
    }];

    NSDate *frontier = [anchorAt dateByAddingTimeInterval:EBStoreIntegrationGapSeconds];
    for (NSDictionary *component in evidence) {
        NSDate *start = component[@"start"];
        NSDate *end = component[@"end"];
        if ([end compare:anchorAt] == NSOrderedAscending) continue;
        if ([start compare:now] == NSOrderedDescending) break;
        if ([start compare:frontier] == NSOrderedDescending) break;
        NSDate *extended = [end dateByAddingTimeInterval:EBStoreIntegrationGapSeconds];
        if ([extended compare:frontier] == NSOrderedDescending) frontier = extended;
        if ([frontier compare:now] != NSOrderedAscending) return result;
    }

    if ([frontier compare:now] == NSOrderedAscending) {
        result.unknown = YES;
        NSDate *freshReadingCutoff =
            [now dateByAddingTimeInterval:-EBStoreIntegrationGapSeconds];
        NSDate *unknownAt = [frontier compare:freshReadingCutoff] == NSOrderedAscending
            ? freshReadingCutoff : frontier;
        result.unknownAt = unknownAt.timeIntervalSince1970;
        result.gapSeconds = [now timeIntervalSinceDate:frontier];
    }
    return result;
}

static double EBLinearChargeWh(double aW, double bW, NSTimeInterval fullSeconds,
                               NSTimeInterval fromSeconds, NSTimeInterval toSeconds) {
    if (fullSeconds <= 0 || toSeconds <= fromSeconds) return 0;
    double slope = (bW - aW) / fullSeconds;
    double fromW = aW + slope * fromSeconds;
    double toW = aW + slope * toSeconds;
    return 0.5 * (fromW + toW) * ((toSeconds - fromSeconds) / 3600.0);
}

static double EBLocalChargeWhExcludingSessions(NSArray<NSDictionary *> *samples,
                                                NSDate *anchorAt, NSDate *now,
                                                NSArray<NSDictionary *> *exactSessions) {
    NSMutableArray<NSDictionary *> *window = [NSMutableArray array];
    for (id value in samples) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDate *t = value[@"t"];
        if (![t isKindOfClass:NSDate.class]) continue;
        // Status-only checkpoints prove cable continuity and detect unplugging,
        // but are intentionally absent from the power series. Ignore them only
        // for energy adjacency; unmarked attempted-failure rows remain gaps.
        if ([value[@"statusOnly"] isEqual:@YES]) continue;
        if ([t compare:anchorAt] == NSOrderedAscending ||
            [t compare:now] == NSOrderedDescending) continue;
        [window addObject:value];
    }
    if (window.count < 2) return 0;

    double totalWh = 0;
    for (NSUInteger i = 1; i < window.count; i++) {
        NSDictionary *a = window[i - 1];
        NSDictionary *b = window[i];
        NSDate *aTime = a[@"t"];
        NSDate *bTime = b[@"t"];
        NSTimeInterval seconds = [bTime timeIntervalSinceDate:aTime];
        if (seconds <= 0 || seconds > EBStoreIntegrationGapSeconds) continue;
        NSNumber *aPower = EBSoCFiniteNumber(a[@"chargeW"]);
        NSNumber *bPower = EBSoCFiniteNumber(b[@"chargeW"]);
        if (!aPower || !bPower) continue;

        NSTimeInterval cursor = 0;
        for (NSDictionary *session in exactSessions) {
            NSDate *sessionStart = session[@"chargeStart"];
            NSDate *sessionEnd = session[@"chargeEnd"];
            if ([sessionEnd compare:aTime] != NSOrderedDescending) continue;
            if ([sessionStart compare:bTime] != NSOrderedAscending) break;
            NSTimeInterval excludedStart = fmax(0, [sessionStart timeIntervalSinceDate:aTime]);
            NSTimeInterval excludedEnd = fmin(seconds, [sessionEnd timeIntervalSinceDate:aTime]);
            if (excludedStart > cursor) {
                totalWh += EBLinearChargeWh(aPower.doubleValue, bPower.doubleValue,
                                             seconds, cursor, excludedStart);
            }
            if (excludedEnd > cursor) cursor = excludedEnd;
            if (cursor >= seconds) break;
        }
        if (cursor < seconds) {
            totalWh += EBLinearChargeWh(aPower.doubleValue, bPower.doubleValue,
                                         seconds, cursor, seconds);
        }
    }
    return totalWh;
}

EBSoCEstimate EBInferSoCWithSessions(NSArray<NSDictionary *> *samples,
                                     NSArray<NSDictionary *> *sessions,
                                     double anchorPct, NSDate *anchorAt,
                                     EBSoCSource anchorSource,
                                     double capacityWh, double efficiency, NSDate *now) {
    EBSoCEstimate out = (EBSoCEstimate){0};
    out.source = EBSoCSourceNone;
    if (!anchorAt || !now || !isfinite(anchorPct) || anchorPct < 0 ||
        !isfinite(capacityWh) || capacityWh <= 0 ||
        !isfinite(efficiency) || efficiency <= 0) return out;
    if (anchorSource == EBSoCSourceNone || anchorSource == EBSoCSourceFullCharge)
        return out;

    // Unplug after the anchor kills the estimate — driving is unknown consumption.
    for (NSDictionary *row in samples) {
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class]) continue;
        if ([t compare:anchorAt] == NSOrderedAscending) continue;
        if ([t compare:now] == NSOrderedDescending) continue;
        NSNumber *st = row[@"st"];
        if (![st isKindOfClass:NSNumber.class]) continue;
        if ([st integerValue] == EBChargerStateUnplugged) return out;
    }

    NSDate *sessionDisconnect = EBLatestSessionDisconnection(sessions, nil, now);
    if (sessionDisconnect &&
        [sessionDisconnect compare:anchorAt] != NSOrderedAscending) return out;

    NSArray<NSDictionary *> *exactSessions = EBExactSessions(sessions, anchorAt, now);
    EBSoCContinuity continuity = EBSoCCheckContinuity(
        samples, anchorAt, now, exactSessions);
    if (continuity.unknown) {
        out.source = anchorSource;
        out.anchorAge = fmax(0, [now timeIntervalSinceDate:anchorAt]);
        out.continuityUnknown = YES;
        out.unknownReason = EBSoCUnknownReasonTelemetryGap;
        out.continuityUnknownAt = continuity.unknownAt;
        out.continuityGapSeconds = continuity.gapSeconds;
        return out;
    }
    double exactSessionWh = 0;
    for (NSDictionary *session in exactSessions)
        exactSessionWh += [session[@"energyWh"] doubleValue];
    double localWh = EBLocalChargeWhExcludingSessions(samples, anchorAt, now, exactSessions);
    double addedWh = localWh + exactSessionWh;
    if (!isfinite(addedWh)) return out;
    double pct = anchorPct + (addedWh * efficiency / capacityWh) * 100.0;
    if (!isfinite(pct)) return out;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    out.known = YES;
    out.percent = pct;
    out.source = anchorSource;
    out.anchorAge = [now timeIntervalSinceDate:anchorAt];
    if (out.anchorAge < 0) out.anchorAge = 0;
    out.addedWh = addedWh;
    out.exactSessionWh = exactSessionWh;
    out.usedExactSessionEnergy = exactSessions.count > 0;
    return out;
}

EBSoCEstimate EBInferSoC(NSArray<NSDictionary *> *samples,
                         double anchorPct, NSDate *anchorAt,
                         EBSoCSource anchorSource,
                         double capacityWh, double efficiency, NSDate *now) {
    return EBInferSoCWithSessions(samples, nil, anchorPct, anchorAt, anchorSource,
                                  capacityWh, efficiency, now);
}
