import SwiftUI

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authService = AuthService.shared
    
    let currentUser: User
    
    @State private var name: String
    @State private var bio: String
    @State private var skillsText: String
    @State private var interestsText: String
    @State private var shareEmail: Bool
    @State private var publicEmail: String
    @State private var sharePhone: Bool
    @State private var publicPhone: String
    @State private var linkedInUrl: String
    @State private var websiteUrl: String
    @State private var preferredContactMethod: String
    
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingSuccess = false
    
    init(currentUser: User) {
        self.currentUser = currentUser
        _name = State(initialValue: currentUser.name)
        _bio = State(initialValue: currentUser.bio ?? "")
        _skillsText = State(initialValue: currentUser.skills?.joined(separator: ", ") ?? "")
        _interestsText = State(initialValue: currentUser.interests?.joined(separator: ", ") ?? "")
        _shareEmail = State(initialValue: currentUser.shareEmail ?? false)
        _publicEmail = State(initialValue: currentUser.publicEmail ?? "")
        _sharePhone = State(initialValue: currentUser.sharePhone ?? false)
        _publicPhone = State(initialValue: currentUser.publicPhone ?? "")
        _linkedInUrl = State(initialValue: currentUser.linkedInUrl ?? "")
        _websiteUrl = State(initialValue: currentUser.websiteUrl ?? "")
        _preferredContactMethod = State(initialValue: currentUser.preferredContactMethod ?? "nearify")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Basic Info")) {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section(header: Text("Skills"), footer: Text("Separate with commas")) {
                    TextField("e.g. Swift, React, Design", text: $skillsText, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section(header: Text("Interests"), footer: Text("Separate with commas")) {
                    TextField("e.g. Music, Art, Technology", text: $interestsText, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section(
                    header: Text("Preferred Contact Info"),
                    footer: Text("Choose what others receive when they save your contact.")
                ) {
                    Toggle("Share Email", isOn: $shareEmail)
                    if shareEmail {
                        TextField("Public email", text: $publicEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }

                    Toggle("Share Phone", isOn: $sharePhone)
                    if sharePhone {
                        TextField("Public phone", text: $publicPhone)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                    }

                    TextField("LinkedIn URL", text: $linkedInUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Website URL", text: $websiteUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    Picker("Preferred Contact Method", selection: $preferredContactMethod) {
                        ForEach(contactMethodOptions, id: \.self) { method in
                            Text(contactMethodLabel(method)).tag(method)
                        }
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        Task {
                            await saveProfile()
                        }
                    }
                    .disabled(isSaving || name.isEmpty)
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView("Saving...")
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemBackground))
                                .shadow(radius: 8)
                        )
                }
            }
            .alert("Profile Updated", isPresented: $showingSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your profile has been updated successfully.")
            }
        }
    }
    
    // MARK: - Save Profile
    
    private func saveProfile() async {
        guard !name.isEmpty else {
            errorMessage = "Name is required"
            return
        }
        
        isSaving = true
        errorMessage = nil
        
        do {
            // Parse skills and interests
            let skills = parseCommaSeparated(skillsText)
            let interests = parseCommaSeparated(interestsText)
            
            // Update profile
            try await ProfileService.shared.updateProfile(
                profileId: currentUser.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                bio: bio.isEmpty ? nil : bio.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: skills.isEmpty ? nil : skills,
                interests: interests.isEmpty ? nil : interests,
                publicEmail: sanitizedContactField(publicEmail),
                publicPhone: sanitizedContactField(publicPhone),
                linkedInUrl: sanitizedContactField(linkedInUrl),
                websiteUrl: sanitizedContactField(websiteUrl),
                shareEmail: shareEmail,
                sharePhone: sharePhone,
                preferredContactMethod: preferredContactMethod
            )
            
            // Refresh auth service to reload profile
            await authService.refreshProfile()
            
            await MainActor.run {
                isSaving = false
                showingSuccess = true
            }
            
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Helpers
    
    private func parseCommaSeparated(_ text: String) -> [String] {
        text
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var contactMethodOptions: [String] {
        ["nearify", "email", "phone", "linkedin"]
    }

    private func contactMethodLabel(_ method: String) -> String {
        switch method {
        case "email": return "Email"
        case "phone": return "Phone"
        case "linkedin": return "LinkedIn"
        default: return "Nearify"
        }
    }

    private func sanitizedContactField(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    EditProfileView(currentUser: User(
        id: UUID(),
        userId: UUID(),
        name: "Doug Hamilton",
        email: "doug@example.com",
        bio: "Human centered design • AI • Founder",
        skills: ["Swift", "Product Design", "AI"],
        interests: ["Technology", "Design", "Innovation"],
        imageUrl: nil,
        imagePath: nil,
        profileCompleted: true,
        connectionCount: 5,
        createdAt: Date(),
        updatedAt: Date()
    ))
}
