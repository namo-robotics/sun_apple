/** Tests live composition, camera motion on a still desktop, and MP4 finalization without device access. */
#import "../src/native/movie.h"
#include <unistd.h>
#include <math.h>

/** Allocates a solid BGRA test frame independent of camera and screen permissions. */
static CVPixelBufferRef frame(int width, int height, unsigned char red, unsigned char blue) {
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &buffer) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    unsigned char *base = CVPixelBufferGetBaseAddress(buffer);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        unsigned char *pixel = base + y * CVPixelBufferGetBytesPerRow(buffer) + 4*x;
        pixel[0] = blue; pixel[1] = 0; pixel[2] = red; pixel[3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

/** Generates one short PCM tone packet on the same host-clock timeline as screen frames. */
static CMSampleBufferRef audio(CMTime time, int packet) {
    AudioStreamBasicDescription description = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0};
    CMAudioFormatDescriptionRef format = NULL;
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMAudioFormatDescriptionCreate(NULL, &description, 0, NULL, 0, NULL, NULL, &format)) return NULL;
    if (!CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 1920, NULL, NULL, 0, 1920, 0, &block) &&
        !CMBlockBufferAssureBlockMemory(block)) {
        char *data = NULL;
        if (!CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &data)) {
            for (int i = 0; i < 960; ++i) ((int16_t *)data)[i] = (int16_t)(4000 * sin(2*M_PI*440*(packet*960+i)/48000));
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, format, 960, time, NULL, &sample);
        }
    }
    if (block) CFRelease(block);
    CFRelease(format);
    return sample;
}

/** Loads a track without using deprecated synchronous asset access. */
static AVAssetTrack *track(AVURLAsset *asset, AVMediaType type) {
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    __block AVAssetTrack *result = nil;
    [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        result = tracks.firstObject;
        dispatch_semaphore_signal(loaded);
    }];
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC))) return nil;
    return result;
}

/** Decodes real output to verify inset placement, camera motion, and a microphone track. */
static BOOL verify(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *video = track(asset, AVMediaTypeVideo);
    if (!video || !track(asset, AVMediaTypeAudio)) return NO;
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    BOOL first = NO, changed = NO;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        const unsigned char *data = CVPixelBufferGetBaseAddress(image);
        size_t stride = CVPixelBufferGetBytesPerRow(image);
        size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
        const unsigned char *camera = data + (height-20)*stride + (width-20)*4, *screen = data + (height/2)*stride + (width/2)*4;
        if (screen[0] < 180 || screen[2] > 40) { CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly); CFRelease(sample); return NO; }
        if (time > .2 && time < .8) first = camera[2] > 180 && camera[0] < 40;
        if (time > 1.7) changed = camera[2] > 180 && camera[0] > 180;
        CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        CFRelease(sample);
    }
    return reader.status == AVAssetReaderStatusCompleted && first && changed;
}

/** Runs deterministic geometry checks and a real-time bounded encoder test. */
int main(int argc, const char *argv[]) {
    BOOL stress = argc == 2 && strcmp(argv[1], "--stress") == 0;
    int width = stress ? 1920 : 320, height = stress ? 1080 : 240;
    @autoreleasepool {
        for (int corner = 0; corner < 4; ++corner) for (int size = 0; size < 3; ++size) {
            CGRect box = sa_camera_rectangle(CGSizeMake(320, 240), CGSizeMake(160, 120), corner, size);
            double fraction = size == 0 ? .2 : size == 1 ? .3 : .4;
            if (fabs(box.size.width - 320*fraction) > .01 || fabs(box.size.height - 240*fraction) > .01 ||
                fabs(box.origin.x - ((corner == 0 || corner == 2) ? 320-box.size.width : 0)) > .01 ||
                fabs(box.origin.y - (corner < 2 ? 0 : 240-box.size.height)) > .01) return 1;
        }
        NSString *path = stress ? @"build/live-movie-stress.mp4" : @"build/live-movie-test.mp4";
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        NSError *error = nil;
        SunAppleMovie *movie = [[SunAppleMovie alloc] initWithURL:[NSURL fileURLWithPath:path] width:width height:height camera:YES microphone:YES corner:0 size:1 error:&error];
        if (!movie) { NSLog(@"%@", error); return 1; }
        dispatch_semaphore_t started = dispatch_semaphore_create(0), ended = dispatch_semaphore_create(0);
        __block BOOL failed = NO;
        movie.started = ^{ dispatch_semaphore_signal(started); };
        movie.finished = ^{ dispatch_semaphore_signal(ended); };
        movie.failed = ^(NSError *failure) { NSLog(@"%@", failure); failed = YES; dispatch_semaphore_signal(ended); };
        CVPixelBufferRef desktop = frame(width, height, 0, 255), camera = frame(160, 120, 255, 0);
        if (!desktop || !camera) return 1;
        dispatch_sync(movie.queue, ^{ [movie cameraFrame:camera]; [movie updateScreen:desktop]; });
        CVPixelBufferRelease(desktop); CVPixelBufferRelease(camera);
        if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC))) return 1;
        CMTime audioStart = CMClockGetTime(CMClockGetHostTimeClock());
        for (int packet = 0; packet < (stress ? 3000 : 110); ++packet) {
            if (packet == 55) {
                CVPixelBufferRef changed = frame(160, 120, 255, 255);
                dispatch_sync(movie.queue, ^{ [movie cameraFrame:changed]; });
                CVPixelBufferRelease(changed);
            }
            CMSampleBufferRef sample = audio(CMTimeAdd(audioStart, CMTimeMake(packet*960, 48000)), packet);
            if (!sample) return 1;
            dispatch_sync(movie.queue, ^{ [movie microphoneSamples:sample]; });
            CFRelease(sample);
            usleep(20000);
        }
        CMTime stopped = CMClockGetTime(CMClockGetHostTimeClock());
        dispatch_sync(movie.queue, ^{ [movie finishAtTime:stopped]; });
        if (dispatch_semaphore_wait(ended, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) || failed) return 1;
        dispatch_sync(movie.queue, ^{ [movie cancel]; });
        if (!verify([NSURL fileURLWithPath:path])) { fprintf(stderr, "Movie pixels or audio track did not match\n"); return 1; }
        puts("PASS live movie geometry, still-screen camera updates, and finalization");
    }
    return 0;
}
