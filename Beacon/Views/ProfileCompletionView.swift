import SwiftUI

struct ProfileCompletionView: View {
    let profile: User
    let onComplete: () -> Void
    
    @State private var name: String
    @State private var bio: String
    @State private var skillsText: String
    @State private var interestsText: String
    @State private var selectedGoal: String = ""
    @State private var selectedQuickInterests: Set<String> = []
    
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    init(profile: User, onComplete: @escaping () -> Void) {
        self.profile = profile
        self.onComplete = onComplete
        
        // Initialize with existing values
        _name = State(initialValue: profile.name)
        _bio = State(initialValue: profile.bio ?? "")
        _skillsText = State(initialValue: profile.skills?.joined(separator: ", ") ?? "")
        _interestsText = State(initialValue: profile.interests?.joined(separator: ", ") ?? "")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("About You")) {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                }

                Section(header: Text("Optional (30 seconds)")) {
                    Picker("Current event goal", selection: $selectedGoal) {
                        Text("Skip for now").tag("")
                        ForEach(EventContextService.supportedIntents, id: \.self) { intent in
                            Text(intent).tag(intent)
                        }
                    }

                    Text("Or choose a few quick interests:")
                        .font(.subheadline.weight(.medium))

                    FlowLayout(spacing: 8) {
                        ForEach(["AI", "Design", "Founders", "Engineering", "Community", "Investing"], id: \.self) { item in
                            Button(item) {
                                if selectedQuickInterests.contains(item) {
                                    selectedQuickInterests.remove(item)
                                } else {
                                    selectedQuickInterests.insert(item)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(selectedQuickInterests.contains(item) ? .blue : .gray.opacity(0.35))
                        }
                    }

                    Text("Everything else can evolve from your activity over time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: saveProfile) {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(isSaving ? "Saving..." : "Start Nearify")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSaving || !isValid)
                }
            }
            .navigationTitle("You're In")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func saveProfile() {
        guard !isSaving else { return }
        guard isValid else { return }
        
        isSaving = true
        
        Task {
            do {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                let skills = parseCommaSeparated(skillsText)
                let typedInterests = parseCommaSeparated(interestsText)
                let interests = Array(Set(typedInterests).union(selectedQuickInterests)).sorted()
                
                try await ProfileService.shared.updateProfile(
                    profileId: profile.id,
                    name: trimmedName,
                    bio: trimmedBio.isEmpty ? nil : trimmedBio,
                    skills: skills.isEmpty ? nil : skills,
                    interests: interests.isEmpty ? nil : interests
                )

                if !selectedGoal.isEmpty {
                    await MainActor.run {
                        ProfileSignalService.shared.recordGoal(selectedGoal)
                    }
                }
                
                await MainActor.run {
                    isSaving = false
                    onComplete()
                }
                
                print("[ProfileCompletion] ✅ Profile saved successfully")
                
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Failed to save profile: \(error.localizedDescription)"
                    showError = true
                }
                
                print("[ProfileCompletion] ❌ Save failed: \(error)")
            }
        }
    }
    
    private func parseCommaSeparated(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
