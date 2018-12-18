//
//  VideoDecoder.m
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "VideoDecoder.h"
#import <Accelerate/Accelerate.h>


// 复制 帧数据 
static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height)
{
    // 行数大小 和 宽度的最小值
    width = MIN(linesize, width);
    // 按照数据大小生成md
    NSMutableData *md = [NSMutableData dataWithLength: width * height];
    // 字节数
    Byte *dst = md.mutableBytes;
    // 在行数内
    for (NSUInteger i = 0; i < height; ++i) {
        // 把 每行的数据 copy 到dst上
        memcpy(dst, src, width);
        // 字节加上宽度
        dst += width;
        // 数据加上每行的大小
        src += linesize;
    }
    return md;
}

static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase)
{
    // 设置 fps、timebase 
    CGFloat fps, timebase;
    // 如果流的 帧的时间戳（以秒为单位）的分母、分子 存在
    if (st->time_base.den && st->time_base.num)
        // 把时间戳结构体 转换成浮点类型
        timebase = av_q2d(st->time_base);
    else if(st->codec->time_base.den && st->codec->time_base.num)
        timebase = av_q2d(st->codec->time_base);
    else
        timebase = defaultTimeBase;
    
    // 帧每秒流失的时间
    if (st->codec->ticks_per_frame != 1) {
        NSLog(@"WARNING: st.codec.ticks_per_frame=%d", st->codec->ticks_per_frame);
        //timebase *= st->codec->ticks_per_frame;
    }
    
    // 平均帧率的 分母、分子 存在
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    // 真实的帧率
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    if (pFPS)
        *pFPS = fps;
    if (pTimeBase)
        *pTimeBase = timebase;
}

static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType)
{
    NSMutableArray *ma = [NSMutableArray array];
    // 遍历文本中的流数目
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i)
        // 如果是视频帧 把指数添加到数组
        if (codecType == formatCtx->streams[i]->codec->codec_type)
            [ma addObject: [NSNumber numberWithInteger: i]];
    return [ma copy];
}


@implementation Frame

@end

@implementation AudioFrame

@end

@implementation VideoFrame

@end

@implementation BuriedPoint

@end

@interface VideoDecoder () {
    
    AVFrame*                    _videoFrame;
    AVFrame*                    _audioFrame;
    
    CGFloat                     _fps;
    
    CGFloat                     _decodePosition;
    
    BOOL                        _isSubscribe;
    BOOL                        _isEOF;
    
    SwrContext*                 _swrContext;
    void*                       _swrBuffer;
    NSUInteger                  _swrBufferSize;
    
    AVPicture                   _picture;
    BOOL                        _pictureValid;
    struct SwsContext*          _swsContext;
    
    int                         _subscribeTimeOutTimeInSecs;
    int                         _readLastestFrameTime;
    
    BOOL                        _interrupted;
    
    int                         _connectionRetry;
}

@end

@implementation VideoDecoder

// interrupt 回调
static int interrupt_callback(void *ctx)
{
    if (!ctx)
        return 0;
    __unsafe_unretained VideoDecoder *p = (__bridge VideoDecoder *)ctx;
    const BOOL r = [p detectInterrupted];
    if (r) NSLog(@"DEBUG: INTERRUPT_CALLBACK!");
    return r;
}

- (void) interrupt
{
    _subscribeTimeOutTimeInSecs = -1;
    _interrupted = YES;
    _isSubscribe = NO;
}

- (BOOL) detectInterrupted
{
    // 当前事后 和最后一帧读取时间的差 大于 订阅超时
    if ([[NSDate date] timeIntervalSince1970] - _readLastestFrameTime > _subscribeTimeOutTimeInSecs) {
        return YES;
    }
    return _interrupted;
}

- (BOOL) openFile: (NSString *) path parameter:(NSDictionary*) parameters error: (NSError **) perror
{
    BOOL ret = YES;
    if (nil == path) {
        return NO;
    }
    _connectionRetry = 0;   // 重试次数
    totalVideoFramecount = 0;  //整个视频帧数
    _subscribeTimeOutTimeInSecs = SUBSCRIBE_VIDEO_DATA_TIME_OUT;   //订阅超时时间
    _interrupted = NO;  // 没有暂停
    _isOpenInputSuccess = NO;  // 没有打开成功
    _isSubscribe = YES;  // 是订阅
    
    // 实例化 buriedPoint
    _buriedPoint = [[BuriedPoint alloc] init];
    // 实例化记录状态
    _buriedPoint.bufferStatusRecords = [[NSMutableArray alloc] init];
    // 上一次读取时间
    _readLastestFrameTime = [[NSDate date] timeIntervalSince1970];
    
    // FFmpeg 初始化
    avformat_network_init();
    av_register_all();
    
    // 记录初始时间
    _buriedPoint.beginOpen = [[NSDate date] timeIntervalSince1970] * 1000;
    // 打开文件
    int openInputErrCode = [self openInput:path parameter:parameters];
    if(openInputErrCode > 0) {
        _buriedPoint.successOpen = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
        _buriedPoint.failOpen = 0.0f;
        _buriedPoint.failOpenType = 1;
        BOOL openVideoStatus = [self openVideoStream];
        BOOL openAudioStatus = [self openAudioStream];
        if(!openVideoStatus || !openAudioStatus){
            [self closeFile];
            ret = NO;
        }
    } else {
        _buriedPoint.failOpen = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
        _buriedPoint.successOpen = 0.0f;
        _buriedPoint.failOpenType = openInputErrCode;
        ret = NO;
    }
    _buriedPoint.retryTimes = _connectionRetry;
    if(ret){
        //在网络的播放器中有可能会拉到长宽都为0 并且pix_fmt是None的流 这个时候我们需要重连
        NSInteger videoWidth = [self frameWidth];
        NSInteger videoHeight = [self frameHeight];
        int retryTimes = 5;
        while(((videoWidth <= 0 || videoHeight <= 0) && retryTimes > 0)){
            NSLog(@"because of videoWidth and videoHeight is Zero We will Retry...");
            usleep(500 * 1000);
            _connectionRetry = 0;
            ret = [self openFile:path parameter:parameters error:perror];
            if(!ret){
                //如果打开失败 则退出
                break;
            }
            retryTimes--;
            videoWidth = [self frameWidth];
            videoHeight = [self frameHeight];
        }
    }
    _isOpenInputSuccess = ret;
    return ret;
}

- (BOOL) isOpenInputSuccess
{
    return _isOpenInputSuccess;
}

- (BOOL) openVideoStream;
{
    // 重置解码流指数
    _videoStreamIndex = -1;
    // 获得视频帧的指数NSNumber集合
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        // 视频流指数
        const NSUInteger iStream = n.integerValue;
        // 获取解码的文本
        AVCodecContext *codecCtx = _formatCtx->streams[iStream]->codec;
        // 获得 AVCodec
        AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
        
        if (!codec) {
            NSLog(@"Find Video Decoder Failed codec_id %d CODEC_ID_H264 is %d", codecCtx->codec_id, CODEC_ID_H264);
            return NO;
        }
        int openCodecErrCode = 0;
        // 用给定的codec 实例化 codecCtx   这不是一个线程安全的函数
        if ((openCodecErrCode = avcodec_open2(codecCtx, codec, NULL)) < 0) {
            NSLog(@"open Video Codec Failed openCodecErr is %s", av_err2str(openCodecErrCode));
            return NO;
        }
        
        // 开辟视频帧内存
        _videoFrame = avcodec_alloc_frame();
        if (!_videoFrame) {
            NSLog(@"Alloc Video Frame Failed...");
            avcodec_close(codecCtx);
            return NO;
        }
        
        // 视频帧 指数 、 视频帧编码内容
        _videoStreamIndex = iStream;
        _videoCodecCtx = codecCtx;
        // determine fps
        // 获取视频流
        AVStream *st = _formatCtx->streams[_videoStreamIndex];
        // 获取视频 fps 和 视频基准时间
        avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
        break;
    }
    return YES;
}

- (BOOL) openAudioStream;
{
    _audioStreamIndex = -1;
    _audioStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        const NSUInteger iStream = [n integerValue];
        AVCodecContext *codecCtx = _formatCtx->streams[iStream]->codec;
        AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
        if(!codec){
            NSLog(@"Find Audio Decoder Failed codec_id %d CODEC_ID_AAC is %d", codecCtx->codec_id, CODEC_ID_AAC);
            return NO;
        }
        
        int openCodecErrCode = 0;
        if ((openCodecErrCode = avcodec_open2(codecCtx, codec, NULL)) < 0){
            NSLog(@"Open Audio Codec Failed openCodecErr is %s", av_err2str(openCodecErrCode));
            return NO;
        }
        
        SwrContext *swrContext = NULL;
        if(![self audioCodecIsSupported:codecCtx]){
            NSLog(@"because of audio Codec Is Not Supported so we will init swresampler...");
            /**
             * 初始化resampler
             * @param s               Swr context, can be NULL
             * @param out_ch_layout   output channel layout (AV_CH_LAYOUT_*)
             * @param out_sample_fmt  output sample format (AV_SAMPLE_FMT_*).
             * @param out_sample_rate output sample rate (frequency in Hz)
             * @param in_ch_layout    input channel layout (AV_CH_LAYOUT_*)
             * @param in_sample_fmt   input sample format (AV_SAMPLE_FMT_*).
             * @param in_sample_rate  input sample rate (frequency in Hz)
             * @param log_offset      logging level offset
             * @param log_ctx         parent logging context, can be NULL
             */
            swrContext = swr_alloc_set_opts(NULL, av_get_default_channel_layout(codecCtx->channels), AV_SAMPLE_FMT_S16, codecCtx->sample_rate, av_get_default_channel_layout(codecCtx->channels), codecCtx->sample_fmt, codecCtx->sample_rate, 0, NULL);
            if (!swrContext || swr_init(swrContext)) {
                if (swrContext)
                    swr_free(&swrContext);
                avcodec_close(codecCtx);
                NSLog(@"init resampler failed...");
                return NO;
            }
            
            
            _audioFrame = avcodec_alloc_frame();
            if (!_audioFrame) {
                NSLog(@"Alloc Audio Frame Failed...");
                if (swrContext)
                    swr_free(&swrContext);
                avcodec_close(codecCtx);
                return NO;
            }
            
            _audioStreamIndex = iStream;
            _audioCodecCtx = codecCtx;
            _swrContext = swrContext;
            
            AVStream *st = _formatCtx->streams[_audioStreamIndex];
            avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
            break;
        }
    }
    return YES;
}


- (BOOL) audioCodecIsSupported:(AVCodecContext *) audioCodecCtx;
{
    if (audioCodecCtx->sample_fmt == AV_SAMPLE_FMT_S16) {
        return true;
    }
    return false;
}

- (int) openInput: (NSString*) path parameter:(NSDictionary*) parameters;
{
    // 初始化 格式内容
    AVFormatContext *formatCtx = avformat_alloc_context();
    // 初始化暂停的回调
    AVIOInterruptCB int_cb  = {interrupt_callback, (__bridge void *)(self)};
    // 赋值
    formatCtx->interrupt_callback = int_cb;
    
    
    int openInputErrCode = 0;
    // 打开指定路径 和参数的文件 获取 formatCtx
    if ((openInputErrCode = [self openFormatInput:&formatCtx path:path parameter:parameters]) != 0) {
        // 失败
        NSLog(@"Video decoder open input file failed... videoSourceURI is %@ openInputErr is %s", path, av_err2str(openInputErrCode));
        // 释放内存
        if (formatCtx)
            avformat_free_context(formatCtx);
        return openInputErrCode;
    }
    
    // 初始化随着时间和大小解析
    [self initAnalyzeDurationAndProbesize:formatCtx parameter:parameters];
    
    
    int findStreamErrCode = 0;
    double startFindStreamTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
    if ((findStreamErrCode = avformat_find_stream_info(formatCtx, NULL)) < 0) {
        avformat_close_input(&formatCtx);
        avformat_free_context(formatCtx);
        NSLog(@"Video decoder find stream info failed... find stream ErrCode is %s", av_err2str(findStreamErrCode));
        return findStreamErrCode;
    }
    int wasteTimeMills = CFAbsoluteTimeGetCurrent() * 1000 - startFindStreamTimeMills;
    NSLog(@"Find Stream Info waste TimeMills is %d", wasteTimeMills);
    if (formatCtx->streams[0]->codec->codec_id == AV_CODEC_ID_NONE) {
        avformat_close_input(&formatCtx);
        avformat_free_context(formatCtx);
        NSLog(@"Video decoder First Stream Codec ID Is UnKnown...");
        if([self isNeedRetry]){
            return [self openInput:path parameter:parameters];
        } else {
            return -1;
        }
    }
    _formatCtx = formatCtx;
    return 1;
}

- (int) openFormatInput:(AVFormatContext**) formatCtx path:(NSString*) path parameter:(NSDictionary*) parameters
{
    // 转换路径为UTF8的字符串
    const char* videoSourceURI = [path cStringUsingEncoding: NSUTF8StringEncoding];
    AVDictionary *options = NULL;
    //RTMP_TCURL_KEY 获取参数的 URL 路径
    NSString* rtmpTcurl = parameters[RTMP_TCURL_KEY];
    if([rtmpTcurl length] > 0){
        const char *rtmp_tcurl = [rtmpTcurl cStringUsingEncoding: NSUTF8StringEncoding];
        // 设置字典
        av_dict_set(&options, "rtmp_tcurl", rtmp_tcurl, 0);
    }
    return avformat_open_input(formatCtx, videoSourceURI, NULL, &options);
}

- (void) initAnalyzeDurationAndProbesize:(AVFormatContext *)formatCtx parameter:(NSDictionary*) parameters
{
    // 获取参数中的尺寸
    float probeSize = [parameters[PROBE_SIZE] floatValue];
    // 赋值formatCtx 的尺寸
    formatCtx->probesize = probeSize ?: 50 * 1024;
    // 获取时间数组
    NSArray* durations = parameters[MAX_ANALYZE_DURATION_ARRAY];
    if (durations && durations.count > _connectionRetry) {
        formatCtx->max_analyze_duration = [durations[_connectionRetry] floatValue];
    } else {
        float multiplier = 0.5 + (double)pow(2.0, (double)_connectionRetry) * 0.25;
        formatCtx->max_analyze_duration = multiplier * AV_TIME_BASE;
    }
//    formatCtx->max_analyze_duration = 75000;
    BOOL fpsProbeSizeConfiged = [parameters[FPS_PROBE_SIZE_CONFIGURED] boolValue];
    if(fpsProbeSizeConfiged){
        formatCtx->fps_probe_size = 3;
    }
}

- (BOOL) isNeedRetry
{
    _connectionRetry++;
    return _connectionRetry <= NET_WORK_STREAM_RETRY_TIME;
}

// 解码包
- (VideoFrame*) decodeVideo:(AVPacket) packet packetSize:(int) pktSize decodeVideoErrorState:(int *)decodeVideoErrorState;
{
    VideoFrame *frame = nil;
    while (pktSize > 0) {
        int gotframe = 0;
        // 视频帧的字节长度
        int len = avcodec_decode_video2(_videoCodecCtx, _videoFrame,
                                        &gotframe,
                                        &packet);
        if (len < 0) {
            NSLog(@"decode video error, skip packet %s", av_err2str(len));
            *decodeVideoErrorState = 1;
            break;
        }
        
        if (gotframe) {
            frame = [self handleVideoFrame];
        }
        if (0 == len)
            break;
        pktSize -= len;
    }
    return frame;
}

- (NSArray *) decodeFrames: (CGFloat) minDuration decodeVideoErrorState:(int *)decodeVideoErrorState
{
    // 若没有启动状态，则返回
    if (_videoStreamIndex == -1 && _audioStreamIndex == -1)
        return nil;
    
    NSMutableArray *result = [NSMutableArray array];
    AVPacket packet;
    CGFloat decodedDuration = 0;
    BOOL finished = NO;
    
    while (!finished) {
        // 如果读取下一帧  如果等于0 是读取成功，小于0 错误或读到最后
        if (av_read_frame(_formatCtx, &packet) < 0) {
            // 标志文件读取结束
            _isEOF = YES;
            break;
        }
        // 数据包 的 大小、流的指数
        int pktSize = packet.size;
        int pktStreamIndex = packet.stream_index;
        // 如果包的流指数 是视频流指数
        if (pktStreamIndex ==_videoStreamIndex) {
            // 获取当前的时间
            double startDecodeTimeMills = CFAbsoluteTimeGetCurrent() * 1000;
            // 获取视频帧
            VideoFrame* frame = [self decodeVideo:packet packetSize:pktSize decodeVideoErrorState:decodeVideoErrorState];
            // 计算消耗时长
            int wasteTimeMills =CFAbsoluteTimeGetCurrent() * 1000 - startDecodeTimeMills;
            // 解码视频帧总时长累加
            decodeVideoFrameWasteTimeMills += wasteTimeMills;
            
            if(frame){
                // 累计视频帧数
                totalVideoFramecount++;
                // 添加到数组中
                [result addObject:frame];
                // 计算总时长  如果时长大于总解码时长，则完成
                decodedDuration += frame.duration;
                if (decodedDuration > minDuration)
                    finished = YES;
            }
        }// 如果包的指数是音频流指数
        else if (pktStreamIndex == _audioStreamIndex) {
            while (pktSize > 0) {
                int gotframe = 0;
                // 从avpacket 获取 大小和 和尺寸
                int len = avcodec_decode_audio4(_audioCodecCtx, _audioFrame,
                                                &gotframe,
                                                &packet);
                
                if (len < 0) {
                    NSLog(@"decode audio error, skip packet");
                    break;
                }
                // gotframe 大于0 说明可以解码
                if (gotframe) {
                    // 获取音频帧
                    AudioFrame * frame = [self handleAudioFrame];
                    if (frame) {
                        // 添加音频帧
                        [result addObject:frame];
                        if (_videoStreamIndex == -1) {
                            // 如果是初始化第一帧 记录解码的位置
                            _decodePosition = frame.position;
                            // 计算总解码时长
                            decodedDuration += frame.duration;
                            if (decodedDuration > minDuration)
                                finished = YES;
                        }
                    }
                }
                if (0 == len)
                    break;
                //减去 已经解码的字节大小
                pktSize -= len;
            }
        } else {
            NSLog(@"We Can Not Process Stream Except Audio And Video Stream...");
        }
        // 释放packet
        av_free_packet(&packet);
    }
//    NSLog(@"decodedDuration is %.3f", decodedDuration);
    // 读取最后一帧的时间
    _readLastestFrameTime = [[NSDate date] timeIntervalSince1970];
    return result;
}

- (BuriedPoint*) getBuriedPoint;
{
    return _buriedPoint;
}

- (VideoFrame *) handleVideoFrame
{
    // 如果没哟数据返回
    if (!_videoFrame->data[0])
        return nil;
    // 开辟视频帧空间
    VideoFrame *frame = [[VideoFrame alloc] init];
    // 如果视频编码文本的像素格式 是 YUV420P 或者 YUVJ420P
    if(_videoCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt == AV_PIX_FMT_YUVJ420P){
        
        frame.luma = copyFrameData(_videoFrame->data[0],
                                      _videoFrame->linesize[0],
                                      _videoCodecCtx->width,
                                      _videoCodecCtx->height);
        
        frame.chromaB = copyFrameData(_videoFrame->data[1],
                                         _videoFrame->linesize[1],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
        
        frame.chromaR = copyFrameData(_videoFrame->data[2],
                                         _videoFrame->linesize[2],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
    } else{
        // 如果没有重构对象 失败
        if (!_swsContext &&
            ![self setupScaler]) {
            NSLog(@"fail setup video scaler");
            return nil;
        }
        // 把每行的 数据放在图片中 从Y=0 和 height 开始
        sws_scale(_swsContext,
                  (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodecCtx->height,
                  _picture.data,
                  _picture.linesize);
        
        frame.luma = copyFrameData(_picture.data[0],
                                   _picture.linesize[0],
                                   _videoCodecCtx->width,
                                   _videoCodecCtx->height);
        
        frame.chromaB = copyFrameData(_picture.data[1],
                                      _picture.linesize[1],
                                      _videoCodecCtx->width / 2,
                                      _videoCodecCtx->height / 2);
        
        frame.chromaR = copyFrameData(_picture.data[2],
                                      _picture.linesize[2],
                                      _videoCodecCtx->width / 2,
                                      _videoCodecCtx->height / 2);
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    
    frame.linesize = _videoFrame->linesize[0];
    
    frame.type = VideoFrameType;
    frame.position = av_frame_get_best_effort_timestamp(_videoFrame) * _videoTimeBase;
    const int64_t frameDuration = av_frame_get_pkt_duration(_videoFrame);
    if (frameDuration) {
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase * 0.5;
    } else {
        // sometimes, ffmpeg unable to determine a frame duration
        // as example yuvj420p stream from web camera
        frame.duration = 1.0 / _fps;
    }
//    if(totalVideoFramecount == 30){
//        //软件解码的第31帧写入文件
//        NSString* softDecoderFrame30FilePath = [CommonUtil documentsPath:@"soft_decoder_30.yuv"];
//        NSMutableData* data1 = [[NSMutableData alloc] init];
//        [data1 appendData:frame.luma];
//        [data1 appendData:frame.chromaB];
//        [data1 appendData:frame.chromaR];
//        [data1 writeToFile:softDecoderFrame30FilePath atomically:YES];
//    } else if(totalVideoFramecount == 60) {
//        //软件解码的第61帧写入文件
//        NSString* softDecoderFrame60FilePath = [CommonUtil documentsPath:@"soft_decoder_60.yuv"];
//        NSMutableData* data1 = [[NSMutableData alloc] init];
//        [data1 appendData:frame.luma];
//        [data1 appendData:frame.chromaB];
//        [data1 appendData:frame.chromaR];
//        [data1 writeToFile:softDecoderFrame60FilePath atomically:YES];
//    }
//    NSLog(@"Add Video Frame position is %.3f", frame.position);
    return frame;
}

- (AudioFrame *) handleAudioFrame
{
    // 如果音频帧的数据不存在 则返回空
    if (!_audioFrame->data[0])
        return nil;
    // 声道数目
    const NSUInteger numChannels = _audioCodecCtx->channels;
    //
    NSInteger numFrames;
    
    void * audioData;
    
    if (_swrContext) {
        const NSUInteger ratio = 2;
        // 对于给定的音频参数获得需要的缓存大小  nb_samples 帧的声道的采样数目  采样格式AV_SAMPLE_FMT_S16  采样的线形 默认0
        const int bufSize =  av_samples_get_buffer_size(NULL, (int)numChannels, (int)(_audioFrame->nb_samples * ratio), AV_SAMPLE_FMT_S16, 1);
        
        // 如果重采样的缓存不存在 或者重采样的字节空间太小
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            // 重新生成 _swrBufferSize 和 _swrBuffer
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        // 输出字节
        Byte *outbuf[2] = { _swrBuffer, 0 };
        // 转换音频 每个声道采样数目
        numFrames = swr_convert(_swrContext,
                                outbuf,
                                (int)(_audioFrame->nb_samples * ratio),
                                (const uint8_t **)_audioFrame->data,
                                _audioFrame->nb_samples);
        if (numFrames < 0) {
            NSLog(@"fail resample audio");
            return nil;
        }
        audioData = _swrBuffer;
    } else {
        // 如果是AV_SAMPLE_FMT_S16
        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSLog(@"Audio format is invalid");
            return nil;
        }
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
    // 元素个数
    const NSUInteger numElements = numFrames * numChannels;
    // 开辟pcm 数据
    NSMutableData *pcmData = [NSMutableData dataWithLength:numElements * sizeof(SInt16)];
    // 内存拷贝
    memcpy(pcmData.mutableBytes, audioData, numElements * sizeof(SInt16));
    // 实例化 音频帧
    AudioFrame *frame = [[AudioFrame alloc] init];
    // 获取最佳的时间
    frame.position = av_frame_get_best_effort_timestamp(_audioFrame) * _audioTimeBase;
    // 获取packet的时长
    frame.duration = av_frame_get_pkt_duration(_audioFrame) * _audioTimeBase;
    
    frame.samples = pcmData;
    frame.type = AudioFrameType;
//    NSLog(@"Add Audio Frame position is %.3f", frame.position);
    return frame;
}

// 出发第一屏幕
- (void) triggerFirstScreen
{
    if (_buriedPoint.failOpenType == 1) {
        _buriedPoint.firstScreenTimeMills = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    }
}

// 添加缓冲状态的记录
- (void) addBufferStatusRecord:(NSString*) statusFlag
{
    // 如果等于“F” 且 buriedPoint 的拉流状态 最后一个头是 F_ 返回
    if ([@"F" isEqualToString:statusFlag] && [[_buriedPoint.bufferStatusRecords lastObject] hasPrefix:@"F_"]) {
        return;
    }
    //记录时间和状态
    float timeInterval = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    [_buriedPoint.bufferStatusRecords addObject:[NSString stringWithFormat:@"%@_%.3f", statusFlag, timeInterval]];
}

- (void) closeFile;
{
    NSLog(@"Enter closeFile...");
    if (_buriedPoint.failOpenType == 1) {
        // 记录时长
        _buriedPoint.duration = ([[NSDate date] timeIntervalSince1970] * 1000 - _buriedPoint.beginOpen) / 1000.0f;
    }
    //暂停 重置订阅超时时长  是暂停 未订阅
    [self interrupt];
    
    // 关闭音频流和视频流
    [self closeAudioStream];
    [self closeVideoStream];
    
    // 置空
    _videoStreams = nil;
    _audioStreams = nil;
    
    // 格式文本存在  置空
    if (_formatCtx) {
        _formatCtx->interrupt_callback.opaque = NULL;
        _formatCtx->interrupt_callback.callback = NULL;
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
    // 解码的平均时长
    float decodeFrameAVGTimeMills = (double)decodeVideoFrameWasteTimeMills / (float)totalVideoFramecount;
    NSLog(@"Decoder decoder totalVideoFramecount is %d decodeFrameAVGTimeMills is %.3f", totalVideoFramecount, decodeFrameAVGTimeMills);
}

- (void) closeAudioStream;
{
    _audioStreamIndex = -1;
    
    if (_swrBuffer) {
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    
    if (_audioFrame) {
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    
    if (_audioCodecCtx) {
        avcodec_close(_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}

- (void) closeVideoStream;
{
    // 重置指数
    _videoStreamIndex = -1;
    
    // 关闭纯量 关闭重采样 和图片
    [self closeScaler];
    
    // 释放帧 和 编码文本
    if (_videoFrame) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if (_videoCodecCtx) {
        avcodec_close(_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}


- (BOOL) setupScaler
{
    [self closeScaler];
    _pictureValid = avpicture_alloc(&_picture,
                                    PIX_FMT_YUV420P,
                                    _videoCodecCtx->width,
                                    _videoCodecCtx->height) == 0;
    if (!_pictureValid)
        return NO;
    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       _videoCodecCtx->pix_fmt,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       PIX_FMT_YUV420P,
                                       SWS_FAST_BILINEAR,
                                       NULL, NULL, NULL);
    return _swsContext != NULL;
}

- (void) closeScaler
{
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if (_pictureValid) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}

- (BOOL) isEOF;
{
    return _isEOF;
}

- (BOOL) isSubscribed;
{
    return _isSubscribe;
}

- (NSUInteger) frameWidth;
{
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (NSUInteger) frameHeight;
{
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}

- (CGFloat) sampleRate;
{
    return _audioCodecCtx ? _audioCodecCtx->sample_rate : 0;
}

- (NSUInteger) channels;
{
    return _audioCodecCtx ? _audioCodecCtx->channels : 0;
}

- (BOOL) validVideo;
{
    return _videoStreamIndex != -1;
}

- (BOOL) validAudio;
{
    return _audioStreamIndex != -1;
}

- (CGFloat) getVideoFPS;
{
    return _fps;
}
- (CGFloat) getDuration;
{
    if(_formatCtx){
        // 没有提供tpts的值
        if(_formatCtx->duration == AV_NOPTS_VALUE){
            return -1;
        }
        // 格式文本的时长 / 1000000
        return _formatCtx->duration / AV_TIME_BASE;
    }
    return -1;
}

- (void) dealloc;
{
    NSLog(@"VideoDecoder Dealloc...");
}
@end
