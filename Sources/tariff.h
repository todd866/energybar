#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EBTariff : NSObject
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *currency;
@property(nonatomic, readonly, copy) NSTimeZone *timeZone;
@property(nonatomic, readonly, copy, nullable) NSString *sourceURL;

+ (nullable instancetype)fromDictionary:(NSDictionary *)dictionary error:(NSError **)error;
- (BOOL)ratesAtDate:(NSDate *)date importCents:(double * _Nullable)importCents exportCents:(double * _Nullable)exportCents;
@end

EBTariff * _Nullable EBTariffLoad(NSString *path, NSError **error);

typedef struct {
    double importWh;
    double exportWh;
    double importCost;
    double exportCredit;
    NSTimeInterval coverage;
    NSTimeInterval span;
} EBGridCostTotals;

EBGridCostTotals EBTariffIntegrate(NSArray<NSDictionary *> *samples,
                                   NSDate *since, NSDate *now,
                                   EBTariff * _Nullable tariff);

NS_ASSUME_NONNULL_END
