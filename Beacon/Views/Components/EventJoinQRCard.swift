import SwiftUI

struct EventJoinQRCard: View {
    let eventId: UUID
    let eventName: String

    private var joinURL: URL {
        QRService.makeEventJoinWebURL(eventId: eventId, eventName: eventName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join this event")
                .font(.headline)
                .foregroundColor(.white)

            Text("Use this to enter the live event network.")
                .font(.caption)
                .foregroundColor(.gray)

            Image(uiImage: QRService.generateQRCode(from: joinURL.absoluteString))
                .interpolation(.none)
                .resizable()
                .frame(width: 180, height: 180)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))

            Text(joinURL.absoluteString)
                .font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
    }
}
