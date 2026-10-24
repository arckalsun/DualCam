import CoreGraphics
import Foundation

/// 两路画面的排布方式。
enum LayoutMode: String, CaseIterable, Identifiable, Codable {
    /// 上下平分（默认）
    case vertical
    /// 左右平分
    case horizontal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: return "上下"
        case .horizontal: return "左右"
        }
    }

    var symbolName: String {
        switch self {
        case .vertical: return "rectangle.split.1x2"
        case .horizontal: return "rectangle.split.2x1"
        }
    }

    var toggled: LayoutMode {
        self == .vertical ? .horizontal : .vertical
    }
}

/// 当前布局：模式 + 分割比例（第一路画面所占比例）。
struct LayoutConfig: Equatable {
    var mode: LayoutMode = .vertical
    /// 0.5 表示平分；取值范围 0.15...0.85，避免某一路被拖到不可见。
    var ratio: CGFloat = 0.5

    static let ratioRange: ClosedRange<CGFloat> = 0.15...0.85

    var clampedRatio: CGFloat {
        min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
    }

    /// 计算两路画面在给定尺寸中的位置（UIKit 坐标系，原点左上角）。
    /// - Returns: (第一路/后置摄像头, 第二路/前置摄像头)
    func frames(in size: CGSize) -> (CGRect, CGRect) {
        let r = clampedRatio
        let w = size.width
        let h = size.height
        switch mode {
        case .vertical:
            return (
                CGRect(x: 0, y: 0, width: w, height: h * r),
                CGRect(x: 0, y: h * r, width: w, height: h * (1 - r))
            )
        case .horizontal:
            return (
                CGRect(x: 0, y: 0, width: w * r, height: h),
                CGRect(x: w * r, y: 0, width: w * (1 - r), height: h)
            )
        }
    }

    /// 录制/拍照使用固定竖屏画布。
    static let videoCanvas = CGSize(width: 1080, height: 1920)
}
