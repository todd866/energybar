#import <Foundation/Foundation.h>
#import <math.h>
#import "forecast.h"
static int fails;
#define Expect(c,msg) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",msg); fails++; } } while(0)
static NSDate *At(NSDate *now,double seconds) { return [now dateByAddingTimeInterval:seconds]; }
static EBPowerForecastInput *Input(void) {
    EBPowerForecastInput *i=[EBPowerForecastInput new]; i.now=[NSDate dateWithTimeIntervalSince1970:1792213200];
    i.inverterW=5000; i.chargerW=3500; i.chargerState=EBChargerStateSolar; i.chargerStatusAt=i.now; i.chargerMeterAt=i.now;
    NSMutableArray *pv=[NSMutableArray array],*meters=[NSMutableArray array],*times=[NSMutableArray array],*ghi=[NSMutableArray array];
    for (int n=-48;n<=0;n++) {
        NSDate *t=At(i.now,n*300); [pv addObject:@{@"t":t,@"pvW":@4000}];
        [meters addObject:@{@"t":t,@"chargeW":@3500,@"supplyW":@500}];
    }
    for (int n=-4;n<=25;n++) { [times addObject:@(At(i.now,n*3600).timeIntervalSince1970)]; [ghi addObject:@500]; }
    i.solarSamples=pv;i.meterSamples=meters;
    i.weather=@{@"fetchedAt":i.now,@"response":@{@"hourly":@{@"time":times,@"shortwave_radiation":ghi},@"hourly_units":@{@"time":@"unixtime",@"shortwave_radiation":@"W/m²"}}};
    EBChargeInput *charge=[EBChargeInput new]; charge.now=i.now; charge.hasSOC=YES;charge.socEstimated=YES;
    charge.soc=100-3500*.9*(2.5+2.0/60)/24000*100;charge.socAt=i.now;charge.capacityWh=24000;charge.efficiency=.9;
    charge.state=EBChargerStateSolar;charge.statusAt=i.now;charge.meterAvailable=YES;charge.meterAt=i.now;charge.wallW=3500;
    i.chargeEstimate=EBEstimateCharge(charge,@[]);return i;
}
int main(void) { @autoreleasepool {
    EBPowerForecastInput *i=Input(); EBPowerForecast *f=EBBuildPowerForecast(i);
    Expect(f.available && f.solarAvailable && f.homeAvailable && f.carAvailable && f.gridAvailable,"valid measured data must produce all forecast components");
    Expect(fabs([f.carFinishesAt timeIntervalSinceDate:i.now]-9120)<.001,"completion must use unrounded ETA, not hardcoded hours");
    NSDictionary *before=EBForecastAverage(f.rows,At(i.now,0),At(i.now,900));
    Expect(fabs([before[@"chargeW"] doubleValue]-3500)<.001,"before finish current charger AC rate");
    Expect(fabs([before[@"homeW"] doubleValue]-1000)<.001,"household baseline must exclude charger load");
    NSDictionary *last=EBForecastAverage(f.rows,At(i.now,9000),At(i.now,9900));
    Expect(fabs([last[@"chargeW"] doubleValue]-3500*120/900.0)<.001,"fractional final 15-minute interval");
    Expect(fabs([last[@"importW"] doubleValue]-500*120/900.0)<.001,"partial interval retains gross import");
    Expect(fabs([last[@"exportW"] doubleValue]-3000*780/900.0)<.001,"partial interval retains gross export");
    NSDictionary *after=EBForecastAverage(f.rows,At(i.now,9900),At(i.now,10800));
    Expect([after[@"chargeW"] doubleValue]==0 && fabs([after[@"exportW"] doubleValue]-3000)<.001,"car stops and released solar becomes export");
    double energy=0;
    for (NSDictionary *r in f.rows) {
        double dt=[r[@"end"] timeIntervalSinceDate:r[@"start"]];energy += [r[@"chargeW"] doubleValue]*dt/3600;
        double balance=[r[@"pvW"] doubleValue]+[r[@"importW"] doubleValue]-[r[@"homeW"] doubleValue]-[r[@"chargeW"] doubleValue]-[r[@"exportW"] doubleValue];
        Expect(fabs(balance)<.001,"each forecast interval must conserve energy");
    }
    Expect(fabs(energy-3500*9120/3600.0)<.001,"AC energy stops exactly at target with efficiency applied once");
    i.chargeEstimate.seconds=30; f=EBBuildPowerForecast(i);
    Expect(fabs([EBForecastAverage(f.rows,i.now,At(i.now,900))[@"chargeW"] doubleValue]-3500/30.0)<.001,"near target first interval fraction");
    i.chargeEstimate.seconds=3600;i.chargerW=1750; f=EBBuildPowerForecast(i);
    Expect([EBForecastAverage(f.rows,i.now,At(i.now,900))[@"chargeW"] doubleValue]==1750,"rate changes rebuild from latest estimate");
    i.chargerState=EBChargerStateWaiting;f=EBBuildPowerForecast(i);
    Expect(f.available && [EBForecastAverage(f.rows,i.now,At(i.now,900))[@"chargeW"] doubleValue]==0,"paused scenario does not project charging");
    i.chargerState=EBChargerStateUnplugged;f=EBBuildPowerForecast(i);
    Expect(f.available && !f.carFinishesAt,"unplugged has no invented finish");
    i=Input();i.chargerStatusAt=At(i.now,-151);f=EBBuildPowerForecast(i);
    Expect(f.solarAvailable && f.homeAvailable && !f.carAvailable && !f.gridAvailable,"stale car status must retain solar and home");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"near-target";f=EBBuildPowerForecast(i);
    Expect(f.solarAvailable && f.homeAvailable && !f.carAvailable,"inferred full keeps solar/home while awaiting car confirmation");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"target-reached";f=EBBuildPowerForecast(i);
    Expect(f.available && f.gridAvailable && !f.carFinishesAt,"confirmed target has no projected charging load");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"battery-unavailable";i.chargeEstimate.detail=@"vehicle cloud: signed out";f=EBBuildPowerForecast(i);
    NSDictionary *partial=EBForecastAverage(f.rows,i.now,At(i.now,900));
    Expect(f.solarAvailable && f.homeAvailable && !f.carAvailable && !f.gridAvailable,"signed-out vehicle cannot hide independent solar and home");
    Expect(partial[@"pvW"] && partial[@"homeW"] && !partial[@"chargeW"] && !partial[@"supplyW"] && !partial[@"exportW"] && !partial[@"carSolarW"],"unknown car and grid fields must stay absent, never zero");
    i.chargerState=EBChargerStateWaiting;f=EBBuildPowerForecast(i);
    Expect(f.gridAvailable && [EBForecastAverage(f.rows,i.now,At(i.now,900))[@"chargeW"] doubleValue]==0,"fresh paused status supports a stopped scenario without any car login");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"stale-meter";f=EBBuildPowerForecast(i);
    Expect(f.solarAvailable && f.homeAvailable && !f.carAvailable,"stale charging meter only suppresses car and dependent grid");
    i=Input();i.chargerMeterAt=At(i.now,-421);f=EBBuildPowerForecast(i);
    Expect(!f.carAvailable && f.homeAvailable && f.solarAvailable,"meter clock independently validates a supplied charging estimate");
    i=Input();i.chargerState=EBChargerStateFault;f=EBBuildPowerForecast(i);
    Expect(!f.carAvailable && f.solarAvailable && f.homeAvailable,"charger fault cannot erase the solar outlook");
    i=Input();i.chargeEstimate.seconds=NAN;f=EBBuildPowerForecast(i);
    Expect(!f.carAvailable && f.solarAvailable,"invalid completion time cannot contaminate independent projection");
    i=Input();NSMutableDictionary *weather=[i.weather mutableCopy];weather[@"fetchedAt"]=At(i.now,-7201);i.weather=weather;f=EBBuildPowerForecast(i);
    Expect(!f.solarAvailable && f.homeAvailable && f.carAvailable && !f.gridAvailable,"stale weather cannot be replayed, but measured home/car assumptions remain");
    weather[@"fetchedAt"]=At(i.now,61);i.weather=weather;Expect(!EBBuildPowerForecast(i).solarAvailable,"future weather timestamp rejected for solar");
    i=Input();i.solarSamples=@[];f=EBBuildPowerForecast(i);
    Expect(!f.solarAvailable && !f.homeAvailable && f.carAvailable && !f.gridAvailable,"startup missing solar is unknown, not zero");
    i=Input();i.meterSamples=@[];f=EBBuildPowerForecast(i);
    Expect(f.solarAvailable && !f.homeAvailable && !f.gridAvailable,"startup missing home must retain independently calibrated solar");
    i=[EBPowerForecastInput new];f=EBBuildPowerForecast(i);
    Expect(!f.available && f.rows.count==0 && f.asOf && !f.carFinishesAt,"all data unavailable retains the forecast boundary without invented rows");
    i=Input();i.weather=@{@"fetchedAt":i.now,@"response":@[]};f=EBBuildPowerForecast(i);
    Expect(!f.solarAvailable && f.homeAvailable,"malformed weather must fail closed without blocking home");
    NSArray *mixed=@[@{@"start":i.now,@"end":At(i.now,450),@"pvW":@1000,@"chargeW":@0},
                     @{@"start":At(i.now,450),@"end":At(i.now,900),@"pvW":@2000}];
    partial=EBForecastAverage(mixed,i.now,At(i.now,900));
    Expect([partial[@"pvW"] doubleValue]==1500 && !partial[@"chargeW"],"partial component coverage cannot average missing values as zero");
    i=Input();NSMutableArray *nightSolar=[NSMutableArray array];
    for (NSDictionary *row in i.solarSamples) {
        NSMutableDictionary *copy=[row mutableCopy];
        if ([i.now timeIntervalSinceDate:row[@"t"]]<=900) copy[@"pvW"]=@0;
        [nightSolar addObject:copy];
    }
    i.solarSamples=nightSolar;
    NSMutableDictionary *nightResponse=[i.weather[@"response"] mutableCopy];
    NSMutableDictionary *nightHours=[nightResponse[@"hourly"] mutableCopy];
    NSMutableArray *nightRadiation=[nightHours[@"shortwave_radiation"] mutableCopy];
    nightRadiation[5]=@0; // The hour immediately ahead is dark; later daylight remains 500 W/m².
    nightHours[@"shortwave_radiation"]=nightRadiation; nightResponse[@"hourly"]=nightHours;
    i.weather=@{@"fetchedAt":i.now,@"response":nightResponse}; f=EBBuildPowerForecast(i);
    Expect(f.solarAvailable && [EBForecastAverage(f.rows,i.now,At(i.now,900))[@"pvW"] doubleValue]==0 &&
           [EBForecastAverage(f.rows,At(i.now,3600),At(i.now,4500))[@"pvW"] doubleValue]>0,
           "overnight measured zero must not erase upcoming daylight radiation");
    i=Input();f=EBBuildPowerForecast(i);
    Expect(!EBForecastAverage(f.rows,At(i.now,24*3600),At(i.now,25*3600)),"past available horizon is unknown");
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/Los_Angeles"]];
    i=[EBPowerForecastInput new];
    i.now=[[NSISO8601DateFormatter new] dateFromString:@"2026-11-01T00:00:00-07:00"];
    i.chargerState=EBChargerStateWaiting; i.chargerStatusAt=i.now;
    f=EBBuildPowerForecast(i);
    Expect(EBForecastAverage(f.rows,At(i.now,24*3600),At(i.now,25*3600))[@"chargeW"] &&
           !EBForecastAverage(f.rows,At(i.now,25*3600),At(i.now,26*3600)),
           "Today projection covers the complete 25-hour local day and stops at its boundary");
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    Expect([before[@"pvLowW"] doubleValue]<4000 && [before[@"pvHighW"] doubleValue]<=5000,"uncertainty envelope and inverter cap");
    Expect(!EBForecastRequestURL(nil) && !EBForecastRequestURL(@{}),"no ongoing consent means no forecast request");
    Expect(!EBForecastRequestURL(@{@"enabled":@YES,@"provider":@"Open-Meteo",@"latitude":@1,@"longitude":@2}),"one-off permission is not recurring consent");
    NSURL *request=EBForecastRequestURL(@{@"enabled":@YES,@"provider":@"Open-Meteo",@"consentVersion":@1,@"latitude":@(12.34567),@"longitude":@(98.76543)});
    Expect([request.host isEqual:@"api.open-meteo.com"] && [request.absoluteString containsString:@"latitude=12.346"] && [request.absoluteString containsString:@"longitude=98.765"],"request sends only the rounded position to the fixed provider");
    printf("forecast boundary tests: %s\n",fails?"FAILED":"ok");return fails?1:0;
} }
