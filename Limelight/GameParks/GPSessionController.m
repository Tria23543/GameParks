//
//  GPSessionController.m
//  GameParks
//
//  See the header for the contract. The method bodies for selection,
//  pairing, the app list and stream configuration are ports of
//  MainFrameViewController's, with UI calls replaced by notifications
//  and the two pairing blocks. Deviations from upstream are marked
//  "GP:" at the site.
//

#import "GPSessionController.h"

#import "CryptoManager.h"
#import "IdManager.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "DiscoveryManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "ServerInfoResponse.h"
#import "AppListResponse.h"
#import "ConnectionHelper.h"
#import "AppAssetManager.h"
#import "PairManager.h"
#import "WakeOnLanManager.h"
#import "StreamConfiguration.h"
#import "StreamFrameViewController.h"
#import "ControllerSupport.h"
#import "Moonlight-Swift.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <Limelight.h>
#include <unistd.h>

NSNotificationName const GPHostsChangedNotification = @"GPHostsChanged";
NSNotificationName const GPAppListChangedNotification = @"GPAppListChanged";
NSNotificationName const GPHostInfoErrorNotification = @"GPHostInfoError";
NSString * const GPHostInfoErrorMessageKey = @"message";

@interface GPSessionController () <DiscoveryCallback, PairCallback, AppAssetCallback>
- (void)startPairing:(NSString *)PIN generation:(NSUInteger)generation;
- (void)pairSuccessful:(NSData *)serverCert generation:(NSUInteger)generation;
- (void)pairFailed:(NSString *)message generation:(NSUInteger)generation;
- (void)alreadyPairedWithGeneration:(NSUInteger)generation;
@end

// GP v2.5 (A-13): PairManager's callbacks carry no sender, so each
// pairing attempt gets its own callback proxy stamped with that
// attempt's generation. A stale operation's callbacks are dropped by
// the session before they can touch current pairing state.
@interface GPGenerationPairCallback : NSObject <PairCallback>
@property (nonatomic, weak) GPSessionController *session;
@property (nonatomic) NSUInteger generation;
@end

@implementation GPGenerationPairCallback
- (void)startPairing:(NSString *)PIN { [self.session startPairing:PIN generation:self.generation]; }
- (void)pairSuccessful:(NSData *)serverCert { [self.session pairSuccessful:serverCert generation:self.generation]; }
- (void)pairFailed:(NSString *)message { [self.session pairFailed:message generation:self.generation]; }
- (void)alreadyPaired { [self.session alreadyPairedWithGeneration:self.generation]; }
@end

@implementation GPSessionController {
    NSOperationQueue *_opQueue;
    DiscoveryManager *_discMan;
    NSData *_clientCert;
    NSString *_uniqueId;

    NSArray<TemporaryHost *> *_hosts;
    NSMutableDictionary<NSString *, NSString *> *_appListErrors;
    NSMutableDictionary<NSString *, NSNumber *> *_pingSamplesMs;

    TemporaryHost *_pairingHost;
    BOOL _pairingInProgress;
    BOOL _pairingCancelled;

    GPSubnetScanner *_scanner;
    BOOL _scanInProgress;
    NSDate *_lastScanStart;

    AppAssetManager *_assetManager;
    BOOL _assetRefreshScheduled;
    TemporaryHost *_assetRefreshHost;

    // GP v2.5 (A-11): in-flight coalescing, keyed by host UUID.
    NSMutableSet<NSString *> *_activationInFlight;
    NSMutableSet<NSString *> *_fetchInFlight;
    // GP v2.5 (A-55/A-10): per-host generation, bumped when a host is
    // removed so stale waits/failures can recognise themselves.
    NSMutableDictionary<NSString *, NSNumber *> *_hostGenerations;

    // GP v2.5 (A-13/A-54): pairing generation + current operation.
    NSUInteger _pairingGeneration;
    PairManager *_currentPairManager;

    // GP v2.5 (A-60): scan generation, so a cancelled sweep's late
    // completion cannot clear a newer sweep's in-progress flag.
    NSUInteger _scanGeneration;

    BOOL _started;
    BOOL _streamActive;
}

+ (instancetype)sharedController {
    static GPSessionController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[GPSessionController alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hosts = @[];
        _appListErrors = [NSMutableDictionary dictionary];
        _pingSamplesMs = [NSMutableDictionary dictionary];
        _activationInFlight = [NSMutableSet set];
        _fetchInFlight = [NSMutableSet set];
        _hostGenerations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (DiscoveryManager *)discoveryManager {
    return _discMan;
}

- (BOOL)pairingInProgress {
    return _pairingInProgress;
}

#pragma mark - Setup (upstream: viewDidLoad)

- (void)start {
    if (_started) {
        return;
    }
    _started = YES;

    // Set up crypto — identical to upstream.
    [CryptoManager generateKeyPairUsingSSL];
    _uniqueId = [IdManager getUniqueId];
    _clientCert = [CryptoManager readCertFromFile];

    _opQueue = [[NSOperationQueue alloc] init];

    [self seedSettingsIfNeeded];
    [self migrateOscToAutoIfNeeded];

    // Upstream retrieveSavedHosts, including the activeAddress fixups.
    DataManager *dataMan = [[DataManager alloc] init];
    NSMutableArray<TemporaryHost *> *loaded = [NSMutableArray array];
    for (TemporaryHost *host in [dataMan getHosts]) {
        if (host.activeAddress == nil) {
            host.activeAddress = host.localAddress;
        }
        if (host.activeAddress == nil) {
            host.activeAddress = host.externalAddress;
        }
        if (host.activeAddress == nil) {
            host.activeAddress = host.address;
        }
        if (host.activeAddress == nil) {
            host.activeAddress = host.ipv6Address;
        }
        [loaded addObject:host];
    }
    _hosts = [self sortedHosts:loaded];

    _discMan = [[DiscoveryManager alloc] initWithHosts:_hosts andCallback:self];
    [_discMan startDiscovery];

    // GP: upstream's box-art fetcher, with this session as its
    // callback (upstream: MainFrameViewController's _appManager).
    _assetManager = [[AppAssetManager alloc] initWithCallback:self];

    _scanner = [[GPSubnetScanner alloc] init];
    [self scanLocalNetworkForce:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    // Upstream: with exactly one known PC, select it right away
    // (not user-initiated, so this never starts pairing on its own).
    if (_hosts.count == 1) {
        _selectedHost = _hosts.firstObject;
        [self activateHost:_selectedHost userInitiated:NO skipFastPath:NO];
    }
}

#pragma mark - GP v2.5 coalescing / generation helpers

- (NSString *)hostKeyForHost:(TemporaryHost *)host {
    return host.uuid ?: [NSString stringWithFormat:@"%p", host];
}

- (NSUInteger)generationForHostKey:(NSString *)key {
    @synchronized (_hostGenerations) {
        return [_hostGenerations[key] unsignedIntegerValue];
    }
}

- (NSUInteger)bumpGenerationForHostKey:(NSString *)key {
    @synchronized (_hostGenerations) {
        NSUInteger generation = [_hostGenerations[key] unsignedIntegerValue] + 1;
        _hostGenerations[key] = @(generation);
        return generation;
    }
}

- (void)endActivationForKey:(NSString *)key {
    @synchronized (_activationInFlight) {
        [_activationInFlight removeObject:key];
    }
}

/// GP v2.5 (A-55): a failure may only be applied when nothing has
/// superseded it — the operation's generation is still current (the
/// host was not removed mid-flight) and the host is still known or
/// selected. Concurrent same-host operations are already coalesced
/// (A-11), so a late failure cannot race a concurrent success for
/// the same host through these paths.
- (BOOL)failureIsCurrentForHost:(TemporaryHost *)host generation:(NSUInteger)generation key:(NSString *)key {
    if ([self generationForHostKey:key] != generation) {
        return NO;
    }
    return [self hostWithUUID:host.uuid] != nil || host == _selectedHost;
}

/// GP v2.5 (A-63): fetch box art for any app of this host that lacks
/// a file, stopping any queued retrieval first (A-56).
- (void)retrieveMissingAssetsForHost:(TemporaryHost *)host {
    if (host == nil || _assetManager == nil) {
        return;
    }
    for (TemporaryApp *app in host.appList) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[AppAssetManager boxArtPathForApp:app]]) {
            [_assetManager stopRetrieving];
            [_assetManager retrieveAssetsFromHost:host];
            return;
        }
    }
}

/// GP v2.5 (A-60): cancelling a sweep clears the session's
/// in-progress flag synchronously; the scanner's group completion
/// may land seconds later and must not gate the next foreground scan.
- (void)cancelScanSynchronously {
    _scanGeneration += 1;
    [_scanner cancel];
    _scanInProgress = NO;
    _lastScanStart = nil;
}

/// Writes Glenda's settled defaults (1080p, 60 fps, 20 Mb/s, codec
/// Auto, stats overlay on) only when the database still holds the
/// engine's factory defaults and no earlier GameParks version has
/// seeded it — her saved settings are never overwritten.
- (void)seedSettingsIfNeeded {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GPSeededSettingsV1"]) {
        return;
    }
    DataManager *dataMan = [[DataManager alloc] init];
    TemporarySettings *current = [dataMan getSettings];
    BOOL factoryDefaults = current != nil
        && [current.bitrate intValue] == 10000
        && [current.width intValue] == 1280
        && [current.height intValue] == 720;
    if (!factoryDefaults) {
        return;
    }
    // GP v2.5 (A-61): factory-valued settings in a profile that
    // already has saved hosts are a pre-GameParks user's deliberate
    // choice, not a fresh install — leave them, and never revisit.
    if ([dataMan getHosts].count > 0) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPSeededSettingsV1"];
        return;
    }
    [dataMan saveSettingsWithBitrate:20000
                           framerate:60
                              height:1080
                               width:1920
                         audioConfig:2
                    onscreenControls:1 // OnScreenControlsLevelAuto — show only with no controller connected
                       optimizeGames:NO
                     multiController:YES
                     swapABXYButtons:NO
                           audioOnPC:NO
                      preferredCodec:0 // CODEC_PREF_AUTO — never forced
                      useFramePacing:NO
                           enableHdr:NO
                      btMouseSupport:NO
                   absoluteTouchMode:NO
                        statsOverlay:YES];
    // GP v2.5 (A-38): GameParks itself wrote the OSC value above;
    // record that provenance for the OSC migration.
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPGameParksWroteOscV25"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPSeededSettingsV1"];
}

/// One-time migration (v2.1): GameParks v1–v2.0 seeded the on-screen
/// controls level as 2, believing it meant "on". In the engine's enum
/// 2 is OnScreenControlsLevelSimple — a fixed set of touch buttons
/// that is always visible, controller or not. The intended behaviour
/// is Auto (1): full touch controls only while no physical controller
/// is connected, hidden (or reduced to the buttons the controller
/// lacks) when one is. The GameParks settings UI only ever offered a
/// plain on/off toggle whose "on" also wrote 2, so a stored 2 can
/// only have come from GameParks itself, never from a user choosing
/// Simple. Rewrite exactly that value to Auto, preserving every
/// other setting; 0 (user turned controls off) and any other value
/// are left untouched.
- (void)migrateOscToAutoIfNeeded {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GPMigratedOscAutoV21"]) {
        return;
    }
    // GP v2.5 (A-19): the done-flag is written only AFTER the record
    // has been inspected and any rewrite saved (below, and in the
    // early exits once inspection has happened).
    DataManager *dataMan = [[DataManager alloc] init];
    TemporarySettings *current = [dataMan getSettings];
    if (current == nil || [current.onscreenControls intValue] != 2) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPMigratedOscAutoV21"];
        return;
    }
    // GP v2.5 (A-38): a stored 2 can also be a deliberate Simple
    // choice made in upstream's settings screen. Migrate only when a
    // GameParks-provenance marker proves GameParks wrote the value.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"GPGameParksWroteOscV25"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPMigratedOscAutoV21"];
        return;
    }
    [dataMan saveSettingsWithBitrate:[current.bitrate intValue]
                           framerate:[current.framerate intValue]
                              height:[current.height intValue]
                               width:[current.width intValue]
                         audioConfig:[current.audioConfig intValue]
                    onscreenControls:1 // OnScreenControlsLevelAuto
                       optimizeGames:current.optimizeGames
                     multiController:current.multiController
                     swapABXYButtons:current.swapABXYButtons
                           audioOnPC:current.playAudioOnPC
                      preferredCodec:(uint32_t)current.preferredCodec
                      useFramePacing:current.useFramePacing
                           enableHdr:current.enableHdr
                      btMouseSupport:current.btMouseSupport
                   absoluteTouchMode:current.absoluteTouchMode
                        statsOverlay:current.statsOverlay];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPGameParksWroteOscV25"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPMigratedOscAutoV21"];
}

#pragma mark - App lifecycle (upstream: beginForegroundRefresh / handleEnterBackground)

- (void)appDidBecomeActive {
    if (_streamActive) {
        // Upstream's observers are removed while streaming; mirror by
        // doing nothing until the stream ends.
        return;
    }
    [_discMan resetDiscoveryState];
    [_discMan startDiscovery];
    [self scanLocalNetworkForce:NO];
    if (_selectedHost != nil && _selectedHost.pairState == PairStatePaired) {
        [self activateHost:_selectedHost userInitiated:NO skipFastPath:NO];
        // GP v2.5 (A-63): foregrounding also recovers any box art a
        // cancelled/failed earlier cycle left missing.
        [self retrieveMissingAssetsForHost:_selectedHost];
    }
}

- (void)appWillResignActive {
    [_discMan stopDiscovery];
    [self cancelScanSynchronously];
    [_assetManager stopRetrieving];
}

#pragma mark - DiscoveryCallback

- (void)updateAllHosts:(NSArray *)hosts {
    // We must copy the array here because it could be modified
    // before our main thread dispatch happens (upstream does this).
    NSArray *hostsCopy = [NSArray arrayWithArray:hosts];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<TemporaryHost *> *sorted = [self sortedHosts:hostsCopy];
        // GP: publish only on a real change. Discovery polls every
        // couple of seconds; notifying unconditionally would rebuild
        // the screens constantly and eat touches mid-tap.
        if ([[self hostsSignature:sorted] isEqualToString:[self hostsSignature:self->_hosts]]) {
            return;
        }
        self->_hosts = sorted;
        [self reresolveSelection];
        [self postHostsChanged];
    });
}

/// Adopts a host validated by the subnet scanner. discoverHost has
/// already added it to DiscoveryManager's queue, so this only
/// persists it and merges it into the visible list.
- (void)adoptScannedHost:(TemporaryHost *)host {
    dispatch_async(dispatch_get_main_queue(), ^{
        DataManager *dataMan = [[DataManager alloc] init];
        [dataMan updateHost:host];
        if ([self hostWithUUID:host.uuid] == nil) {
            NSMutableArray<TemporaryHost *> *merged = [self->_hosts mutableCopy];
            [merged addObject:host];
            self->_hosts = [self sortedHosts:merged];
            if (self->_selectedHost == nil) {
                self->_selectedHost = host;
            }
            [self postHostsChanged];
        }
    });
}

#pragma mark - Subnet scan

- (void)rescanLocalNetwork {
    [self scanLocalNetworkForce:NO];
}

- (void)scanLocalNetworkForce:(BOOL)force {
    if (_discMan == nil || _scanner == nil || _scanInProgress) {
        return;
    }
    if (!force && _lastScanStart != nil
        && [[NSDate date] timeIntervalSinceDate:_lastScanStart] < 20) {
        return;
    }
    _scanInProgress = YES;
    _lastScanStart = [NSDate date];
    _scanGeneration += 1;
    NSUInteger scanGeneration = _scanGeneration;
    __weak typeof(self) weakSelf = self;
    [_scanner scanWithDiscoveryManager:_discMan onHost:^(TemporaryHost *host) {
        [weakSelf adoptScannedHost:host];
    } completion:^(BOOL completed) {
        GPSessionController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_scanGeneration != scanGeneration) {
            return;
        }
        strongSelf->_scanInProgress = NO;
        if (!completed) {
            // A superseded/cancelled sweep must not throttle the
            // next real attempt for the full interval.
            strongSelf->_lastScanStart = nil;
        }
    }];
}

#pragma mark - Selection & activation (upstream: hostClicked:view:)

- (void)selectHost:(TemporaryHost *)host {
    _selectedHost = host;
}

- (void)activateHost:(TemporaryHost *)host userInitiated:(BOOL)userInitiated skipFastPath:(BOOL)skipFastPath {
    _selectedHost = host;

    // Upstream fast path: online, paired, and a cached app list —
    // skip straight to the app list fetch.
    if (!skipFastPath
        && host.state == StateOnline
        && host.pairState == PairStatePaired
        && host.appList.count > 0) {
        [self fetchAppListForHost:host];
        return;
    }

    // GP v2.5 (A-11): coalesce concurrent activations per host.
    NSString *hostKey = [self hostKeyForHost:host];
    @synchronized (_activationInFlight) {
        if ([_activationInFlight containsObject:hostKey]) {
            return;
        }
        [_activationInFlight addObject:hostKey];
    }
    NSUInteger generation = [self generationForHostKey:hostKey];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for the PC's status to be known (upstream does this).
        // GP v2.5 (A-10): bounded (max 15 iterations) and abandoned if
        // the host was removed (generation bump) or a stream started.
        int unknownWaits = 0;
        while (host.state == StateUnknown && unknownWaits++ < 15) {
            if ([self generationForHostKey:hostKey] != generation || self->_streamActive) {
                break;
            }
            sleep(1);
        }
        if (host.state == StateUnknown) {
            [self endActivationForKey:hostKey];
            return;
        }

        // Don't bother polling if the server is already offline.
        if (host.state == StateOffline) {
            [self endActivationForKey:hostKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postHostsChanged];
            });
            return;
        }

        HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
        ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];

        NSDate *requestStart = [NSDate date];
        // Exempt this host from discovery while handling the request.
        [self->_discMan pauseDiscoveryForHost:host];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                          withUrlRequest:[hMan newServerInfoRequest:false]
                                                           fallbackError:401
                                                         fallbackRequest:[hMan newHttpServerInfoRequest]]];
        [self->_discMan resumeDiscoveryForHost:host];

        if (![serverInfoResp isStatusOk]) {
            Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
            [self endActivationForKey:hostKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                // GP v2.5 (A-55): never apply a stale failure.
                if (![self failureIsCurrentForHost:host generation:generation key:hostKey]) {
                    return;
                }
                host.state = StateOffline;
                if (userInitiated) {
                    [self postHostInfoError:host
                                    message:serverInfoResp.statusMessage ?: @"Could not reach this PC."];
                }
                [self postHostsChanged];
            });
            return;
        }

        // Update the host object with this data.
        [serverInfoResp populateHost:host];

        NSInteger elapsedMs = MAX((NSInteger)(-[requestStart timeIntervalSinceNow] * 1000), 1);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithArray:self->_pingSamplesMs[host.uuid] ?: @[]];
            [samples addObject:@(elapsedMs)];
            while (samples.count > 10) {
                [samples removeObjectAtIndex:0];
            }
            self->_pingSamplesMs[host.uuid] = samples;
            [self postHostsChanged];
        });

        if (host.pairState == PairStatePaired) {
            Log(LOG_I, @"Already Paired");
            [self fetchAppListForHost:host];
        }
        // Only pair when this was the result of explicit user action.
        else if (userInitiated) {
            Log(LOG_I, @"Trying to pair");
            [self startPairingWithHost:host httpManager:hMan];
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postHostsChanged];
            });
        }
        [self endActivationForKey:hostKey];
    });
}

#pragma mark - Pairing (upstream: hostClicked pairing branch + PairCallback)

- (void)pairSelectedHost {
    if (_selectedHost != nil) {
        [self activateHost:_selectedHost userInitiated:YES skipFastPath:NO];
    }
}

/// Runs on a background queue (called from activateHost's block) —
/// this is the queue discipline whose absence on the main queue
/// deadlocked v1.1's pairing.
- (void)startPairingWithHost:(TemporaryHost *)host httpManager:(HttpManager *)hMan {
    // GP v2.5 (A-54): pairing state is confined to the main queue.
    // This method runs on a background queue (from activateHost), so
    // the claim is taken synchronously on main before anything else.
    __block BOOL claimed = NO;
    __block NSUInteger generation = 0;
    void (^claim)(void) = ^{
        if (self->_pairingInProgress) {
            return;
        }
        self->_pairingInProgress = YES;
        self->_pairingCancelled = NO;
        self->_pairingHost = host;
        self->_pairingGeneration += 1;
        generation = self->_pairingGeneration;
        claimed = YES;
    };
    if ([NSThread isMainThread]) {
        claim();
    } else {
        dispatch_sync(dispatch_get_main_queue(), claim);
    }
    if (!claimed) {
        return;
    }

    // Polling the server while pairing causes the server to screw
    // up, so discovery stops completely first (upstream's words).
    [_discMan stopDiscoveryBlocking];

    // GP v2.5 (A-13): the operation gets a generation-stamped proxy
    // callback and is retained, so cancelPairing can cancel it and
    // its late callbacks are ignored once superseded. (A-115: the old
    // nil-PairManager branch was dead code and is gone.)
    GPGenerationPairCallback *callback = [[GPGenerationPairCallback alloc] init];
    callback.session = self;
    callback.generation = generation;
    PairManager *pMan = [[PairManager alloc] initWithManager:hMan clientCert:_clientCert callback:callback];

    __block BOOL stillCurrent = NO;
    void (^store)(void) = ^{
        if (self->_pairingGeneration == generation && self->_pairingInProgress) {
            self->_currentPairManager = pMan;
            stillCurrent = YES;
        }
    };
    if ([NSThread isMainThread]) {
        store();
    } else {
        dispatch_sync(dispatch_get_main_queue(), store);
    }
    if (!stillCurrent) {
        [pMan cancel];
        return;
    }
    [_opQueue addOperation:pMan];

    // GP v2.5 (A-54): watchdog — a PairManager that ends without a
    // callback must not wedge pairing for the life of the process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self->_pairingInProgress || self->_pairingGeneration != generation) {
            return;
        }
        self->_pairingGeneration += 1;
        [self->_currentPairManager cancel];
        self->_currentPairManager = nil;
        self->_pairingInProgress = NO;
        self->_pairingHost = nil;
        [self->_discMan startDiscovery];
        if (self.onPairingResult) {
            self.onPairingResult(NO, @"Pairing timed out. Try again.");
        }
        [self postHostsChanged];
    });
}

- (void)cancelPairing {
    // GP v2.5 (A-13/A-54): main-queue confined; bump the generation,
    // cancel the actual PairManager operation, and clear state so a
    // late callback from it is dropped as stale.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cancelPairing];
        });
        return;
    }
    _pairingGeneration += 1;
    [_currentPairManager cancel];
    _currentPairManager = nil;
    _pairingCancelled = YES;
    _pairingInProgress = NO;
    _pairingHost = nil;
    [_discMan startDiscovery];
}

- (void)startPairing:(NSString *)PIN {
    [self startPairing:PIN generation:_pairingGeneration];
}

- (void)startPairing:(NSString *)PIN generation:(NSUInteger)generation {
    // Needs to be synchronous to ensure the PIN UI is shown before
    // any potential failure callback could be invoked (upstream).
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (generation != self->_pairingGeneration) {
            return; // GP v2.5 (A-13): stale attempt's PIN.
        }
        if (self.onPairingPIN) {
            self.onPairingPIN(PIN);
        }
    });
}

- (void)pairSuccessful:(NSData *)serverCert {
    [self pairSuccessful:serverCert generation:_pairingGeneration];
}

- (void)pairSuccessful:(NSData *)serverCert generation:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_pairingGeneration) {
            return; // GP v2.5 (A-13): stale attempt — ignore.
        }
        self->_currentPairManager = nil;
        // GP: apply the result to the host that was actually paired
        // (upstream applies it to its selected host; v1.2 shipped a
        // bug doing exactly that when the two differed).
        TemporaryHost *host = self->_pairingHost ?: self->_selectedHost;
        if (host != nil) {
            host.serverCert = serverCert;
            host.pairState = PairStatePaired;
            // GP: persist immediately instead of waiting for the
            // next discovery poll to save the host.
            DataManager *dataMan = [[DataManager alloc] init];
            [dataMan updateHost:host];
        }
        self->_pairingInProgress = NO;
        self->_pairingHost = nil;
        [self->_discMan startDiscovery];
        if (self.onPairingResult) {
            self.onPairingResult(YES, nil);
        }
        if (host != nil) {
            [self fetchAppListForHost:host];
        }
        [self postHostsChanged];
    });
}

- (void)pairFailed:(NSString *)message {
    [self pairFailed:message generation:_pairingGeneration];
}

- (void)pairFailed:(NSString *)message generation:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_pairingGeneration) {
            return; // GP v2.5 (A-13): stale attempt — ignore.
        }
        self->_currentPairManager = nil;
        BOOL cancelled = self->_pairingCancelled;
        self->_pairingInProgress = NO;
        self->_pairingHost = nil;
        self->_pairingCancelled = NO;
        [self->_discMan startDiscovery];
        // A failure arriving after the user cancelled is expected
        // (discovery resuming disrupts the attempt) — swallow it.
        if (!cancelled && self.onPairingResult) {
            self.onPairingResult(NO, message);
        }
        [self postHostsChanged];
    });
}

- (void)alreadyPaired {
    [self alreadyPairedWithGeneration:_pairingGeneration];
}

- (void)alreadyPairedWithGeneration:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_pairingGeneration) {
            return; // GP v2.5 (A-13): stale attempt — ignore.
        }
        self->_currentPairManager = nil;
        TemporaryHost *host = self->_pairingHost ?: self->_selectedHost;
        self->_pairingInProgress = NO;
        self->_pairingHost = nil;
        // Discovery was stopped before the pairing attempt began.
        [self->_discMan startDiscovery];
        if (self.onPairingResult) {
            self.onPairingResult(YES, nil);
        }
        if (host != nil) {
            [self fetchAppListForHost:host];
        }
    });
}

#pragma mark - App list (upstream: alreadyPaired + updateApplist:forHost:)

- (void)fetchAppListForHost:(TemporaryHost *)host {
    // Serve the cached list immediately when we have one (upstream).
    if (host.appList.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self postAppListChanged:host];
            // GP v2.5 (A-63/A-56): serving the cached list also
            // recovers missing box art; stop queued retrievers first.
            [self->_assetManager stopRetrieving];
            [self->_assetManager retrieveAssetsFromHost:host];
        });
    }

    // GP v2.5 (A-11): coalesce concurrent app-list fetches per host.
    NSString *fetchKey = [self hostKeyForHost:host];
    @synchronized (_fetchInFlight) {
        if ([_fetchInFlight containsObject:fetchKey]) {
            return;
        }
        [_fetchInFlight addObject:fetchKey];
    }
    NSUInteger generation = [self generationForHostKey:fetchKey];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Exempt this host from discovery while handling the query.
        [self->_discMan pauseDiscoveryForHost:host];
        AppListResponse *appListResp = [ConnectionHelper getAppListForHost:host];
        [self->_discMan resumeDiscoveryForHost:host];

        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self->_fetchInFlight) {
                    [self->_fetchInFlight removeObject:fetchKey];
                }
                // GP v2.5 (A-55): never apply a stale failure.
                if (![self failureIsCurrentForHost:host generation:generation key:fetchKey]) {
                    return;
                }
                // GP: the failure is recorded and posted so the
                // screens show an honest state with Retry, where
                // upstream shows an alert and drops to host selection.
                self->_appListErrors[host.uuid] =
                    appListResp.statusMessage ?: @"Could not load the game list.";
                host.state = StateOffline; // upstream does this too
                [self postAppListChanged:host];
                [self postHostsChanged];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self->_fetchInFlight) {
                [self->_fetchInFlight removeObject:fetchKey];
            }
            [self updateAppList:[appListResp getAppList] forHost:host];
            [self->_appListErrors removeObjectForKey:host.uuid];
            [self postAppListChanged:host];
            [self postHostsChanged];
            // GP: with a fresh app list in hand, fetch any box art
            // the host serves that isn't already cached on disk
            // (upstream calls retrieveAssetsFromHost the same way;
            // the retrievers run in the background, max 4 at once).
            // GP v2.5 (A-56): stop any previous retrieval first, as
            // upstream does in alreadyPaired.
            [self->_assetManager stopRetrieving];
            [self->_assetManager retrieveAssetsFromHost:host];
        });
    });
}

/// AppAssetCallback — a box-art file has landed in the on-disk
/// cache (AppAssetRetriever delivers this on the main thread).
/// The screens re-render through the normal app-list notification;
/// arrivals are coalesced so a burst of covers produces one
/// rebuild, not one per image (and the screens' own scroll-aware
/// deferral holds it until scrolling ends regardless).
- (void)receivedAssetForApp:(TemporaryApp *)app {
    [self receivedAssetForApp:app success:YES];
}

- (void)receivedAssetForApp:(TemporaryApp *)app success:(BOOL)success {
    // GP v2.5 (A-65): failures write nothing, so they must not
    // trigger a rebuild; and the coalesced post re-captures a
    // non-nil host from any arrival during the window.
    if (!success) {
        return;
    }
    if (app.host != nil) {
        _assetRefreshHost = app.host;
    }
    if (_assetRefreshScheduled) {
        return;
    }
    _assetRefreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_assetRefreshScheduled = NO;
        TemporaryHost *host = self->_assetRefreshHost;
        self->_assetRefreshHost = nil;
        if (host != nil) {
            [self postAppListChanged:host];
        }
    });
}

- (NSString *)appListErrorForHost:(TemporaryHost *)host {
    return _appListErrors[host.uuid];
}

/// Upstream updateApplist:forHost:, verbatim apart from the name.
- (void)updateAppList:(NSSet *)newList forHost:(TemporaryHost *)host {
    DataManager *database = [[DataManager alloc] init];
    NSMutableSet *newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp *app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp *savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }

    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;

        for (TemporaryApp *app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp *mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                [newHostAppList removeObject:app];

                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];

                break;
            }
        }

        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);

    host.appList = newHostAppList;

    [database updateAppsForExistingHost:host];
}

#pragma mark - Host actions (upstream: hostLongClicked menu)

- (void)wakeHost:(TemporaryHost *)host {
    if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [WakeOnLanManager wakeHost:host];
    });
}

- (void)removeHost:(TemporaryHost *)host {
    // GP v2.5 (A-62): all state mutated here is main-queue state —
    // dispatch to main at entry when called from anywhere else.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeHost:host];
        });
        return;
    }
    [_discMan removeHostFromDiscovery:host];
    DataManager *dataMan = [[DataManager alloc] init];
    [dataMan removeHost:host];
    NSMutableArray<TemporaryHost *> *remaining = [_hosts mutableCopy];
    [remaining removeObject:host];
    _hosts = [remaining copy];
    if (_selectedHost.uuid != nil && [_selectedHost.uuid isEqualToString:host.uuid]) {
        _selectedHost = nil;
    }
    [_appListErrors removeObjectForKey:host.uuid];
    [_pingSamplesMs removeObjectForKey:host.uuid];
    if (_pairingHost != nil && [_pairingHost.uuid isEqualToString:host.uuid]) {
        _pairingHost = nil;
        _pairingGeneration += 1;
        [_currentPairManager cancel];
        _currentPairManager = nil;
        _pairingInProgress = NO;
    }
    // Invalidate any in-flight activation/fetch for this host (A-55).
    [self bumpGenerationForHostKey:[self hostKeyForHost:host]];
    [self postHostsChanged];
}

- (void)addHostAtAddress:(NSString *)address
              completion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self->_discMan discoverHost:address withCallback:^(TemporaryHost *host, NSString *error) {
            if (host != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // GP: persist now; upstream relies on the
                    // discovery worker's next poll to save it.
                    DataManager *dataMan = [[DataManager alloc] init];
                    [dataMan updateHost:host];
                    if ([self hostWithUUID:host.uuid] == nil) {
                        NSMutableArray<TemporaryHost *> *merged = [self->_hosts mutableCopy];
                        [merged addObject:host];
                        self->_hosts = [self sortedHosts:merged];
                    }
                    self->_selectedHost = [self hostWithUUID:host.uuid] ?: host;
                    [self postHostsChanged];
                    completion(YES, nil);
                });
            }
            else if ([error isEqualToString:@"Host information updated"]) {
                // discoverHost's way of saying "already known" —
                // upstream surfaces it as an error dialog; GP
                // treats it as the success it is.
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(YES, nil);
                });
            }
            else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, error ?: @"PC not found at that address.");
                });
            }
        }];
    });
}

#pragma mark - Running app & quit (upstream: findRunningApp + quit flow)

- (TemporaryApp *)runningAppForHost:(TemporaryHost *)host {
    for (TemporaryApp *app in host.appList) {
        if ([app.id isEqualToString:host.currentGame]) {
            return app;
        }
    }
    return nil;
}

- (void)quitApp:(TemporaryApp *)app
         onHost:(TemporaryHost *)host
     completion:(void (^)(BOOL))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        HttpRequest *quitRequest = [HttpRequest requestForResponse:quitResponse
                                                   withUrlRequest:[hMan newQuitAppRequest]];

        // Exempt this host from discovery while handling the quit.
        [self->_discMan pauseDiscoveryForHost:host];
        [hMan executeRequestSynchronously:quitRequest];
        if (quitResponse.statusCode == 200) {
            ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                              withUrlRequest:[hMan newServerInfoRequest:false]
                                                               fallbackError:401
                                                             fallbackRequest:[hMan newHttpServerInfoRequest]]];
            if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                // On newer host versions, the quit request succeeds even though the app doesn't
                // really quit if another client tries to kill your app. Patch the response to
                // look like an error in that case, so the UI behaves (upstream's reasoning).
                quitResponse.statusCode = 599;
            }
            else if ([serverInfoResp isStatusOk]) {
                [serverInfoResp populateHost:host];
            }
        }
        [self->_discMan resumeDiscoveryForHost:host];

        BOOL success = (quitResponse.statusCode == 200);
        if (success) {
            host.currentGame = @"0";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self postHostsChanged];
            completion(success);
        });
    });
}

#pragma mark - Stream launch (upstream: prepareToStreamApp: + createStreamFrame segue)

- (UIViewController *)streamViewControllerForApp:(TemporaryApp *)app {
    StreamConfiguration *config = [self streamConfigForApp:app];
    if (config == nil) {
        return nil;
    }
    NSString *storyboardName = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? @"iPad" : @"iPhone";
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
    StreamFrameViewController *streamFrame =
        [storyboard instantiateViewControllerWithIdentifier:@"streamFrame"];
    // The one assignment upstream's prepareForSegue: performs.
    streamFrame.streamConfig = config;
    return streamFrame;
}

/// Upstream prepareToStreamApp:, verbatim apart from building and
/// returning a local configuration instead of setting an ivar.
- (StreamConfiguration *)streamConfigForApp:(TemporaryApp *)app {
    if (app.host == nil) {
        return nil;
    }
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    streamConfig.host = app.host.activeAddress;
    streamConfig.httpsPort = app.host.httpsPort;
    streamConfig.appID = app.id;
    streamConfig.appName = app.name;
    streamConfig.serverCert = app.host.serverCert;

    DataManager *dataMan = [[DataManager alloc] init];
    TemporarySettings *streamSettings = [dataMan getSettings];

    streamConfig.frameRate = [streamSettings.framerate intValue];
    if (@available(iOS 10.3, *)) {
        // Don't stream more FPS than the display can show
        if (streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
            streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
            Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", streamConfig.frameRate);
        }
    }

    streamConfig.height = [streamSettings.height intValue];
    streamConfig.width = [streamSettings.width intValue];
#if TARGET_OS_TV
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && streamConfig.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        streamConfig.width = 1920;
        streamConfig.height = 1080;
    }
#endif

    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.useFramePacing = streamSettings.useFramePacing;
    streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:streamConfig];

    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);

    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;

    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through

        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through

        case CODEC_PREF_H264:
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((streamConfig.width > 4096 || streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;

        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif

    return streamConfig;
}

- (void)noteStreamStarted {
    _streamActive = YES;
    // Upstream's front-end disappears when the stream is pushed,
    // which stops its discovery. Mirror that here.
    [_discMan stopDiscovery];
    [self cancelScanSynchronously];
}

- (void)noteStreamEnded {
    _streamActive = NO;
    // Upstream beginForegroundRefresh.
    [_discMan resetDiscoveryState];
    [_discMan startDiscovery];
    [self scanLocalNetworkForce:NO];
    if (_selectedHost != nil && _selectedHost.pairState == PairStatePaired) {
        // skipFastPath: upstream deliberately re-fetches server info
        // after streaming so the current-game state is correct.
        [self activateHost:_selectedHost userInitiated:NO skipFastPath:YES];
    }
}

#pragma mark - Ping

- (NSInteger)lastPingMsForHost:(TemporaryHost *)host {
    NSArray<NSNumber *> *samples = _pingSamplesMs[host.uuid];
    if (samples.count == 0) {
        return -1;
    }
    NSInteger total = 0;
    for (NSNumber *sample in samples) {
        total += sample.integerValue;
    }
    return total / (NSInteger)samples.count;
}

#pragma mark - Helpers

- (NSArray<TemporaryHost *> *)sortedHosts:(NSArray<TemporaryHost *> *)hosts {
    return [hosts sortedArrayUsingSelector:@selector(compareName:)];
}

- (TemporaryHost *)hostWithUUID:(NSString *)uuid {
    if (uuid == nil) {
        return nil;
    }
    for (TemporaryHost *host in _hosts) {
        if ([host.uuid isEqualToString:uuid]) {
            return host;
        }
    }
    return nil;
}

- (void)reresolveSelection {
    if (_selectedHost != nil) {
        _selectedHost = [self hostWithUUID:_selectedHost.uuid] ?: _selectedHost;
    }
    if (_pairingHost != nil) {
        _pairingHost = [self hostWithUUID:_pairingHost.uuid] ?: _pairingHost;
    }
}

/// A cheap fingerprint of everything the screens render from the
/// host list. Discovery polls that change nothing produce the same
/// signature and are dropped in updateAllHosts:.
- (NSString *)hostsSignature:(NSArray<TemporaryHost *> *)hosts {
    NSMutableString *signature = [NSMutableString string];
    for (TemporaryHost *host in hosts) {
        // GP v2.5 (A-09): every rendered/launch-relevant field —
        // codec support, HTTPS port, MAC, addresses, a hash of the
        // server cert, and the app list's CONTENTS (id+name+HDR per
        // app, sorted), not just its count.
        NSUInteger certHash = 2166136261u;
        const unsigned char *certBytes = [host.serverCert bytes];
        for (NSUInteger i = 0; i < [host.serverCert length]; i++) {
            certHash ^= certBytes[i];
            certHash *= 16777619u;
        }
        NSMutableString *appsSignature = [NSMutableString string];
        NSArray<TemporaryApp *> *apps = [host.appList sortedArrayUsingComparator:
            ^NSComparisonResult(TemporaryApp *a, TemporaryApp *b) {
                NSComparisonResult byId = [(a.id ?: @"") compare:(b.id ?: @"")];
                return byId != NSOrderedSame ? byId : [(a.name ?: @"") compare:(b.name ?: @"")];
            }];
        for (TemporaryApp *app in apps) {
            [appsSignature appendFormat:@"%@=%@/%d,", app.id ?: @"", app.name ?: @"", app.hdrSupported ? 1 : 0];
        }
        [signature appendFormat:@"%@|%@|%d|%d|%@|%d|%hu|%@|%@|%@|%@|%@|%lu|%@;",
         host.uuid ?: @"", host.name ?: @"", (int)host.state, (int)host.pairState,
         host.currentGame ?: @"", host.serverCodecModeSupport, host.httpsPort,
         host.mac ?: @"", host.localAddress ?: @"", host.externalAddress ?: @"",
         host.ipv6Address ?: @"", host.activeAddress ?: @"",
         (unsigned long)certHash, appsSignature];
    }
    if (_selectedHost != nil) {
        [signature appendFormat:@"sel:%@", _selectedHost.uuid ?: @""];
    }
    return signature;
}

- (void)postHostsChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:GPHostsChangedNotification object:self];
}

- (void)postAppListChanged:(TemporaryHost *)host {
    [[NSNotificationCenter defaultCenter] postNotificationName:GPAppListChangedNotification object:host];
}

- (void)postHostInfoError:(TemporaryHost *)host message:(NSString *)message {
    [[NSNotificationCenter defaultCenter] postNotificationName:GPHostInfoErrorNotification
                                                        object:host
                                                      userInfo:@{GPHostInfoErrorMessageKey: message}];
}

@end
