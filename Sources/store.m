#import "store.h"
#import <errno.h>
#import <fcntl.h>
#import <float.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

const NSTimeInterval EBStoreIntegrationGapSeconds = 7 * 60;

static NSISO8601DateFormatter *EBStoreISO(void) {
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSISO8601DateFormatter new];
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return f;
}

static NSDate *EBStoreParseDate(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return nil;
    NSDate *d = [EBStoreISO() dateFromString:s];
    if (d) return d;
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [f dateFromString:s];
}

static NSNumber *EBStoreFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static NSNumber *EBStoreStateNumber(id value) {
    NSNumber *number = EBStoreFiniteNumber(value);
    if (!number) return nil;
    double state = number.doubleValue;
    return trunc(state) == state ? number : nil;
}

static BOOL EBStoreWritePrivateFile(NSString *path, NSData *data) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    NSString *name = path.lastPathComponent.length ? path.lastPathComponent : @"samples";
    NSString *templatePath = [directory stringByAppendingPathComponent:
                              [NSString stringWithFormat:@".%@.XXXXXX", name]];
    const char *templateFS = templatePath.fileSystemRepresentation;
    if (!templateFS) return NO;
    char *temporaryFS = strdup(templateFS);
    if (!temporaryFS) return NO;

    int fd = mkstemp(temporaryFS);
    if (fd < 0) {
        free(temporaryFS);
        return NO;
    }

    BOOL ok = fchmod(fd, S_IRUSR | S_IWUSR) == 0;
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            ok = NO;
            break;
        }
        cursor += written;
        remaining -= (NSUInteger)written;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0) ok = NO;

    const char *destinationFS = path.fileSystemRepresentation;
    if (!destinationFS || !ok || rename(temporaryFS, destinationFS) != 0) {
        unlink(temporaryFS);
        free(temporaryFS);
        return NO;
    }
    free(temporaryFS);
    return YES;
}

static BOOL EBStoreAppendRow(NSString *path, NSDate *t,
                             NSNumber *pvW, NSNumber *supplyW, NSNumber *chargeW,
                             NSNumber *chargerState, BOOL statusOnly,
                             NSTimeInterval maxAgeSeconds) {
    if (!path.length || !t) return NO;
    if ((pvW && !EBStoreFiniteNumber(pvW)) ||
        (supplyW && !EBStoreFiniteNumber(supplyW)) ||
        (chargeW && !EBStoreFiniteNumber(chargeW)) ||
        (chargerState && !EBStoreStateNumber(chargerState))) return NO;
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"t"] = [EBStoreISO() stringFromDate:t];
    if (pvW) row[@"pvW"] = pvW;
    if (supplyW) row[@"supplyW"] = supplyW;
    if (chargeW) row[@"chargeW"] = chargeW;
    if (chargerState) row[@"st"] = chargerState;
    if (statusOnly) row[@"statusOnly"] = @YES;
    if (row.count == 1) return NO; // timestamp only — nothing to store

    NSData *lineData = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if (!lineData) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    BOOL existingFile = [fm fileExistsAtPath:path];
    NSError *readError = nil;
    NSString *existing = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:&readError];
    if (existingFile && !existing) return NO;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-maxAgeSeconds];
    if (existing.length) {
        for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (line.length == 0) continue;
            NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            NSDate *dt = EBStoreParseDate(j[@"t"]);
            if (dt && [dt compare:cutoff] != NSOrderedAscending) [keep addObject:line];
        }
    }
    [keep addObject:[[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding]];
    NSString *out = [[keep componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSData *outData = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (!outData) return NO;
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) directory = @".";
    BOOL isDirectory = NO;
    BOOL directoryExists = [fm fileExistsAtPath:directory isDirectory:&isDirectory];
    if (directoryExists && !isDirectory) return NO;
    if (!directoryExists) {
        NSError *error = nil;
        if (![fm createDirectoryAtPath:directory
           withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0700}
                                 error:&error]) return NO;
        if (![fm setAttributes:@{NSFilePosixPermissions: @0700}
                        ofItemAtPath:directory error:&error]) return NO;
    }
    return EBStoreWritePrivateFile(path, outData);
}

BOOL EBStoreAppend(NSString *path, NSDate *t,
                   NSNumber *pvW, NSNumber *supplyW, NSNumber *chargeW,
                   NSNumber *chargerState,
                   NSTimeInterval maxAgeSeconds) {
    return EBStoreAppendRow(path, t, pvW, supplyW, chargeW, chargerState,
                            NO, maxAgeSeconds);
}

BOOL EBStoreAppendStatus(NSString *path, NSDate *t, NSNumber *chargerState,
                         NSTimeInterval maxAgeSeconds) {
    if (!EBStoreStateNumber(chargerState)) return NO;
    return EBStoreAppendRow(path, t, nil, nil, nil, chargerState,
                            YES, maxAgeSeconds);
}

BOOL EBStoreSecureExistingFile(NSString *path) {
    if (!path.length) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = path.stringByDeletingLastPathComponent;
    BOOL isDirectory = NO;
    if ([manager fileExistsAtPath:directory isDirectory:&isDirectory]) {
        if (!isDirectory || chmod(directory.fileSystemRepresentation, 0700) != 0) return NO;
    }
    BOOL isFileDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isFileDirectory]) return YES;
    if (isFileDirectory) return NO;
    return chmod(path.fileSystemRepresentation, 0600) == 0;
}

static NSArray<NSDictionary *> *EBCanonicalStoreRows(NSArray<NSDictionary *> *input) {
    NSMutableArray<NSDictionary *> *rows = [input mutableCopy] ?: [NSMutableArray array];
    [rows sortWithOptions:NSSortStable
          usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"t"] compare:b[@"t"]];
    }];
    NSMutableArray<NSDictionary *> *canonical = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSUInteger replacement = NSNotFound;
        BOOL rowIsStatus = [row[@"statusOnly"] boolValue];
        for (NSUInteger i = canonical.count; i > 0; i--) {
            NSDictionary *candidate = canonical[i - 1];
            if ([candidate[@"t"] compare:row[@"t"]] != NSOrderedSame) break;
            if ([candidate[@"statusOnly"] boolValue] == rowIsStatus) {
                replacement = i - 1;
                break;
            }
        }
        if (replacement != NSNotFound)
            canonical[replacement] = row; // latest supplied row wins per role
        else
            [canonical addObject:row];
    }
    return canonical;
}

NSArray<NSDictionary *> *EBStoreLoad(NSString *path, NSTimeInterval maxAgeSeconds) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!existing.length) return rows;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-maxAgeSeconds];
    for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0) continue;
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![j isKindOfClass:NSDictionary.class]) continue;
        NSDate *dt = EBStoreParseDate(j[@"t"]);
        if (!dt || [dt compare:cutoff] == NSOrderedAscending) continue;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"t"] = dt;
        NSNumber *pv = EBStoreFiniteNumber(j[@"pvW"]);
        NSNumber *supply = EBStoreFiniteNumber(j[@"supplyW"]);
        NSNumber *charge = EBStoreFiniteNumber(j[@"chargeW"]);
        NSNumber *state = EBStoreStateNumber(j[@"st"]);
        BOOL statusOnly = [j[@"statusOnly"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)j[@"statusOnly"]) == CFBooleanGetTypeID() &&
            [j[@"statusOnly"] boolValue];
        if (pv) out[@"pvW"] = pv;
        if (supply) out[@"supplyW"] = supply;
        if (charge) out[@"chargeW"] = charge;
        if (state) out[@"st"] = state;
        if (statusOnly) out[@"statusOnly"] = @YES;
        [rows addObject:out];
    }
    return EBCanonicalStoreRows(rows);
}

NSArray<NSDictionary *> *EBStoreMergeSamples(NSArray<NSDictionary *> *persisted,
                                               NSArray<NSDictionary *> *transient,
                                               NSDate *now,
                                               NSTimeInterval maxAgeSeconds) {
    NSDate *cutoff = [now dateByAddingTimeInterval:-maxAgeSeconds];
    NSMutableArray<NSArray<NSDictionary *> *> *canonicalSources = [NSMutableArray array];
    for (NSArray *source in @[persisted ?: @[], transient ?: @[]]) {
        NSMutableArray<NSDictionary *> *eligible = [NSMutableArray array];
        for (id value in source) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *row = value;
            NSDate *t = row[@"t"];
            if (![t isKindOfClass:NSDate.class] ||
                [t compare:cutoff] == NSOrderedAscending) continue;
            [eligible addObject:row];
        }
        [canonicalSources addObject:EBCanonicalStoreRows(eligible)];
    }
    // Role-aware canonicalization deduplicates the same live checkpoint after
    // it has also been persisted, while keeping equal-time status and power
    // rows distinct. Energy inference filters only the former.
    NSMutableArray<NSDictionary *> *merged = [NSMutableArray array];
    for (NSArray *source in canonicalSources) [merged addObjectsFromArray:source];
    return EBCanonicalStoreRows(merged);
}

NSArray<NSDictionary *> *EBStoreDownsample(NSArray<NSDictionary *> *samples, NSUInteger maxPoints) {
    if (samples.count <= maxPoints || maxPoints == 0) return samples;
    if (maxPoints == 1) return @[samples.lastObject];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:maxPoints];
    NSUInteger n = samples.count;
    for (NSUInteger i = 0; i < maxPoints; i++) {
        NSUInteger idx = (i * (n - 1)) / (maxPoints - 1);
        [out addObject:samples[idx]];
    }
    return out;
}

NSDate *EBStartOfLocalDay(NSDate *now) {
    NSCalendar *cal = NSCalendar.currentCalendar;
    return [cal startOfDayForDate:now ?: [NSDate date]];
}

NSArray<NSDictionary *> *EBStoreBucket(NSArray<NSDictionary *> *samples,
                                       NSDate *since, NSDate *now,
                                       NSUInteger buckets) {
    if (!since || !now || buckets == 0 || samples.count == 0) return @[];
    NSTimeInterval span = [now timeIntervalSinceDate:since];
    if (span <= 0) return @[];
    NSTimeInterval width = span / (NSTimeInterval)buckets;
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger b = 0; b < buckets; b++) {
        NSDate *lo = [since dateByAddingTimeInterval:width * b];
        NSDate *hi = [since dateByAddingTimeInterval:width * (b + 1)];
        NSDictionary *minSupplyRow = nil, *maxSupplyRow = nil;
        NSDictionary *minChargeRow = nil, *maxChargeRow = nil;
        double minSupply = DBL_MAX, maxSupply = -DBL_MAX;
        double minCharge = DBL_MAX, maxCharge = -DBL_MAX;
        for (NSDictionary *row in samples) {
            NSDate *t = row[@"t"];
            if (![t isKindOfClass:NSDate.class]) continue;
            if ([t compare:lo] == NSOrderedAscending) continue;
            if ([t compare:hi] != NSOrderedAscending && b + 1 < buckets) continue;
            if (b + 1 == buckets && [t compare:hi] == NSOrderedDescending) continue;
            NSNumber *supply = [row[@"supplyW"] isKindOfClass:NSNumber.class] ? row[@"supplyW"] : nil;
            if (supply) {
                double v = supply.doubleValue;
                if (v < minSupply) { minSupply = v; minSupplyRow = row; }
                if (v > maxSupply) { maxSupply = v; maxSupplyRow = row; }
            }
            NSNumber *charge = [row[@"chargeW"] isKindOfClass:NSNumber.class] ? row[@"chargeW"] : nil;
            if (charge) {
                double v = charge.doubleValue;
                if (v < minCharge) { minCharge = v; minChargeRow = row; }
                if (v > maxCharge) { maxCharge = v; maxChargeRow = row; }
            }
        }
        NSMutableArray<NSDictionary *> *selected = [NSMutableArray arrayWithCapacity:4];
        NSArray *candidates = @[minSupplyRow ?: NSNull.null,
                                maxSupplyRow ?: NSNull.null,
                                minChargeRow ?: NSNull.null,
                                maxChargeRow ?: NSNull.null];
        for (id candidate in candidates) {
            if (candidate == NSNull.null || [selected containsObject:candidate]) continue;
            [selected addObject:(NSDictionary *)candidate];
        }
        [selected sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *bRow) {
            return [a[@"t"] compare:bRow[@"t"]];
        }];
        [out addObjectsFromArray:selected];
    }
    return out;
}

EBChartSeriesAverages EBStoreChartSeriesAverages(NSArray<NSDictionary *> *samples) {
    EBChartSeriesAverages result = (EBChartSeriesAverages){0};
    double solarChargeTotal = 0;
    double gridChargeTotal = 0;
    double surplusTotal = 0;
    double importTotal = 0;
    double pvTotal = 0;
    for (NSDictionary *row in samples) {
        NSNumber *pvValue = [row[@"pvW"] isKindOfClass:NSNumber.class] ? row[@"pvW"] : nil;
        if (pvValue) {
            pvTotal += fmax(0, pvValue.doubleValue);
            result.pvSampleCount++;
        }
        NSNumber *supplyValue = [row[@"supplyW"] isKindOfClass:NSNumber.class] ? row[@"supplyW"] : nil;
        if (!supplyValue) continue;

        double supply = supplyValue.doubleValue;
        if (supply < 0) surplusTotal += -supply;
        else importTotal += supply;
        result.supplySampleCount++;

        NSNumber *chargeValue = [row[@"chargeW"] isKindOfClass:NSNumber.class] ? row[@"chargeW"] : nil;
        if (!chargeValue) continue;
        double charge = fmax(0, chargeValue.doubleValue);
        double fromGrid = fmin(charge, fmax(0, supply));
        gridChargeTotal += fromGrid;
        solarChargeTotal += charge - fromGrid;
        result.chargeSampleCount++;
    }
    if (result.chargeSampleCount > 0) {
        result.carSolarW = solarChargeTotal / result.chargeSampleCount;
        result.carGridW = gridChargeTotal / result.chargeSampleCount;
    }
    if (result.supplySampleCount > 0) {
        result.unusedSurplusW = surplusTotal / result.supplySampleCount;
        result.importW = importTotal / result.supplySampleCount;
        result.homeGridW = fmax(0, result.importW - result.carGridW);
    }
    if (result.pvSampleCount > 0) {
        result.solarW = pvTotal / result.pvSampleCount;
        if (result.supplySampleCount > 0)
            result.homeSolarW = fmax(0, result.solarW - result.unusedSurplusW - result.carSolarW);
    }
    return result;
}

EBGridEnergy EBGridEnergyForInterval(double firstW, double lastW, NSTimeInterval seconds) {
    EBGridEnergy result = {0};
    if (!isfinite(firstW) || !isfinite(lastW) || !isfinite(seconds) || seconds <= 0) return result;
    double hours = seconds / 3600.0;
    if (firstW >= 0 && lastW >= 0) result.importWh = (firstW / 2 + lastW / 2) * hours;
    else if (firstW <= 0 && lastW <= 0) result.exportWh = -(firstW / 2 + lastW / 2) * hours;
    else {
        double fraction = fabs(firstW) / (fabs(firstW) + fabs(lastW));
        double firstWh = fabs(firstW) * fraction * hours / 2;
        double lastWh = fabs(lastW) * (1 - fraction) * hours / 2;
        result.importWh = firstW > 0 ? firstWh : lastWh;
        result.exportWh = firstW < 0 ? firstWh : lastWh;
    }
    return result;
}

EBDayTotals EBStoreIntegrateSince(NSArray<NSDictionary *> *samples, NSDate *since, NSDate *now) {
    EBDayTotals r = (EBDayTotals){0};
    if (!since) return r;
    NSDate *end = now ?: [NSDate date];
    r.span = [end timeIntervalSinceDate:since];
    if (r.span < 0) r.span = 0;
    if (samples.count < 2) return r;

    NSMutableArray *day = [NSMutableArray array];
    for (NSDictionary *row in samples) {
        NSDate *t = row[@"t"];
        if (![t isKindOfClass:NSDate.class]) continue;
        if ([row[@"statusOnly"] isEqual:@YES]) continue;
        if ([t compare:since] == NSOrderedAscending) continue;
        if ([t compare:end] == NSOrderedDescending) continue;
        [day addObject:row];
    }
    if (day.count < 2) return r;

    for (NSUInteger i = 1; i < day.count; i++) {
        NSDictionary *a = day[i - 1], *b = day[i];
        NSTimeInterval dt = [b[@"t"] timeIntervalSinceDate:a[@"t"]];
        if (dt <= 0 || dt > EBStoreIntegrationGapSeconds) continue;
        double hours = dt / 3600.0;

        if (a[@"pvW"] && b[@"pvW"]) {
            r.pvWh += 0.5 * ([a[@"pvW"] doubleValue] + [b[@"pvW"] doubleValue]) * hours;
            r.pvCoverage += dt;
        }
        if (a[@"supplyW"] && b[@"supplyW"]) {
            EBGridEnergy energy = EBGridEnergyForInterval([a[@"supplyW"] doubleValue],
                                                          [b[@"supplyW"] doubleValue], dt);
            r.importWh += energy.importWh;
            r.exportWh += energy.exportWh;
            r.gridCoverage += dt;
        }
        if (a[@"chargeW"] && b[@"chargeW"]) {
            r.chargeWh += 0.5 * ([a[@"chargeW"] doubleValue] + [b[@"chargeW"] doubleValue]) * hours;
            r.chargeCoverage += dt;
            if (a[@"supplyW"] && b[@"supplyW"]) {
                double gridA = fmin([a[@"chargeW"] doubleValue], fmax(0, [a[@"supplyW"] doubleValue]));
                double gridB = fmin([b[@"chargeW"] doubleValue], fmax(0, [b[@"supplyW"] doubleValue]));
                r.chargeGridWh += 0.5 * (fmax(0, gridA) + fmax(0, gridB)) * hours;
            }
        }
    }
    return r;
}
