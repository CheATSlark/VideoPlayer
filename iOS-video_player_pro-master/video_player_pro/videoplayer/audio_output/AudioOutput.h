//
//  AudioOutput.h
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol FillDataDelegate <NSObject>

- (NSInteger) fillAudioData:(SInt16*) sampleBuffer numFrames:(NSInteger)frameNum numChannels:(NSInteger)channels;

@end

@interface AudioOutput : NSObject

@property(nonatomic, assign) Float64 sampleRate;    //样本率
@property(nonatomic, assign) Float64 channels;   //声道

- (id) initWithChannels:(NSInteger) channels sampleRate:(NSInteger) sampleRate bytesPerSample:(NSInteger) bytePerSample filleDataDelegate:(id<FillDataDelegate>) fillAudioDataDelegate;

- (BOOL) play;
- (void) stop;

@end
