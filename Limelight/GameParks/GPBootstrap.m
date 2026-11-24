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
    GPTabBarController *tabBarController = [[GPTabBarController alloc] init];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:tabBarController];
    [navigationController setNavigationBarHidden:YES animated:NO];
    navigationController.delegate = tabBarController;
    window.rootViewController = navigationController;

    [[GPSessionController sharedController] start];
}

@end
