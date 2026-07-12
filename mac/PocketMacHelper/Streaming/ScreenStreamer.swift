import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import os

/// Captures the Mac's display and H.264-encodes it in realtime, emitting Annex-B frames.
///
/// ScreenCaptureKit (`SCStream`) delivers BGRA frames; `VTCompressionSession` encodes them low-latency;
/// each encoded frame is converted to an Annex-B elementary stream (start-code-delimited NAL units,
/// with SPS/PPS prepended on keyframes) so the iOS `VTDecompressionSession` can decode it directly.
///
/// Requires the **Screen Recording** permission (`kTCCServiceScreenCapture`) — the first `startCapture`
/// prompts. This is the streaming source that turns the control channel into a remote desktop.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "com.innoedge.pocketmac", category: "stream")
    private let onEncodedFrame: @Sendable (_ annexB: Data, _ isKeyframe: Bool, _ width: Int, _ height: Int) -> Void
    private let queue = DispatchQueue(label: "com.innoedge.pocketmac.stream")

    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameCount = 0

    /// Cap the long edge so bandwidth stays sane on the relay path; scaled proportionally.
    private let maxLongEdge = 1600

    init(onEncodedFrame: @escaping @Sendable (Data, Bool, Int, Int) -> Void) {
        self.onEncodedFrame = onEncodedFrame
    }

    // MARK: Lifecycle

    func start(fps: Int = 30, bitrate: Int = 6_000_000) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "PocketMac.Stream", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }

        // Scale the display's point size down to the long-edge cap.
        let scale = min(1.0, Double(maxLongEdge) / Double(max(display.width, display.height)))
        let w = Int((Double(display.width) * scale).rounded(.down)) & ~1  // even dimensions for H.264
        let h = Int((Double(display.height) * scale).rounded(.down)) & ~1
        width = Int32(w); height = Int32(h)

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = true

        try setupEncoder(width: width, height: height, fps: fps, bitrate: bitrate)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("screen capture started \(w)x\(h) @\(fps)fps")
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    // MARK: Encoder

    private func setupEncoder(width: Int32, height: Int32, fps: Int, bitrate: Int) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw NSError(domain: "PocketMac.Stream", code: 2, userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed (\(status))"])
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.6 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let session,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Only encode complete frames (SCStream tags status in the sample attachments).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let frameStatus = SCFrameStatus(rawValue: statusRaw),
           frameStatus != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.emit(encoded)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("capture stopped: \(error.localizedDescription)")
    }

    // MARK: Annex-B conversion

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe = !cmSampleBufferIsNotSync(sampleBuffer)
        var annexB = Data()

        // On keyframes, prepend SPS/PPS from the format description.
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0 ..< parameterSetCount(format) {
                if let ps = parameterSet(format, at: index) {
                    annexB.append(contentsOf: [0, 0, 0, 1])
                    annexB.append(ps)
                }
            }
        }

        // Convert the AVCC (4-byte length-prefixed) NAL units to Annex-B start codes.
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard offset + nalLength <= length else { break }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(Data(bytes: bytes + offset, count: nalLength))
            offset += nalLength
        }

        frameCount += 1
        if frameCount % 60 == 0 { log.debug("encoded frame #\(self.frameCount) key=\(isKeyframe) bytes=\(annexB.count)") }
        onEncodedFrame(annexB, isKeyframe, Int(width), Int(height))
    }

    private func cmSampleBufferIsNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }

    private func parameterSetCount(_ format: CMFormatDescription) -> Int {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return count
    }

    private func parameterSet(_ format: CMFormatDescription, at index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
