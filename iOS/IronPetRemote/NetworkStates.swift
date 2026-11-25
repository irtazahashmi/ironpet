import IronPetKit
import SwiftUI

/// The three places a network state can show, and no others:
/// the status strip under the top bar, the full-page error of a screen that never loaded, and the one-time sheet for a problem only the person can fix.
/// An item that was sent shows its own state on the item (see `OutgoingLook` and `PendingSyncMark`).

// MARK: Status strip

/// A thin strip under the top bar. It overlays the content at a fixed height, so nothing moves when it shows or hides.
struct NetworkStatusStrip: View {
    static let height: CGFloat = 40
    let network: NetworkHealth

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: network.pathSatisfied ? "desktopcomputer.trianglebadge.exclamationmark" : "wifi.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(network.stripTitle).font(.footnote.weight(.semibold))
                // The minute count follows the clock, not a request, so the strip keeps counting while nothing can be read.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    if let updated = network.updatedText(at: timeline.date) {
                        Text(updated).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("network-strip-updated")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("network-strip")
    }
}

extension View {
    /// Puts the strip under the top bar of every tab. The top bars are inline, so they are the same height on every tab.
    func networkStatusStrip(_ network: NetworkHealth) -> some View {
        overlay(alignment: .top) {
            // The overlay starts under the status bar, so 44 pt (the inline top bar) puts the strip right below the top bar.
            ZStack(alignment: .top) {
                if network.stripVisible {
                    // An offset, not padding, so the strip's own frame stays its fixed height.
                    NetworkStatusStrip(network: network)
                        .offset(y: 44)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}

// MARK: Full-page error

/// What a screen shows when it has never loaded and the Mac cannot be reached.
struct LoadErrorView: View {
    let retry: () async -> Void
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("Can't reach your Mac").font(.headline)
            Button {
                retrying = true
                Task { await retry(); retrying = false }
            } label: {
                if retrying { ProgressView() } else { Text("Retry") }
            }
            .buttonStyle(.bordered)
            .disabled(retrying)
            .accessibilityIdentifier("load-error-retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("load-error")
    }
}

extension View {
    /// Covers the screen with the full-page error while it has never loaded. Once any read worked, the screen keeps its last data instead.
    func fullPageLoadError(_ model: SocketModel) -> some View {
        overlay {
            if model.showsLoadError {
                LoadErrorView { await model.refresh() }.background(SharedTheme.window)
            }
        }
    }
}

// MARK: One-time sheet

/// A problem only the person can fix: what is wrong and the one thing to do.
struct ProblemSheet: View {
    let problem: NetworkHealth.Problem
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: problem == .pairingExpired ? "key.slash" : "arrow.down.app").font(.largeTitle).foregroundStyle(.orange)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: dismiss) { Text(action).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("problem-action")
        }
        .padding(24)
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("problem-sheet")
    }

    private var title: String {
        switch problem {
        case .pairingExpired: return "Pair this phone again"
        case .macTooOld: return "Update IronPet on your Mac"
        }
    }

    private var detail: String {
        switch problem {
        case .pairingExpired: return "The Mac no longer accepts this phone. Make a new pairing code in IronPet on your Mac."
        case .macTooOld: return "The IronPet app on your Mac is older than this phone app. Update it, then open this app again."
        }
    }

    private var action: String { problem == .pairingExpired ? "Pair again" : "OK" }
}
