//
//  DiscoveryManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "MDNSManager.h"
#import "TemporaryHost.h"

@protocol DiscoveryCallback <NSObject>

- (void) updateAllHosts:(NSArray*)hosts;

@end

@interface DiscoveryManager : NSObject <MDNSCallback>

- (id) initWithHosts:(NSArray*)hosts andCallback:(id<DiscoveryCallback>) callback;
- (void) startDiscovery;
- (void) stopDiscovery;
- (void) stopDiscoveryBlocking;
- (void) resetDiscoveryState;
- (BOOL) addHostToDiscovery:(TemporaryHost*)host;
- (void) removeHostFromDiscovery:(TemporaryHost*)host;
- (void) pauseDiscoveryForHost:(TemporaryHost *)host;
- (void) resumeDiscoveryForHost:(TemporaryHost *)host;
- (void) discoverHost:(NSString*)hostAddress withCallback:(void (^)(TemporaryHost*, NSString*))callback;
// GP v2.5 (A-57): token-aware variant. shouldAddToDiscovery is consulted
// immediately before the host would be added to the discovery queue; if
// it returns NO, the add (and its updateAllHosts side effect) is skipped
// and the callback receives (nil, @"Discovery superseded").
- (void) discoverHost:(NSString*)hostAddress withCallback:(void (^)(TemporaryHost*, NSString*))callback shouldAddToDiscovery:(BOOL (^)(void))shouldAddToDiscovery;

@end
