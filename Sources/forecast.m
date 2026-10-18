#import "forecast.h"
#import <math.h>

@implementation EBPowerForecastInput
- (instancetype)init { if ((self=[super init])) { _now=[NSDate date]; _solarSamples=@[]; _meterSamples=@[]; } return self; }
@end
@implementation EBPowerForecast
- (instancetype)init { if ((self=[super init])) { _rows=@[]; _detail=@"Forecast unavailable"; } return self; }
@end
static BOOL Number(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID() && isfinite([n doubleValue]);
}
static NSDate *ParsedDate(id value) {
    if ([value isKindOfClass:NSDate.class]) return value;
    if (Number(value)) return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSISO8601DateFormatter *f=[NSISO8601DateFormatter new];
    f.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d=[f dateFromString:value];
    if (!d) { f.formatOptions=NSISO8601DateFormatWithInternetDateTime; d=[f dateFromString:value]; }
    return d;
}
static double Median(NSArray<NSNumber *> *numbers) {
    if (!numbers.count) return NAN;
    NSArray *s=[numbers sortedArrayUsingSelector:@selector(compare:)]; NSUInteger n=s.count;
    return n%2 ? [s[n/2] doubleValue] : ([s[n/2-1] doubleValue]+[s[n/2] doubleValue])/2;
}
static BOOL Fresh(NSDate *date, NSDate *now, double age) {
    if (!date) return NO;
    double seconds=[now timeIntervalSinceDate:date]; return seconds>=-60 && seconds<=age;
}
double EBForecastCarMeanW(double w, NSDate *now, NSDate *finish, NSDate *start, NSDate *end) {
    double seconds=[end timeIntervalSinceDate:start];
    if (!isfinite(w) || w<0 || !now || !finish || !start || !end || seconds<=0) return 0;
    double overlap=fmax(0, fmin(end.timeIntervalSince1970,finish.timeIntervalSince1970)-fmax(start.timeIntervalSince1970,now.timeIntervalSince1970));
    return w*overlap/seconds;
}
NSDictionary *EBForecastBalance(double pv, double home, double car) {
    if (!isfinite(pv)||!isfinite(home)||!isfinite(car)||pv<0||home<0||car<0) return nil;
    double net=home+car-pv;
    double imported=fmax(0,net),carGrid=fmin(car,imported),homeGrid=imported-carGrid;
    return @{@"pvW":@(pv),@"homeW":@(home),@"chargeW":@(car),@"supplyW":@(net),
             @"importW":@(imported),@"exportW":@(fmax(0,-net)),
             @"carSolarW":@(car-carGrid),@"carGridW":@(carGrid),
             @"homeSolarW":@(home-homeGrid),@"homeGridW":@(homeGrid)};
}
NSDictionary *EBForecastAverage(NSArray<NSDictionary *> *rows, NSDate *start, NSDate *end) {
    if (!start || !end) return nil;
    double seconds=[end timeIntervalSinceDate:start], coverage=0;
    if (seconds<=0) return nil;
    NSArray *keys=@[@"pvW",@"homeW",@"chargeW",@"supplyW",@"importW",@"exportW",@"carSolarW",@"carGridW",@"homeSolarW",@"homeGridW",@"pvLowW",@"pvHighW"];
    NSMutableDictionary *sums=[NSMutableDictionary dictionary],*covered=[NSMutableDictionary dictionary];
    for (NSDictionary *r in rows) {
        NSDate *a=r[@"start"],*b=r[@"end"];
        if (![a isKindOfClass:NSDate.class]||![b isKindOfClass:NSDate.class]) continue;
        double n=fmax(0,fmin(end.timeIntervalSince1970,b.timeIntervalSince1970)-fmax(start.timeIntervalSince1970,a.timeIntervalSince1970));
        if (!n) continue;
        coverage+=n;
        for (NSString *key in keys) if (Number(r[key])) {
            sums[key]=@([sums[key] doubleValue]+[r[key] doubleValue]*n);
            covered[key]=@([covered[key] doubleValue]+n);
        }
    }
    if (fabs(coverage-seconds)>0.01) return nil;
    for (NSString *key in keys) {
        if (fabs([covered[key] doubleValue]-seconds)<=.01) sums[key]=@([sums[key] doubleValue]/seconds);
        else [sums removeObjectForKey:key];
    }
    return sums;
}
EBPowerForecast *EBBuildPowerForecast(EBPowerForecastInput *i) {
    EBPowerForecast *out=[EBPowerForecast new]; out.asOf=i.now;
    out.weatherFetchedAt=ParsedDate(i.weather[@"fetchedAt"]);
    NSString *solarIssue=nil,*homeIssue=nil,*carIssue=nil;
    if (!Fresh(out.weatherFetchedAt,i.now,7200)) solarIssue=@"weather missing or over 2 hours old";
    else if (!isfinite(i.inverterW)||i.inverterW<=0) solarIssue=@"inverter capacity unknown";
    NSDictionary *response=i.weather[@"response"];
    NSDictionary *hourly=[response isKindOfClass:NSDictionary.class] ? response[@"hourly"] : nil;
    NSDictionary *units=[response isKindOfClass:NSDictionary.class] ? response[@"hourly_units"] : nil;
    NSArray *times=[hourly isKindOfClass:NSDictionary.class] ? hourly[@"time"] : nil;
    NSArray *radiation=[hourly isKindOfClass:NSDictionary.class] ? hourly[@"shortwave_radiation"] : nil;
    BOOL validWeather=[units isKindOfClass:NSDictionary.class] &&
        [times isKindOfClass:NSArray.class] && [radiation isKindOfClass:NSArray.class] && times.count==radiation.count &&
        [units[@"time"] isEqual:@"unixtime"] && [@[@"W/m²",@"W/m2"] containsObject:units[@"shortwave_radiation"] ?: @""];
    if (!validWeather && !solarIssue) solarIssue=@"radiation units or intervals invalid";
    NSMutableArray *hours=[NSMutableArray array];
    double now=i.now.timeIntervalSince1970;
    if (validWeather) for (NSUInteger k=0;k<times.count;k++) {
        if (!Number(times[k])||!Number(radiation[k])||[radiation[k] doubleValue]<0) continue;
        double end=[times[k] doubleValue];
        [hours addObject:@{@"start":@(end-3600),@"end":@(end),@"ghi":radiation[k]}];
    }
    [hours sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
    // Invalid/overlapping weather intervals cannot support a calibrated solar curve.
    double lastEnd=-INFINITY;
    for (NSDictionary *h in hours) {
        if ([h[@"start"] doubleValue]<lastEnd) solarIssue=@"overlapping radiation intervals";
        lastEnd=[h[@"end"] doubleValue];
    }
    NSMutableArray *solar=[NSMutableArray array],*recent=[NSMutableArray array],*home=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,NSMutableArray *> *slots=[NSMutableDictionary dictionary];
    NSDate *latest=nil;
    for (NSDictionary *r in i.solarSamples) {
        NSDate *t=r[@"t"]; id w=r[@"pvW"];
        if (![t isKindOfClass:NSDate.class]||!Number(w)||[w doubleValue]<0||[t compare:i.now]==NSOrderedDescending) continue;
        [solar addObject:r]; if (!latest||[t compare:latest]==NSOrderedDescending) latest=t;
        if ([i.now timeIntervalSinceDate:t]<=900) [recent addObject:w];
        NSNumber *slot=@(floor(t.timeIntervalSince1970/300)*300);
        if (!slots[slot]) slots[slot]=[NSMutableArray array]; [slots[slot] addObject:w];
    }
    if (!Fresh(latest,i.now,600) && !solarIssue) solarIssue=@"solar measurements stale";
    NSMutableArray *ratios=[NSMutableArray array]; double currentGHI=NAN;
    for (NSDictionary *h in hours) {
        double a=[h[@"start"] doubleValue], b=[h[@"end"] doubleValue], ghi=[h[@"ghi"] doubleValue];
        if (a<=now && b>now) currentGHI=ghi;
        if (b>now || now-b>86400 || ghi<100) continue;
        NSMutableArray *means=[NSMutableArray array];
        for (NSNumber *slot in slots) if (slot.doubleValue>=a && slot.doubleValue<b) [means addObject:@(Median(slots[slot]))];
        if (means.count>=9) { double ratio=Median(means)/ghi; if (ratio>0 && isfinite(ratio)) [ratios addObject:@(ratio)]; }
    }
    if (ratios.count<3 && !solarIssue) solarIssue=@"insufficient overlapping solar measurements";
    if (!isfinite(currentGHI) && !solarIssue) solarIssue=@"no radiation interval covering now";
    double ratio=Median(ratios),low=0,high=0;
    if (!solarIssue) {
        if (currentGHI>=100&&recent.count>=2) ratio=Median(recent)/currentGHI;
        low=fmin([[ratios valueForKeyPath:@"@min.self"] doubleValue],ratio*.6);
        high=fmax([[ratios valueForKeyPath:@"@max.self"] doubleValue],ratio*1.4);
        out.solarAvailable=YES;
        out.solarValidUntil=[latest dateByAddingTimeInterval:600];
        NSDate *weatherEnd=[out.weatherFetchedAt dateByAddingTimeInterval:7200];
        if ([weatherEnd compare:out.solarValidUntil]==NSOrderedAscending) out.solarValidUntil=weatherEnd;
    }
    NSMutableSet *homeHours=[NSMutableSet set]; NSDate *latestHome=nil;
    for (NSDictionary *r in i.meterSamples) {
        NSDate *t=r[@"t"];
        if (![t isKindOfClass:NSDate.class]||!Fresh(t,i.now,10800)||[t compare:i.now]==NSOrderedDescending ||
            [r[@"statusOnly"] boolValue] || !Number(r[@"supplyW"])||!Number(r[@"chargeW"])||[r[@"chargeW"] doubleValue]<0) continue;
        NSDictionary *nearest=nil; double distance=151;
        for (NSDictionary *p in solar) { double d=fabs([t timeIntervalSinceDate:p[@"t"]]); if (d<distance) { distance=d; nearest=p; } }
        if (!nearest) continue;
        double residual=[nearest[@"pvW"] doubleValue]+[r[@"supplyW"] doubleValue]-[r[@"chargeW"] doubleValue];
        if (residual<0) continue;
        [home addObject:@(residual)]; [homeHours addObject:@(floor(t.timeIntervalSince1970/3600))];
        if (!latestHome || [t compare:latestHome]==NSOrderedDescending) latestHome=t;
    }
    if (home.count<12 || homeHours.count<2 || !Fresh(latestHome,i.now,3600)) homeIssue=@"insufficient aligned household history";
    else { out.homeAvailable=YES; out.homeValidUntil=[latestHome dateByAddingTimeInterval:3600]; }
    double homeW=Median(home),carW=0;
    BOOL charging=i.chargerState==EBChargerStateCharging || i.chargerState==EBChargerStateSolar;
    if (!Fresh(i.chargerStatusAt,i.now,150) || i.chargerState==EBChargerStateUnknown || i.chargerState==EBChargerStateFault)
        carIssue=@"charger state unknown, faulty or stale";
    else if (charging && !i.chargeEstimate.available && ![i.chargeEstimate.state isEqual:@"target-reached"])
        carIssue=i.chargeEstimate.detail.length ? i.chargeEstimate.detail : @"completion estimate unavailable";
    else if (charging && i.chargeEstimate.available) {
        if (!Fresh(i.chargerMeterAt,i.now,420) || !isfinite(i.chargerW)||i.chargerW<0 ||
            !isfinite(i.chargeEstimate.seconds)||i.chargeEstimate.seconds<=0) carIssue=@"charging power or completion time unavailable";
        else { carW=i.chargerW; out.carFinishesAt=[i.now dateByAddingTimeInterval:i.chargeEstimate.seconds]; }
    }
    if (!carIssue) {
        out.carAvailable=YES; out.carValidUntil=[i.chargerStatusAt dateByAddingTimeInterval:150];
        if (carW>0) {
            NSDate *meterEnd=[i.chargerMeterAt dateByAddingTimeInterval:420];
            if ([meterEnd compare:out.carValidUntil]==NSOrderedAscending) out.carValidUntil=meterEnd;
        }
    }
    out.gridAvailable=out.solarAvailable && out.homeAvailable && out.carAvailable;
    NSMutableArray *rows=[NSMutableArray array];
    // Keep separate component coverage; an unknown car never becomes a zero load.
    NSCalendar *calendar=NSCalendar.currentCalendar;
    NSDate *dayEnd=[calendar dateByAddingUnit:NSCalendarUnitDay value:1
                                     toDate:[calendar startOfDayForDate:i.now] options:0];
    // Include the whole local day even on a 25-hour daylight-saving transition.
    double horizon=fmax(now+24*3600,dayEnd.timeIntervalSince1970);
    NSMutableSet<NSNumber *> *bounds=[NSMutableSet setWithObjects:@(now),@(horizon),nil];
    for (NSDictionary *h in hours) for (NSString *key in @[@"start",@"end"]) {
        double t=[h[key] doubleValue]; if (t>now&&t<horizon) [bounds addObject:@(t)];
    }
    if (out.carFinishesAt && out.carFinishesAt.timeIntervalSince1970<horizon) [bounds addObject:@(out.carFinishesAt.timeIntervalSince1970)];
    NSArray *edges=[bounds.allObjects sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger k=0;k+1<edges.count;k++) {
        double a=[edges[k] doubleValue],b=[edges[k+1] doubleValue]; NSDictionary *weatherHour=nil;
        for (NSDictionary *h in hours) if ([h[@"start"] doubleValue]<=a && [h[@"end"] doubleValue]>=b) { weatherHour=h; break; }
        NSDate *start=[NSDate dateWithTimeIntervalSince1970:a],*end=[NSDate dateWithTimeIntervalSince1970:b];
        NSMutableDictionary *r=[NSMutableDictionary dictionary];
        if (out.solarAvailable && weatherHour) {
            r[@"pvW"]=@(fmin(i.inverterW,ratio*[weatherHour[@"ghi"] doubleValue]));
            r[@"pvLowW"]=@(fmin(i.inverterW,low*[weatherHour[@"ghi"] doubleValue]));
            r[@"pvHighW"]=@(fmin(i.inverterW,high*[weatherHour[@"ghi"] doubleValue]));
        }
        if (out.homeAvailable) r[@"homeW"]=@(homeW);
        if (out.carAvailable) r[@"chargeW"]=@(carW>0?EBForecastCarMeanW(carW,i.now,out.carFinishesAt,start,end):0);
        if (r[@"pvW"] && r[@"homeW"] && r[@"chargeW"])
            [r addEntriesFromDictionary:EBForecastBalance([r[@"pvW"] doubleValue],homeW,[r[@"chargeW"] doubleValue])];
        if (!r.count) continue;
        r[@"start"]=start; r[@"end"]=end; [rows addObject:r];
    }
    out.rows=rows; out.available=rows.count>0;
    NSMutableArray *details=[NSMutableArray arrayWithObject:@"Softly filled bars after Now are a conditional forecast, not scheduled controls."];
    if (solarIssue) [details addObject:[@"Solar unavailable · " stringByAppendingString:solarIssue]];
    else [details addObject:@"Solar uses Open-Meteo hourly radiation calibrated to measured PV, capped at the inverter rating; the broad scenario range is not a confidence interval. Roof angles are unverified."];
    [details addObject:homeIssue ? [@"Home unavailable · " stringByAppendingString:homeIssue]
        : @"Home is the recent 3-hour median residual excluding measured car load."];
    if (carIssue) [details addObject:[@"Car unavailable · " stringByAppendingString:carIssue]];
    else if (carW>0) [details addObject:[NSString stringWithFormat:@"Car holds current AC power until %@; the final interval is partial. Solar throttling, taper or a changed rate may delay completion.",
        i.chargeEstimate.targetKnown?@"the configured display target":@"hypothetical full (vehicle charge limit unknown)"]];
    else [details addObject:@"Car remains stopped, paused, disconnected or at the confirmed target; a restart requires a new reading."];
    if (!out.gridAvailable) [details addObject:@"Import/export and solar allocations are unavailable until solar, home and car are all known; missing car load is not zero."];
    if (out.weatherFetchedAt) {
        NSDateFormatter *clock=[NSDateFormatter new]; clock.dateFormat=@"EEE HH:mm z";
        [details addObject:[@"Weather fetched " stringByAppendingString:[clock stringFromDate:out.weatherFetchedAt]]];
    }
    out.detail=[details componentsJoinedByString:@" "];
    return out;
}

NSURL *EBForecastRequestURL(NSDictionary *settings) {
    if (![settings isKindOfClass:NSDictionary.class] || ![settings[@"enabled"] isEqual:@YES] ||
        ![settings[@"provider"] isEqual:@"Open-Meteo"] || ![settings[@"consentVersion"] isEqual:@1] ||
        !Number(settings[@"latitude"]) || !Number(settings[@"longitude"])) return nil;
    double lat=[settings[@"latitude"] doubleValue],lon=[settings[@"longitude"] doubleValue];
    if (fabs(lat)>90 || fabs(lon)>180) return nil;
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://api.open-meteo.com/v1/forecast"];
    url.queryItems=@[
        [NSURLQueryItem queryItemWithName:@"latitude" value:[NSString stringWithFormat:@"%.3f",lat]],
        [NSURLQueryItem queryItemWithName:@"longitude" value:[NSString stringWithFormat:@"%.3f",lon]],
        [NSURLQueryItem queryItemWithName:@"hourly" value:@"shortwave_radiation"],
        [NSURLQueryItem queryItemWithName:@"timeformat" value:@"unixtime"],
        [NSURLQueryItem queryItemWithName:@"timezone" value:@"UTC"],
        [NSURLQueryItem queryItemWithName:@"past_days" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"forecast_days" value:@"2"]
    ];
    return url.URL;
}
