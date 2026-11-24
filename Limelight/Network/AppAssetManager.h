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
// GP v2.7 (C-02): scoped variant of stopRetrieving — cancels only
// the given host's in-flight retrievers, leaving other hosts'
// batches on the shared queue untouched. Per-host stop+retrieve
// call sites should use this; plain stopRetrieving remains the
// global stop for lifecycle events (resign active, leaving the
// host screens).
- (void) stopRetrievingForHost:(TemporaryHost*)host;
// GP v2.7 (C-25): drop persisted box-art signature entries whose
// host UUID is not in the given set (called after a host is
// removed, so GPBoxArtListSignaturesV1 cannot grow without bound).
- (void) pruneBoxArtSignaturesKeepingUUIDs:(NSSet<NSString *> *)uuids;
+ (NSString*) boxArtPathForApp:(TemporaryApp*)app;
// GP v2.5 (A-67): path derived from an explicit host (the one the
// retriever was given), not from app.host.
+ (NSString*) boxArtPathForApp:(TemporaryApp*)app host:(TemporaryHost*)host;

@end
