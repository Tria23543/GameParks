//
//  GPBootstrap.h
//  GameParks
//

#import <UIKit/UIKit.h>

@interface GPBootstrap : NSObject

/// Installs the GameParks root UI in the window: a GPTabBarController
/// at the root of a single navigation controller with its bar hidden
/// (every GameParks screen draws its own header, including its back
/// control). Pushed screens — host, game, connecting, and upstream's
/// stream view controller — ride the same navigation controller,
/// mirroring upstream's storyboard flow where its root pushes the
/// stream screen. Also starts the session controller.
+ (void)installInWindow:(UIWindow *)window;

@end
