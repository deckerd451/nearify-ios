import Foundation
import UIKit
import Supabase

/// Service for managing profile image uploads, updates, and deletions.
/// Writes avatar_url to public.profiles (the canonical profile table).
@MainActor
final class ProfileImageService {
    
    static let shared = ProfileImageService()
    
    private let supabase = AppEnvironment.shared.supabaseClient
    private let bucketName = "profile-images"
    
    private init() {}

    enum Variant: String, CaseIterable {
        case immersive = "immersive_4x5"
        case header = "header"
        case avatar = "avatar"
        case nearby = "nearby"
        case placeholder = "placeholder"

        var maxDimension: CGFloat {
            switch self {
            case .immersive: return 1400
            case .header: return 800
            case .avatar: return 420
            case .nearby: return 180
            case .placeholder: return 48
            }
        }

        var compression: CGFloat {
            switch self {
            case .immersive: return 0.84
            case .header: return 0.8
            case .avatar: return 0.76
            case .nearby: return 0.7
            case .placeholder: return 0.45
            }
        }
    }
    
    // MARK: - Image Processing
    
    /// Processes raw image data into compressed JPEG data
    func processImageData(_ data: Data) throws -> Data {
        print("[ProfileImage] 📸 Processing selected image")
        print("[ProfileImage]    Original size: \(data.count) bytes")
        
        guard let image = UIImage(data: data) else {
            throw ProfileImageError.invalidImageData
        }
        
        let resized = resizeImage(image, maxDimension: 800)
        
        guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
            throw ProfileImageError.compressionFailed
        }
        
        print("[ProfileImage]    Processed size: \(jpegData.count) bytes")
        print("[ProfileImage]    Dimensions: \(resized.size.width)x\(resized.size.height)")
        
        return jpegData
    }

    func processIdentityImageVariants(_ data: Data) throws -> (primary: Data, variants: [Variant: Data], warnings: [String]) {
        guard let image = UIImage(data: data) else { throw ProfileImageError.invalidImageData }
        let normalized = normalizeOrientation(image)
        let warnings = qualityWarnings(for: normalized)

        let immersiveCrop = cropToRatio(normalized, aspectRatio: 4.0 / 5.0)
        var variants: [Variant: Data] = [:]

        for variant in Variant.allCases {
            let source: UIImage = (variant == .immersive) ? immersiveCrop : normalized
            let resized = resizeImage(source, maxDimension: variant.maxDimension)
            if let data = resized.jpegData(compressionQuality: variant.compression) {
                variants[variant] = data
            }
        }

        guard let primary = variants[.immersive] else { throw ProfileImageError.compressionFailed }
        return (primary, variants, warnings)
    }

    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func cropToRatio(_ image: UIImage, aspectRatio: CGFloat) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let targetHeight = width / aspectRatio
        if targetHeight <= height {
            let y = max(0, (height * 0.18) - (targetHeight * 0.18))
            let rect = CGRect(x: 0, y: min(y, height - targetHeight), width: width, height: targetHeight)
            let renderer = UIGraphicsImageRenderer(size: rect.size)
            return renderer.image { _ in image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y)) }
        }

        let targetWidth = height * aspectRatio
        let x = (width - targetWidth) / 2
        let rect = CGRect(x: max(0, x), y: 0, width: min(width, targetWidth), height: height)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y)) }
    }

    private func qualityWarnings(for image: UIImage) -> [String] {
        var warnings: [String] = []
        let area = image.size.width * image.size.height
        if area < 500_000 { warnings.append("Move slightly closer for better recognition.") }
        if let cg = image.cgImage {
            if cg.width < 700 || cg.height < 700 { warnings.append("Face may be difficult to recognize at this resolution.") }
        }
        return warnings
    }
    
    /// Resizes an image to fit within maxDimension while maintaining aspect ratio
    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        
        if size.width <= maxDimension && size.height <= maxDimension {
            return image
        }
        
        let ratio = size.width / size.height
        let newSize: CGSize
        
        if size.width > size.height {
            newSize = CGSize(width: maxDimension, height: maxDimension / ratio)
        } else {
            newSize = CGSize(width: maxDimension * ratio, height: maxDimension)
        }
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    // MARK: - Upload
    
    /// Uploads a profile image to storage and persists the public URL
    /// into public.profiles.avatar_url for the given profile row.
    func uploadProfileImage(
        _ imageData: Data,
        for profileId: UUID
    ) async throws -> ProfileImageResult {
        print("[ProfileImage] ⬆️ Starting profile image upload")
        print("[ProfileImage]    Bucket: \(bucketName)")
        print("[ProfileImage]    Profile ID: \(profileId)")
        print("[ProfileImage]    Data size: \(imageData.count) bytes")
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let storagePath = "avatars/\(profileId.uuidString)/\(timestamp).jpg"
        
        print("[ProfileImage]    Upload path: \(storagePath)")
        
        do {
            try await supabase.storage
                .from(bucketName)
                .upload(
                    storagePath,
                    data: imageData,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false
                    )
                )
            print("[ProfileImage] ✅ Upload successful to bucket '\(bucketName)' at path '\(storagePath)'")
        } catch {
            print("[ProfileImage] ❌ Upload FAILED to bucket '\(bucketName)'")
            print("[ProfileImage]    Path: \(storagePath)")
            print("[ProfileImage]    Error: \(error)")
            print("[ProfileImage]    Error detail: \(error.localizedDescription)")
            throw error
        }
        
        let publicURL: URL
        do {
            publicURL = try supabase.storage
                .from(bucketName)
                .getPublicURL(path: storagePath)
            print("[ProfileImage] ✅ Public URL generated: \(publicURL.absoluteString)")
        } catch {
            print("[ProfileImage] ❌ Public URL generation FAILED for path '\(storagePath)' in bucket '\(bucketName)'")
            print("[ProfileImage]    Error: \(error)")
            throw error
        }
        
        do {
            try await updateProfileAvatarUrl(
                profileId: profileId,
                avatarUrl: publicURL.absoluteString
            )
            print("[ProfileImage] ✅ avatar_url persisted to public.profiles")
            print("[ProfileImage]    avatar_url: \(publicURL.absoluteString)")
        } catch {
            print("[ProfileImage] ❌ Failed to persist avatar_url to public.profiles")
            print("[ProfileImage]    Error: \(error)")
            throw error
        }
        
        return ProfileImageResult(
            imageUrl: publicURL.absoluteString,
            imagePath: storagePath
        )
    }
    
    // MARK: - Remove
    
    func removeProfileImage(
        for profileId: UUID,
        currentImagePath: String?
    ) async throws {
        print("[ProfileImage] 🗑️ Removing profile image")
        print("[ProfileImage]    Profile ID: \(profileId)")
        print("[ProfileImage]    Current path: \(currentImagePath ?? "nil")")
        
        try await updateProfileAvatarUrl(
            profileId: profileId,
            avatarUrl: nil
        )
        
        print("[ProfileImage] ✅ avatar_url cleared in public.profiles")
        
        if let imagePath = currentImagePath, !imagePath.isEmpty {
            do {
                print("[ProfileImage] 🗑️ Deleting storage file from bucket '\(bucketName)': \(imagePath)")
                try await supabase.storage
                    .from(bucketName)
                    .remove(paths: [imagePath])
                
                print("[ProfileImage] ✅ Storage file deleted: \(imagePath)")
            } catch {
                print("[ProfileImage] ⚠️ Storage deletion failed (non-fatal): \(error)")
            }
        }
    }
    
    // MARK: - Database Update (public.profiles)
    
    private func updateProfileAvatarUrl(
        profileId: UUID,
        avatarUrl: String?
    ) async throws {
        struct AvatarUpdate: Encodable {
            let avatar_url: String?
        }
        
        let update = AvatarUpdate(avatar_url: avatarUrl)
        
        print("[ProfileImage] 💾 Updating public.profiles.avatar_url for id: \(profileId)")
        print("[ProfileImage]    avatar_url: \(avatarUrl ?? "nil")")
        
        try await supabase
            .from("profiles")
            .update(update)
            .eq("id", value: profileId.uuidString)
            .execute()
        
        print("[ProfileImage] ✅ public.profiles row updated")
    }
}

struct ProfileImageResult {
    let imageUrl: String
    let imagePath: String
}

enum ProfileImageError: LocalizedError {
    case failedToLoadImage
    case invalidImageData
    case compressionFailed
    case uploadFailed
    case updateFailed
    
    var errorDescription: String? {
        switch self {
        case .failedToLoadImage:
            return "Failed to load selected image"
        case .invalidImageData:
            return "Invalid image data"
        case .compressionFailed:
            return "Failed to compress image"
        case .uploadFailed:
            return "Failed to upload image"
        case .updateFailed:
            return "Failed to update profile"
        }
    }
}
