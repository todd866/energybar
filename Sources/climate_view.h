#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol EBClimateViewDelegate <NSObject>
- (void)climateViewRequestCoolNow:(id)sender completion:(void (^)(NSString * _Nullable error))completion;
@end

@interface EBClimateView : NSView
@property(nonatomic, weak, nullable) id<EBClimateViewDelegate> delegate;
@property(nonatomic, copy) NSString *configPath;
@property(nonatomic, copy) NSString *statePath;
- (instancetype)initWithConfigPath:(NSString *)configPath statePath:(NSString *)statePath;
- (void)reloadState;
- (void)flushToDisk;
@end

NSAlert *EBBuildClimateAlert(EBClimateView *view);

NS_ASSUME_NONNULL_END