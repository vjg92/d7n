import XCTest
import AVFoundation
@testable import d7n

final class AudioStoreTests: XCTestCase {
    func testCallbackBufferIsCopiedAndReleasedOnTake() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0][0] = 0.25
        let store = AudioStore()
        store.append(buffer)
        buffer.floatChannelData![0][0] = 0.75
        let result = try store.take()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].floatChannelData![0][0], 0.25)
        XCTAssertTrue(try store.take().isEmpty)
    }
    func testOverlongAudioFailsClosedAndReleasesBuffers() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        let store = AudioStore()
        for _ in 0..<121 { store.append(buffer) }
        XCTAssertThrowsError(try store.take())
        XCTAssertTrue(try store.take().isEmpty)
    }
}
