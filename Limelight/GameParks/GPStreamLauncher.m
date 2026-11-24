//
//  GPStreamLauncher.m
//  GameParks
//

#import "GPStreamLauncher.h"
#import "StreamFrameViewController.h"
#import "StreamConfiguration.h"

@implementation GPStreamLauncher

+ (UIViewController*) streamViewControllerWithConfig:(StreamConfiguration*)config {
    // Validate before touching the storyboard: a zeroed or hostless
    // configuration can only produce a broken stream screen.
    if (config == nil || config.host == nil || config.width <= 0 || config.height <= 0) {
        return nil;
    }
    NSString* storyboardName = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? @"iPad" : @"iPhone";
    // storyboardWithName: raises an NSException (it does not return
    // nil) when the storyboard is missing from the bundle, so check
    // for the resource first and honour the header's nil promise.
    if ([[NSBundle mainBundle] pathForResource:storyboardName ofType:@"storyboardc"] == nil) {
        return nil;
    }
    UIStoryboard* storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
    UIViewController* viewController = [storyboard instantiateViewControllerWithIdentifier:@"streamFrame"];
    if (![viewController isKindOfClass:[StreamFrameViewController class]]) {
        return nil;
    }
    StreamFrameViewController* streamViewController = (StreamFrameViewController*)viewController;
    streamViewController.streamConfig = config;
    return streamViewController;
}

@end
