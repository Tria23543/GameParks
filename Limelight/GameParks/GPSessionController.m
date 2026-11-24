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

@interface GPSessionController () <DiscoveryCallback, PairCallback>
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
    [dataMan saveSettingsWithBitrate:20000
                           framerate:60
                              height:1080
                               width:1920
                         audioConfig:2
                    onscreenControls:2
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
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"GPSeededSettingsV1"];
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
    }
}

- (void)appWillResignActive {
    [_discMan stopDiscovery];
    [_scanner cancel];
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
    __weak typeof(self) weakSelf = self;
    [_scanner scanWithDiscoveryManager:_discMan onHost:^(TemporaryHost *host) {
        [weakSelf adoptScannedHost:host];
    } completion:^(BOOL completed) {
        weakSelf->_scanInProgress = NO;
        if (!completed) {
            // A superseded/cancelled sweep must not throttle the
            // next real attempt for the full interval.
            weakSelf->_lastScanStart = nil;
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

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for the PC's status to be known (upstream does this).
        while (host.state == StateUnknown) {
            sleep(1);
        }

        // Don't bother polling if the server is already offline.
        if (host.state == StateOffline) {
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
            dispatch_async(dispatch_get_main_queue(), ^{
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
    if (_pairingInProgress) {
        return;
    }
    _pairingInProgress = YES;
    _pairingCancelled = NO;
    _pairingHost = host;

    // Polling the server while pairing causes the server to screw
    // up, so discovery stops completely first (upstream's words).
    [_discMan stopDiscoveryBlocking];

    PairManager *pMan = [[PairManager alloc] initWithManager:hMan clientCert:_clientCert callback:self];
    if (pMan == nil) {
        _pairingInProgress = NO;
        _pairingHost = nil;
        [_discMan startDiscovery];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onPairingResult) {
                self.onPairingResult(NO, @"Pairing could not start. Try again.");
            }
        });
        return;
    }
    [_opQueue addOperation:pMan];
}

- (void)cancelPairing {
    _pairingCancelled = YES;
    _pairingInProgress = NO;
    [_discMan startDiscovery];
}

- (void)startPairing:(NSString *)PIN {
    // Needs to be synchronous to ensure the PIN UI is shown before
    // any potential failure callback could be invoked (upstream).
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.onPairingPIN) {
            self.onPairingPIN(PIN);
        }
    });
}

- (void)pairSuccessful:(NSData *)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
        });
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Exempt this host from discovery while handling the query.
        [self->_discMan pauseDiscoveryForHost:host];
        AppListResponse *appListResp = [ConnectionHelper getAppListForHost:host];
        [self->_discMan resumeDiscoveryForHost:host];

        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
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
            [self updateAppList:[appListResp getAppList] forHost:host];
            [self->_appListErrors removeObjectForKey:host.uuid];
            [self postAppListChanged:host];
            [self postHostsChanged];
        });
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
    [_scanner cancel];
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
        [signature appendFormat:@"%@|%@|%d|%d|%@|%lu|%@;",
         host.uuid ?: @"", host.name ?: @"", (int)host.state, (int)host.pairState,
         host.currentGame ?: @"", (unsigned long)host.appList.count,
         host.activeAddress ?: @""];
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
