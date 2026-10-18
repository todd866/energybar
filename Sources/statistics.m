#import "statistics.h"
#import "store.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

const NSTimeInterval EBStatisticsRetention = 90.0 * 86400.0;
const NSUInteger EBStatisticsRecordLimit = 50000;
static const NSUInteger EBStatisticsByteLimit = 16 * 1024 * 1024;

@implementation EBStatisticsReport
- (instancetype)init {
    if ((self=[super init])) { _days=@[]; _weeks=@[]; _asOf=[NSDate date]; _timeZoneName=@"UTC"; }
    return self;
}
@end

static BOOL Number(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID() && isfinite([n doubleValue]);
}
static NSError *Problem(NSString *message) {
    return [NSError errorWithDomain:@"EnergybarStatistics" code:1
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *Hash(NSString *s) {
    NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding]; unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes,(CC_LONG)d.length,bytes); NSMutableString *out=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(bytes);i++) [out appendFormat:@"%02x",bytes[i]];
    return out;
}
static BOOL ValidRecord(NSDictionary *r, BOOL solar) {
    if (![r isKindOfClass:NSDictionary.class] || !Number(r[@"t"]) || [r[@"t"] doubleValue]<=0) return NO;
    if (solar) return [r[@"device"] isKindOfClass:NSString.class] && [r[@"device"] length]==64 &&
        Number(r[@"span"]) && [r[@"span"] doubleValue]>0 && [r[@"span"] doubleValue]<=48*3600 &&
        Number(r[@"wh"]) && [r[@"wh"] doubleValue]>=0;
    return (!r[@"supplyW"] || Number(r[@"supplyW"])) &&
        (!r[@"chargeW"] || (Number(r[@"chargeW"]) && [r[@"chargeW"] doubleValue]>=0));
}
static BOOL ValidDocument(NSDictionary *doc, NSString *sourceID) {
    if (![doc isKindOfClass:NSDictionary.class] || ![doc[@"schema"] isEqual:@1] ||
        ![doc[@"source"] isEqual:sourceID]) return NO;
    for (NSString *key in @[@"meter",@"solar"]) {
        if (![doc[key] isKindOfClass:NSArray.class] || [doc[key] count]>EBStatisticsRecordLimit) return NO;
        for (NSDictionary *r in doc[key]) if (!ValidRecord(r,[key isEqual:@"solar"])) return NO;
    }
    return YES;
}
static NSArray *Bounded(NSArray *old, NSArray *incoming, BOOL solar, NSDate *now) {
    NSMutableDictionary *byKey=[NSMutableDictionary dictionary];
    double end=now.timeIntervalSince1970,cutoff=end-EBStatisticsRetention;
    for (NSArray *source in @[old ?: @[], incoming]) for (NSDictionary *r in source) {
        if (!ValidRecord(r,solar)) continue;
        double t=[r[@"t"] doubleValue]; if (t<cutoff || t>end) continue;
        NSString *key=solar ? [NSString stringWithFormat:@"%@/%.6f",r[@"device"],t]
                           : [NSString stringWithFormat:@"%.6f",t];
        // Whitelist fields, including when loading an older local file.
        NSMutableDictionary *clean=[@{@"t":r[@"t"]} mutableCopy];
        for (NSString *field in solar ? @[@"device",@"span",@"wh"] : @[@"supplyW",@"chargeW"])
            if (r[field]) clean[field]=r[field];
        byKey[key]=clean;
    }
    NSArray *rows=[byKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult t=[a[@"t"] compare:b[@"t"]];
        return t==NSOrderedSame && solar ? [a[@"device"] compare:b[@"device"]] : t;
    }];
    return rows.count>EBStatisticsRecordLimit ? [rows subarrayWithRange:NSMakeRange(rows.count-EBStatisticsRecordLimit,EBStatisticsRecordLimit)] : rows;
}
NSDictionary *EBStatisticsMerge(NSDictionary *previous, NSString *sourceID, NSArray *samples,
    NSArray<EBFroniusPVInterval *> *solar, NSDate *now, NSError **error) {
    if (!sourceID.length || !now || (previous && !ValidDocument(previous,sourceID))) {
        if (error) *error=Problem(@"Statistics history is invalid or belongs to another source; preserved unchanged.");
        return nil;
    }
    NSMutableArray *meter=[NSMutableArray array],*pv=[NSMutableArray array];
    for (NSDictionary *sample in samples) {
        if (![sample isKindOfClass:NSDictionary.class] || [sample[@"statusOnly"] isEqual:@YES] ||
            ![sample[@"t"] isKindOfClass:NSDate.class]) continue;
        NSMutableDictionary *r=[@{@"t":@([sample[@"t"] timeIntervalSince1970])} mutableCopy];
        for (NSString *key in @[@"supplyW",@"chargeW"]) {
            id n=sample[key];
            if (Number(n) && (![key isEqual:@"chargeW"] || [n doubleValue]>=0)) r[key]=n;
        }
        [meter addObject:r]; // an empty power row is a real gap, not a zero.
    }
    for (EBFroniusPVInterval *iv in solar) {
        [pv addObject:@{@"t":@(iv.anchor.timeIntervalSince1970),@"span":@(iv.spanSeconds),
                       @"wh":@(iv.energyWh),@"device":Hash(iv.deviceID)}];
    }
    return @{@"schema":@1,@"source":sourceID,@"updatedAt":@(now.timeIntervalSince1970),
        @"meter":Bounded(previous[@"meter"],meter,NO,now),@"solar":Bounded(previous[@"solar"],pv,YES,now)};
}

NSDictionary *EBStatisticsLoad(NSString *path,NSString *sourceID,NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *previous=nil;
    if ([fm fileExistsAtPath:path]) {
        NSDictionary *attrs=[fm attributesOfItemAtPath:path error:error];
        if (!attrs || [attrs[NSFileSize] unsignedLongLongValue]>EBStatisticsByteLimit ||
            ![attrs[NSFileType] isEqual:NSFileTypeRegular]) {
            if (error) *error=Problem(@"Statistics history cannot be read safely; preserved unchanged."); return nil;
        }
        NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error];
        previous=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
        if (!previous) { if (error) *error=Problem(@"Statistics history is unreadable; preserved unchanged."); return nil; }
    }
    if(previous&&!ValidDocument(previous,sourceID)) { if(error)*error=Problem(@"Statistics history is invalid or belongs to another source; preserved unchanged.");return nil; }
    return previous;
}
NSDictionary *EBStatisticsUpdate(NSString *path, NSString *sourceID, NSArray *samples,
    NSArray<EBFroniusPVInterval *> *solar, NSDate *now, NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *previous=EBStatisticsLoad(path,sourceID,error);
    if(!previous&&[fm fileExistsAtPath:path])return nil;
    NSDictionary *merged=EBStatisticsMerge(previous,sourceID,samples,solar,now,error);
    if (!merged) return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:merged options:NSJSONWritingSortedKeys error:error];
    if (!data || data.length>EBStatisticsByteLimit) {
        if (error) *error=Problem(@"Statistics history exceeded its storage bound; previous history preserved."); return nil;
    }
    NSString *dir=path.stringByDeletingLastPathComponent;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    if (chmod(dir.fileSystemRepresentation,0700)!=0) { if(error)*error=Problem(@"Statistics directory cannot be secured.");return nil; }
    NSString *template=[dir stringByAppendingPathComponent:@".statistics-XXXXXX"];
    char *tmp=strdup(template.fileSystemRepresentation); int fd=mkstemp(tmp);
    if (fd<0) { free(tmp);if(error)*error=Problem(@"Statistics history cannot be saved.");return nil; }
    BOOL ok=fchmod(fd,0600)==0; const uint8_t *bytes=data.bytes; NSUInteger remaining=data.length;
    while (ok && remaining) {
        ssize_t n=write(fd,bytes,remaining); if(n<0 && errno==EINTR)continue;
        if(n<=0){ok=NO;break;} bytes+=n;remaining-=(NSUInteger)n;
    }
    if(ok && fsync(fd)!=0)ok=NO;
    if(close(fd)!=0)ok=NO;
    if(ok && rename(tmp,path.fileSystemRepresentation)!=0)ok=NO;
    if(!ok)unlink(tmp); free(tmp);
    if(ok) { int d=open(dir.fileSystemRepresentation,O_RDONLY); if(d<0)ok=NO;else{if(fsync(d)!=0)ok=NO;if(close(d)!=0)ok=NO;} }
    if(!ok){if(error)*error=Problem(@"Statistics history could not be durably saved.");return nil;}
    return merged;
}

static NSMutableDictionary *Metric(void) { return [@{@"wh":@0,@"coverage":@0,@"latest":@0} mutableCopy]; }
static NSMutableDictionary *Period(NSDate *start, NSDate *end) {
    return [@{@"start":start,@"end":end,@"span":@(fmax(0,[end timeIntervalSinceDate:start])),
        @"solar":Metric(),@"import":Metric(),@"export":Metric(),@"car":Metric()} mutableCopy];
}
static void Add(NSMutableDictionary *m,double wh,double seconds,double latest) {
    m[@"wh"]=@([m[@"wh"] doubleValue]+wh);m[@"coverage"]=@([m[@"coverage"] doubleValue]+seconds);
    m[@"latest"]=@(fmax([m[@"latest"] doubleValue],latest));
}
static double CoveredSeconds(NSArray<NSArray<NSNumber *> *> *intervals) {
    NSArray *ordered=[intervals sortedArrayUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [a[0] compare:b[0]];}];
    double total=0,start=0,end=0;BOOL have=NO;
    for(NSArray *interval in ordered){
        double a=[interval[0] doubleValue],b=[interval[1] doubleValue];
        if(have && a>end){total+=end-start;have=NO;}
        if(!have){start=a;end=b;have=YES;}else end=fmax(end,b);
    }
    return total+(have?end-start:0);
}
EBStatisticsReport *EBStatisticsSummarize(NSDictionary *document, NSDate *now,NSTimeZone *timeZone) {
    EBStatisticsReport *report=[EBStatisticsReport new];report.asOf=now;report.timeZoneName=timeZone.name;
    NSCalendar *cal=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];cal.timeZone=timeZone;cal.firstWeekday=2;cal.minimumDaysInFirstWeek=4;
    NSDate *today=[cal startOfDayForDate:now];
    NSMutableDictionary<NSDate *,NSMutableDictionary *> *days=[NSMutableDictionary dictionary];
    for(NSInteger i=0;i<90;i++){
        NSDate *start=[cal dateByAddingUnit:NSCalendarUnitDay value:-i toDate:today options:0];
        NSDate *end=[cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:start options:0];
        days[start]=Period(start,[end earlierDate:now]);
    }
    NSArray *meter=document[@"meter"] ?: @[];
    for(NSUInteger i=1;i<meter.count;i++){
        NSDictionary *a=meter[i-1],*b=meter[i];double ta=[a[@"t"] doubleValue],tb=[b[@"t"] doubleValue],dt=tb-ta;
        if(dt<=0||dt>EBStoreIntegrationGapSeconds||tb>now.timeIntervalSince1970)continue;
        double cursor=ta;
        while(cursor<tb){
            NSDate *date=[NSDate dateWithTimeIntervalSince1970:cursor];NSDate *day=[cal startOfDayForDate:date];
            double edge=[[cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0] timeIntervalSince1970];
            double end=fmin(tb,edge),seconds=end-cursor;NSMutableDictionary *p=days[day];
            if(p){
                double lo=(cursor-ta)/dt,hi=(end-ta)/dt;
                if(a[@"supplyW"]&&b[@"supplyW"]){
                    double x=[a[@"supplyW"] doubleValue],delta=[b[@"supplyW"] doubleValue]-x;
                    EBGridEnergy energy=EBGridEnergyForInterval(x+delta*lo,x+delta*hi,seconds);
                    Add(p[@"import"],energy.importWh,seconds,tb);Add(p[@"export"],energy.exportWh,seconds,tb);
                }
                if(a[@"chargeW"]&&b[@"chargeW"]){
                    double x=[a[@"chargeW"] doubleValue],delta=[b[@"chargeW"] doubleValue]-x;
                    Add(p[@"car"],(x+delta*(lo+hi)/2)*seconds/3600,seconds,tb);
                }
            }
            cursor=end;
        }
    }
    NSMutableSet *devices=[NSMutableSet set];NSMutableDictionary *solarCoverage=[NSMutableDictionary dictionary];
    for(NSDictionary *r in document[@"solar"]){
        [devices addObject:r[@"device"]];
        double t=[r[@"t"] doubleValue],span=[r[@"span"] doubleValue];
        NSDate *day=[cal startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:t]];NSMutableDictionary *p=days[day];
        // Unknown anchor direction: include only whole records inside BOTH possible interpretations.
        if(!p||t-span<[p[@"start"] timeIntervalSince1970]||t+span>[p[@"end"] timeIntervalSince1970])continue;
        // The archive's identity is device+anchor, already deduplicated at merge.
        // Logger duration jitter must not discard a distinct energy-register record.
        Add(p[@"solar"],[r[@"wh"] doubleValue],0,t);
        if(!solarCoverage[day])solarCoverage[day]=[NSMutableDictionary dictionary];
        NSMutableDictionary *byDevice=solarCoverage[day];
        if(!byDevice[r[@"device"]])byDevice[r[@"device"]]=@[[NSMutableArray array],[NSMutableArray array]];
        NSArray *interpretations=byDevice[r[@"device"]];
        [interpretations[0] addObject:@[@(t-span),@(t)]];
        [interpretations[1] addObject:@[@(t),@(t+span)]];
    }
    NSArray *ordered=[days.allKeys sortedArrayUsingSelector:@selector(compare:)];NSMutableArray *daily=[NSMutableArray array];
    NSMutableDictionary<NSDate *,NSMutableDictionary *> *weeks=[NSMutableDictionary dictionary];
    for(NSDate *date in ordered){
        NSMutableDictionary *day=days[date];NSMutableDictionary *sun=day[@"solar"];
        double recorded=0;
        for(NSArray *interpretations in [solarCoverage[date] allValues])
            recorded+=fmin(CoveredSeconds(interpretations[0]),CoveredSeconds(interpretations[1]));
        // Union overlapping time, and use the smaller total of both possible
        // anchor directions. Energy remains the sum of exact source records.
        sun[@"coverage"]=@(recorded/fmax(1,devices.count));sun[@"deviceCount"]=@(devices.count);
        NSDate *weekStart=nil;
        [cal rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&weekStart interval:NULL forDate:date];
        NSMutableDictionary *week=weeks[weekStart];
        if(!week){NSDate *end=[cal dateByAddingUnit:NSCalendarUnitDay value:7 toDate:weekStart options:0];week=Period(weekStart,[end earlierDate:now]);weeks[weekStart]=week;}
        for(NSString *key in @[@"solar",@"import",@"export",@"car"]){
            NSMutableDictionary *m=day[key];double coverage=[m[@"coverage"] doubleValue];
            m[@"partial"]=@([key isEqual:@"solar"]||coverage+1<[day[@"span"] doubleValue]);
            m[@"source"]=[key isEqual:@"solar"]?@"archive-register":@"measured-power-integration";
            Add(week[key],[m[@"wh"] doubleValue],coverage,[m[@"latest"] doubleValue]);
        }
        [daily addObject:day];
    }
    NSMutableArray *weekly=[NSMutableArray array];
    for(NSDate *date in [weeks.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        NSMutableDictionary *week=weeks[date];
        for(NSString *key in @[@"solar",@"import",@"export",@"car"]){NSMutableDictionary *m=week[key];
            m[@"partial"]=@([key isEqual:@"solar"]||[m[@"coverage"] doubleValue]+1<[week[@"span"] doubleValue]);
            m[@"source"]=[key isEqual:@"solar"]?@"archive-register":@"measured-power-integration";
        }
        week[@"solar"][@"deviceCount"]=@(devices.count);[weekly addObject:week];
    }
    report.days=[[daily reverseObjectEnumerator] allObjects];report.weeks=[[weekly reverseObjectEnumerator] allObjects];
    return report;
}
