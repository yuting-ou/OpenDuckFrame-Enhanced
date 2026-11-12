#import <Foundation/Foundation.h>
#import "SPFileFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN
@interface SPFileRifeEngine : NSObject <SPFileFrameProvider>
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality;
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle;
/// inferenceLongEdge caps the model input resolution (0 keeps the source size);
/// bridgeCount runs interpolation phases on parallel engines (1-4). Outputs are
/// always restored to the decoded source size.
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle
                inferenceLongEdge:(int)inferenceLongEdge bridgeCount:(int)bridgeCount;
@end
NS_ASSUME_NONNULL_END
