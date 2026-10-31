/** Adapts AppKit and ScreenCaptureKit callbacks to a main-thread polling interface. */
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import "capture.h"
#import "movie.h"

CGRect sa_region_rectangle(CGPoint first, CGPoint last, CGSize bounds) {
    CGRect rect = CGRectIntersection((CGRect){CGPointZero,bounds}, CGRectMake(MIN(first.x,last.x), MIN(first.y,last.y), fabs(first.x-last.x), fabs(first.y-last.y)));
    if (CGRectIsNull(rect)) return CGRectZero;
    rect.origin.y = bounds.height - CGRectGetMaxY(rect);
    return rect;
}

/** Allows Escape events on a borderless region overlay. */
@interface SunAppleRegionWindow : NSWindow
@end
@implementation SunAppleRegionWindow
/** Permits keyboard focus for cancellation. */
- (BOOL)canBecomeKeyWindow { return YES; }
@end

/** Draws and collects a display-local drag selection. */
@interface SunAppleRegionView : NSView
@property CGPoint first;
@property CGPoint last;
@property BOOL dragging;
@property(copy) void (^completion)(CGRect, BOOL);
@end
@implementation SunAppleRegionView
/** Receives Escape while selecting. */
- (BOOL)acceptsFirstResponder { return YES; }
/** Draws the dimmed display and clear selection. */
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithWhite:0 alpha:0.3] setFill];
    NSRectFill(self.bounds);
    if (!self.dragging) return;
    CGRect rect = CGRectMake(MIN(self.first.x,self.last.x), MIN(self.first.y,self.last.y),
                            fabs(self.first.x-self.last.x), fabs(self.first.y-self.last.y));
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationCopy);
    [[NSColor systemTealColor] setStroke];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:rect];
    outline.lineWidth = 2;
    [outline stroke];
}
/** Starts a drag in overlay coordinates. */
- (void)mouseDown:(NSEvent *)event {
    self.first = self.last = [self convertPoint:event.locationInWindow fromView:nil];
    self.dragging = YES;
    self.needsDisplay = YES;
}
/** Updates the selection without leaving the display. */
- (void)mouseDragged:(NSEvent *)event {
    self.last = [self convertPoint:event.locationInWindow fromView:nil];
    self.needsDisplay = YES;
}
/** Reports a bounded, top-left rectangle in display points. */
- (void)mouseUp:(NSEvent *)event {
    if (!self.dragging) return;
    [self mouseDragged:event];
    CGRect rect = sa_region_rectangle(self.first, self.last, self.bounds.size);
    if (rect.size.width < 2 || rect.size.height < 2) return;
    if (self.completion) self.completion(rect, NO);
}
/** Reports cancellation without producing a rectangle. */
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53 && self.completion) self.completion(CGRectZero, YES);
}
@end

/** Keeps Apple objects alive and serializes callbacks without calling into Sun from native threads. */
@interface SunAppleCaptureSession : NSObject <SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate>
@property SCContentFilter *filter;
@property SCStream *stream;
@property SCRecordingOutput *recording;
@property SunAppleMovie *movie;
@property AVCaptureSession *cameraSession;
@property dispatch_queue_t cameraQueue;
@property BOOL live;
@property BOOL camera;
@property BOOL microphone;
@property int corner;
@property int cameraSize;
/** Starts camera acquisition and the authorized screen stream after device permission is granted. */
- (void)startLive;
/** Requests only the device permissions explicitly enabled by the caller. */
- (void)authorizeLive;
/** Stops live inputs and drains their writer in callback order. */
- (void)stopLive;
@property NSWindow *overlay;
@property NSMutableArray<NSNumber *> *events;
@property NSString *error;
@property CGRect region;
@property int source;
@property BOOL closed;
@property BOOL selected;
@property BOOL stopping;
/** Enqueues a protocol-independent native event on the main queue. */
- (void)event:(int)event;
/** Saves a native error and queues failure. */
- (void)fail:(NSError *)error;
/** Shows the overlay for a selected display. */
- (void)selectRegion;
@end
@implementation SunAppleCaptureSession
/** Initializes a session without requesting capture permission. */
- (instancetype)init {
    if ((self = [super init])) { _events = [NSMutableArray new]; _error = @""; }
    return self;
}
- (void)event:(int)event {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.closed) [self.events addObject:@(event)]; });
}
- (void)fail:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.closed) { self.error = error.localizedDescription ?: @"Apple capture failed"; [self.events addObject:@6]; }
    });
}
/** Receives system picker cancellation. */
- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream {
    [self event:2];
}
/** Receives native picker errors. */
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error { [self fail:error]; }
/** Retains the authorized filter before allowing Sun to begin capture. */
- (void)contentSharingPicker:(SCContentSharingPicker *)picker didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed || self.selected) return;
        self.selected = YES;
        self.filter = filter;
        if (self.source == 2) [self selectRegion]; else [self event:1];
    });
}
- (void)selectRegion {
    SCDisplay *display = self.filter.includedDisplays.firstObject;
    NSScreen *chosen = nil;
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display.displayID) chosen = screen;
    if (!display || !chosen) {
        [self fail:[NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Selected display is no longer available"}]];
        return;
    }
    SunAppleRegionWindow *window = [[SunAppleRegionWindow alloc] initWithContentRect:chosen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.level = NSScreenSaverWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    SunAppleRegionView *view = [[SunAppleRegionView alloc] initWithFrame:(CGRect){CGPointZero, chosen.frame.size}];
    __weak SunAppleCaptureSession *weak = self;
    view.completion = ^(CGRect rect, BOOL cancelled) {
        SunAppleCaptureSession *owner = weak;
        if (!owner || owner.closed) return;
        [owner.overlay orderOut:nil];
        owner.overlay = nil;
        owner.region = rect;
        [owner event:cancelled ? 2 : 1];
    };
    window.contentView = view;
    self.overlay = window;
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [self event:7];
}
/** Delivers completed screen frames and microphone buffers to the serial movie writer. */
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeMicrophone) { [self.movie microphoneSamples:sample]; return; }
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    [self.movie updateScreen:CMSampleBufferGetImageBuffer(sample)];
}
/** Retains only the newest camera image on the same queue as screen composition. */
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    [self.movie cameraFrame:CMSampleBufferGetImageBuffer(sample)];
}
- (void)authorizeLive {
    if (self.closed || self.stopping) return;
    for (AVMediaType media in @[AVMediaTypeVideo, AVMediaTypeAudio]) {
        if (([media isEqual:AVMediaTypeVideo] && !self.camera) || ([media isEqual:AVMediaTypeAudio] && !self.microphone)) continue;
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:media];
        if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:media completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self authorizeLive]; });
            }];
            return;
        }
        if (status != AVAuthorizationStatusAuthorized) {
            [self fail:[NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:
                [media isEqual:AVMediaTypeVideo] ? @"Camera access denied. Allow Camera access in System Settings > Privacy & Security." : @"Microphone access denied. Allow Microphone access in System Settings > Privacy & Security."}]];
            return;
        }
    }
    [self startLive];
}
- (void)startLive {
    if (self.closed || self.stopping) return;
    if (self.camera) {
        NSError *error = nil;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;
        AVCaptureSession *camera = [AVCaptureSession new];
        AVCaptureVideoDataOutput *frames = [AVCaptureVideoDataOutput new];
        frames.alwaysDiscardsLateVideoFrames = YES;
        frames.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
        [frames setSampleBufferDelegate:self queue:self.movie.queue];
        if (!input || ![camera canAddInput:input] || ![camera canAddOutput:frames]) {
            [self fail:error ?: [NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The default camera is unavailable"}]];
            return;
        }
        [camera addInput:input]; [camera addOutput:frames];
        if ([camera canSetSessionPreset:AVCaptureSessionPreset640x480]) camera.sessionPreset = AVCaptureSessionPreset640x480;
        self.cameraSession = camera;
        self.cameraQueue = dispatch_queue_create("org.sun.capture.camera", DISPATCH_QUEUE_SERIAL);
        dispatch_async(self.cameraQueue, ^{ [camera startRunning]; });
    }
    SCStream *stream = self.stream;
    [stream startCaptureWithCompletionHandler:^(NSError *error) {
        if (error) [self fail:error];
        if (self.closed || self.stopping) [stream stopCaptureWithCompletionHandler:^(NSError *ignored) {}];
    }];
}
- (void)stopLive {
    CMTime stopped = CMClockGetTime(CMClockGetHostTimeClock());
    if (self.cameraSession) dispatch_async(self.cameraQueue, ^{ [self.cameraSession stopRunning]; });
    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(self.movie.queue, ^{ [self.movie finishAtTime:stopped]; });
    }];
}

/** Signals readiness only after the recording output has started. */
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output { [self event:3]; }
/** Signals finalization only after the native file is complete. */
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output { [self event:4]; }
/** Propagates recording failures. */
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error { [self fail:error]; }
/** Propagates permission revocation and source loss. */
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (self.live && !self.stopping) {
        self.stopping = YES;
        if (self.cameraSession) dispatch_async(self.cameraQueue, ^{ [self.cameraSession stopRunning]; });
        CMTime stopped = CMClockGetTime(CMClockGetHostTimeClock());
        dispatch_async(self.movie.queue, ^{ [self.movie finishAtTime:stopped]; });
    } else if (!self.stopping) [self fail:error];
}
@end

/** Tracks the one session allowed to own Apple's shared picker. */
static __weak SunAppleCaptureSession *active_session;

void *sa_capture_new(void) {
    if (!NSThread.isMainThread || active_session) return NULL;
    if (@available(macOS 15.2, *)) {
        if (!NSApp) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            [NSApp finishLaunching];
        }
        SunAppleCaptureSession *owner = [SunAppleCaptureSession new];
        active_session = owner;
        return (__bridge_retained void *)owner;
    }
    return NULL;
}
void sa_capture_free(void *pointer) {
    if (!pointer) return;
    SunAppleCaptureSession *owner = (__bridge_transfer SunAppleCaptureSession *)pointer;
    owner.closed = YES;
    if (owner.cameraSession) dispatch_sync(owner.cameraQueue, ^{ [owner.cameraSession stopRunning]; });
    if (owner.cameraSession) {
        for (AVCaptureOutput *output in owner.cameraSession.outputs)
            if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) [(AVCaptureVideoDataOutput *)output setSampleBufferDelegate:nil queue:NULL];
        owner.cameraSession = nil;
    }
    if (owner.movie) dispatch_sync(owner.movie.queue, ^{ [owner.movie cancel]; });
    if (owner.live && owner.stream) {
        [owner.stream removeStreamOutput:owner type:SCStreamOutputTypeScreen error:NULL];
        if (owner.microphone) [owner.stream removeStreamOutput:owner type:SCStreamOutputTypeMicrophone error:NULL];
    }
    if (active_session == owner) active_session = nil;
    [SCContentSharingPicker.sharedPicker removeObserver:owner];
    SCContentSharingPicker.sharedPicker.active = NO;
    [owner.overlay orderOut:nil];
    owner.overlay = nil;
    if (owner.stream && !owner.stopping) [owner.stream stopCaptureWithCompletionHandler:^(NSError *error) {}];
}
void sa_capture_select(void *pointer, int source) {
    SunAppleCaptureSession *owner = (__bridge SunAppleCaptureSession *)pointer;
    owner.source = source;
    SCContentSharingPickerConfiguration *configuration = [SCContentSharingPickerConfiguration new];
    configuration.allowedPickerModes = source == 1 ? SCContentSharingPickerModeSingleWindow : SCContentSharingPickerModeSingleDisplay;
    configuration.allowsChangingSelectedContent = NO;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    picker.defaultConfiguration = configuration;
    [picker addObserver:owner];
    picker.active = YES;
    [NSApp activateIgnoringOtherApps:YES];
    [picker presentPickerUsingContentStyle:source == 1 ? SCShareableContentStyleWindow : SCShareableContentStyleDisplay];
}
int sa_capture_poll(void *pointer) {
    @autoreleasepool {
        SunAppleCaptureSession *owner = (__bridge SunAppleCaptureSession *)pointer;
        for (int i = 0; i < 32; ++i) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!event) break;
            [NSApp sendEvent:event];
        }
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        if (!owner.events.count) return 0;
        int event = owner.events.firstObject.intValue;
        [owner.events removeObjectAtIndex:0];
        return event;
    }
}
const char *sa_capture_error(void *pointer) { return [(__bridge SunAppleCaptureSession *)pointer error].UTF8String; }
void sa_capture_start(void *pointer, int recording, int cursor, const char *path) {
    SunAppleCaptureSession *owner = (__bridge SunAppleCaptureSession *)pointer;
    if (!owner.filter || owner.closed) return;
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    CGSize size = owner.source == 2 ? owner.region.size : owner.filter.contentRect.size;
    CGFloat scale = owner.filter.pointPixelScale;
    configuration.width = MAX(2, (NSInteger)(size.width * scale) / 2 * 2);
    configuration.height = MAX(2, (NSInteger)(size.height * scale) / 2 * 2);
    configuration.showsCursor = cursor != 0;
    configuration.capturesAudio = NO;
    configuration.captureMicrophone = recording && owner.microphone;
    configuration.queueDepth = 3;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    configuration.minimumFrameInterval = CMTimeMake(1,30);
    if (owner.source == 2) configuration.sourceRect = owner.region;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    if (!recording) {
        [SCScreenshotManager captureImageWithFilter:owner.filter configuration:configuration completionHandler:^(CGImageRef image, NSError *error) {
            if (error) { [owner fail:error]; return; }
            CGImageRef retained = image ? CGImageRetain(image) : NULL;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (owner.closed) { if (retained) CGImageRelease(retained); return; }
                CGImageDestinationRef destination = retained ? CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL) : NULL;
                BOOL success = NO;
                if (destination) { CGImageDestinationAddImage(destination,retained,NULL); success = CGImageDestinationFinalize(destination); CFRelease(destination); }
                if (retained) CGImageRelease(retained);
                if (success) [owner event:5];
                else [owner fail:[NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot save screenshot"}]];
            });
        }];
    } else if (owner.live) {
        NSError *error = nil;
        owner.movie = [[SunAppleMovie alloc] initWithURL:url width:configuration.width height:configuration.height camera:owner.camera microphone:owner.microphone corner:owner.corner size:owner.cameraSize error:&error];
        if (!owner.movie) { [owner fail:error ?: [NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot configure the MP4 encoder"}]]; return; }
        __weak SunAppleCaptureSession *weak = owner;
        owner.movie.started = ^{ [weak event:3]; };
        owner.movie.finished = ^{ [weak event:4]; };
        owner.movie.failed = ^(NSError *failure) { [weak fail:failure]; };
        owner.stream = [[SCStream alloc] initWithFilter:owner.filter configuration:configuration delegate:owner];
        if (![owner.stream addStreamOutput:owner type:SCStreamOutputTypeScreen sampleHandlerQueue:owner.movie.queue error:&error] ||
            (owner.microphone && ![owner.stream addStreamOutput:owner type:SCStreamOutputTypeMicrophone sampleHandlerQueue:owner.movie.queue error:&error])) {
            [owner fail:error]; return;
        }
        [owner authorizeLive];
    } else {
        SCRecordingOutputConfiguration *output = [SCRecordingOutputConfiguration new];
        output.outputURL = url;
        output.outputFileType = AVFileTypeMPEG4;
        output.videoCodecType = AVVideoCodecTypeH264;
        owner.recording = [[SCRecordingOutput alloc] initWithConfiguration:output delegate:owner];
        owner.stream = [[SCStream alloc] initWithFilter:owner.filter configuration:configuration delegate:owner];
        NSError *error = nil;
        if (![owner.stream addRecordingOutput:owner.recording error:&error]) { [owner fail:error]; return; }
        [owner.stream startCaptureWithCompletionHandler:^(NSError *error) { if (error) [owner fail:error]; }];
    }
}
void sa_capture_start_live(void *pointer, int cursor, const char *path, int camera, int microphone, int corner, int size) {
    SunAppleCaptureSession *owner = (__bridge SunAppleCaptureSession *)pointer;
    if (!owner || corner < 0 || corner > 3 || size < 0 || size > 2) return;
    owner.live = YES; owner.camera = camera != 0; owner.microphone = microphone != 0;
    owner.corner = corner; owner.cameraSize = size;
    sa_capture_start(pointer, 1, cursor, path);
}
void sa_capture_stop(void *pointer) {
    SunAppleCaptureSession *owner = (__bridge SunAppleCaptureSession *)pointer;
    if (!owner.stream || owner.stopping) return;
    owner.stopping = YES;
    if (owner.live) { [owner stopLive]; return; }
    [owner.stream stopCaptureWithCompletionHandler:^(NSError *error) { if (error) [owner fail:error]; }];
}
char *sa_uuid(void) { @autoreleasepool { return strdup(NSUUID.UUID.UUIDString.UTF8String); } }
char *sa_media_directory(int video) {
    @autoreleasepool {
        NSURL *url = [NSFileManager.defaultManager URLsForDirectory:video ? NSMoviesDirectory : NSPicturesDirectory inDomains:NSUserDomainMask].firstObject;
        return url ? strdup(url.path.UTF8String) : NULL;
    }
}
void sa_string_free(char *text) { free(text); }
