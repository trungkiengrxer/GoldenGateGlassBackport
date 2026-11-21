// Management app UI: Status, Effects, Excluded after crashes, log and uninstall buttons. Uses the stock SwiftUI
// controls and Liquid Glass of macOS 26; when ggapp runs, the app itself gets the 27 look.
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Form {
            Section("Status") {
                StatusRow(ok: store.problem == nil, title: "This Mac",
                          detail: store.problem ?? "macOS 26.6 (25G72), Intel, SIP and AMFI off")
                StatusRow(ok: store.daemonRunning && store.agentRunning, title: "Background helpers",
                          detail: store.daemonRunning && store.agentRunning ? "Running" : "Not running. Reinstall or restart your Mac.")
                StatusRow(ok: store.glassActive, title: "WindowServer",
                          detail: store.glassActive ? "Glass shaders loaded" : "Glass shaders not loaded. Restart your Mac.")
                StatusRow(ok: store.sessionOn, title: "This session",
                          detail: store.sessionOn ? "App effects on" : "App effects off. Log out and back in.")
                HStack {
                    if store.everythingOff {
                        Button("Turn On") { store.turnOn() }.buttonStyle(.glassProminent)
                    } else {
                        Button("Turn Everything Off") { store.turnOff() }.buttonStyle(.glass)
                    }
                    if store.glassChanged {
                        Text("Takes effect after WindowServer restarts (restart your Mac).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(effects, id: \.key) { effect in
                    Toggle(isOn: Binding(get: { store.values[effect.key] ?? effect.defaultOn },
                                         set: { store.set(effect.key, $0) })) {
                        Text(effect.title)
                        Text(effect.detail)
                    }
                    .disabled(store.appOff)
                }
            } header: {
                Text("Effects")
            } footer: {
                Text("Applies to apps opened from now on.").foregroundStyle(.secondary)
            }
            Section("Excluded after crashes") {
                if store.excluded.isEmpty {
                    Text("No apps are excluded.").foregroundStyle(.secondary)
                }
                ForEach(store.excluded, id: \.self) { id in
                    HStack {
                        Text(id)
                        Spacer()
                        Button("Allow Again") { store.allowAgain(id) }.buttonStyle(.glass)
                    }
                }
            }
            Section {
                HStack {
                    Button("Open Logs") { store.openLogs() }.buttonStyle(.glass)
                    Spacer()
                    Button("Uninstall…", role: .destructive) { store.uninstall() }.buttonStyle(.glass)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in store.refresh() }
    }
}

struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "circle.fill").font(.caption).foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
