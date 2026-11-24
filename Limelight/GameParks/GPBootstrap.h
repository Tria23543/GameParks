//
//  GPBootstrap.h
//  GameParks
//
//  Tiny bridge from the app delegate to the GameParks (Swift) UI.
//  On iOS, GameParks replaces the stock front-end entirely; the
//  streaming engine underneath is unchanged.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPBootstrap : NSObject

/// Installs the GameParks tab-bar UI as the window's root view controller,
/// wrapped in the navigation controller the stream view expects to pop back to.
/// Contract: called exactly once, from the app delegate's
/// didFinishLaunchingWithOptions. The navigation controller's delegate is
/// the tab bar controller — GPEngine's stream-end detection depends on
/// that assignment, so it must not be moved or dropped.
+ (void) installInWindow:(UIWindow*)window;

@end

NS_ASSUME_NONNULL_END
