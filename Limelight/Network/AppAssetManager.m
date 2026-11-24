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
    // GP v2.5 (A-64): keys (host UUID | app id | name hash) with a
    // retriever already queued/running, so duplicate fetches are
    // not stacked. GP v2.6 (B-01): the value is the retriever itself,
    // so a later retrieve can tell a live retriever from a cancelled
    // one whose key was never cleaned up, and a stale completion
    // block can tell it is no longer the retriever for its key.
    NSMutableDictionary<NSString*, AppAssetRetriever*>* _inFlightRetrievers;
    // GP v2.6 (B-31): keys whose last completed (non-cancelled)
    // retrieval left no file on disk — the host serves no art for
    // them — stamped with when that was learned. They are not
    // re-requested on every trigger; an entry expires after
    // GPNoArtRetrySeconds (so a transient outage cannot strand a
    // cover for the whole session) and a host's entries are cleared
    // whenever its app-list signature changes.
    NSMutableDictionary<NSString*, NSDate*>* _noArtAppKeys;
}

static const int MAX_REQUEST_COUNT = 4;

// FNV-1a-32 over the UTF-8 bytes: stable across launches, unlike
// -[NSString hash], whose algorithm is not guaranteed stable.
// GP v2.6 (B-43): the accumulation is done in a uint32_t so it wraps
// at 32 bits — this is now genuinely FNV-1a-32 (offset basis
// 2166136261, prime 16777619), matching the name. Filenames derived
// from it change once versus v2.5, so each cover is re-fetched once.
+ (NSUInteger) stableHashOfString:(NSString*)string {
    uint32_t hash = 2166136261u;
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
    _inFlightRetrievers = [NSMutableDictionary dictionary];
    _noArtAppKeys = [NSMutableDictionary dictionary];
    
    return self;
}

// GP v2.6 (B-03): a host-side cover change must be able to reach
// the app. Two revalidation mechanisms, both on the existing
// retrieve triggers (app-list refresh, foreground) and neither
// re-downloading fresh covers:
//  1. App-list signature: a hash of the host's sorted id+name list
//     is kept per host (in memory and user defaults). When it
//     changes — an app gained, lost or renamed, which is when a
//     user is editing entries in Sunshine — every cached cover for
//     the host is deleted and re-fetched, and the B-31 no-art
//     memory for the host is cleared.
//  2. Age: a cached file older than GPBoxArtMaxAgeSeconds is
//     deleted and re-fetched, so a pure art swap in Sunshine (no
//     app-list change) still propagates within a week.
static const NSTimeInterval GPBoxArtMaxAgeSeconds = 7 * 24 * 60 * 60;
static const NSTimeInterval GPNoArtRetrySeconds = 60 * 60;
static NSString * const GPBoxArtSignatureDefaultsKey = @"GPBoxArtListSignaturesV1";

- (NSString*) appListSignatureForHost:(TemporaryHost*)host {
    NSMutableArray<NSString*> *parts = [NSMutableArray array];
    for (TemporaryApp *app in host.appList) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", app.id ?: @"", app.name ?: @""]];
    }
    [parts sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%08lx",
            (unsigned long)[AppAssetManager stableHashOfString:[parts componentsJoinedByString:@"|"]]];
}

- (void) retrieveAssetsFromHost:(TemporaryHost*)host {
    NSString *hostKey = host.uuid ?: @"";
    // GP v2.6 (B-03, mechanism 1): app-list signature revalidation.
    NSString *signature = [self appListSignatureForHost:host];
    NSMutableDictionary *signatures = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GPBoxArtSignatureDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *storedSignature = signatures[hostKey];
    BOOL signatureChanged = storedSignature != nil && ![storedSignature isEqualToString:signature];
    if (storedSignature == nil || signatureChanged) {
        signatures[hostKey] = signature;
        [[NSUserDefaults standardUserDefaults] setObject:signatures forKey:GPBoxArtSignatureDefaultsKey];
    }
    if (signatureChanged) {
        @synchronized (_noArtAppKeys) {
            NSString *prefix = [hostKey stringByAppendingString:@"|"];
            NSMutableArray<NSString*> *mine = [NSMutableArray array];
            for (NSString *noArtKey in _noArtAppKeys) {
                if ([noArtKey hasPrefix:prefix]) {
                    [mine addObject:noArtKey];
                }
            }
            [_noArtAppKeys removeObjectsForKeys:mine];
        }
    }

    // GP v2.6 (B-31): deterministic order — host.appList is an NSSet,
    // so queue the retrievers name-sorted; real covers are not left
    // behind guaranteed-fail requests by set-order chance.
    NSArray<TemporaryApp*> *apps = [[host.appList allObjects] sortedArrayUsingComparator:^NSComparisonResult(TemporaryApp *a, TemporaryApp *b) {
        return [(a.name ?: @"") compare:(b.name ?: @"")];
    }];
    for (TemporaryApp* app in apps) {
        NSString *path = [AppAssetManager boxArtPathForApp:app host:host];
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        if (exists && signatureChanged) {
            // GP v2.6 (B-03): the app list changed — drop the cached
            // file so this retrieve re-fetches the current art.
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            exists = NO;
        } else if (exists) {
            // GP v2.6 (B-03): age revalidation for art-only changes.
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *mtime = attrs[NSFileModificationDate];
            if (mtime != nil && [[NSDate date] timeIntervalSinceDate:mtime] > GPBoxArtMaxAgeSeconds) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                exists = NO;
            }
        }
        if (exists) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@|%@|%08lx", hostKey, app.id ?: @"",
                         (unsigned long)[AppAssetManager stableHashOfString:app.name ?: @""]];
        @synchronized (_noArtAppKeys) {
            NSDate *noArtSince = _noArtAppKeys[key];
            if (noArtSince != nil
                && [[NSDate date] timeIntervalSinceDate:noArtSince] < GPNoArtRetrySeconds) {
                continue;
            }
            if (noArtSince != nil) {
                [_noArtAppKeys removeObjectForKey:key];
            }
        }
        AppAssetRetriever* retriever = [[AppAssetRetriever alloc] init];
        retriever.app = app;
        retriever.host = host;
        retriever.callback = _callback;
        @synchronized (_inFlightRetrievers) {
            // GP v2.6 (B-01/A-64): skip only a retriever that is
            // actually still live. A cancelled one (e.g. stopRetrieving
            // ran immediately before this retrieve, per A-56) must not
            // suppress the re-queue — that interaction stranded every
            // cover past the first four until the next trigger.
            AppAssetRetriever *existing = _inFlightRetrievers[key];
            if (existing != nil && ![existing isCancelled]) {
                continue;
            }
            _inFlightRetrievers[key] = retriever;
        }
        NSMutableDictionary<NSString*, AppAssetRetriever*> *inFlight = _inFlightRetrievers;
        NSMutableDictionary<NSString*, NSDate*> *noArt = _noArtAppKeys;
        __weak AppAssetRetriever *weakRetriever = retriever;
        retriever.completionBlock = ^{
            AppAssetRetriever *finished = weakRetriever;
            @synchronized (inFlight) {
                // Only the retriever currently registered for the key
                // may clear it — a cancelled predecessor must not evict
                // its replacement's entry.
                if (finished != nil && inFlight[key] == finished) {
                    [inFlight removeObjectForKey:key];
                }
            }
            // GP v2.6 (B-31): a completed, non-cancelled retrieval
            // that left no file means the host has no art for this
            // app — remember it (until the app list changes) instead
            // of re-requesting it on every trigger. A cancelled
            // retrieval records nothing: it never really asked.
            if (finished != nil && ![finished isCancelled]
                && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                @synchronized (noArt) {
                    noArt[key] = [NSDate date];
                }
            }
        };

        [_opQueue addOperation:retriever];
    }
}

- (void) stopRetrieving {
    [_opQueue cancelAllOperations];
    // GP v2.6 (B-01): cancelAllOperations alone left the cancelled
    // retrievers' keys in the in-flight set until their completion
    // blocks ran, so the stop+retrieve pairs (A-56) re-queued
    // nothing. Drop every cancelled retriever's entry now; the
    // retrieve-side isCancelled check covers any entry whose
    // completion lands between this clear and the re-queue.
    @synchronized (_inFlightRetrievers) {
        NSMutableArray<NSString*> *cancelledKeys = [NSMutableArray array];
        for (NSString *key in _inFlightRetrievers) {
            if ([_inFlightRetrievers[key] isCancelled]) {
                [cancelledKeys addObject:key];
            }
        }
        [_inFlightRetrievers removeObjectsForKeys:cancelledKeys];
    }
}

@end
