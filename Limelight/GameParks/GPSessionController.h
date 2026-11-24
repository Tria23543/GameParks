//
//  GPSessionController.h
//  GameParks
//
//  The single owner of everything the GameParks screens need from the
//  streaming engine: discovery, host selection, pairing, the app list,
//  Wake-on-LAN, quitting, and stream configuration/launch.
//
//  This class deliberately mirrors MainFrameViewController's non-UI
//  logic — the upstream front-end whose identical call patterns run
//  the standalone app — instead of re-inventing it. Wherever a method
//  corresponds to an upstream method, the upstream name is noted.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "TemporaryHost.h"
#import "TemporaryApp.h"

@class DiscoveryManager;

NS_ASSUME_NONNULL_BEGIN

// Notification names posted (on the main queue) for the screens.
// The userInfo of GPHostInfoErrorNotification carries the message
// under GPHostInfoErrorMessageKey; its object is the host.
extern NSNotificationName const GPHostsChangedNotification;
extern NSNotificationName const GPAppListChangedNotification;
extern NSNotificationName const GPHostInfoErrorNotification;
extern NSString * const GPHostInfoErrorMessageKey;

@interface GPSessionController : NSObject

+ (instancetype)sharedController;

/// All known hosts, sorted by name. Replaced (never mutated) when
/// discovery reports a real change.
@property (nonatomic, readonly) NSArray<TemporaryHost *> *hosts;

/// The host the screens are focused on. Re-resolved by UUID whenever
/// the host list is replaced, so it always points at a live instance.
/// GP v2.7 (C-22): readonly publicly — the synthesized setter used
/// to bypass the A-55 generation bump in setSelectedHostInternal:,
/// so external callers must go through selectHost:/activateHost:.
@property (nonatomic, readonly, nullable) TemporaryHost *selectedHost;

@property (nonatomic, readonly, nullable) DiscoveryManager *discoveryManager;

/// YES while a pairing operation is in flight.
@property (nonatomic, readonly) BOOL pairingInProgress;

// Pairing callbacks — the only single-consumer events, used by the
// pairing overlay. Always invoked on the main queue. The PIN callback
// is delivered with dispatch_sync (upstream's startPairing does the
// same) so the PIN UI exists before any failure can arrive.
@property (nonatomic, copy, nullable) void (^onPairingPIN)(NSString *pin);
@property (nonatomic, copy, nullable) void (^onPairingResult)(BOOL success, NSString *_Nullable message);

/// GP v2.6 (B-14): ownership token for the two callback slots
/// above. Whoever installs callbacks sets this to a token only it
/// holds; on teardown it restores the previous callbacks ONLY if
/// the token is still its own — otherwise a newer owner has taken
/// the slots over and must not be clobbered by a stale restore.
@property (nonatomic, strong, nullable) NSObject *pairingCallbackOwner;

/// One-time setup: crypto, saved hosts, discovery, subnet scan.
/// Mirrors MainFrameViewController's viewDidLoad.
- (void)start;

/// Sets the selection without touching the network.
- (void)selectHost:(TemporaryHost *)host;

/// Upstream hostClicked:view: minus the UI. Fast path when the host
/// is online, paired and has a cached app list; otherwise a
/// background server-info fetch, then the app list (paired) or
/// pairing (only when userInitiated, exactly like upstream).
/// skipFastPath forces the server-info round trip — used after a
/// stream ends, like upstream's post-stream refresh.
- (void)activateHost:(TemporaryHost *)host userInitiated:(BOOL)userInitiated skipFastPath:(BOOL)skipFastPath;

/// Starts pairing with the selected host (activate, user-initiated).
- (void)pairSelectedHost;

/// Upstream's pairing-alert Cancel: dismiss is the UI's job; here we
/// just restart discovery, which aborts the attempt in practice.
- (void)cancelPairing;

/// Upstream alreadyPaired: serve the cached list immediately, then
/// fetch the fresh list on a background queue. Failures are recorded
/// (see appListErrorForHost:) and posted, never silent.
- (void)fetchAppListForHost:(TemporaryHost *)host;

/// The last app-list error for this host, or nil. Cleared on success.
- (nullable NSString *)appListErrorForHost:(TemporaryHost *)host;

/// Upstream's Wake-on-LAN action from the host long-press menu.
- (void)wakeHost:(TemporaryHost *)host;

/// Upstream's Remove Host action: stops discovery for the host and
/// deletes it from the database.
- (void)removeHost:(TemporaryHost *)host;

/// Upstream addHostClicked's engine half: background discoverHost,
/// persist + merge on success. Completion runs on the main queue.
- (void)addHostAtAddress:(NSString *)address
              completion:(void (^)(BOOL success, NSString *_Nullable error))completion;

/// Runs the subnet sweep (throttled unless a sweep is due). This is
/// the LiveContainer-proof auto-discovery; Bonjour still runs via
/// DiscoveryManager in parallel and both feed the same host list.
- (void)rescanLocalNetwork;

/// Upstream findRunningApp:.
- (nullable TemporaryApp *)runningAppForHost:(TemporaryHost *)host;

/// Upstream's quit flow from the app long-press menu, including the
/// post-quit server-info verification. Completion on the main queue.
- (void)quitApp:(TemporaryApp *)app
         onHost:(TemporaryHost *)host
     completion:(void (^)(BOOL success))completion;

/// Builds the stream configuration exactly as upstream's
/// prepareToStreamApp: does, creates upstream's own
/// StreamFrameViewController from the iPhone/iPad storyboard
/// (identifier "streamFrame"), and sets its streamConfig — the one
/// assignment upstream's prepareForSegue: performs. The caller
/// pushes the returned controller onto the navigation stack,
/// exactly like upstream's push segue "createStreamFrame".
/// Returns nil if the app has no host, or if the settings record
/// is missing (GP v2.6, B-28). Call on the main queue.
- (nullable UIViewController *)streamViewControllerForApp:(TemporaryApp *)app;

/// The stream view controller was pushed / popped. Discovery pauses
/// during a stream (upstream's viewDidDisappear does this) and a
/// full refresh runs when it ends (upstream's beginForegroundRefresh).
- (void)noteStreamStarted;
- (void)noteStreamEnded;

/// Last measured server-info round trip for the host, in ms
/// (-1 when unknown). A relative indicator, like upstream's timing.
- (NSInteger)lastPingMsForHost:(TemporaryHost *)host;

@end

NS_ASSUME_NONNULL_END
