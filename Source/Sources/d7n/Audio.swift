@preconcurrency import AVFoundation
import Speech

enum QuietError: Error { case unavailable, audio, tooLong, overflow }

/// The audio callback owns only this locked buffer store, never UI state.
final class AudioStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var seconds = 0.0
    private var failed = false
    func append(_ source: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        seconds += Double(source.frameLength) / source.format.sampleRate
        guard seconds <= 120, let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { failed = true; return }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count {
            guard let from = src[i].mData, let to = dst[i].mData else { failed = true; return }
            memcpy(to, from, Int(src[i].mDataByteSize))
        }
        buffers.append(copy)
    }
    func take() throws -> [AVAudioPCMBuffer] {
        lock.lock(); defer { buffers.removeAll(); seconds = 0; failed = false; lock.unlock() }
        guard !failed else { throw QuietError.overflow }
        return buffers
    }
}

@MainActor final class Dictation {
    private var engine: AVAudioEngine?
    private var store: AudioStore?
    private var analyzer: SpeechAnalyzer?
    private(set) var locale = Locale(identifier: "en_AU")

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw QuietError.unavailable }
        locale = supported
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let warm = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await warm.prepareToAnalyze(in: format)
        await warm.cancelAndFinishNow()
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw QuietError.audio }
        let store = AudioStore()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in store.append(buffer) }
        self.engine = engine; self.store = store
        do { try engine.start() } catch { cancelRecording(); throw error }
    }

    func cancelRecording() {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        engine = nil; store = nil
    }

    func stop() throws -> [AVAudioPCMBuffer] {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        let captured = store; store = nil
        return try captured?.take() ?? []
    }

    func cancelAnalysis() async { await analyzer?.cancelAndFinishNow() }

    func transcribe(_ buffers: [AVAudioPCMBuffer]) async throws -> String {
        guard let source = buffers.first?.format else { return "" }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: source, to: format) else { throw QuietError.audio }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        defer { self.analyzer = nil }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await analyzer.start(inputSequence: stream)
            for buffer in buffers {
                try Task.checkCancellation()
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / source.sampleRate)) + 256
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw QuietError.audio }
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true; inputStatus.pointee = .haveData; return buffer
                }
                if let conversionError { throw conversionError }
                guard status != .error else { throw QuietError.audio }
                if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await results.value
            try Task.checkCancellation()
            return text
        } catch {
            continuation.finish(); results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
