import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct OpenDisplayBridgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 560, minHeight: 460)
        }
        .windowStyle(.titleBar)

        // Top-bar status item.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            Image(systemName: state.statusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// SF Symbol reflecting the two things that have to be true for a session.
extension AppState {
    var senderUp: Bool { senderConnected }
    var statusSymbol: String {
        switch (senderConnected, receiverAttached) {
        case (true, true):  return "display.2"
        case (true, false): return "display.trianglebadge.exclamationmark"
        case (false, true): return "iphone.badge.exclamationmark"
        case (false, false): return "iphone.slash"
        }
    }
    var statusText: String {
        switch (senderConnected, receiverAttached) {
        case (true, true):  return "streaming"
        case (true, false): return "sender up — no receiver"
        case (false, true): return "no sender — showing demo"
        case (false, false): return "idle"
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text("OpenDisplay Bridge — \(state.statusText)")

        if state.senderConnected {
            Text("Sender: connected")
        } else {
            Text("Sender: waiting on :9000")
        }

        Divider()

        Text("Pairing code: \(state.pairingCode)")
        ForEach(state.receiverURLs, id: \.self) { url in
            Button("Copy \(url)") {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                #endif
            }
        }

        Divider()

        Button("Regenerate Code") { state.regenerateCode() }

        #if canImport(AppKit)
        Button("Show Log Window") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenDisplay Web Bridge").font(.title2).bold()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Pairing code:").font(.headline)
                Text(state.pairingCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Button("Regenerate") { state.regenerateCode() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("On your iPad (Safari), open:").font(.headline)
                // Every candidate address, not just the first. A device on a
                // different interface has no other way in, and the old UI gave
                // it exactly one guess.
                ForEach(state.receiverURLs, id: \.self) { url in
                    HStack(spacing: 8) {
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            #if canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            #endif
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("The iPad must be on the SAME WiFi network as this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                statusRow("OpenDisplay sender",
                          ok: state.senderConnected,
                          okText: "connected on :9000",
                          badText: "waiting for a sender to dial :9000")
                statusRow("iPad receiver",
                          ok: state.receiverAttached,
                          okText: "connected",
                          badText: "no receiver paired")
            }

            if !state.senderConnected && state.receiverAttached {
                Text("No sender yet — showing the generated test pattern. "
                     + "Start the OpenDisplay app, or set OD_SOURCE=relay to wait for one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .onChange(of: state.log.count) { _ in
                        if let last = state.log.indices.last { proxy.scrollTo(last) }
                    }
                }
            }
        }
        .padding(20)
    }

    private func statusRow(_ title: String, ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.green : Color.gray).frame(width: 10, height: 10)
            Text(title).font(.headline)
            Text(ok ? okText : badText).foregroundStyle(.secondary)
        }
    }
}
