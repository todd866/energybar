#import "tariff.h"
#import "store.h"
#import <math.h>

static NSString * const EBTariffErrorDomain = @"EnergybarTariff";

static NSError *EBTariffError(NSString *message) {
    return [NSError errorWithDomain:EBTariffErrorDomain code:1 userInfo:@{
        NSLocalizedDescriptionKey: message ?: @"Invalid tariff"
    }];
}

static BOOL EBFiniteNumber(id value, double *out) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double n = [value doubleValue];
    if (!isfinite(n)) return NO;
    if (out) *out = n;
    return YES;
}

static BOOL EBIntegerNumber(id value, NSInteger *out) {
    double n = 0;
    if (!EBFiniteNumber(value, &n) || floor(n) != n) return NO;
    // Every integer in this format is either a day number or minute of day.
    // Bound before casting, including double's rounded representation of NSIntegerMax.
    if (n < 0 || n > 1440) return NO;
    if (out) *out = (NSInteger)n;
    return YES;
}

static NSDate *EBDateOnly(NSString *text, NSTimeZone *zone) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = zone;
    f.lenient = NO;
    f.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [f dateFromString:text];
    if (!date || ![[f stringFromDate:date] isEqualToString:text]) return nil;
    return date;
}

@interface EBTariffBand : NSObject
@property NSInteger startMinute, endMinute;
@property double importCents, exportCents;
@property NSSet<NSNumber *> *weekdays;
@end
@implementation EBTariffBand @end

@interface EBTariff ()
@property(nonatomic, readwrite, copy) NSString *name;
@property(nonatomic, readwrite, copy) NSString *currency;
@property(nonatomic, readwrite, copy) NSTimeZone *timeZone;
@property(nonatomic, readwrite, copy, nullable) NSString *sourceURL;
@property(nonatomic, copy) NSArray<EBTariffBand *> *bands;
@property(nonatomic, copy, nullable) NSDate *validFrom;
@property(nonatomic, copy, nullable) NSDate *validUntil;
@end

@implementation EBTariff

+ (instancetype)fromDictionary:(NSDictionary *)dictionary error:(NSError **)error {
    if (error) *error = nil;
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        if (error) *error = EBTariffError(@"Tariff root must be an object");
        return nil;
    }
    NSString *name = dictionary[@"name"], *currency = dictionary[@"currency"];
    NSString *zoneName = dictionary[@"timeZone"];
    NSCharacterSet *uppercase = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    BOOL isoCurrency = [currency isKindOfClass:NSString.class] && currency.length == 3 &&
        [currency rangeOfCharacterFromSet:[uppercase invertedSet]].location == NSNotFound;
    if (![name isKindOfClass:NSString.class] || !name.length || name.length > 80 ||
        !isoCurrency || ![NSLocale.ISOCurrencyCodes containsObject:currency] ||
        ![zoneName isKindOfClass:NSString.class] || !zoneName.length) {
        if (error) *error = EBTariffError(@"name, uppercase ISO-4217 currency, and timeZone are required");
        return nil;
    }
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:zoneName];
    if (!zone) {
        if (error) *error = EBTariffError(@"timeZone must be a valid IANA timezone");
        return nil;
    }
    id source = dictionary[@"sourceURL"];
    if (source && ![source isKindOfClass:NSString.class]) {
        if (error) *error = EBTariffError(@"sourceURL must be a string");
        return nil;
    }
    EBTariff *tariff = [EBTariff new];
    tariff.name = name; tariff.currency = currency; tariff.timeZone = zone;
    tariff.sourceURL = [source length] ? source : nil;
    for (NSString *key in @[@"validFrom", @"validUntil"]) {
        id text = dictionary[key];
        if (text && (![text isKindOfClass:NSString.class] || !EBDateOnly(text, zone))) {
            if (error) *error = EBTariffError([NSString stringWithFormat:@"%@ must be YYYY-MM-DD", key]);
            return nil;
        }
    }
    tariff.validFrom = dictionary[@"validFrom"] ? EBDateOnly(dictionary[@"validFrom"], zone) : nil;
    tariff.validUntil = dictionary[@"validUntil"] ? EBDateOnly(dictionary[@"validUntil"], zone) : nil;
    if (tariff.validFrom && tariff.validUntil && [tariff.validUntil compare:tariff.validFrom] != NSOrderedDescending) {
        if (error) *error = EBTariffError(@"validUntil must be after validFrom");
        return nil;
    }
    NSArray *rawBands = dictionary[@"bands"];
    if (![rawBands isKindOfClass:NSArray.class] || rawBands.count == 0 || rawBands.count > 32) {
        if (error) *error = EBTariffError(@"bands must contain 1 to 32 entries");
        return nil;
    }
    NSMutableArray *bands = [NSMutableArray arrayWithCapacity:rawBands.count];
    for (NSDictionary *raw in rawBands) {
        if (![raw isKindOfClass:NSDictionary.class]) { if (error) *error = EBTariffError(@"each band must be an object"); return nil; }
        NSInteger start = 0, end = 0; double import = 0, export = 0;
        if (!EBIntegerNumber(raw[@"startMinute"], &start) || !EBIntegerNumber(raw[@"endMinute"], &end) ||
            start < 0 || end > 1440 || end <= start ||
            !EBFiniteNumber(raw[@"importCents"], &import) || !EBFiniteNumber(raw[@"exportCents"], &export) ||
            import < 0 || export < 0 || import > 1000 || export > 1000) {
            if (error) *error = EBTariffError(@"band minutes/rates are invalid or out of bounds");
            return nil;
        }
        id days = raw[@"weekdays"];
        NSSet *weekdays = nil;
        if (days) {
            if (![days isKindOfClass:NSArray.class] || ![(NSArray *)days count]) { if (error) *error = EBTariffError(@"weekdays must be a nonempty array"); return nil; }
            NSMutableSet *set = [NSMutableSet set];
            for (id day in days) { NSInteger n = 0; if (!EBIntegerNumber(day, &n) || n < 1 || n > 7) { if (error) *error = EBTariffError(@"weekdays must contain integers 1 through 7"); return nil; } [set addObject:@(n)]; }
            weekdays = [set copy];
        }
        EBTariffBand *band = [EBTariffBand new]; band.startMinute = start; band.endMinute = end; band.importCents = import; band.exportCents = export; band.weekdays = weekdays;
        [bands addObject:band];
    }
    for (NSInteger day = 1; day <= 7; day++) {
        NSArray *applicable = [bands filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(EBTariffBand *band, NSDictionary *_) {
            return !band.weekdays || [band.weekdays containsObject:@(day)];
        }]];
        applicable = [applicable sortedArrayUsingComparator:^NSComparisonResult(EBTariffBand *a, EBTariffBand *b) {
            return a.startMinute < b.startMinute ? NSOrderedAscending : (a.startMinute > b.startMinute ? NSOrderedDescending : NSOrderedSame);
        }];
        NSInteger cursor = 0;
        for (EBTariffBand *band in applicable) {
            if (band.startMinute != cursor) { if (error) *error = EBTariffError(@"bands must exactly cover every weekday without overlap"); return nil; }
            cursor = band.endMinute;
        }
        if (cursor != 1440) { if (error) *error = EBTariffError(@"bands must exactly cover every weekday without overlap"); return nil; }
    }
    tariff.bands = [bands copy];
    return tariff;
}

- (BOOL)ratesAtDate:(NSDate *)date importCents:(double *)importCents exportCents:(double *)exportCents {
    if (!date || (self.validFrom && [date compare:self.validFrom] == NSOrderedAscending) ||
        (self.validUntil && [date compare:self.validUntil] != NSOrderedAscending)) return NO;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = self.timeZone;
    NSDateComponents *c = [cal components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    NSInteger minute = c.hour * 60 + c.minute;
    for (EBTariffBand *band in self.bands) if ((!band.weekdays || [band.weekdays containsObject:@(c.weekday)]) && minute >= band.startMinute && minute < band.endMinute) {
        if (importCents) *importCents = band.importCents;
        if (exportCents) *exportCents = band.exportCents;
        return YES;
    }
    return NO;
}

@end

EBTariff *EBTariffLoad(NSString *path, NSError **error) {
    if (error) *error = nil;
    NSError *attributeError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributeError];
    if (!attributes) {
        BOOL missing = [attributeError.domain isEqual:NSCocoaErrorDomain] &&
            (attributeError.code == NSFileNoSuchFileError || attributeError.code == NSFileReadNoSuchFileError);
        if (error && !missing) *error = attributeError;
        return nil;
    }
    unsigned long long size = [attributes fileSize];
    if (size > 65536) { if (error) *error = EBTariffError(@"tariff file exceeds 64 KiB"); return nil; }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) { if (error) *error = readError ?: EBTariffError(@"tariff file could not be read"); return nil; }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!object) { if (error) *error = jsonError; return nil; }
    return [EBTariff fromDictionary:object error:error];
}

EBGridCostTotals EBTariffIntegrate(NSArray<NSDictionary *> *samples, NSDate *since, NSDate *now, EBTariff *tariff) {
    EBGridCostTotals out = {0};
    if (!since || !now || [now compare:since] == NSOrderedAscending) return out;
    out.span = [now timeIntervalSinceDate:since];
    if (!tariff || samples.count < 2) return out;
    NSPredicate *validDate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *_) {
        return [row isKindOfClass:NSDictionary.class] && [row[@"t"] isKindOfClass:NSDate.class] && ![row[@"statusOnly"] isEqual:@YES];
    }];
    NSArray *sorted = [[samples filteredArrayUsingPredicate:validDate] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"t"] compare:b[@"t"]]; }];
    for (NSUInteger i = 1; i < sorted.count; i++) {
        NSDictionary *a = sorted[i-1], *b = sorted[i]; NSDate *ta = a[@"t"], *tb = b[@"t"];
        NSNumber *wa = a[@"supplyW"], *wb = b[@"supplyW"];
        if (![ta isKindOfClass:NSDate.class] || ![tb isKindOfClass:NSDate.class] || !EBFiniteNumber(wa, NULL) || !EBFiniteNumber(wb, NULL)) continue;
        NSTimeInterval dt = [tb timeIntervalSinceDate:ta]; if (dt <= 0 || dt > EBStoreIntegrationGapSeconds) continue;
        NSDate *lo = [ta compare:since] == NSOrderedAscending ? since : ta; NSDate *hi = [tb compare:now] == NSOrderedDescending ? now : tb;
        if ([hi compare:lo] != NSOrderedDescending) continue;
        double firstW = [wa doubleValue] + ([wb doubleValue]-[wa doubleValue]) * ([lo timeIntervalSinceDate:ta]/dt);
        NSDate *cursor = lo;
        while ([cursor compare:hi] == NSOrderedAscending) {
            NSTimeInterval remaining = [hi timeIntervalSinceDate:cursor];
            NSTimeInterval epoch = [cursor timeIntervalSince1970];
            NSTimeInterval nextMinute = (floor(epoch / 60.0) + 1.0) * 60.0;
            NSDate *next = [NSDate dateWithTimeIntervalSince1970:MIN([hi timeIntervalSince1970], nextMinute)];
            if ([next compare:cursor] != NSOrderedDescending) next = [cursor dateByAddingTimeInterval:MIN(remaining, 60.0)];
            NSTimeInterval seconds = [next timeIntervalSinceDate:cursor];
            double lastW = [wa doubleValue] + ([wb doubleValue]-[wa doubleValue]) * ([next timeIntervalSinceDate:ta]/dt);
            double importRate = 0, exportRate = 0;
            if ([tariff ratesAtDate:[cursor dateByAddingTimeInterval:seconds/2] importCents:&importRate exportCents:&exportRate]) {
                EBGridEnergy energy = EBGridEnergyForInterval(firstW, lastW, seconds);
                out.importWh += energy.importWh; out.exportWh += energy.exportWh;
                out.importCost += energy.importWh / 1000.0 * importRate / 100.0;
                out.exportCredit += energy.exportWh / 1000.0 * exportRate / 100.0;
                out.coverage += seconds;
            }
            firstW = lastW; cursor = next;
        }
    }
    return out;
}
