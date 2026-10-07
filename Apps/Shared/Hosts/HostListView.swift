import SwiftUI
import AcceSSHCore

struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Host?
    @State private var path: [UUID] = []
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.hosts.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to connect to it over SSH.")
                    } actions: {
                        Button("Add Host") { editing = Host(hostname: "", username: "") }
                    }
                }
                #if DEBUG
                ForEach(model.seedErrors, id: \.self) { Text($0) }
                #endif
                ForEach(model.hosts.sortedHosts) { host in
                    NavigationLink(value: host.id) {
                        HostRow(host: host, isConnected: model.sessions.contains { $0.host.id == host.id && $0.state.isActive })
                    }
                    .accessibilityAction(named: "Edit") { editing = host }
                    .accessibilityAction(named: host.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        var updated = host
                        updated.isFavorite.toggle()
                        model.hosts.save(updated)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { model.hosts.delete(host) }
                        Button("Edit") { editing = host }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = host }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.hosts.delete(host) }
                    }
                }
            }
            .navigationTitle("AcceSSH")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Host(hostname: "", username: "") } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .navigationDestination(for: UUID.self) { hostID in
                if let host = model.hosts.hosts.first(where: { $0.id == hostID }) {
                    SessionView(session: model.session(for: host))
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(item: $editing) { host in
                HostEditorView(host: host) { saved in
                    model.hosts.save(saved)
                }
            }
        }
    }
}

private struct HostRow: View {
    let host: Host
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(host.effectiveDisplayName).font(.headline)
                if host.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityHidden(true)
                }
            }
            Text(host.connectionSummary).font(.subheadline).foregroundStyle(.primary)
            if isConnected {
                Label("Connected", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.effectiveDisplayName)
        .accessibilityValue([host.connectionSummary, host.isFavorite ? "Favorite" : nil, isConnected ? "Connected" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Connects to this host.")
    }
}
