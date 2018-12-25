//
//  VideoOutput.m
//  video_player
//
//  Created by apple on 16/8/25.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "VideoOutput.h"
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "YUVFrameCopier.h"
#import "YUVFrameFastCopier.h"
#import "ContrastEnhancerFilter.h"
#import "DirectPassRenderer.h"
#import <Foundation/Foundation.h>

/**
 * 本类的职责:
 *  1:作为一个UIView的子类, 必须提供layer的绘制, 我们这里是靠RenderBuffer和我们的CAEAGLLayer进行绑定来绘制的
 *  2:需要构建OpenGL的环境, EAGLContext与运行Thread
 *  3:调用第三方的Filter与Renderer去把YUV420P的数据处理以及渲染到RenderBuffer上
 *  4:由于这里面涉及到OpenGL的操作, 要增加NotificationCenter的监听, 在applicationWillResignActive 停止绘制
 *
 */

@interface VideoOutput()

@property (atomic) BOOL readyToRender;
@property (nonatomic, assign) BOOL shouldEnableOpenGL;
@property (nonatomic, strong) NSLock *shouldEnableOpenGLLock;
@property (nonatomic, strong) NSOperationQueue *renderOperationQueue;

@end

@implementation VideoOutput 
{
    EAGLContext*                            _context;
    GLuint                                  _displayFramebuffer;      //展示buffer
    GLuint                                  _renderbuffer;          //渲染buffer
    GLint                                   _backingWidth;
    GLint                                   _backingHeight;
    
    BOOL                                    _stopping;
    
    YUVFrameCopier*                         _videoFrameCopier;      //视频帧编译
    
    BaseEffectFilter*                       _filter;           //基础作用滤镜
    
    DirectPassRenderer*                     _directPassRenderer;     //直接传递渲染
}

+ (Class) layerClass
{
    return [CAEAGLLayer class];
}

- (id) initWithFrame:(CGRect)frame textureWidth:(NSInteger)textureWidth textureHeight:(NSInteger)textureHeight usingHWCodec: (BOOL) usingHWCodec {
    return [self initWithFrame:frame textureWidth:textureWidth textureHeight:textureHeight usingHWCodec:usingHWCodec shareGroup:nil];
}

- (id) initWithFrame:(CGRect)frame textureWidth:(NSInteger)textureWidth textureHeight:(NSInteger)textureHeight usingHWCodec: (BOOL) usingHWCodec shareGroup:(EAGLSharegroup *)shareGroup
{
    self = [super initWithFrame:frame];
    if (self) {
        // 生成OpenGL 的线程锁
        _shouldEnableOpenGLLock = [NSLock new];
        // 锁住线程
        [_shouldEnableOpenGLLock lock];
        // 判断当前是否在激活状态
        _shouldEnableOpenGL = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
        // 解锁线程
        [_shouldEnableOpenGLLock unlock];
        
        // 监听应用
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        
        // 赋值layer
        CAEAGLLayer *eaglLayer = (CAEAGLLayer*) self.layer;
        //
        eaglLayer.opaque = YES;
        // 设置绘制参数 0 drawablepropertyretainedbacking  colorformatRGBA8 drawablepropertycolorformat
        eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithBool:FALSE], kEAGLDrawablePropertyRetainedBacking,
                                        kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                        nil];
        // 实例化线程
        _renderOperationQueue = [[NSOperationQueue alloc] init];
        // 最大操作数目是1
        _renderOperationQueue.maxConcurrentOperationCount = 1;
        _renderOperationQueue.name = @"com.changba.video_player.videoRenderQueue";
        
        __weak VideoOutput *weakSelf = self;
        // 添加到队列中执行
        [_renderOperationQueue addOperationWithBlock:^{
            if (!weakSelf) {
                return;
            }

            __strong VideoOutput *strongSelf = weakSelf;
            
            // 初始化 OpenGL ES 的文本内容 是否带有 EAGLSharegroup
            if (shareGroup) {
                strongSelf->_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:shareGroup];
            } else {
                strongSelf->_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
            }
            
            // 判断_context 是否存在， 且把_context 设置为当前的context
            if (!strongSelf->_context || ![EAGLContext setCurrentContext:strongSelf->_context]) {
                NSLog(@"Setup EAGLContext Failed...");
            }
            //  创建展示的帧缓冲区
            if(![strongSelf createDisplayFramebuffer]){
                NSLog(@"create Dispaly Framebuffer failed...");
            }
            
            // 是否创建硬解实例
            [strongSelf createCopierInstance:usingHWCodec];
            
            // 是否准备按照 宽、高 进行渲染
            if (![strongSelf->_videoFrameCopier prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_videoFrameFastCopier prepareRender failed...");
            }
            
            // 创建图像对比度处理滤镜实例
            strongSelf->_filter = [self createImageProcessFilterInstance];
            // 对比度滤镜的准备
            if (![strongSelf->_filter prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_contrastEnhancerFilter prepareRender failed...");
            }
            // 把视频编译的输出ID 赋 给对比度滤镜
            [strongSelf->_filter setInputTexture:[strongSelf->_videoFrameCopier outputTextureID]];
            
            // 实例化直传渲染
            strongSelf->_directPassRenderer = [[DirectPassRenderer alloc] init];
            if (![strongSelf->_directPassRenderer prepareRender:textureWidth height:textureHeight]) {
                NSLog(@"_directPassRenderer prepareRender failed...");
            }
            // 把对比滤镜的输出ID 赋给 直传滤镜
            [strongSelf->_directPassRenderer setInputTexture:[strongSelf->_filter outputTextureID]];
            
            strongSelf.readyToRender = YES;
        }];
    }
    return self;
}

- (BaseEffectFilter*) createImageProcessFilterInstance
{
    return [[ContrastEnhancerFilter alloc] init];
}

- (BaseEffectFilter*) getImageProcessFilterInstance
{
    return _filter;
}

- (void) createCopierInstance:(BOOL) usingHWCodec
{
    if(usingHWCodec){
        // 使用硬解
        _videoFrameCopier = [[YUVFrameFastCopier alloc] init];
    } else{
        // 使用软解
        _videoFrameCopier = [[YUVFrameCopier alloc] init];
    }
}

static int count = 0;
//static int totalDroppedFrames = 0;

//当前operationQueue里允许最多的帧数，理论上好的机型上不会有超过1帧的情况，差一些的机型（比如iPod touch），渲染的比较慢，
//队列里可能会有多帧的情况，这种情况下，如果有超过三帧，就把除了最近3帧以前的帧移除掉（对应的operation cancel掉）
static const NSInteger kMaxOperationQueueCount = 3;

- (void) presentVideoFrame:(VideoFrame*) frame;
{
    if(_stopping){
        NSLog(@"Prevent A InValid Renderer >>>>>>>>>>>>>>>>>");
        return;
    }
    
    // 进行加锁
    @synchronized (self.renderOperationQueue) {
        NSInteger operationCount = _renderOperationQueue.operationCount;
        // 如果队列中超过最大设置
        if (operationCount > kMaxOperationQueueCount) {
            // 对队列中的操作数组 进行 保留3个
            [_renderOperationQueue.operations enumerateObjectsUsingBlock:^(__kindof NSOperation * _Nonnull operation, NSUInteger idx, BOOL * _Nonnull stop) {
                // 如果数目大于最大值 则取消
                if (idx < operationCount - kMaxOperationQueueCount) {
                    [operation cancel];
                } else {
                    //totalDroppedFrames += (idx - 1);
                    //NSLog(@"===========================❌ Dropped frames: %@, total: %@", @(idx - 1), @(totalDroppedFrames));
                    *stop = YES;
                }
            }];
        }
        
        __weak VideoOutput *weakSelf = self;
        [_renderOperationQueue addOperationWithBlock:^{
            if (!weakSelf) {
                return;
            }

            __strong VideoOutput *strongSelf = weakSelf;
            
            [strongSelf.shouldEnableOpenGLLock lock];
            // 判断是否准备好了
            if (!strongSelf.readyToRender || !strongSelf.shouldEnableOpenGL) {
                glFinish();
                [strongSelf.shouldEnableOpenGLLock unlock];
                return;
            }
            [strongSelf.shouldEnableOpenGLLock unlock];
            
            // 计数加一
            count++;
            // 获取帧的宽、高
            int frameWidth = (int)[frame width];
            int frameHeight = (int)[frame height];
            // 设置当前的OpenGL 的context 内容
            [EAGLContext setCurrentContext:strongSelf->_context];
            
            [strongSelf->_videoFrameCopier renderWithTexId:frame];
            
            [strongSelf->_filter renderWithWidth:frameWidth height:frameHeight position:frame.position];
            // 绑定视频帧缓冲区
            glBindFramebuffer(GL_FRAMEBUFFER, strongSelf->_displayFramebuffer);
            
            [strongSelf->_directPassRenderer renderWithWidth:strongSelf->_backingWidth height:strongSelf->_backingHeight position:frame.position];
            // 绑定绘制缓冲
            glBindRenderbuffer(GL_RENDERBUFFER, strongSelf->_renderbuffer);
            
            // 展示
            [strongSelf->_context presentRenderbuffer:GL_RENDERBUFFER];
        }];
    }
    
}

- (BOOL) createDisplayFramebuffer;
{
    BOOL ret = TRUE;
    // 创建帧缓冲区
    glGenFramebuffers(1, &_displayFramebuffer);
    // 创建绘制缓冲区
    glGenRenderbuffers(1, &_renderbuffer);
    // 绑定帧缓冲区到渲染管线
    glBindFramebuffer(GL_FRAMEBUFFER, _displayFramebuffer);
   // 绑定绘制缓存区到渲染管线
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    
    // 为绘制缓存区分配存储区
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    
    // 获取绘制缓冲区的像素 宽、高
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    
    // 将绘制缓冲区绑定到帧缓冲区
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffer);
    
    // 检查帧缓存区的状态
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"failed to make complete framebuffer object %x", status);
        return FALSE;
    }
    // 获取错误
    GLenum glError = glGetError();
    // 没有错误
    if (GL_NO_ERROR != glError) {
        NSLog(@"failed to setup GL %x", glError);
        return FALSE;
    }

    NSLog(@"------------%d -------------%d",GL_NO_ERROR,glError);
    return ret;
}

- (void) destroy;
{
    _stopping = true;
    
    __weak VideoOutput *weakSelf = self;
    [self.renderOperationQueue addOperationWithBlock:^{
        if (!weakSelf) {
            return;
        }
        __strong VideoOutput *strongSelf = weakSelf;
        if(strongSelf->_videoFrameCopier) {
            [strongSelf->_videoFrameCopier releaseRender];
        }
        if(strongSelf->_filter) {
            [strongSelf->_filter releaseRender];
        }
        if(strongSelf->_directPassRenderer) {
            [strongSelf->_directPassRenderer releaseRender];
        }
        if (strongSelf->_displayFramebuffer) {
            glDeleteFramebuffers(1, &strongSelf->_displayFramebuffer);
            strongSelf->_displayFramebuffer = 0;
        }
        if (strongSelf->_renderbuffer) {
            glDeleteRenderbuffers(1, &strongSelf->_renderbuffer);
            strongSelf->_renderbuffer = 0;
        }
        if ([EAGLContext currentContext] == strongSelf->_context) {
            [EAGLContext setCurrentContext:nil];
        }
    }];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_renderOperationQueue) {
        [_renderOperationQueue cancelAllOperations];
        _renderOperationQueue = nil;
    }
    
    _videoFrameCopier = nil;
    _filter = nil;
    _directPassRenderer = nil;
    
    _context = nil;
    NSLog(@"Render Frame Count is %d", count);
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self.shouldEnableOpenGLLock lock];
    self.shouldEnableOpenGL = NO;
    [self.shouldEnableOpenGLLock unlock];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self.shouldEnableOpenGLLock lock];
    self.shouldEnableOpenGL = YES;
    [self.shouldEnableOpenGLLock unlock];
}
@end
