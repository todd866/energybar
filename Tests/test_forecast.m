#import <Foundation/Foundation.h>
#import <math.h>
#import "forecast.h"
static int fails;
#define Expect(c,msg) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",msg); fails++; } } while(0)
static NSDate *At(NSDate *now,double seconds) { return [now dateByAddingTimeInterval:seconds]; }
static EBPowerForecastInput *Input(void) {
    EBPowerForecastInput *i=[EBPowerForecastInput new]; i.now=[NSDate dateWithTimeIntervalSince1970:1792213200];
    i.inverterW=5000; i.chargerW=3500; i.chargerState=EBChargerStateSolar; i.chargerStatusAt=i.now;
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
    Expect(f.available,"valid measured data must produce forecast");
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
    i=Input();i.chargerStatusAt=At(i.now,-151);Expect(!EBBuildPowerForecast(i).available,"stale status suppresses projection");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"near-target";Expect(!EBBuildPowerForecast(i).available,"estimated full while still charging must await confirmation");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"target-reached";f=EBBuildPowerForecast(i);Expect(f.available && !f.carFinishesAt,"confirmed target has no projected charging load");
    i=Input();i.chargeEstimate.available=NO;i.chargeEstimate.state=@"stale-meter";Expect(!EBBuildPowerForecast(i).available,"stale active charger power suppresses projection");
    i=Input();NSMutableDictionary *weather=[i.weather mutableCopy];weather[@"fetchedAt"]=At(i.now,-7201);i.weather=weather;
    Expect(!EBBuildPowerForecast(i).available,"stale weather must not be replayed as fresh");
    weather[@"fetchedAt"]=At(i.now,61);i.weather=weather;Expect(!EBBuildPowerForecast(i).available,"future weather timestamp rejected");
    i=Input();i.solarSamples=@[];Expect(!EBBuildPowerForecast(i).available,"startup missing solar is not zero");
    i=Input();i.meterSamples=@[];Expect(!EBBuildPowerForecast(i).available,"startup missing home is not zero");
    i=Input();f=EBBuildPowerForecast(i);
    Expect(!EBForecastAverage(f.rows,At(i.now,24*3600),At(i.now,25*3600)),"past available horizon is unknown");
    Expect([before[@"pvLowW"] doubleValue]<4000 && [before[@"pvHighW"] doubleValue]<=5000,"uncertainty envelope and inverter cap");
    Expect(!EBForecastRequestURL(nil) && !EBForecastRequestURL(@{}),"no ongoing consent means no forecast request");
    Expect(!EBForecastRequestURL(@{@"enabled":@YES,@"provider":@"Open-Meteo",@"latitude":@1,@"longitude":@2}),"one-off permission is not recurring consent");
    NSURL *request=EBForecastRequestURL(@{@"enabled":@YES,@"provider":@"Open-Meteo",@"consentVersion":@1,@"latitude":@(12.34567),@"longitude":@(98.76543)});
    Expect([request.host isEqual:@"api.open-meteo.com"] && [request.absoluteString containsString:@"latitude=12.346"] && [request.absoluteString containsString:@"longitude=98.765"],"request sends only the rounded position to the fixed provider");
    printf("forecast boundary tests: %s\n",fails?"FAILED":"ok");return fails?1:0;
} }
