import SwiftUI

/// Admin tools: switch versions, edit a model's personality, download base models.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var data: AdminModels?
    @State private var loadError: String?
    @State private var pullName = ""
    @State private var pulling = false
    @State private var pullProgress: Double?
    @State private var pullStatus: String?

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }

                Section("My models") {
                    if data == nil && loadError == nil {
                        ProgressView()
                    } else if let data, data.custom.isEmpty {
                        Text("No custom models yet. Create one from the dashboard on your computer.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(data?.custom ?? []) { model in
                        NavigationLink {
                            ModelDetailView(model: model) { await load() }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(model.name).font(.headline)
                                    Text("v\(model.activeVersion ?? 0)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                                }
                                if !model.description.isEmpty {
                                    Text(model.description).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("e.g. llama3.2:3b", text: $pullName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Download to server") { Task { await pull() } }
                        .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty || pulling)
                    if let pullStatus {
                        VStack(alignment: .leading, spacing: 6) {
                            if let pullProgress { ProgressView(value: pullProgress) }
                            Text(pullStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Download a base model")
                } footer: {
                    Text("Browse models at ollama.com/library. 1–4B models run on most computers; 7–8B need about 16 GB of RAM.")
                }

                if let base = data?.base, !base.isEmpty {
                    Section("On the server") {
                        ForEach(base) { b in
                            LabeledContent(b.name, value: ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))
                        }
                    }
                }
            }
            .navigationTitle("My models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let api = state.api else { return }
        do {
            data = try await api.adminModels()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func pull() async {
        guard let api = state.api else { return }
        let name = pullName.trimmingCharacters(in: .whitespaces)
        pulling = true
        pullStatus = "Starting…"
        pullProgress = 0
        do {
            for try await p in api.pull(model: name) {
                if let total = p.total, total > 0 {
                    pullProgress = Double(p.completed ?? 0) / Double(total)
                }
                if let status = p.status { pullStatus = status }
            }
            pullStatus = "\(name) is ready"
            pullProgress = 1
            pullName = ""
            await load()
            await state.refreshModels()
        } catch {
            pullStatus = error.localizedDescription
            pullProgress = nil
        }
        pulling = false
    }
}

struct ModelDetailView: View {
    @Environment(AppState.self) private var state
    let model: CustomModel
    let onChange: () async -> Void

    @State private var versions: [ModelVersion]
    @State private var active: Int?
    @State private var system: String
    @State private var notes = ""
    @State private var teach = false
    @State private var saving = false

    init(model: CustomModel, onChange: @escaping () async -> Void) {
        self.model = model
        self.onChange = onChange
        _versions = State(initialValue: model.versions)
        _active = State(initialValue: model.activeVersion)
        _system = State(initialValue: model.versions.first { $0.version == model.activeVersion }?.system ?? "")
    }

    private var nextVersion: Int { (versions.map(\.version).max() ?? 0) + 1 }

    var body: some View {
        Form {
            Section {
                ForEach(versions.reversed()) { v in
                    Button {
                        Task { await activate(v.version) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("v\(v.version)").font(.headline)
                                Text(subtitle(v)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if v.version == active {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Versions")
            } footer: {
                Text("Tap a version to make it live. Every app using \(model.name) switches instantly.")
            }

            Section {
                TextEditor(text: $system)
                    .frame(minHeight: 150)
                TextField("What changed? (optional)", text: $notes)
                Toggle("Teach it my 👍 replies", isOn: $teach)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Save as v\(nextVersion)").bold() }
                }
                .disabled(saving)
            } header: {
                Text("Personality")
            } footer: {
                Text("Saving builds a new version from the live one and makes it live. You can always switch back.")
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func subtitle(_ v: ModelVersion) -> String {
        if !v.notes.isEmpty { return v.notes }
        return v.ggufDigest != nil ? "Custom weights" : (v.base ?? "")
    }

    private func activate(_ version: Int) async {
        guard version != active, let api = state.api else { return }
        do {
            try await api.activate(model.name, version: version)
            active = version
            system = versions.first { $0.version == version }?.system ?? system
            state.show("\(model.name) is now on v\(version)")
            await onChange()
        } catch {
            state.show(error.localizedDescription)
        }
    }

    private func save() async {
        guard let api = state.api else { return }
        saving = true
        defer { saving = false }
        do {
            let v = try await api.newVersion(model.name, system: system, notes: notes.isEmpty ? "from iPhone" : notes, teach: teach)
            versions.append(v)
            active = v.version
            notes = ""
            teach = false
            state.show("v\(v.version) is live")
            await onChange()
            await state.refreshModels()
        } catch {
            state.show(error.localizedDescription)
        }
    }
}
