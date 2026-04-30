import SwiftUI

struct ProfileView: View {
    let profile: User
    @Environment(\.dismiss) private var dismiss
    
    @State private var isCreatingConnection = false
    @State private var connectionCreated = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccessBanner = false
    @State private var successMessage = ""
    @State private var showFindMode = false
    @State private var showContactSaveSheet = false
    
    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 24) {
                        // Profile Header
                        VStack(spacing: 16) {
                            // Avatar placeholder
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Text(String(profile.name.prefix(1)))
                                        .font(.system(size: 40))
                                        .fontWeight(.bold)
                                        .foregroundColor(.blue)
                                )
                            
                            Text(profile.name)
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            if let publicEmail = sanitizedContactValue(profile.publicEmail), profile.shareEmail == true {
                                Text(publicEmail)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 32)
                        
                        Divider()
                            .padding(.horizontal)
                        
                        // Action Buttons
                        VStack(spacing: 16) {
                            if connectionCreated {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("You're connected")
                                        .fontWeight(.semibold)
                                }
                                .font(.headline)
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(12)
                            } else {
                                Button(action: createConnection) {
                                    HStack {
                                        if isCreatingConnection {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "person.badge.plus")
                                            Text("Connect")
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(isCreatingConnection)
                            }
                            
                            if connectionCreated {
                                Button(action: {
                                    print("[ContactShare] save enabled via connection")
                                    print("[ContactShare] restricted to public contact fields")
                                    showContactSaveSheet = true
                                }) {
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.plus")
                                    Text("Save Contact")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            }

                            // Find button
                            Button(action: openFindMode) {
                                HStack {
                                    Image(systemName: "location.fill")
                                    Text("Find")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal)
                        
                        Spacer()
                    }
                }
                
                // Success banner
                if showSuccessBanner {
                    VStack {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                            
                            Text(successMessage)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                            
                            Spacer()
                        }
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                        .shadow(radius: 4)
                        .padding()
                        
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showSuccessBanner)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showFindMode) {
                FindAttendeeView(attendee: profileToAttendee())
            }
            .task(id: profile.imageUrl) {
                await prefetchContactAvatarIfNeeded()
            }
            .sheet(isPresented: $showContactSaveSheet) {
                ContactSaveSheet(draft: profileContactDraft) { didSave in
                    showContactSaveSheet = false
                    guard didSave else { return }
                    let eventName = EventJoinService.shared.currentEventName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saveMessage = eventName.flatMap { $0.isEmpty ? nil : $0 }
                        .map { "Saved with context from \($0)" } ?? "Saved with Nearify context"
                    showSuccessBanner(message: saveMessage)
                }
            }
        }
    }
    

    private var profileContactDraft: ContactDraftData {
        let avatarImageData = ContactAvatarResolver.cachedImageData(avatarUrl: profile.imageUrl)
        let sanitizedPublicPhone = sanitizedContactValue(profile.publicPhone)
        let sanitizedPublicEmail = sanitizedContactValue(profile.publicEmail)
        let sanitizedLinkedIn = sanitizedContactValue(profile.linkedInUrl)
        let sanitizedWebsite = sanitizedContactValue(profile.websiteUrl)

        return ContactDraftData(
            name: profile.name,
            nearifyProfileIdentifier: profile.id,
            eventName: EventJoinService.shared.currentEventName,
            imageData: avatarImageData,
            phoneNumbers: (profile.sharePhone == true ? [sanitizedPublicPhone].compactMap { $0 } : []),
            emailAddresses: (profile.shareEmail == true ? [sanitizedPublicEmail].compactMap { $0 } : []),
            linkedInUrl: sanitizedLinkedIn,
            websiteUrl: sanitizedWebsite,
            socialProfiles: [],
            interactionLine: nil as String?,
            memoryCues: Array(((profile.interests ?? []) + (profile.skills ?? [])).prefix(2)),
            followUpLine: nil
        )
    }

    private func prefetchContactAvatarIfNeeded() async {
        guard let avatarUrl = profile.imageUrl,
              ThumbnailCache.shared.thumbnail(for: avatarUrl) == nil else {
            return
        }
        _ = await ThumbnailCache.shared.loadThumbnail(for: avatarUrl)
    }

    private func createConnection() {
        guard !isCreatingConnection else { return }
        
        isCreatingConnection = true
        
        Task {
            do {
                try await ConnectionService.shared.createConnection(to: profile.id.uuidString)
                
                await MainActor.run {
                    isCreatingConnection = false
                    connectionCreated = true
                    showSuccessBanner(message: "Connected with \(profile.name)")
                }
                
                print("[Profile] ✅ Connection created to: \(profile.name)")
                
            } catch {
                let errorDescription = error.localizedDescription
                
                // Check if this is a duplicate connection error
                if errorDescription.contains("unique_connection_from_to") ||
                    errorDescription.contains("duplicate key") {
                    // Treat duplicate as success - already connected
                    await MainActor.run {
                        isCreatingConnection = false
                        connectionCreated = true
                        showSuccessBanner(message: "Already connected with \(profile.name)")
                    }
                    
                    print("[Profile] ℹ️ Duplicate connection detected (already connected): \(profile.name)")
                    
                } else {
                    // Actual error - show error message
                    await MainActor.run {
                        isCreatingConnection = false
                        errorMessage = "Failed to create connection: \(errorDescription)"
                        showError = true
                    }
                    
                    print("[Profile] ❌ Connection failed: \(error)")
                }
            }
        }
    }
    
    private func showSuccessBanner(message: String) {
        successMessage = message
        showSuccessBanner = true
        
        // Hide banner after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showSuccessBanner = false
        }
    }
    
    private func openFindMode() {
        print("[Profile] 📍 Opening Find Mode for: \(profile.name)")
        showFindMode = true
    }

    private func sanitizedContactValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lowered = trimmed.lowercased()
        let placeholders = ["n/a", "na", "none", "null", "-", "--", "tbd"]
        return placeholders.contains(lowered) ? nil : trimmed
    }
    
    /// Converts the User profile to an EventAttendee for Find Mode.
    /// Uses lightweight mapping since we don't have full attendee data from QR scan.
    private func profileToAttendee() -> EventAttendee {
        EventAttendee(
            id: profile.id,
            name: profile.name,
            avatarUrl: nil,
            bio: nil,
            skills: [],
            interests: [],
            energy: 1.0,
            lastSeen: Date()
        )
    }
}
