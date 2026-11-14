#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import "SPFileRifeEngine.h"

// Real-GPU headless contract for 10-bit SDR file interpolation: HEVC Main 10
// web releases keep BT.709 SDR color in a 10-bit container, and the engine
// must accept 'x420' frames through its VT transfer pipeline and return
// generated frames at capture size.

static CVPixelBufferRef source8(int width, int height, uint8_t luma) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                           (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), su = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    uint8_t *u = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    memset(y, luma, sy * height);
    for (size_t r = 0; r < (size_t)height / 2; ++r)
        for (size_t c = 0; c < (size_t)width / 2; ++c) { u[r * su + 2 * c] = 128; u[r * su + 2 * c + 1] = 128; }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static CVPixelBufferRef source10(int width, int height, uint16_t luma) {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                           (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), su = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    uint16_t *y = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    uint16_t *u = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    for (size_t r = 0; r < (size_t)height; ++r)
        for (size_t c = 0; c < (size_t)width; ++c) y[r * sy / 2 + c] = luma << 2;
    for (size_t r = 0; r < (size_t)height / 2; ++r)
        for (size_t c = 0; c < (size_t)width / 2; ++c) { u[r * su / 2 + 2 * c] = 512 << 2; u[r * su / 2 + 2 * c + 1] = 512 << 2; }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) return 2;
        Class cls = NSClassFromString(@"SPFileRifeEngine");
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[2])];
        if (!cls || !bundle) return 3;

        const int w = 3840, h = 1608;
        SPFileRifeEngine *engine = [[cls alloc] initWithModelID:@"rife-v4.25" quality:@"fast"
            resourceBundle:bundle inferenceLongEdge:1600 bridgeCount:1];

        CVPixelBufferRef sample = source10(w, h, 128);
        if (!sample) { NSLog(@"setup failed"); return 3; }
        dispatch_semaphore_t prepared = dispatch_semaphore_create(0);
        __block BOOL ready = NO; __block NSString *message = nil;
        [engine prepareWithSample:sample completion:^(BOOL r, NSString *m) {
            ready = r; message = m; dispatch_semaphore_signal(prepared);
        }];
        BOOL preparedOK = dispatch_semaphore_wait(prepared, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0 && ready;
        if (!preparedOK) NSLog(@"prepare failed: %@", message);

        // One generated frame from a real 10-bit pair.
        CVPixelBufferRef previous = source10(w, h, 100), current = source10(w, h, 160);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL generated = NO; __block NSString *submitFailure = nil;
        BOOL accepted = preparedOK && [engine submitPrevious:previous current:current
            previousPTSUs:0 currentPTSUs:40000 phases:@[@0.5] token:7
            completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double latency, NSError *failure) {
                CVPixelBufferRef frame = frames.firstObject.buffer;
                generated = token == 7 && !failure && frames.count == 1 && frame &&
                    CVPixelBufferGetWidth(frame) == w && CVPixelBufferGetHeight(frame) == h;
                submitFailure = failure.localizedDescription;
                dispatch_semaphore_signal(done);
            }];
        BOOL submitted = accepted && dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0;

        // Sustained X2 throughput: sequential pairs at the 25 fps source cadence.
        // The budget is one pair per 40 ms; report each round-trip latency.
        double worst = 0, sum = 0; int misses = 0, ran = 0;
        for (int i = 0; i < 10; ++i) {
            CVPixelBufferRef prev = source10(w, h, 100 + i * 10), cur = source10(w, h, 140 + i * 10);
            dispatch_semaphore_t pairDone = dispatch_semaphore_create(0);
            __block double pairLatency = -1; __block BOOL pairOK = NO;
            BOOL pairAccepted = [engine submitPrevious:prev current:cur
                previousPTSUs:(int64_t)(i * 40000) currentPTSUs:(int64_t)((i + 1) * 40000)
                phases:@[@0.5] token:(uint64_t)(100 + i)
                completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double latency, NSError *failure) {
                    pairLatency = latency; pairOK = !failure && frames.count == 1;
                    dispatch_semaphore_signal(pairDone);
                }];
            double pairStarted = CFAbsoluteTimeGetCurrent();
            BOOL pairFinished = pairAccepted && dispatch_semaphore_wait(pairDone, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_SEC)) == 0;
            double pairWall = (CFAbsoluteTimeGetCurrent() - pairStarted) * 1000;
            CVPixelBufferRelease(prev); CVPixelBufferRelease(cur);
            if (!pairFinished || !pairOK) { misses++; continue; }
            ran++;
            worst = MAX(worst, pairWall); sum += pairWall;
            if (pairWall > 40.0) misses++;
        }
        double average = ran ? sum / ran : -1;
        NSLog(@"[TENBIT-TIMING] averageMs=%.1f worstMs=%.1f ran=%d misses=%d", average, worst, ran, misses);
        [engine invalidate];
        CVPixelBufferRelease(sample); CVPixelBufferRelease(previous); CVPixelBufferRelease(current);

        // 8-bit comparison: the same profile through the proven NV12 path.
        double avg8 = -1, worst8 = -1; int ran8 = 0;
        {
            SPFileRifeEngine *engine8 = [[cls alloc] initWithModelID:@"rife-v4.25" quality:@"fast"
                resourceBundle:bundle inferenceLongEdge:1600 bridgeCount:1];
            CVPixelBufferRef sample8 = source8(w, h, 128);
            dispatch_semaphore_t p8 = dispatch_semaphore_create(0);
            __block BOOL r8 = NO;
            [engine8 prepareWithSample:sample8 completion:^(BOOL r, NSString *m) { r8 = r; dispatch_semaphore_signal(p8); }];
            dispatch_semaphore_wait(p8, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
            if (r8) {
                double sum = 0;
                for (int i = 0; i < 10; ++i) {
                    CVPixelBufferRef prev = source8(w, h, 100 + i * 10), cur = source8(w, h, 140 + i * 10);
                    dispatch_semaphore_t pairDone = dispatch_semaphore_create(0);
                    __block BOOL pairOK = NO;
                    BOOL pairAccepted = [engine8 submitPrevious:prev current:cur
                        previousPTSUs:(int64_t)(i * 40000) currentPTSUs:(int64_t)((i + 1) * 40000)
                        phases:@[@0.5] token:(uint64_t)(200 + i)
                        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double latency, NSError *failure) {
                            pairOK = !failure && frames.count == 1; dispatch_semaphore_signal(pairDone);
                        }];
                    double t0 = CFAbsoluteTimeGetCurrent();
                    BOOL finished = pairAccepted && dispatch_semaphore_wait(pairDone, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_SEC)) == 0;
                    double wallMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
                    CVPixelBufferRelease(prev); CVPixelBufferRelease(cur);
                    if (finished && pairOK) { ran8++; sum += wallMs; worst8 = MAX(worst8, wallMs); }
                }
                avg8 = ran8 ? sum / ran8 : -1;
            }
            [engine8 invalidate];
            if (sample8) CVPixelBufferRelease(sample8);
        }

        BOOL ok = preparedOK && accepted && submitted && generated;
        NSDictionary *result = @{ @"ok": @(ok), @"prepared": @(preparedOK), @"accepted": @(accepted),
            @"submitted": @(submitted), @"generatedAtCaptureSize": @(generated),
            @"pairsRan": @(ran), @"pairsMissed": @(misses),
            @"eightBitAverageMs": @(round(avg8 * 10) / 10.0), @"eightBitWorstMs": @(round(worst8 * 10) / 10.0), @"eightBitRan": @(ran8),
            @"averagePairLatencyMs": @(round(average * 10) / 10.0), @"worstPairLatencyMs": @(round(worst * 10) / 10.0),
            @"error": (message ?: submitFailure ?: @""),
            @"scope": @"real GPU 10-bit SDR ('x420') interpolation at 3840x1608 with 1600 adaptive inference; 10-pair sustained timing over the 40 ms pair budget; no GUI" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return ok ? 0 : 1;
    }
}
