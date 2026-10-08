// Energybar — menu bar energy glance (icon + popover telemetry).
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>
#import <os/log.h>
#import <unistd.h>
#import "config.h"
#import "fixture.h"
#import "pure.h"
#import "parse.h"
#import "store.h"
#import "sessions.h"
#import "fronius_archive.h"
#import "chart.h"
#import "tiles.h"
#import "popover.h"
#import "vehicle.h"

static NSString * const EBVersion = @"0.5.1";
static NSString * const EBCognitoClientId = @"rol3lsv2vg41783550i18r7vi";
static NSString * const EBCognitoURL = @"https://cognito-idp.ap-southeast-2.amazonaws.com/";
static NSString * const EBEvnexBase = @"https://client-api.evnex.io";
static const NSTimeInterval EBStoreMaxAge = 48.0 * 3600.0;
static const NSTimeInterval EBFroniusPollInterval = 5.0;
static const NSTimeInterval EBEvnexBasePollInterval = 30.0;
static const NSTimeInterval EBEvnexIdlePollInterval = 120.0;
static const NSTimeInterval EBSessionRefreshInterval = 5.0 * 60.0;
static const NSTimeInterval EBFroniusArchiveRefreshInterval = 30.0 * 60.0;

#pragma mark - HTTP

@interface EBHTTPResponse : NSObject
@property NSInteger status;
@property(copy, nullable) NSData *data;
@property(copy, nullable) NSError *error;
@property(readonly) BOOL successful;
@end

@implementation EBHTTPResponse
- (BOOL)successful { return !self.error && self.status >= 200 && self.status < 300; }
@end

static NSError *EBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Energybar" code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static EBHTTPResponse *EBHTTP(NSString *method, NSString *url, NSDictionary *headers, NSData *body) {
    NSURL *endpoint = [NSURL URLWithString:url];
    if (!endpoint || !endpoint.scheme.length || !endpoint.host.length) {
        EBHTTPResponse *response = [EBHTTPResponse new];
        response.error = EBError(3, [NSString stringWithFormat:@"Invalid URL: %@", url ?: @"(null)"]);
        return response;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:endpoint];
    req.HTTPMethod = method;
    req.timeoutInterval = 15;
    for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
    req.HTTPBody = body;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSInteger status = 0;
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
                                   completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)r;
        if ([hr isKindOfClass:NSHTTPURLResponse.class]) status = hr.statusCode;
        responseData = d;
        responseError = e;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    EBHTTPResponse *response = [EBHTTPResponse new];
    if (waited != 0) {
        [task cancel];
        response.error = EBError(4, @"Request timed out");
    } else {
        response.status = status;
        response.data = responseData;
        response.error = responseError;
    }
    return response;
}

static NSString *EBURLPathSegment(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static dispatch_queue_t EBStoreQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("energybar.store", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static dispatch_queue_t EBRefreshQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("energybar.refresh", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_queue_t EBFroniusArchiveQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("energybar.fronius-archive", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// Serializes polls and commands so charger mutations cannot race each other or
/// be reordered around a status refresh.
static dispatch_queue_t EBEvnexQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("energybar.evnex", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDictionary *EBJSONDictionary(NSData *data) {
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
}

static NSString *EBJSONDateString(NSDate *date) {
    if (!date) return nil;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date];
}

static NSString *EBStableSourceID(NSString *kind, NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return [NSString stringWithFormat:@"%@-sha256-%@", kind, hex];
}

static NSArray<NSDictionary *> *EBSessionInferenceRecords(EBSessionHistory *history) {
    if (!history) return @[];
    if (history.complete) return history.sessions ?: @[];
    // An incomplete list cannot prove energy or cable continuity, but an
    // individually confirmed EVDisconnected event remains valid safety evidence.
    NSMutableArray<NSDictionary *> *disconnects = [NSMutableArray array];
    for (NSDictionary *record in history.sessions) {
        NSDate *at = record[EBSessionDisconnectedAtKey];
        NSString *identifier = record[EBSessionIDKey];
        if ([at isKindOfClass:NSDate.class] && [identifier isKindOfClass:NSString.class])
            [disconnects addObject:@{ EBSessionIDKey: identifier,
                                      EBSessionDisconnectedAtKey: at }];
    }
    return disconnects;
}

static BOOL EBRefreshAccessToken(EBConfig *c, BOOL force, NSError **err) {
    if (!force && c.accessToken.length && c.expiresAt && [c.expiresAt timeIntervalSinceNow] > 120)
        return YES;
    if (!c.refreshToken.length) {
        if (err) *err = [NSError errorWithDomain:@"Energybar" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"No Evnex refresh token — run: uvx evnex==0.7.0 auth login"}];
        return NO;
    }
    NSDictionary *payload = @{
        @"AuthFlow": @"REFRESH_TOKEN_AUTH",
        @"ClientId": EBCognitoClientId,
        @"AuthParameters": @{@"REFRESH_TOKEN": c.refreshToken},
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSDictionary *headers = @{
        @"Content-Type": @"application/x-amz-json-1.1",
        @"X-Amz-Target": @"AWSCognitoIdentityProviderService.InitiateAuth",
    };
    EBHTTPResponse *response = EBHTTP(@"POST", EBCognitoURL, headers, body);
    if (!response.successful) {
        if (err) *err = response.error ?: EBError(2, [NSString stringWithFormat:
            @"Evnex token refresh failed (HTTP %ld)", (long)response.status]);
        return NO;
    }
    NSDictionary *json = EBJSONDictionary(response.data);
    if (!json) {
        if (err) *err = EBError(5, @"Evnex token refresh returned invalid JSON");
        return NO;
    }
    return EBConfigSaveTokens(c, json, err);
}

static EBHTTPResponse *EBEvnexHTTP(EBConfig *c, NSString *method, NSString *url, NSData *body) {
    NSError *authError = nil;
    if (!EBRefreshAccessToken(c, NO, &authError)) {
        EBHTTPResponse *failed = [EBHTTPResponse new];
        failed.error = authError;
        return failed;
    }
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSDictionary *headers = @{
            @"Accept": @"application/json",
            @"Content-Type": @"application/json",
            @"Authorization": c.accessToken,
            @"User-Agent": [NSString stringWithFormat:@"energybar/%@", EBVersion],
        };
        EBHTTPResponse *response = EBHTTP(method, url, headers, body);
        if (response.status != 401 || attempt == 1) return response;
        c.accessToken = @"";
        c.expiresAt = nil;
        if (!EBRefreshAccessToken(c, YES, &authError)) {
            response.error = authError;
            return response;
        }
    }
    NSCAssert(NO, @"unreachable");
    return [EBHTTPResponse new];
}

/// A poll serializes each individual Evnex request, not the whole multi-source
/// refresh. A user command queued between status/detail requests therefore runs
/// before the next poll request and never waits behind Fronius I/O or sleeps.
static EBHTTPResponse *EBEvnexPollHTTP(EBConfig *c, NSString *method,
                                       NSString *url, NSData *body) {
    __block EBHTTPResponse *response = nil;
    dispatch_sync(EBEvnexQueue(), ^{
        response = EBEvnexHTTP(c, method, url, body);
    });
    return response;
}

#pragma mark - Snapshot

@interface EBSnapshot : NSObject
@property BOOL pvOK; @property double pvW; @property BOOL eDayOK; @property double eDayWh;
@property BOOL gridOK; @property double supplyW; @property double chargeW;
@property BOOL chargerOK;
@property BOOL evnexAttempted;
@property BOOL evnexRateLimited;
@property BOOL meterAttempted;
@property BOOL meterSampleOK;
@property double meterSampleSupplyW;
@property double meterSampleChargeW;
@property BOOL haveOcpp;
@property BOOL gridStale;
@property(copy) NSDate *gridAsOf;
@property(copy) NSString *ocppStatus;
@property(copy) NSString *chargingLogic;
@property(copy) NSString *chargingCurrentControl;
@property BOOL chargeNow;
@property BOOL chargeNowKnown;
@property(copy) NSString *scheduleBehaviour;
@property(copy) NSString *pvError;
@property(copy) NSString *evnexError;
@property(copy) NSString *storageError;
@property(copy) NSString *recoveryError;
@property(copy) NSString *vehicleError;
@property(copy) NSDate *pvAt;
@property(copy) NSDate *evnexAt;
@property(copy) NSDictionary *rawFronius;
@property(copy) NSDictionary *rawStatus;
@property(copy) NSDictionary *rawDetail;
@property EBSessionHistory *sessionHistory;
@property(copy) NSString *sessionError;
@property(copy) NSString *sessionStorageError;
@property BOOL sessionStoreAttempted;
@property BOOL sessionStoreOK;
@end
@implementation EBSnapshot
- (EBSnapshotView *)viewModel {
    EBSnapshotView *v = [EBSnapshotView new];
    v.pvOK = self.pvOK; v.pvW = self.pvW; v.eDayWh = self.eDayWh;
    v.gridOK = self.gridOK; v.gridStale = self.gridStale; v.gridAsOf = self.gridAsOf;
    v.supplyW = self.supplyW; v.chargeW = self.chargeW;
    v.chargerOK = self.chargerOK; v.haveOcpp = self.haveOcpp;
    v.ocppStatus = self.ocppStatus; v.chargingLogic = self.chargingLogic;
    v.chargingCurrentControl = self.chargingCurrentControl; v.chargeNow = self.chargeNow;
    v.pvError = self.pvError; v.evnexError = self.evnexError;
    v.storageError = self.storageError;
    v.vehicleError = self.vehicleError;
    v.pvAt = self.pvAt; v.evnexAt = self.evnexAt;
    if (self.sessionHistory.fetchedAt) {
        NSDate *now = [NSDate date];
        NSDate *day = EBStartOfLocalDay(now);
        NSDate *through = [self.sessionHistory.fetchedAt compare:now] == NSOrderedDescending
            ? now : self.sessionHistory.fetchedAt;
        EBSessionEnergySummary summary = EBSessionEnergyInWindow(
            self.sessionHistory.sessions, day, through);
        v.carDayAvailable = self.sessionHistory.complete &&
            [through compare:day] != NSOrderedAscending && summary.exact;
        v.carDayWh = summary.energyWh;
        v.carDaySessionCount = summary.sessionCount;
        v.carDayAsOf = through;
        v.carDayStale = !self.sessionHistory.current ||
            [now timeIntervalSinceDate:through] > 10 * 60;
    }
    v.sessionError = self.sessionError;
    return v;
}
@end

static const NSTimeInterval EBDetailTTL = 5 * 60.0;
static const NSTimeInterval EBDetailMeterMaxAge = 7 * 60.0;
static NSDictionary *gCachedDetail = nil;
static NSDate *gDetailNextAttemptAt = nil;
static BOOL gDetailCurrent = NO;
static NSString *gDetailLastError = nil;
static EBSessionHistory *gSessionHistory = nil;
static NSDate *gSessionNextAttemptAt = nil;
static NSString *gSessionCachePath = nil;
static NSString *gSessionLastError = nil;

@interface EBDetailResult : NSObject
@property(copy) NSDictionary *document;
@property BOOL fetchedNow;
@property BOOL attempted;
@property BOOL current;
@property(copy) NSString *errorMessage;
@end
@implementation EBDetailResult @end

@interface EBSessionResult : NSObject
@property EBSessionHistory *history;
@property BOOL attempted;
@property BOOL rateLimited;
@property BOOL storeAttempted;
@property BOOL storeOK;
@property(copy) NSString *errorMessage;
@property(copy) NSString *storageErrorMessage;
@end
@implementation EBSessionResult @end

static EBSessionResult *EBFetchSessions(EBConfig *config, NSString *encodedChargePointID,
                                        BOOL allowNetwork) {
    EBSessionResult *result = [EBSessionResult new];
    if (!gSessionHistory || ![gSessionCachePath isEqualToString:config.sessionsPath]) {
        NSError *cacheError = nil;
        gSessionHistory = EBSessionCacheLoad(config.sessionsPath, config.chargePointId,
                                             EBStoreMaxAge, &cacheError);
        gSessionCachePath = [config.sessionsPath copy];
        gSessionNextAttemptAt = nil;
        gSessionLastError = nil;
        if (cacheError) result.storageErrorMessage = cacheError.localizedDescription;
    }
    result.history = gSessionHistory ?: [EBSessionHistory new];
    result.errorMessage = gSessionLastError;
    if (!allowNetwork) return result;
    NSDate *now = [NSDate date];
    BOOL due = !gSessionNextAttemptAt ||
               [gSessionNextAttemptAt compare:now] != NSOrderedDescending;
    if (!due) return result;

    result.attempted = YES;
    __block EBHTTPResponse *response = nil;
    dispatch_sync(EBEvnexQueue(), ^{
        response = EBEvnexHTTP(config, @"GET",
            [NSString stringWithFormat:@"%@/charge-points/%@/sessions",
             EBEvnexBase, encodedChargePointID], nil);
    });
    gSessionNextAttemptAt = [now dateByAddingTimeInterval:EBSessionRefreshInterval];
    NSDictionary *document = response.successful ? EBJSONDictionary(response.data) : nil;
    NSArray *data = [document[@"data"] isKindOfClass:NSArray.class] ? document[@"data"] : nil;
    if (!data) {
        result.rateLimited = response.status == 429;
        result.errorMessage = response.error.localizedDescription ?:
            [NSString stringWithFormat:@"Session history unavailable (HTTP %ld)",
             (long)response.status];
        gSessionHistory.current = NO;
        gSessionLastError = result.errorMessage;
        return result;
    }

    EBSessionHistory *fresh = [EBSessionHistory new];
    fresh.fetchedAt = now;
    fresh.sourceID = config.chargePointId;
    fresh.current = YES;
    BOOL complete = NO;
    fresh.sessions = EBParseEvnexSessions(document, now, EBStoreMaxAge, &complete);
    fresh.complete = complete;
    gSessionLastError = nil;
    result.errorMessage = nil;
    NSError *saveError = nil;
    result.storeAttempted = YES;
    result.storeOK = EBSessionCacheSave(config.sessionsPath, fresh, &saveError);
    if (result.storeOK)
        result.storageErrorMessage = nil;
    else
        result.storageErrorMessage = [NSString stringWithFormat:
            @"Session history not saved — %@", saveError.localizedDescription ?: @"cache unavailable"];
    gSessionHistory = fresh;
    result.history = fresh;
    return result;
}

static EBDetailResult *EBFetchDetail(EBConfig *c, NSString *encodedChargePointID) {
    EBDetailResult *result = [EBDetailResult new];
    dispatch_sync(EBEvnexQueue(), ^{
        NSDate *now = [NSDate date];
        result.document = gCachedDetail;
        result.current = gDetailCurrent;
        result.errorMessage = gDetailLastError;
        BOOL due = !gDetailNextAttemptAt ||
                   [gDetailNextAttemptAt compare:now] != NSOrderedDescending;
        if (!due) return;
        result.attempted = YES;
        EBHTTPResponse *response = EBEvnexHTTP(c, @"GET",
            [NSString stringWithFormat:@"%@/charge-points/%@",
             EBEvnexBase, encodedChargePointID], nil);
        NSDictionary *fresh = response.successful ? EBJSONDictionary(response.data) : nil;
        // Detail supplies the live meter reading. A failed request keeps its
        // own retry horizon instead of being retried by every five-second PV tick.
        gDetailNextAttemptAt = [now dateByAddingTimeInterval:EBDetailTTL];
        if (fresh) {
            gCachedDetail = fresh;
            gDetailCurrent = EBDetailCurrentState(gDetailCurrent, YES, YES);
            gDetailLastError = nil;
            result.document = fresh;
            result.fetchedNow = YES;
            result.current = YES;
            result.errorMessage = nil;
            NSDate *meterAt = nil;
            if (EBParseEvnexDetailMeter(fresh, now, EBDetailMeterMaxAge,
                                         nil, nil, &meterAt)) {
                NSTimeInterval age = [now timeIntervalSinceDate:meterAt];
                gDetailNextAttemptAt = [now dateByAddingTimeInterval:
                    EBNextDetailPollInterval(age)];
            }
        } else {
            gDetailCurrent = EBDetailCurrentState(gDetailCurrent, YES, NO);
            gDetailLastError = response.error.localizedDescription ?:
                [NSString stringWithFormat:@"Detail unavailable (HTTP %ld)",
                 (long)response.status];
            result.current = NO;
            result.errorMessage = gDetailLastError;
        }
    });
    return result;
}

static EBSnapshot *EBFetch(EBConfig *c, BOOL includeEvnex) {
    EBSnapshot *s = [EBSnapshot new];

    if (c.froniusAPI.length) {
        NSString *url = [c.froniusAPI stringByAppendingString:@"/v1/GetPowerFlowRealtimeData.fcgi"];
        EBHTTPResponse *response = EBHTTP(@"GET", url, @{@"Accept": @"application/json"}, nil);
        NSDictionary *j = response.successful ? EBJSONDictionary(response.data) : nil;
        s.rawFronius = j;
        double pv = 0, day = 0;
        BOOL haveDay = NO;
        if (EBParseFroniusPowerFlowFields(j, &pv, &day, &haveDay)) {
            s.pvOK = YES;
            s.pvW = pv;
            s.eDayOK = haveDay;
            s.eDayWh = day;
            s.pvAt = [NSDate date];
        } else {
            s.pvError = response.error.localizedDescription ?:
                (response.status ? [NSString stringWithFormat:@"Fronius unavailable (HTTP %ld)",
                                     (long)response.status] : @"Fronius unreachable");
        }
    } else {
        s.pvError = @"FRONIUS_SOLAR_API not set";
    }

    if (!includeEvnex) return s;
    s.evnexAttempted = YES;
    if (!c.chargePointId.length) {
        s.evnexError = @"EVNEX_CHARGE_POINT_ID not set";
        return s;
    }
    NSString *cp = EBURLPathSegment(c.chargePointId);
    NSData *empty = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    EBHTTPResponse *statusResponse = EBEvnexPollHTTP(c, @"POST",
        [NSString stringWithFormat:@"%@/charge-points/%@/commands/get-status", EBEvnexBase, cp],
        empty);
    // get-status is relayed to the charger, which times out around its own 5-minute meter
    // upload (logged 2026-10-07: HTTP 0, timed out, only on meter polls). One retry clears it.
    if (statusResponse.status == 0 && statusResponse.error.code == NSURLErrorTimedOut) {
        os_log(OS_LOG_DEFAULT, "Energybar: get-status timed out; retrying once");
        usleep(2000000);
        statusResponse = EBEvnexPollHTTP(c, @"POST",
            [NSString stringWithFormat:@"%@/charge-points/%@/commands/get-status", EBEvnexBase, cp],
            empty);
    }
    NSDate *statusAt = [NSDate date];
    NSDictionary *stJ = statusResponse.successful ? EBJSONDictionary(statusResponse.data) : nil;
    s.evnexRateLimited = statusResponse.status == 429;
    if (!stJ) {
        NSString *body = [[NSString alloc] initWithData:statusResponse.data ?: NSData.data
                                               encoding:NSUTF8StringEncoding] ?: @"";
        if (body.length > 160) body = [body substringToIndex:160];
        os_log(OS_LOG_DEFAULT, "Energybar: get-status failed HTTP %ld %{public}@ %{public}@",
               (long)statusResponse.status, statusResponse.error.localizedDescription ?: @"-", body);
    }

    EBDetailResult *detail = [EBDetailResult new];
    usleep(150000);
    detail = EBFetchDetail(c, cp);
    NSDictionary *detJ = detail.document;
    s.meterAttempted = detail.attempted;

    s.rawStatus = stJ;
    s.rawDetail = detJ;

    // Session and detail endpoints have independent quotas. A status failure
    // must not starve shutdown recovery from an otherwise healthy endpoint.
    EBSessionResult *sessions = EBFetchSessions(c, cp, YES);
    s.sessionHistory = sessions.history;
    s.sessionError = sessions.errorMessage;
    s.sessionStorageError = sessions.storageErrorMessage;
    s.sessionStoreAttempted = sessions.storeAttempted;
    s.sessionStoreOK = sessions.storeOK;

    EBEvnexParsed *e = [EBEvnexParsed new];
    EBParseEvnexBundle(stJ, nil, detJ, nil, e);
    NSDate *meterAt = nil;
    double detailSupplyW = 0, detailChargeW = 0;
    BOOL detailMeterOK = EBParseEvnexDetailMeter(
        detJ, [NSDate date], EBDetailMeterMaxAge,
        &detailSupplyW, &detailChargeW, &meterAt);
    s.meterSampleOK = detail.fetchedNow && detailMeterOK;
    if (detailMeterOK) {
        if (s.meterSampleOK) {
            // Preserve the detail document's own source-time values for history.
            // Fresher status reconciliation below is display/current-state only.
            s.meterSampleSupplyW = detailSupplyW;
            s.meterSampleChargeW = detailChargeW;
        }
        e.meterOK = YES;
        e.supplyW = detailSupplyW;
        e.chargeW = EBChargePowerForLiveStatus(
            detailChargeW, e.statusOK, e.chargingLogic,
            e.chargingCurrentControl, e.chargeNow);
        e.ok = YES;
    }
    if (!e.ok) {
        if (statusResponse.status == 429)
            s.evnexError = @"Evnex rate-limited (429) — backing off";
        else if (statusResponse.error || detail.errorMessage.length)
            s.evnexError = statusResponse.error.localizedDescription ?:
                           detail.errorMessage;
        else
            s.evnexError = [NSString stringWithFormat:
                @"Evnex status/detail failed (HTTP %ld)",
                (long)statusResponse.status];
        return s;
    }
    s.chargerOK = e.statusOK;
    // Cached detail remains useful for static schedule/org fields, but dynamic
    // OCPP state is exposed only from a detail response fetched in this poll.
    s.haveOcpp = detail.fetchedNow && e.haveOcppStatus;
    s.chargingLogic = e.chargingLogic;
    s.chargingCurrentControl = e.chargingCurrentControl;
    s.chargeNow = e.chargeNow;
    s.chargeNowKnown = e.haveChargeNow;
    s.ocppStatus = s.haveOcpp ? e.ocppStatus : nil;
    s.scheduleBehaviour = e.scheduleBehaviour;
    if (!c.orgId.length && e.orgId.length) c.orgId = e.orgId;
    s.evnexAt = statusAt;

    if (e.meterOK) {
        // A cached detail document remains a valid live view until its source
        // timestamp ages out. If a due refresh failed, show that same reading
        // as stale and persist the failed sampling opportunity as a gap.
        s.gridOK = detail.current;
        s.gridStale = !s.gridOK;
        s.supplyW = e.supplyW;
        s.chargeW = e.chargeW;
        s.gridAsOf = meterAt;
    } else {
        s.gridOK = NO;
        s.gridStale = NO;
    }
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    if (!e.statusOK) [errors addObject:statusResponse.error.localizedDescription ?:
        [NSString stringWithFormat:@"Status unavailable (HTTP %ld)", (long)statusResponse.status]];
    if (!e.meterOK)
        [errors addObject:detail.errorMessage ?: @"Meter unavailable in charge-point detail"];
    else if (detail.errorMessage.length)
        [errors addObject:detail.errorMessage];
    if (errors.count) s.evnexError = [errors componentsJoinedByString:@" · "];
    return s;
}

// The shared colour language (instrument-ux/menubar-apps.md): the tint says what the energy is
// doing, not that the app is healthy. Car blue, export green, waiting/stale amber, fault red;
// night and cloud keep the menu bar's own ink.
static NSColor *EBBarColor(EBBarState st, NSString *glyph) {
    switch (st) {
        case EBBarStateError: return NSColor.systemRedColor;
        case EBBarStateWarn: return NSColor.systemYellowColor;
        case EBBarStateOK: break;
    }
    if ([glyph isEqualToString:@"bolt.fill"]) return NSColor.systemBlueColor;
    if ([glyph isEqualToString:@"sun.max.fill"]) return NSColor.systemGreenColor;
    return nil;
}

@interface EBApp : NSObject <NSApplicationDelegate>
@property EBConfig *config;
@property EBSnapshot *snap;
@property NSStatusItem *item;
@property NSTimer *timer;
@property NSPopover *popover;
@property EBPopoverViews *views;
@property EBVehicleManualProvider *vehicleManual;
@property EBVehicleInferredProvider *vehicleInferred;
@property EBVehicleOBDProvider *vehicleOBD;
@property EBVehicleLiveProvider *vehicleLive;
@property id<EBVehicleProvider> vehicle;
@property double lastSupplyW;
@property double lastChargeW;
@property(copy) NSDate *lastMeterAt;
@property NSTimeInterval evnexPollInterval;
@property(copy) NSDate *evnexNextAttemptAt;
@property BOOL refreshInFlight;
@property BOOL refreshPending;
@property BOOL commandInFlight;
@property BOOL storageReady;
@property(copy) NSString *storageWarning;
@property(copy) NSString *vehicleStorageWarning;
@property(copy) NSString *sessionStorageWarning;
@property(copy) NSArray<NSDictionary *> *liveVehicleSamples;
@property(copy) NSArray<EBFroniusPVInterval *> *froniusArchive;
@property BOOL froniusArchiveInFlight;
@property BOOL froniusArchiveUnsupported;
@property(copy) NSDate *froniusArchiveNextAttemptAt;
@property(copy) NSString *froniusArchiveError;
@property(copy) NSString *froniusArchiveStorageWarning;
/// Live Fronius readings for the chart's newest bars, which the 30-minute archive
/// refresh has not reached yet. Memory only; the archive is the durable record.
@property(strong) NSMutableArray<NSDictionary *> *livePV;
@end

/// Chart solar rows: exact archive intervals as mean power (summed across inverters
/// that share an anchor), then live readings newer than the last archived anchor so
/// a bar never weighs both. The archive anchor may be an interval's start or end
/// (Fronius does not say); at 5-minute spans that is well inside a chart bar.
static NSArray<NSDictionary *> *EBChartPVRows(NSArray<EBFroniusPVInterval *> *archive,
                                             NSArray<NSDictionary *> *live) {
    NSMutableDictionary<NSDate *, NSNumber *> *byAnchor = [NSMutableDictionary dictionary];
    NSDate *last = nil;
    for (EBFroniusPVInterval *iv in archive) {
        if (iv.spanSeconds <= 0) continue;
        double w = iv.energyWh * 3600.0 / iv.spanSeconds;
        byAnchor[iv.anchor] = @(byAnchor[iv.anchor].doubleValue + w);
        if (!last || [iv.anchor compare:last] == NSOrderedDescending) last = iv.anchor;
    }
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:byAnchor.count + live.count];
    [byAnchor enumerateKeysAndObjectsUsingBlock:^(NSDate *t, NSNumber *w, BOOL *stop) {
        (void)stop;
        [rows addObject:@{@"t": t, @"pvW": w}];
    }];
    for (NSDictionary *row in live)
        if (!last || [row[@"t"] compare:last] == NSOrderedDescending) [rows addObject:row];
    return rows;
}

@implementation EBApp

- (NSString *)recoveryStorageWarning {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    if (self.sessionStorageWarning.length) [problems addObject:self.sessionStorageWarning];
    if (self.froniusArchiveStorageWarning.length)
        [problems addObject:self.froniusArchiveStorageWarning];
    return problems.count ? [problems componentsJoinedByString:@" · "] : nil;
}

- (void)rememberLiveVehicleSample:(NSDictionary *)sample {
    if (![sample[@"t"] isKindOfClass:NSDate.class]) return;
    self.liveVehicleSamples = EBStoreMergeSamples(
        @[], [self.liveVehicleSamples ?: @[] arrayByAddingObject:sample],
        [NSDate date], EBStoreMaxAge);
}

- (NSArray<NSDictionary *> *)vehicleSamplesIncludingLive:(NSArray<NSDictionary *> *)persisted {
    return EBStoreMergeSamples(persisted ?: @[], self.liveVehicleSamples ?: @[],
                               [NSDate date], EBStoreMaxAge);
}

- (void)startFroniusArchiveBackfillIfDue {
    if (self.froniusArchiveInFlight || self.froniusArchiveUnsupported ||
        !self.config.froniusAPI.length) return;
    NSDate *now = [NSDate date];
    if (self.froniusArchiveNextAttemptAt &&
        [self.froniusArchiveNextAttemptAt compare:now] == NSOrderedDescending) return;
    self.froniusArchiveInFlight = YES;
    self.froniusArchiveNextAttemptAt =
        [now dateByAddingTimeInterval:EBFroniusArchiveRefreshInterval];
    EBConfig *config = self.config;
    dispatch_async(EBFroniusArchiveQueue(), ^{
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:-2
                                            toDate:now options:0] ?: now;
        NSDateFormatter *dateFormatter = [NSDateFormatter new];
        dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dateFormatter.timeZone = NSTimeZone.localTimeZone;
        dateFormatter.dateFormat = @"dd.MM.yyyy";
        NSURLComponents *components = [NSURLComponents componentsWithString:
            [config.froniusAPI stringByAppendingString:@"/v1/GetArchiveData.cgi"]];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"Scope" value:@"System"],
            [NSURLQueryItem queryItemWithName:@"SeriesType" value:@"Detail"],
            [NSURLQueryItem queryItemWithName:@"HumanReadable" value:@"True"],
            [NSURLQueryItem queryItemWithName:@"StartDate"
                                        value:[dateFormatter stringFromDate:start]],
            [NSURLQueryItem queryItemWithName:@"EndDate"
                                        value:[dateFormatter stringFromDate:now]],
            [NSURLQueryItem queryItemWithName:@"Channel" value:@"TimeSpanInSec"],
            [NSURLQueryItem queryItemWithName:@"Channel"
                                        value:@"EnergyReal_WAC_Sum_Produced"],
        ];
        EBHTTPResponse *response = components.URL
            ? EBHTTP(@"GET", components.URL.absoluteString, @{ @"Accept": @"application/json" }, nil)
            : nil;
        NSDictionary *document = response.successful ? EBJSONDictionary(response.data) : nil;
        NSError *archiveError = nil;
        NSArray<EBFroniusPVInterval *> *incoming = document
            ? EBFroniusArchiveParsePVIntervals(document, &archiveError) : nil;
        if (!incoming && !archiveError) {
            archiveError = response.error ?: EBError(30,
                [NSString stringWithFormat:@"Fronius archive unavailable (HTTP %ld)",
                 (long)response.status]);
        }
        __block NSArray<EBFroniusPVInterval *> *merged = nil;
        __block NSError *mergeError = nil;
        if (incoming) {
            dispatch_sync(EBStoreQueue(), ^{
                merged = EBFroniusArchiveMergePVCache(
                    config.froniusArchivePath,
                    EBStableSourceID(@"fronius", config.froniusAPI), incoming,
                    [NSDate date], &mergeError);
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.froniusArchiveInFlight = NO;
            if (merged) {
                self.froniusArchive = merged;
                self.froniusArchiveError = nil;
                self.froniusArchiveStorageWarning = nil;
            } else if (mergeError) {
                self.froniusArchiveStorageWarning = [NSString stringWithFormat:
                    @"Solar archive not saved — %@", mergeError.localizedDescription];
            } else if (archiveError) {
                self.froniusArchiveError = archiveError.localizedDescription;
                if ([archiveError.domain isEqualToString:EBFroniusArchiveErrorDomain] &&
                    archiveError.code == EBFroniusArchiveErrorUnsupported)
                    self.froniusArchiveUnsupported = YES;
            }
            if (self.snap) self.snap.recoveryError = [self recoveryStorageWarning];
            if (self.popover.shown) [self updatePopoverBody];
            if (self.snap) [self applyBar:self.snap];
        });
    });
}

- (void)scheduleNextPoll {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:EBFroniusPollInterval
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    self.config = EBLoadConfig();
    self.storageReady = EBStoreSecureExistingFile(self.config.samplesPath);
    if (!self.storageReady)
        self.storageWarning = @"History unavailable — sample store permissions could not be secured";
    if (!EBSessionCacheSecureExistingFile(self.config.sessionsPath))
        self.sessionStorageWarning = @"Recovered session history unavailable — cache permissions could not be secured";
    NSError *archiveLoadError = nil;
    self.froniusArchive = self.config.froniusAPI.length
        ? (EBFroniusArchiveLoadPVCache(
            self.config.froniusArchivePath,
            EBStableSourceID(@"fronius", self.config.froniusAPI), [NSDate date],
            &archiveLoadError) ?: @[])
        : @[];
    if (archiveLoadError)
        self.froniusArchiveStorageWarning = [NSString stringWithFormat:
            @"Solar archive unavailable — %@", archiveLoadError.localizedDescription];
    NSString *vehicleManualPath = [EBHome()
        stringByAppendingPathComponent:@".config/energybar/vehicle.json"];
    NSString *vehicleStatePath = [EBHome()
        stringByAppendingPathComponent:@".cache/energybar/vehicle.json"];
    NSString *vehicleTokenPath = [EBHome()
        stringByAppendingPathComponent:@".cache/energybar/vehicle-token.json"];
    self.vehicleManual = [[EBVehicleManualProvider alloc] initWithPath:vehicleManualPath];
    self.vehicleInferred = [[EBVehicleInferredProvider alloc] initWithPath:vehicleStatePath
                                                            capacityWh:self.config.evBatteryWh
                                                            efficiency:self.config.evChargeEfficiency];
    // TODO(obd): enable when sidecar writes a fresh cache; seam stays unavailable until then.
    self.vehicleOBD = [[EBVehicleOBDProvider alloc] initWithCachePath:self.config.obdCachePath
                                                   maxAgeSeconds:self.config.obdMaxAgeSeconds];
    self.vehicleLive = [[EBVehicleLiveProvider alloc] initWithTokenPath:vehicleTokenPath];
    self.vehicle = EBResolveVehicle(@[self.vehicleOBD, self.vehicleLive, self.vehicleInferred, self.vehicleManual]);
    self.evnexPollInterval = EBEvnexBasePollInterval;
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:
                 self.config.barText ? NSVariableStatusItemLength : NSSquareStatusItemLength];
    self.item.button.imagePosition = NSImageLeft;
    self.item.button.target = self;
    self.item.button.action = @selector(togglePopover:);
    self.item.button.toolTip = @"Energybar";
    self.item.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    [self refresh];
}

- (void)applyBar:(EBSnapshot *)s {
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:[NSDate date]];
    EBBarState st = EBComputeBarState(s.pvOK, s.gridOK, s.chargerOK,
                                      s.ocppStatus, s.chargingLogic, s.chargingCurrentControl,
                                      s.chargeNow, s.supplyW);
    if (s.storageError.length || s.recoveryError.length || s.vehicleError.length)
        st = EBBarStateError;
    EBChargerState chargerState = EBComputeChargerState(s.ocppStatus, s.chargingLogic,
                                                         s.chargingCurrentControl, s.chargeNow,
                                                         s.haveOcpp);
    NSString *sym = EBBarGlyphNameForState(st, chargerState != EBChargerStateUnknown,
                                            s.pvOK, s.pvW, s.gridOK, s.supplyW,
                                            s.chargerOK, s.chargeW, hour);
    NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:@"Energybar"];
    img.template = YES;
    self.item.button.image = img;

    if (self.config.barText && s.pvOK && s.eDayWh > 0)
        self.item.button.title = [NSString stringWithFormat:@"%.1f kWh", s.eDayWh / 1000.0];
    else
        self.item.button.title = @"";

    self.item.button.contentTintColor = EBBarColor(st, sym);

    NSMutableString *tip = [NSMutableString stringWithFormat:@"Now: %@",
        EBGlanceString(s.pvOK, s.pvW, s.gridOK, s.supplyW,
                       s.chargerOK, s.ocppStatus, s.chargingLogic,
                       s.chargingCurrentControl, s.chargeNow)];
    if (s.pvOK && s.eDayWh > 0)
        [tip appendFormat:@"\nSolar energy today: %.1f kWh", s.eDayWh / 1000.0];
    if (s.storageError.length) [tip appendFormat:@"\n%@", s.storageError];
    if (s.recoveryError.length) [tip appendFormat:@"\n%@", s.recoveryError];
    if (s.vehicleError.length) [tip appendFormat:@"\n%@", s.vehicleError];
    self.item.button.toolTip = tip;
}

- (void)refresh {
    if (self.refreshInFlight) {
        self.refreshPending = YES;
        return;
    }
    self.refreshInFlight = YES;
    NSDate *startedAt = [NSDate date];
    BOOL includeEvnex = !self.evnexNextAttemptAt ||
                         [self.evnexNextAttemptAt compare:startedAt] != NSOrderedDescending;
    dispatch_async(EBRefreshQueue(), ^{
        EBSnapshot *s = EBFetch(self.config, includeEvnex);
        NSDate *sampleAt = [NSDate date];
        __block BOOL storeAttempted = NO;
        __block BOOL storeOK = YES;
        __block NSArray *vehicleSamples = nil;
        __block NSDictionary *liveVehicleSample = nil;
        if (includeEvnex) {
            dispatch_sync(EBStoreQueue(), ^{
                NSNumber *chargerState = s.chargerOK ? @(EBComputeChargerState(
                    s.ocppStatus, s.chargingLogic, s.chargingCurrentControl,
                    s.chargeNow, s.haveOcpp)) : @(EBChargerStateUnknown);
                if (EBShouldPersistPoll(s.meterAttempted)) {
                    storeAttempted = YES;
                    NSDate *historyAt = s.meterSampleOK && s.gridAsOf
                        ? s.gridAsOf : sampleAt;
                    NSNumber *gapState = s.meterSampleOK
                        ? nil : @(EBChargerStateUnknown);
                    storeOK = EBStoreAppend(self.config.samplesPath, historyAt,
                                            nil,
                                            s.meterSampleOK ? @(s.meterSampleSupplyW) : nil,
                                            s.meterSampleOK ? @(s.meterSampleChargeW) : nil,
                                            gapState, EBStoreMaxAge);
                    BOOL statusStored = EBStoreAppendStatus(
                        self.config.samplesPath, s.evnexAt ?: sampleAt,
                        chargerState, EBStoreMaxAge);
                    storeOK = storeOK && statusStored;
                }
                vehicleSamples = EBStoreLoad(self.config.samplesPath, EBStoreMaxAge);
                // Keep current status temporally separate from source-time power.
                liveVehicleSample = chargerState
                    ? @{@"t": s.evnexAt ?: sampleAt, @"st": chargerState,
                        @"statusOnly": @YES} : nil;
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (storeAttempted) {
                self.storageReady = storeOK;
                self.storageWarning = storeOK ? nil :
                    @"History unavailable — sample store is not writable";
            }
            if (s.sessionStoreAttempted)
                self.sessionStorageWarning = s.sessionStoreOK ? nil :
                    (s.sessionStorageError ?: @"Recovered session history is not writable");
            else if (s.sessionStorageError.length)
                self.sessionStorageWarning = s.sessionStorageError;
            s.storageError = self.storageWarning;
            s.recoveryError = [self recoveryStorageWarning];
            if (liveVehicleSample) [self rememberLiveVehicleSample:liveVehicleSample];
            if (vehicleSamples) [self resolveVehicleWithSamples:
                [self vehicleSamplesIncludingLive:vehicleSamples]
                                                     sessions:EBSessionInferenceRecords(s.sessionHistory)];
            s.vehicleError = self.vehicleStorageWarning;
            if (includeEvnex) {
                BOOL healthy = !EBShouldBackoffEvnex(s.chargerOK, s.evnexRateLimited);
                self.evnexPollInterval = EBNextPollInterval(self.evnexPollInterval, healthy);
                // Each status check is a command relayed to the charger. With nobody looking,
                // every 2 minutes is plenty for the bar; opening the popover checks at once.
                NSTimeInterval wait = self.evnexPollInterval;
                if (healthy && !self.popover.shown) wait = fmax(wait, EBEvnexIdlePollInterval);
                self.evnexNextAttemptAt = [NSDate dateWithTimeIntervalSinceNow:wait];
                if (s.gridOK) {
                    self.lastSupplyW = s.supplyW;
                    self.lastChargeW = s.chargeW;
                    self.lastMeterAt = s.gridAsOf;
                } else if (EBShouldUseLastMeterFallback(s.gridAsOf != nil,
                                                        self.lastMeterAt != nil)) {
                    s.supplyW = self.lastSupplyW;
                    s.chargeW = EBChargePowerForLiveStatus(
                        self.lastChargeW, s.chargerOK, s.chargingLogic,
                        s.chargingCurrentControl, s.chargeNow);
                    s.gridAsOf = self.lastMeterAt;
                    s.gridStale = YES;
                }
                EBChargerState now = s.chargerOK ? EBComputeChargerState(s.ocppStatus, s.chargingLogic,
                    s.chargingCurrentControl, s.chargeNow, s.haveOcpp) : EBChargerStateUnknown;
                if (now == EBChargerStateUnknown) {
                    NSLog(@"Energybar: charger state unknown (statusOK %d, ocpp %@, logic %@, control %@, error %@)",
                          s.chargerOK, s.ocppStatus, s.chargingLogic, s.chargingCurrentControl, s.evnexError);
                    // One missed or unreadable status is not news: hold the last known state for
                    // one poll (150 s) instead of flashing "?" in the bar. History still records the miss.
                    EBSnapshot *p = self.snap;
                    EBChargerState before = p.chargerOK ? EBComputeChargerState(p.ocppStatus, p.chargingLogic,
                        p.chargingCurrentControl, p.chargeNow, p.haveOcpp) : EBChargerStateUnknown;
                    if (before != EBChargerStateUnknown && p.evnexAt &&
                        [startedAt timeIntervalSinceDate:p.evnexAt] < EBEvnexIdlePollInterval + 30) {
                        s.chargerOK = YES;
                        s.haveOcpp = p.haveOcpp; s.ocppStatus = p.ocppStatus;
                        s.chargingLogic = p.chargingLogic;
                        s.chargingCurrentControl = p.chargingCurrentControl;
                        s.chargeNow = p.chargeNow; s.chargeNowKnown = p.chargeNowKnown;
                        s.evnexAt = p.evnexAt;
                    }
                }
            } else if (self.snap) {
                // Evnex is deliberately not due yet. Preserve the last sampled
                // status for display. This Fronius-only refresh is not appended
                // to shared history because it was not a meter sampling attempt.
                s.gridOK = self.snap.gridOK;
                s.gridStale = self.snap.gridStale;
                s.supplyW = self.snap.supplyW;
                s.chargeW = self.snap.chargeW;
                s.gridAsOf = self.snap.gridAsOf;
                s.chargerOK = self.snap.chargerOK;
                s.haveOcpp = self.snap.haveOcpp;
                s.ocppStatus = self.snap.ocppStatus;
                s.chargingLogic = self.snap.chargingLogic;
                s.chargingCurrentControl = self.snap.chargingCurrentControl;
                s.chargeNow = self.snap.chargeNow;
                s.chargeNowKnown = self.snap.chargeNowKnown;
                s.scheduleBehaviour = self.snap.scheduleBehaviour;
                s.evnexAt = self.snap.evnexAt;
                s.evnexError = self.snap.evnexError;
                s.evnexRateLimited = self.snap.evnexRateLimited;
                s.sessionHistory = self.snap.sessionHistory;
                s.sessionError = self.snap.sessionError;
            }
            self.snap = s;
            if (s.pvOK) {
                if (!self.livePV) self.livePV = [NSMutableArray array];
                NSDate *at = s.pvAt ?: [NSDate date];
                [self.livePV addObject:@{@"t": at, @"pvW": @(s.pvW)}];
                NSDate *cutoff = [at dateByAddingTimeInterval:-3 * 3600];
                while (self.livePV.count && [self.livePV[0][@"t"] compare:cutoff] == NSOrderedAscending)
                    [self.livePV removeObjectAtIndex:0];
            }
            [self startFroniusArchiveBackfillIfDue];
            [self applyBar:s];
            if (self.popover.shown) [self updatePopoverBody];
            self.refreshInFlight = NO;
            if (self.refreshPending) {
                self.refreshPending = NO;
                [self refresh];
            } else {
                [self scheduleNextPoll];
            }
        });
    });
}

- (void)resolveVehicleWithSamples:(NSArray *)samples sessions:(NSArray *)sessions {
    BOOL inferredSaved = [self.vehicleInferred updateWithSamples:samples
                                                      sessions:sessions
                                                           now:[NSDate date]];
    // TODO(obd): refresh OBD cache read here; poll sidecar only while charger plugged.
    self.vehicle = EBResolveVehicle(@[self.vehicleOBD, self.vehicleLive, self.vehicleInferred, self.vehicleManual]);
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    if (self.vehicleManual.persistenceError)
        [problems addObject:self.vehicleManual.persistenceError.localizedDescription];
    if (self.vehicleInferred.persistenceError)
        [problems addObject:self.vehicleInferred.persistenceError.localizedDescription];
    if (!inferredSaved && !problems.count)
        [problems addObject:@"Vehicle state could not be persisted"];
    self.vehicleStorageWarning = problems.count
        ? [NSString stringWithFormat:@"Vehicle state not saved — %@",
           [problems componentsJoinedByString:@" · "]]
        : nil;
}

- (void)updatePopoverBody {
    if (!self.views || !self.snap) return;
    NSArray *samples = EBStoreLoad(self.config.samplesPath, EBStoreMaxAge);
    [self resolveVehicleWithSamples:[self vehicleSamplesIncludingLive:samples]
                         sessions:EBSessionInferenceRecords(self.snap.sessionHistory)];
    self.snap.vehicleError = self.vehicleStorageWarning;
    EBSnapshotView *vm = [self.snap viewModel];
    NSDate *now = [NSDate date];
    vm.referenceDate = now;
    NSError *tariffError = nil;
    self.config.tariff = EBTariffLoad(self.config.tariffPath, &tariffError);
    self.config.tariffError = tariffError.localizedDescription;
    vm.tariff = self.config.tariff;
    vm.tariffError = self.config.tariffError;
    NSCalendar *billingCalendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    billingCalendar.timeZone = vm.tariff.timeZone ?: NSTimeZone.localTimeZone;
    NSDate *day = [billingCalendar startOfDayForDate:now];
    vm.today = EBStoreIntegrateSince(samples, day, now);
    vm.gridCostToday = EBTariffIntegrate(samples, day, now, vm.tariff);
    EBFroniusPVArchiveSummary archiveDay = EBFroniusArchiveSummarizePV(
        self.froniusArchive ?: @[], day, now);
    vm.pvArchiveAvailable = archiveDay.hasData;
    vm.pvArchiveWh = archiveDay.energyWh;
    vm.pvArchiveIntervalCount = archiveDay.intervalCount;
    NSMutableArray<NSString *> *archiveProblems = [NSMutableArray array];
    if (self.froniusArchiveError.length) [archiveProblems addObject:self.froniusArchiveError];
    if (self.froniusArchiveStorageWarning.length)
        [archiveProblems addObject:self.froniusArchiveStorageWarning];
    vm.pvArchiveError = archiveProblems.count
        ? [archiveProblems componentsJoinedByString:@" · "] : nil;
    NSMutableArray<NSString *> *sessionProblems = [NSMutableArray array];
    if (vm.sessionError.length) [sessionProblems addObject:vm.sessionError];
    if (self.sessionStorageWarning.length)
        [sessionProblems addObject:self.sessionStorageWarning];
    vm.sessionError = sessionProblems.count
        ? [sessionProblems componentsJoinedByString:@" · "] : nil;
    vm.orgId = self.config.orgId;
    vm.vehicleLine = self.vehicle.statusLine;
    vm.vehicleHasSOC = self.vehicle.hasSOC;
    vm.vehicleSOC = self.vehicle.socPercent;
    vm.vehicleHasReady = self.vehicle.hasReady;
    vm.vehicleReady = self.vehicle.readyToCharge;
    vm.vehicleSOCIsEstimate = self.vehicle.socIsEstimate;
    vm.vehicleCapacityWh = self.config.evBatteryWh;
    vm.vehicleChargeEfficiency = self.config.evChargeEfficiency;
    vm.inverterW = self.config.inverterW;
    vm.vehicleHasStoredState = self.vehicle.hasSOC || self.vehicle.hasReady
        || self.vehicle.socInvalidatedAt != nil;
    NSArray *chartRows = [samples arrayByAddingObjectsFromArray:
        EBChartPVRows(self.froniusArchive ?: @[], self.livePV ?: @[])];
    EBApplySnapshot(self.views, vm, chartRows);
    if (self.popover) self.popover.contentSize = self.views.root.frame.size;
    if (self.commandInFlight) [self setCommandControlsEnabled:NO];
}

- (void)togglePopover:(id)sender {
    (void)sender;
    if (!self.views) {
        self.views = EBBuildPopover(self);
        NSViewController *vc = [NSViewController new];
        vc.view = self.views.root;
        self.popover = [NSPopover new];
        self.popover.behavior = NSPopoverBehaviorTransient;
        self.popover.contentViewController = vc;
    }
    [self updatePopoverBody];
    if (self.popover.shown) [self.popover performClose:nil];
    else {
        [self.popover showRelativeToRect:self.item.button.bounds ofView:self.item.button preferredEdge:NSRectEdgeMinY];
        // Closed, status is checked every 2 minutes; bring it up to date on open.
        if (self.evnexPollInterval <= EBEvnexBasePollInterval &&
            (!self.snap.evnexAt || -[self.snap.evnexAt timeIntervalSinceNow] > EBEvnexBasePollInterval)) {
            self.evnexNextAttemptAt = nil;
            [self refresh];
        }
    }
}

- (void)changeWindow:(NSSegmentedControl *)sender {
    if (!self.views.chart) return;
    self.views.chart.windowSeconds = sender.selectedSegment == 1 ? 48 * 3600 : 12 * 3600;
    [self updatePopoverBody];
}

- (void)showError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = error ? [NSAlert alertWithError:error] : [NSAlert new];
    if (title.length) alert.messageText = title;
    [alert runModal];
}

- (void)updateLaunchAtLoginMenuItem {
    NSMenuItem *login = [self.views.gearMenu itemWithTag:9002];
    if (!login) return;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    login.title = status == SMAppServiceStatusRequiresApproval
        ? @"Launch at Login (approve in System Settings)"
        : @"Launch at Login";
    login.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                : status == SMAppServiceStatusRequiresApproval ? NSControlStateValueMixed
                : NSControlStateValueOff;
}

- (BOOL)setLaunchAtLoginEnabled:(BOOL)enabled showErrors:(BOOL)showErrors {
    NSError *error = nil;
    BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                      : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!ok && showErrors) [self showError:error title:@"Couldn’t update Launch at Login"];
    if (ok && enabled && SMAppService.mainAppService.status == SMAppServiceStatusRequiresApproval
        && showErrors) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Approval required";
        alert.informativeText = @"macOS requires approval in System Settings → General → Login Items. "
                                @"Energybar has submitted the request.";
        [alert runModal];
    }
    [self updateLaunchAtLoginMenuItem];
    return ok;
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    BOOL enabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    [self setLaunchAtLoginEnabled:!enabled showErrors:YES];
}

- (void)showGearMenu:(NSButton *)sender {
    if (!self.views.gearMenu) return;
    [self updateLaunchAtLoginMenuItem];
    NSPoint p = NSMakePoint(0, sender.bounds.size.height + 2);
    [self.views.gearMenu popUpMenuPositioningItem:nil atLocation:p inView:sender];
}

- (void)refreshNow:(id)sender {
    (void)sender;
    self.evnexPollInterval = EBEvnexBasePollInterval;
    self.evnexNextAttemptAt = nil;
    gSessionNextAttemptAt = nil;
    self.froniusArchiveNextAttemptAt = nil;
    [self refresh];
}

- (void)openSamples:(id)sender {
    (void)sender;
    NSString *dir = self.config.samplesPath.stringByDeletingLastPathComponent;
    NSURL *url = [NSURL fileURLWithPath:dir isDirectory:YES];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)copyDiagnostics:(id)sender {
    (void)sender;
    NSString *text = [NSString stringWithFormat:@"Energybar %@\nglance=%@\npvOK=%d gridOK=%d chargerOK=%d\nvehicle=%@\nstorage=%@\nrecoveryStorage=%@\nvehicleStorage=%@\n",
                      EBVersion,
                      EBGlanceString(self.snap.pvOK, self.snap.pvW, self.snap.gridOK, self.snap.supplyW,
                                     self.snap.chargerOK, self.snap.ocppStatus, self.snap.chargingLogic,
                                     self.snap.chargingCurrentControl, self.snap.chargeNow),
                      self.snap.pvOK, self.snap.gridOK, self.snap.chargerOK,
                      self.vehicle.statusLine,
                      self.snap.storageError ?: @"ok",
                      self.snap.recoveryError ?: @"ok",
                      self.snap.vehicleError ?: @"ok"];
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

- (void)vehicleSetSOC:(id)sender {
    (void)sender;
    EBVehicleManualProvider *g = self.vehicleManual;
    NSAlert *a = [NSAlert new];
    a.messageText = @"Battery state of charge";
    a.informativeText = @"Enter 0–100. Used as an anchor while plugged; cleared after unplug until you provide a newer reading.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 80, 24)];
    if (g.hasSOC) field.stringValue = [NSString stringWithFormat:@"%.0f", g.socPercent];
    a.accessoryView = field;
    [a addButtonWithTitle:@"Save"];
    [a addButtonWithTitle:@"Cancel"];
    [a.window makeFirstResponder:field];
    double pct = 0;
    for (;;) {
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        NSString *value = [field.stringValue stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner = [NSScanner scannerWithString:value];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        if (value.length && [scanner scanDouble:&pct] && scanner.isAtEnd &&
            isfinite(pct) && pct >= 0 && pct <= 100) break;
        NSAlert *bad = [NSAlert new];
        bad.messageText = @"Enter a number between 0 and 100";
        [bad runModal];
    }
    if (![g setSOC:pct]) {
        [self showVehiclePersistenceAlert:@"Battery percentage was not saved"
                                    error:g.persistenceError];
        [self refreshVehiclePresentation];
        return;
    }
    if (![self.vehicleInferred setAnchorPercent:pct at:[NSDate date]
                                        source:EBSoCSourceManual]) {
        [self showVehiclePersistenceAlert:
            @"Battery percentage was saved, but its estimate anchor was not"
                                    error:self.vehicleInferred.persistenceError];
    }
    [self refreshVehiclePresentation];
}

- (void)vehicleToggleReady:(id)sender {
    (void)sender;
    EBVehicleManualProvider *g = self.vehicleManual;
    BOOL next = !(g.hasReady && g.readyToCharge);
    if (![g setReady:next])
        [self showVehiclePersistenceAlert:@"Charge readiness was not saved"
                                    error:g.persistenceError];
    [self refreshVehiclePresentation];
}

- (void)vehicleClear:(id)sender {
    (void)sender;
    BOOL manualCleared = [self.vehicleManual clear];
    // Clear the durable manual fallback first. If that fails, retain the
    // inferred tombstone so an old manual percentage cannot be exposed.
    BOOL inferredCleared = manualCleared ? [self.vehicleInferred clearAllState] : NO;
    if (!manualCleared || !inferredCleared) {
        NSMutableArray<NSString *> *details = [NSMutableArray array];
        if (!manualCleared)
            [details addObject:[NSString stringWithFormat:@"Manual state: %@",
                self.vehicleManual.persistenceError.localizedDescription ?: @"not cleared"]];
        if (!inferredCleared && manualCleared)
            [details addObject:[NSString stringWithFormat:@"Estimate anchor: %@",
                self.vehicleInferred.persistenceError.localizedDescription ?: @"not cleared"]];
        else if (!manualCleared)
            [details addObject:@"Estimate state was retained until manual state can be cleared safely"];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Vehicle data was only partly cleared";
        alert.informativeText = [details componentsJoinedByString:@"\n"];
        [alert runModal];
    }
    [self refreshVehiclePresentation];
}

- (void)showVehiclePersistenceAlert:(NSString *)title error:(NSError *)error {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = error.localizedDescription ?:
        @"The vehicle state store is unavailable. No success was recorded.";
    [alert runModal];
}

- (void)refreshVehiclePresentation {
    if (self.popover.shown) {
        [self updatePopoverBody];
    } else {
        NSArray *samples = EBStoreLoad(self.config.samplesPath, EBStoreMaxAge);
        [self resolveVehicleWithSamples:[self vehicleSamplesIncludingLive:samples]
                             sessions:EBSessionInferenceRecords(self.snap.sessionHistory)];
        self.snap.vehicleError = self.vehicleStorageWarning;
    }
    if (self.snap) [self applyBar:self.snap];
}

- (void)setCommandControlsEnabled:(BOOL)enabled {
    if (!self.views) return;
    EBSetCommandsEnabled(self.views, enabled, self.config.orgId.length > 0);
}

- (void)restoreActionSelection {
    if (!self.views || !self.snap) return;
    EBChargerState state = EBComputeChargerState(
        self.snap.ocppStatus, self.snap.chargingLogic,
        self.snap.chargingCurrentControl, self.snap.chargeNow,
        self.snap.haveOcpp);
    if (state == EBChargerStateCharging) EBSetChargeMode(self.views, 1);
    else if (state == EBChargerStateSolar || state == EBChargerStateWaiting ||
             state == EBChargerStateUnplugged) EBSetChargeMode(self.views, 0);
    else EBSetChargeMode(self.views, -1);
}

- (void)runEvnexCommand:(NSString *)name
                  block:(EBHTTPResponse *(^)(EBConfig *config))block {
    if (self.commandInFlight) {
        [self restoreActionSelection];
        return;
    }
    self.commandInFlight = YES;
    [self setCommandControlsEnabled:NO];
    dispatch_async(EBEvnexQueue(), ^{
        EBHTTPResponse *response = block(self.config);
        if (response.successful) {
            // The detail document contains connector state. Force the next
            // refresh to obtain it rather than replaying pre-command state.
            gCachedDetail = nil;
            gDetailNextAttemptAt = nil;
            gDetailCurrent = NO;
            gDetailLastError = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.commandInFlight = NO;
            [self setCommandControlsEnabled:YES];
            if (!response.successful) {
                NSString *detail = response.error.localizedDescription ?:
                    [NSString stringWithFormat:@"HTTP %ld", (long)response.status];
                NSAlert *alert = [NSAlert new];
                alert.messageText = [NSString stringWithFormat:@"%@ failed", name];
                alert.informativeText = detail;
                [alert runModal];
                [self restoreActionSelection];
            }
            self.evnexPollInterval = EBEvnexBasePollInterval;
            self.evnexNextAttemptAt = nil;
            [self refresh];
        });
    });
}

- (void)doChargeNow:(id)sender {
    (void)sender;
    NSMutableArray<NSString *> *concerns = [NSMutableArray array];
    if (self.vehicle.hasReady && !self.vehicle.readyToCharge) {
        [concerns addObject:@"Vehicle is marked not ready to accept charge."];
    }
    if (self.vehicle.hasSOC && self.vehicle.socPercent >= 90.0) {
        [concerns addObject:[NSString stringWithFormat:@"Battery is at %.0f%%%@.",
                             self.vehicle.socPercent,
                             self.vehicle.socIsEstimate ? @" estimated" : @""]];
    }
    if (concerns.count) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Charge at full power anyway?";
        a.informativeText = [concerns componentsJoinedByString:@"\n"];
        [a addButtonWithTitle:@"Cancel"];
        [a addButtonWithTitle:@"Charge anyway"];
        if ([a runModal] != NSAlertSecondButtonReturn) {
            [self restoreActionSelection];
            return;
        }
    }
    [self runEvnexCommand:@"Charge now" block:^EBHTTPResponse *(EBConfig *c) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"connectorId": @1, @"chargeNow": @YES}
                                                       options:0 error:nil];
        return EBEvnexHTTP(c, @"POST",
            [NSString stringWithFormat:@"%@/charge-points/%@/commands/set-override",
             EBEvnexBase, EBURLPathSegment(c.chargePointId)],
            body);
    }];
}

- (void)doSolar:(id)sender {
    (void)sender;
    [self runEvnexCommand:@"Return to solar" block:^EBHTTPResponse *(EBConfig *c) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"connectorId": @1, @"chargeNow": @NO}
                                                       options:0 error:nil];
        return EBEvnexHTTP(c, @"POST",
            [NSString stringWithFormat:@"%@/charge-points/%@/commands/set-override",
             EBEvnexBase, EBURLPathSegment(c.chargePointId)],
            body);
    }];
}

- (void)doStop:(id)sender {
    (void)sender;
    if (!self.config.orgId.length) return;
    NSAlert *a = [NSAlert new];
    a.messageText = @"Stop charging now?";
    a.informativeText = @"Sends a remote stop to the Evnex charge point.";
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Stop"];
    if ([a runModal] != NSAlertSecondButtonReturn) return;
    [self runEvnexCommand:@"Stop charging" block:^EBHTTPResponse *(EBConfig *c) {
        NSString *org = c.orgId.length ? c.orgId : @"";
        if (!org.length) {
            EBHTTPResponse *failed = [EBHTTPResponse new];
            failed.error = EBError(20, @"Organisation ID is unavailable");
            return failed;
        }
        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"connectorId": @"1"} options:0 error:nil];
        return EBEvnexHTTP(c, @"POST",
            [NSString stringWithFormat:@"%@/v2/apps/organisations/%@/charge-points/%@/commands/remote-stop-transaction",
             EBEvnexBase, EBURLPathSegment(org), EBURLPathSegment(c.chargePointId)], body);
    }];
}

@end

#pragma mark - CLI

static int EBDump(BOOL jsonMode) {
    EBConfig *c = EBLoadConfig();
    EBSnapshot *s = EBFetch(c, YES);
    NSString *vehicleManualPath = [EBHome()
        stringByAppendingPathComponent:@".config/energybar/vehicle.json"];
    NSString *vehicleStatePath = [EBHome()
        stringByAppendingPathComponent:@".cache/energybar/vehicle.json"];
    NSString *vehicleTokenPath = [EBHome()
        stringByAppendingPathComponent:@".cache/energybar/vehicle-token.json"];
    EBVehicleManualProvider *manual = [[EBVehicleManualProvider alloc]
        initWithPath:vehicleManualPath];
    EBVehicleInferredProvider *inferred = [[EBVehicleInferredProvider alloc]
        initWithPath:vehicleStatePath capacityWh:c.evBatteryWh efficiency:c.evChargeEfficiency];
    EBVehicleOBDProvider *obd = [[EBVehicleOBDProvider alloc] initWithCachePath:c.obdCachePath
                                                             maxAgeSeconds:c.obdMaxAgeSeconds];
    EBVehicleLiveProvider *live = [[EBVehicleLiveProvider alloc]
        initWithTokenPath:vehicleTokenPath];
    NSArray *samples = EBStoreLoad(c.samplesPath, EBStoreMaxAge);
    NSDate *dumpNow = [NSDate date];
    NSCalendar *billingCalendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    billingCalendar.timeZone = c.tariff.timeZone ?: NSTimeZone.localTimeZone;
    NSDate *dumpDay = [billingCalendar startOfDayForDate:dumpNow];
    EBGridCostTotals gridCosts = EBTariffIntegrate(samples, dumpDay, dumpNow, c.tariff);
    double importRate = 0, exportRate = 0;
    BOOL activeRates = [c.tariff ratesAtDate:dumpNow importCents:&importRate exportCents:&exportRate];
    BOOL livePriced = activeRates && s.gridOK && !s.gridStale;
    NSError *archiveCacheError = nil;
    NSArray<EBFroniusPVInterval *> *archiveIntervals = c.froniusAPI.length
        ? EBFroniusArchiveLoadPVCache(c.froniusArchivePath,
                                     EBStableSourceID(@"fronius", c.froniusAPI),
                                     dumpNow, &archiveCacheError) : @[];
    EBFroniusPVArchiveSummary archiveDay = EBFroniusArchiveSummarizePV(
        archiveIntervals ?: @[], dumpDay, dumpNow);
    EBFroniusPVArchiveSummary archive48h = EBFroniusArchiveSummarizePV(
        archiveIntervals ?: @[], [dumpNow dateByAddingTimeInterval:-EBStoreMaxAge], dumpNow);
    BOOL inferredSaved = [inferred updateWithSamples:samples
                                             sessions:EBSessionInferenceRecords(s.sessionHistory)
                                                  now:[NSDate date]];
    id<EBVehicleProvider> vehicle = EBResolveVehicle(@[obd, live, inferred, manual]);
    NSMutableArray<NSString *> *vehicleProblems = [NSMutableArray array];
    if (manual.persistenceError)
        [vehicleProblems addObject:manual.persistenceError.localizedDescription];
    if (inferred.persistenceError)
        [vehicleProblems addObject:inferred.persistenceError.localizedDescription];
    if (!inferredSaved && !vehicleProblems.count)
        [vehicleProblems addObject:@"Vehicle state could not be persisted"];
    NSString *vehiclePersistenceError = vehicleProblems.count
        ? [vehicleProblems componentsJoinedByString:@" · "] : nil;
    NSMutableDictionary *vehicleJSON = [vehicle.dictionaryValue mutableCopy];
    vehicleJSON[@"persistenceError"] = vehiclePersistenceError ?: NSNull.null;
    if (jsonMode) {
        NSDate *sessionDay = EBStartOfLocalDay([NSDate date]);
        NSDate *sessionThrough = s.sessionHistory.fetchedAt;
        EBSessionEnergySummary sessionDayTotal = EBSessionEnergyInWindow(
            s.sessionHistory.sessions ?: @[], sessionDay, sessionThrough);
        BOOL sessionDayAvailable = s.sessionHistory.complete && sessionThrough &&
            [sessionThrough compare:sessionDay] != NSOrderedAscending && sessionDayTotal.exact;
        NSDictionary *out = @{
            @"schemaVersion": @7,
            @"version": EBVersion,
            @"glance": EBGlanceString(s.pvOK, s.pvW, s.gridOK, s.supplyW, s.chargerOK,
                                      s.ocppStatus, s.chargingLogic, s.chargingCurrentControl, s.chargeNow),
            @"barState": @(EBComputeBarState(s.pvOK, s.gridOK, s.chargerOK,
                                             s.ocppStatus, s.chargingLogic, s.chargingCurrentControl,
                                             s.chargeNow, s.supplyW)),
            @"fronius": @{
                @"available": @(s.pvOK),
                @"pvW": s.pvOK ? @(s.pvW) : NSNull.null,
                @"eDayWh": s.eDayOK ? @(s.eDayWh) : NSNull.null,
                @"archiveLowerBoundAvailable": @(archiveDay.hasData),
                @"archiveEnergyTodayLowerBoundWh": archiveDay.hasData
                    ? @(archiveDay.energyWh) : NSNull.null,
                @"archiveIntervalCount": @(archiveDay.intervalCount),
                @"archiveRecordedDeviceSeconds": @(archiveDay.recordedDeviceSeconds),
                @"archiveDeviceCount": @(archiveDay.deviceCount),
                @"archiveEnergy48hLowerBoundWh": archive48h.hasData
                    ? @(archive48h.energyWh) : NSNull.null,
                @"archive48hIntervalCount": @(archive48h.intervalCount),
                @"archive48hRecordedDeviceSeconds": @(archive48h.recordedDeviceSeconds),
                @"archive48hDeviceCount": @(archive48h.deviceCount),
                @"archiveSiteCompleteness": @"unverified",
                @"archiveAttribution": @"whole intervals guaranteed inside the window; boundary intervals omitted",
                @"archiveError": archiveCacheError.localizedDescription ?: NSNull.null,
                @"error": s.pvError ?: [NSNull null],
            },
            @"evnex": @{
                @"available": @(s.chargerOK && s.gridOK),
                @"statusAvailable": @(s.chargerOK),
                @"meterAvailable": @(s.gridOK),
                @"meterStale": @(s.gridStale),
                @"meterAsOf": s.gridAsOf ? EBJSONDateString(s.gridAsOf) : NSNull.null,
                @"rateLimited": @(s.evnexRateLimited),
                @"supplyW": (s.gridOK || s.gridStale) ? @(s.supplyW) : NSNull.null,
                @"chargeW": (s.gridOK || s.gridStale) ? @(s.chargeW) : NSNull.null,
                @"ocppStatus": s.ocppStatus ?: [NSNull null],
                @"chargingLogic": s.chargingLogic ?: [NSNull null],
                @"chargingCurrentControl": s.chargingCurrentControl ?: [NSNull null],
                @"chargeNow": (s.chargerOK && s.chargeNowKnown) ? @(s.chargeNow) : NSNull.null,
                @"scheduleBehaviour": s.scheduleBehaviour ?: [NSNull null],
                @"sessionHistoryAvailable": @(s.sessionHistory.fetchedAt != nil),
                @"sessionHistoryCurrent": @(s.sessionHistory.current),
                @"sessionHistoryComplete": @(s.sessionHistory.complete),
                @"sessionHistoryAsOf": s.sessionHistory.fetchedAt
                    ? EBJSONDateString(s.sessionHistory.fetchedAt) : NSNull.null,
                @"sessionCount": @(s.sessionHistory.sessions.count),
                @"sessionEnergyTodayWh": sessionDayAvailable
                    ? @(sessionDayTotal.energyWh) : NSNull.null,
                @"sessionEnergyTodayExact": @(sessionDayAvailable),
                @"sessionError": s.sessionError ?: NSNull.null,
                @"sessionStorageError": s.sessionStorageError ?: NSNull.null,
                @"error": s.evnexError ?: [NSNull null],
            },
            @"gridCosts": @{
                @"tariff": c.tariff.name ?: NSNull.null,
                @"currency": c.tariff.currency ?: NSNull.null,
                @"timeZone": c.tariff.timeZone.name ?: NSNull.null,
                @"sourceURL": c.tariff.sourceURL ?: NSNull.null,
                @"error": c.tariffError ?: NSNull.null,
                @"estimated": @YES,
                @"supplyChargesIncluded": @NO,
                @"pricedCoverageSeconds": @(gridCosts.coverage),
                @"daySpanSeconds": @(gridCosts.span),
                @"importWh": gridCosts.coverage > 0 ? @(gridCosts.importWh) : NSNull.null,
                @"exportWh": gridCosts.coverage > 0 ? @(gridCosts.exportWh) : NSNull.null,
                @"importCost": gridCosts.coverage > 0 ? @(gridCosts.importCost) : NSNull.null,
                @"exportCredit": gridCosts.coverage > 0 ? @(gridCosts.exportCredit) : NSNull.null,
                @"importCentsPerKWhNow": activeRates ? @(importRate) : NSNull.null,
                @"exportCentsPerKWhNow": activeRates ? @(exportRate) : NSNull.null,
                @"importCostPerHourNow": livePriced ? @(fmax(0, s.supplyW) * importRate / 100000) : NSNull.null,
                @"exportCreditPerHourNow": livePriced ? @(fmax(0, -s.supplyW) * exportRate / 100000) : NSNull.null,
            },
            @"vehicle": vehicleJSON,
        };
        NSError *jsonError = nil;
        NSData *d = [NSJSONSerialization dataWithJSONObject:out
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:&jsonError];
        if (!d) {
            fprintf(stderr, "json: %s\n", jsonError.localizedDescription.UTF8String);
            return 2;
        }
        fwrite(d.bytes, 1, d.length, stdout);
        fputc('\n', stdout);
    } else {
        NSDate *now = dumpNow;
        NSDate *day = dumpDay;
        EBDayTotals tot = EBStoreIntegrateSince(samples, day, now);
        NSDate *sessionThrough = s.sessionHistory.fetchedAt;
        EBSessionEnergySummary sessionDayTotal = EBSessionEnergyInWindow(
            s.sessionHistory.sessions ?: @[], day, sessionThrough);
        BOOL sessionDayAvailable = s.sessionHistory.complete && sessionThrough &&
            [sessionThrough compare:day] != NSOrderedAscending && sessionDayTotal.exact;
        NSString *pvDay = @"—";
        if (s.pvOK && s.eDayWh > 0) pvDay = EBFmtKWh(s.eDayWh);
        else if (archiveDay.hasData) pvDay = [@"≥" stringByAppendingString:EBFmtKWh(archiveDay.energyWh)];
        else {
            NSString *n = EBCoverageNote(tot.pvCoverage, tot.span);
            if (![n isEqualToString:@"no data"]) pvDay = EBFmtKWh(tot.pvWh);
        }
        NSString *gNote = EBCoverageNote(tot.gridCoverage, tot.span);
        NSString *gridDay = [gNote isEqualToString:@"no data"] ? @"—" : EBFmtGridDay(tot.exportWh, tot.importWh);
        NSString *cNote = sessionDayAvailable ? @"metered" :
            EBCoverageNote(tot.chargeCoverage, tot.span);
        NSString *carDay = sessionDayAvailable ? EBFmtKWh(sessionDayTotal.energyWh) :
            ([cNote isEqualToString:@"no data"] ? @"—" : EBFmtKWh(tot.chargeWh));
        printf("             Now          Today\n");
        printf("Produce  %-12s %s\n",
               s.pvOK ? [[NSString stringWithFormat:@"%@ kW", EBFmtKW(s.pvW)] UTF8String] : "—",
               pvDay.UTF8String);
        printf("Grid     %-12s %s%s\n",
               s.gridOK ? EBFmtGridNow(s.supplyW).UTF8String : (s.gridStale ? "*" : "—"),
               gridDay.UTF8String,
               (gNote && ![gNote isEqualToString:@"no data"]) ? [[NSString stringWithFormat:@" (%@)", gNote] UTF8String] : "");
        printf("Car      %-12s %s%s\n",
               s.gridOK ? [[NSString stringWithFormat:@"%@ kW", EBFmtKW(s.chargeW)] UTF8String] : "—",
               carDay.UTF8String,
               (cNote && ![cNote isEqualToString:@"no data"]) ? [[NSString stringWithFormat:@" (%@)", cNote] UTF8String] : "");
        printf("Vehicle  %s\n", vehicle.statusLine.UTF8String);
        if (c.tariff && gridCosts.coverage > 0) {
            printf("Energy   import %.2f %s cost / export %.2f %s credit (recorded estimate; supply charges excluded)\n",
                   gridCosts.importCost, c.tariff.currency.UTF8String,
                   gridCosts.exportCredit, c.tariff.currency.UTF8String);
        } else printf("Energy costs: %s\n", c.tariffError.length ? c.tariffError.UTF8String : "rates or priced history unavailable");
        if (vehiclePersistenceError)
            printf("Vehicle storage: %s\n", vehiclePersistenceError.UTF8String);
        if (s.chargerOK)
            printf("%s\n", EBChargerLabelForState(EBComputeChargerState(s.ocppStatus, s.chargingLogic, s.chargingCurrentControl, s.chargeNow, s.haveOcpp)).UTF8String);
        if (s.pvError) printf("Fronius: %s\n", s.pvError.UTF8String);
        if (archiveCacheError)
            printf("Fronius archive: %s\n", archiveCacheError.localizedDescription.UTF8String);
        if (s.evnexError) printf("Evnex: %s\n", s.evnexError.UTF8String);
        if (s.sessionError) printf("Evnex sessions: %s\n", s.sessionError.UTF8String);
        if (s.sessionStorageError) printf("Session storage: %s\n", s.sessionStorageError.UTF8String);
    }
    return (s.pvOK || s.chargerOK || s.gridOK) && !vehiclePersistenceError &&
           !s.sessionStorageError && !archiveCacheError ? 0 : 2;
}

static int EBRefreshFixtures(BOOL acceptTrackedFixtures) {
    EBConfig *c = EBLoadConfig();
    EBSnapshot *s = EBFetch(c, YES);
    NSString *root = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString *repo = root.stringByDeletingLastPathComponent;
    NSString *fix = [repo stringByAppendingPathComponent:
                     acceptTrackedFixtures ? @"Tests/fixtures" : @"build/fixture-preview"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:fix withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0700}
                                                        error:&directoryError]) {
        fprintf(stderr, "refresh-fixtures: %s\n", directoryError.localizedDescription.UTF8String);
        return 2;
    }

    NSDictionary *rawByName = @{
        @"fronius_powerflow.json": s.rawFronius ?: NSNull.null,
        @"evnex_status.json": s.rawStatus ?: NSNull.null,
        @"evnex_detail.json": s.rawDetail ?: NSNull.null,
    };
    NSMutableDictionary<NSString *, NSDictionary *> *fixtures = [NSMutableDictionary dictionary];
    [rawByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, id raw, BOOL *stop) {
        (void)stop;
        NSDictionary *projected = raw == NSNull.null ? nil : EBFixtureProjection(name, raw);
        if (projected) fixtures[name] = projected;
    }];
    if (!fixtures.count) {
        fputs("refresh-fixtures: nothing safe to write (check config/network)\n", stderr);
        return 2;
    }
    if (acceptTrackedFixtures && fixtures.count != rawByName.count) {
        fprintf(stderr, "refresh-fixtures: refusing partial tracked update (%lu/%lu documents)\n",
                (unsigned long)fixtures.count, (unsigned long)rawByName.count);
        return 2;
    }

    __block BOOL writeOK = YES;
    [fixtures enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSDictionary *obj, BOOL *stop) {
        (void)stop;
        NSError *error = nil;
        NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                                    options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                      error:&error];
        NSString *path = [fix stringByAppendingPathComponent:name];
        if (!d || ![d writeToFile:path options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "refresh-fixtures: %s: %s\n", name.UTF8String,
                    error.localizedDescription.UTF8String);
            writeOK = NO;
            return;
        }
        printf("wrote %s/%s\n", fix.UTF8String, name.UTF8String);
    }];
    if (!acceptTrackedFixtures)
        fputs("preview only; pass --accept-fixtures to replace tracked sanitized fixtures\n", stderr);
    return writeOK ? 0 : 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        if ([args containsObject:@"--help"] || [args containsObject:@"-h"]) {
            puts("Energybar — home energy menu bar\n"
                 "  (no args)              run menu bar app (icon-only)\n"
                 "  --dump                 human snapshot\n"
                 "  --dump --json          JSON snapshot\n"
                 "  --refresh-fixtures     write sanitized build/fixture-preview files\n"
                 "  --refresh-fixtures --accept-fixtures  replace tracked sanitized fixtures\n"
                 "  --register-login       enable Launch at Login (SMAppService)\n"
                 "  --unregister-login     disable Launch at Login\n"
                 "  --version");
            return 0;
        }
        if ([args containsObject:@"--version"]) {
            printf("Energybar %s\n", EBVersion.UTF8String);
            return 0;
        }
        if ([args containsObject:@"--register-login"] || [args containsObject:@"--unregister-login"]) {
            BOOL enable = [args containsObject:@"--register-login"];
            NSError *error = nil;
            BOOL ok = enable ? [SMAppService.mainAppService registerAndReturnError:&error]
                             : [SMAppService.mainAppService unregisterAndReturnError:&error];
            if (!ok) {
                fprintf(stderr, "Launch at Login %s failed: %s\n",
                        enable ? "register" : "unregister",
                        error.localizedDescription.UTF8String ?: "unknown error");
                return 1;
            }
            SMAppServiceStatus status = SMAppService.mainAppService.status;
            const char *label = status == SMAppServiceStatusEnabled ? "enabled"
                              : status == SMAppServiceStatusRequiresApproval ? "requires approval"
                              : status == SMAppServiceStatusNotRegistered ? "not registered"
                              : "not found";
            printf("Launch at Login: %s\n", label);
            return 0;
        }
        if ([args containsObject:@"--refresh-fixtures"]) {
            return EBRefreshFixtures([args containsObject:@"--accept-fixtures"]);
        }
        if ([args containsObject:@"--dump"]) {
            return EBDump([args containsObject:@"--json"]);
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        EBApp *delegate = [EBApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
