import Foundation

/// One chunk of an H.264 video frame. Encoded frames (especially keyframes) exceed a single
/// record, so each is split into ≤~60 KB chunks and reassembled on the phone by `frameID`.
///
/// This rides the same ``SecureSession`` as control input for the LAN path — the screen-streaming
/// half of the remote-desktop pivot. (A later optimization moves video to its own channel so a heavy
/// keyframe can't delay a click.)
public struct VideoChunk: Sendable, Equatable {
    public let frameID: UInt32
    public let chunkIndex: UInt16
    public let chunkCount: UInt16
    /// bit 0 = keyframe (IDR).
    public let flags: UInt8
    public let width: UInt16
    public let height: UInt16
    /// This chunk's slice of the frame's Annex-B bytes.
    public let data: Data

    public var isKeyframe: Bool { flags & 0x1 != 0 }

    public init(frameID: UInt32, chunkIndex: UInt16, chunkCount: UInt16,
                isKeyframe: Bool, width: UInt16, height: UInt16, data: Data) {
        self.frameID = frameID
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.flags = isKeyframe ? 0x1 : 0x0
        self.width = width
        self.height = height
        self.data = data
    }

    /// Splits a full encoded Annex-B frame into wire chunks.
    public static func chunk(frameID: UInt32, annexB: Data, isKeyframe: Bool, width: Int, height: Int,
                             maxChunk: Int = 60_000) -> [VideoChunk] {
        let total = max(1, (annexB.count + maxChunk - 1) / maxChunk)
        var chunks: [VideoChunk] = []
        var offset = 0
        for i in 0 ..< total {
            let end = min(offset + maxChunk, annexB.count)
            chunks.append(VideoChunk(
                frameID: frameID, chunkIndex: UInt16(i), chunkCount: UInt16(total),
                isKeyframe: isKeyframe, width: UInt16(truncatingIfNeeded: width),
                height: UInt16(truncatingIfNeeded: height),
                data: annexB.subdata(in: offset ..< end)))
            offset = end
        }
        return chunks
    }
}

/// Reassembles ``VideoChunk``s into whole Annex-B frames, in order, dropping incomplete ones.
public struct VideoReassembler {
    private var currentFrameID: UInt32?
    private var received: [Int: Data] = [:]
    private var expected = 0

    public init() {}

    /// Feeds a chunk; returns the complete frame `(annexB, isKeyframe, width, height)` when the last
    /// chunk of a frame arrives, else nil.
    public mutating func accept(_ chunk: VideoChunk) -> (annexB: Data, isKeyframe: Bool, width: Int, height: Int)? {
        if chunk.frameID != currentFrameID {
            currentFrameID = chunk.frameID
            received = [:]
            expected = Int(chunk.chunkCount)
        }
        received[Int(chunk.chunkIndex)] = chunk.data
        guard received.count == expected else { return nil }

        var annexB = Data()
        for i in 0 ..< expected {
            guard let part = received[i] else { return nil } // gap — drop this frame
            annexB.append(part)
        }
        received = [:]
        currentFrameID = nil
        return (annexB, chunk.isKeyframe, Int(chunk.width), Int(chunk.height))
    }
}
