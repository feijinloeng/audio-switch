import SwiftUI

enum MotionCurve: Equatable {
    case easeOut
    case easeInOut
}

struct MotionSpec: Equatable {
    let duration: Double
    let curve: MotionCurve

    var animation: SwiftUI.Animation {
        switch curve {
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        }
    }
}

enum DesignTokens {

    // MARK: - Colors

    enum Colors {
        static let accentPrimary: Color = .accentColor

        static let textPrimary: Color = .primary
        static let textSecondary: Color = .secondary
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        static let separator = Color(nsColor: .separatorColor)

        static let mutedIndicator = Color(nsColor: .systemRed).opacity(0.85)
        static let defaultDevice: Color = .accentColor

        static let sliderTrack: Color = .primary.opacity(0.15)
        static let sliderFill: Color = .accentColor

    }

    // MARK: - Typography

    enum Typography {
        static let sectionHeader = Font.system(size: 12, weight: .bold)
        static let rowName = Font.system(size: 13, weight: .regular)
        static let percentage = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let caption = Font.system(size: 10, weight: .regular)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Dimensions

    enum Dimensions {
        static let popupWidth: CGFloat = 398
        static let iconSize: CGFloat = 22

        static let sliderThumbWidth: CGFloat = 16
        static let sliderThumbHeight: CGFloat = 10
        static let rowContentHeight: CGFloat = 28
        static let appNameControlWidth: CGFloat = 130
        static let sliderWidth: CGFloat = 140
        static let panoramaDetailSliderWidth: CGFloat = 240
        static let muteButtonWidth: CGFloat = 24
        static let sliderMinWidth: CGFloat = 120
        static let percentageWidth: CGFloat = 40

        static let vuMeterBarCount: Int = 8
    }

    // MARK: - Animation

    enum Animation {
        static let press = MotionSpec(duration: 0.08, curve: .easeOut)
        static let hover = MotionSpec(duration: 0.12, curve: .easeOut)
        static let state = MotionSpec(duration: 0.16, curve: .easeOut)
        static let content = MotionSpec(duration: 0.20, curve: .easeInOut)
        static let reveal = MotionSpec(duration: 0.20, curve: .easeOut)
    }
}
