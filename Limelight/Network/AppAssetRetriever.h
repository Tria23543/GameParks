//
//  AppAssetRetriever.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/31/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "AppAssetManager.h"

// GP v2.7 (C-05): how a retrieval ended, so the manager can tell a
// definitive "this host has no art for this app" (a 4xx, or a 200
// whose body never decodes as an image) from a transient failure
// (transport error, 5xx, write failure, cancellation). Only the
// definitive outcome may stamp the manager's no-art memory.
typedef NS_ENUM(NSInteger, AppAssetRetrievalOutcome) {
    AppAssetRetrievalOutcomeOtherFailure = 0,
    AppAssetRetrievalOutcomeWroteFile,
    AppAssetRetrievalOutcomeDefinitiveNoArt,
};

@interface AppAssetRetriever : NSOperation

@property (nonatomic) TemporaryHost* host;
@property (nonatomic) TemporaryApp* app;
@property (nonatomic) id<AppAssetCallback> callback;
// GP v2.7 (C-05): set by -main before the operation finishes; read
// by the manager's completion block.
@property (nonatomic) AppAssetRetrievalOutcome retrievalOutcome;
// GP v2.7 (C-01): the host's box-art epoch captured by the manager
// when this retriever was created, and a manager-supplied check
// (weakly capturing the manager) that the epoch has not moved
// since. The write path consults the check alongside isCancelled,
// so art fetched before an app-list signature change is never
// written after it. Nil block means no epoch tracking (treated as
// still current).
@property (nonatomic) NSUInteger artEpoch;
@property (nonatomic, copy) BOOL (^artEpochStillCurrentBlock)(void);

@end
