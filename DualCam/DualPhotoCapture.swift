import AVFoundation
import UIKit

/// 同时触发前后摄像头的拍照，并把两张照片按当前布局合成一张。
final class DualPhotoCapture: NSObject {
    private let outputs: [CameraSlot: AVCapturePhotoOutput]
    private let layout: LayoutConfig
    private let compositor: Compositor
    private let lock = NSLock()

    private var images: [CameraSlot: UIImage] = [:]
    private var completedCallbacks = 0
    private var firstError: Error?
    private var finished = false
    private var completion: ((Result<UIImage, Error>) -> Void)?

    init(outputs: [CameraSlot: AVCapturePhotoOutput],
         layout: LayoutConfig,
         compositor: Compositor = .shared) {
        self.outputs = outputs
        self.layout = layout
        self.compositor = compositor
    }

    func capture(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
        for output in outputs.values {
            let settings = AVCapturePhotoSettings()
            // 多摄会话下 maxPhotoQualityPrioritization 可能被系统降到 .balanced，
            // 请求值高于上限会直接抛 NSInvalidArgumentException。
            settings.photoQualityPrioritization = quality(for: output)
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func quality(for output: AVCapturePhotoOutput) -> AVCapturePhotoOutput.QualityPrioritization {
        switch output.maxPhotoQualityPrioritization {
        case .quality: return .quality
        case .balanced: return .balanced
        default: return .speed
        }
    }
}

extension DualPhotoCapture: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        completedCallbacks += 1
        if let error, firstError == nil {
            firstError = error
        }
        if let slot = outputs.first(where: { $0.value === output })?.key,
           let data = photo.fileDataRepresentation(),
           let image = UIImage(data: data) {
            images[slot] = image
        }

        guard completedCallbacks >= outputs.count else { return }
        finished = true
        let completion = self.completion
        let result: Result<UIImage, Error>
        if let error = firstError {
            result = .failure(error)
        } else if images.count == outputs.count,
                  let composed = compositor.compose(photos: images, layout: layout) {
            result = .success(composed)
        } else {
            result = .failure(CameraError.composeFailed)
        }

        DispatchQueue.main.async {
            completion?(result)
        }
    }
}
