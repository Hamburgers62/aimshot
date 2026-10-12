import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes the finished photo (keeping the camera's metadata) and saves it to Photos.
enum PhotoSaver {
    /// HEIC (or JPEG fallback) with the original EXIF, fixed up for the crop and rotation.
    static func encode(_ cg: CGImage, metadata: [String: Any]) -> Data? {
        var meta = metadata
        meta[kCGImagePropertyOrientation as String] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
            meta[kCGImagePropertyExifDictionary as String] = exif
        }
        meta[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        for type in [UTType.heic, UTType.jpeg] {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(dest, cg, meta as CFDictionary)
            if CGImageDestinationFinalize(dest) { return data as Data }
        }
        return nil
    }

    /// Saves the photo, and the RAW file as its own item if there is one. Completion runs on main.
    static func save(photo: Data, raw: Data?, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo, options: nil)
                if let raw = raw {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "com.adobe.raw-image"
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: raw, options: options)
                }
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            })
        }
    }
}
