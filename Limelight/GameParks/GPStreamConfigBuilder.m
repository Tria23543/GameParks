//
//  GPStreamConfigBuilder.m
//  GameParks
//

#import "GPStreamConfigBuilder.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "ControllerSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <sys/utsname.h>

// This mirrors MainFrameViewController's prepareToStreamApp: line
// for line, including the Apple TV HD clamp (compiled out on iOS).
// The only deliberate divergence is the nil guard at the top.

#include <Limelight.h>

@implementation GPStreamConfigBuilder

+ (StreamConfiguration*) configForApp:(TemporaryApp*)app {
    if (app == nil || app.host == nil) {
        return nil;
    }

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    if (streamSettings == nil) {
        return nil;
    }

    StreamConfiguration* config = [[StreamConfiguration alloc] init];
    config.host = app.host.activeAddress;
    config.httpsPort = app.host.httpsPort;
    config.appID = app.id;
    config.appName = app.name;
    config.serverCert = app.host.serverCert;

    config.frameRate = [streamSettings.framerate intValue];
    if (@available(iOS 10.3, *)) {
        // Don't stream more FPS than the display can show
        if (config.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
            config.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
            Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", config.frameRate);
        }
    }

    config.height = [streamSettings.height intValue];
    config.width = [streamSettings.width intValue];
#if TARGET_OS_TV
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && config.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        config.width = 1920;
        config.height = 1080;
    }
#endif

    config.bitRate = [streamSettings.bitrate intValue];
    config.optimizeGameSettings = streamSettings.optimizeGames;
    config.playAudioOnPC = streamSettings.playAudioOnPC;
    config.useFramePacing = streamSettings.useFramePacing;
    config.swapABXYButtons = streamSettings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    config.multiController = streamSettings.multiController;
    config.gamepadMask = [ControllerSupport getConnectedGamepadMask:config];

    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);

    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        config.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        config.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    config.serverCodecModeSupport = app.host.serverCodecModeSupport;

    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through

        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through

        case CODEC_PREF_H264:
            config.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((config.width > 4096 || config.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265;

        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            config.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((config.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif

    return config;
}

@end
