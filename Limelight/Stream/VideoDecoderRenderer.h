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

@interface VideoDecoderRenderer : NSObject

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
