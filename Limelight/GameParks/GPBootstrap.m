//
//  GPBootstrap.m
//  GameParks
//

#import "GPBootstrap.h"
#import "Moonlight-Swift.h"

@implementation GPBootstrap

+ (void) installInWindow:(UIWindow*)window {
    GPTabBarController* tabBarController = [[GPTabBarController alloc] init];
    UINavigationController* navController = [[UINavigationController alloc] initWithRootViewController:tabBarController];
    [navController setNavigationBarHidden:YES animated:NO];
    navController.delegate = tabBarController;
    window.rootViewController = navController;
}

@end
