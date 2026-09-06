import SwiftUI

/// Mute toggle button with SF Symbol.
struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? Color.red : Color.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(isMuted ? "取消静音" : "静音")
    }
}
