import SwiftUI
import Supabase
import PhotosUI

struct MyQRView: View {
    let currentUser: User
    @State private var showingSignOutConfirmation = false
    @State private var showingEditProfile = false
    @State private var showingPhotoOptions = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var uploadError: String?
    @State private var authUserId: String?
    @State private var authProvider: String?
    
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var latelyService = DynamicProfileService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared

    @State private var showIntelligenceDebug = false
    @State private var showActivityDetail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignTokens.sectionSpacing) {
                    // ── 1. IDENTITY ──
                    identitySection

                    // ── 2. CONNECTION TOOLS ──
                    qrCodeSection

                    // ── 3. CREDIBILITY / BACKGROUND ──
                    if hasSkillsOrInterests {
                        attributesSection
                    }

                    // ── 4. ACTIVITY INSIGHT (collapsed) ──
                    if hasActivityInsight {
                        activityInsightSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, DesignTokens.titleToContent)
                .padding(.bottom, DesignTokens.scrollBottomPadding)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sign Out") {
                        showingSignOutConfirmation = true
                    }
                }
            }
            .sheet(isPresented: $showIntelligenceDebug) {
                IntelligenceDebugView()
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { oldValue, newValue in
                if let newValue {
                    Task { await uploadPhoto(newValue) }
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileView(currentUser: displayUser)
            }
            .confirmationDialog("Sign Out", isPresented: $showingSignOutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    Task { try? await AuthService.shared.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out?")
            }
            .task {
                await loadAuthDetails()
                latelyService.refresh()
            }
        }
    }

    // MARK: - 1. Identity Section

    private var identitySection: some View {
        VStack(spacing: DesignTokens.sectionHeaderToContent) {
            Button(action: { showingPhotoOptions = true }) {
                ZStack(alignment: .bottomTrailing) {
                    avatarView.frame(width: 100, height: 100)
                    Image(systemName: displayUser.imageUrl != nil ? "pencil.circle.fill" : "camera.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .background(Circle().fill(Color.white))
                }
            }
            .disabled(isUploadingPhoto)
            .confirmationDialog("Profile Photo", isPresented: $showingPhotoOptions) {
                Button(displayUser.imageUrl != nil ? "Change Photo" : "Add Photo") {
                    showingPhotoPicker = true
                }
                if displayUser.imageUrl != nil {
                    Button("Remove Photo", role: .destructive) {
                        Task { await removePhoto() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }

            if isUploadingPhoto {
                ProgressView("Uploading…").font(.caption)
            } else if let error = uploadError {
                Text(error).font(.caption).foregroundColor(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            Text(displayUser.name)
                .font(.title2).fontWeight(.bold)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) {
                    guard AppEnvironment.isDebugMode else { return }
                    showIntelligenceDebug = true
                }

            if let bio = displayUser.bio, !bio.isEmpty {
                Text(bio).font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            Button(action: { showingEditProfile = true }) {
                Label("Edit Profile", systemImage: "pencil")
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.blue)
            }
        }
    }

    // MARK: - 2. QR Code Section

    private var qrCodeSection: some View {
        PersonalConnectQRCard(
            title: "Connect with me",
            subtitle: "Anyone can scan this to connect with you instantly — even without the app.",
            eventId: resolvedPersonalQREventId,
            profileId: displayUser.id
        )
    }

    private var resolvedPersonalQREventId: UUID? {
        if let currentEventID = eventJoin.currentEventID,
           let eventUUID = UUID(uuidString: currentEventID) {
            return eventUUID
        }

        if let reconnectEventId = eventJoin.reconnectContext?.eventId,
           let reconnectUUID = UUID(uuidString: reconnectEventId) {
            return reconnectUUID
        }

        return nil
    }

    // MARK: - 3. Attributes (Skills + Interests)

    private var hasSkillsOrInterests: Bool {
        !(displayUser.skills ?? []).isEmpty || !(displayUser.interests ?? []).isEmpty
    }

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.elementSpacing) {
            if let skills = displayUser.skills, !skills.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skills").font(.caption).foregroundColor(.secondary).textCase(.uppercase)
                    FlowLayout(spacing: 6) {
                        ForEach(skills.prefix(6), id: \.self) { skill in
                            Text(skill).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.1)))
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            if let interests = displayUser.interests, !interests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Interests").font(.caption).foregroundColor(.secondary).textCase(.uppercase)
                    FlowLayout(spacing: 6) {
                        ForEach(interests.prefix(6), id: \.self) { interest in
                            Text(interest).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 4. Activity Insight (Collapsed)

    private var hasActivityInsight: Bool {
        !latelyService.latelyLines.isEmpty
        || latelyService.emergingStrengthsParagraph != nil
        || !latelyService.earnedTraits.isEmpty
    }

    private var activitySummaryLine: String {
        if let first = latelyService.latelyLines.first { return first }
        if let p = latelyService.emergingStrengthsParagraph { return String(p.prefix(80)) }
        if let t = latelyService.earnedTraits.first { return t.publicText }
        return "Your recent activity"
    }

    private var activityInsightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activitySummaryLine)
                .font(.caption).foregroundColor(.secondary).lineLimit(2)

            DisclosureGroup("Your activity", isExpanded: $showActivityDetail) {
                VStack(alignment: .leading, spacing: 12) {
                    if !latelyService.latelyLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lately").font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                            ForEach(latelyService.latelyLines, id: \.self) { line in
                                Text(line).font(.caption).foregroundColor(.primary)
                            }
                        }
                    }
                    if let paragraph = latelyService.emergingStrengthsParagraph {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Emerging Strengths").font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                            Text(paragraph).font(.caption).foregroundColor(.primary)
                        }
                    }
                    if !latelyService.earnedTraits.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Earned Traits").font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                            ForEach(latelyService.earnedTraits) { trait in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundColor(.green)
                                    Text(trait.publicText).font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    private var avatarView: some View {
        Group {
            if let imageUrl = displayUser.imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 100, height: 100)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                    case .failure:
                        initialsPlaceholder
                    @unknown default:
                        initialsPlaceholder
                    }
                }
            } else {
                initialsPlaceholder
            }
        }
    }
    
    private var initialsPlaceholder: some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(initials)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            )
    }
    
    private var initials: String {
        let components = displayUser.name.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[1].prefix(1)
            return "\(first)\(last)".uppercased()
        } else {
            return String(displayUser.name.prefix(2)).uppercased()
        }
    }
    
    /// Use the latest user from AuthService if available, otherwise use passed-in user
    private var displayUser: User {
        authService.currentUser ?? currentUser
    }
    
    // MARK: - Photo Management
    
    private func uploadPhoto(_ item: PhotosPickerItem) async {
        print("[EditProfilePhoto] 📤 uploadPhoto() called")
        print("[EditProfilePhoto]    User ID: \(displayUser.id)")
        
        isUploadingPhoto = true
        uploadError = nil
        
        do {
            print("[EditProfilePhoto] 📥 Loading raw image data from picker...")
            
            // Load raw image data from picker
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                print("[EditProfilePhoto] ❌ Failed to load transferable data")
                throw ProfileImageError.failedToLoadImage
            }
            
            print("[EditProfilePhoto] ✅ Raw data loaded: \(rawData.count) bytes")
            print("[EditProfilePhoto] 🔄 Processing image...")
            
            // Process image (resize and compress)
            let processedData = try ProfileImageService.shared.processImageData(rawData)
            
            print("[EditProfilePhoto] ✅ Image processed: \(processedData.count) bytes")
            print("[EditProfilePhoto] ⬆️ Uploading to storage...")
            
            // Upload to storage
            let result = try await ProfileImageService.shared.uploadProfileImage(
                processedData,
                for: displayUser.id
            )
            
            print("[EditProfilePhoto] ✅ Upload successful!")
            print("[EditProfilePhoto]    Image URL: \(result.imageUrl)")
            print("[EditProfilePhoto]    Image Path: \(result.imagePath)")
            print("[EditProfilePhoto] 🔄 Refreshing profile...")
            
            // Refresh profile
            await authService.refreshProfile()
            
            print("[EditProfilePhoto] ✅ Profile refresh complete")
            
            await MainActor.run {
                isUploadingPhoto = false
                selectedPhotoItem = nil
                print("[EditProfilePhoto] ✅ Upload flow complete - UI updated")
            }
            
        } catch {
            print("[EditProfilePhoto] ❌ Upload error: \(error)")
            print("[EditProfilePhoto]    Error type: \(type(of: error))")
            print("[EditProfilePhoto]    Error description: \(error.localizedDescription)")
            
            await MainActor.run {
                isUploadingPhoto = false
                uploadError = "Failed to upload: \(error.localizedDescription)"
                selectedPhotoItem = nil
            }
        }
    }
    
    private func removePhoto() async {
        print("[EditProfilePhoto] 🗑️ removePhoto() called")
        print("[EditProfilePhoto]    User ID: \(displayUser.id)")
        print("[EditProfilePhoto]    Current imagePath: \(displayUser.imagePath ?? "nil")")
        
        isUploadingPhoto = true
        uploadError = nil
        
        do {
            print("[EditProfilePhoto] 🔄 Calling removeProfileImage service...")
            
            try await ProfileImageService.shared.removeProfileImage(
                for: displayUser.id,
                currentImagePath: displayUser.imagePath
            )
            
            print("[EditProfilePhoto] ✅ Remove successful!")
            print("[EditProfilePhoto] 🔄 Refreshing profile...")
            
            // Refresh profile
            await authService.refreshProfile()
            
            print("[EditProfilePhoto] ✅ Profile refresh complete")
            
            await MainActor.run {
                isUploadingPhoto = false
                print("[EditProfilePhoto] ✅ Remove flow complete - UI updated")
            }
            
        } catch {
            print("[EditProfilePhoto] ❌ Remove error: \(error)")
            print("[EditProfilePhoto]    Error type: \(type(of: error))")
            print("[EditProfilePhoto]    Error description: \(error.localizedDescription)")
            
            await MainActor.run {
                isUploadingPhoto = false
                uploadError = "Failed to remove: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Helpers
    
    private func loadAuthDetails() async {
        do {
            let supabase = AppEnvironment.shared.supabaseClient
            let session = try await supabase.auth.session
            
            await MainActor.run {
                authUserId = session.user.id.uuidString
                
                if let provider = session.user.appMetadata["provider"]?.stringValue {
                    authProvider = provider
                } else if case let .array(values)? = session.user.appMetadata["providers"] {
                    let providers = values.compactMap { $0.stringValue }
                    if let first = providers.first {
                        authProvider = first
                    }
                }
            }
        } catch {
            print("Failed to load auth details: \(error)")
        }
    }
}

// MARK: - Info Row Component

struct InfoRow: View {
    let label: String
    let value: String
    var monospace: Bool = false
    var valueColor: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(monospace ? .system(.caption, design: .monospaced) : .caption)
                .foregroundColor(valueColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
