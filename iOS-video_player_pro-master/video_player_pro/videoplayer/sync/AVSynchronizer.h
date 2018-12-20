//
//  AVSynchronizer.h
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "VideoDecoder.h"

#define TIMEOUT_DECODE_ERROR            20
#define TIMEOUT_BUFFER                  10

extern NSString * const kMIN_BUFFERED_DURATION;
extern NSString * const kMAX_BUFFERED_DURATION;

// 打开状态
typedef enum OpenState{
    OPEN_SUCCESS,
    OPEN_FAILED,
    CLIENT_CANCEL,
} OpenState;

// 播放器状态回调 、 打开成功、 连接失败、 展示和隐藏加载页、 完成、 隐藏点的回调 、 重启
@protocol PlayerStateDelegate <NSObject>

- (void) openSucceed;

- (void) connectFailed;

- (void) hideLoading;

- (void) showLoading;

- (void) onCompletion;

- (void) buriedPointCallback:(BuriedPoint*) buriedPoint;

- (void) restart;

@end

@interface AVSynchronizer : NSObject

@property (nonatomic, weak) id<PlayerStateDelegate> playerStateDelegate;

- (id) initWithPlayerStateDelegate:(id<PlayerStateDelegate>) playerStateDelegate;
// 打开文件  路径、是否硬解、额外参数、
- (OpenState) openFile: (NSString *) path usingHWCodec: (BOOL) usingHWCodec
            parameters:(NSDictionary*) parameters error: (NSError **) perror;

- (OpenState) openFile: (NSString *) path usingHWCodec: (BOOL) usingHWCodec
                 error: (NSError **) perror;
// 关闭文件
- (void) closeFile;

// 音频回调 填入数据、帧数目、声道数
- (void) audioCallbackFillData: (SInt16 *) outData
                     numFrames: (UInt32) numFrames
                   numChannels: (UInt32) numChannels;
// 获取正确的视频帧
- (VideoFrame*) getCorrectVideoFrame;
// 运行、 是否打开输入成功、 暂停、 是否硬解、 播放完成
- (void) run;
- (BOOL) isOpenInputSuccess;
- (void) interrupt;

- (BOOL) usingHWCodec;

- (BOOL) isPlayCompleted;

// 获取 音频采样率、音频声道数、 视频帧率、 视频宽、高、 当前的时间
- (NSInteger) getAudioSampleRate;
- (NSInteger) getAudioChannels;
- (CGFloat) getVideoFPS;
- (NSInteger) getVideoFrameHeight;
- (NSInteger) getVideoFrameWidth;
- (BOOL) isValid;
- (CGFloat) getDuration;

@end
