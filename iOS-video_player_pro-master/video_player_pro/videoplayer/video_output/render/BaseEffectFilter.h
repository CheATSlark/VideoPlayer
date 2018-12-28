//
//  BaseEffectFilter.h
//  video_player
//
//  Created by apple on 16/9/1.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

// 添加#
#define STRINGIZE(x) #x
// 添加##
#define STRINGIZE2(x) STRINGIZE(x)

#define SHADER_STRING(text) @ STRINGIZE2(text)

// 图像滤镜的输入回调 子类添加的方法
@protocol ImageFilterInput <NSObject>

- (void) renderWithWidth:(NSInteger) width height:(NSInteger) height position:(float)position;

- (void) setInputTexture:(GLint) textureId;

@end

// 是否可用的工程 建立内联函数
static inline BOOL validateProgram(GLuint prog)
{
    
    GLint status;
    // 检验prog 是否可运行
    glValidateProgram(prog);
    
#ifdef DEBUG
    // 日志长
    GLint logLength;
    // 获取信息
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        // 开辟内存
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == GL_FALSE) {
        NSLog(@"Failed to validate program %d", prog);
        return NO;
    }
    
    return YES;
}

// 获取编译着色器
static inline GLuint compileShader(GLenum type, NSString *shaderString)
{
    GLint status;
    //
    const GLchar *sources = (GLchar *)shaderString.UTF8String;
    // 创建指定类型的着色器
    GLuint shader = glCreateShader(type);
    //
    if (shader == 0 || shader == GL_INVALID_ENUM) {
       // 创建失败
        NSLog(@"Failed to create shader %d", type);
        return 0;
    }
    // 绑定一个string的资源 遇到NULL 终止
    glShaderSource(shader, 1, &sources, NULL);
    // 编译
    glCompileShader(shader);
    
#ifdef DEBUG
    GLint logLength;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_FALSE) {
        glDeleteShader(shader);
        NSLog(@"Failed to compile shader:\n");
        return 0;
    }
    
    return shader;
}

// 4维浮点矩阵   （左 、 右、 底、 顶、 近、 远、 ）
static inline void mat4f_LoadOrtho(float left, float right, float bottom, float top, float near, float far, float* mout)
{
    float r_l = right - left;     // 长
    float t_b = top - bottom;       // 高
    float f_n = far - near;         // 宽
    
    float tx = - (right + left) / (right - left);
    float ty = - (top + bottom) / (top - bottom);
    float tz = - (far + near) / (far - near);
    
    // mout 16个浮点
    
    mout[0] = 2.0f / r_l;
    mout[1] = 0.0f;
    mout[2] = 0.0f;
    mout[3] = 0.0f;
    
    mout[4] = 0.0f;
    mout[5] = 2.0f / t_b;
    mout[6] = 0.0f;
    mout[7] = 0.0f;
    
    mout[8] = 0.0f;
    mout[9] = 0.0f;
    mout[10] = -2.0f / f_n;
    mout[11] = 0.0f;
    
    mout[12] = tx;
    mout[13] = ty;
    mout[14] = tz;
    mout[15] = 1.0f;
}
// 基础效果滤镜
@interface BaseEffectFilter : NSObject
{
    GLint                               _inputTexId;     // 输入ID
    
    GLuint                              filterProgram;   //滤镜工程
    GLint                               filterPositionAttribute;   //滤镜位置属性
    GLint                               filterTextureCoordinateAttribute;  //滤镜文本坐标参数
    GLint                               filterInputTextureUniform;   // 滤镜输入图像内容
    
}

// 是否准备好对指定宽、高的帧进行渲染
- (BOOL) prepareRender:(NSInteger) frameWidth height:(NSInteger) frameHeight;

// 渲染指定位置 宽 高的帧
- (void) renderWithWidth:(NSInteger) width height:(NSInteger) height position:(float)position;

// 是否创建 指定 vertexShader fragmentShader 的工程
- (BOOL) buildProgram:(NSString*) vertexShader fragmentShader:(NSString*) fragmentShader;

// 输入图像内容ID
- (void) setInputTexture:(GLint) textureId;

// 释放渲染
- (void) releaseRender;

// 输出图像ID
- (GLint) outputTextureID;

@end
