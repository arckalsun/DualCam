import AVFoundation
import CoreVideo
import Foundation

/// 把两路摄像头画面按当前布局实时合成为一个 .mov 文件（含麦克风声音）。
final class VideoRecorder {
    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let layout: LayoutConfig
    private let canvas: CGSize
    private let compositor: Compositor
    private let queue = DispatchQueue(label: "com.dualcamera.recorder")

    private var frames: [CameraSlot: CVPixelBuffer] = [:]
    private var startTime: CMTime = .invalid
    private var frameCount = 0
    private let stateLock = NSLock()
    private var composeInFlight = false
    private var lastTime: CMTime = .invalid
    private var finished = false
    private let minFrameInterval = CMTime(value: 1, timescale: 30)

    init?(layout: LayoutConfig, canvas: CGSize, compositor: Compositor = .shared) {
        self.layout = layout
        self.canvas = canvas
        self.compositor = compositor
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCam-\(UUID().uuidString).mov")

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )

        // 音频直接透传麦克风采样，不做重编码。
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        } else {
            audioInput.markAsFinished()
        }

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = writer.inputs.contains(where: { $0 === audioInput }) ? audioInput : nil
    }

    // MARK: - 写入

    func appendVideo(_ buffer: CVPixelBuffer, slot: CameraSlot, at time: CMTime) {
        // 上一帧还没合成完就直接丢弃，防止队列无限堆积导致停止录像时卡住。
        stateLock.lock()
        let canEnqueue = !composeInFlight
        if canEnqueue { composeInFlight = true }
        stateLock.unlock()
        guard canEnqueue else { return }

        queue.async { [weak self] in
            defer {
                self?.stateLock.lock()
                self?.composeInFlight = false
                self?.stateLock.unlock()
            }
            guard let self, !self.finished else { return }
            self.frames[slot] = buffer
            guard let back = self.frames[.back], let front = self.frames[.front] else { return }

            if self.startTime.isValid,
               CMTimeCompare(CMTimeSubtract(time, self.lastTime), self.minFrameInterval) < 0 {
                return
            }

            // 像素缓冲池只有在 writer 开始写入之后才存在，所以必须先 startWriting。
            if !self.startTime.isValid {
                guard self.writer.startWriting() else {
                    self.finishFailed()
                    return
                }
                self.writer.startSession(atSourceTime: time)
                self.startTime = time
            }

            guard let pool = self.adaptor.pixelBufferPool else { return }
            var destination: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
                  let output = destination else { return }

            self.compositor.compose(
                videoFrames: [.back: back, .front: front],
                layout: self.layout,
                canvas: self.canvas,
                into: output
            )

            guard self.writer.status == .writing,
                  self.adaptor.assetWriterInput.isReadyForMoreMediaData else { return }

            if self.adaptor.append(output, withPresentationTime: time) {
                self.frameCount += 1
            }
            self.lastTime = time

        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self,
                  !self.finished,
                  self.startTime.isValid,
                  self.writer.status == .writing,
                  let audioInput = self.audioInput,
                  audioInput.isReadyForMoreMediaData else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard CMTimeCompare(time, self.startTime) >= 0 else { return }
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - 结束

    func finish(completion: @escaping (URL?) -> Void) {
        CamLog.d("finish requested, started=\(startTime.isValid), frames=\(frameCount), status=\(writer.status.rawValue)")
        // 这里必须强引用 self：调用方会在 finish 返回后立刻释放 recorder，
        // 用 weak 会导致 block 空跑、completion 永远不回调（表现为一直转圈）。
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            CamLog.d("finish running on queue, frames=\(self.frameCount)")

            guard self.startTime.isValid else {
                self.writer.cancelWriting()
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer.finishWriting {
                CamLog.d("finishWriting done status=\(self.writer.status.rawValue) frames=\(self.frameCount)")
                let url = self.writer.status == .completed ? self.outputURL : nil
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    private func finishFailed() {
        finished = true
        writer.cancelWriting()
    }
}
