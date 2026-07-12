import SwiftUI
import AVFoundation
import CoreMedia

/// Displays the Mac's H.264 screen stream. `AVSampleBufferDisplayLayer` decodes and renders the
/// stream directly — we parse the Annex-B NAL units into `CMSampleBuffer`s (building a format
/// description from the SPS/PPS that ride each keyframe) and enqueue them.
final class ScreenHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false // let the SwiftUI control gesture above receive touches
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Feed one complete Annex-B frame (as emitted by the Mac's ScreenStreamer).
    func enqueue(annexB: Data) {
        let nals = Self.splitNALUnits(annexB)
        var pictureNALs: [Data] = []
        var newSPS = sps, newPPS = pps
        for nal in nals {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7: newSPS = nal          // SPS
            case 8: newPPS = nal          // PPS
            case 9: continue              // access-unit delimiter — skip
            default: pictureNALs.append(nal)
            }
        }
        // (Re)build the format description when the parameter sets change.
        if let s = newSPS, let p = newPPS, s != sps || p != pps || formatDescription == nil {
            sps = s; pps = p
            formatDescription = Self.makeFormatDescription(sps: s, pps: p)
        }
        guard let formatDescription, !pictureNALs.isEmpty else { return }

        // Convert Annex-B picture NALs to AVCC (4-byte length prefixed).
        var avcc = Data()
        for nal in pictureNALs {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }
        guard let sampleBuffer = Self.makeSampleBuffer(avcc: avcc, format: formatDescription) else { return }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    // MARK: Annex-B helpers

    private static func splitNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var nals: [Data] = []
        var i = 0
        var nalStart = -1
        func isStart(_ p: Int) -> Int {
            if p + 3 < bytes.count, bytes[p] == 0, bytes[p+1] == 0, bytes[p+2] == 0, bytes[p+3] == 1 { return 4 }
            if p + 2 < bytes.count, bytes[p] == 0, bytes[p+1] == 0, bytes[p+2] == 1 { return 3 }
            return 0
        }
        while i < bytes.count {
            let sc = isStart(i)
            if sc > 0 {
                if nalStart >= 0 { nals.append(Data(bytes[nalStart ..< i])) }
                i += sc
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0, nalStart < bytes.count { nals.append(Data(bytes[nalStart ..< bytes.count])) }
        return nals
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let pointers = [spsPtr, ppsPtr]
                let sizes = [sps.count, pps.count]
                var format: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                return status == noErr ? format : nil
            }
        }
    }

    private static func makeSampleBuffer(avcc: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var data = avcc
        let created = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: raw.baseAddress,
                blockLength: avcc.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                flags: 0, blockBufferOut: &blockBuffer)
        }
        guard created == noErr, let blockBuffer else { return nil }
        // Copy bytes in (the source Data is transient).
        var mutableCopy: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: blockBuffer,
                                            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                            offsetToData: 0, dataLength: 0, flags: kCMBlockBufferAlwaysCopyDataFlag,
                                            blockBufferOut: &mutableCopy) == noErr, let mutableCopy else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sizes = [avcc.count]
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: mutableCopy, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        // Display immediately (low latency).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

/// The "Screen" surface: shows the Mac's live screen and lets you operate it directly via the
/// UIKit ``ScreenControlView`` (tap-click, hold-drag, two-finger scroll, pinch-zoom). Manages the
/// stream's start/stop lifecycle.
struct ScreenModeView: View {
    let connection: ConnectionController
    let connected: Bool

    var body: some View {
        ZStack {
            Color.black
            if connected {
                ScreenControlSurface(connection: connection)
            } else {
                ContentUnavailableView("Not connected", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .onAppear { if connected { connection.startVideo(fps: 30) } }
        .onDisappear {
            connection.stopVideo()
            connection.onVideoFrame = nil
        }
        .onChange(of: connected) { _, now in if now { connection.startVideo(fps: 30) } }
    }
}
