import SwiftUI

/// 使用 macOS 原生控件的音量滑条。
struct VolumeSlider: View {
    @Binding var value: Double
    let isMuted: Bool
    let accessibilityLabel: String
    let accessibilityValue: (Double) -> String
    let onEditingChanged: (Bool) -> Void

    init(
        value: Binding<Double>,
        isMuted: Bool,
        accessibilityLabel: String = "音量",
        accessibilityValue: @escaping (Double) -> String = {
            "\(Int(min(max($0, 0), 1) * 100))%"
        },
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.isMuted = isMuted
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.onEditingChanged = onEditingChanged
    }

    static func clampedBinding(
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { min(max(get(), 0), 1) },
            set: { set(min(max($0, 0), 1)) }
        )
    }

    var body: some View {
        Slider(
            value: Self.clampedBinding(
                get: { value },
                set: { value = $0 }
            ),
            in: 0...1,
            onEditingChanged: onEditingChanged
        )
        .tint(isMuted ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.sliderFill)
        .controlSize(.small)
        .frame(height: 16)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue(value))
    }
}
