import IronPetCore
import enum IronPetKit.SharedSymbols
import SwiftUI

/// A one-line banner for sections that read the database.
struct DatabaseBanner: View {
    let reason: String

    var body: some View {
        Label(DatabaseNotice.bannerText, systemImage: SharedSymbols.warning)
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.12))
            .help(reason)
            .accessibilityLabel("\(DatabaseNotice.bannerText). \(reason)")
    }
}
