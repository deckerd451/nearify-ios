import SwiftUI
import UIKit

struct PersonalConnectQRCard: View {
    let title: String
    let subtitle: String
    let connectURL: URL?
    let qrImage: UIImage?

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.gray)

            if let connectURL, let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))

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
                        Label(didCopy ? "Copied" : "Copy Link", systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
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
            } else {
                Text("Join an event to generate your connect QR.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
