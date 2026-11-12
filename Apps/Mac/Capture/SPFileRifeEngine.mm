#import "SPFileRifeEngine.h"
#import "SPRifeBridge.h"
#import "SPFileColorTransfer.h"
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cmath>
#include <initializer_list>

static NSError *SPFileRifeError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"OpenDuckFrame.FileRife" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static CVPixelBufferRef SPFileRifeCreate(int w,int h,OSType format){
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef result=NULL;return CVPixelBufferCreate(NULL,w,h,format,(__bridge CFDictionaryRef)attrs,&result)==kCVReturnSuccess?result:NULL;
}
static void SPFileRifeCopyAttachments(CVPixelBufferRef from,CVPixelBufferRef to){
    CVBufferPropagateAttachments(from,to);
    CVBufferRemoveAttachment(to,kCVImageBufferCleanApertureKey);
    CVBufferRemoveAttachment(to,kCVImageBufferPreferredCleanApertureKey);
    CVBufferRemoveAttachment(to,kCVImageBufferDisplayDimensionsKey);
}
@implementation SPFileRifeEngine {
    NSString *_modelID,*_quality;
    NSBundle *_resourceBundle;
    NSArray<SPRifeBridge *> *_bridges;
    VTPixelTransferSessionRef _toRGB,_toNV12,_downscale,_upscale;
    dispatch_queue_t _queue;
    std::atomic<bool> _busy;
    uint64_t _epoch;
    BOOL _ready;
    int _width,_height;                 // decoded source size
    int _inferenceWidth,_inferenceHeight;
    int _inferenceLongEdge;
    int _bridgeCount;
    CVPixelBufferRef _cachedSource,_cachedInfer,_cachedRGB;
    int64_t _cachedPTS;
    uint64_t _cachedIdentity,_nextIdentity;
}
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality {return [self initWithModelID:modelID quality:quality resourceBundle:NSBundle.mainBundle];}
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle {
    return [self initWithModelID:modelID quality:quality resourceBundle:bundle inferenceLongEdge:0 bridgeCount:1];
}
- (instancetype)initWithModelID:(NSString *)modelID quality:(NSString *)quality resourceBundle:(NSBundle *)bundle
                inferenceLongEdge:(int)inferenceLongEdge bridgeCount:(int)bridgeCount {
    if(!(self=[super init]))return nil;
    _resourceBundle=bundle;_modelID=[modelID copy];_quality=[quality copy];
    _inferenceLongEdge=MAX(0,inferenceLongEdge);
    _bridgeCount=MAX(1,MIN(4,bridgeCount));
    _queue=dispatch_queue_create("app.openduckframe.file-rife",DISPATCH_QUEUE_SERIAL);_busy.store(false);return self;
}
- (void)clearInputCache {
    if(_cachedSource)CVPixelBufferRelease(_cachedSource);
    if(_cachedInfer)CVPixelBufferRelease(_cachedInfer);
    if(_cachedRGB)CVPixelBufferRelease(_cachedRGB);
    _cachedSource=NULL;_cachedInfer=NULL;_cachedRGB=NULL;_cachedIdentity=0;
}
- (void)releaseBridges {
    for(SPRifeBridge *bridge in _bridges)[bridge invalidate];
    _bridges=nil;
}
- (void)releaseSessions {
    if(_toRGB){CFRelease(_toRGB);_toRGB=NULL;}
    if(_toNV12){CFRelease(_toNV12);_toNV12=NULL;}
    if(_downscale){CFRelease(_downscale);_downscale=NULL;}
    if(_upscale){CFRelease(_upscale);_upscale=NULL;}
}
- (void)dealloc {[self releaseBridges];[self clearInputCache];[self releaseSessions];}
// Diagnostic compatibility: existing probes read the active bridge through KVC.
- (SPRifeBridge *)bridge { @synchronized(self){ return _bridges.firstObject; } }
- (void)invalidate {
    NSArray<SPRifeBridge *> *bridges;
    @synchronized(self){_epoch++;_ready=NO;bridges=_bridges;_bridges=nil;}
    for(SPRifeBridge *bridge in bridges)[bridge invalidate];
    dispatch_async(_queue,^{[self clearInputCache];});
}
- (BOOL)prepareWithSample:(CVPixelBufferRef)sample completion:(void (^)(BOOL, NSString *))completion {
    if(!sample||!completion){if(completion)completion(NO,@"文件视频帧尚未就绪。");return NO;}
    CVPixelBufferRetain(sample);uint64_t seen;@synchronized(self){seen=_epoch;_ready=NO;}
    dispatch_async(_queue,^{
        int w=(int)CVPixelBufferGetWidth(sample),h=(int)CVPixelBufferGetHeight(sample);OSType f=CVPixelBufferGetPixelFormatType(sample);
        CFTypeRef matrix=CVBufferCopyAttachment(sample,kCVImageBufferYCbCrMatrixKey,NULL);
        CFTypeRef pri=CVBufferCopyAttachment(sample,kCVImageBufferColorPrimariesKey,NULL),trc=CVBufferCopyAttachment(sample,kCVImageBufferTransferFunctionKey,NULL);
        BOOL hdr=trc&&(CFEqual(trc,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)||CFEqual(trc,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
        BOOL valid=matrix&&pri&&trc&&!hdr&&w>=2&&h>=2&&w<=3840&&h<=2160&&!(w&1)&&!(h&1)&&
            (f==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||f==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)&&
            CGRectEqualToRect(CVImageBufferGetCleanRect(sample),CGRectMake(0,0,w,h));
        if(matrix)CFRelease(matrix);if(pri)CFRelease(pri);if(trc)CFRelease(trc);
        if(!valid){CVPixelBufferRelease(sample);completion(NO,@"文件 RIFE 需要完整 SDR 8 位 NV12 帧、已知色彩信息和最高 3840×2160 的偶数尺寸。");return;}
        if(![@[@"fast",@"balanced",@"hq"] containsObject:self->_quality]){CVPixelBufferRelease(sample);completion(NO,@"所选 RIFE 质量档位不可用。");return;}
        int inferW=w,inferH=h;
        if(self->_inferenceLongEdge>0){
            int longEdge=MAX(w,h);
            if(longEdge>self->_inferenceLongEdge){
                const double scale=(double)self->_inferenceLongEdge/longEdge;
                inferW=MAX(2,((int)llround(w*scale))&~1);
                inferH=MAX(2,((int)llround(h*scale))&~1);
            }
        }
        [self releaseBridges];[self releaseSessions];[self clearInputCache];
        if(VTPixelTransferSessionCreate(NULL,&self->_toRGB)!=noErr||VTPixelTransferSessionCreate(NULL,&self->_toNV12)!=noErr){
            CVPixelBufferRelease(sample);completion(NO,@"RIFE 色彩转换准备失败。");return;
        }
        if(inferW!=w||inferH!=h){
            if(VTPixelTransferSessionCreate(NULL,&self->_downscale)!=noErr||VTPixelTransferSessionCreate(NULL,&self->_upscale)!=noErr){
                [self releaseSessions];CVPixelBufferRelease(sample);completion(NO,@"RIFE 尺寸转换准备失败。");return;
            }
            VTSessionSetProperty(self->_downscale,kVTPixelTransferPropertyKey_ScalingMode,kVTScalingMode_Normal);
            VTSessionSetProperty(self->_upscale,kVTPixelTransferPropertyKey_ScalingMode,kVTScalingMode_Normal);
        }
        NSMutableArray<SPRifeBridge *> *bridges=[NSMutableArray array];
        NSError *error=nil;
        for(int i=0;i<self->_bridgeCount;i++){
            SPRifeBridge *bridge=[[SPRifeBridge alloc] initWithResourceBundle:self->_resourceBundle];
            if(![bridge prepareModelID:self->_modelID quality:self->_quality width:inferW height:inferH error:&error]){
                for(SPRifeBridge *prepared in bridges)[prepared invalidate];
                [self releaseSessions];CVPixelBufferRelease(sample);
                completion(NO,error.localizedDescription?:@"RIFE 模型准备失败。");return;
            }
            bridge.liveStreamEnabled=YES;
            [bridges addObject:bridge];
        }
        @synchronized(self){
            if(seen!=self->_epoch){
                for(SPRifeBridge *bridge in bridges)[bridge invalidate];
                [self releaseSessions];CVPixelBufferRelease(sample);
                completion(NO,@"准备已取消，原设置保持不变。");return;
            }
            self->_bridges=bridges;self->_width=w;self->_height=h;self->_inferenceWidth=inferW;self->_inferenceHeight=inferH;self->_ready=YES;
        }
        NSArray<NSNumber *> *warmPhases=self->_bridgeCount>=4?@[@0.2,@0.4,@0.6,@0.8]:(self->_bridgeCount==3?@[@0.25,@0.5,@0.75]:(self->_bridgeCount==2?@[@0.3,@0.7]:@[@0.5]));
        BOOL submitted=[self submitPrevious:sample current:sample previousPTSUs:0 currentPTSUs:33333 phases:warmPhases token:1 completion:^(uint64_t token,NSArray<SPOwnedPixelBuffer *> *out,double latency,NSError *failure){
            (void)token;(void)latency;BOOL ready=!failure&&out.count==warmPhases.count&&CVPixelBufferGetWidth(out.firstObject.buffer)==(size_t)w&&CVPixelBufferGetHeight(out.firstObject.buffer)==(size_t)h&&CVPixelBufferGetPixelFormatType(out.firstObject.buffer)==f;
            CVPixelBufferRelease(sample);if(!ready)[self invalidate];completion(ready,failure.localizedDescription?:@"");
        }];
        if(!submitted){CVPixelBufferRelease(sample);[self invalidate];completion(NO,@"RIFE 预检任务繁忙。");}
    });
    return YES;
}
- (BOOL)submitPrevious:(CVPixelBufferRef)previous current:(CVPixelBufferRef)current previousPTSUs:(int64_t)previousPTSUs currentPTSUs:(int64_t)currentPTSUs phases:(NSArray<NSNumber *> *)phases token:(uint64_t)token completion:(SPFRCPhasesCompletion)completion {
    if(!previous||!current||!completion||currentPTSUs<=previousPTSUs||phases.count<1||phases.count>4)return NO;
    uint64_t seen;NSArray<SPRifeBridge *> *bridges;int inferW,inferH;@synchronized(self){if(!_ready)return NO;seen=_epoch;bridges=_bridges;inferW=_inferenceWidth;inferH=_inferenceHeight;}
    if(!bridges.count||inferW<2||inferH<2)return NO;
    if(_busy.exchange(true))return NO;
    CVPixelBufferRetain(previous);CVPixelBufferRetain(current);
    const double started=CFAbsoluteTimeGetCurrent();
    dispatch_async(_queue,^{
        CVPixelBufferRef inferPrev=NULL,inferCur=NULL,rgbPrev=NULL,rgbCur=NULL;
        void (^fail)(NSError *)=^(NSError *error){
            [self clearInputCache];
            if(inferPrev)CVPixelBufferRelease(inferPrev);
            if(inferCur)CVPixelBufferRelease(inferCur);
            if(rgbPrev)CVPixelBufferRelease(rgbPrev);
            if(rgbCur)CVPixelBufferRelease(rgbCur);
            CVPixelBufferRelease(previous);CVPixelBufferRelease(current);self->_busy.store(false);
            completion(token,nil,CFAbsoluteTimeGetCurrent()-started,error);
        };
        OSType format=CVPixelBufferGetPixelFormatType(previous);
        CFTypeRef m1=CVBufferCopyAttachment(previous,kCVImageBufferYCbCrMatrixKey,NULL),m2=CVBufferCopyAttachment(current,kCVImageBufferYCbCrMatrixKey,NULL);
        CFTypeRef p1=CVBufferCopyAttachment(previous,kCVImageBufferColorPrimariesKey,NULL),p2=CVBufferCopyAttachment(current,kCVImageBufferColorPrimariesKey,NULL);
        CFTypeRef t1=CVBufferCopyAttachment(previous,kCVImageBufferTransferFunctionKey,NULL),t2=CVBufferCopyAttachment(current,kCVImageBufferTransferFunctionKey,NULL);
        BOOL compatible=m1&&m2&&p1&&p2&&t1&&t2&&CFEqual(m1,m2)&&CFEqual(p1,p2)&&CFEqual(t1,t2)&&
           CVPixelBufferGetWidth(previous)==(size_t)self->_width&&CVPixelBufferGetHeight(previous)==(size_t)self->_height&&
           CVPixelBufferGetWidth(current)==(size_t)self->_width&&CVPixelBufferGetHeight(current)==(size_t)self->_height&&CVPixelBufferGetPixelFormatType(current)==format&&
           CGRectEqualToRect(CVImageBufferGetCleanRect(previous),CGRectMake(0,0,self->_width,self->_height))&&
           CGRectEqualToRect(CVImageBufferGetCleanRect(current),CGRectMake(0,0,self->_width,self->_height))&&
           (format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)&&
           !CFEqual(t1,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)&&!CFEqual(t1,kCVImageBufferTransferFunction_ITU_R_2100_HLG);
        if(m1)CFRelease(m1);if(m2)CFRelease(m2);if(p1)CFRelease(p1);if(p2)CFRelease(p2);if(t1)CFRelease(t1);if(t2)CFRelease(t2);
        if(!compatible||!SPConfigureFileColorTransfer(self->_toNV12,previous,YES)||
           VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2)!=noErr||
           VTSessionSetProperty(self->_toRGB,kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2)!=noErr){fail(SPFileRifeError(1,@"RIFE 帧对的格式或色彩信息不兼容。"));return;}
        // Consecutive pairs share the same immutable original. Keep the decoded
        // source, its inference-size copy, and the bridge input so every engine
        // can reuse its features. A seek or skipped source starts a fresh pair.
        const BOOL cached=self->_cachedSource==previous && self->_cachedPTS==previousPTSUs && self->_cachedInfer && self->_cachedRGB;
        const uint64_t previousIdentity=cached?self->_cachedIdentity:++self->_nextIdentity;
        const uint64_t currentIdentity=++self->_nextIdentity;
        if(cached){
            inferPrev=CVPixelBufferRetain(self->_cachedInfer);
            rgbPrev=CVPixelBufferRetain(self->_cachedRGB);
        }else if(self->_downscale){
            inferPrev=SPFileRifeCreate(inferW,inferH,format);
            if(inferPrev)SPFileRifeCopyAttachments(previous,inferPrev);
            if(!inferPrev||VTPixelTransferSessionTransferImage(self->_downscale,previous,inferPrev)!=noErr){fail(SPFileRifeError(2,@"RIFE 输入缩小失败。"));return;}
            rgbPrev=SPFileRifeCreate(inferW,inferH,kCVPixelFormatType_32BGRA);
        }else{
            inferPrev=CVPixelBufferRetain(previous);
            rgbPrev=SPFileRifeCreate(inferW,inferH,kCVPixelFormatType_32BGRA);
        }
        if(self->_downscale){
            inferCur=SPFileRifeCreate(inferW,inferH,format);
            if(inferCur)SPFileRifeCopyAttachments(current,inferCur);
            if(!inferCur||VTPixelTransferSessionTransferImage(self->_downscale,current,inferCur)!=noErr){fail(SPFileRifeError(2,@"RIFE 输入缩小失败。"));return;}
        }else inferCur=CVPixelBufferRetain(current);
        rgbCur=SPFileRifeCreate(inferW,inferH,kCVPixelFormatType_32BGRA);
        if(!rgbPrev||!rgbCur){fail(SPFileRifeError(3,@"RIFE 输入画面分配失败。"));return;}
        for(CVPixelBufferRef rgb:{rgbPrev,rgbCur}){CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);}
        if((!cached&&VTPixelTransferSessionTransferImage(self->_toRGB,inferPrev,rgbPrev)!=noErr)||VTPixelTransferSessionTransferImage(self->_toRGB,inferCur,rgbCur)!=noErr){fail(SPFileRifeError(4,@"RIFE 输入格式转换失败。"));return;}
        for(CVPixelBufferRef rgb:{rgbPrev,rgbCur}){CVBufferSetAttachment(rgb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferSetAttachment(rgb,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);CVBufferRemoveAttachment(rgb,kCVImageBufferYCbCrMatrixKey);}
        NSMutableArray<id> *slots=[NSMutableArray arrayWithCapacity:phases.count];
        for(NSUInteger i=0;i<phases.count;i++)[slots addObject:[NSNull null]];
        dispatch_group_t group=dispatch_group_create();
        __block NSError *bridgeError=nil;
        for(NSUInteger bi=0;bi<bridges.count;bi++){
            NSMutableArray<NSNumber *> *subset=[NSMutableArray array],*indices=[NSMutableArray array];
            for(NSUInteger pi=bi;pi<phases.count;pi+=bridges.count){[subset addObject:phases[pi]];[indices addObject:@(pi)];}
            if(!subset.count)continue;
            dispatch_group_enter(group);
            SPRifeBridge *bridge=bridges[bi];
            BOOL accepted=[bridge submitLivePrevious:rgbPrev current:rgbCur previousID:previousIdentity currentID:currentIdentity
                previousPTS:CMTimeMake(previousPTSUs,1000000) currentPTS:CMTimeMake(currentPTSUs,1000000)
                generation:seen clockEpoch:seen timesteps:subset token:token completion:^(uint64_t callbackToken,NSArray<SPOwnedPixelBuffer *> *outputs,double latency,NSError *error){
                (void)callbackToken;(void)latency;
                if(error||outputs.count!=subset.count){
                    @synchronized(slots){if(!bridgeError)bridgeError=error?:SPFileRifeError(8,@"RIFE 没有返回全部插帧。");}
                }else{
                    @synchronized(slots){
                        for(NSUInteger j=0;j<subset.count;j++)[slots replaceObjectAtIndex:[indices[j] unsignedIntegerValue] withObject:outputs[j]];
                    }
                }
                dispatch_group_leave(group);
            }];
            if(!accepted){
                @synchronized(slots){if(!bridgeError)bridgeError=SPFileRifeError(9,@"RIFE 暂时无法接收任务。");}
                dispatch_group_leave(group);
            }
        }
        if(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC))!=0&&!bridgeError)bridgeError=SPFileRifeError(10,@"RIFE 推理超时。");
        BOOL stale;@synchronized(self){stale=seen!=self->_epoch;}
        if(stale){fail(SPFileRifeError(6,@"RIFE 结果属于旧会话。"));return;}
        if(bridgeError){fail(bridgeError);return;}
        NSMutableArray<SPOwnedPixelBuffer *> *converted=[NSMutableArray arrayWithCapacity:phases.count];
        NSError *failure=nil;
        for(id slot in slots){
            if(![slot isKindOfClass:[SPOwnedPixelBuffer class]]){failure=SPFileRifeError(8,@"RIFE 没有返回全部插帧。");break;}
            SPOwnedPixelBuffer *box=(SPOwnedPixelBuffer *)slot;
            if(CVPixelBufferGetWidth(box.buffer)!=(size_t)inferW||CVPixelBufferGetHeight(box.buffer)!=(size_t)inferH){failure=SPFileRifeError(11,@"RIFE 输出尺寸不正确。");break;}
            CVPixelBufferRef inferNV=SPFileRifeCreate(inferW,inferH,format);
            if(!inferNV){failure=SPFileRifeError(12,@"RIFE 输出画面分配失败。");break;}
            SPFileRifeCopyAttachments(previous,inferNV);
            if(VTPixelTransferSessionTransferImage(self->_toNV12,box.buffer,inferNV)!=noErr){CVPixelBufferRelease(inferNV);failure=SPFileRifeError(5,@"RIFE 输出格式转换失败。");break;}
            if(self->_upscale){
                CVPixelBufferRef full=SPFileRifeCreate(self->_width,self->_height,format);
                if(!full||VTPixelTransferSessionTransferImage(self->_upscale,inferNV,full)!=noErr){if(full)CVPixelBufferRelease(full);CVPixelBufferRelease(inferNV);failure=SPFileRifeError(13,@"RIFE 输出放大失败。");break;}
                CVPixelBufferRelease(inferNV);
                SPFileRifeCopyAttachments(previous,full);
                [converted addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:full]];
            }else{
                [converted addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:inferNV]];
            }
        }
        [self clearInputCache];
        if(!failure&&converted.count==phases.count){
            self->_cachedSource=CVPixelBufferRetain(current);
            self->_cachedInfer=CVPixelBufferRetain(inferCur);
            self->_cachedRGB=CVPixelBufferRetain(rgbCur);
            self->_cachedPTS=currentPTSUs;self->_cachedIdentity=currentIdentity;
        }else if(!failure)failure=SPFileRifeError(8,@"RIFE 没有返回全部插帧。");
        if(inferPrev)CVPixelBufferRelease(inferPrev);
        if(inferCur)CVPixelBufferRelease(inferCur);
        if(rgbPrev)CVPixelBufferRelease(rgbPrev);
        if(rgbCur)CVPixelBufferRelease(rgbCur);
        CVPixelBufferRelease(previous);CVPixelBufferRelease(current);self->_busy.store(false);
        completion(token,failure?nil:converted,CFAbsoluteTimeGetCurrent()-started,failure);
    });
    return YES;
}
@end
