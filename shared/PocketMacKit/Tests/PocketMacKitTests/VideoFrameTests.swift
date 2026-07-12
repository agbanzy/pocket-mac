import Foundation
import Testing
@testable import PocketMacKit

@Suite("Video chunk codec + reassembly")
struct VideoFrameTests {
    let codec = FrameCodec()

    @Test("a video chunk round-trips through the codec")
    func chunkRoundTrip() throws {
        let chunk = VideoChunk(frameID: 7, chunkIndex: 2, chunkCount: 5, isKeyframe: true,
                               width: 1600, height: 900, data: Data((0..<1000).map { UInt8($0 & 0xFF) }))
        let decoded = try codec.decode(try codec.encode(.video(chunk)))
        #expect(decoded == .video(chunk))
    }

    @Test("chunking + reassembly reproduces the original Annex-B frame")
    func chunkAndReassemble() {
        let original = Data((0 ..< 200_000).map { UInt8($0 & 0xFF) }) // > several 60KB chunks
        let chunks = VideoChunk.chunk(frameID: 42, annexB: original, isKeyframe: true, width: 1280, height: 720)
        #expect(chunks.count == 4) // ceil(200000 / 60000)

        var reassembler = VideoReassembler()
        var result: (annexB: Data, isKeyframe: Bool, width: Int, height: Int)?
        for chunk in chunks { result = reassembler.accept(chunk) }
        #expect(result?.annexB == original)
        #expect(result?.isKeyframe == true)
        #expect(result?.width == 1280)
    }

    @Test("a dropped chunk yields no frame (incomplete frames are discarded)")
    func droppedChunk() {
        let chunks = VideoChunk.chunk(frameID: 1, annexB: Data(count: 150_000), isKeyframe: false, width: 100, height: 100)
        var reassembler = VideoReassembler()
        var result: (annexB: Data, isKeyframe: Bool, width: Int, height: Int)?
        for chunk in chunks.dropLast() { result = reassembler.accept(chunk) } // never deliver the last
        #expect(result == nil)
    }
}
