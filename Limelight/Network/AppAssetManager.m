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
    // GP v2.7 (C-01): per-host box-art epoch, bumped whenever the
    // host's app-list signature changes. A retriever captures the
    // epoch when it is created; if the epoch has moved by the time
    // it is about to write, its art predates the change and the
    // write is skipped (the file is left absent, so it is
    // re-fetched by the fresh retriever queued in the same pass).
    NSMutableDictionary<NSString*, NSNumber*>* _artEpochsByHost;
    // GP v2.7 (C-12): lock for the read-modify-write of the
    // persisted signature dictionary in NSUserDefaults, which the
    // B-03 code performed unsynchronised — two concurrent retrieves
    // for different hosts could copy the same stored dictionary and
    // the later write lost the earlier host's signature update.
    NSObject* _signatureLock;
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

// GP v2.7 (C-25): the on-disk directory holding one host's box art
// (the boxArtPath prefix for that host's UUID).
+ (NSString*) boxArtDirectoryForHostKey:(NSString*)hostKey {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dirPath = [paths objectAtIndex:0];
    dirPath = [dirPath stringByAppendingPathComponent:@"v25"];
    dirPath = [dirPath stringByAppendingPathComponent:hostKey];
    return dirPath;
}

- (id) initWithCallback:(id<AppAssetCallback>)callback {
    self = [super init];
    _callback = callback;
    _opQueue = [[NSOperationQueue alloc] init];
    [_opQueue setMaxConcurrentOperationCount:MAX_REQUEST_COUNT];
    _inFlightRetrievers = [NSMutableDictionary dictionary];
    _noArtAppKeys = [NSMutableDictionary dictionary];
    _artEpochsByHost = [NSMutableDictionary dictionary];
    _signatureLock = [[NSObject alloc] init];

    return self;
}

// GP v2.7 (C-01): the host's current box-art epoch (0 if the host's
// signature has never changed this session).
- (NSUInteger) artEpochForHostKey:(NSString*)hostKey {
    @synchronized (_artEpochsByHost) {
        return [_artEpochsByHost[hostKey] unsignedIntegerValue];
    }
}

- (void) bumpArtEpochForHostKey:(NSString*)hostKey {
    @synchronized (_artEpochsByHost) {
        _artEpochsByHost[hostKey] = @([_artEpochsByHost[hostKey] unsignedIntegerValue] + 1);
    }
}

// GP v2.7 (C-01/C-02): cancel one in-flight retriever and drop its
// key at once, so a fresh retriever can be queued for the key in
// the same pass. The cancelled retriever's completion block is
// identity-guarded, so it cannot evict its replacement's entry.
- (void) cancelInFlightRetrieverForKey:(NSString*)key {
    @synchronized (_inFlightRetrievers) {
        AppAssetRetriever *stale = _inFlightRetrievers[key];
        if (stale != nil) {
            [stale cancel];
            [_inFlightRetrievers removeObjectForKey:key];
        }
    }
}

// GP v2.7 (C-02): cancel only the given host's in-flight retrievers
// (keys are "<host UUID>|...") and drop their keys; every other
// host's queued/running retrievers are left untouched.
- (void) cancelInFlightRetrieversForHostKey:(NSString*)hostKey {
    NSString *prefix = [hostKey stringByAppendingString:@"|"];
    @synchronized (_inFlightRetrievers) {
        NSMutableArray<NSString*> *mine = [NSMutableArray array];
        for (NSString *key in _inFlightRetrievers) {
            if ([key hasPrefix:prefix]) {
                [_inFlightRetrievers[key] cancel];
                [mine addObject:key];
            }
        }
        [_inFlightRetrievers removeObjectsForKeys:mine];
    }
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

// GP v2.7 (C-12): read the persisted signature dictionary under the
// signature lock.
- (NSMutableDictionary*) mutableSignatureDictionary {
    @synchronized (_signatureLock) {
        return [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GPBoxArtSignatureDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
}

// GP v2.7 (C-12): merge one host's signature into the persisted
// dictionary atomically — re-read under the lock, set, write back —
// so concurrent updates for other hosts are never lost.
- (void) persistSignature:(NSString*)signature forHostKey:(NSString*)hostKey {
    @synchronized (_signatureLock) {
        NSMutableDictionary *signatures = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GPBoxArtSignatureDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
        signatures[hostKey] = signature;
        [[NSUserDefaults standardUserDefaults] setObject:signatures forKey:GPBoxArtSignatureDefaultsKey];
    }
}

- (void) retrieveAssetsFromHost:(TemporaryHost*)host {
    // GP v2.7 (C-10): a host with a nil/empty UUID would collide
    // with every other such host in every cover namespace — the
    // signature entry, the no-art and in-flight keys, and the
    // on-disk art directory all fall back to the same "" key, so
    // one host's list change could delete another's art. Skip
    // retrieval and signature persistence entirely for such a host.
    if (host.uuid.length == 0) {
        Log(LOG_W, @"AppAssetManager: skipping box art retrieval for host with no UUID: %@", host.name);
        return;
    }
    NSString *hostKey = host.uuid;
    // GP v2.6 (B-03, mechanism 1): app-list signature revalidation.
    // GP v2.7 (C-12): the read is taken under the signature lock,
    // and the write is deferred (see the end of this method).
    NSString *signature = [self appListSignatureForHost:host];
    NSString *storedSignature = [self mutableSignatureDictionary][hostKey];
    BOOL signatureChanged = storedSignature != nil && ![storedSignature isEqualToString:signature];
    if (signatureChanged) {
        // GP v2.7 (C-01): bump the host's art epoch FIRST, before
        // any file is deleted or any retriever is examined. Every
        // retriever created before this moment carries the old
        // epoch and will skip its write even if it is already past
        // its isCancelled check, so pre-change art can never land
        // at a cover path after the change.
        [self bumpArtEpochForHostKey:hostKey];
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

    if (signatureChanged) {
        // GP v2.7 (C-25): the per-app deletion below only visits
        // apps in the host's CURRENT list, so art for apps removed
        // from the list would be orphaned in the host's directory
        // forever. On a signature change, delete every file in the
        // host's art directory that is not the cover path of a
        // current app.
        NSMutableSet<NSString*> *currentFileNames = [NSMutableSet set];
        for (TemporaryApp *app in apps) {
            [currentFileNames addObject:[[AppAssetManager boxArtPathForApp:app host:host] lastPathComponent]];
        }
        NSString *hostDir = [AppAssetManager boxArtDirectoryForHostKey:hostKey];
        NSArray<NSString*> *dirFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:hostDir error:nil];
        for (NSString *fileName in dirFiles) {
            if (![currentFileNames containsObject:fileName]) {
                [[NSFileManager defaultManager] removeItemAtPath:[hostDir stringByAppendingPathComponent:fileName] error:nil];
            }
        }
    }

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
        if (signatureChanged) {
            // GP v2.7 (C-01): an in-flight retriever for this key is
            // fetching PRE-change art. Cancel it and remove its key
            // now, so the fresh retriever below is queued instead of
            // being suppressed by the live-entry check; its stale
            // completion is identity-guarded and cannot evict the
            // replacement, and the epoch bump above guarantees it
            // cannot write even if cancellation lands late.
            [self cancelInFlightRetrieverForKey:key];
        }
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
        // GP v2.7 (C-01): stamp the retriever with the host's
        // current art epoch; the write path re-checks it (via a
        // block that captures this manager weakly, so the block
        // cannot keep the manager — or, through it, the in-flight
        // dictionary — alive).
        NSUInteger epochAtCreation = [self artEpochForHostKey:hostKey];
        retriever.artEpoch = epochAtCreation;
        __weak AppAssetManager *weakSelf = self;
        retriever.artEpochStillCurrentBlock = ^BOOL{
            AppAssetManager *manager = weakSelf;
            return manager != nil && [manager artEpochForHostKey:hostKey] == epochAtCreation;
        };
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
        __weak AppAssetRetriever *weakRetriever = retriever;
        // GP v2.7 (C-24): the completion block must not capture the
        // in-flight / no-art dictionaries (or this manager)
        // strongly — dictionary → retriever → completion block →
        // dictionary was a self-breaking retain cycle that pinned
        // any retriever whose completion never ran. Capture the
        // manager weakly and reach the dictionaries through it;
        // normal completion behaviour is unchanged.
        retriever.completionBlock = ^{
            AppAssetManager *manager = weakSelf;
            AppAssetRetriever *finished = weakRetriever;
            if (manager == nil || finished == nil) {
                return;
            }
            NSMutableDictionary<NSString*, AppAssetRetriever*> *inFlight = manager->_inFlightRetrievers;
            NSMutableDictionary<NSString*, NSDate*> *noArt = manager->_noArtAppKeys;
            @synchronized (inFlight) {
                // Only the retriever currently registered for the key
                // may clear it — a cancelled predecessor must not evict
                // its replacement's entry.
                if (inFlight[key] == finished) {
                    [inFlight removeObjectForKey:key];
                }
            }
            // GP v2.6 (B-31): a completed, non-cancelled retrieval
            // that left no file means the host has no art for this
            // app — remember it (until the app list changes) instead
            // of re-requesting it on every trigger. A cancelled
            // retrieval records nothing: it never really asked.
            // GP v2.7 (C-05): B-31 stamped this for ANY file-less
            // completion, including transport and write failures —
            // a host briefly down had all its missing covers
            // suppressed for the full hour after it recovered.
            // Stamp ONLY on the retriever's definitive no-art
            // outcome (4xx, or a 200 whose body never decodes).
            if (![finished isCancelled]
                && finished.retrievalOutcome == AppAssetRetrievalOutcomeDefinitiveNoArt
                && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                @synchronized (noArt) {
                    noArt[key] = [NSDate date];
                }
            }
        };

        [_opQueue addOperation:retriever];
    }

    // GP v2.7 (C-01/C-12): persist the new signature only AFTER the
    // refetch batch for this host has been queued above. The B-03
    // code persisted it before the loop, so an interruption (or the
    // in-flight suppression C-01 fixes) left the NEW signature
    // blessing PRE-change art with no later trigger revalidating it
    // until the 7-day age check; persisting last means an
    // interrupted pass leaves the old signature stored and the next
    // trigger re-runs the whole change path. The write itself is a
    // lock-guarded merge (persistSignature:forHostKey:), not the
    // old unsynchronised copy-modify-write.
    if (storedSignature == nil || signatureChanged) {
        [self persistSignature:signature forHostKey:hostKey];
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

// GP v2.7 (C-02): scoped stop — cancel only this host's retrievers
// on the shared queue and drop their in-flight keys, so the
// caller's retrieveAssetsFromHost: for this host re-queues its own
// batch while other hosts' in-flight batches run on untouched.
// (Plain stopRetrieving above remains the global stop, used for
// lifecycle events where every host's work really should stop.)
- (void) stopRetrievingForHost:(TemporaryHost*)host {
    if (host.uuid.length == 0) {
        // No scoped namespace exists for a UUID-less host (C-10);
        // there is nothing of its own to cancel.
        return;
    }
    [self cancelInFlightRetrieversForHostKey:host.uuid];
}

// GP v2.7 (C-25): prune persisted box-art signatures for hosts that
// no longer exist. GPBoxArtListSignaturesV1 previously gained an
// entry per host UUID and never lost one.
- (void) pruneBoxArtSignaturesKeepingUUIDs:(NSSet<NSString *> *)uuids {
    @synchronized (_signatureLock) {
        NSMutableDictionary *signatures = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GPBoxArtSignatureDefaultsKey] mutableCopy];
        if (signatures == nil) {
            return;
        }
        NSMutableArray<NSString*> *stale = [NSMutableArray array];
        for (NSString *uuid in signatures) {
            if (![uuids containsObject:uuid]) {
                [stale addObject:uuid];
            }
        }
        if (stale.count == 0) {
            return;
        }
        [signatures removeObjectsForKeys:stale];
        [[NSUserDefaults standardUserDefaults] setObject:signatures forKey:GPBoxArtSignatureDefaultsKey];
    }
}

@end
