//
//  AppAssetRetriever.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/31/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppAssetRetriever.h"
#import "HttpManager.h"
#import "CryptoManager.h"
#import "AppAssetResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"
#import <UIKit/UIKit.h>

@implementation AppAssetRetriever
static const double RETRY_DELAY = 2; // seconds
static const int MAX_ATTEMPTS = 5;

- (void) main {
    BOOL success = NO;
    // GP v2.7 (C-05): the outcome this operation reports to the
    // manager when it finishes. Only DefinitiveNoArt (a 4xx, or a
    // final 200 whose body never decodes) may stamp the no-art
    // memory; transport errors, 5xx and write failures stay
    // OtherFailure so a recovered host is re-asked on the next
    // trigger instead of being suppressed for an hour.
    AppAssetRetrievalOutcome outcome = AppAssetRetrievalOutcomeOtherFailure;
    int attempts = 0;
    while (![self isCancelled] && attempts++ < MAX_ATTEMPTS) {
        HttpManager* hMan = [[HttpManager alloc] initWithHost:_host];
        AppAssetResponse* appAssetResp = [[AppAssetResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appAssetResp withUrlRequest:[hMan newAppAssetRequestWithAppId:self.app.id]]];

        // Whether THIS attempt proved the host has no art for this
        // app via a 200 with an undecodable body; reset per attempt
        // so only the final attempt's result decides the outcome if
        // the retry budget runs out.
        BOOL attemptProvedNoArt = NO;

        // GP v2.7 (C-09, also the B-20 re-open): the HTTP status
        // check is hoisted ABOVE the data check. A 4xx is permanent
        // — retrying cannot help — so break at once, regardless of
        // whether the response carried a body. (Previously the
        // break sat inside if (data != nil) and data was forced nil
        // for empty bodies, so Sunshine's normal no-art shape — a
        // bare 404 with no body — was retried all 5 attempts.)
        NSInteger statusCode = appAssetResp.statusCode;
        if (statusCode >= 400 && statusCode < 500) {
            outcome = AppAssetRetrievalOutcomeDefinitiveNoArt;
            break;
        }

        // GP v2.6 (B-02): an empty body is no body at all — v2.5's
        // data != nil test let a 0-byte 200 response be written as a
        // "cover" that no existence check would ever re-fetch.
        NSData *data = (appAssetResp.data.length > 0) ? appAssetResp.data : nil;
        if (statusCode == 200 && data != nil) {
            // GP v2.5 (A-02): only a real 200 body is box art. An error
            // body must never be cached. (5xx and transport failures
            // fall past this block to the retry below: a 5xx —
            // Sunshine busy or restarting — is transient and uses the
            // existing attempt budget.)
            // GP v2.6 (B-02): status alone is not enough — only
            // bytes that actually decode as an image may be
            // written as box art. A 200 HTML/XML error page or a
            // truncated body must never reach the disk cache.
            UIImage *probe = [UIImage imageWithData:data];
            // GP v2.7 (C-04): UIImage decoding is lazy and -size
            // comes from the header, so the old probe let a
            // header-valid truncated body pass. Force a real decode
            // by rendering the probe into a bitmap context; a failed
            // render means the body does not decode and must not be
            // written.
            // GP v2.8 (D-02): the render is capped like the display
            // side (GPCatalog's B-11 cap, ~10 MP): a probe whose
            // pixel count exceeds the cap — or whose dimensions are
            // zero/negative — is rejected BEFORE any bitmap is
            // allocated, so a hostile or corrupt header cannot force
            // a huge allocation. The rejection is a transient
            // OtherFailure, never DefinitiveNoArt: the host may well
            // have art, just art this side will not render.
            // GP v2.8 (D-03): the probe draws into a raw CGContext
            // over a zero-filled buffer (premultipliedLast, mirroring
            // the display side) and scans the bytes afterwards:
            // "decodable" means at least one non-zero byte appeared.
            // The old UIGraphics probe could not detect a raster
            // that decoded nothing — its opaque, pre-filled context
            // always yielded an image. Composition: an opaque image
            // always sets alpha bytes 0xFF, so all-black opaque art
            // still passes; a fully transparent image scans all-zero
            // and fails (accepted — it is invisible art, and the
            // display side no longer deletes for an all-zero raster,
            // D-04). The C-04 limit is unchanged: a truncated body
            // rasterising partial non-blank pixels still passes.
            BOOL decodable = NO;
            BOOL probeRejected = NO;
            if (probe != nil) {
                double pixelCount = (double)probe.size.width * (double)probe.size.height;
                if (probe.size.width <= 0 || probe.size.height <= 0 || pixelCount > 10000000) {
                    probeRejected = YES;
                } else {
                    NSUInteger probeWidth = (NSUInteger)llround(probe.size.width);
                    NSUInteger probeHeight = (NSUInteger)llround(probe.size.height);
                    CGImageRef cgImage = probe.CGImage;
                    if (cgImage != NULL && probeWidth > 0 && probeHeight > 0) {
                        size_t bytesPerRow = probeWidth * 4;
                        // calloc: the buffer starts zero-filled, so
                        // any non-zero byte after the draw was put
                        // there by the raster.
                        unsigned char *buffer = calloc(probeHeight, bytesPerRow);
                        if (buffer != NULL) {
                            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                            CGContextRef context = CGBitmapContextCreate(buffer, probeWidth, probeHeight, 8, bytesPerRow, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
                            CGColorSpaceRelease(colorSpace);
                            if (context != NULL) {
                                CGContextDrawImage(context, CGRectMake(0, 0, probeWidth, probeHeight), cgImage);
                                size_t byteCount = bytesPerRow * probeHeight;
                                for (size_t index = 0; index < byteCount; index++) {
                                    if (buffer[index] != 0) {
                                        decodable = YES;
                                        break;
                                    }
                                }
                                CGContextRelease(context);
                            }
                            free(buffer);
                        }
                    }
                }
            }
            if (decodable) {
                // GP v2.5 (A-64): a cancelled retriever must not write.
                if ([self isCancelled]) {
                    break;
                }
                // GP v2.7 (C-01): a retriever created before an
                // app-list signature change must not write its
                // pre-change art after the change, even if the
                // cancellation landed after the isCancelled check
                // above — the manager bumped the host's art epoch
                // when the signature changed, so a moved epoch
                // skips the write (the manager has already queued
                // a fresh retriever for the current art).
                if (self.artEpochStillCurrentBlock != nil && !self.artEpochStillCurrentBlock()) {
                    break;
                }
                // GP v2.5 (A-67): path from the host this retriever was
                // given (_host), via the manager's host-explicit variant.
                NSString* boxArtPath = [AppAssetManager boxArtPathForApp:self.app host:_host];
                [[NSFileManager defaultManager] createDirectoryAtPath:[boxArtPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                // GP v2.5 (A-04): atomic write, result checked; the
                // callback below reports success only when this wrote.
                success = [data writeToFile:boxArtPath atomically:YES];
                // GP v2.8 (D-01): the pre-write checks above are a
                // check-then-write window — a signature change (or
                // cancellation) landing between them and the atomic
                // write would still bless pre-change art. Re-check
                // both immediately AFTER a successful write and, if
                // stale or cancelled, delete the just-written file
                // and report the write as failed: success = NO makes
                // the callback report failure, and OtherFailure
                // below can neither stamp the no-art memory (only
                // DefinitiveNoArt may) nor be read as a genuine
                // fetch success (only WroteFile is).
                if (success && ([self isCancelled] || (self.artEpochStillCurrentBlock != nil && !self.artEpochStillCurrentBlock()))) {
                    [[NSFileManager defaultManager] removeItemAtPath:boxArtPath error:nil];
                    success = NO;
                }
                if (success) {
                    outcome = AppAssetRetrievalOutcomeWroteFile;
                } else {
                    // A write failure is a transient failure, never
                    // proof of no art — clear any definitive outcome
                    // an earlier attempt in this loop recorded.
                    outcome = AppAssetRetrievalOutcomeOtherFailure;
                }
                break;
            }
            // A 200 whose body does not decode: possibly a truncated
            // transfer that completes on a retry, so fall through to
            // the retry below — but remember this attempt proved
            // no-art, so if the budget runs out on undecodable 200s
            // the outcome is definitive (GP v2.7, C-05).
            // GP v2.8 (D-02): a probe rejected for size/dimensions
            // proved nothing about art existing — it must not set
            // this flag, so its outcome stays OtherFailure.
            if (!probeRejected) {
                attemptProvedNoArt = YES;
            }
        }

        if (attemptProvedNoArt) {
            outcome = AppAssetRetrievalOutcomeDefinitiveNoArt;
        } else if (outcome == AppAssetRetrievalOutcomeDefinitiveNoArt) {
            // A later attempt failed some other way (transport, 5xx,
            // empty body): the undecodable-200 evidence is stale.
            outcome = AppAssetRetrievalOutcomeOtherFailure;
        }

        // GP v2.7 (C-26): sleep only when another attempt will
        // actually follow — after the final failed attempt the old
        // code still slept the full delay, holding a queue slot
        // ~2 s longer than necessary.
        if (![self isCancelled] && attempts < MAX_ATTEMPTS) {
            [NSThread sleepForTimeInterval:RETRY_DELAY];
        }
    }
    self.retrievalOutcome = outcome;
    // GP v2.5 (A-65): report success/failure, not unconditional success.
    BOOL wrote = success;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.callback respondsToSelector:@selector(receivedAssetForApp:success:)]) {
            [self.callback receivedAssetForApp:self.app success:wrote];
        } else {
            [self.callback receivedAssetForApp:self.app];
        }
    });
}

@end
