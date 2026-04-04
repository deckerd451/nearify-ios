import Foundation
import UIKit
import Supabase

/// Service for managing profile image uploads, updates, and deletions
@MainActor
final class ProfileImageService {
    
    static let shared = ProfileImageService()
    
    private let supabase = AppEnvironment.shared.supabaseClient
    private let bucketName = "profile-images"
    
    private init() {}
    
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
    
    /// Uploads a profile image and updates the community profile
    func uploadProfileImage(
        _ imageData: Data,
        for communityId: UUID
    ) async throws -> ProfileImageResult {
        print("[ProfileImage] ⬆️ Starting profile image upload")
        print("[ProfileImage]    Bucket: \(bucketName)")
        print("[ProfileImage]    Community ID: \(communityId)")
        print("[ProfileImage]    Data size: \(imageData.count) bytes")
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let storagePath = "avatars/\(communityId.uuidString)/\(timestamp).jpg"
        
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
            try await updateCommunityProfile(
                communityId: communityId,
                imageUrl: publicURL.absoluteString,
                imagePath: storagePath
            )
            print("[ProfileImage] ✅ Avatar URL persisted to community table")
            print("[ProfileImage]    image_url: \(publicURL.absoluteString)")
            print("[ProfileImage]    image_path: \(storagePath)")
        } catch {
            print("[ProfileImage] ❌ Failed to persist avatar URL to community table")
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
        for communityId: UUID,
        currentImagePath: String?
    ) async throws {
        print("[ProfileImage] 🗑️ Removing profile image")
        print("[ProfileImage]    Community ID: \(communityId)")
        print("[ProfileImage]    Current path: \(currentImagePath ?? "nil")")
        
        try await updateCommunityProfile(
            communityId: communityId,
            imageUrl: nil,
            imagePath: nil
        )
        
        print("[ProfileImage] ✅ Database fields cleared (image_url, image_path set to nil)")
        
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
    
    // MARK: - Database Update
    
    private func updateCommunityProfile(
        communityId: UUID,
        imageUrl: String?,
        imagePath: String?
    ) async throws {
        struct ImageUpdate: Encodable {
            let image_url: String?
            let image_path: String?
        }
        
        let update = ImageUpdate(
            image_url: imageUrl,
            image_path: imagePath
        )
        
        print("[ProfileImage] 💾 Updating community table for id: \(communityId)")
        print("[ProfileImage]    image_url: \(imageUrl ?? "nil")")
        print("[ProfileImage]    image_path: \(imagePath ?? "nil")")
        
        try await supabase
            .from("community")
            .update(update)
            .eq("id", value: communityId.uuidString)
            .execute()
        
        print("[ProfileImage] ✅ Community profile updated in database")
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
