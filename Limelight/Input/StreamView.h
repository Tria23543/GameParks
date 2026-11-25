//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

@class VideoDecoderRenderer;

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

// GameParks: the video renderer that draws into this view. Weak: the
// renderer is owned by the stream's connection machinery, not the view.
// layoutSubviews calls its updateDisplayLayerGeometry whenever this
// view's size changes, so the video refits after rotation — the same
// hook that refreshes the on-screen controls.
@property (nonatomic, weak) VideoDecoderRenderer *videoRenderer;

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;

// GameParks: re-apply the on-screen-controls level from the current
// settings record, using exactly the branch setupStreamView used at
// stream start (absolute touch mode forces Off; Auto goes through
// ControllerSupport's auto mode; anything else is set directly).
// Lets the in-stream menu show/hide the virtual gamepad live, after
// the new level has been saved to the settings store.
- (void) gpApplyOnScreenControlsFromSettings:(ControllerSupport*)controllerSupport;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
