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
    double seconds=[end timeIntervalSinceDate:start], coverage=0;
    if (seconds<=0) return nil;
    NSArray *keys=@[@"pvW",@"homeW",@"chargeW",@"supplyW",@"importW",@"exportW",@"carSolarW",@"carGridW",@"homeSolarW",@"homeGridW",@"pvLowW",@"pvHighW"];
    NSMutableDictionary *sums=[NSMutableDictionary dictionary];
    for (NSDictionary *r in rows) {
        NSDate *a=r[@"start"],*b=r[@"end"];
        if (![a isKindOfClass:NSDate.class]||![b isKindOfClass:NSDate.class]) continue;
        double n=fmax(0,fmin(end.timeIntervalSince1970,b.timeIntervalSince1970)-fmax(start.timeIntervalSince1970,a.timeIntervalSince1970));
        if (!n) continue;
        coverage+=n;
        for (NSString *key in keys) sums[key]=@([sums[key] doubleValue]+[r[key] doubleValue]*n);
    }
    if (fabs(coverage-seconds)>0.01) return nil;
    for (NSString *key in keys) sums[key]=@([sums[key] doubleValue]/seconds);
    return sums;
}
EBPowerForecast *EBBuildPowerForecast(EBPowerForecastInput *i) {
    EBPowerForecast *out=[EBPowerForecast new]; out.asOf=i.now;
    out.weatherFetchedAt=ParsedDate(i.weather[@"fetchedAt"]);
    if (!Fresh(out.weatherFetchedAt,i.now,7200)) { out.detail=@"Forecast unavailable · weather missing or over 2 hours old"; return out; }
    if (!Fresh(i.chargerStatusAt,i.now,150) || i.chargerState==EBChargerStateUnknown || i.chargerState==EBChargerStateFault) {
        out.detail=@"Forecast unavailable · charger state unknown or stale"; return out;
    }
    BOOL charging=i.chargerState==EBChargerStateCharging || i.chargerState==EBChargerStateSolar;
    if (charging && !i.chargeEstimate.available && ![i.chargeEstimate.state isEqual:@"target-reached"]) {
        out.detail=[@"Forecast unavailable · " stringByAppendingString:i.chargeEstimate.detail ?: @"charging estimate unavailable"]; return out;
    }
    if (!isfinite(i.inverterW)||i.inverterW<=0) { out.detail=@"Forecast unavailable · inverter capacity unknown"; return out; }
    NSDictionary *response=i.weather[@"response"];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"hourly"] isKindOfClass:NSDictionary.class] || ![response[@"hourly_units"] isKindOfClass:NSDictionary.class]) {
        out.detail=@"Forecast unavailable · invalid weather document"; return out;
    }
    NSDictionary *hourly=response[@"hourly"],*units=response[@"hourly_units"];
    NSArray *times=hourly[@"time"],*radiation=hourly[@"shortwave_radiation"];
    if (![times isKindOfClass:NSArray.class] || ![radiation isKindOfClass:NSArray.class] || times.count!=radiation.count ||
        ![units[@"time"] isEqual:@"unixtime"] || ![@[@"W/m²",@"W/m2"] containsObject:units[@"shortwave_radiation"] ?: @""]) {
        out.detail=@"Forecast unavailable · radiation units or intervals invalid"; return out;
    }
    NSMutableArray *hours=[NSMutableArray array];
    double now=i.now.timeIntervalSince1970;
    for (NSUInteger k=0;k<times.count;k++) {
        if (!Number(times[k])||!Number(radiation[k])||[radiation[k] doubleValue]<0) continue;
        double end=[times[k] doubleValue];
        [hours addObject:@{@"start":@(end-3600),@"end":@(end),@"ghi":radiation[k]}];
    }
    [hours sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
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
    if (!Fresh(latest,i.now,600)) { out.detail=@"Forecast unavailable · solar measurements stale"; return out; }
    NSMutableArray *ratios=[NSMutableArray array]; double currentGHI=NAN;
    for (NSDictionary *h in hours) {
        double a=[h[@"start"] doubleValue], b=[h[@"end"] doubleValue], ghi=[h[@"ghi"] doubleValue];
        if (a<=now && b>now) currentGHI=ghi;
        if (b>now || now-b>86400 || ghi<100) continue;
        NSMutableArray *means=[NSMutableArray array];
        for (NSNumber *slot in slots) if (slot.doubleValue>=a && slot.doubleValue<b) [means addObject:@(Median(slots[slot]))];
        if (means.count>=9) { double ratio=Median(means)/ghi; if (ratio>0 && isfinite(ratio)) [ratios addObject:@(ratio)]; }
    }
    if (ratios.count<3) { out.detail=@"Forecast unavailable · insufficient overlapping solar measurements"; return out; }
    double ratio=Median(ratios);
    if (isfinite(currentGHI)&&currentGHI>=100&&recent.count>=2) ratio=Median(recent)/currentGHI;
    double low=fmin([[ratios valueForKeyPath:@"@min.self"] doubleValue],ratio*.6);
    double high=fmax([[ratios valueForKeyPath:@"@max.self"] doubleValue],ratio*1.4);
    NSMutableSet *homeHours=[NSMutableSet set]; NSDate *latestHome=nil;
    for (NSDictionary *r in i.meterSamples) {
        NSDate *t=r[@"t"];
        if (![t isKindOfClass:NSDate.class]||!Fresh(t,i.now,10800)||[t compare:i.now]==NSOrderedDescending ||
            !Number(r[@"supplyW"])||!Number(r[@"chargeW"])||[r[@"chargeW"] doubleValue]<0) continue;
        NSDictionary *nearest=nil; double distance=151;
        for (NSDictionary *p in solar) { double d=fabs([t timeIntervalSinceDate:p[@"t"]]); if (d<distance) { distance=d; nearest=p; } }
        if (!nearest) continue;
        double residual=[nearest[@"pvW"] doubleValue]+[r[@"supplyW"] doubleValue]-[r[@"chargeW"] doubleValue];
        if (residual<0) continue;
        [home addObject:@(residual)]; [homeHours addObject:@(floor(t.timeIntervalSince1970/3600))];
        if (!latestHome || [t compare:latestHome]==NSOrderedDescending) latestHome=t;
    }
    if (home.count<12 || homeHours.count<2 || !Fresh(latestHome,i.now,3600)) { out.detail=@"Forecast unavailable · insufficient aligned household history"; return out; }
    double homeW=Median(home),carW=charging&&i.chargeEstimate.available?i.chargerW:0;
    if (!isfinite(carW)||carW<0) { out.detail=@"Forecast unavailable · charger power invalid"; return out; }
    if (carW>0) out.carFinishesAt=[i.now dateByAddingTimeInterval:i.chargeEstimate.seconds];
    NSMutableArray *rows=[NSMutableArray array];
    // Exact hour and charging-finish boundaries avoid redistributing the final charge interval.
    NSMutableSet<NSNumber *> *bounds=[NSMutableSet setWithObjects:@(now),@(now+24*3600),nil];
    for (NSDictionary *h in hours) {
        for (NSString *key in @[@"start",@"end"]) { double t=[h[key] doubleValue]; if (t>now&&t<now+24*3600) [bounds addObject:@(t)]; }
    }
    if (out.carFinishesAt && out.carFinishesAt.timeIntervalSince1970<now+24*3600) [bounds addObject:@(out.carFinishesAt.timeIntervalSince1970)];
    NSArray *edges=[bounds.allObjects sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger k=0;k+1<edges.count;k++) {
        double a=[edges[k] doubleValue],b=[edges[k+1] doubleValue]; NSDictionary *weatherHour=nil;
        for (NSDictionary *h in hours) if ([h[@"start"] doubleValue]<=a && [h[@"end"] doubleValue]>=b) { weatherHour=h; break; }
        if (!weatherHour) continue;
        NSDate *start=[NSDate dateWithTimeIntervalSince1970:a],*end=[NSDate dateWithTimeIntervalSince1970:b];
        double pv=fmin(i.inverterW,ratio*[weatherHour[@"ghi"] doubleValue]);
        double car=carW>0?EBForecastCarMeanW(carW,i.now,out.carFinishesAt,start,end):0;
        NSMutableDictionary *r=[EBForecastBalance(pv,homeW,car) mutableCopy];
        r[@"start"]=start; r[@"end"]=end;
        r[@"pvLowW"]=@(fmin(i.inverterW,low*[weatherHour[@"ghi"] doubleValue]));
        r[@"pvHighW"]=@(fmin(i.inverterW,high*[weatherHour[@"ghi"] doubleValue])); [rows addObject:r];
    }
    out.rows=rows; out.available=rows.count>0;
    NSString *carBasis=carW>0 ? @"Car holds the current AC charging power until the displayed target; the final interval is partial. Solar throttling, taper or a changed rate may delay completion."
        : @"Car remains stopped, paused, disconnected or at the estimated target; a restart requires a new reading.";
    NSDateFormatter *fetchedClock=[NSDateFormatter new]; fetchedClock.dateFormat=@"EEE HH:mm z";
    out.detail=[NSString stringWithFormat:@"Outlined bars are a conditional forecast, not scheduled controls. %@ %@ Solar uses Open-Meteo hourly radiation calibrated to measured PV, capped at the inverter rating; the interval details show a broad scenario range, not a confidence interval. Home is the recent 3-hour median residual excluding car load. Weather fetched %@; roof angles are unverified.",
        carBasis,i.chargeEstimate.targetKnown?@"The configured display target is used.":@"Vehicle charge limit unknown; full is hypothetical.",[fetchedClock stringFromDate:out.weatherFetchedAt]];
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
