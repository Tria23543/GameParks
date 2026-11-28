//
//  OnScreenControls.h
//  Moonlight
//
//  Created by Diego Waxemberg on 12/28/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ControllerSupport;
@class StreamConfiguration;

@interface OnScreenControls : NSObject

typedef NS_ENUM(NSInteger, OnScreenControlsLevel) {
    OnScreenControlsLevelOff,
    OnScreenControlsLevelAuto,
    OnScreenControlsLevelSimple,
    OnScreenControlsLevelFull,
    
    // Internal levels selected by ControllerSupport
    OnScreenControlsLevelAutoGCGamepad,
    OnScreenControlsLevelAutoGCExtendedGamepad,
    OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons
};

- (id) initWithView:(UIView*)view controllerSup:(ControllerSupport*)controllerSupport streamConfig:(StreamConfiguration*)streamConfig;
- (BOOL) handleTouchDownEvent:(NSSet*)touches;
- (BOOL) handleTouchUpEvent:(NSSet*)touches;
- (BOOL) handleTouchMovedEvent:(NSSet*)touches;
- (void) setLevel:(OnScreenControlsLevel)level;
- (OnScreenControlsLevel) getLevel;
// GameParks: recompute the control layout from the view's current
// frame (the frame captured at init may predate a rotation).
- (void) refreshLayout;
// GameParks v2.18: the Full layout's arrangement — 0 = the layout
// GameParks has always shipped (called PS5 in the app), 1 = the
// Xbox arrangement (left stick high, D-pad below it, the ABXY
// cluster high on the right). Only the centres move; the same
// centres drive the touch handling.
- (void) setControllerLayout:(NSInteger)layout;
- (void) show;

@end
