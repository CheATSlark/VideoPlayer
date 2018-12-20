//
//  VideoToolboxDecoder.h
//  video_player
//
//  Created by apple on 16/9/6.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <VideoToolbox/VideoToolbox.h>
#import "VideoDecoder.h"

@protocol H264DecoderDelegate <NSObject>
@optional
// 获取解压的图像数据
-(void) getDecodeImageData:(CVImageBufferRef) imageBuffer;
@end

@interface VideoToolboxDecoder : VideoDecoder
// H264解码代理
@property (nonatomic, strong) id <H264DecoderDelegate> delegate;
// 视频格式的描述
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDesc;
// Video Tool 解压会话
@property (nonatomic, assign) VTDecompressionSessionRef decompressionSession;
@end
