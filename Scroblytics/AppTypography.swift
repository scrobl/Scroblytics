import Foundation
import SwiftUI

/// The app-wide semantic typography ramp. Roles use system text styles so
/// hierarchy remains consistent across every screen and platform appearance.
enum AppTypography {
    static let pageTitle = Font.title2.bold()
    static let navigationIcon = Font.body.weight(.semibold)

    static let entityTitle = Font.title2.bold()
    static let entitySubtitle = Font.title3
    static let entityTertiary = Font.callout

    static let sectionTitle = Font.headline
    static let contentTitle = Font.body.weight(.medium)
    static let compactTitle = Font.callout.weight(.medium)
    static let metadata = Font.callout
    static let compactMetadata = Font.caption
    static let supporting = Font.caption
    static let supportingDense = Font.caption2

    static let statLabel = Font.caption
    static let statValue = Font.title3.monospacedDigit()

    static let badge = Font.caption.weight(.semibold)
    static let denseBadge = Font.caption2.weight(.semibold)

    static let tableHeading = Font.callout.weight(.semibold)
    static let tableRank = Font.body.weight(.semibold).monospacedDigit()
    static let tableValue = Font.callout.weight(.medium).monospacedDigit()
    static let tablePreviousValue = Font.callout.monospacedDigit()

    static let chartAxis = Font.caption2
    static let codeInput = Font.body.monospaced()
    static let indexStrip = Font.caption2.weight(.semibold)
}

/// Shared entity-artwork dimensions. Grid tiles remain adaptive within the
/// same range, while list and compact-card thumbnails use one fixed baseline.
enum AppArtworkSizing {
    static let thumbnail: CGFloat = 48
    static let tileMinimum: CGFloat = 140
    static let tileMaximum: CGFloat = 180
    static let tileSpacing: CGFloat = 16
}

enum AppColors {
    /// Darker than the system green so compact badges retain strong contrast
    /// when their foreground is white.
    static let positiveBadge = Color(red: 0.10, green: 0.45, blue: 0.22)
}

enum AppDateFormatting {
    static let recentPlay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm a"
        return formatter
    }()

    static let releaseDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = AppCalendars.releaseDates
        formatter.timeZone = AppCalendars.releaseDates.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
