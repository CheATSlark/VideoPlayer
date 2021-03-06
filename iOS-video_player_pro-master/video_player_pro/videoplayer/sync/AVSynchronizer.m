//
//  AVSynchronizer.m
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "AVSynchronizer.h"
#import "VideoDecoder.h"
#import "VideoToolboxDecoder.h"
#import <UIKit/UIDevice.h>
#import <pthread.h>

#define LOCAL_MIN_BUFFERED_DURATION                     0.5
#define LOCAL_MAX_BUFFERED_DURATION                     1.0
#define NETWORK_MIN_BUFFERED_DURATION                   2.0
#define NETWORK_MAX_BUFFERED_DURATION                   4.0
#define LOCAL_AV_SYNC_MAX_TIME_DIFF                     0.05
#define FIRST_BUFFER_DURATION                           0.5

NSString * const kMIN_BUFFERED_DURATION = @"Min_Buffered_Duration";
NSString * const kMAX_BUFFERED_DURATION = @"Max_Buffered_Duration";

@interface AVSynchronizer () {
    
    VideoDecoder*                                       _decoder;
    BOOL                                                _usingHWCodec;
    BOOL                                                isOnDecoding;
    BOOL                                                isInitializeDecodeThread;
    BOOL                                                isDestroyed;
    
    BOOL                                                isFirstScreen;
    /** 解码第一段buffer的控制变量 **/
    pthread_mutex_t                                     decodeFirstBufferLock;
    pthread_cond_t                                      decodeFirstBufferCondition;
    pthread_t                                           decodeFirstBufferThread;
    /** 是否正在解码第一段buffer **/
    BOOL                                                isDecodingFirstBuffer;
    
    pthread_mutex_t                                     videoDecoderLock;
    pthread_cond_t                                      videoDecoderCondition;
    pthread_t                                           videoDecoderThread;
    
//    dispatch_queue_t                                    _dispatchQueue;
    NSMutableArray*                                     _videoFrames;
    NSMutableArray*                                     _audioFrames;
    
    /** 分别是当外界需要音频数据和视频数据的时候, 全局变量缓存数据 **/
    NSData*                                             _currentAudioFrame;
    NSUInteger                                          _currentAudioFramePos;
    CGFloat                                             _audioPosition;
    VideoFrame*                                         _currentVideoFrame;
    
    /** 控制何时该解码 **/
    BOOL                                                _buffered;
    CGFloat                                             _bufferedDuration;
    CGFloat                                             _minBufferedDuration;
    CGFloat                                             _maxBufferedDuration;
    
    CGFloat                                             _syncMaxTimeDiff;
    NSInteger                                           _firstBufferDuration;
    
    BOOL                                                _completion;
    
    NSTimeInterval                                      _bufferedBeginTime;
    NSTimeInterval                                      _bufferedTotalTime;
    
    int                                                 _decodeVideoErrorState;
    NSTimeInterval                                      _decodeVideoErrorBeginTime;
    NSTimeInterval                                      _decodeVideoErrorTotalTime;
}

@end

@implementation AVSynchronizer

static BOOL isNetworkPath (NSString *path)
{
    NSRange r = [path rangeOfString:@":"];
    if (r.location == NSNotFound)
        return NO;
    NSString *scheme = [path substringToIndex:r.length];
    if ([scheme isEqualToString:@"file"])
        return NO;
    return YES;
}

// 解码线程
static void* runDecoderThread(void* ptr)
{
    // 转换类型
    AVSynchronizer* synchronizer = (__bridge AVSynchronizer*)ptr;
    [synchronizer run];
    return NULL;
}

- (BOOL) isPlayCompleted;
{
    return _completion;
}

- (void) run
{
    while(isOnDecoding){
        pthread_mutex_lock(&videoDecoderLock);
//        NSLog(@"Before wait First decode Buffer...");
        pthread_cond_wait(&videoDecoderCondition, &videoDecoderLock);
//        NSLog(@"After wait First decode Buffer...");
        pthread_mutex_unlock(&videoDecoderLock);
        //			LOGI("after pthread_cond_wait");
        // 循环进行解码操作
        [self decodeFrames];
    }
}

// 解码第一个缓冲runloop
static void* decodeFirstBufferRunLoop(void* ptr)
{
    AVSynchronizer* synchronizer = (__bridge AVSynchronizer*)ptr;
    [synchronizer decodeFirstBuffer];
    return NULL;
}

- (void) decodeFirstBuffer
{
    // 获取当前第一缓冲区时间
    double startDecodeFirstBufferTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
    // 在 0.5 解码帧
    [self decodeFramesWithDuration:FIRST_BUFFER_DURATION];
    int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startDecodeFirstBufferTimeMills;
    NSLog(@"Decode First Buffer waste TimeMills is %d", wasteTimeMills);
    pthread_mutex_lock(&decodeFirstBufferLock);
    pthread_cond_signal(&decodeFirstBufferCondition);
    pthread_mutex_unlock(&decodeFirstBufferLock);
    isDecodingFirstBuffer = false;
}

- (void) decodeFramesWithDuration:(CGFloat) duration;
{
    BOOL good = YES;
    while (good) {
        good = NO;
        @autoreleasepool {
            if (_decoder && (_decoder.validVideo || _decoder.validAudio)) {
                int tmpDecodeVideoErrorState;
                NSArray *frames = [_decoder decodeFrames:0.0f decodeVideoErrorState:&tmpDecodeVideoErrorState];
                if (frames.count) {
                    good = [self addFrames:frames duration:duration];
                }
            }
        }
    }
}

- (void) decodeFrames
{
    const CGFloat duration = 0.0f;
    BOOL good = YES;
    while (good) {
        good = NO;
        @autoreleasepool {
            // 解码存在 且可被 视频或音频解码
            if (_decoder && (_decoder.validVideo || _decoder.validAudio)) {
                // 获取帧 只包含一个视频帧 可以有多个音频帧
                NSArray *frames = [_decoder decodeFrames:duration decodeVideoErrorState:&_decodeVideoErrorState];
                if (frames.count) {
                    // 在最大缓冲时间添加
                    // 对音视频帧 进行分类
                    good = [self addFrames:frames duration:_maxBufferedDuration];
                    if (good == NO) {
                        
                    }
                }
            }
        }
    }
}

- (id) initWithPlayerStateDelegate:(id<PlayerStateDelegate>) playerStateDelegate
{
    self = [super init];
    if (self) {
        _playerStateDelegate = playerStateDelegate;
    }
    return self;
}

- (void) signalDecoderThread
{
    if(NULL == _decoder || isDestroyed) {
        return;
    }
    if(!isDestroyed) {
        pthread_mutex_lock(&videoDecoderLock);
//        NSLog(@"Before signal First decode Buffer...");
        pthread_cond_signal(&videoDecoderCondition);
//        NSLog(@"After signal First decode Buffer...");
        pthread_mutex_unlock(&videoDecoderLock);
    }
}

- (OpenState) openFile: (NSString *) path usingHWCodec: (BOOL) usingHWCodec error: (NSError **) perror;
{
    NSMutableDictionary* parameters = [NSMutableDictionary dictionary];
    parameters[FPS_PROBE_SIZE_CONFIGURED] = @(true);
    parameters[PROBE_SIZE] = @(50 * 1024);
    NSMutableArray* durations = [NSMutableArray array];
    durations[0] = @(1250000);
    durations[0] = @(1750000);
    durations[0] = @(2000000);
    parameters[MAX_ANALYZE_DURATION_ARRAY] = durations;
    return [self openFile:path usingHWCodec:usingHWCodec parameters:parameters error:perror];
}

- (BOOL) usingHWCodec
{
    return _usingHWCodec;
}

- (OpenState) openFile: (NSString *) path usingHWCodec: (BOOL) usingHWCodec parameters:(NSDictionary*) parameters error: (NSError **) perror;
{
    //1、创建decoder实例
    if(usingHWCodec){
        BOOL isIOS8OrUpper = ([[[UIDevice currentDevice] systemVersion] floatValue] >= 8.0);
        if(!isIOS8OrUpper){
            usingHWCodec = false;
        }
    }
    _usingHWCodec = usingHWCodec;
    
    
    // 创建 _decoder 的实例
    [self createDecoderInstance];
    //2、初始化成员变量
    _currentVideoFrame = NULL;
    
    _currentAudioFramePos = 0;
    
    _bufferedBeginTime = 0;
    _bufferedTotalTime = 0;
    
    _decodeVideoErrorBeginTime = 0;
    _decodeVideoErrorTotalTime = 0;
    
    isFirstScreen = YES;
    
    // 获取最大、小缓冲时间
    _minBufferedDuration = [parameters[kMIN_BUFFERED_DURATION] floatValue];
    _maxBufferedDuration = [parameters[kMAX_BUFFERED_DURATION] floatValue];
    
    BOOL isNetwork = isNetworkPath(path);
    
    // 如果 _minBufferedDuration 的绝对值 小于 最小非负的浮点值
    if (ABS(_minBufferedDuration - 0.f) < CGFLOAT_MIN) {
        if(isNetwork){
            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
        } else{
            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
        }
    }
    // _maxBufferedDuration
    if ((ABS(_maxBufferedDuration - 0.f) < CGFLOAT_MIN)) {
        if(isNetwork){
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
        } else{
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
    }
    
    // 保证最大值 不小于 最小值
    if (_minBufferedDuration > _maxBufferedDuration) {
        float temp = _minBufferedDuration;
        _minBufferedDuration = _maxBufferedDuration;
        _maxBufferedDuration = temp;
    }
    
    // 同步最大时间不同
    _syncMaxTimeDiff = LOCAL_AV_SYNC_MAX_TIME_DIFF;
    // 第一个缓冲区时长
    _firstBufferDuration = FIRST_BUFFER_DURATION;
    
    //3、打开流并且解析出来音视频流的Context
    BOOL openCode = [_decoder openFile:path parameter:parameters error:perror];
    if(!openCode || ![_decoder isSubscribed] || isDestroyed){
        NSLog(@"VideoDecoder decode file fail...");
        [self closeDecoder];
        return [_decoder isSubscribed] ? OPEN_FAILED : CLIENT_CANCEL;
    }
    //4、回调客户端视频宽高以及duration
    NSUInteger videoWidth = [_decoder frameWidth];
    NSUInteger videoHeight = [_decoder frameHeight];
    if(videoWidth <= 0 || videoHeight <= 0){
        return [_decoder isSubscribed] ? OPEN_FAILED : CLIENT_CANCEL;
    }
    //5、开启解码线程与解码队列
    _audioFrames        = [NSMutableArray array];
    _videoFrames        = [NSMutableArray array];
    // 开启解码线程
    [self startDecoderThread];
    // 开始解码第一个缓冲线程
    [self startDecodeFirstBufferThread];
    return OPEN_SUCCESS;
}

- (void) startDecodeFirstBufferThread
{
    // 初始化 线程互斥
    pthread_mutex_init(&decodeFirstBufferLock, NULL);
    // 初始化 第一缓冲线程条件
    pthread_cond_init(&decodeFirstBufferCondition, NULL);
    
    isDecodingFirstBuffer = true;
    // 创建执行线程
    pthread_create(&decodeFirstBufferThread, NULL, decodeFirstBufferRunLoop, (__bridge void*)self);
}

- (void) startDecoderThread {
    NSLog(@"AVSynchronizer::startDecoderThread ...");
    //    _dispatchQueue      = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
    
    isOnDecoding = true;
    isDestroyed = false;
    // 初始化 视频解码线程锁
    pthread_mutex_init(&videoDecoderLock, NULL);
    // 初始化 视频解码线程条件
    pthread_cond_init(&videoDecoderCondition, NULL);
    
    isInitializeDecodeThread = true;
    // 创建 视频解码线程  执行解码操作
    // 第一参数 传出的线程   第二个 线程参数 NULL为使用默认配置  第三个 执行的函数   第三个 函数的参数
    pthread_create(&videoDecoderThread, NULL, runDecoderThread, (__bridge void*)self);
}

static int count = 0;
static int invalidGetCount = 0;
float lastPosition = -1.0;

- (VideoFrame*) getCorrectVideoFrame;
{
    VideoFrame *frame = NULL;
    @synchronized(_videoFrames) {
        while (_videoFrames.count > 0) {
            frame = _videoFrames[0];
            const CGFloat delta = _audioPosition - frame.position;
            if (delta < (0 - _syncMaxTimeDiff)) {
//                NSLog(@"视频比音频快了好多,我们还是渲染上一帧");
                frame = NULL;
                break;
            }
            [_videoFrames removeObjectAtIndex:0];
            if (delta > _syncMaxTimeDiff) {
//                NSLog(@"视频比音频慢了好多,我们需要继续从queue拿到合适的帧 _audioPosition is %.3f frame.position %.3f", _audioPosition, frame.position);
                frame = NULL;
                continue;
            } else {
                break;
            }
        }
    }
    if (frame) {
        if (isFirstScreen) {
            [_decoder triggerFirstScreen];
            isFirstScreen = NO;
        }
//        NSLog(@"frame is Not NUll position is %.3f", frame.position);
        if (NULL != _currentVideoFrame) {
            _currentVideoFrame = NULL;
        }
        _currentVideoFrame = frame;
    } else{
//        NSLog(@"frame is NULL");
    }
//    if(NULL != _currentVideoFrame){
//        NSLog(@"audio played position is %.3f _currentVideoFrame position is %.3f", _audioPosition, _currentVideoFrame.position);
//    }
    
    if(fabs(_currentVideoFrame.position - lastPosition) > 0.01f){
//        NSLog(@"lastPosition is %.3f _currentVideoFrame position is %.3f", lastPosition, _currentVideoFrame.position);
        lastPosition = _currentVideoFrame.position;
        count++;
        return _currentVideoFrame;
    } else {
        invalidGetCount++;
        return nil;
    }
}

// 控制器调取
- (void) audioCallbackFillData: (SInt16 *) outData
                     numFrames: (UInt32) numFrames
                   numChannels: (UInt32) numChannels;
{
    // 检查状态，且进行下一帧解码
    [self checkPlayState];
    if (_buffered) {
        // 把内存中的outData 的numFrames*numChannels*sizeof(SInt16)的字符设为0
        memset(outData, 0, numFrames * numChannels * sizeof(SInt16));
        return;
    }
    @autoreleasepool {
        //当帧数大于0的时候
        while (numFrames > 0) {
            // 如果不存在当前音频数据
            if (!_currentAudioFrame) {
                //从队列中取出音频数据 、初始化
                @synchronized(_audioFrames) {
                    NSUInteger count = _audioFrames.count;
                    if (count > 0) {
                        // 把音频帧数组里面的第一个 音频帧对象取出
                        AudioFrame *frame = _audioFrames[0];
                        // 减去对应的时长
                        _bufferedDuration -= frame.duration;
                        // 移除
                        [_audioFrames removeObjectAtIndex:0];
                        // 获取帧的位置
                        _audioPosition = frame.position;
        
                        _currentAudioFramePos = 0;
                        // 获取帧的采样数据
                        _currentAudioFrame = frame.samples;
                    }
                }
            }
            
            if (_currentAudioFrame) {
                const void *bytes = (Byte *)_currentAudioFrame.bytes + _currentAudioFramePos;
                const NSUInteger bytesLeft = (_currentAudioFrame.length - _currentAudioFramePos);
                const NSUInteger frameSizeOf = numChannels * sizeof(SInt16);
                const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
                const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
                
                // 把数据bytes复制到 outData
                memcpy(outData, bytes, bytesToCopy);
                // 减去framesToCopy
                numFrames -= framesToCopy;
                // 加上
                outData += framesToCopy * numChannels;
                
                if (bytesToCopy < bytesLeft)
                    _currentAudioFramePos += bytesToCopy;
                else
                    _currentAudioFrame = nil;
                
            } else {
                memset(outData, 0, numFrames * numChannels * sizeof(SInt16));
                break;
            }
        }
    }
}

- (void)checkPlayState;
{
    if (NULL == _decoder) {
        return;
    }
    if (_buffered && ((_bufferedDuration > _minBufferedDuration))) {
        _buffered = NO;
        if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(hideLoading)]){
            [_playerStateDelegate hideLoading];
        }
    }
    if (1 == _decodeVideoErrorState) {
        _decodeVideoErrorState = 0;
        if (_minBufferedDuration > 0 && !_buffered) {
            _buffered = YES;
            _decodeVideoErrorBeginTime = [[NSDate date] timeIntervalSince1970];
        }
        
        _decodeVideoErrorTotalTime = [[NSDate date] timeIntervalSince1970] - _decodeVideoErrorBeginTime;
        if (_decodeVideoErrorTotalTime > TIMEOUT_DECODE_ERROR) {
            NSLog(@"decodeVideoErrorTotalTime = %f", _decodeVideoErrorTotalTime);
            _decodeVideoErrorTotalTime = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"restart after decodeVideoError");
                if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(restart)]){
                    [_playerStateDelegate restart];
                }
            });
        }
        return;
    }
    // 解码器为音频、视频可用 获得，视频帧和音频帧的数目
    const NSUInteger leftVideoFrames = _decoder.validVideo ? _videoFrames.count : 0;
    const NSUInteger leftAudioFrames = _decoder.validAudio ? _audioFrames.count : 0;
    
    if (0 == leftVideoFrames || 0 == leftAudioFrames) {
        //Buffer Status Empty Record
        // 缓冲区的没有记录
        [_decoder addBufferStatusRecord:@"E"];
        if (_minBufferedDuration > 0 && !_buffered) {
            _buffered = YES;
            _bufferedBeginTime = [[NSDate date] timeIntervalSince1970];
            if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(showLoading)]){
                [_playerStateDelegate showLoading];
            }
        }
        if([_decoder isEOF]){
            if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(onCompletion)]){
                _completion = YES;
                [_playerStateDelegate onCompletion];
            }
        }
    }
    
    if (_buffered) {
        _bufferedTotalTime = [[NSDate date] timeIntervalSince1970] - _bufferedBeginTime;
        // 如果解码总时长超时  重新启动
        if (_bufferedTotalTime > TIMEOUT_BUFFER) {
            _bufferedTotalTime = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
#ifdef DEBUG
                NSLog(@"AVSynchronizer restart after timeout");
#endif
                if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(restart)]){
                    NSLog(@"=============================== AVSynchronizer restart");
                    [_playerStateDelegate restart];
                }
            });
            return;
        }
    }
    
    // 
    if (!isDecodingFirstBuffer && (0 == leftVideoFrames || 0 == leftAudioFrames || !(_bufferedDuration > _minBufferedDuration))) {
#ifdef DEBUG
//        NSLog(@"AVSynchronizer _bufferedDuration is %.3f _minBufferedDuration is %.3f", _bufferedDuration, _minBufferedDuration);
#endif
        // 发送解码信号
        [self signalDecoderThread];
    } else if(_bufferedDuration >= _maxBufferedDuration) {
        //Buffer Status Full Record
        // 缓冲区添加记录
        [_decoder addBufferStatusRecord:@"F"];
    }
}

- (BOOL) addFrames: (NSArray *)frames duration:(CGFloat) duration
{
    NSLog(@"arr classfiy ------>start");
    if (_decoder.validVideo) {
        // 对_videoFrames 进行加锁处理
        NSLog(@"vide classfiy");
        @synchronized(_videoFrames) {
            for (Frame *frame in frames)
                if (frame.type == VideoFrameType || frame.type == iOSCVVideoFrameType) {
                    [_videoFrames addObject:frame];
                }
        }
    }
    
    if (_decoder.validAudio) {
        NSLog(@"aduio classfiy");
        @synchronized(_audioFrames) {
            for (Frame *frame in frames)
                if (frame.type == AudioFrameType) {
                    [_audioFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
    }
    NSLog(@"arr classfiy ------>end");
    return _bufferedDuration < duration;
}

- (void) createDecoderInstance
{
    if(_usingHWCodec){
        _decoder = [[VideoToolboxDecoder alloc] init];
    } else {
        _decoder = [[VideoDecoder alloc] init];
    }
}

- (BOOL) isOpenInputSuccess
{
    BOOL ret = NO;
    if (_decoder){
        ret = [_decoder isOpenInputSuccess];
    }
    return ret;
}

- (void) interrupt
{
    if (_decoder){
        [_decoder interrupt];
    }
}

- (void) closeFile;
{
    if (_decoder){
        [_decoder interrupt];
    }
    [self destroyDecodeFirstBufferThread];
    [self destroyDecoderThread];
    if([_decoder isOpenInputSuccess]){
        [self closeDecoder];
    }
    
    @synchronized(_videoFrames) {
        [_videoFrames removeAllObjects];
    }
    
    @synchronized(_audioFrames) {
        [_audioFrames removeAllObjects];
        _currentAudioFrame = nil;
    }
    NSLog(@"present diff video frame cnt is %d invalidGetCount is %d", count, invalidGetCount);
}

- (void) closeDecoder;
{
    if(_decoder){
        [_decoder closeFile];
        if(_playerStateDelegate && [_playerStateDelegate respondsToSelector:@selector(buriedPointCallback:)]){
            [_playerStateDelegate buriedPointCallback:[_decoder getBuriedPoint]];
        }
        _decoder = nil;
    }
}

- (void) destroyDecodeFirstBufferThread {
    if (isDecodingFirstBuffer) {
        NSLog(@"Begin Wait Decode First Buffer...");
        double startWaitDecodeFirstBufferTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
        pthread_mutex_lock(&decodeFirstBufferLock);
        pthread_cond_wait(&decodeFirstBufferCondition, &decodeFirstBufferLock);
        pthread_mutex_unlock(&decodeFirstBufferLock);
        int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startWaitDecodeFirstBufferTimeMills;
        NSLog(@" Wait Decode First Buffer waste TimeMills is %d", wasteTimeMills);
    }
}

- (void) destroyDecoderThread {
    NSLog(@"AVSynchronizer::destroyDecoderThread ...");
    //    if(_dispatchQueue){
    //        _dispatchQueue = nil;
    //    }
    
    isDestroyed = true;
    isOnDecoding = false;
    if (!isInitializeDecodeThread) {
        return;
    }
    
    void* status;
    pthread_mutex_lock(&videoDecoderLock);
    pthread_cond_signal(&videoDecoderCondition);
    pthread_mutex_unlock(&videoDecoderLock);
    pthread_join(videoDecoderThread, &status);
    pthread_mutex_destroy(&videoDecoderLock);
    pthread_cond_destroy(&videoDecoderCondition);
}

- (NSInteger) getAudioSampleRate;
{
    if (_decoder) {
        return [_decoder sampleRate];
    }
    return -1;
}

- (NSInteger) getAudioChannels;
{
    if (_decoder) {
        return [_decoder channels];
    }
    return -1;
}

- (CGFloat) getVideoFPS;
{
    if (_decoder) {
        return [_decoder getVideoFPS];
    }
    return 0.0f;
}

- (NSInteger) getVideoFrameHeight;
{
    if (_decoder) {
        return [_decoder frameHeight];
    }
    return 0;
}

- (NSInteger) getVideoFrameWidth;
{
    if (_decoder) {
        return [_decoder frameWidth];
    }
    return 0;
}

- (BOOL) isValid;
{
    if(_decoder && ![_decoder validVideo] && ![_decoder validAudio]){
        return NO;
    }
    return YES;
}

- (CGFloat) getDuration;
{
    if (_decoder) {
        return [_decoder getDuration];
    }
    return 0.0f;
}

- (void) dealloc;
{
    NSLog(@"AVSynchronizer Dealloc...");
}
@end
