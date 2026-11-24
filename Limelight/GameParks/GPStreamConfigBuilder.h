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

+ (StreamConfiguration*) configForApp:(TemporaryApp*)app;

@end

NS_ASSUME_NONNULL_END
