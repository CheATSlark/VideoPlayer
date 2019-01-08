//
//  ELAudioSession.h
//  video_player
//
//  Created by apple on 16/9/5.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

extern const NSTimeInterval AUSAudioSessionLatency_Background;
extern const NSTimeInterval AUSAudioSessionLatency_Default;
extern const NSTimeInterval AUSAudioSessionLatency_LowLatency;

@interface ELAudioSession : NSObject     // 音频会话

+ (ELAudioSession *)sharedInstance;

@property(nonatomic, strong) AVAudioSession *audioSession; // Underlying system audio session 依靠系统的音频会话
@property(nonatomic, assign) Float64 preferredSampleRate;  // 偏好采样率
@property(nonatomic, assign, readonly) Float64 currentSampleRate;  // 当前采样率
@property(nonatomic, assign) NSTimeInterval preferredLatency;  // 偏好延迟时长
@property(nonatomic, assign) BOOL active;  // 是否活跃
@property(nonatomic, strong) NSString *category;  // 类别

- (void)addRouteChangeListener;
@end
