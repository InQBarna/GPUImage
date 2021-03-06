#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "GPUImageContext.h"
#import "GPUImageOutput.h"
#import "TPCircularBuffer.h"

/** Protocol for getting Movie played callback.
 */
@protocol GPUImageMovieWithAudioDelegate <NSObject>

- (void)didCompletePlayingMovie;
@end

 
#ifndef max
#define max( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif
 
#ifndef min
#define min( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif
 
/** Source object for filtering movies
 */
@interface GPUImageMovieWithAudio : GPUImageOutput

@property (readwrite, retain) AVAsset *asset;
@property(readwrite, retain) NSURL *url;

/** This enables the benchmarking mode, which logs out instantaneous and average frame times to the console
 */
@property(readwrite, nonatomic) BOOL runBenchmark;

/** This determines whether to play back a movie as fast as the frames can be processed, or if the original speed of the movie should be respected. Defaults to NO.
 */
@property(readwrite, nonatomic) BOOL playAtActualSpeed;

/** This determines whether the video should repeat (loop) at the end and restart from the beginning. Defaults to NO.
 */
@property(readwrite, nonatomic) BOOL shouldRepeat;

/** This is used to send the delete Movie did complete playing alert
 */
@property (readwrite, nonatomic, assign) id <GPUImageMovieWithAudioDelegate>delegate;
 
// TODO: documentation
@property(readwrite, nonatomic) AudioBuffer aBuffer;
 
@property (nonatomic) TPCircularBuffer tpCircularBuffer;
 
/// @name Initialization and teardown
- (id)initWithAsset:(AVAsset *)asset;
- (id)initWithURL:(NSURL *)url;
- (void)textureCacheSetup;

/// @name Movie processing
- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
- (void)readNextVideoFrameFromOutput:(AVAssetReaderTrackOutput *)readerVideoTrackOutput;
- (void)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput;
- (void)startProcessing;
- (void)endProcessing;
- (void)cancelProcessing;
- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer;
 
@property(nonatomic, copy) void(^completionBlock)(void);
 
@end
