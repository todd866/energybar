#import <Foundation/Foundation.h>
#import "learning.h"
#import <math.h>
#import <sys/stat.h>
static int fails;
#define Check(c,msg) do { if(!(c)){fprintf(stderr,"FAIL: %s\n",msg);fails++;} } while(0)
static NSDate *At(double t){return [NSDate dateWithTimeIntervalSince1970:t];}
static double Date(NSString *s){return [[[NSISO8601DateFormatter new] dateFromString:s] timeIntervalSince1970];}
static BOOL Close(double a,double b){return fabs(a-b)<.001;}
static NSDictionary *Observe(NSDictionary *previous,NSArray *pv,NSArray *sessions,double t){NSError *e=nil;NSDictionary *d=EBLearningObserve(previous,@"synthetic",pv,sessions,At(t),&e);Check(d&&!e,"observe valid data");return d;}
static NSDictionary *Model(NSDictionary *stats,NSDictionary *ledger,double t){return EBLearningModel(stats,ledger,At(t),[NSTimeZone timeZoneForSecondsFromGMT:0]);}
static NSDictionary *Session(NSString *identifier,double start,double wh,BOOL active){return @{@"id":identifier,@"chargeStart":At(start),@"chargeEnd":At(start+3600),@"energyWh":@(wh),@"active":@(active)};}
static EBPowerForecast *Forecast(double t,double start,double home,double pv){EBPowerForecast *f=[EBPowerForecast new];f.asOf=At(t);f.rows=@[@{@"start":At(start),@"end":At(start+3600),@"homeW":@(home),@"pvW":@(pv),@"basePvW":@(pv)}];return f;}
int main(void){@autoreleasepool{
    double day=Date(@"2026-10-05T00:00:00Z");
    NSDictionary *empty=Observe(nil,@[],@[],day);
    Check([Model(@{},empty,day)[@"homeBuckets"] count]==0,"startup has no invented household baseline");
    Check(![Model(@{},empty,day)[@"solarCalibration"][@"available"] boolValue],"startup has no invented solar correction");
    NSMutableArray *pv=[NSMutableArray array],*meter=[NSMutableArray array];
    // Five weekdays and a weekend with a different household demand.
    for(int d=0;d<7;d++) for(int n=0;n<=12;n++) {
        double t=day+d*86400+12*3600+n*300,home=d<5?500+d*100:2500;
        [pv addObject:@{@"t":At(t),@"pvW":@2000}];
        [meter addObject:@{@"t":@(t),@"supplyW":@(home+1000-2000),@"chargeW":@1000}];
    }
    double now=day+7*86400;NSDictionary *ledger=Observe(empty,pv,@[],now),*stats=@{@"meter":meter};
    NSDictionary *model=Model(stats,ledger,now),*bucket=model[@"homeBuckets"][@"weekday/12"];
    Check(Close([bucket[@"median"] doubleValue],700)&&[bucket[@"days"] intValue]==5,"weekday-hour median uses five dates, excluding car load");
    Check(Close([bucket[@"p10"] doubleValue],540)&&Close([bucket[@"p90"] doubleValue],860),"interpretable observed spread");
    Check(!model[@"homeBuckets"][@"weekend/12"],"two weekend dates cannot borrow weekday confidence");
    Check([Model(stats,ledger,day+4*86400)[@"homeBuckets"] count]==0,"chronological cutoff excludes later outcomes");
    Check([Model(stats,ledger,now+30*86400)[@"homeBuckets"] count]==0,"old household data expires");
    Check(Close([bucket[@"coverageSeconds"] doubleValue],5*3600),"coverage is time, not number of polls");

    NSArray *oneHour=@[@{@"t":@(day),@"supplyW":@1000,@"chargeW":@0},@{@"t":@(day+300),@"supplyW":@-1000,@"chargeW":@0}];
    NSDictionary *cross=@{@"meter":oneHour};
    NSDictionary *h=EBLearningHours(cross,empty,At(day+600)).firstObject;
    Check(Close([h[@"importW"][@"meanW"] doubleValue],250)&&Close([h[@"exportW"][@"meanW"] doubleValue],250),"gross import/export crossing zero cannot cancel");
    Check(!h[@"homeW"],"without measured PV household residual stays missing");
    NSArray *pvgap=@[@{@"t":At(day),@"pvW":@2000},@{@"t":At(day+120)},@{@"t":At(day+300),@"pvW":@2000}];
    NSDictionary *gap=Observe(nil,pvgap,@[],day+600);
    h=EBLearningHours(cross,gap,At(day+600)).firstObject;
    Check(!h[@"pvW"]&&!h[@"homeW"],"an explicit solar failure breaks interpolation");
    NSDictionary *longGap=Observe(nil,@[@{@"t":At(day),@"pvW":@2000},@{@"t":At(day+600),@"pvW":@2000}],@[],day+600);
    Check(EBLearningHours(@{},longGap,At(day+600)).count==0,"long gaps cannot be held forward");
    NSDictionary *minute=Observe(nil,@[@{@"t":At(day),@"pvW":@0},@{@"t":At(day+5),@"pvW":@100},@{@"t":At(day+10)}],@[],day+60);
    Check([minute[@"pv"] count]==1&&!minute[@"pv"][0][@"pvW"],"failed minute wins over dense successful polls");
    Check([Observe(minute,@[@{@"t":At(day+20),@"pvW":@200}],@[],day+60)[@"pv"] isEqual:minute[@"pv"]],"gap survives repeated overlapping merge");
    Check([Observe(nil,@[@{@"t":At(day+100),@"pvW":@1},@{@"t":At(day-91*86400),@"pvW":@1}],@[],day)[@"pv"] count]==0,"future and expired observations excluded");

    // First-issued vintage remains unchanged across app restart/recomputation.
    double issue=day+11*3600+30,start=day+12*3600;
    NSDictionary *v=EBLearningRecord(empty,@{},Forecast(issue,start,1000,1000),@{@"socSource":@"manual",@"socEstimated":@YES},At(issue));
    Check([v[@"vintages"] count]==1,"future-only next-hour prediction saved");
    Check([v[@"vintages"][0][@"vehicle"][@"socSource"] isEqual:@"manual"],"manual provenance stored separately from session totals");
    v=EBLearningRecord(v,@{},Forecast(issue+60,start,9999,9999),@{},At(issue+60));
    Check([v[@"vintages"] count]==1&&[v[@"vintages"][0][@"prediction"][@"homeW"] intValue]==1000,"forecast vintage is immutable");
    NSMutableDictionary *withPV=[ledger mutableCopy];withPV[@"vintages"]=v[@"vintages"];
    NSDictionary *unscored=EBLearningRecord(withPV,stats,[EBPowerForecast new],@{},At(start+3600+599));
    Check([unscored[@"vintages"][0][@"outcome"] count]==0,"no scoring before closeout lag");
    NSDictionary *scored=EBLearningRecord(withPV,stats,[EBPowerForecast new],@{},At(start+3600+600));
    NSDictionary *outcome=scored[@"vintages"][0][@"outcome"];
    Check(Close([outcome[@"homeW"][@"meanW"] doubleValue],500)&&Close([outcome[@"pvW"][@"meanW"] doubleValue],2000),"scores later independent measurements with common coverage");
    Check([EBLearningRecord(scored,@{},[EBPowerForecast new],@{},At(now))[@"vintages"][0][@"outcome"] isEqual:outcome],"recorded outcomes remain immutable");
    Check([Model(stats,scored,start)[@"errors"] count]==0,"later-scored outcomes cannot leak into an earlier model");
    Check(Close([Model(stats,scored,now)[@"errors"][@"homeW"][@"maeW"] doubleValue],500),"score reports absolute forecast error in watts");
    Check(![Model(stats,scored,now)[@"solarCalibration"][@"available"] boolValue],"one scored hour cannot calibrate solar");
    NSDictionary *missing=EBLearningRecord(v,@{},[EBPowerForecast new],@{},At(now));
    Check([missing[@"vintages"][0][@"outcome"] count]==0,"missing measurements cannot score as zero");

    // Context is captured prospectively. A later charging start/resume must not
    // be mixed with power errors from an already-active completion scenario.
    NSDictionary *chargeLedger=Observe(nil,@[],@[],day);
    NSArray *states=@[@"unplugged",@"waiting",@"charging",@"solar",@"charging",@"unknown"];
    NSArray *scenarios=@[@"idle",@"idle",@"active-charge",@"active-charge",@"target-reached",@"legacy"];
    NSArray *predictions=@[@0,@0,@0,@2000,@0,@0],*actuals=@[@3000,@0,@1000,@2500,@700,@500];
    for(NSUInteger n=0;n<states.count;n++) {
        double target=start+n*7200,issued=target-1800;
        EBPowerForecast *f=[EBPowerForecast new];f.asOf=At(issued);
        f.rows=@[@{@"start":At(target),@"end":At(target+3600),@"chargeW":predictions[n]}];
        if(n<5) {
            NSMutableDictionary *context=[@{@"state":states[n],@"scenario":scenarios[n],@"statusAt":@(issued),
                @"meterAt":@(issued-30),@"powerW":@3500,@"sessionID":@"must-not-be-retained"} mutableCopy];
            if([scenarios[n] isEqual:@"active-charge"])context[@"finishesAt"]=@(n==2?target-60:target+1800);
            f.chargerContext=context;
        }
        chargeLedger=EBLearningRecord(chargeLedger,@{},f,@{},At(issued));
        NSDictionary *original=[chargeLedger[@"vintages"] lastObject];
        Check(n==5?!original[@"charger"]:[original[@"charger"][@"state"] isEqual:states[n]],"legacy absent context and new issuance state preserved");
        Check(!original[@"charger"][@"sessionID"],"charger context only retains approved diagnostic fields");
        f.chargerContext=@{@"state":@"waiting",@"scenario":@"idle"};
        NSDictionary *retried=EBLearningRecord(chargeLedger,@{},f,@{},At(issued+60));
        Check([[retried[@"vintages"] lastObject] isEqual:original],"recomputation cannot replace issuance context, including legacy records");
        NSMutableArray *measured=[NSMutableArray array];
        for(int k=0;k<=12;k++)[measured addObject:@{@"t":@(target+k*300),@"chargeW":actuals[n]}];
        NSDictionary *partialScore=EBLearningRecord(chargeLedger,@{@"meter":[measured subarrayWithRange:NSMakeRange(0,3)]},[EBPowerForecast new],@{},At(target+4200));
        Check([partialScore[@"vintages"] lastObject][@"outcome"][@"chargeW"]==nil,"context never relaxes measured coverage requirements");
        chargeLedger=EBLearningRecord(chargeLedger,@{@"meter":measured},[EBPowerForecast new],@{},At(target+4200));
    }
    NSDictionary *chargeModel=Model(@{},chargeLedger,start+12*3600),*byScenario=chargeModel[@"chargeErrorsByScenario"];
    Check([chargeModel[@"errors"][@"chargeW"][@"count"] intValue]==6&&
          Close([chargeModel[@"errors"][@"chargeW"][@"maeW"] doubleValue],950),"all charger errors remain in the unchanged aggregate");
    Check([byScenario[@"idle-load-observed"][@"count"] intValue]==1&&
          Close([byScenario[@"idle-load-observed"][@"biasW"] doubleValue],-3000),"charging after idle is separated from active-charge errors");
    Check([byScenario[@"idle-no-load"][@"count"] intValue]==1&&
          Close([byScenario[@"idle-no-load"][@"maeW"] doubleValue],0),"idle with measured zero remains a valid scored outcome");
    Check([byScenario[@"active-charge"][@"count"] intValue]==2&&
          Close([byScenario[@"active-charge"][@"maeW"] doubleValue],750),"active charge remains active even when predicted to finish before target hour");
    Check([byScenario[@"target-reached"][@"count"] intValue]==1&&[byScenario[@"unclassified"][@"count"] intValue]==1,
          "confirmed target and legacy unknown state have separate score groups");
    Check([Model(@{},chargeLedger,start)[@"chargeErrorsByScenario"] count]==0,"scenario scores obey the same chronological cutoff");
    Check([Model(@{},chargeLedger,start+30*86400)[@"chargeErrorsByScenario"] count]==0,"scenario scores expire with the existing training window");

    // Repeated walk-forward issuance followed by later measurements. No weather
    // reconstruction: each prediction is already frozen before its target hour.
    NSMutableArray *backtestPV=[NSMutableArray array],*backtestMeter=[NSMutableArray array];
    NSDictionary *walk=Observe(nil,@[],@[],day);double totalBaselineError=0,totalLearnedError=0;int compared=0;
    for(int d=0;d<14;d++) {
        for(int hour=10;hour<14;hour++) {
            double target=day+d*86400+hour*3600,issued=target-1800;
            NSDictionary *training=Model(@{@"meter":backtestMeter},walk,issued);
            NSString *key=[NSString stringWithFormat:@"%@/%d",d%7>=5?@"weekend":@"weekday",hour];
            NSDictionary *learned=training[@"homeBuckets"][key];double actualHome=hour%2?1500:500;
            if(learned){totalBaselineError+=fabs(1000-actualHome);totalLearnedError+=fabs([learned[@"median"] doubleValue]-actualHome);compared++;}
            walk=EBLearningRecord(walk,@{@"meter":backtestMeter},Forecast(issued,target,learned?[learned[@"median"] doubleValue]:1000,1000),@{},At(issued));
            for(int n=0;n<=12;n++){double t=target+n*300;[backtestPV addObject:@{@"t":At(t),@"pvW":@800}];[backtestMeter addObject:@{@"t":@(t),@"supplyW":@(actualHome-800),@"chargeW":@0}];}
            // Deduplicate adjacent-hour boundaries like the existing statistics store.
            NSMutableDictionary *byT=[NSMutableDictionary dictionary];for(NSDictionary *r in backtestMeter)byT[r[@"t"]]=r;
            backtestMeter=[[byT.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"t"] compare:b[@"t"]];}] mutableCopy];
            walk=Observe(walk,backtestPV,@[],target+4200);
            walk=EBLearningRecord(walk,@{@"meter":backtestMeter},[EBPowerForecast new],@{},At(target+4200));
        }
    }
    NSDictionary *trained=Model(@{@"meter":backtestMeter},walk,day+15*86400);
    Check(compared>0&&totalLearnedError<totalBaselineError,"walk-forward hourly baseline improves on flat baseline for scheduled synthetic demand");
    Check([trained[@"solarCalibration"][@"available"] boolValue]&&Close([trained[@"solarCalibration"][@"factor"] doubleValue],.8),"solar bias learned only after twelve saved/scored hours and three dates");
    Check([trained[@"errors"][@"pvW"][@"count"] intValue]>=12,"independent solar forecast errors counted");
    fprintf(stdout,"walk-forward synthetic comparison: %d covered predictions; flat MAE %.1f W, hourly MAE %.1f W\n",compared,totalBaselineError/compared,totalLearnedError/compared);

    NSMutableArray *sessions=[NSMutableArray array];for(int n=0;n<5;n++)[sessions addObject:Session([NSString stringWithFormat:@"private-car-%d",n],day+n*86400,1000+n*1000,NO)];
    [sessions addObject:Session(@"active",day+6*86400,99999,YES)];[sessions addObject:Session(@"future",now+86400,99999,NO)];
    NSDictionary *history=Observe(nil,@[],sessions,now),*summary=Model(@{},history,now)[@"sessions"];
    Check([summary[@"available"] boolValue]&&[summary[@"completedCount"] intValue]==5,"only complete, measured sessions enter distribution");
    Check([summary[@"energyWh"][@"median"] intValue]==3000&&[summary[@"elapsedSeconds"][@"median"] intValue]==3600,"session energy and elapsed timing medians");
    Check(![summary[@"currentBatteryNeedInferred"] boolValue],"past session cannot infer current battery requirements");
    Check(![history.description containsString:@"private-car"],"raw session identities are not retained");
    Check([Observe(history,@[],sessions,now)[@"sessions"] count]==5,"session overlap is deduplicated");
    Check(![Model(@{},Observe(nil,@[],[sessions subarrayWithRange:NSMakeRange(0,4)],now),now)[@"sessions"][@"available"] boolValue],"four sessions cannot claim a learned distribution");

    // UTC hours distinguish both repeated local hours, but each date counts once.
    double fall=Date(@"2026-11-01T05:00:00Z");
    NSArray *dst=@[@{@"t":At(fall),@"pvW":@0},@{@"t":At(fall+300),@"pvW":@0},@{@"t":At(fall+3600),@"pvW":@0},@{@"t":At(fall+3900),@"pvW":@0}];
    Check(EBLearningHours(@{},Observe(nil,dst,@[],fall+4000),At(fall+4000)).count==2,"DST repeated hour retains separate absolute measurement windows");

    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString],*path=[directory stringByAppendingPathComponent:@"learning.json"];NSError *error=nil;
    Check(EBLearningSave(path,history,&error),"atomic private save");
    NSDictionary *loaded=EBLearningLoad(path,@"synthetic",&error);Check([loaded isEqual:history],"ledger survives restart");
    Check(EBLearningSave(path,chargeLedger,&error)&&[EBLearningLoad(path,@"synthetic",&error) isEqual:chargeLedger],
          "mixed legacy and contextual vintages round-trip without migration or data loss");
    NSMutableDictionary *invalid=[chargeLedger mutableCopy],*invalidVintage=[chargeLedger[@"vintages"][0] mutableCopy];
    invalidVintage[@"charger"]=@{@"state":@"unplugged",@"scenario":@"active-charge"};
    NSMutableArray *invalidVintages=[chargeLedger[@"vintages"] mutableCopy];invalidVintages[0]=invalidVintage;invalid[@"vintages"]=invalidVintages;
    NSData *validBytes=[NSData dataWithContentsOfFile:path];error=nil;
    Check(!EBLearningSave(path,invalid,&error)&&error&&[[NSData dataWithContentsOfFile:path] isEqual:validBytes],
          "invalid charger scenario fails closed and preserves stored history");
    struct stat mode;stat(path.fileSystemRepresentation,&mode);Check((mode.st_mode&0777)==0600,"ledger mode 0600");stat(directory.fileSystemRepresentation,&mode);Check((mode.st_mode&0777)==0700,"directory mode 0700");
    error=nil;Check(!EBLearningLoad(path,@"other-source",&error)&&error,"source mismatch fails closed");
    NSData *before=[NSData dataWithContentsOfFile:path];NSMutableDictionary *wrong=[history mutableCopy];wrong[@"source"]=@"other-source";
    Check(!EBLearningSave(path,wrong,&error)&&[[NSData dataWithContentsOfFile:path] isEqual:before],"source-mismatched save preserves old file");
    [@"corrupt" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];error=nil;
    Check(!EBLearningLoad(path,@"synthetic",&error)&&error,"corrupt ledger reported");
    Check(!EBLearningSave(path,history,&error),"corrupt ledger not overwritten");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    fprintf(stdout,"learning tests: %s\n",fails?"FAILED":"ok");return fails?1:0;
}}
