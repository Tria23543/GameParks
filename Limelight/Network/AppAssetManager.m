//
//  AppAssetManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/25/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AppAssetManager.h"
#import "CryptoManager.h"
#import "Utils.h"
#import "HttpResponse.h"
#import "AppAssetRetriever.h"

@implementation AppAssetManager {
    NSOperationQueue* _opQueue;
    id<AppAssetCallback> _callback;
    // GP v2.5 (A-64): keys (host UUID | app id) with a retriever
    // already queued/running, so duplicate fetches are not stacked.
    NSMutableSet<NSString*>* _inFlightAppKeys;
}

static const int MAX_REQUEST_COUNT = 4;

// FNV-1a over the UTF-8 bytes: stable across launches, unlike
// -[NSString hash], whose algorithm is not guaranteed stable.
+ (NSUInteger) stableHashOfString:(NSString*)string {
    NSUInteger hash = 2166136261u;
    const char *bytes = [string UTF8String];
    for (NSUInteger i = 0; bytes[i] != '\0'; i++) {
        hash ^= (unsigned char)bytes[i];
        hash *= 16777619u;
    }
    return hash;
}

+ (NSString*) boxArtPathForApp:(TemporaryApp*)app {
    return [AppAssetManager boxArtPathForApp:app host:app.host];
}

+ (NSString*) boxArtPathForApp:(TemporaryApp*)app host:(TemporaryHost*)host {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *filePath = [paths objectAtIndex:0];

    // GP v2.5 (cache invalidation, A-05): the "v25" component orphans
    // every file cached by v2.4 and earlier in one place — retriever,
    // manager and the Swift catalog all resolve paths through here.
    filePath = [filePath stringByAppendingPathComponent:@"v25"];

    // Keep app assets separate by host UUID (A-67: the explicit host).
    filePath = [filePath stringByAppendingPathComponent:host.uuid ?: @""];

    // GP v2.5 (A-06): the file name is the app ID plus a stable hash
    // of the app name, so if Sunshine reassigns an ID to a different
    // game the old file is a cache miss, not the wrong game's art.
    NSString *fileName = [NSString stringWithFormat:@"%@-%08lx", app.id ?: @"",
                          (unsigned long)[AppAssetManager stableHashOfString:app.name ?: @""]];
    filePath = [filePath stringByAppendingPathComponent:fileName];

    // Add a png extension
    filePath = [filePath stringByAppendingPathExtension:@"png"];

    return filePath;
}

- (id) initWithCallback:(id<AppAssetCallback>)callback {
    self = [super init];
    _callback = callback;
    _opQueue = [[NSOperationQueue alloc] init];
    [_opQueue setMaxConcurrentOperationCount:MAX_REQUEST_COUNT];
    _inFlightAppKeys = [NSMutableSet set];
    
    return self;
}

- (void) retrieveAssetsFromHost:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[AppAssetManager boxArtPathForApp:app host:host]]) {
            // GP v2.5 (A-64): skip apps a retriever is already fetching.
            NSString *key = [NSString stringWithFormat:@"%@|%@", host.uuid ?: @"", app.id ?: @""];
            @synchronized (_inFlightAppKeys) {
                if ([_inFlightAppKeys containsObject:key]) {
                    continue;
                }
                [_inFlightAppKeys addObject:key];
            }
            AppAssetRetriever* retriever = [[AppAssetRetriever alloc] init];
            retriever.app = app;
            retriever.host = host;
            retriever.callback = _callback;
            NSMutableSet<NSString*> *inFlightKeys = _inFlightAppKeys;
            retriever.completionBlock = ^{
                @synchronized (inFlightKeys) {
                    [inFlightKeys removeObject:key];
                }
            };

            [_opQueue addOperation:retriever];
        }
    }
}

- (void) stopRetrieving {
    [_opQueue cancelAllOperations];
}

@end
