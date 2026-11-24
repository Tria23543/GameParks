//
//  AppAssetRetriever.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/31/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppAssetRetriever.h"
#import "HttpManager.h"
#import "CryptoManager.h"
#import "AppAssetResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"
#import <UIKit/UIKit.h>

@implementation AppAssetRetriever
static const double RETRY_DELAY = 2; // seconds
static const int MAX_ATTEMPTS = 5;

- (void) main {
    BOOL success = NO;
    int attempts = 0;
    while (![self isCancelled] && attempts++ < MAX_ATTEMPTS) {
        HttpManager* hMan = [[HttpManager alloc] initWithHost:_host];
        AppAssetResponse* appAssetResp = [[AppAssetResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appAssetResp withUrlRequest:[hMan newAppAssetRequestWithAppId:self.app.id]]];

        // GP v2.6 (B-02): an empty body is no body at all — v2.5's
        // data != nil test let a 0-byte 200 response be written as a
        // "cover" that no existence check would ever re-fetch.
        NSData *data = (appAssetResp.data.length > 0) ? appAssetResp.data : nil;
        if (data != nil) {
            // GP v2.5 (A-02): only a real 200 body is box art. An error
            // body must never be cached.
            // GP v2.6 (B-20): a 4xx is permanent — retrying cannot
            // help, so stop at once. A 5xx (Sunshine busy or
            // restarting) is transient: fall through to the retry
            // below and use the existing attempt budget.
            if (appAssetResp.statusCode != 200) {
                if (appAssetResp.statusCode >= 400 && appAssetResp.statusCode < 500) {
                    break;
                }
            } else {
                // GP v2.6 (B-02): status alone is not enough — only
                // bytes that actually decode as an image may be
                // written as box art. A 200 HTML/XML error page or a
                // truncated body must never reach the disk cache;
                // a decode failure is treated as a failed attempt
                // (a truncated body may complete on a retry).
                UIImage *probe = [UIImage imageWithData:data];
                if (probe != nil && probe.size.width > 0 && probe.size.height > 0) {
                    // GP v2.5 (A-64): a cancelled retriever must not write.
                    if ([self isCancelled]) {
                        break;
                    }
                    // GP v2.5 (A-67): path from the host this retriever was
                    // given (_host), via the manager's host-explicit variant.
                    NSString* boxArtPath = [AppAssetManager boxArtPathForApp:self.app host:_host];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[boxArtPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                    // GP v2.5 (A-04): atomic write, result checked; the
                    // callback below reports success only when this wrote.
                    success = [data writeToFile:boxArtPath atomically:YES];
                    break;
                }
            }
        }

        if (![self isCancelled]) {
            [NSThread sleepForTimeInterval:RETRY_DELAY];
        }
    }
    // GP v2.5 (A-65): report success/failure, not unconditional success.
    BOOL wrote = success;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.callback respondsToSelector:@selector(receivedAssetForApp:success:)]) {
            [self.callback receivedAssetForApp:self.app success:wrote];
        } else {
            [self.callback receivedAssetForApp:self.app];
        }
    });
}

@end
