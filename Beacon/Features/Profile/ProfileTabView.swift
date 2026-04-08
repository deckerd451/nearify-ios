import SwiftUI

/// Profile tab — shows the user's profile with edit capability.
/// Replaces the old Diagnostics tab in the navigation.
struct ProfileTabView: View {
    let currentUser: User
    
    @ObservedObject private var authService = AuthService.shared
    @State private var showEditProfile = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Avatar
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Text(String(currentUser.name.prefix(1)).uppercased())
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.blue)
                            )
                            .padding(.top, 24)
                        
                        // Name + email
                        VStack(spacing: 4) {
                            Text(currentUser.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            if let email = currentUser.email {
                                Text(email)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        // Bio
                        if let bio = currentUser.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        
                        // Tags
                        if let interests = currentUser.interests, !interests.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(interests, id: \.self) { interest in
                                    Text(interest)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.white.opacity(0.1))
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        if let skills = currentUser.skills, !skills.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(skills, id: \.self) { skill in
                                    Text(skill)
                                        .font(.caption)
                                        .foregroundColor(.blue.opacity(0.9))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // Stats
                        if let count = currentUser.connectionCount, count > 0 {
                            HStack {
                                Image(systemName: "person.2")
                                    .foregroundColor(.gray)
                                Text("\(count) connections")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        // Edit button
                        Button(action: { showEditProfile = true }) {
                            HStack {
                                Image(systemName: "pencil")
                                Text("Edit Profile")
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                        
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.horizontal)
                        
                        // Sign out
                        Button(action: signOut) {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Sign Out")
                            }
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showEditProfile) {
                EditProfileView(currentUser: currentUser)
            }
        }
    }
    
    private func signOut() {
        Task {
            try? await authService.signOut()
        }
    }
}
