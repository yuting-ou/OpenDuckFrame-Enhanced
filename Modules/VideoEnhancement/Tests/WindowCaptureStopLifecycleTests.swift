import Foundation
import CoreVideo

private final class SCStream: Equatable {
    static func == (lhs: SCStream, rhs: SCStream) -> Bool { lhs === rhs }
}

private final class StreamBinding {
    private var generation: UInt64?

    func snapshot(_ stream: SCStream) -> UInt64? { generation }
    func retire(_ stream: SCStream) {
        if generation != nil { generation = nil }
    }
    @discardableResult
    func withCurrent(_ stream: SCStream, generation: UInt64, _ body: () -> Void) -> Bool {
        body()
        return true
    }
    func activate(_ stream: SCStream, generation: UInt64) { self.generation = generation }
}

private final class StopHarness: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.openduckframe.capture-stop")
    let streamBinding = StreamBinding()
    let contentFrameGate = ContentFrameGate()
    let stream = SCStream()
    private(set) var running = true
    private var stoppedCount = 0
    private let geometryLock = NSLock()
    private var screenRectGeneration: UInt64 = 7
    private var frameGeometryReceipt: Any?
    var onGeometry: (@Sendable ([String: Any]?, UInt64) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onNote: (@Sendable (Int) -> Void)?

    init() {
        streamBinding.activate(stream, generation: 7)
    }

    private func stopResizeMonitoring(note: String) {}

    // ACTUAL_STREAM_STOP_DELEGATE
}

@main
private struct WindowCaptureStopLifecycleTests {
    private static func frame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA,
            nil, &buffer) == kCVReturnSuccess)
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        memset(base, 32, CVPixelBufferGetBytesPerRow(image) * 8)
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    static func main() {
        let harness = StopHarness()
        let image = frame()
        precondition(harness.contentFrameGate.evaluate(buffer: image, generation: 7, hostNs: 1) == .accepted)
        precondition(harness.contentFrameGate.diagnostics(nowNs: 1)["contentSnapshotBytes"] as? Int == 512)

        harness.stream(harness.stream, didStopWithError: NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic stream failure"]))
        let deadline = Date().addingTimeInterval(2)
        while harness.running && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!harness.running, "Error stop must retire the running state")
        harness.queue.sync {}

        let remaining = harness.contentFrameGate.diagnostics(nowNs: 2)["contentSnapshotBytes"] as? Int ?? -1
        precondition(remaining == 0, "Error stop must release the owned snapshot; remaining=\(remaining)")
        precondition(harness.streamBinding.snapshot(harness.stream) == nil,
                     "Error stop must retire the stream so late samples cannot rebuild the snapshot")
        print("Window capture error-stop lifecycle passed")
    }
}
