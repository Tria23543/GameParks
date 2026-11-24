//
//  AppAssetResponse.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppAssetResponse.h"

@implementation AppAssetResponse
@synthesize data, statusCode, statusMessage;

- (void)populateWithData:(NSData *)imageData {
    // GP v2.5 (A-02/A-117): only the body arrives here. The real HTTP
    // status is populated by HttpManager from the NSHTTPURLResponse
    // immediately after this call; do not fabricate one.
    self.data = imageData;
    self.statusMessage = nil;
    self.statusCode = -1;
}

@end
