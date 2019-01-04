//
//  YUVFrameFastCopier.m
//  video_player
//
//  Created by apple on 16/9/7.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "YUVFrameFastCopier.h"
#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)
// 颜色转换常量（YUV 到 RGB） 包含适应从 16-235 / 16- 240 （视频范围）

// BT.601, which is the standard for SDTV.
// YCbCr 是标准数字电视
__unused static const GLfloat kColorConversion601[] = {
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
};

GLfloat kColorConversion601FullRangeDefault[] = {
    1.0,    1.0,    1.0,
    0.0,    -0.343, 1.765,
    1.4,    -0.711, 0.0,
};

GLfloat kColorConversion601FullRange[] = {
    1.0,    1.0,    1.0,
    0.0,    -0.39465, 2.03211,
    1.13983,-0.58060, 0.0,
};

// BT.709, which is the standard for HDTV.
// YCbCr 是高清数字电视
static const GLfloat kColorConversion709[] = {
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
};

// 字符化
NSString *const yuvFasterVertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec2 texcoord;
 uniform mat4 modelViewProjectionMatrix;
 varying vec2 v_texcoord;
 
 void main()
 {
     gl_Position = modelViewProjectionMatrix * position;
     v_texcoord = texcoord.xy;
 }
 );
/**
 * 
 * Passthrough shader for displaying CVPixelbuffers
 *
 **/
// 传递着色器为了展示CVPixelBuffer
NSString *const yuvFasterFragmentShaderString = SHADER_STRING
(
 varying highp vec2 v_texcoord;
 precision mediump float;
 
 uniform sampler2D inputImageTexture;
 uniform sampler2D SamplerUV;
 uniform mat3 colorConversionMatrix;
 
 void main()
 {
     mediump vec3 yuv;
     lowp vec3 rgb;
     
     // Subtract constants to map the video range start at 0
//     yuv.x = (texture2D(inputImageTexture, v_texcoord).r - (16.0/255.0));
     //     yuv.yz = (texture2D(SamplerUV, v_texcoord).rg - vec2(0.5, 0.5));
     yuv.x = texture2D(inputImageTexture, v_texcoord).r;
     yuv.yz = texture2D(SamplerUV, v_texcoord).ra - vec2(0.5, 0.5);
     
     rgb = colorConversionMatrix * yuv;
     
     gl_FragColor = vec4(rgb,1);
 }
);
@interface YUVFrameFastCopier(){
    GLuint                              _framebuffer;    //帧缓存
    GLuint                              _outputTextureID;  // 输出内容ID
    
    GLint                               _uniformMatrix;  // 格式矩阵
    GLint                               _chromaInputTextureUniform;
    GLint                               _colorConversionMatrixUniform;
    
    CVOpenGLESTextureRef                _lumaTexture;    //亮度内容
    CVOpenGLESTextureRef                _chromaTexture;  // 色度内容
    CVOpenGLESTextureCacheRef           _videoTextureCache;  // 视频内容缓存
    const GLfloat*                      _preferredConversion; //偏好转换
    
    CVPixelBufferPoolRef                _pixelBufferPool;  //像素缓存池
}

@end
@implementation YUVFrameFastCopier

- (BOOL) prepareRender:(NSInteger) frameWidth height:(NSInteger) frameHeight;
{
    BOOL ret = NO;
    // 按照 vertexShader 和 fragmentShader 创建 program
    if([self buildProgram:yuvFasterVertexShaderString fragmentShader:yuvFasterFragmentShaderString]) {
        // 获取 SamplerUV
        _chromaInputTextureUniform = glGetUniformLocation(filterProgram, "SamplerUV");
        //
        _colorConversionMatrixUniform = glGetUniformLocation(filterProgram, "colorConversionMatrix");
        
        glUseProgram(filterProgram);
        glEnableVertexAttribArray(filterPositionAttribute);
        glEnableVertexAttribArray(filterTextureCoordinateAttribute);
        
        //生成FBO And TextureId
        glGenFramebuffers(1, &_framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        
        // 进行输出配置
        glActiveTexture(GL_TEXTURE1);
        glGenTextures(1, &_outputTextureID);
        glBindTexture(GL_TEXTURE_2D, _outputTextureID);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (int)frameWidth, (int)frameHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, 0);
        NSLog(@"width=%d, height=%d", (int)frameWidth, (int)frameHeight);
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _outputTextureID, 0);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"failed to make complete framebuffer object %x", status);
        }
        
        glBindTexture(GL_TEXTURE_2D, 0);
        // Create CVOpenGLESTextureCacheRef for optimal CVPixelBufferRef to GLES texture conversion.
        if (!_videoTextureCache) {
            EAGLContext* context = [EAGLContext currentContext];
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, context, NULL, &_videoTextureCache);
            if (err != noErr) {
                NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
                return NO;
            }
        }
        
        // Set the default conversion to BT.709, which is the standard for HDTV.
        _preferredConversion = kColorConversion709;
        _preferredConversion = kColorConversion601FullRange;
//        _preferredConversion = kColorConversion601FullRangeDefault;
//        _preferredConversion = kColorConversion601;
        
        ret = YES;
    }
    return ret;
}

- (GLint) outputTextureID;
{
    return _outputTextureID;
}

- (void) uploadTexture:(VideoFrame*) videoFrame width:(int) frameWidth height:(int) frameHeight;
{
    // 这是用code Video 进行
    // 图像缓存
    CVImageBufferRef pixelBuffer = nil;
    if(videoFrame.type == VideoFrameType){
        // 视频类型
        pixelBuffer = [self buildCVPixelBufferByVideoFrame:videoFrame width:frameWidth height:frameHeight];
    } else if(videoFrame.type == iOSCVVideoFrameType) {
        // 硬解的像素
        pixelBuffer = (__bridge CVImageBufferRef)videoFrame.imageBuffer;
//        CFTypeRef colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
//        if (colorAttachments != NULL)
//        {
//            if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
//            {
//                NSLog(@"color Attachments is kCVImageBufferYCbCrMatrix_ITU_R_601_4...");
//            }
//        }
    }
    if (pixelBuffer) {
        [self cleanUpTextures];
        glActiveTexture(GL_TEXTURE0);
        
        CVReturn err;
        // 创建_videoTextureCache  _lumaTexture
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           _videoTextureCache,
                                                           pixelBuffer,
                                                           NULL,
                                                           GL_TEXTURE_2D,
//                                                           GL_RED_EXT,
                                                           GL_LUMINANCE,
                                                           frameWidth,
                                                           frameHeight,
                                                           GL_LUMINANCE,
//                                                           GL_RED_EXT,
                                                           GL_UNSIGNED_BYTE,
                                                           0,
                                                           &_lumaTexture);
        if (err) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
        // 纹理过滤
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        // UV-plane.
        glActiveTexture(GL_TEXTURE1);
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           _videoTextureCache,
                                                           pixelBuffer,
                                                           NULL,
                                                           GL_TEXTURE_2D,
                                                           GL_LUMINANCE_ALPHA,
//                                                           GL_RG_EXT,
                                                           frameWidth / 2,
                                                           frameHeight / 2,
//                                                           GL_RG_EXT,
                                                           GL_LUMINANCE_ALPHA,
                                                           GL_UNSIGNED_BYTE,
                                                           1,
                                                           &_chromaTexture);
        if (err) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        if(videoFrame.type == VideoFrameType){
            CFRelease(pixelBuffer);
        }
    }
}

- (CVPixelBufferRef) buildCVPixelBufferByVideoFrame:(VideoFrame*) videoFrame width:(int) frameWidth height:(int) frameHeight;
{
    CVPixelBufferRef pixelBuffer = nil;
    CVReturn error;
    if(!_pixelBufferPool){
        NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
        [attributes setObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
//        [attributes setObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
        [attributes setObject:[NSNumber numberWithInt:frameWidth] forKey:(NSString*) kCVPixelBufferWidthKey];
        [attributes setObject:[NSNumber numberWithInt:frameHeight] forKey:(NSString*) kCVPixelBufferHeightKey];
        [attributes setObject:@(videoFrame.linesize) forKey:(NSString*) kCVPixelBufferBytesPerRowAlignmentKey];
        [attributes setObject:[NSDictionary dictionary] forKey:(NSString*)kCVPixelBufferIOSurfacePropertiesKey];
        // 创建pixelBufferPool  一个新的像素缓存池
        error = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pixelBufferPool);
        if(error != kCVReturnSuccess){
            NSLog(@"CVPixelBufferPool Create Failed...");
        }
    }
    if(!_pixelBufferPool){
        NSLog(@"pixelBuffer Pool is NULL...");
    }
    // 从缓存池中创建一个新的像素缓存对象
    CVPixelBufferPoolCreatePixelBuffer(NULL, _pixelBufferPool, &pixelBuffer);
    if(!pixelBuffer){
        NSLog(@"CVPixelBufferPoolCreatePixelBuffer Failed...");
    }
    
    // 双平面
    size_t bytePerRowY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t bytePerRowUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    int lumaDataSize = (int)bytePerRowY * frameHeight;
    uint8_t* lumaData = malloc(lumaDataSize);
    uint8_t* luma = (uint8_t*)videoFrame.luma.bytes;
    for(int i = 0; i < frameHeight; i++) {
        memcpy(lumaData, luma, frameWidth);
        luma += frameWidth;
        lumaData += bytePerRowY;
    }
    lumaData-=lumaDataSize;
    
    uint8_t* sourceChromaB = (uint8_t*)(videoFrame.chromaB.bytes);
    uint8_t* sourceChromaR = (uint8_t*)(videoFrame.chromaR.bytes);
    
    int chromaDataSize = (int)bytePerRowUV * frameHeight / 2;
    uint8_t* chromaB = malloc(chromaDataSize / 2);
    uint8_t* chromaR = malloc(chromaDataSize / 2);
    for(int i = 0; i < frameHeight / 2; i++) {
        memcpy(chromaB, sourceChromaB, frameWidth / 2);
        memcpy(chromaR, sourceChromaR, frameWidth / 2);
        sourceChromaB += frameWidth / 2;
        sourceChromaR += frameWidth / 2;
        chromaB += bytePerRowUV / 2;
        chromaR += bytePerRowUV / 2;
    }
    
    chromaB-=chromaDataSize / 2;
    chromaR-=chromaDataSize / 2;
    uint8_t* chromaData = malloc(chromaDataSize);
    for (int i = 0; i < chromaDataSize; i++) {
        if(i % 2 == 0){
            chromaData[i] = chromaB[i / 2];
        } else {
            chromaData[i] = chromaR[i / 2];
        }
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    memcpy(base, lumaData, lumaDataSize);
    base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    memcpy(base, chromaData, chromaDataSize);
    free(chromaB);
    free(chromaR);
    free(lumaData);
    free(chromaData);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

- (void) renderWithTexId:(VideoFrame*) videoFrame;
{
    // 准备渲染工作
    int frameWidth = (int)[videoFrame width];
    int frameHeight = (int)[videoFrame height];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glUseProgram(filterProgram);
    glViewport(0, 0, frameWidth, frameHeight);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // 获取 Y UV
    [self uploadTexture:videoFrame width:frameWidth height:frameHeight];
    
    static const GLfloat imageVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    GLfloat noRotationTextureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };
    
    // 指定filterPositionAttribute
    glVertexAttribPointer(filterPositionAttribute, 2, GL_FLOAT, 0, 0, imageVertices);
    glEnableVertexAttribArray(filterPositionAttribute);
    // 指定filterTextureCoordinateAttribute
    glVertexAttribPointer(filterTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, noRotationTextureCoordinates);
    glEnableVertexAttribArray(filterTextureCoordinateAttribute);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_lumaTexture));
    glUniform1i(filterInputTextureUniform, 0);
    
    
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_chromaTexture));
    glUniform1i(_chromaInputTextureUniform, 1);
    
    glUniformMatrix3fv(_colorConversionMatrixUniform, 1, GL_FALSE, _preferredConversion);
    
    GLfloat modelviewProj[16];
    mat4f_LoadOrtho(-1.0f, 1.0f, -1.0f, 1.0f, -1.0f, 1.0f, modelviewProj);
    glUniformMatrix4fv(_uniformMatrix, 1, GL_FALSE, modelviewProj);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

- (void)cleanUpTextures
{
    if (_lumaTexture) {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;
    }
    
    if (_chromaTexture) {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
    
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
}

- (void) releaseRender;
{
    [super releaseRender];
    if(_outputTextureID){
        glDeleteTextures(1, &_outputTextureID);
        _outputTextureID = 0;
    }
    if (_framebuffer) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }
    
    [self cleanUpTextures];
    
    if(_videoTextureCache) {
        CFRelease(_videoTextureCache);
    }
    if(_pixelBufferPool) {
        CFRelease(_pixelBufferPool);
    }
}
@end
