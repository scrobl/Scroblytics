import Foundation
import Observation

/// Which Help article is showing. Shared so any view can open Help at a particular article.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()

    var selectedID: String? = HelpContent.firstArticleID
    var query = ""

    func show(_ id: String) {
        query = ""
        selectedID = id
    }
}

import SwiftUI

/// A small link that opens the Help window at one article.
struct HelpLinkButton: View {
    let articleID: String
    var title = "Learn more in Help"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            HelpNavigator.shared.show(articleID)
            openWindow(id: "help")
        }
        .buttonStyle(.link)
        .font(AppTypography.supporting)
    }
}
