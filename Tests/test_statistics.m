#import <Foundation/Foundation.h>
#import "statistics.h"
#import <math.h>
#import <sys/stat.h>

static int failures=0;
static void Check(BOOL yes,NSString *what){if(!yes){fprintf(stderr,"FAIL: %s\n",what.UTF8String);failures++;}}
static NSDate *Date(NSString *s){return [[NSISO8601DateFormatter new] dateFromString:s];}
static NSDate *At(NSDate *d,double seconds){return [d dateByAddingTimeInterval:seconds];}
static NSDictionary *Row(NSDate *t,id grid,id car){NSMutableDictionary *r=[@{@"t":t} mutableCopy];if(grid)r[@"supplyW"]=grid;if(car)r[@"chargeW"]=car;return r;}
static BOOL Close(double a,double b){return fabs(a-b)<.00001;}
static NSDictionary *Merge(NSDictionary *old,NSArray *r,NSArray *solar,NSDate *now){NSError *error=nil;NSDictionary *d=EBStatisticsMerge(old,@"synthetic-source",r,solar,now,&error);Check(d!=nil&&error==nil,@"valid merge");return d;}
static EBStatisticsReport *Report(NSDictionary *d,NSDate *now){return EBStatisticsSummarize(d,now,[NSTimeZone timeZoneForSecondsFromGMT:0]);}

int main(void){@autoreleasepool{
    NSDate *midnight=Date(@"2026-01-08T00:00:00Z"),*now=At(midnight,600);
    NSArray *samples=@[Row(At(midnight,-120),@1200,@3000),Row(At(midnight,120),@-1200,@3000)];
    NSDictionary *doc=Merge(nil,samples,@[],now);EBStatisticsReport *r=Report(doc,now);
    NSDictionary *today=r.days[0],*yesterday=r.days[1];
    Check(Close([today[@"export"][@"wh"] doubleValue],20),@"crossing midnight preserves export triangle");
    Check(Close([yesterday[@"import"][@"wh"] doubleValue],20),@"crossing midnight preserves import triangle");
    Check(Close([today[@"car"][@"wh"] doubleValue],100)&&Close([yesterday[@"car"][@"wh"] doubleValue],100),@"car split at midnight without double count");
    Check(Close([today[@"car"][@"coverage"] doubleValue],120),@"no held tail after newest sample");
    Check([today[@"car"][@"partial"] boolValue],@"partial day visible");
    Check(Close([r.weeks[0][@"car"][@"wh"] doubleValue],200),@"week sums independent days");
    Check([r.weeks[0][@"start"] isEqual:Date(@"2026-01-05T00:00:00Z")],@"Monday calendar week");

    NSDictionary *twice=Merge(doc,samples,@[],now);
    Check([doc[@"meter"] isEqual:twice[@"meter"]],@"overlapping cache merge is idempotent");
    NSDictionary *corrected=Merge(doc,@[Row(At(midnight,120),@0,@0)],@[],now);
    Check([corrected[@"meter"] count]==2, @"same source timestamp replaces rather than appends");
    Check([corrected[@"meter"][1][@"chargeW"] doubleValue]==0,@"valid zero survives correction");

    NSArray *gaps=@[Row(midnight,@1000,@1000),Row(At(midnight,100),nil,nil),Row(At(midnight,200),@1000,@1000),Row(At(midnight,800),@1000,@1000)];
    NSDictionary *gapDoc=Merge(nil,gaps,@[],At(midnight,900));
    Check([Report(gapDoc,At(midnight,900)).days[0][@"import"][@"coverage"] doubleValue]==0,@"explicit gap and >7-minute gap are not bridged");
    NSArray *status=@[Row(midnight,@0,@0),@{@"t":At(midnight,100),@"statusOnly":@YES,@"st":@2},Row(At(midnight,200),@0,@0)];
    NSDictionary *zero=Report(Merge(nil,status,@[],now),now).days[0];
    Check([zero[@"car"][@"coverage"] doubleValue]==200&&[zero[@"car"][@"wh"] doubleValue]==0,@"measured zero differs from unavailable; status-only does not break power");
    NSDictionary *separate=Report(Merge(nil,@[Row(midnight,@500,nil),Row(At(midnight,200),@500,nil)],@[],now),now).days[0];
    Check([separate[@"import"][@"coverage"] doubleValue]==200&&[separate[@"car"][@"coverage"] doubleValue]==0,@"independent series coverage");

    NSArray *invalid=@[Row(midnight,@YES,@-1),Row(At(midnight,100),@(NAN),@(INFINITY)),Row(At(now,1),@900,@900),Row(At(now,-EBStatisticsRetention-1),@900,@900)];
    NSDictionary *clean=Merge(nil,invalid,@[],now);
    Check([clean[@"meter"] count]==2,@"future and expired timestamps rejected");
    Check([clean[@"meter"][0] count]==1&&[clean[@"meter"][1] count]==1,@"booleans NaN infinity and negative car values become gaps");
    NSError *error=nil;
    Check(!EBStatisticsMerge(doc,@"different-source",@[],@[],now,&error)&&error!=nil,@"source mismatch rejects history");
    NSMutableDictionary *bad=[doc mutableCopy];bad[@"meter"]=@[@{@"t":@1,@"supplyW":@YES}];
    Check(!EBStatisticsMerge(bad,@"synthetic-source",@[],@[],now,&error),@"corrupt stored numbers fail closed");

    EBFroniusPVInterval *(^PV)(NSString *,double,double,double)=^EBFroniusPVInterval *(NSString *device,double offset,double span,double wh){return [[EBFroniusPVInterval alloc] initWithDeviceID:device deviceType:nil anchor:At(midnight,offset) spanSeconds:span energyWh:wh];};
    NSArray *solar=@[PV(@"synthetic-a",0,300,10),PV(@"synthetic-a",300,300,100),PV(@"synthetic-a",400,300,999),PV(@"synthetic-a",600,300,100),PV(@"synthetic-b",300,300,50)];
    NSDictionary *pvDoc=Merge(nil,@[],solar,At(midnight,1000));
    NSDictionary *sun=Report(pvDoc,At(midnight,1000)).days[0][@"solar"];
    Check(Close([sun[@"wh"] doubleValue],250),@"solar excludes ambiguous boundary and overlapping intervals");
    Check(Close([sun[@"coverage"] doubleValue],450),@"solar coverage averages device seconds");
    Check([sun[@"partial"] boolValue],@"solar register never claims complete site coverage");
    Check(![[pvDoc description] containsString:@"synthetic-a"],@"device identity is hashed in durable store");
    Check([Merge(pvDoc,@[],solar,At(midnight,1000))[@"solar"] count]==5,@"solar archive idempotent merge");

    NSMutableArray *wholeDay=[NSMutableArray array];NSDate *dayStart=At(midnight,-86400);
    for(int i=0;i<=288;i++)[wholeDay addObject:Row(At(dayStart,i*300),@500,@0)];
    NSDictionary *full=Report(Merge(nil,wholeDay,@[],midnight),midnight).days[1];
    Check(Close([full[@"import"][@"wh"] doubleValue],12000)&&![full[@"import"][@"partial"] boolValue],@"complete measured day with full coverage");
    EBStatisticsReport *dst=EBStatisticsSummarize(@{},Date(@"2026-03-09T04:00:00Z"),[NSTimeZone timeZoneWithName:@"America/New_York"]);
    Check([dst.days[1][@"span"] doubleValue]==23*3600,@"DST day denominator is 23 hours");
    Check([dst.weeks[1][@"span"] doubleValue]==167*3600,@"DST calendar week denominator is 167 hours");
    EBStatisticsReport *empty=Report(@{},now);
    Check(empty.days.count==90&&[empty.days[0][@"car"][@"coverage"] doubleValue]==0,@"startup unavailable history remains 90 empty calendar bins");

    NSMutableArray *many=[NSMutableArray array];
    for(NSUInteger i=0;i<EBStatisticsRecordLimit+1;i++)[many addObject:Row(At(now,-(double)i),@1,@0)];
    Check([Merge(nil,many,@[],now)[@"meter"] count]==EBStatisticsRecordLimit,@"hard record count bound");
    NSDictionary *expired=Merge(doc,@[],@[],At(now,EBStatisticsRetention+1000));
    Check([expired[@"meter"] count]==0,@"retention pruning on restart");

    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"energybar-statistics-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *path=[dir stringByAppendingPathComponent:@"statistics.json"];
    NSDictionary *saved=EBStatisticsUpdate(path,@"synthetic-source",samples,solar,now,&error);
    Check(saved!=nil,@"durable write succeeds");
    struct stat st;stat(path.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0600,@"private file mode");
    stat(dir.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0700,@"private directory mode");
    NSDictionary *restarted=EBStatisticsUpdate(path,@"synthetic-source",@[],@[],now,&error);
    Check([saved isEqual:restarted],@"restart preserves historical data with empty incoming caches");
    NSData *bytes=[NSData dataWithContentsOfFile:path];
    Check(!EBStatisticsUpdate(path,@"other",@[],@[],now,&error),@"durable source mismatch rejected");
    Check([[NSData dataWithContentsOfFile:path] isEqual:bytes],@"source mismatch preserves original bytes");
    [@"{broken" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check(!EBStatisticsUpdate(path,@"synthetic-source",samples,@[],now,&error),@"corrupt file rejected");
    Check([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:@"{broken"],@"corrupt file is not overwritten");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    printf("statistics: %s\n",failures?"FAILED":"all coverage, retention, provenance and persistence checks passed");
    return failures?1:0;
}}
