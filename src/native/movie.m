/** Composes the newest camera frame onto screen frames without retaining a recording in memory. */
#import "movie.h"

CGRect sa_camera_rectangle(CGSize screen, CGSize camera, int corner, int size) {
    if (screen.width <= 0 || screen.height <= 0 || camera.width <= 0 || camera.height <= 0 ||
        corner < 0 || corner > 3 || size < 0 || size > 2) return CGRectZero;
    double fraction = size == 0 ? .2 : size == 1 ? .3 : .4;
    double scale = MIN(screen.width * fraction / camera.width, screen.height * fraction / camera.height);
    CGSize inset = CGSizeMake(camera.width * scale, camera.height * scale);
    return CGRectMake((corner == 0 || corner == 2) ? screen.width - inset.width : 0,
                      corner < 2 ? 0 : screen.height - inset.height, inset.width, inset.height);
}

/** Owns only the latest camera frame, a small render pool, and the encoder's bounded working buffers. */
@implementation SunAppleMovie {
    AVAssetWriter *_writer;
    AVAssetWriterInput *_video;
    AVAssetWriterInput *_audio;
    AVAssetWriterInputPixelBufferAdaptor *_pixels;
    CIContext *_context;
    CGColorSpaceRef _colorSpace;
    CVPixelBufferRef _cameraFrame;
    CVPixelBufferRef _screenFrame;
    dispatch_source_t _timer;
    CGSize _dimensions;
    int _corner, _size;
    BOOL _camera, _began, _ended, _reportedError;
    CMTime _startTime, _lastTime;
}
- (instancetype)initWithURL:(NSURL *)url width:(NSInteger)width height:(NSInteger)height camera:(BOOL)camera microphone:(BOOL)microphone corner:(int)corner size:(int)size error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("org.sun.capture.movie", DISPATCH_QUEUE_SERIAL);
    _dimensions = CGSizeMake(width, height); _camera = camera; _corner = corner; _size = size;
    _writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:error];
    if (!_writer) return nil;
    _writer.movieFragmentInterval = CMTimeMake(1, 1);
    NSDictionary *compression = @{AVVideoAverageBitRateKey:@(MAX(2000000, MIN(120000000, width * height * 8))),
                                  AVVideoMaxKeyFrameIntervalDurationKey:@1,
                                  AVVideoAllowFrameReorderingKey:@NO};
    _video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:
              @{AVVideoCodecKey:AVVideoCodecTypeH264, AVVideoWidthKey:@(width), AVVideoHeightKey:@(height),
                AVVideoCompressionPropertiesKey:compression}];
    _video.expectsMediaDataInRealTime = YES;
    _pixels = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_video
        sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
                                      (id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
                                      (id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    if (![_writer canAddInput:_video]) return nil;
    [_writer addInput:_video];
    if (microphone) {
        _audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:
                  @{AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@48000,
                    AVNumberOfChannelsKey:@1, AVEncoderBitRateKey:@128000}];
        _audio.expectsMediaDataInRealTime = YES;
        if (![_writer canAddInput:_audio]) return nil;
        [_writer addInput:_audio];
    }
    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    return self;
}
/** Releases the one explicitly retained Core Video frame. */
- (void)dealloc { if (_colorSpace) CGColorSpaceRelease(_colorSpace); if (_cameraFrame) CVPixelBufferRelease(_cameraFrame); if (_screenFrame) CVPixelBufferRelease(_screenFrame); }
/** Reports one error and prevents further writes. */
- (void)fail:(NSString *)message {
    if (_reportedError) return;
    _reportedError = YES; _ended = YES;
    if (_timer) dispatch_source_cancel(_timer);
    if (self.failed) self.failed(_writer.error ?: [NSError errorWithDomain:@"sun_apple" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]);
}
- (void)cameraFrame:(CVPixelBufferRef)frame {
    if (_ended || !frame) return;
    CVPixelBufferRetain(frame);
    if (_cameraFrame) CVPixelBufferRelease(_cameraFrame);
    _cameraFrame = frame;
}
- (void)updateScreen:(CVPixelBufferRef)frame {
    if (_ended || !frame) return;
    CVPixelBufferRetain(frame);
    if (_screenFrame) CVPixelBufferRelease(_screenFrame);
    _screenFrame = frame;
    if (!_timer) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
        __weak SunAppleMovie *weak = self;
        dispatch_source_set_event_handler(_timer, ^{
            SunAppleMovie *movie = weak;
            if (movie && !movie->_ended) [movie screenFrame:movie->_screenFrame time:CMClockGetTime(CMClockGetHostTimeClock())];
        });
        dispatch_resume(_timer);
    }
}
- (void)screenFrame:(CVPixelBufferRef)frame time:(CMTime)time {
    @autoreleasepool {
        if (_ended || !frame || !CMTIME_IS_NUMERIC(time) || (_camera && !_cameraFrame)) return;
        if (!_began) {
            if (![_writer startWriting]) { [self fail:@"Cannot start MP4 recording"]; return; }
            [_writer startSessionAtSourceTime:time];
            _startTime = time; _lastTime = kCMTimeInvalid; _began = YES;
        }
        if (!_video.readyForMoreMediaData) {
            if (_writer.status == AVAssetWriterStatusFailed) [self fail:@"Video encoder failed"];
            return;
        }
        if (CMTIME_IS_VALID(_lastTime) && CMTimeCompare(time, _lastTime) <= 0) return;
        CVPixelBufferRef output = NULL;
        NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@3};
        CVReturn allocated = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pixels.pixelBufferPool, (__bridge CFDictionaryRef)limits, &output);
        if (allocated == kCVReturnWouldExceedAllocationThreshold) return;
        if (allocated != kCVReturnSuccess) { [self fail:@"Cannot allocate a recording frame"]; return; }
        CIImage *image = [CIImage imageWithCVPixelBuffer:frame];
        if (_camera) {
            CIImage *camera = [CIImage imageWithCVPixelBuffer:_cameraFrame];
            CGRect inset = sa_camera_rectangle(_dimensions, camera.extent.size, _corner, _size);
            camera = [camera imageByApplyingTransform:CGAffineTransformMakeScale(inset.size.width / camera.extent.size.width, inset.size.height / camera.extent.size.height)];
            camera = [camera imageByApplyingTransform:CGAffineTransformMakeTranslation(inset.origin.x, inset.origin.y)];
            image = [camera imageByCompositingOverImage:image];
        }
        [_context render:image toCVPixelBuffer:output bounds:(CGRect){CGPointZero, _dimensions} colorSpace:_colorSpace];
        BOOL appended = [_pixels appendPixelBuffer:output withPresentationTime:time];
        CVPixelBufferRelease(output);
        if (!appended) { [self fail:@"Cannot write a recording frame"]; return; }
        BOOL first = !CMTIME_IS_VALID(_lastTime);
        _lastTime = time;
        if (first && self.started) self.started();
    }
}
- (void)microphoneSamples:(CMSampleBufferRef)samples {
    if (_ended || !_began || !_audio || !CMSampleBufferDataIsReady(samples)) return;
    CMTime time = CMSampleBufferGetPresentationTimeStamp(samples);
    if (!CMTIME_IS_NUMERIC(time) || CMTimeCompare(time, _startTime) < 0) return;
    if (!_audio.readyForMoreMediaData || ![_audio appendSampleBuffer:samples])
        [self fail:@"The microphone encoder could not keep up; the partial recording was retained"];
}
- (void)finishAtTime:(CMTime)time {
    if (_ended) return;
    _ended = YES;
    if (_timer) dispatch_source_cancel(_timer);
    if (!_began || !CMTIME_IS_VALID(_lastTime)) { [self fail:@"No recording frames were received"]; return; }
    if (CMTIME_IS_NUMERIC(time) && CMTimeCompare(time, _lastTime) > 0) [_writer endSessionAtSourceTime:time];
    [_video markAsFinished];
    if (_audio) [_audio markAsFinished];
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_async(self.queue, ^{
            if (self->_writer.status == AVAssetWriterStatusCompleted) { if (self.finished) self.finished(); }
            else [self fail:@"Cannot finalize the MP4 recording"];
        });
    }];
}
- (void)cancel {
    _ended = YES;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
    if (_cameraFrame) { CVPixelBufferRelease(_cameraFrame); _cameraFrame = NULL; }
    if (_screenFrame) { CVPixelBufferRelease(_screenFrame); _screenFrame = NULL; }
}
@end
