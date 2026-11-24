//
//  AppAssetManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/25/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "TemporaryApp.h"
#import "HttpManager.h"
#import "TemporaryHost.h"

@protocol AppAssetCallback <NSObject>

- (void) receivedAssetForApp:(TemporaryApp*)app;

@optional
// GP v2.5 (A-65): success-aware variant. When the callback implements
// this, the retriever reports whether a file was actually written.
- (void) receivedAssetForApp:(TemporaryApp*)app success:(BOOL)success;

@end

@interface AppAssetManager : NSObject

- (id) initWithCallback:(id<AppAssetCallback>)callback;
- (void) retrieveAssetsFromHost:(TemporaryHost*)host;
- (void) stopRetrieving;
+ (NSString*) boxArtPathForApp:(TemporaryApp*)app;
// GP v2.5 (A-67): path derived from an explicit host (the one the
// retriever was given), not from app.host.
+ (NSString*) boxArtPathForApp:(TemporaryApp*)app host:(TemporaryHost*)host;

@end
