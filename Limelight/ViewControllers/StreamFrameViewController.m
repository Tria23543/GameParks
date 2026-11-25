//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "GPSessionController.h"
#import "Moonlight-Swift.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
// GameParks v2.11: the in-stream menu (GPStreamPanelViewController,
// Swift) reports its live effects through this delegate.
@interface StreamFrameViewController () <GPStreamPanelDelegate>
- (void)gpSizeMenuButton;
@end
#endif

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    // GameParks: visible in-stream exit affordance (upstream's only
    // exits are an edge swipe and a gamepad combo — undiscoverable).
    UIButton *_exitButton;
    // GameParks v2.11: the in-stream menu button, a sibling pill
    // next to the exit pill. It is view chrome, not part of the
    // on-screen controls, so it stays reachable when the virtual
    // gamepad is hidden.
    UIButton *_menuButton;
    // GameParks v2.12: the XStreaming-style stats strip — a
    // full-width bar pinned to the top of the screen carrying one
    // horizontal row of stats. It replaces the v2.11 top-left
    // stats chip; the connection warnings keep their own overlay
    // view. Created with the other stream chrome (iOS only).
    UIView *_statsStrip;
    UILabel *_statsLabel;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    // GameParks: last size seen by viewWillLayoutSubviews, used to
    // refit the absolute-mode scroll view only when the size changes.
    CGSize _gpLastLayoutSize;
    // A-33: the pop gesture's enabled value before this screen
    // disabled it, restored verbatim on disappear.
    BOOL _gpSavedPopGestureEnabled;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

// GameParks: the stream is landscape-only. Every other screen in the
// app is portrait; the app delegate resolves the top view controller's
// mask, so these two methods are what switch the app to landscape for
// the duration of a stream.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    return UIInterfaceOrientationLandscapeRight;
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Only enable scroll and zoom in absolute touch mode
    if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];

#if !TARGET_OS_TV
    // GameParks: a visible, always-present way out of the stream.
    // Upstream's exits are a left-edge swipe (whose tip label hides
    // as soon as the stream connects) and a gamepad button combo —
    // neither is discoverable for a first-time user. This button is
    // the obvious one-tap exit; it performs the same return as the
    // edge swipe. Positioned in viewWillLayoutSubviews.
    _exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_exitButton setTitle:@"✕ End Stream" forState:UIControlStateNormal];
    [_exitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _exitButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _exitButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    // A-32: pad to at least the 44 pt touch-target height.
    _exitButton.layer.cornerRadius = 22;
    _exitButton.contentEdgeInsets = UIEdgeInsetsMake(14, 16, 14, 16);
    [_exitButton addTarget:self action:@selector(exitButtonPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_exitButton];

    // GameParks v2.11: the in-stream menu button — same pill chrome
    // as the exit button, added to this view (never to the stream
    // view), so it is not part of the virtual gamepad and stays
    // visible and tappable when the gamepad is hidden. Its touches
    // are handled by the button itself; nothing reaches the stream
    // view's input handlers. Positioned with the exit pill as a
    // centred pair in viewWillLayoutSubviews.
    _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_menuButton setTitle:@"☰" forState:UIControlStateNormal];
    [_menuButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _menuButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _menuButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    _menuButton.layer.cornerRadius = 22;
    _menuButton.accessibilityLabel = @"Stream menu";
    [_menuButton addTarget:self action:@selector(menuButtonPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_menuButton];

    // GameParks v2.12: the stats strip — XStreaming's PerfPanel
    // horizontal style: translucent black at 0.7 panel opacity,
    // square corners, 10 pt white text, the row centred, 2 pt
    // padding. Hidden unless the stats overlay is on; its frame
    // is set in viewWillLayoutSubviews. It never takes touches.
    _statsStrip = [[UIView alloc] init];
    _statsStrip.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    _statsStrip.alpha = 0.7;
    _statsStrip.userInteractionEnabled = NO;
    _statsStrip.hidden = YES;
    _statsLabel = [[UILabel alloc] init];
    _statsLabel.font = [UIFont systemFontOfSize:10];
    _statsLabel.textColor = [UIColor whiteColor];
    _statsLabel.textAlignment = NSTextAlignmentCenter;
    _statsLabel.userInteractionEnabled = NO;
    [_statsStrip addSubview:_statsLabel];
    [self.view addSubview:_statsStrip];
#endif
}

- (void)exitButtonPressed {
    Log(LOG_I, @"User tapped End Stream button");

    [self returnToMainFrame];
}

#if !TARGET_OS_TV
// GameParks v2.11: size the menu pill to the exit pill's 44 pt
// height with the same 16 pt side padding, by frame — reusing the
// exit pill's contentEdgeInsets would add a second instance of
// that property's deprecation warning to the build.
- (void)gpSizeMenuButton {
    [_menuButton sizeToFit];
    CGRect frame = _menuButton.frame;
    frame.size.height = 44;
    frame.size.width += 32;
    _menuButton.frame = frame;
}

- (void)menuButtonPressed {
    // Tapping the hamburger with the menu already open closes it.
    if (self.presentedViewController != nil) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    GPStreamPanelViewController *panel = [[GPStreamPanelViewController alloc] init];
    panel.delegate = self;
    panel.modalPresentationStyle = UIModalPresentationOverFullScreen;
    panel.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:panel animated:YES completion:nil];
}

#pragma mark - GPStreamPanelDelegate (GameParks v2.11)

- (void)streamPanelDidChangeAspectMode:(NSInteger)mode {
    // The mode is already persisted by the panel (GPSettingsStore).
    // Apply it to the live renderer; updateDisplayLayerGeometry
    // stays the only writer of the layer's geometry. Before the
    // connection starts there is no renderer yet — the persisted
    // value is applied in connectionStarted instead.
    VideoDecoderRenderer *renderer = _streamView.videoRenderer;
    if (renderer != nil) {
        renderer.gpDisplayMode = (GPDisplayMode)mode;
        [renderer updateDisplayLayerGeometry];
    }
}

- (void)streamPanelDidChangeStatsOverlay:(BOOL)on {
    // The setting is already persisted by the panel. Drive the same
    // timer upstream's connectionStarted starts, live.
    if (on) {
        if (_statsUpdateTimer == nil) {
            _statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                 target:self
                                                               selector:@selector(updateStatsOverlay)
                                                               userInfo:nil
                                                                repeats:YES];
            [self updateStatsOverlay];
        }
        // GameParks v2.12: show the stats strip; the layout pass
        // moves the pill pair below it.
        _statsStrip.hidden = NO;
        [self.view setNeedsLayout];
    }
    else {
        [_statsUpdateTimer invalidate];
        _statsUpdateTimer = nil;
        [self updateOverlayText:nil];
        // GameParks v2.12: hide the stats strip; the layout pass
        // returns the pill pair to the top.
        _statsStrip.hidden = YES;
        [self.view setNeedsLayout];
    }
}

- (void)streamPanelDidChangeOnScreenControls {
    // The new level is already persisted by the panel; re-apply it
    // to the live controls exactly as stream setup did.
    [_streamView gpApplyOnScreenControlsFromSettings:_controllerSupport];
}

- (void)streamPanelRequestsStreamRestart {
    // The panel has already saved the new resolution/bitrate to the
    // settings store. Rebuild a stream screen for the same host/app
    // through the session's launch path (its configuration is built
    // from the current settings), then swap it into this screen's
    // place in the stack. Being removed from the stack stops this
    // stream (willMoveToParentViewController:), the game keeps
    // running on the host, and the new stream manager resumes it at
    // the new settings. The stats session and the session's
    // stream-active flag belong to the navigation flow, which only
    // closes them when the stack pops to the root — a swap does not.
    UIViewController *newStream = [[GPSessionController sharedController] streamViewControllerForRestartOfConfig:self.streamConfig];
    if (newStream == nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't restart the stream"
                                                                       message:@"Your new settings are saved and will apply next time you launch. To use them now, end the stream and launch the game again."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // The repeating stats timer retains this controller; the normal
    // exit path invalidates it in returnToMainFrame, so do the same
    // here before being removed from the stack.
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    UINavigationController *nav = self.navigationController;
    NSMutableArray<UIViewController *> *stack = [nav.viewControllers mutableCopy];
    NSUInteger index = [stack indexOfObject:self];
    if (index == NSNotFound) {
        return;
    }
    stack[index] = newStream;
    [nav setViewControllers:stack animated:NO];
}
#endif

#if !TARGET_OS_TV
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // GameParks: the navigation controller's interactive pop gesture
    // also claims the left edge and would pop back to the connecting
    // screen instead of ending the stream. Disable it while the
    // stream screen is on top so upstream's left-edge exit swipe is
    // the only edge gesture in play.
    // A-33: save the prior value; another screen may have disabled
    // the gesture for its own reasons.
    _gpSavedPopGestureEnabled = self.navigationController.interactivePopGestureRecognizer.enabled;
    self.navigationController.interactivePopGestureRecognizer.enabled = NO;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    // A-33: restore what viewWillAppear saved, not a hard-coded YES.
    self.navigationController.interactivePopGestureRecognizer.enabled = _gpSavedPopGestureEnabled;
}

// GameParks: this screen is pushed from a portrait app, so the view
// (and everything sized from it in viewDidLoad — the stream view, the
// centred labels) starts out with a portrait frame and only gets its
// landscape bounds when the interface rotates. Upstream never sees
// this because it is landscape-only from launch. Re-assert every
// frame against the current bounds on each layout pass so the stream
// fills the screen after rotation.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGRect bounds = self.view.bounds;
    BOOL sizeChanged = !CGSizeEqualToSize(bounds.size, _gpLastLayoutSize);
    // A-97: the zoom/contentSize reset below was written for the
    // portrait->landscape transition; detect that orientation-class
    // change specifically, not any size change.
    BOOL orientationClassChanged = sizeChanged && !CGSizeEqualToSize(_gpLastLayoutSize, CGSizeZero)
        && ((_gpLastLayoutSize.width > _gpLastLayoutSize.height) != (bounds.size.width > bounds.size.height));
    _gpLastLayoutSize = bounds.size;
    if (_streamView != nil) {
        // A-97: don't fight a user's pinch-zoom with a frame write.
        if (!(_scrollView != nil && _scrollView.zoomScale != 1.0)) {
            _streamView.frame = bounds;
        }
    }
    if (_scrollView != nil) {
        _scrollView.frame = bounds;
        if (orientationClassChanged) {
            // GameParks: in absolute-touch mode the stream view lives
            // inside this scroll view, which was also created with the
            // pre-rotation portrait frame. Refit its content to the
            // real bounds on a size change so the (now full-size)
            // stream view isn't rendered small through a stale
            // content size or zoom. (GameParks seeds absolute touch
            // mode off, so this branch is defensive.)
            _scrollView.contentSize = bounds.size;
            _scrollView.zoomScale = 1.0;
        }
    }
    _stageLabel.center = CGPointMake(bounds.size.width / 2, bounds.size.height / 2);
    _spinner.center = CGPointMake(bounds.size.width / 2, bounds.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    _tipLabel.center = CGPointMake(bounds.size.width / 2, bounds.size.height * 0.9);
    if (_exitButton != nil) {
        // A-32: re-size only when the bounds size actually changed.
        if (sizeChanged) {
            [_exitButton sizeToFit];
            [self gpSizeMenuButton];
        }
        // GameParks v2.12: while the stats overlay is on, the
        // stats strip owns the top of the screen and the pill pair
        // sits directly below it; with stats off the pair returns
        // to the top. Strip visibility follows the stats timer —
        // the same condition connectionStatusUpdate uses to give
        // the stats precedence over the connection warnings.
        CGFloat pairY = self.view.safeAreaInsets.top + 6;
        if (_statsStrip != nil) {
            BOOL statsOn = (_statsUpdateTimer != nil);
            _statsStrip.hidden = !statsOn;
            if (statsOn) {
                CGFloat stripHeight = ceilf(_statsLabel.font.lineHeight) + 4;
                _statsStrip.frame = CGRectMake(0, 0, bounds.size.width, stripHeight);
                _statsLabel.frame = CGRectInset(_statsStrip.bounds, 2, 2);
                pairY = stripHeight + 6;
            }
        }
        // GameParks v2.11: the exit and menu pills sit as one
        // centred pair, menu on the left.
        CGFloat pairGap = 8;
        CGFloat pairWidth = _menuButton.frame.size.width + pairGap + _exitButton.frame.size.width;
        CGRect menuFrame = _menuButton.frame;
        menuFrame.origin.x = (bounds.size.width - pairWidth) / 2;
        menuFrame.origin.y = pairY;
        _menuButton.frame = menuFrame;
        CGRect buttonFrame = _exitButton.frame;
        buttonFrame.origin.x = menuFrame.origin.x + menuFrame.size.width + pairGap;
        buttonFrame.origin.y = pairY;
        _exitButton.frame = buttonFrame;
    }
}
#endif

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_TV
        [self updateOverlayText:overlayText];
#else
        // GameParks v2.12: the stats row renders in the top stats
        // strip, not the connection-warning overlay. A nil text
        // (no complete stats window yet) leaves the last row up.
        if (overlayText != nil) {
            self->_statsLabel.text = overlayText;
        }
#endif
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        // GameParks v2.11: the overlay is a small chip in the
        // design's tokens — panel-toned, Manrope, rounded — instead
        // of upstream's centred grey block. It also carries the
        // connection warnings, which read fine in the same chip.
        [_overlayView setFont:[UIFont fontWithName:@"Manrope-SemiBold" size:12] ?: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
        [_overlayView setTextColor:[UIColor whiteColor]];
        [_overlayView setBackgroundColor:[[UIColor colorWithRed:16.0/255 green:19.0/255 blue:29.0/255 alpha:1.0] colorWithAlphaComponent:0.78]];
        _overlayView.layer.cornerRadius = 8;
        _overlayView.clipsToBounds = YES;
        [_overlayView setTextContainerInset:UIEdgeInsetsMake(6, 8, 6, 8)];
        if (_statsUpdateTimer != nil) {
            [_overlayView setTextAlignment:NSTextAlignmentLeft];
        }
#endif
#if TARGET_OS_TV
        [_overlayView setAlpha:0.5];
#else
        // GameParks v2.11: the chip's translucency lives in its
        // background colour; the text stays fully legible.
        [_overlayView setAlpha:1.0];
#endif
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
#if TARGET_OS_TV
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
#else
        // GameParks v2.11: top-left corner, below the centred
        // chrome pills, instead of upstream's top-centre.
        [_overlayView setFrame:CGRectMake(self.view.safeAreaInsets.left + 8,
                                          self.view.safeAreaInsets.top + 56,
                                          _overlayView.frame.size.width,
                                          _overlayView.frame.size.height)];
#endif
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
#if !TARGET_OS_TV
    // GameParks v2.11: if the in-stream menu is open, it leaves
    // with the stream — popping while a modal is still presented
    // would strand the panel over the root screens.
    if (self.presentedViewController != nil) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
#endif
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];

        [self->_controllerSupport connectionEstablished];

#if !TARGET_OS_TV
        // GameParks v2.11: apply the persisted display aspect mode
        // to the renderer that now exists. The mode's only other
        // writer is the in-stream menu, live.
        VideoDecoderRenderer *renderer = self->_streamView.videoRenderer;
        if (renderer != nil) {
            renderer.gpDisplayMode = (GPDisplayMode)[[NSUserDefaults standardUserDefaults] integerForKey:@"GPDisplayAspectMode"];
            [renderer updateDisplayLayerGeometry];
        }
#endif

        // GameParks v2.11: read the stats setting fresh rather than
        // from the viewDidLoad snapshot — the in-stream menu can
        // change it before the connection finishes starting, and the
        // snapshot would override the user's choice.
        if ([[[DataManager alloc] init] getSettings].statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
            // GameParks v2.12: show the stats strip; the layout
            // pass moves the pill pair below it. (The strip is
            // iOS-only chrome; on tvOS it is nil and this is a
            // no-op.)
            self->_statsStrip.hidden = NO;
            [self.view setNeedsLayout];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking GameParks. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking GameParks. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
