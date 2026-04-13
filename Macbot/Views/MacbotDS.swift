import SwiftUI

enum MacbotDS {
    enum Colors {
        static let bg = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let elevated = Color(nsColor: .underPageBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let textPri = Color.primary
        static let textSec = Color.secondary
        static let textTer = Color(nsColor: .tertiaryLabelColor)
        static let accent = Color.accentColor
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let info = Color.cyan
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Typo {
        static let title = Font.title3.weight(.medium)
        static let heading = Font.subheadline.weight(.semibold)
        static let body = Font.body
        static let caption = Font.caption
        static let detail = Font.caption2.weight(.medium)
        static let mono = Font.caption2.monospaced()
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Mat {
        static let chrome = Material.regularMaterial
        static let float = Material.ultraThinMaterial
    }
}

enum Motion {
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.7)
    static let lively = Animation.spring(response: 0.35, dampingFraction: 0.5)
}
