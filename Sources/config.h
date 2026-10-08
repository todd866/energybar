#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class EBTariff;

@interface EBConfig : NSObject
@property(copy) NSString *froniusAPI;
@property(copy) NSString *chargePointId;
@property(copy) NSString *orgId;
@property(copy) NSString *accessToken;
@property(copy) NSString *refreshToken;
@property(copy, nullable) NSDate *expiresAt;
@property(copy) NSString *tokenCachePath;
@property(copy) NSString *samplesPath;
@property(copy) NSString *sessionsPath;
@property(copy) NSString *froniusArchivePath;
@property double evBatteryWh;
/// Inverter AC capacity in W (INVERTER_KW); 0 = unknown. The Solar bar is full at this.
@property double inverterW;
@property double evChargeEfficiency;
@property(copy) NSString *obdCachePath;
@property NSTimeInterval obdMaxAgeSeconds;
/// Vehicle cloud helper cache (VEHICLE_CLOUD_CACHE); default ~/.cache/energybar/vehicle-cloud.json.
@property(copy) NSString *cloudCachePath;
@property BOOL barText;
@property(copy) NSString *tariffPath;
@property(strong, nullable) EBTariff *tariff;
@property(copy, nullable) NSString *tariffError;
@end

/// ENERGYBAR_HOME when set, otherwise NSHomeDirectory().
NSString *EBHome(void);

/// Parse the small KEY=VALUE configuration format used by Energybar.
/// Keys and values are trimmed; unquoted inline comments are removed.
NSDictionary<NSString *, NSString *> *EBParseEnvFile(NSString *path);

/// Load config and the existing Evnex token cache. Process environment values
/// override the corresponding file values.
EBConfig *EBLoadConfig(void);

/// Persist a Cognito AuthenticationResult atomically with private permissions.
BOOL EBConfigSaveTokens(EBConfig *config, NSDictionary *response, NSError **error);

NS_ASSUME_NONNULL_END
