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
