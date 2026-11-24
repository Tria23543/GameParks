//
//  GPStreamLauncher.m
//  GameParks
//

#import "GPStreamLauncher.h"
#import "StreamFrameViewController.h"
#import "StreamConfiguration.h"

@implementation GPStreamLauncher

+ (UIViewController*) streamViewControllerWithConfig:(StreamConfiguration*)config {
    NSString* storyboardName = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? @"iPad" : @"iPhone";
    UIStoryboard* storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
    UIViewController* viewController = [storyboard instantiateViewControllerWithIdentifier:@"streamFrame"];
    if (![viewController isKindOfClass:[StreamFrameViewController class]]) {
        return nil;
    }
    StreamFrameViewController* streamViewController = (StreamFrameViewController*)viewController;
    streamViewController.streamConfig = config;
    streamViewController.hidesBottomBarWhenPushed = YES;
    return streamViewController;
}

@end
