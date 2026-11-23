import IronPetKit
import SwiftUI
import UIKit

/// The chat background the Mac has selected, for every screen to draw: its id, and the decoded picture when the id is `custom`.
struct MacBackground: Equatable {
    var id = ChatBackgrounds.defaultID
    var image: UIImage?
}

private struct MacBackgroundKey: EnvironmentKey {
    static let defaultValue = MacBackground()
}

extension EnvironmentValues {
    var macBackground: MacBackground {
        get { self[MacBackgroundKey.self] }
        set { self[MacBackgroundKey.self] = newValue }
    }
}

/// The Mac's window background, or the chat background the Mac selected, behind a navigation screen. A custom image gets the thin
/// material the Mac puts over it, so list rows and text stay readable on a busy photo.
private struct ScreenBackground: View {
    @Environment(\.macBackground) private var background

    var body: some View {
        ZStack {
            ChatBackgroundPicture(id: background.id, customImage: background.image.map(Image.init(uiImage:)), fallback: SharedTheme.window)
            if background.id == ChatBackgrounds.customID, background.image != nil { Rectangle().fill(.thinMaterial) }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .accessibilityIdentifier("screen-background-\(background.id)")
    }
}

extension View {
    /// The Mac's window background, or the background it chose for the chat, behind a navigation screen, with the system's grouped list
    /// background hidden so it shows through. Apply it inside the NavigationStack, next to `navigationTitle`; the system's black or grey
    /// draws over a background set outside it.
    @ViewBuilder func themedScreen() -> some View {
        if #available(iOS 18, *) {
            self.scrollContentBackground(.hidden).containerBackground(for: .navigation) { ScreenBackground() }
        } else {
            self.scrollContentBackground(.hidden).background { ScreenBackground() }
        }
    }

    /// The tab bar draws the Mac sidebar's half-strength thin material instead of the system's default on iOS 17 to 25.
    /// On iOS 26 the system's glass stays, as the Mac uses glass there too.
    @ViewBuilder func themedTabBar() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            self.toolbarBackground(.ultraThinMaterial.opacity(SharedTheme.chromeStrength), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}
