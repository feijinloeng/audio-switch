@preconcurrency import AVFAudio
import Foundation
import OSLog

enum CompanionInboundAudioEvent: Sendable {
    case ignored
    case playoutConfigured(startupPackets: Int)
    case firstAudioPacket
}

/// The complete UDP-to-playout pipeline for the phone endpoint.
///
/// This actor deliberately owns authentication, reordering, PCM conversion,
/// and AVAudioEngine scheduling. Keeping those 200-per-second operations away
/// from the main actor prevents SwiftUI work from starving the hardware queue.
actor CompanionAudioRenderer {
    private static let logger = Logger(
        subsystem: "com.mankeipun.yinpinqiehuan.companion",
        category: "audio-stream"
    )
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let manualDelay = AVAudioUnitDelay()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(PanoramaAudioPacket.sampleRate),
        channels: AVAudioChannelCount(PanoramaAudioPacket.channels),
        interleaved: false
    )!

    private var jitterBuffer = PanoramaJitterBuffer()
    private var replayWindow = PanoramaReplayWindow()
    private var isGraphConfigured = false
    private var hasReceivedAudio = false
    private var scheduledFrameCount = 0
    private var timelineGeneration: UInt64 = 0
    private var acceptedPacketCount = 0
    private var renderedBufferCount = 0
    private var fadeOutCount = 0
    /// Keep 200 ms scheduled ahead of the render clock. This is independent of
    /// the one-second network jitter buffer used to absorb Wi-Fi variation.
    private let targetScheduledFrameCount = 9_600
    private let packetsPerScheduledBuffer = 4

    func startNewSession() throws {
        resetTimeline()
        replayWindow = PanoramaReplayWindow()
        hasReceivedAudio = false
        try start()
    }

    func restartAfterRouteChange() throws {
        resetTimeline()
        try start()
    }

    func stop() {
        resetTimeline()
        replayWindow = PanoramaReplayWindow()
        hasReceivedAudio = false
    }

    func consume(
        _ datagram: Data,
        sessionID: UUID,
        key: PanoramaSessionKey
    ) -> CompanionInboundAudioEvent {
        guard let messageType = datagram.first.flatMap(PanoramaDatagramType.init(rawValue:)) else {
            return .ignored
        }
        if messageType == .playoutControl,
           let control = try? PanoramaCompanionPlayoutControl.decodeDatagram(datagram),
           control.isValid(for: sessionID, key: key) {
            manualDelay.delayTime = PanoramaCompanionDelayPolicy.delaySeconds(
                startupPackets: control.startupPackets
            )
            return .playoutConfigured(startupPackets: control.startupPackets)
        }

        guard messageType == .audio,
              let packet = try? PanoramaAudioPacket.decode(
            datagram,
            expectedSessionID: sessionID,
            authenticatedWith: key
        ), replayWindow.accept(packet.sequence) else {
            return .ignored
        }

        jitterBuffer.insert(packet)
        acceptedPacketCount += 1
        if acceptedPacketCount.isMultiple(of: 1_000) {
            Self.logger.debug(
                "iPhone stream packets=\(self.acceptedPacketCount, privacy: .public) scheduledFrames=\(self.scheduledFrameCount, privacy: .public) renderedBuffers=\(self.renderedBufferCount, privacy: .public)"
            )
        }
        fillPlayoutQueue()
        defer { hasReceivedAudio = true }
        return hasReceivedAudio ? .ignored : .firstAudioPacket
    }

    private func start() throws {
        if !isGraphConfigured {
            engine.attach(player)
            engine.attach(manualDelay)
            manualDelay.wetDryMix = 100
            manualDelay.feedback = 0
            manualDelay.lowPassCutoff = 22_050
            engine.connect(player, to: manualDelay, format: format)
            engine.connect(manualDelay, to: engine.mainMixerNode, format: format)
            isGraphConfigured = true
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func resetTimeline() {
        timelineGeneration &+= 1
        player.stop()
        engine.stop()
        scheduledFrameCount = 0
        jitterBuffer = PanoramaJitterBuffer()
    }

    private func fillPlayoutQueue() {
        while scheduledFrameCount < targetScheduledFrameCount {
            guard let pcm = dequeuePCMGroup() else { return }
            let frameCount = UInt32(pcm.count / (MemoryLayout<Int16>.size * Int(format.channelCount)))
            guard frameCount > 0 else { return }
            player.volume = 1
            schedule(pcm, frameCount: frameCount)
        }
    }

    /// Batching four 5 ms UDP blocks into one 20 ms AVAudioPCMBuffer reduces
    /// schedule/callback churn fourfold while preserving the wire cadence.
    private func dequeuePCMGroup() -> Data? {
        var pcm = Data()
        for _ in 0 ..< packetsPerScheduledBuffer {
            switch jitterBuffer.dequeue() {
            case .notReady:
                return pcm.isEmpty ? nil : pcm
            case let .audio(block), let .interpolated(block):
                pcm.append(block)
            case .fadeOut:
                fadeOutCount += 1
                Self.logger.error(
                    "iPhone stream rebuffer requested after sustained packet loss count=\(self.fadeOutCount, privacy: .public)"
                )
                player.volume = max(0, player.volume - 0.05)
                return pcm.isEmpty ? nil : pcm
            }
        }
        return pcm
    }

    private func schedule(_ pcm: Data, frameCount: UInt32) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }
        pcm.withUnsafeBytes { source in
            let samples = source.bindMemory(to: Int16.self)
            guard samples.count >= Int(frameCount) * Int(format.channelCount),
                  let channels = buffer.floatChannelData else { return }
            for channel in 0 ..< Int(format.channelCount) {
                let destination = channels[channel]
                for frame in 0 ..< Int(frameCount) {
                    let sample = Float(samples[frame * Int(format.channelCount) + channel]) / 32_767
                    destination[frame] = max(-1, sample)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        scheduledFrameCount += Int(frameCount)
        let generation = timelineGeneration
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataRendered
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.didRender(frameCount: Int(frameCount), generation: generation)
            }
        }
    }

    private func didRender(frameCount: Int, generation: UInt64) {
        guard generation == timelineGeneration else { return }
        renderedBufferCount += 1
        scheduledFrameCount = max(0, scheduledFrameCount - frameCount)
        fillPlayoutQueue()
    }
}
