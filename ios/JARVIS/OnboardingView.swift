import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var server = ""
    @State private var key = ""
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case server, key }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image("Logo")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("JARVIS").font(.largeTitle.bold()).tracking(2)
                    Text("Your own AI models, running on your own server.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("Server address", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .server)
                        .onSubmit { focus = .key }
                        .fieldStyle()
                    SecureField("API key (jv-…)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focus, equals: .key)
                        .onSubmit { Task { await connect() } }
                        .fieldStyle()
                }

                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Text("Connect").bold() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || server.isEmpty || key.isEmpty)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("**Server address:** at home on Wi-Fi, your computer's IP and port, like `192.168.1.20:8000`. Away from home, your Tailscale address, like `https://my-pc.tail1234.ts.net`.")
                    Text("**API key:** make one in the JARVIS dashboard's API keys tab, or run `jarvis create-key --name iphone` on the server. An admin key also lets you manage models from your phone.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { server = state.serverURL?.absoluteString ?? "" }
    }

    private func connect() async {
        guard !server.isEmpty, !key.isEmpty, !busy else { return }
        busy = true
        errorText = nil
        do {
            try await state.signIn(server: server, key: key)
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }
}

private extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
