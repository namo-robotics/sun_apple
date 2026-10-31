#ifndef SUN_APPLE_MOVIE_H
#define SUN_APPLE_MOVIE_H
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

/** Fits a camera frame into a corner of a bottom-left-origin output rectangle. */
CGRect sa_camera_rectangle(CGSize screen, CGSize camera, int corner, int size);

/** Serializes live composition and fragmented MP4 writing with a bounded pixel-buffer pool. */
@interface SunAppleMovie : NSObject
@property(readonly) dispatch_queue_t queue;
@property(copy) void (^started)(void);
@property(copy) void (^finished)(void);
@property(copy) void (^failed)(NSError *);
/** Creates an H.264/AAC writer; no frames are retained until append calls arrive. */
- (instancetype)initWithURL:(NSURL *)url width:(NSInteger)width height:(NSInteger)height camera:(BOOL)camera microphone:(BOOL)microphone corner:(int)corner size:(int)size error:(NSError **)error;
/** Replaces the single retained camera frame; call on queue. */
- (void)cameraFrame:(CVPixelBufferRef)frame;
/** Retains the newest desktop frame and starts a host-clock timer so a still desktop keeps camera motion live; call on queue. */
- (void)updateScreen:(CVPixelBufferRef)frame;
/** Composes one screen frame and drops it if the bounded encoder cannot accept it yet; call on queue. */
- (void)screenFrame:(CVPixelBufferRef)frame time:(CMTime)time;
/** Appends microphone samples on the screen's host-clock timeline; call on queue. */
- (void)microphoneSamples:(CMSampleBufferRef)samples;
/** Ends the timeline at the supplied host-clock time and finalizes asynchronously; call on queue. */
- (void)finishAtTime:(CMTime)time;
/** Stops writing before the caller removes partial output; call on queue. */
- (void)cancel;
@end
#endif
