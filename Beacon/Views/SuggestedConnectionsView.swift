import SwiftUI

struct SuggestedConnectionsView: View {
    @State private var suggestions: [SuggestedConnection] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var currentProfileId: UUID?

    private let service = SuggestedConnectionsService.shared

    var body: some View {
        VStack(spacing: 0) {
            generateButton

            if isLoading {
                ProgressView("Loading suggestions...")
                    .padding()
            } else if suggestions.isEmpty {
                emptyState
            } else {
                suggestionsList
            }
        }
        .navigationTitle("Suggested Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await resolveProfileId()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let error = errorMessage { Text(error) }
        }
    }

    // MARK: - Components

    private var generateButton: some View {
        Button {
            Task { await generateSuggestions() }
        } label: {
            HStack {
                if isGenerating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isGenerating ? "Generating..." : "Generate Suggestions")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(isGenerating || currentProfileId == nil)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Suggestions Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Tap 'Generate Suggestions' to find people you shared an event with.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxHeight: .infinity)
    }

    private var suggestionsList: some View {
        List {
            ForEach(suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion) { action in
                    await handleAction(action, for: suggestion)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    private func resolveProfileId() async {
        do {
            currentProfileId = try await service.resolveCurrentUserCommunityId()
        } catch {
            errorMessage = "Failed to resolve user ID: \(error.localizedDescription)"
        }
    }

    private func generateSuggestions() async {
        isGenerating = true
        errorMessage = nil

        do {
            let count = try await service.generateSuggestions(
                groupId: nil,
                minOverlapSeconds: 120,
                lookbackMinutes: 240
            )

            if let profileId = currentProfileId {
                suggestions = try await service.fetchSuggestions(for: profileId)
            }

            if count == 0 {
                errorMessage = "No suggestions found. Join an event first and make sure others are attending too."
            }
        } catch {
            errorMessage = "Failed to generate suggestions: \(error.localizedDescription)"
        }

        isGenerating = false
    }

    private func handleAction(_ action: SuggestionAction, for suggestion: SuggestedConnection) async {
        do {
            switch action {
            case .accept:
                try await service.acceptSuggestion(profileId: suggestion.otherUserId)
            case .ignore:
                service.ignoreSuggestion(profileId: suggestion.otherUserId)
            }
            suggestions.removeAll { $0.id == suggestion.id }
        } catch {
            errorMessage = "Action failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SuggestionRow

struct SuggestionRow: View {
    let suggestion: SuggestedConnection
    let onAction: (SuggestionAction) async -> Void

    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Text(suggestion.displayName.prefix(2).uppercased())
                            .font(.headline)
                            .foregroundColor(.blue)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.displayName)
                        .font(.headline)

                    HStack(spacing: 12) {
                        Label(
                            suggestion.sharedEvents == 1 ? "1 shared event" : "\(suggestion.sharedEvents) shared events",
                            systemImage: "calendar"
                        )
                        Label(suggestion.lastSeenAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()
            }

            if !isProcessing {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            isProcessing = true
                            await onAction(.accept)
                            isProcessing = false
                        }
                    } label: {
                        Label("Connect", systemImage: "person.badge.plus")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.1))
                            .foregroundColor(.green)
                            .cornerRadius(8)
                    }

                    Button {
                        Task {
                            isProcessing = true
                            await onAction(.ignore)
                            isProcessing = false
                        }
                    } label: {
                        Label("Ignore", systemImage: "xmark.circle")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.1))
                            .foregroundColor(.gray)
                            .cornerRadius(8)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }
}

enum SuggestionAction {
    case accept
    case ignore
}
