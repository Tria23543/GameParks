//
//  GPBootstrap.m
//  GameParks
//

#import "GPBootstrap.h"
#import "GPSessionController.h"
#import "Moonlight-Swift.h"

@implementation GPBootstrap

+ (void)installInWindow:(UIWindow *)window {
    if (window == nil) {
        return;
    }
    // GP v2.5 (A-86): idempotent — if the window already shows the
    // GameParks hierarchy, a second call (scene reconnect, re-install)
    // must not discard it or re-run start.
    UIViewController *existingRoot = window.rootViewController;
    if ([existingRoot isKindOfClass:[GPTabBarController class]]) {
        return;
    }
    if ([existingRoot isKindOfClass:[UINavigationController class]]
        && [[(UINavigationController *)existingRoot topViewController] isKindOfClass:[GPTabBarController class]]) {
        return;
    }
    if ([existingRoot isKindOfClass:[UINavigationController class]]
        && [[(UINavigationController *)existingRoot viewControllers].firstObject isKindOfClass:[GPTabBarController class]]) {
        return;
    }
    GPTabBarController *tabBarController = [[GPTabBarController alloc] init];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:tabBarController];
    [navigationController setNavigationBarHidden:YES animated:NO];
    navigationController.delegate = tabBarController;
    window.rootViewController = navigationController;

    [[GPSessionController sharedController] start];
}

@end
