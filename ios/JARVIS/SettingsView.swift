import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var engine: Bool?
    @State private var checkedEngine = false
    @State private var confirmClear = false
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var s = state
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address", value: state.serverURL?.host() ?? "–")
                    LabeledContent("Engine") {
                        if !checkedEngine {
                            ProgressView()
                        } else if engine == true {
                            Text("Online").foregroundStyle(.green)
                        } else {
                            Text(engine == false ? "Offline" : "Unreachable").foregroundStyle(.red)
                        }
                    }
                    LabeledContent("Signed in as", value: state.me.map { $0.isAdmin ? "\($0.name) · admin" : $0.name } ?? "Offline")
                }

                Section {
                    Toggle("Read replies aloud", isOn: $s.readAloud)
                    Toggle("Custom creativity", isOn: Binding(
                        get: { state.temperature != nil },
                        set: { state.temperature = $0 ? 0.7 : nil }
                    ))
                    if let t = state.temperature {
                        VStack(alignment: .leading) {
                            Slider(value: Binding(get: { t }, set: { state.temperature = ($0 * 10).rounded() / 10 }), in: 0...1.5) {
                                Text("Creativity")
                            } minimumValueLabel: {
                                Text("Precise").font(.caption)
                            } maximumValueLabel: {
                                Text("Creative").font(.caption)
                            }
                            Text("Temperature \(t, specifier: "%.1f")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Tip: dictate messages with the mic on the keyboard.")
                }

                Section {
                    Button("Delete all chats on this iPhone", role: .destructive) { confirmClear = true }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Chats are stored only on this iPhone. Replies come only from your own JARVIS server; nothing is sent to anyone else.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                engine = await state.engineOnline()
                checkedEngine = true
            }
            .confirmationDialog("Delete every chat on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all chats", role: .destructive) { state.deleteAllConversations() }
            }
            .confirmationDialog("Sign out of JARVIS?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    state.signOut()
                }
            }
        }
    }
}
