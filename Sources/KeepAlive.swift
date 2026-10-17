import Foundation
import AVFoundation
import Combine

/// 静音音频保活：让 App 退到后台后仍能保持端口监听、脚本与 Cookie 服务可用。
final class KeepAlive: ObservableObject {
    static let shared = KeepAlive()

    @Published private(set) var active = false
    @Published private(set) var recoverCount = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !active else { return }
        installObservers()
        build()
        active = true
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop()
        engine?.stop()
        engine = nil; player = nil; buffer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        active = false
    }

    private func build() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buf.frameLength = 44100
        if let ch = buf.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                memset(ch[c], 0, Int(buf.frameLength) * MemoryLayout<Float>.size)
            }
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            engine.prepare()
            try engine.start()
            player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            player.play()
        } catch {
            // 保活失败不影响主功能
            print("KeepAlive 失败: \(error)")
        }

        self.engine = engine
        self.player = player
        self.buffer = buf
    }

    private func check() {
        guard active else { return }
        guard let engine, let player else { build(); return }
        if !engine.isRunning || !player.isPlaying {
            recover()
        }
    }

    private func recover() {
        guard let engine, let player, let buf else { rebuild(); return }
        do {
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
                player.play()
            }
            recoverCount += 1
        } catch {
            rebuild()
        }
    }

    private func rebuild() {
        player?.stop()
        engine?.stop()
        engine = nil; player = nil; buffer = nil
        build()
        recoverCount += 1
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        })
        // 媒体服务重置后原引擎已失效，必须重建对象
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.rebuild() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self?.rebuild() }
        })
    }
}
