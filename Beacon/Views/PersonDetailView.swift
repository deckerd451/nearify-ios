import SwiftUI

/// Lightweight person detail screen shown when tapping an attendee
struct PersonDetailView: View {
    let attendee: EventAttendee
    
    @State private var showingFindSheet = false
    @State private var showContactSaveSheet = false
    @State private var showSavedConfirmation = false
    @State private var publicProfile: PublicProfileSummary?

    @ObservedObject private var encounterService = EncounterService.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Avatar
                AvatarView(
                    imageUrl: attendee.avatarUrl,
                    name: attendee.name,
                    size: 100
                )
                .padding(.top, 24)
                
                // Bio
                if let bio = attendee.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Skills
                if let skills = attendee.skills, !skills.isEmpty {
                    tagSection(title: "Skills", tags: skills, color: .blue)
                }
                
                // Interests
                if let interests = attendee.interests, !interests.isEmpty {
                    tagSection(title: "Interests", tags: interests, color: .green)
                }

                // Lately
                if let pub = publicProfile, !pub.latelyLines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lately")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pub.latelyLines, id: \.self) { line in
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }

                // Emerging Strengths
                if let paragraph = publicProfile?.emergingStrengthsParagraph {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Emerging Strengths")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        Text(paragraph)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }

                // Earned Traits
                if let pub = publicProfile, !pub.earnedTraits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Earned Traits")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pub.earnedTraits) { trait in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Text(trait.publicText)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }
                
                // Status
                HStack(spacing: 8) {
                    Circle()
                        .fill(attendee.isActiveNow ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(attendee.lastSeenText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
                
                Button(action: { showContactSaveSheet = true }) {
                    Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)

                // Find Person button
                Button(action: { showingFindSheet = true }) {
                    Label("Find Person", systemImage: "location.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
                
                if meaningfulEncounterDuration >= 120 {
                    Text("Meaningful encounter unlocked — save to contacts while context is fresh")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 32)
                }

                Spacer(minLength: 40)
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedConfirmation {
                Text("Saved to your contacts with context from Nearify")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.green))
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .navigationTitle(attendee.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFindSheet) {
            FindAttendeeView(attendee: attendee)
        }
        .sheet(isPresented: $showContactSaveSheet) {
            ContactSaveSheet(draft: contactDraft) { didSave in
                showContactSaveSheet = false
                guard didSave else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSavedConfirmation = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSavedConfirmation = false
                    }
                }
            }
        }
        .task {
            // Build a lightweight User for the generation method
            let targetUser = User(
                id: attendee.id,
                userId: nil,
                name: attendee.name,
                email: nil,
                bio: attendee.bio,
                skills: attendee.skills,
                interests: attendee.interests,
                imageUrl: attendee.avatarUrl,
                imagePath: nil,
                profileCompleted: nil,
                connectionCount: nil,
                createdAt: nil,
                updatedAt: nil
            )
            publicProfile = await DynamicProfileService.shared.generatePublicProfile(
                for: attendee.id,
                targetUser: targetUser
            )
        }
    }
    
    private var meaningfulEncounterDuration: Int {
        encounterService.activeEncounters[attendee.id]?.totalSeconds ?? 0
    }

    private var contactDraft: ContactDraftData {
        ContactDraftData(
            name: attendee.name,
            eventName: EventJoinService.shared.currentEventName ?? "Nearify event",
            interests: attendee.interests ?? [],
            skills: attendee.skills ?? [],
            earnedTraits: publicProfile?.earnedTraits.map(\.publicText) ?? []
        )
    }

    // MARK: - Tag Section
    
    private func tagSection(title: String, tags: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(color.opacity(0.1))
                        )
                        .foregroundColor(color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
    }
}
