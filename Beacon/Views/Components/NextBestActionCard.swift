import SwiftUI

/// Adaptive "Next Best Action" card for the Home screen.
///
/// Computes the single highest-priority contextual action from live service
/// state and renders a compact, tappable card. Returns EmptyView when nothing
/// clears the caller-supplied priority threshold — callers tune the threshold
/// to suppress actions the surrounding UI already surfaces.
///
/// Action routing is handled entirely by the caller via `onAction`.
/// This view only decides WHAT action to show, not how to navigate to it.
struct NextBestActionCard: View {

    // MARK: - Public interface

    /// Minimum priority for an action to surface. Callers set this based on
    /// what the surrounding UI already shows:
    ///   0.35 — empty state: surface anything useful
    ///   0.95 — attendee list visible: only surface unread messages
    var minPriority: Double = 0.35

    enum Action {
        case openMessages
        case findAttendee(EventAttendee)
        case showBrief
        case showGoalPicker
        case goToPeople
    }

    var onAction: (Action) -> Void

    // MARK: - Observed state (all pre-existing singletons)

    @ObservedObject private var messaging = MessagingService.shared
    @ObservedObject private var memory = RelationshipMemoryService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var attendeesService = EventAttendeesService.shared
    @ObservedObject private var briefController = BriefHydrationController.shared

    // MARK: - Internal display model

    private struct DisplayAction {
        let headline: String
        let subtitle: String?
        let ctaLabel: String
        let icon: String
        let accentColor: Color
        let action: Action
        let priority: Double
    }

    // MARK: - Priority computation

    private var topDisplayAction: DisplayAction? {
        var candidates: [DisplayAction] = []

        // ── 1. Unread messages ──────────────────────────────────────────
        // Highest urgency: the user has something waiting for them.
        let unread = messaging.totalUnreadCount
        if unread > 0 {
            candidates.append(DisplayAction(
                headline: unread == 1
                    ? "You have a new message"
                    : "You have \(unread) unread messages",
                subtitle: nil,
                ctaLabel: "Reply",
                icon: "bubble.left.fill",
                accentColor: VisualStyle.primaryAction,
                action: .openMessages,
                priority: 1.0
            ))
        }

        // ── 2. Top person from brief — live (checked in) ────────────────
        // Named recommendation is more specific than "Who to Talk To".
        if eventJoin.isCheckedIn,
           let topPerson = briefController.currentBrief?.priorityPeople.first {
            let matchedAttendee = attendeesService.attendees.first { $0.id == topPerson.id }
            let isLocatable = matchedAttendee != nil || topPerson.isNearby == true
            let displayName = topPerson.name
            #if DEBUG
            print("[IdentityRenderPath] using normalized displayName source=RecommendationCard person=\(displayName)")
            #endif
            let score = topPerson.matchScore ?? 0.5
            let headline: String
            if score >= 0.75 {
                headline = "You might enjoy talking with \(displayName)"
            } else if score >= 0.45 {
                headline = "You might enjoy talking with \(displayName)"
            } else {
                headline = "You might enjoy meeting \(displayName)"
            }
            candidates.append(DisplayAction(
                headline: headline,
                subtitle: topPerson.reason.isEmpty ? nil : topPerson.reason,
                ctaLabel: isLocatable && matchedAttendee != nil ? "Walk over" : "Who's here",
                icon: "sparkles",
                accentColor: VisualStyle.intelligence,
                action: isLocatable && matchedAttendee != nil
                    ? .findAttendee(matchedAttendee!)
                    : .showBrief,
                priority: 0.85
            ))
        }

        // ── 3. Top person from brief — pre-event (joined, not checked in) ─
        // Shows a warm teaser before the user arrives.
        if eventJoin.isEventJoined, !eventJoin.isCheckedIn,
           let topPerson = briefController.currentBrief?.priorityPeople.first {
            let displayName = topPerson.name
            #if DEBUG
            print("[IdentityRenderPath] using normalized displayName source=RecommendationCard.preEvent person=\(displayName)")
            #endif
            let score = topPerson.matchScore ?? 0.5
            let headline = score >= 0.65
                ? "You might enjoy meeting \(displayName)"
                : "You might enjoy meeting \(displayName)"
            candidates.append(DisplayAction(
                headline: headline,
                subtitle: topPerson.reason.isEmpty ? nil : topPerson.reason,
                ctaLabel: "Open briefing",
                icon: "sparkles",
                accentColor: VisualStyle.intelligence,
                action: .showBrief,
                priority: 0.75
            ))
        }

        // ── 4. Follow-up opportunity ────────────────────────────────────
        // Surface the most recent person the user should reconnect with.
        if !eventJoin.isCheckedIn {
            let topFollowUp = memory.relationships
                .filter { $0.needsFollowUp }
                .sorted {
                    ($0.lastEncounterAt ?? .distantPast) > ($1.lastEncounterAt ?? .distantPast)
                }
                .first
            if let rel = topFollowUp {
                let relDisplayName = IdentityDisplayName.primaryName(
                    name: rel.name,
                    debugSource: "NextBestActionCard.followUp"
                )
                candidates.append(DisplayAction(
                    headline: "Follow up with \(relDisplayName)",
                    subtitle: rel.whyLine.isEmpty ? nil : rel.whyLine,
                    ctaLabel: "Say hello",
                    icon: "arrow.turn.up.right",
                    accentColor: VisualStyle.intelligence,
                    action: .goToPeople,
                    priority: 0.70
                ))
            }
        }

        // ── 5. No goal set — pre-event nudge ───────────────────────────
        // Only surfaces when the brief has no people yet (nothing sharper to show).
        if eventJoin.isEventJoined, !eventJoin.isCheckedIn,
           briefController.currentBrief?.priorityPeople.isEmpty != false {
            let hasGoal = EventContextService.shared.cachedContext?.intentPrimary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            if !hasGoal {
                candidates.append(DisplayAction(
                    headline: "Set a goal for better recommendations",
                    subtitle: "Nearify uses it to find better matches",
                    ctaLabel: "Set goal",
                    icon: "target",
                    accentColor: VisualStyle.primaryAction,
                    action: .showGoalPicker,
                    priority: 0.50
                ))
            }
        }

        return candidates
            .filter { $0.priority >= minPriority }
            .max { $0.priority < $1.priority }
    }

    // MARK: - Body

    var body: some View {
        if let display = topDisplayAction {
            cardView(display)
                .padding(.horizontal)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Card rendering

    private func cardView(_ display: DisplayAction) -> some View {
        Button {
            onAction(display.action)
        } label: {
            HStack(spacing: 12) {
                // Icon badge
                ZStack {
                    Circle()
                        .fill(display.accentColor.opacity(0.13))
                        .frame(width: 34, height: 34)
                    Image(systemName: display.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(display.accentColor)
                }

                // Copy
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sub = display.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundColor(VisualStyle.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // CTA pill
                Text(display.ctaLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(display.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(display.accentColor.opacity(0.14)))
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(display.accentColor.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressableScaleButtonStyle())
    }
}
