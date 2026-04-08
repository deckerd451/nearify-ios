import SwiftUI

/// Lightweight messaging view between connected users.
/// Text only. No attachments. No reactions.
/// Header shows: "You met at {Event Name}"
struct ConversationView: View {
    let targetProfileId: UUID
    
    @ObservedObject private var messaging = MessagingService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var conversation: Conversation?
    @State private var messageText = ""
    @State private var isLoading = true
    @State private var targetName = "..."
    @State private var errorMessage: String?
    
    private var myId: UUID? {
        AuthService.shared.currentUser?.id
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Event context header
                    if let eventName = conversation?.eventName {
                        HStack {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("You met at \(eventName)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.04))
                    }
                    
                    if isLoading {
                        Spacer()
                        ProgressView().tint(.white)
                        Spacer()
                    } else {
                        // Messages
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(messaging.currentMessages) { msg in
                                        messageBubble(msg)
                                            .id(msg.id)
                                    }
                                }
                                .padding()
                            }
                            .onChange(of: messaging.currentMessages.count) { _, _ in
                                if let last = messaging.currentMessages.last {
                                    withAnimation {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                        
                        // Input
                        messageInput
                    }
                }
            }
            .navigationTitle(targetName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white)
                }
            }
            .task {
                await loadConversation()
            }
        }
    }
    
    // MARK: - Message Bubble
    
    private func messageBubble(_ message: Message) -> some View {
        let isMine = message.isMine(myId: myId ?? UUID())
        
        return HStack {
            if isMine { Spacer(minLength: 60) }
            
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isMine ? Color.blue : Color.white.opacity(0.12))
                    )
                
                if let date = message.createdAt {
                    Text(date.feedRelativeString)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            
            if !isMine { Spacer(minLength: 60) }
        }
    }
    
    // MARK: - Input
    
    private var messageInput: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $messageText)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.1))
                )
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.black)
    }
    
    // MARK: - Actions
    
    private func loadConversation() async {
        isLoading = true
        defer { isLoading = false }
        
        // Load target profile name
        if let profile = try? await ProfileService.shared.fetchProfileById(targetProfileId) {
            targetName = profile.name
        }
        
        // Get or create conversation
        let eventId = EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) }
        let eventName = EventJoinService.shared.currentEventName
        
        do {
            let convo = try await messaging.getOrCreateConversation(
                with: targetProfileId,
                eventId: eventId,
                eventName: eventName
            )
            conversation = convo
            await messaging.fetchMessages(conversationId: convo.id)
        } catch {
            errorMessage = error.localizedDescription
            print("[Conversation] ❌ Failed to load: \(error)")
        }
    }
    
    private func sendMessage() {
        guard let convo = conversation else { return }
        let text = messageText
        messageText = ""
        
        Task {
            do {
                try await messaging.sendMessage(conversationId: convo.id, content: text)
            } catch {
                messageText = text // Restore on failure
                print("[Conversation] ❌ Send failed: \(error)")
            }
        }
    }
}
