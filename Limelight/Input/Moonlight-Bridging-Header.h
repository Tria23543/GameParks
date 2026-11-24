//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

// GameParks front-end: engine surface exposed to Swift.
// A-85: trimmed to the headers whose types Swift actually
// references (TemporaryHost/TemporaryApp/TemporarySettings via
// DataManager, DiscoveryManager for GPSubnetScanner, AppAssetManager
// for GPCatalog's box-art path, and the GPSessionController facade).
// The low-level HTTP/crypto/identity/pairing primitives are no
// longer exposed to Swift; the facade owns them.
#import "DataManager.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "TemporarySettings.h"
#import "DiscoveryManager.h"
#import "AppAssetManager.h"
#import "GPSessionController.h"
