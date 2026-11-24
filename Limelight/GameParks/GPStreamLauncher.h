//
//  GPStreamLauncher.h
//  GameParks
//
//  Creates the engine's stream view controller for a prepared
//  StreamConfiguration. This wrapper exists because
//  StreamFrameViewController.h (through StreamView.h) imports the
//  generated Swift header, so it can never be part of the bridging
//  header's own include graph. Swift calls this launcher instead;
//  the implementation file may import the engine headers freely.
//

#import <UIKit/UIKit.h>

@class StreamConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface GPStreamLauncher : NSObject

/// Instantiates the stream view controller from the iPhone/iPad
/// storyboard, attaches the configuration, and returns it ready to
/// install. Returns nil for an unusable configuration (nil config,
/// nil host, zero dimensions) or when the storyboard scene is not
/// the engine's stream view controller.
+ (nullable UIViewController*) streamViewControllerWithConfig:(StreamConfiguration*)config;

@end

NS_ASSUME_NONNULL_END
