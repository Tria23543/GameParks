//
//  GPStreamConfigBuilder.h
//  GameParks
//
//  Builds a StreamConfiguration for an app using the user's saved
//  stream settings. This is the GameParks front-end's entry into the
//  streaming engine — the logic mirrors the engine's own reference
//  implementation so behaviour (codec negotiation, audio, gamepad
//  mask) is identical.
//

#import <Foundation/Foundation.h>
#import "TemporaryApp.h"
#import "StreamConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPStreamConfigBuilder : NSObject

/// Builds the configuration, or returns nil when the app has no
/// host or no saved settings exist — the one deliberate divergence
/// from the engine's reference implementation, which would build a
/// zeroed configuration in those cases instead of failing cleanly.
+ (nullable StreamConfiguration*) configForApp:(TemporaryApp*)app;

@end

NS_ASSUME_NONNULL_END
