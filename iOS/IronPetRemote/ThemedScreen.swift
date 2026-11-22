import IronPetKit
import SwiftUI

extension View {
    /// The Mac's window background behind a navigation screen, with the system's grouped list background hidden so it shows through.
    /// Apply it inside the NavigationStack, next to `navigationTitle`; the system's black or grey draws over a background set outside it.
    @ViewBuilder func themedScreen() -> some View {
        if #available(iOS 18, *) {
            self.scrollContentBackground(.hidden).containerBackground(SharedTheme.window, for: .navigation)
        } else {
            self.scrollContentBackground(.hidden).background(SharedTheme.window)
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
