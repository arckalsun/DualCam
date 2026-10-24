import Foundation
import Photos
import UIKit

/// 把合成好的照片 / 视频写入系统相册。
enum PhotoLibrary {
    static func save(image: UIImage,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            completion(.failure(CameraError.composeFailed))
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCam-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            completion(.failure(error))
            return
        }
        saveResource(at: url, type: .photo) { result in
            try? FileManager.default.removeItem(at: url)
            completion(result)
        }
    }

    static func save(videoAt url: URL,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        saveResource(at: url, type: .video, completion: completion)
    }

    private static func saveResource(at url: URL,
                                     type: PHAssetResourceType,
                                     completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(.failure(SaveError.permissionDenied))
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: type, fileURL: url, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(error ?? SaveError.unknown))
                    }
                }
            }
        }
    }

    enum SaveError: LocalizedError {
        case permissionDenied
        case unknown

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有相册写入权限，请到「设置」中允许"
            case .unknown: return "未知错误"
            }
        }
    }
}
