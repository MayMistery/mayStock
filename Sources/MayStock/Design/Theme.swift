import SwiftUI
import MayStockKit

/// The one place type, spacing and semantic colour are decided.
///
/// The previous front end set sizes inline — 8, 9, 10 and 11 point text on
/// the same row, chosen per call site — which is how it ended up dense and
/// hard to read. Views now pick a *role* here; the number lives in one place.
enum Theme {
    // MARK: Type

    enum Text {
        /// Window page titles.
        static let title = Font.system(size: 20, weight: .semibold)
        /// Card and section headings.
        static let heading = Font.system(size: 13, weight: .semibold)
        /// Regular reading text.
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        /// Supporting text: subtitles, table cells, explanations.
        static let secondary = Font.system(size: 11)
        static let secondaryMedium = Font.system(size: 11, weight: .medium)
        /// Labels above numbers, footnotes. The smallest size used anywhere.
        static let caption = Font.system(size: 10)
        static let captionMedium = Font.system(size: 10, weight: .medium)
        static let captionBold = Font.system(size: 10, weight: .bold)
        /// Big figures: account equity, the instrument price.
        static let hero = Font.system(size: 28, weight: .medium, design: .rounded)
        static let heroSmall = Font.system(size: 20, weight: .medium, design: .rounded)
        /// Figures inside tiles and rows.
        static let number = Font.system(size: 14, weight: .medium, design: .rounded)
        static let numberSmall = Font.system(size: 12, weight: .medium, design: .rounded)
        static let mono = Font.system(size: 11, design: .monospaced)
        static let monoSmall = Font.system(size: 10, design: .monospaced)
    }

    // MARK: Spacing & shape

    static let pagePadding: CGFloat = 22
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 8
    static let sectionSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 10

    // MARK: Colour

    static let up = ChartStyle.up
    static let down = ChartStyle.down
    static let accent = ChartStyle.accent
    static let warning = Color.orange
    /// Demo is amber, live is red — the same two colours everywhere the mode is
    /// shown, so a glance at any surface says which account is in play.
    static func mode(_ mode: TradingMode) -> Color { mode.isDemo ? .orange : down }
    static func trend(_ isUp: Bool) -> Color { isUp ? up : down }
    static func signed(_ value: Double) -> Color { value >= 0 ? up : down }

    static let cardFill = Color.primary.opacity(0.04)
    static let cardStroke = Color.primary.opacity(0.07)
    static let rowFill = Color.primary.opacity(0.03)
    static let selectedFill = Color.accentColor.opacity(0.14)
    static let hairline = Color.primary.opacity(0.08)
}

// MARK: - Modifiers

extension View {
    /// The standard content card.
    func cardStyle(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    /// A quieter inset block inside a card.
    func rowStyle(padding: CGFloat = 8) -> some View {
        self
            .padding(padding)
            .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }

    /// Numbers everywhere are monospaced-digit so columns of them line up.
    func numeric() -> some View { monospacedDigit() }
}
