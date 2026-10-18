#import "learning.h"
#import "store.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const double Retention=90*86400.0, Training=28*86400.0;
static const NSUInteger PVLimit=130000, SessionLimit=1000, VintageLimit=2200, ByteLimit=16*1024*1024;
static NSArray *Metrics(void) { return @[@"pvW",@"homeW",@"chargeW",@"supplyW",@"importW",@"exportW"]; }
static BOOL Num(id x) { return [x isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID() && isfinite([x doubleValue]); }
static BOOL Dict(id x) { return [x isKindOfClass:NSDictionary.class]; }
static NSError *Problem(void) { return [NSError errorWithDomain:@"EnergybarLearning" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Learning history could not be read or saved safely; existing history preserved."}]; }
static NSString *Hash(NSString *s) {
    NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding]; unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes,(CC_LONG)d.length,bytes); NSMutableString *out=[NSMutableString string];
    for(NSUInteger n=0;n<sizeof(bytes);n++)[out appendFormat:@"%02x",bytes[n]]; return out;
}
static double Quantile(NSArray *values,double q) {
    if(!values.count)return NAN;
    NSArray *s=[values sortedArrayUsingSelector:@selector(compare:)];double p=(s.count-1)*q;
    NSUInteger lo=(NSUInteger)floor(p),hi=(NSUInteger)ceil(p);
    return [s[lo] doubleValue]*(1-(p-lo))+[s[hi] doubleValue]*(p-lo);
}
static NSDictionary *Distribution(NSArray *values) {
    if(!values.count)return @{};
    return @{@"p10":@(Quantile(values,.1)),@"median":@(Quantile(values,.5)),@"p90":@(Quantile(values,.9))};
}
static BOOL Valid(NSDictionary *d,NSString *source) {
    if(!Dict(d)||![d[@"schema"] isEqual:@1]||![d[@"modelVersion"] isEqual:@1]||![d[@"source"] isEqual:source])return NO;
    NSArray *keys=@[@"pv",@"sessions",@"vintages"],*limits=@[@(PVLimit),@(SessionLimit),@(VintageLimit)];
    for(NSUInteger k=0;k<keys.count;k++) if(![d[keys[k]] isKindOfClass:NSArray.class]||[d[keys[k]] count]>[limits[k] unsignedIntegerValue])return NO;
    double last=-INFINITY;
    for(NSDictionary *r in d[@"pv"]) {
        if(!Dict(r)||!Num(r[@"t"])||[r[@"t"] doubleValue]<=last ||
           (r[@"pvW"]&&(!Num(r[@"pvW"])||[r[@"pvW"] doubleValue]<0)))return NO;
        last=[r[@"t"] doubleValue];
    }
    for(NSDictionary *r in d[@"sessions"]) if(!Dict(r)||![r[@"id"] isKindOfClass:NSString.class]||[r[@"id"] length]!=64||
        !Num(r[@"start"])||!Num(r[@"end"])||[r[@"end"] doubleValue]<=[r[@"start"] doubleValue]||
        !Num(r[@"energyWh"])||[r[@"energyWh"] doubleValue]<=0)return NO;
    NSMutableSet *starts=[NSMutableSet set];
    for(NSDictionary *v in d[@"vintages"]) {
        if(!Dict(v)||!Num(v[@"issuedAt"])||!Num(v[@"start"])||!Num(v[@"end"])||
           ![v[@"modelVersion"] isEqual:@1]||
           [v[@"issuedAt"] doubleValue]>=[v[@"start"] doubleValue]||
           fabs([v[@"end"] doubleValue]-[v[@"start"] doubleValue]-3600)>.01||
           [starts containsObject:v[@"start"]]||!Dict(v[@"prediction"])||!Dict(v[@"outcome"]))return NO;
        [starts addObject:v[@"start"]];
        for(NSString *key in v[@"prediction"])if(!Num(v[@"prediction"][key]))return NO;
        for(NSString *key in v[@"outcome"]) {
            NSDictionary *o=v[@"outcome"][key];
            if(![Metrics() containsObject:key]||!Dict(o)||!Num(o[@"meanW"])||!Num(o[@"coverage"])||
               [o[@"coverage"] doubleValue]<3240||[o[@"coverage"] doubleValue]>3600.01||!Num(o[@"observedAt"])||
               [o[@"observedAt"] doubleValue]<[v[@"end"] doubleValue]||
               (![key isEqual:@"supplyW"]&&[o[@"meanW"] doubleValue]<0))return NO;
        }
    }
    return YES;
}
NSDictionary *EBLearningLoad(NSString *path,NSString *source,NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:path])return nil;
    NSDictionary *attrs=[fm attributesOfItemAtPath:path error:error];
    if(![attrs[NSFileType] isEqual:NSFileTypeRegular]||[attrs[NSFileSize] unsignedLongLongValue]>ByteLimit){if(error)*error=Problem();return nil;}
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error];
    NSDictionary *d=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if(!Valid(d,source)){if(error)*error=Problem();return nil;}return d;
}
BOOL EBLearningSave(NSString *path,NSDictionary *d,NSError **error) {
    if(!Valid(d,d[@"source"])){if(error)*error=Problem();return NO;}
    NSFileManager *fm=NSFileManager.defaultManager;
    if([fm fileExistsAtPath:path]&&!EBLearningLoad(path,d[@"source"],error))return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:error];
    if(!data||data.length>ByteLimit){if(error)*error=Problem();return NO;}
    NSString *dir=path.stringByDeletingLastPathComponent;
    if(![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    if(chmod(dir.fileSystemRepresentation,0700)!=0){if(error)*error=Problem();return NO;}
    char *tmp=strdup([dir stringByAppendingPathComponent:@".learning-XXXXXX"].fileSystemRepresentation);
    int fd=mkstemp(tmp);if(fd<0){free(tmp);if(error)*error=Problem();return NO;}
    BOOL ok=fchmod(fd,0600)==0;const uint8_t *bytes=data.bytes;NSUInteger left=data.length;
    while(ok&&left){ssize_t n=write(fd,bytes,left);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}bytes+=n;left-=(NSUInteger)n;}
    if(ok&&fsync(fd)!=0)ok=NO;if(close(fd)!=0)ok=NO;
    if(ok&&rename(tmp,path.fileSystemRepresentation)!=0)ok=NO;
    if(!ok)unlink(tmp);free(tmp);
    if(ok){int dirfd=open(dir.fileSystemRepresentation,O_RDONLY);if(dirfd<0)ok=NO;else{if(fsync(dirfd)!=0)ok=NO;if(close(dirfd)!=0)ok=NO;}}
    if(!ok&&error)*error=Problem();return ok;
}
static NSArray *Bound(NSArray *rows,NSString *key,NSUInteger limit) {
    NSArray *sorted=[rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[key] compare:b[key]];}];
    return sorted.count>limit?[sorted subarrayWithRange:NSMakeRange(sorted.count-limit,limit)]:sorted;
}
NSDictionary *EBLearningObserve(NSDictionary *previous,NSString *source,NSArray *pv,NSArray *sessions,NSDate *now,NSError **error) {
    if(!source.length||(previous&&!Valid(previous,source))){if(error)*error=Problem();return nil;}
    double end=now.timeIntervalSince1970,cutoff=end-Retention;
    NSMutableDictionary *slots=[NSMutableDictionary dictionary],*savedSessions=[NSMutableDictionary dictionary];
    NSMutableArray *incoming=[NSMutableArray array];
    for(NSDictionary *r in pv) {
        if(!Dict(r)||![r[@"t"] isKindOfClass:NSDate.class])continue;
        NSMutableDictionary *row=[@{@"t":@([r[@"t"] timeIntervalSince1970])} mutableCopy];
        if(Num(r[@"pvW"])&&[r[@"pvW"] doubleValue]>=0)row[@"pvW"]=r[@"pvW"];
        [incoming addObject:row];
    }
    // Keep the earliest actual sample in each minute (not a retimed average).
    // Any explicit failed poll wins its minute and breaks continuity.
    for(NSArray *rows in @[previous[@"pv"]?:@[],incoming])for(NSDictionary *r in rows) {
        double t=[r[@"t"] doubleValue];if(t<cutoff||t>end)continue;NSNumber *slot=@(floor(t/60));NSDictionary *old=slots[slot];
        if(!old || (old[@"pvW"]&&!r[@"pvW"]) || (r[@"pvW"]&&old[@"pvW"]&&t<[old[@"t"] doubleValue]))slots[slot]=r;
    }
    for(NSDictionary *r in previous[@"sessions"])if([r[@"end"] doubleValue]>=cutoff&&[r[@"end"] doubleValue]<=end)savedSessions[r[@"id"]]=r;
    // Input is the existing sanitized session parser's contract, with NSDate dates.
    for(NSDictionary *r in sessions) {
        NSDate *a=r[@"chargeStart"],*b=r[@"chargeEnd"];id wh=r[@"energyWh"];
        if(![r[@"id"] isKindOfClass:NSString.class]||![r[@"id"] length]||![r[@"active"] isEqual:@NO]||
           ![a isKindOfClass:NSDate.class]||![b isKindOfClass:NSDate.class]||!Num(wh)||[wh doubleValue]<=0||
           [b compare:now]==NSOrderedDescending||b.timeIntervalSince1970<cutoff||[b timeIntervalSinceDate:a]<=0)continue;
        NSString *key=Hash(r[@"id"]);
        savedSessions[key]=@{@"id":key,@"start":@(a.timeIntervalSince1970),@"end":@(b.timeIntervalSince1970),@"energyWh":wh};
    }
    NSMutableArray *vintages=[NSMutableArray array];
    for(NSDictionary *v in previous[@"vintages"])if([v[@"end"] doubleValue]>=cutoff&&[v[@"issuedAt"] doubleValue]<=end)[vintages addObject:v];
    return @{@"schema":@1,@"modelVersion":@1,@"source":source,@"updatedAt":@(end),
        @"pv":Bound(slots.allValues,@"t",PVLimit),@"sessions":Bound(savedSessions.allValues,@"end",SessionLimit),
        @"vintages":Bound(vintages,@"start",VintageLimit)};
}

static BOOL Value(NSDictionary *r,NSString *key) { return Num(r[key])&&([key isEqual:@"supplyW"]||[r[key] doubleValue]>=0); }
static double Interpolate(NSDictionary *a,NSDictionary *b,NSString *key,double t) {
    double x=[a[@"t"] doubleValue],y=[b[@"t"] doubleValue];
    return [a[key] doubleValue]+([b[key] doubleValue]-[a[key] doubleValue])*(t-x)/(y-x);
}
static void Add(NSMutableDictionary *hours,NSString *key,double start,double end,double first,double last) {
    double cursor=start;
    while(cursor<end) {
        double hour=floor(cursor/3600)*3600,b=fmin(end,hour+3600),dt=b-cursor;
        NSNumber *slot=@(hour);if(!hours[slot])hours[slot]=[NSMutableDictionary dictionaryWithObjectsAndKeys:slot,@"start",@(hour+3600),@"end",nil];
        NSMutableDictionary *r=hours[slot];if(!r[key])r[key]=[NSMutableDictionary dictionaryWithObjectsAndKeys:@0,@"wattSeconds",@0,@"coverage",nil];
        NSMutableDictionary *m=r[key];double x=first+(last-first)*(cursor-start)/(end-start),y=first+(last-first)*(b-start)/(end-start);
        double ws=(x+y)*dt/2;
        if([key isEqual:@"importW"]||[key isEqual:@"exportW"]) {
            EBGridEnergy energy=EBGridEnergyForInterval(x,y,dt);ws=([key isEqual:@"importW"]?energy.importWh:energy.exportWh)*3600;
        }
        m[@"wattSeconds"]=@([m[@"wattSeconds"] doubleValue]+ws);m[@"coverage"]=@([m[@"coverage"] doubleValue]+dt);cursor=b;
    }
}
static BOOL Continuous(NSDictionary *a,NSDictionary *b,double now) {
    double ta=[a[@"t"] doubleValue],tb=[b[@"t"] doubleValue];return tb>ta&&tb-ta<=EBStoreIntegrationGapSeconds&&tb<=now;
}
NSArray *EBLearningHours(NSDictionary *statistics,NSDictionary *ledger,NSDate *now) {
    NSArray *meter=statistics[@"meter"]?:@[],*pv=ledger[@"pv"]?:@[];double stop=now.timeIntervalSince1970;
    NSMutableDictionary *hours=[NSMutableDictionary dictionary];
    for(NSUInteger k=1;k<pv.count;k++) {
        NSDictionary *a=pv[k-1],*b=pv[k];if(Continuous(a,b,stop)&&Value(a,@"pvW")&&Value(b,@"pvW"))
            Add(hours,@"pvW",[a[@"t"] doubleValue],[b[@"t"] doubleValue],[a[@"pvW"] doubleValue],[b[@"pvW"] doubleValue]);
    }
    NSUInteger j=1;
    for(NSUInteger k=1;k<meter.count;k++) {
        NSDictionary *a=meter[k-1],*b=meter[k];if(!Continuous(a,b,stop))continue;
        double ta=[a[@"t"] doubleValue],tb=[b[@"t"] doubleValue];
        for(NSString *key in @[@"supplyW",@"chargeW"])if(Value(a,key)&&Value(b,key)) {
            Add(hours,key,ta,tb,[a[key] doubleValue],[b[key] doubleValue]);
            if([key isEqual:@"supplyW"])for(NSString *direction in @[@"importW",@"exportW"])Add(hours,direction,ta,tb,[a[key] doubleValue],[b[key] doubleValue]);
        }
        if(!Value(a,@"supplyW")||!Value(b,@"supplyW")||!Value(a,@"chargeW")||!Value(b,@"chargeW"))continue;
        while(j<pv.count&&[pv[j][@"t"] doubleValue]<=ta)j++;
        for(NSUInteger p=j;p<pv.count&&[pv[p-1][@"t"] doubleValue]<tb;p++) {
            NSDictionary *x=pv[p-1],*y=pv[p];if(!Continuous(x,y,stop)||!Value(x,@"pvW")||!Value(y,@"pvW"))continue;
            double lo=fmax(ta,[x[@"t"] doubleValue]),hi=fmin(tb,[y[@"t"] doubleValue]);if(hi<=lo)continue;
            double h0=Interpolate(x,y,@"pvW",lo)+Interpolate(a,b,@"supplyW",lo)-Interpolate(a,b,@"chargeW",lo);
            double h1=Interpolate(x,y,@"pvW",hi)+Interpolate(a,b,@"supplyW",hi)-Interpolate(a,b,@"chargeW",hi);
            if(h0>=0&&h1>=0)Add(hours,@"homeW",lo,hi,h0,h1); // inconsistent balances are unavailable
        }
    }
    NSMutableArray *result=[NSMutableArray array];
    for(NSNumber *key in [hours.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableDictionary *r=hours[key];for(NSString *metric in Metrics())if(r[metric]) {
            NSMutableDictionary *m=r[metric];m[@"meanW"]=@([m[@"wattSeconds"] doubleValue]/[m[@"coverage"] doubleValue]);[m removeObjectForKey:@"wattSeconds"];
        }
        [result addObject:r];
    }return result;
}
static NSString *Day(NSCalendar *c,NSDate *d) { NSDateComponents *p=[c components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:d];return [NSString stringWithFormat:@"%04ld-%02ld-%02ld",(long)p.year,(long)p.month,(long)p.day]; }
static NSString *Bucket(NSCalendar *c,NSDate *d) { NSInteger weekday=[c component:NSCalendarUnitWeekday fromDate:d];return [NSString stringWithFormat:@"%@/%ld",weekday==1||weekday==7?@"weekend":@"weekday",(long)[c component:NSCalendarUnitHour fromDate:d]]; }
NSDictionary *EBLearningModel(NSDictionary *statistics,NSDictionary *ledger,NSDate *now,NSTimeZone *zone) {
    NSCalendar *cal=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];cal.timeZone=zone;
    double t=now.timeIntervalSince1970;NSMutableDictionary *groups=[NSMutableDictionary dictionary];NSUInteger coveredHours=0;
    for(NSDictionary *h in EBLearningHours(statistics,ledger,now)) {
        double end=[h[@"end"] doubleValue];if(end>t||end<t-Training||[h[@"homeW"][@"coverage"] doubleValue]<2700)continue;
        NSDate *date=[NSDate dateWithTimeIntervalSince1970:[h[@"start"] doubleValue]];NSString *key=Bucket(cal,date),*day=Day(cal,date);
        if(!groups[key])groups[key]=[NSMutableDictionary dictionary];
        // A repeated DST hour contributes once per date, not two training days.
        groups[key][day]=@{@"w":h[@"homeW"][@"meanW"],@"coverage":h[@"homeW"][@"coverage"],@"end":@(end)};coveredHours++;
    }
    NSMutableDictionary *buckets=[NSMutableDictionary dictionary];
    for(NSString *key in groups) {
        NSArray *rows=[groups[key] allValues];NSMutableArray *values=[NSMutableArray array];double coverage=0,latest=0;
        for(NSDictionary *r in rows){[values addObject:r[@"w"]];coverage+=[r[@"coverage"] doubleValue];latest=fmax(latest,[r[@"end"] doubleValue]);}
        if(values.count<5||t-latest>14*86400)continue;
        NSMutableDictionary *b=[Distribution(values) mutableCopy];b[@"days"]=@(values.count);b[@"coverageSeconds"]=@(coverage);b[@"latest"]=@(latest);buckets[key]=b;
    }
    NSMutableArray *ratios=[NSMutableArray array];NSMutableSet *solarDays=[NSMutableSet set];NSMutableDictionary *errors=[NSMutableDictionary dictionary];
    NSUInteger scored=0;
    for(NSDictionary *v in ledger[@"vintages"]) {
        if([v[@"end"] doubleValue]>t||[v[@"end"] doubleValue]<t-Training||[v[@"issuedAt"] doubleValue]>=[v[@"start"] doubleValue])continue;
        BOOL any=NO;
        for(NSString *key in Metrics()) {
            NSDictionary *o=v[@"outcome"][key];id prediction=v[@"prediction"][key];
            if(!o||!Num(prediction)||[o[@"observedAt"] doubleValue]>t)continue;
            double error=[prediction doubleValue]-[o[@"meanW"] doubleValue];
            if(!errors[key])errors[key]=[NSMutableArray array];[errors[key] addObject:@(error)];any=YES;
        }
        if(any)scored++;
        NSDictionary *solar=v[@"outcome"][@"pvW"];double base=[v[@"prediction"][@"basePvW"] doubleValue];
        if(solar&&[solar[@"observedAt"] doubleValue]<=t&&base>=200) {
            double ratio=[solar[@"meanW"] doubleValue]/base;
            [ratios addObject:@(ratio)];[solarDays addObject:Day(cal,[NSDate dateWithTimeIntervalSince1970:[v[@"start"] doubleValue]])];
        }
    }
    BOOL calibrated=ratios.count>=12&&solarDays.count>=3;
    NSMutableDictionary *calibration=[@{@"available":@(calibrated),@"scoredDaylightHours":@(ratios.count),@"days":@(solarDays.count)} mutableCopy];
    if(calibrated){calibration[@"factor"]=@(fmin(1.5,fmax(.5,Quantile(ratios,.5))));calibration[@"lowFactor"]=@(fmax(0,Quantile(ratios,.1)));calibration[@"highFactor"]=@(fmin(2.5,Quantile(ratios,.9)));}
    NSMutableDictionary *scores=[NSMutableDictionary dictionary];
    for(NSString *key in errors){double sum=0,abs=0;for(NSNumber *n in errors[key]){sum+=n.doubleValue;abs+=fabs(n.doubleValue);}scores[key]=@{@"count":@([errors[key] count]),@"biasW":@(sum/[errors[key] count]),@"maeW":@(abs/[errors[key] count])};}
    NSMutableArray *energy=[NSMutableArray array],*duration=[NSMutableArray array];NSMutableSet *sessionDays=[NSMutableSet set];NSMutableDictionary *startHours=[NSMutableDictionary dictionary];
    for(NSDictionary *r in ledger[@"sessions"]) {
        double end=[r[@"end"] doubleValue];if(end>t||end<t-Retention)continue;
        [energy addObject:r[@"energyWh"]];[duration addObject:@(end-[r[@"start"] doubleValue])];
        NSDate *start=[NSDate dateWithTimeIntervalSince1970:[r[@"start"] doubleValue]];[sessionDays addObject:Day(cal,start)];NSString *key=Bucket(cal,start);startHours[key]=@([startHours[key] unsignedIntegerValue]+1);
    }
    BOOL sessionsReady=energy.count>=5&&sessionDays.count>=3;
    NSMutableDictionary *sessionSummary=[@{@"available":@(sessionsReady),@"completedCount":@(energy.count),@"days":@(sessionDays.count),@"source":@"measured-charger-register",@"currentBatteryNeedInferred":@NO} mutableCopy];
    if(sessionsReady){sessionSummary[@"energyWh"]=Distribution(energy);sessionSummary[@"elapsedSeconds"]=Distribution(duration);sessionSummary[@"startHours"]=startHours;}
    return @{@"modelVersion":@1,@"asOf":@(t),@"timeZone":zone.name,@"trainingDays":@28,@"homeMinimumDays":@5,@"homeCoveredHours":@(coveredHours),@"homeBuckets":buckets,
        @"solarCalibration":calibration,@"sessions":sessionSummary,@"savedVintages":@([ledger[@"vintages"] count]),@"scoredVintages":@(scored),@"errors":scores,
        @"rangeMeaning":@"observed p10–p90 spread; conditional scenarios, not a confidence interval or a battery-state measurement"};
}
NSDictionary *EBLearningRecord(NSDictionary *ledger,NSDictionary *statistics,EBPowerForecast *forecast,NSDictionary *context,NSDate *now) {
    double t=now.timeIntervalSince1970;NSMutableDictionary *hours=[NSMutableDictionary dictionary];
    for(NSDictionary *h in EBLearningHours(statistics,ledger,now))hours[h[@"start"]]=h;
    NSMutableArray *vintages=[NSMutableArray array];double start=(floor(t/3600)+1)*3600;BOOL exists=NO;
    for(NSDictionary *old in ledger[@"vintages"]) {
        NSMutableDictionary *v=[old mutableCopy];if([v[@"start"] doubleValue]==start)exists=YES;
        NSMutableDictionary *outcome=[v[@"outcome"] mutableCopy];NSDictionary *h=hours[v[@"start"]];
        // A ten-minute closeout lag lets source-time meter samples arrive. Never
        // hold a last reading forward; missing series remain unscored.
        if([v[@"end"] doubleValue]+600<=t)for(NSString *key in Metrics()) {
            NSDictionary *m=h[key];if(!outcome[key]&&v[@"prediction"][key]&&[m[@"coverage"] doubleValue]>=3240)
                outcome[key]=@{@"meanW":m[@"meanW"],@"coverage":m[@"coverage"],@"observedAt":@(t)};
        }
        v[@"outcome"]=outcome;[vintages addObject:v];
    }
    if(!exists&&forecast.asOf&&forecast.asOf.timeIntervalSince1970<=t&&t-forecast.asOf.timeIntervalSince1970<=60) {
        NSDictionary *average=EBForecastAverage(forecast.rows,[NSDate dateWithTimeIntervalSince1970:start],[NSDate dateWithTimeIntervalSince1970:start+3600]);
        NSMutableDictionary *prediction=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"pvW",@"basePvW",@"homeW",@"chargeW",@"supplyW",@"importW",@"exportW",@"pvLowW",@"pvHighW",@"homeLowW",@"homeHighW",@"supplyLowW",@"supplyHighW"])
            if(Num(average[key]))prediction[key]=average[key];
        if(prediction.count) {
            NSMutableDictionary *vehicle=[NSMutableDictionary dictionary];
            for(NSString *key in @[@"socSource",@"socEstimated",@"socAvailable",@"targetKnown",@"etaAvailable"])
                if([context[key] isKindOfClass:NSString.class]||[context[key] isKindOfClass:NSNumber.class])vehicle[key]=context[key];
            [vintages addObject:@{@"issuedAt":@(t),@"start":@(start),@"end":@(start+3600),@"modelVersion":@1,@"prediction":prediction,@"vehicle":vehicle,@"outcome":@{}}];
        }
    }
    NSMutableDictionary *result=[ledger mutableCopy];result[@"vintages"]=Bound(vintages,@"start",VintageLimit);return result;
}
