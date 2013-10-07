#import "GPUImageMovieWithAudio.h"
#import "GPUImageMovieWriter.h"
#import "TPCircularBuffer+AudioBufferList.h"

#define kOutputBus 0


void checkStatus(int status);
static OSStatus playbackCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData);

void checkStatus(int status)
{
    if (status) {
        printf("Status not 0! %d\n", status);
        //      exit(1);
    }
}

/**
 This callback is called when the audioUnit needs new data to play through the
 speakers. If you don't have any, just don't write anything in the buffers
 */
static OSStatus playbackCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    
    //GPUImageMovieWithAudio *gpiwa = (GPUImageMovieWithAudio*)inRefCon;
    TPCircularBuffer *tpCircularBuffer = inRefCon;
    UInt32 ioLengthInFrames = inNumberFrames;
    
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate         = 44100.00;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags        = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mChannelsPerFrame   = 2;
    audioFormat.mBitsPerChannel     = 16;
    audioFormat.mBytesPerPacket     = 4;
    audioFormat.mBytesPerFrame      = 4;
    
    AudioTimeStamp outTimestamp;
    
    
    UInt32 retVal = TPCircularBufferPeek(tpCircularBuffer, &outTimestamp, &audioFormat);
    
    if (retVal > 0) {
        TPCircularBufferDequeueBufferListFrames(tpCircularBuffer,
                                                &ioLengthInFrames,
                                                ioData,
                                                &outTimestamp,
                                                &audioFormat);
    } else {
            if ( ioData ) {
                for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
                    memset((char*)ioData->mBuffers[i].mData,0, ioData->mBuffers[i].mDataByteSize);
                }
            }
    }
    
    return noErr;
}

@interface GPUImageMovieWithAudio ()
{
    BOOL audioEncodingIsFinished, videoEncodingIsFinished;
    GPUImageMovieWriter *synchronizedMovieWriter;
    CVOpenGLESTextureCacheRef coreVideoTextureCache;
    AVAssetReader *reader;
    CMTime previousFrameTime, previousAudioFrameTime;
    CFAbsoluteTime previousActualFrameTime, previousAudioActualFrameTime;
    BOOL keepLooping;
    
    AudioComponentInstance audioUnit;
    BOOL audioSetup;
    BOOL audioOpen;
    BOOL audioExtractionIsFinished;
    
}

- (void)processAsset;

@end

@implementation GPUImageMovieWithAudio

@synthesize url = _url;
@synthesize asset = _asset;
@synthesize runBenchmark = _runBenchmark;
@synthesize playAtActualSpeed = _playAtActualSpeed;
@synthesize delegate = _delegate;
@synthesize shouldRepeat = _shouldRepeat;
@synthesize completionBlock;
@synthesize tpCircularBuffer = _tpCircularBuffer;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    if (!(self = [super init])) 
    {
        return nil;
    }

    [self textureCacheSetup];

    self.url = url;
    self.asset = nil;
    
    TPCircularBufferInit(&_tpCircularBuffer, 4096*500);

    return self;
}

- (id)initWithAsset:(AVAsset *)asset;
{
    if (!(self = [super init])) 
    {
      return nil;
    }
    
    [self textureCacheSetup];

    self.url = nil;
    self.asset = asset;
    
    TPCircularBufferInit(&_tpCircularBuffer, 4096*500);

    return self;
}

- (void)textureCacheSetup;
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
        runSynchronouslyOnVideoProcessingQueue(^{
            [GPUImageContext useImageProcessingContext];
#if defined(__IPHONE_6_0)
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#else
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#endif
            if (err)
            {
                NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
            }
            
            // Need to remove the initially created texture
            [self deleteOutputTexture];
        });
    }
}

- (void)dealloc
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
        CFRelease(coreVideoTextureCache);
    }
    
    TPCircularBufferCleanup(&_tpCircularBuffer);
}
#pragma mark -
#pragma mark Movie processing

- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
{
    synchronizedMovieWriter = movieWriter;
    movieWriter.encodingLiveVideo = NO;
}

- (void)startProcessing
{
    if(self.url == nil)
    {
      [self processAsset];
      return;
    }
    
    if (_shouldRepeat) keepLooping = YES;
    
    previousFrameTime = kCMTimeZero;
    previousActualFrameTime = CFAbsoluteTimeGetCurrent();
    
    previousAudioFrameTime = kCMTimeZero;
    previousAudioActualFrameTime = CFAbsoluteTimeGetCurrent();
  
    NSDictionary *inputOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
    AVURLAsset *inputAsset = [[AVURLAsset alloc] initWithURL:self.url options:inputOptions];    
    
    GPUImageMovieWithAudio __block *blockSelf = self;
    
    [inputAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler: ^{
        runSynchronouslyOnVideoProcessingQueue(^{
            NSError *error = nil;
            AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
            if (!tracksStatus == AVKeyValueStatusLoaded)
            {
                return;
            }
            blockSelf.asset = inputAsset;
            [blockSelf setupAudio];
            [blockSelf processAsset];
            blockSelf = nil;
        });
    }];
}

- (void)processAsset
{
    __unsafe_unretained GPUImageMovieWithAudio *weakSelf = self;
    NSError *error = nil;
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionary];
    [outputSettings setObject: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]
                       forKey: (NSString*)kCVPixelBufferPixelFormatTypeKey];

    AVAssetReaderTrackOutput *readerVideoTrackOutput =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[[self.asset tracksWithMediaType:AVMediaTypeVideo]
                                                                   objectAtIndex:0]
                                                   outputSettings:outputSettings];
    AVAssetReaderTrackOutput *readerAudioTrackOutput = nil;
    
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    BOOL shouldRecordAudioTrack = (([audioTracks count] > 0) && (weakSelf.audioEncodingTarget != nil) );
    BOOL shouldPlayAudioTrack = ([audioTracks count] > 0);
    audioExtractionIsFinished = YES;
    audioEncodingIsFinished = YES;
    
    // open a trackoutput for audio
    NSMutableDictionary *audioOutputSettings = [NSMutableDictionary dictionary];
    [audioOutputSettings setObject:[NSNumber numberWithInt:kAudioFormatLinearPCM] forKey:AVFormatIDKey];
    [audioOutputSettings setObject:[NSNumber numberWithInt:44100] forKey:AVSampleRateKey];
    if ( [[UIDevice currentDevice].systemVersion floatValue] >= 6.0 ) {
        [audioOutputSettings setObject:[NSNumber numberWithInt:2] forKey:AVNumberOfChannelsKey];
    }
    [audioOutputSettings setObject:[NSNumber numberWithInt:16] forKey:AVLinearPCMBitDepthKey];
    [audioOutputSettings setObject:[NSNumber numberWithBool:NO] forKey:AVLinearPCMIsBigEndianKey];
    [audioOutputSettings setObject:[NSNumber numberWithBool:NO] forKey:AVLinearPCMIsFloatKey];
    [audioOutputSettings setObject:[NSNumber numberWithBool:NO] forKey:AVLinearPCMIsNonInterleaved];

    // This might need to be extended to handle movies with more than one audio track
    AVAssetTrack* audioTrack = [audioTracks objectAtIndex:0];
    readerAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:audioOutputSettings];
    
    AVAssetReader *r = nil;
    @synchronized(reader) {
        r = [AVAssetReader assetReaderWithAsset:self.asset error:&error];

        [r addOutput:readerVideoTrackOutput];

        // this piece was only executed if shoudlRecordAudioTracks
        if ( shouldPlayAudioTrack )
        {
            [r addOutput:readerAudioTrackOutput];
            
            audioExtractionIsFinished = NO;
            TPCircularBufferClear(&_tpCircularBuffer);
        }

        if ( shouldRecordAudioTrack ) {
            [self.audioEncodingTarget setShouldInvalidateAudioSampleWhenDone:YES];
            audioEncodingIsFinished = NO;
        }

        if ([r startReading] == NO)
        {
            NSLog(@"Error reading from file at URL: %@", weakSelf.url);
            return;
        }
        reader = r;
        
    }
    
    if (synchronizedMovieWriter != nil)
    {
        [synchronizedMovieWriter setVideoInputReadyCallback:^{
            [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
        }];

        [synchronizedMovieWriter setAudioInputReadyCallback:^{
            [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
        }];

        [synchronizedMovieWriter enableSynchronizationCallbacks];
    }
    else
    {

        [self startAudioPlay];
        
        while (true)
        {
            @synchronized(reader) {
                if (reader.status == AVAssetReaderStatusReading && (!_shouldRepeat || keepLooping))
                {
                    [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];

                    if ( shouldPlayAudioTrack && !audioExtractionIsFinished )
                    {
                        [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
                    }
                } else {
                    break;
                }
            }
        }
        
        [self stopAudioPlay];

        if (reader.status == AVAssetWriterStatusCompleted) {
                
            [reader cancelReading];

            if (keepLooping) {
                reader = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self startProcessing];
                });
            } else {
                [weakSelf endProcessing];
                if ([self.delegate respondsToSelector:@selector(didCompletePlayingMovie)]) {
                    [self.delegate didCompletePlayingMovie];
                }
            }

        }
    }
}

- (void)readNextVideoFrameFromOutput:(AVAssetReaderTrackOutput *)readerVideoTrackOutput;
{
    if (reader.status == AVAssetReaderStatusReading)
    {
        CMSampleBufferRef sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
        if (sampleBufferRef) 
        {
            if (_playAtActualSpeed)
            {
                // Do this outside of the video processing queue to not slow that down while waiting
                CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef);
                CMTime differenceFromLastFrame = CMTimeSubtract(currentSampleTime, previousFrameTime);
                CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();
                
                CGFloat frameTimeDifference = CMTimeGetSeconds(differenceFromLastFrame);
                CGFloat actualTimeDifference = currentActualTime - previousActualFrameTime;
                
                if (frameTimeDifference > actualTimeDifference)
                {
                    usleep(1000000.0 * (frameTimeDifference - actualTimeDifference));
                }
                
                previousFrameTime = currentSampleTime;
                previousActualFrameTime = CFAbsoluteTimeGetCurrent();
            }

            __unsafe_unretained GPUImageMovieWithAudio *weakSelf = self;
            runSynchronouslyOnVideoProcessingQueue(^{
                [weakSelf processMovieFrame:sampleBufferRef];
            });
            
            CMSampleBufferInvalidate(sampleBufferRef);
            CFRelease(sampleBufferRef);
        }
        else
        {
            if (!keepLooping) {
                videoEncodingIsFinished = YES;
                [self endProcessing];
            }
        }
    }
    else if (synchronizedMovieWriter != nil)
    {
        if (reader.status == AVAssetWriterStatusCompleted) 
        {
            [self endProcessing];
        }
    }
}

- (void)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput;
{
    CMSampleBufferRef audioSampleBufferRef = [readerAudioTrackOutput copyNextSampleBuffer];
    
    if (audioSampleBufferRef) 
    {
        __unsafe_unretained GPUImageMovieWithAudio *weakSelf = self;
        runSynchronouslyOnVideoProcessingQueue(^{
            
            if ( !audioEncodingIsFinished ) {
                [self.audioEncodingTarget processAudioBuffer:audioSampleBufferRef];
            }
            
            [weakSelf processAudioFrame:audioSampleBufferRef];
            
            CMSampleBufferInvalidate(audioSampleBufferRef);
            CFRelease(audioSampleBufferRef);
        });
    }
    else
    {
        audioEncodingIsFinished = YES;
        audioExtractionIsFinished = YES;
      
    }
}

- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer; 
{
//    CMTimeGetSeconds
//    CMTimeSubtract
    
    CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(movieSampleBuffer);
    CVImageBufferRef movieFrame = CMSampleBufferGetImageBuffer(movieSampleBuffer);

    int bufferHeight = CVPixelBufferGetHeight(movieFrame);
#if TARGET_IPHONE_SIMULATOR
    int bufferWidth = CVPixelBufferGetBytesPerRow(movieFrame) / 4; // This works around certain movie frame types on the Simulator (see https://github.com/BradLarson/GPUImage/issues/424)
#else
    int bufferWidth = CVPixelBufferGetWidth(movieFrame);
#endif

    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();

    if ([GPUImageContext supportsFastTextureUpload])
    {
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        [GPUImageContext useImageProcessingContext];
        CVOpenGLESTextureRef texture = NULL;
        CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, 
                                                                    coreVideoTextureCache, 
                                                                    movieFrame, 
                                                                    NULL, 
                                                                    GL_TEXTURE_2D, 
                                                                    GL_RGBA, 
                                                                    bufferWidth, 
                                                                    bufferHeight, 
                                                                    GL_BGRA, 
                                                                    GL_UNSIGNED_BYTE, 
                                                                    0, 
                                                                    &texture);
        
        if (!texture || err) {
            NSLog(@"Movie CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);  
            return;
        }
        
        outputTexture = CVOpenGLESTextureGetName(texture);
        //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, self.outputTextureOptions.minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, self.outputTextureOptions.magFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, self.outputTextureOptions.wrapS);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, self.outputTextureOptions.wrapT);
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
            [currentTarget setInputTexture:outputTexture atIndex:targetTextureIndex];
            [currentTarget setTextureDelegate:self atIndex:targetTextureIndex];
            
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
        
        // Flush the CVOpenGLESTexture cache and release the texture
        CVOpenGLESTextureCacheFlush(coreVideoTextureCache, 0);
        CFRelease(texture);
        outputTexture = 0;        
    }
    else
    {
        // Upload to texture
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        // Using BGRA extension to pull in video frame data directly
        glTexImage2D(GL_TEXTURE_2D, 
                     0, 
                     GL_RGBA, 
                     bufferWidth, 
                     bufferHeight, 
                     0, 
                     GL_BGRA, 
                     GL_UNSIGNED_BYTE, 
                     CVPixelBufferGetBaseAddress(movieFrame));
        
        CGSize currentSize = CGSizeMake(bufferWidth, bufferHeight);
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];

            [currentTarget setInputSize:currentSize atIndex:targetTextureIndex];
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
    }
    
    if (_runBenchmark)
    {
        CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
    }
}

- (void)endProcessing;
{
    keepLooping = NO;

    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
    if (synchronizedMovieWriter != nil)
    {
        [synchronizedMovieWriter setVideoInputReadyCallback:^{}];
        [synchronizedMovieWriter setAudioInputReadyCallback:^{}];
    }
    
    if (completionBlock)
    {
        completionBlock();
    }
}

- (void)cancelProcessing
{
    @synchronized(reader) {
        if (reader) {
            [reader cancelReading];
        }
    }
    [self endAudio];
    [self endProcessing];
    
}

- (void)processAudioFrame:(CMSampleBufferRef)movieSampleBuffer;
{
   // CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(movieSampleBuffer);
  //  NSLog(@"%f\n", CMTimeGetSeconds(currentSampleTime));
 //   CMItemCount numSamplesInBuffer = CMSampleBufferGetNumSamples(movieSampleBuffer);
    
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer;
    BOOL copied = NO;
    
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(movieSampleBuffer,
                                                            NULL,
                                                            &audioBufferList,
                                                            sizeof(audioBufferList),
                                                            NULL,
                                                            NULL,
                                                            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                            &blockBuffer);
    
    copied = TPCircularBufferCopyAudioBufferList(&_tpCircularBuffer,
                                                 &audioBufferList,
                                                 NULL,
                                                 kTPCircularBufferCopyAll,
                                                 NULL);
    
    if ( !copied )
        NSLog(@"Error copying from TPCircularBuffer");
    
    CFRelease(blockBuffer);
    
}

- (void) setupAudio {
    
    if ( audioSetup )
        return;
    
    OSStatus status;
    
    SInt32 ambient = kAudioSessionCategory_SoloAmbientSound;
    if (AudioSessionSetProperty (kAudioSessionProperty_AudioCategory, sizeof (ambient), &ambient)) {
        NSLog(@"Error setting ambient property");
    }
    
    // Describe audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    
    // Get audio units
    status = AudioComponentInstanceNew(inputComponent, &audioUnit);
    checkStatus(status);
    
    UInt32 flag = 1;
    // Enable IO for playback
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output,
                                  kOutputBus,
                                  &flag,
                                  sizeof(flag));
    checkStatus(status);
    
    // Describe format
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate         = 44100.00;
    audioFormat.mFormatID           = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags        = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket    = 1;
    audioFormat.mChannelsPerFrame   = 2;
    audioFormat.mBitsPerChannel     = 16;
    audioFormat.mBytesPerPacket     = 4;
    audioFormat.mBytesPerFrame      = 4;
    
    
    // Apply format
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  kOutputBus,
                                  &audioFormat,
                                  sizeof(audioFormat));
    checkStatus(status);
    
    // Set output callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = (void *)(&_tpCircularBuffer);
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Global,
                                  kOutputBus,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    checkStatus(status);
    
    // Allocate our own buffers (1 channel, 16 bits per sample, thus 16 bits per frame, thus 2 bytes per frame).
    // Practice learns the buffers used contain 512 frames, if this changes it will be fixed in processAudio.
    //tempBuffer.mNumberChannels = 1;
    //tempBuffer.mDataByteSize = 512 * 2;
    //tempBuffer.mData = malloc( 512 * 2 );
    
    // Initialise
    status = AudioUnitInitialize(audioUnit);
    checkStatus(status);
    
    audioSetup = YES;
}


- (void) endAudio {
    
    AudioUnitUninitialize(audioUnit);
    audioUnit = nil;
    audioSetup = NO;
}

- (void) startAudioPlay {
    if ( audioOpen ) {
        return;
    }
    OSStatus status = AudioOutputUnitStart(audioUnit);
    checkStatus(status);
    audioOpen = YES;
}

- (void) stopAudioPlay {
    OSStatus status = AudioOutputUnitStop(audioUnit);
    checkStatus(status);
    audioOpen = NO;
}



@end
