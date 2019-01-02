//
//  YUVFrameCopier.m
//  video_player
//
//  Created by apple on 16/9/1.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "YUVFrameCopier.h"

NSString *const yuvVertexShaderString = SHADER_STRING
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

NSString *const yuvFragmentShaderString = SHADER_STRING
(
 varying highp vec2 v_texcoord;
 uniform sampler2D inputImageTexture;
 uniform sampler2D s_texture_u;
 uniform sampler2D s_texture_v;
 
 void main()
 {
     highp float y = texture2D(inputImageTexture, v_texcoord).r;
     highp float u = texture2D(s_texture_u, v_texcoord).r - 0.5;
     highp float v = texture2D(s_texture_v, v_texcoord).r - 0.5;
     
     highp float r = y +             1.402 * v;
     highp float g = y - 0.344 * u - 0.714 * v;
     highp float b = y + 1.772 * u;
     
     gl_FragColor = vec4(r,g,b,1.0);
 }
 );

@interface YUVFrameCopier(){
    GLuint                              _framebuffer;     // 帧缓冲
    GLuint                              _outputTextureID;   //输出图像的ID
    
    GLint                               _uniformMatrix;       // 矩阵
    GLint                               _chromaBInputTextureUniform;   //输入图像的色度 蓝色
    GLint                               _chromaRInputTextureUniform;   //输入图像的色度 红色

    GLuint                              _inputTextures[3];      //输入的图像数组
}

@end

@implementation YUVFrameCopier

- (BOOL) prepareRender:(NSInteger) frameWidth height:(NSInteger) frameHeight;
{
    BOOL ret = NO;
    // 按照指定的 顶点着色器 和 片段着色器 创建编译器
    if([self buildProgram:yuvVertexShaderString fragmentShader:yuvFragmentShaderString]) {
        
        // 获取工程的 片段着色器中的 s_texture_u  s_texture_v
        _chromaBInputTextureUniform = glGetUniformLocation(filterProgram, "s_texture_u");
        _chromaRInputTextureUniform = glGetUniformLocation(filterProgram, "s_texture_v");
        // 使显卡绘制程序
        glUseProgram(filterProgram);
        
        // 设置图像的postion
        glEnableVertexAttribArray(filterPositionAttribute);
        // 设置图像的纹理 textureCoordinate
        glEnableVertexAttribArray(filterTextureCoordinateAttribute);
        
        //生成FBO And TextureId
        // 生成帧缓存对象（frame buffer object）
        glGenFramebuffers(1, &_framebuffer);
        // 绑定FBO 到 管线
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        
        // 绑定纹理
        glActiveTexture(GL_TEXTURE1);
        // 获取一个纹理对象 放在_outputTextureID  这是对 output进行处理
        glGenTextures(1, &_outputTextureID);
        glBindTexture(GL_TEXTURE_2D, _outputTextureID);
        //GL_LINEAR 双线性过滤
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        // GL_CLAMP_TO_EDGE s、t轴的重复映射或约减映射
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        // 把RGBA的数组传到显卡的texId的纹理对象，
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (int)frameWidth, (int)frameHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, 0);
        NSLog(@"width=%d, height=%d", (int)frameWidth, (int)frameHeight);
        
        // 绑定图像到缓冲帧上
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _outputTextureID, 0);
        // 检查缓冲区的状态
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"failed to make complete framebuffer object %x", status);
        }
        
        // 解绑 传递给片段着色器
        glBindTexture(GL_TEXTURE_2D, 0);
        
        // 对input纹理进行处理 3张纹理
        [self genInputTexture:(int)frameWidth height:(int)frameHeight];
        
        ret = TRUE;
    }
    return ret;
}

// 释放渲染
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
}

// 获取输出纹理的ID
- (GLint) outputTextureID;
{
    return _outputTextureID;
}

// 按纹理渲染
- (void) renderWithTexId:(VideoFrame*) videoFrame;
{
    int frameWidth = (int)[videoFrame width];
    int frameHeight = (int)[videoFrame height];
    
    // 把帧缓存绑定到管线上
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    // 使用显卡显示
    glUseProgram(filterProgram);
    //规定窗口
    glViewport(0, 0, frameWidth, frameHeight);
    // 清除颜色
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    //进行渲染
    [self uploadTexture:videoFrame width:frameWidth height:frameHeight];
    
    // 图像的顶点集合 （表示坐标点在图像中心） 点精灵的坐标系
    static const GLfloat imageVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    // OpenGL 的坐标系 坐标中心在左下角
    GLfloat noRotationTextureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };
    //根据 position  设置物体的坐标
    glVertexAttribPointer(filterPositionAttribute, 2, GL_FLOAT, 0, 0, imageVertices);
    glEnableVertexAttribArray(filterPositionAttribute);
    //根据 texcoord 设置纹理坐标
    glVertexAttribPointer(filterTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, noRotationTextureCoordinates);
    glEnableVertexAttribArray(filterTextureCoordinateAttribute);
    
    //根据  inputImageTexture
    // 选择激活的纹理单元
    glActiveTexture(GL_TEXTURE0);
    // 绑定指定的纹理
    glBindTexture(GL_TEXTURE_2D, _inputTextures[0]);
    // 纹理第一层
    glUniform1i(filterInputTextureUniform, 0);
    
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _inputTextures[1]);
    // 纹理第二层
    glUniform1i(_chromaBInputTextureUniform, 1);
    
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, _inputTextures[2]);
    // 纹理第三层
    glUniform1i(_chromaRInputTextureUniform, 2);
    
    GLfloat modelviewProj[16];
    mat4f_LoadOrtho(-1.0f, 1.0f, -1.0f, 1.0f, -1.0f, 1.0f, modelviewProj);
    glUniformMatrix4fv(_uniformMatrix, 1, GL_FALSE, modelviewProj);
    
    // 执行绘制
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    
}

- (void) genInputTexture:(int) frameWidth height:(int) frameHeight;
{
    // 加载一张图片作为OpenGL的纹理
    glGenTextures(3, _inputTextures);
    // 三张
    for (int i = 0; i < 3; ++i) {
        /*
         //GL_LINEAR 双线性过滤
         glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
         glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
         
         // GL_CLAMP_TO_EDGE s、t轴的重复映射或约减映射
         glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
         glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
         glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (int)frameWidth, (int)frameHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, 0);
         */
        
        // 绑定纹理对象
        glBindTexture(GL_TEXTURE_2D, _inputTextures[i]);
        
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, frameWidth, frameHeight, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0);
    }
}

- (void) uploadTexture:(VideoFrame*) videoFrame width:(int) frameWidth height:(int) frameHeight;
{
    // 设置线性位打包队列 app 设置1，像素以1个字节划分
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    // 获取 亮度luma  色度choma chromaB chromaR
    const UInt8 *pixels[3] = { videoFrame.luma.bytes, videoFrame.chromaB.bytes, videoFrame.chromaR.bytes };
    // 宽度数组
    const NSUInteger widths[3]  = { frameWidth, frameWidth / 2, frameWidth / 2 };
    // 高度数组
    const NSUInteger heights[3] = { frameHeight, frameHeight / 2, frameHeight / 2 };
    // inputTexture 是三个元素的数组
    for (int i = 0; i < 3; ++i) {
        // 把指定的texId 绑定纹理对象
        glBindTexture(GL_TEXTURE_2D, _inputTextures[i]);
        // 0基本图像级别  指定纹理存储的内核格式 GL_LUMINANCE  0边框宽度   GL_UNSIGNED_BYTE 像素数据的数据类型
        glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, (int)widths[i], (int)heights[i],
                     0, GL_LUMINANCE, GL_UNSIGNED_BYTE, pixels[i]);
    }
}

@end
