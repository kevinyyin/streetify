import AVFoundation

/// One sine oscillator whose pitch and on/off follow `ToneSettings`.
final class Tone {
    let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    // ponytail: plain Doubles read on the render thread without a lock; use an atomic if the tone ever glitches.
    private var frequencyHz = 0.0
    private var isOn = false
    private var phase = 0.0

    init() {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: outputRate > 0 ? outputRate : 44_100, channels: 1)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let step = 2 * Double.pi * frequencyHz / format.sampleRate
            let amplitude = isOn ? Config.toneAmplitude : 0
            for frame in 0..<Int(frameCount) {
                let sample = amplitude * Float(sin(phase))
                phase = (phase + step).truncatingRemainder(dividingBy: 2 * .pi)
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func apply(_ settings: ToneSettings) {
        // Route changes (e.g. Bluetooth headphones) and interruptions (calls, Siri) stop the engine; restart on the next update.
        if !engine.isRunning { try? engine.start() }
        frequencyHz = settings.frequencyHz
        isOn = settings.isOn
    }
}
