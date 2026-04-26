import SwiftUI
import Supabase
import PhotosUI
import UIKit

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
    @State private var showProfilePreview = false
    @State private var showFullScreenQR = false
    @State private var showIntelligenceDebug = false

    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var latelyService = DynamicProfileService.shared

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let layout = layoutMetrics(for: proxy)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(layout: layout)
                            .ignoresSafeArea(edges: .top)

                        heroActions(layout: layout)
                            .padding(.top, 14)
                            .padding(.bottom, 22)

                        profileContent(layout: layout)
                    }
                }
                .background(Color.black)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sign Out") {
                        showingSignOutConfirmation = true
                    }
                }
            }
            .sheet(isPresented: $showProfilePreview) {
                NavigationStack {
                    PersonDetailView(attendee: previewAttendee)
                }
            }
            .sheet(isPresented: $showIntelligenceDebug) {
                IntelligenceDebugView()
            }
            .fullScreenCover(isPresented: $showFullScreenQR) {
                if let connectURL, let qrCodeImage {
                    FullScreenQRView(connectURL: connectURL, qrImage: qrCodeImage)
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, newValue in
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
                print("[MyProfileHero] rendered")
                await loadAuthDetails()
                latelyService.refresh()
            }
        }
    }

    private func layoutMetrics(for proxy: GeometryProxy) -> MyProfileLayoutMetrics {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let safeWidth = max(1, proxy.size.width)

        return MyProfileLayoutMetrics(
            heroHeight: isPad ? 320 : 384,
            actionButtonSize: isPad ? 68 : 64,
            contentMaxWidth: isPad ? min(max(1, safeWidth - 48), 800) : .infinity,
            horizontalPadding: isPad ? 24 : 20
        )
    }

    private func heroSection(layout: MyProfileLayoutMetrics) -> some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground

            VStack(alignment: .leading, spacing: 10) {
                Button(action: { showingPhotoOptions = true }) {
                    ZStack(alignment: .bottomTrailing) {
                        avatarView
                            .frame(width: 90, height: 90)

                        Image(systemName: displayUser.imageUrl != nil ? "pencil.circle.fill" : "camera.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .buttonStyle(.plain)
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

                Text(displayUser.name)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.0) {
                        guard AppEnvironment.isDebugMode else { return }
                        showIntelligenceDebug = true
                    }

                if let identity = identityLine {
                    Text(identity)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }

                if !heroTraitsLine.isEmpty {
                    Text(heroTraitsLine)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.bottom, 24)
        }
        .frame(height: layout.heroHeight)
        .clipped()
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let imageUrl = displayUser.imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    fallbackHeroBackground

                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(Color.black.opacity(0.28))
                        .overlay(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.76),
                                    Color.black.opacity(0.2),
                                    .clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .clipped()

                case .failure:
                    fallbackHeroBackground

                @unknown default:
                    fallbackHeroBackground
                }
            }
        } else {
            fallbackHeroBackground
        }
    }

    private var fallbackHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.indigo,
                    Color.blue.opacity(0.75),
                    Color.teal.opacity(0.7)
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )

            Text(initials)
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.25))
        }
        .overlay(Color.black.opacity(0.25))
        .overlay(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.75),
                    .clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    private func heroActions(layout: MyProfileLayoutMetrics) -> some View {
        let spacing: CGFloat = 22
        let padding: CGFloat = layout.horizontalPadding
        let buttonSize: CGFloat = layout.actionButtonSize

        return HStack(spacing: spacing) {
            profileActionButton(
                systemImage: "qrcode",
                title: "QR",
                buttonSize: buttonSize
            ) {
                showFullScreenQR = true
            }
            .disabled(connectURL == nil)

            if let shareURL {
                ShareLink(item: shareURL) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: buttonSize, height: buttonSize)
                            .background(.ultraThinMaterial, in: Circle())

                        Text("Share")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            } else {
                profileActionButton(
                    systemImage: "square.and.arrow.up",
                    title: "Share",
                    buttonSize: buttonSize
                ) {
                    UIPasteboard.general.string = fallbackShareText
                }
                .disabled(true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, padding)
    }

    private func profileActionButton(
        systemImage: String,
        title: String,
        buttonSize: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.ultraThinMaterial, in: Circle())

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func profileContent(layout: MyProfileLayoutMetrics) -> some View {
        VStack(spacing: 18) {
            qrCodeSection

            if !latelyService.latelyLines.isEmpty {
                sectionCard(title: "Lately") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(latelyService.latelyLines, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            if !remainingEarnedTraits.isEmpty {
                sectionCard(title: "Earned Traits") {
                    Text(remainingEarnedTraits.map(\.publicText).joined(separator: " · "))
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }

            if let skills = displayUser.skills, !skills.isEmpty {
                sectionCard(title: "Skills") {
                    tagSection(tags: skills, color: .blue)
                }
            }

            if let interests = displayUser.interests, !interests.isEmpty {
                sectionCard(title: "Interests") {
                    tagSection(tags: interests, color: .green)
                }
            }

            if let bio = displayUser.bio, !bio.isEmpty {
                sectionCard(title: "Bio") {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let paragraph = latelyService.emergingStrengthsParagraph {
                sectionCard(title: "Emerging Strengths") {
                    Text(paragraph)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = uploadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer(minLength: 36)
        }
        .frame(maxWidth: layout.contentMaxWidth)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, DesignTokens.scrollBottomPadding)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var qrCodeSection: some View {
        PersonalConnectQRCard(
            title: "Your Nearify QR",
            subtitle: "Share your profile instantly",
            connectURL: connectURL,
            qrImage: qrCodeImage
        )
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func tagSection(tags: [String], color: Color) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color.opacity(0.12))
                    )
                    .foregroundColor(color)
            }
        }
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

    private var displayUser: User {
        authService.currentUser ?? currentUser
    }

    private var previewAttendee: EventAttendee {
        EventAttendee(
            id: displayUser.id,
            name: displayUser.name,
            avatarUrl: displayUser.imageUrl,
            bio: displayUser.bio,
            skills: displayUser.skills,
            interests: displayUser.interests,
            energy: 1.0,
            lastSeen: Date()
        )
    }

    private var identityLine: String? {
        let top = displayUser.skills?.first
        let second = displayUser.interests?.first

        switch (top, second) {
        case let (lhs?, rhs?):
            return "\(lhs) · \(rhs)"
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        default:
            return nil
        }
    }

    private var heroTraits: [EarnedTrait] {
        Array(latelyService.earnedTraits.prefix(2))
    }

    private var remainingEarnedTraits: [EarnedTrait] {
        Array(latelyService.earnedTraits.dropFirst(heroTraits.count))
    }

    private var heroTraitsLine: String {
        heroTraits.map(\.publicText).joined(separator: " · ")
    }

    private var connectURL: URL? {
        guard let eventId = PersonalQRContextResolver.shared.resolve()?.eventId else {
            return nil
        }

        return QRService.makePersonalConnectWebURL(
            eventId: eventId,
            profileId: displayUser.id
        )
    }

    private var qrCodeImage: UIImage? {
        guard let connectURL else { return nil }
        return QRService.generateQRCode(from: connectURL.absoluteString)
    }

    private var shareURL: URL? {
        connectURL
    }

    private var fallbackShareText: String {
        "Connect with me on Nearify: \(displayUser.name)"
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        print("[EditProfilePhoto] 📤 uploadPhoto() called")
        print("[EditProfilePhoto]    User ID: \(displayUser.id)")

        await MainActor.run {
            isUploadingPhoto = true
            uploadError = nil
        }

        do {
            print("[EditProfilePhoto] 📥 Loading raw image data from picker...")

            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                print("[EditProfilePhoto] ❌ Failed to load transferable data")
                throw ProfileImageError.failedToLoadImage
            }

            print("[EditProfilePhoto] ✅ Raw data loaded: \(rawData.count) bytes")
            print("[EditProfilePhoto] 🔄 Processing image...")

            let processedData = try ProfileImageService.shared.processImageData(rawData)

            print("[EditProfilePhoto] ✅ Image processed: \(processedData.count) bytes")
            print("[EditProfilePhoto] ⬆️ Uploading to storage...")

            let result = try await ProfileImageService.shared.uploadProfileImage(
                processedData,
                for: displayUser.id
            )

            print("[EditProfilePhoto] ✅ Upload successful!")
            print("[EditProfilePhoto]    Image URL: \(result.imageUrl)")
            print("[EditProfilePhoto]    Image Path: \(result.imagePath)")
            print("[EditProfilePhoto] 🔄 Refreshing profile...")

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

        await MainActor.run {
            isUploadingPhoto = true
            uploadError = nil
        }

        do {
            print("[EditProfilePhoto] 🔄 Calling removeProfileImage service...")

            try await ProfileImageService.shared.removeProfileImage(
                for: displayUser.id,
                currentImagePath: displayUser.imagePath
            )

            print("[EditProfilePhoto] ✅ Remove successful!")
            print("[EditProfilePhoto] 🔄 Refreshing profile...")

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

private struct FullScreenQRView: View {
    let connectURL: URL
    let qrImage: UIImage

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Nearify QR")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Share your profile instantly")
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack {
                        Spacer(minLength: 0)

                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 300, height: 300)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.white)
                            )

                        Spacer(minLength: 0)
                    }

                    Text(connectURL.absoluteString)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = connectURL.absoluteString
                            didCopy = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                didCopy = false
                            }
                        } label: {
                            Label(
                                didCopy ? "Copied" : "Copy Link",
                                systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                            .font(.caption)
                            .fontWeight(.semibold)
                        }
                        .buttonStyle(.bordered)

                        ShareLink(item: connectURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct MyProfileLayoutMetrics {
    let heroHeight: CGFloat
    let actionButtonSize: CGFloat
    let contentMaxWidth: CGFloat
    let horizontalPadding: CGFloat
}

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
