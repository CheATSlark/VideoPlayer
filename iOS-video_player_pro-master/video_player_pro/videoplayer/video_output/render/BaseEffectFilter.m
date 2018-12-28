//
//  BaseEffectFilter.m
//  video_player
//
//  Created by apple on 16/9/1.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "BaseEffectFilter.h"

@implementation BaseEffectFilter

- (BOOL) prepareRender:(NSInteger) frameWidth height:(NSInteger) frameHeight;
{
    return NO;
}

//template method
- (void) renderWithWidth:(NSInteger) width height:(NSInteger) height position:(float)position {
    
}

- (BOOL) buildProgram:(NSString*) vertexShader fragmentShader:(NSString*) fragmentShader;
{
    BOOL result = NO;
    
    GLuint vertShader = 0, fragShader = 0;
    
    // 创建工程
    filterProgram = glCreateProgram();
    
    vertShader = compileShader(GL_VERTEX_SHADER, vertexShader);
    if (!vertShader)
        goto exit;
    fragShader = compileShader(GL_FRAGMENT_SHADER, fragmentShader);
    if (!fragShader)
        goto exit;
    
    // 添加 定点着色器 和 片段着色器
    glAttachShader(filterProgram, vertShader);
    glAttachShader(filterProgram, fragShader);
    
    // 关联工程
    glLinkProgram(filterProgram);
    
    // 获取 位置、坐标、输入的图像内容
    filterPositionAttribute = glGetAttribLocation(filterProgram, "position");
    filterTextureCoordinateAttribute = glGetAttribLocation(filterProgram, "texcoord");
    filterInputTextureUniform = glGetUniformLocation(filterProgram, "inputImageTexture");
    
    GLint status;
    // 检测是否创建成功
    glGetProgramiv(filterProgram, GL_LINK_STATUS, &status);
    if (status == GL_FALSE) {
        NSLog(@"Failed to link program %d", filterProgram);
        goto exit;
    }
    // 是否可用
    result = validateProgram(filterProgram);
exit:
    if (vertShader)
        glDeleteShader(vertShader);
    if (fragShader)
        glDeleteShader(fragShader);
    
    if (result) {
        NSLog(@"OK setup GL programm");
    } else {
        glDeleteProgram(filterProgram);
        filterProgram = 0;
    }
    return result;
}

- (void) releaseRender;
{
    // 退出工程
    if (filterProgram) {
        glDeleteProgram(filterProgram);
        filterProgram = 0;
    }
}

- (void) setInputTexture:(GLint) textureId;
{
    _inputTexId = textureId;
}

- (GLint) outputTextureID
{
    return -1;
}

@end
