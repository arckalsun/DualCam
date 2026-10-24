import AVFoundation
import SwiftUI

/// 把 AVCaptureVideoPreviewLayer 塞进 SwiftUI，并让它跟随视图尺寸变化。
struct CameraPreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewHostView {
        PreviewHostView()
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.attach(layer)
    }
}

final class PreviewHostView: UIView {
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ layer: AVCaptureVideoPreviewLayer?) {
        guard previewLayer !== layer else { return }
        previewLayer?.removeFromSuperlayer()
        previewLayer = layer
        guard let layer else { return }
        layer.frame = bounds
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
    }
}
