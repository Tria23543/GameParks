//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"

#include "Limelight.h"

// GameParks: how the video layer is fitted into the stream view.
// Fit keeps the whole picture (letterbox); Fill crops to cover the
// screen; Stretch distorts to the screen exactly; the Lock modes
// letterbox to a fixed ratio instead of the stream's own. The mode
// only changes the math inside updateDisplayLayerGeometry — that
// method remains the single writer of the layer's geometry.
typedef NS_ENUM(NSInteger, GPDisplayMode) {
    GPDisplayModeFit = 0,
    GPDisplayModeFill,
    GPDisplayModeStretch,
    GPDisplayModeLock16x9,
    GPDisplayModeLock4x3,
    GPDisplayModeLock21x9,
};

@interface VideoDecoderRenderer : NSObject

// GameParks: the display mode applied by updateDisplayLayerGeometry.
// Written by the stream screen (from the persisted setting and the
// in-stream menu); read only inside updateDisplayLayerGeometry.
@property (nonatomic) GPDisplayMode gpDisplayMode;

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;

// GameParks: recomputes the display layer's bounds/position from the
// stream view's current bounds. Called by StreamView.layoutSubviews
// whenever the view's size changes (e.g. rotation into landscape).
- (void)updateDisplayLayerGeometry;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

@end
