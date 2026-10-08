#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reduce a live API document to the exact fields exercised by committed tests.
/// Unknown keys and identifier values are never copied into the result.
NSDictionary * _Nullable EBFixtureProjection(NSString *name, NSDictionary *document);

NS_ASSUME_NONNULL_END
