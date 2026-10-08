#import "pure.h"
#import <math.h>

NSString *EBFmtKW(double watts) {
    double kw = watts / 1000.0;
    if (kw < 0) kw = -kw;
    return [NSString stringWithFormat:@"%.1f", kw];
}

NSString *EBGridSegment(double supplyActivePowerW) {
    double absW = supplyActivePowerW < 0 ? -supplyActivePowerW : supplyActivePowerW;
    NSString *mag = EBFmtKW(absW);
    if (supplyActivePowerW < -50.0) return [@"↑" stringByAppendingString:mag];
    if (supplyActivePowerW > 50.0) return [@"↓" stringByAppendingString:mag];
    return [@"·" stringByAppendingString:mag];
}

EBChargerState EBComputeChargerState(NSString *ocppStatus,
                                     NSString *chargingLogic,
                                     NSString *chargingCurrentControl,
                                     BOOL chargeNow,
                                     BOOL haveOcpp) {
    NSString *ocpp  = ocppStatus ?: @"";
    NSString *logic = chargingLogic ?: @"";
    NSString *ctrl  = chargingCurrentControl ?: @"";

    if ([ocpp isEqualToString:@"FAULTED"] ||
        [logic isEqualToString:@"Fault"] ||
        [logic isEqualToString:@"Unavailable"]) return EBChargerStateFault;

    // NoVehicle comes from the live status endpoint and is sufficient evidence
    // of an unplug even when the slower detail endpoint is unavailable.
    if ([logic isEqualToString:@"NoVehicle"])
        return EBChargerStateUnplugged;

    // These fields come from the live status endpoint and are stronger than a
    // cached connector document. Use them even when current OCPP is unavailable.
    if (chargeNow || [ctrl isEqualToString:@"FullPower"]) return EBChargerStateCharging;
    if ([ctrl isEqualToString:@"SolarControl"]) return EBChargerStateSolar;
    if ([ctrl isEqualToString:@"WaitingSolar"] ||
        [ctrl isEqualToString:@"WaitingSchedule"]) return EBChargerStateWaiting;

    if (!haveOcpp || ocpp.length == 0) return EBChargerStateUnknown;

    if ([ocpp isEqualToString:@"AVAILABLE"])
        return EBChargerStateUnplugged;

    if ([ocpp isEqualToString:@"CHARGING"]) return EBChargerStateCharging;
    // FINISHING means the transaction ended, not that the cable left the car.
    if ([ocpp isEqualToString:@"FINISHING"]) return EBChargerStateWaiting;
    return EBChargerStateUnknown;
}

double EBChargePowerForLiveStatus(double detailChargeW, BOOL statusOK,
                                  NSString *chargingLogic,
                                  NSString *chargingCurrentControl,
                                  BOOL chargeNow) {
    if (!statusOK) return detailChargeW;
    EBChargerState state = EBComputeChargerState(nil, chargingLogic,
                                                  chargingCurrentControl,
                                                  chargeNow, NO);
    if (state == EBChargerStateUnplugged || state == EBChargerStateWaiting ||
        state == EBChargerStateFault) return 0;
    return detailChargeW;
}

NSString *EBChargerWordForState(EBChargerState state) {
    switch (state) {
        case EBChargerStateUnplugged: return @"—";
        case EBChargerStateWaiting:   return @"wait";
        case EBChargerStateSolar:     return @"solar";
        case EBChargerStateCharging:  return @"charge";
        case EBChargerStateFault:     return @"!";
        case EBChargerStateUnknown:   break;
    }
    return @"?";
}

NSString *EBChargerLabelForState(EBChargerState state) {
    switch (state) {
        case EBChargerStateUnplugged: return @"Not plugged in";
        case EBChargerStateWaiting:   return @"Waiting for solar";
        case EBChargerStateSolar:     return @"Charging on solar";
        case EBChargerStateCharging:  return @"Charging at full power";
        case EBChargerStateFault:     return @"Charger fault";
        case EBChargerStateUnknown:   break;
    }
    return @"Charger state unknown";
}

NSString *EBChargerWord(NSString *ocppStatus, NSString *chargingLogic,
                        NSString *chargingCurrentControl, BOOL chargeNow) {
    return EBChargerWordForState(
        EBComputeChargerState(ocppStatus, chargingLogic, chargingCurrentControl, chargeNow, YES));
}

NSString *EBGlanceString(BOOL pvOK, double pvWatts,
                         BOOL gridOK, double supplyActivePowerW,
                         BOOL chargerOK,
                         NSString *ocppStatus,
                         NSString *chargingLogic,
                         NSString *chargingCurrentControl,
                         BOOL chargeNow) {
    NSString *sun = pvOK
        ? [NSString stringWithFormat:@"☀ %@", EBFmtKW(pvWatts)]
        : @"☀ —";
    NSString *grid = gridOK ? EBGridSegment(supplyActivePowerW) : @"·—";
    NSString *plug = chargerOK
        ? [NSString stringWithFormat:@"🔌 %@",
              EBChargerWord(ocppStatus, chargingLogic, chargingCurrentControl, chargeNow)]
        : @"🔌 —";
    return [NSString stringWithFormat:@"%@  %@  %@", sun, grid, plug];
}

static BOOL EBIsFault(NSString *ocpp, NSString *logic) {
    if ([ocpp isEqualToString:@"FAULTED"]) return YES;
    if ([logic isEqualToString:@"Fault"]) return YES;
    if ([logic isEqualToString:@"Unavailable"]) return YES;
    return NO;
}

EBBarState EBComputeBarState(BOOL pvOK, BOOL gridOK, BOOL chargerOK,
                             NSString *ocppStatus,
                             NSString *chargingLogic,
                             NSString *chargingCurrentControl,
                             BOOL chargeNow,
                             double supplyActivePowerW) {
    if (!pvOK && !chargerOK) return EBBarStateError;
    if (chargerOK && EBIsFault(ocppStatus ?: @"", chargingLogic ?: @"")) return EBBarStateError;

    if (chargerOK && EBComputeChargerState(ocppStatus, chargingLogic,
                                           chargingCurrentControl, chargeNow,
                                           ocppStatus.length > 0) == EBChargerStateUnknown)
        return EBBarStateWarn;

    if (!pvOK || !gridOK || !chargerOK) return EBBarStateWarn;

    NSString *ctrl = chargingCurrentControl ?: @"";
    if (chargeNow && supplyActivePowerW > 500.0) return EBBarStateWarn;
    if ([ctrl isEqualToString:@"WaitingSolar"] || [ctrl isEqualToString:@"WaitingSchedule"])
        return EBBarStateWarn;

    return EBBarStateOK;
}

NSTimeInterval EBNextPollInterval(NSTimeInterval current, BOOL success) {
    const NSTimeInterval base = 30, cap = 300;
    if (success) return base;
    NSTimeInterval next = (current < base ? base : current) * 2;
    return next > cap ? cap : next;
}

BOOL EBShouldBackoffEvnex(BOOL statusOK, BOOL rateLimited) {
    return !statusOK || rateLimited;
}

NSTimeInterval EBNextDetailPollInterval(NSTimeInterval meterAgeSeconds) {
    const NSTimeInterval normal = 5 * 60.0;
    const NSTimeInterval maximumFreshAge = 7 * 60.0;
    const NSTimeInterval catchupFloor = 30.0;
    const NSTimeInterval sourceGrace = 15.0;
    if (!isfinite(meterAgeSeconds) || meterAgeSeconds < -60.0 ||
        meterAgeSeconds > maximumFreshAge) return normal;
    NSTimeInterval untilExpectedUpdate = normal - meterAgeSeconds + sourceGrace;
    return fmin(normal, fmax(catchupFloor, untilExpectedUpdate));
}

BOOL EBDetailCurrentState(BOOL wasCurrent, BOOL attempted, BOOL successful) {
    return attempted ? successful : wasCurrent;
}

BOOL EBShouldUseLastMeterFallback(BOOL snapshotHasMeter, BOOL haveLastMeter) {
    return !snapshotHasMeter && haveLastMeter;
}

BOOL EBShouldPersistPoll(BOOL meterAttempted) {
    return meterAttempted;
}

NSString *EBFmtKWh(double wattHours) {
    double kwh = wattHours / 1000.0;
    if (kwh < 0) kwh = -kwh;
    return [NSString stringWithFormat:@"%.1f kWh", kwh];
}

NSString *EBFmtGridNow(double supplyActivePowerW) {
    return [NSString stringWithFormat:@"%@ kW", EBGridSegment(supplyActivePowerW)];
}

NSString *EBFmtGridDay(double exportWh, double importWh) {
    double net = exportWh - importWh; // + = net export
    double kwh = (net < 0 ? -net : net) / 1000.0;
    if (net > 50.0) return [NSString stringWithFormat:@"↑%.1f kWh", kwh];
    if (net < -50.0) return [NSString stringWithFormat:@"↓%.1f kWh", kwh];
    return [NSString stringWithFormat:@"·%.1f kWh", kwh];
}

NSString *EBBarGlyphName(BOOL pvOK, double pvW,
                         BOOL gridOK, double supplyW,
                         BOOL chargerOK, double chargeW,
                         NSInteger hour) {
    if (chargerOK && chargeW > 100.0) return @"bolt.fill";

    BOOL makingPV = pvOK && pvW > 50.0;
    // The inverter knows when the sun is up (it reads 0 W asleep); the clock is only the
    // fallback when solar is unknown. A fixed 06–19 showed a cloud after a Perth sunset.
    BOOL daytime = pvOK ? makingPV : (hour >= 6 && hour < 19);

    if (!daytime) return @"moon.fill";

    BOOL exporting = gridOK && supplyW < -50.0;
    if (exporting) return @"sun.max.fill";
    return @"cloud.fill";
}

NSString *EBBarGlyphNameForState(EBBarState state, BOOL chargerStateKnown,
                                 BOOL pvOK, double pvW,
                                 BOOL gridOK, double supplyW,
                                 BOOL chargerOK, double chargeW,
                                 NSInteger hour) {
    if (state == EBBarStateError) return @"exclamationmark.triangle.fill";
    if (state == EBBarStateWarn &&
        (!pvOK || !gridOK || !chargerOK || !chargerStateKnown))
        return @"questionmark.circle.fill";
    return EBBarGlyphName(pvOK, pvW, gridOK, supplyW, chargerOK, chargeW, hour);
}

NSString *EBCoverageNote(NSTimeInterval coverageSeconds, NSTimeInterval spanSeconds) {
    if (spanSeconds <= 0) return nil;
    if (coverageSeconds >= spanSeconds * 0.9) return nil;
    if (coverageSeconds < spanSeconds * 0.01) return @"no data";
    return @"partial";
}

EBMatchState EBComputeMatchState(BOOL gridOK, double supplyW,
                                 BOOL chargerOK, double chargeW,
                                 BOOL vehicleHasReady, BOOL vehicleReady,
                                 BOOL vehicleHasSOC, double vehicleSOC) {
    if (!gridOK && !chargerOK) return EBMatchOffline;
    if (!gridOK) return EBMatchUnknown;

    BOOL charging = chargerOK && chargeW >= 100.0;
    BOOL importing = gridOK && supplyW >= 100.0;
    BOOL exporting = gridOK && supplyW <= -100.0;
    // Meets the import threshold: 50–100 W of import while charging is noise, not grid charging.
    BOOL balancedOrExport = gridOK && supplyW < 100.0;

    if (charging) {
        if (importing) return EBMatchChargingFromGrid;
        if (balancedOrExport) return EBMatchMatchingSolar;
        return EBMatchChargingFromGrid;
    }

    if (exporting) {
        if (vehicleHasReady && !vehicleReady) return EBMatchIdle;
        if (vehicleHasSOC && vehicleSOC >= 90.0) return EBMatchIdle;
        return EBMatchSurplusUnused;
    }

    return EBMatchIdle;
}

NSString *EBMatchLabel(EBMatchState state) {
    switch (state) {
        case EBMatchMatchingSolar:     return @"Matching solar";
        case EBMatchChargingFromGrid:  return @"Charging from grid";
        case EBMatchSurplusUnused:     return @"Surplus unused";
        case EBMatchIdle:              return @"Idle";
        case EBMatchOffline:           return @"Offline";
        case EBMatchUnknown:           return @"Grid data unknown";
    }
    return @"Idle";
}

EBBarState EBBarStateForMatch(EBMatchState state) {
    switch (state) {
        case EBMatchMatchingSolar:     return EBBarStateOK;
        case EBMatchChargingFromGrid:  return EBBarStateError;
        case EBMatchSurplusUnused:     return EBBarStateWarn;
        case EBMatchOffline:           return EBBarStateError;
        case EBMatchIdle:              return EBBarStateWarn;
        case EBMatchUnknown:           return EBBarStateWarn;
    }
    return EBBarStateWarn;
}
