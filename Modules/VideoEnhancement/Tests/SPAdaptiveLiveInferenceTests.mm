#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import "SPRifeBridge.h"

// Real-GPU headless contract for adaptive live inference: oversized captures
// run downscaled inference through the prescale scalers and return frames at
// capture size, without the Air cadence, keeper or presenter machinery.

static CVPixelBufferRef source(int width, int height, uint8_t luma) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                           (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    for (size_t plane = 0; plane < 2; ++plane)
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane ? 128 : luma,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane));
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) return 2;
        Class cls = NSClassFromString(@"SPRifeBridge");
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[2])];
        if (!cls || !bundle || ![cls windowOptimizationCapabilitiesSupported]) return 3;

        // 1. An oversized live capture opts into downscaled inference.
        SPRifeBridge *adaptive = [[cls alloc] initWithResourceBundle:bundle];
        adaptive.liveStreamEnabled = YES;
        adaptive.adaptiveLiveInference = YES;
        NSError *error = nil;
        BOOL ready = [adaptive prepareModelID:@"rife-v4.25" quality:@"fast" width:3456 height:2168 error:&error];
        int processWidth = adaptive.processingWidth, processHeight = adaptive.processingHeight;
        BOOL sizing = ready && !adaptive.airPerformanceEnabled && !adaptive.residentKeepAliveEnabled
            && processWidth > 0 && processHeight > 0 && processWidth < 3456 && processHeight < 2168
            && (processWidth % 2) == 0 && (processHeight % 2) == 0
            && (long long)processWidth * processHeight <= 1920LL * 1080
            && ((processWidth + 255) / 256) * 256 <= 2048 && ((processHeight + 255) / 256) * 256 <= 1280;

        // 2. Generated frames come back at capture size (upscaled in the push).
        CVPixelBufferRef previous = source(3456, 2168, 32), current = source(3456, 2168, 180);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL output = NO;
        __block NSString *failure = error.localizedDescription;
        BOOL accepted = ready && previous && current && [adaptive submitLivePrevious:previous current:current
            previousID:1 currentID:2 previousPTS:CMTimeMake(0, 25) currentPTS:CMTimeMake(1, 25)
            generation:1 clockEpoch:1 timesteps:@[@0.5] token:1
            completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double seconds, NSError *err) {
                CVPixelBufferRef frame = frames.firstObject.buffer;
                output = token == 1 && !err && frames.count == 1 && frame &&
                    CVPixelBufferGetWidth(frame) == 3456 && CVPixelBufferGetHeight(frame) == 2168;
                failure = err.localizedDescription;
                dispatch_semaphore_signal(done);
            }];
        BOOL completed = accepted && dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0;
        [adaptive invalidate];
        if (previous) CVPixelBufferRelease(previous);
        if (current) CVPixelBufferRelease(current);

        // 3. Below the area budget the flag is a no-op: native sizing stays.
        SPRifeBridge *small = [[cls alloc] initWithResourceBundle:bundle];
        small.liveStreamEnabled = YES;
        small.adaptiveLiveInference = YES;
        BOOL smallUnchanged = [small prepareModelID:@"rife-v4.25" quality:@"fast" width:1280 height:720 error:&error] &&
            small.processingWidth == 1280 && small.processingHeight == 720;
        [small invalidate];

        // 4. The prescale configuration requires the Fast tier; the planner
        // never sets the flag for other qualities, and the engine refuses it.
        SPRifeBridge *balanced = [[cls alloc] initWithResourceBundle:bundle];
        balanced.liveStreamEnabled = YES;
        balanced.adaptiveLiveInference = YES;
        BOOL balancedRefused = ![balanced prepareModelID:@"rife-v4.25" quality:@"balanced" width:3456 height:2168 error:&error];
        [balanced invalidate];

        BOOL ok = sizing && accepted && completed && output && smallUnchanged && balancedRefused;
        NSDictionary *result = @{ @"ok": @(ok), @"sizing": @(sizing), @"accepted": @(accepted),
            @"completed": @(completed), @"frameAtCaptureSize": @(output),
            @"processingPixels": @[@(processWidth), @(processHeight)],
            @"smallUnchanged": @(smallUnchanged), @"balancedRefused": @(balancedRefused),
            @"error": failure ?: @"",
            @"scope": @"real GPU downscaled inference at 3456x2168; one generated frame; no capture, presentation or sustained FPS" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return ok ? 0 : 1;
    }
}
