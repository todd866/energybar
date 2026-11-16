#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Default climate.json per shared controller contract.
NSDictionary *EBClimateDefaultConfig(void);

/// Merge file contents over defaults; missing file yields defaults only.
NSDictionary *EBClimateLoadConfig(NSString *path);

/// Read climate-state.json; missing file yields empty dict.
NSDictionary *EBClimateLoadState(NSString *path);

/// Persist config atomically at mode 0600, preserving unknown keys from any existing file.
BOOL EBClimateSaveConfig(NSString *path, NSDictionary *config, NSError ** _Nullable error);

/// One status line: next/blocked + today's kWh cap usage. No other prose.
NSString *EBClimateStatusLine(NSDictionary * _Nullable state, NSDictionary *config);

NS_ASSUME_NONNULL_END