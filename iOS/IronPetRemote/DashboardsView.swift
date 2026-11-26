import IronPetKit
import SwiftUI

/// The Dashboards section at the top of More: each dashboard with the icon and colour it has on the Mac, and its count.
struct DashboardsSection: View {
    let model: DashboardsModel

    var body: some View {
        if !model.dashboards.isEmpty {
            Section("Dashboards") {
                ForEach(model.dashboards) { dashboard in
                    NavigationLink(value: MoreDestination.dashboard(dashboard.id)) {
                        HStack {
                            Label { Text(dashboard.title) } icon: { Image(systemName: dashboard.icon).foregroundStyle(DashboardColors.color(dashboard.color)) }
                            Spacer()
                            if let count = dashboard.count { Text("\(count)").foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("dashboard-\(dashboard.id)")
                }
            }
            .listRowBackground(SharedTheme.card)
        }
    }
}

/// One dashboard, drawn from the tree the Mac built. "…" holds Change icon and Capabilities.
struct DashboardDetailView: View {
    let list: DashboardsModel
    let model: DashboardViewModel
    @State private var pickingIcon = false
    @State private var showingCapabilities = false

    private var dashboard: RemoteDashboard? { list.dashboards.first { $0.id == model.id } ?? model.view?.dashboard }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.view?.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                } else if let root = model.view?.root {
                    DashboardNodeView(node: root) { handler in Task { await model.tap(handler) } }
                } else if model.loaded {
                    ContentUnavailableView("Nothing to show", systemImage: "square.grid.2x2")
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.orange) }
                if dashboard?.approval == "pending" {
                    Label("Waiting for Approve on the Mac", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(dashboard?.title ?? "Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { pickingIcon = true } label: { Label("Change icon", systemImage: "star") }.accessibilityIdentifier("dashboard-change-icon")
                    Button { showingCapabilities = true } label: { Label("Capabilities", systemImage: "checkmark.shield") }.accessibilityIdentifier("dashboard-capabilities")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("dashboard-menu")
            }
        }
        .sheet(isPresented: $pickingIcon) { if let dashboard { DashboardIconSheet(list: list, dashboard: dashboard) } }
        .sheet(isPresented: $showingCapabilities) { if let dashboard { DashboardCapabilitiesSheet(dashboard: dashboard) } }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

/// The capabilities a dashboard declares, read only. Approving them is done on the Mac.
struct DashboardCapabilitiesSheet: View {
    let dashboard: RemoteDashboard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if dashboard.capabilities.isEmpty {
                    Text("This dashboard asks for no capabilities. It only shows its own data.").foregroundStyle(.secondary)
                }
                ForEach(dashboard.capabilities) { capability in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(capability.title).font(.headline)
                            if capability.isNew { Text("New").font(.caption2.bold()).padding(.horizontal, 5).background(Capsule().fill(.orange)).foregroundStyle(.black) }
                        }
                        Text(capability.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if dashboard.approval == "pending" {
                    Section { Text("Some of these wait for you on the Mac. Until you approve them there, they do not run.") }
                }
            }
            .navigationTitle(dashboard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Picks an icon and a colour. The choice goes to the Mac, which keeps it for the sidebar and every phone.
struct DashboardIconSheet: View {
    let list: DashboardsModel
    let dashboard: RemoteDashboard
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        ForEach(DashboardColors.names, id: \.self) { name in
                            Button { Task { await list.setAppearance(dashboard, color: name) } } label: {
                                Circle().fill(DashboardColors.color(name)).frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: dashboard.color == name ? 2 : 0).padding(-3))
                            }
                            .accessibilityLabel(name)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(DashboardSymbols.matching(query).map(\.symbol), id: \.self) { symbol in
                            Button { Task { await list.setAppearance(dashboard, icon: symbol) } } label: {
                                Image(systemName: symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(dashboard.icon == symbol ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain).accessibilityLabel(symbol).accessibilityIdentifier("dashboard-icon-\(symbol)")
                        }
                    }
                }
                .padding(16)
            }
            .searchable(text: $query, prompt: "Search symbols")
            .navigationTitle("Icon and colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
