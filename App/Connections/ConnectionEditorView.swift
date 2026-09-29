import DBCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditorView: View {
    @State var model: ConnectionEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showCertImporter = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $model.kind) {
                ForEach(ConnectionEditorModel.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .onChange(of: model.kind) { model.testState = .idle }

            switch model.kind {
            case .postgres: postgresForm
            case .supabase: supabaseForm
            }

            Divider()
            footer.padding()
        }
        .frame(width: 540, height: 640)
        .fileImporter(isPresented: $showCertImporter, allowedContentTypes: [.x509Certificate, .data]) { result in
            if case .success(let url) = result { model.config.sslRootCert = url.path }
        }
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $model.config.name, prompt: Text(model.resultingConfig.summary))
            Picker("Color", selection: $model.config.colorTag) {
                Text("None").tag(String?.none)
                ForEach(ColorTag.allCases) { tag in
                    Label { Text(tag.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(tag.color) }
                        .tag(Optional(tag.rawValue))
                }
            }
        }
    }

    private var postgresForm: some View {
        Form {
            generalSection
            Section {
                TextField("URL", text: $model.connectionString, prompt: Text("postgresql://user@host:5432/db"), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...3)
                if let error = model.parseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
                ForEach(model.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
                }
                TextField("Host", text: $model.config.host, prompt: Text("localhost or /tmp"))
                TextField("Port", value: $model.config.port, format: .number.grouping(.never))
                TextField("Database", text: $model.config.database)
                TextField("User", text: $model.config.user)
                SecureField("Password", text: $model.password)
            } header: {
                Text("Server")
            } footer: {
                Text("The URL and the fields stay in sync: paste a postgresql:// URL to fill the form. The password is kept in the Keychain, never in the URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Security") {
                Picker("TLS", selection: $model.config.tlsMode) {
                    ForEach(TLSMode.allCases) { Text($0.label).tag($0) }
                }
                if model.config.tlsMode == .verifyCA || model.config.tlsMode == .verifyFull {
                    HStack {
                        TextField("Root Certificate", text: Binding(
                            get: { model.config.sslRootCert ?? "" },
                            set: { model.config.sslRootCert = $0.nilIfEmpty }), prompt: Text("System trust store"))
                        Button("Choose…") { showCertImporter = true }
                    }
                }
            }
            Section("SSH Tunnel") {
                Toggle("Connect through SSH", isOn: $model.useSSH)
                if model.useSSH {
                    TextField("SSH Host", text: $model.ssh.host)
                    TextField("SSH Port", value: $model.ssh.port, format: .number.grouping(.never))
                    TextField("SSH User", text: $model.ssh.user)
                    SecureField("SSH Password", text: $model.sshPassword)
                }
            }
            Section("Advanced") {
                TextField("Connect Timeout (s)", value: $model.config.connectTimeout, format: .number)
                TextField("Application Name", text: Binding(
                    get: { model.config.applicationName ?? "" },
                    set: { model.config.applicationName = $0.nilIfEmpty }), prompt: Text("DB Explorer"))
            }
        }
        .formStyle(.grouped)
    }

    private var supabaseForm: some View {
        Form {
            generalSection
            Section {
                TextField("Project", text: $model.projectRef, prompt: Text("project ref or URL"))
                    .onChange(of: model.projectRef) { _, newValue in model.projectRefChanged(newValue) }
                SecureField("Access Token", text: $model.supabaseToken, prompt: Text("sbp_…"))
            } header: {
                Text("Project")
            } footer: {
                Text("A personal access token from supabase.com/dashboard/account/tokens. On connect, the project's Postgres (temporary login role through the pooler), Storage (S3) and Edge Functions are resolved with it. The token is kept in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Button("Test Connection") { Task { await model.test() } }
                .disabled(model.testState == .testing || !model.canSave)
            testStatus
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(model.isNew ? "Add" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!model.canSave || (model.kind == .postgres && model.parseError != nil))
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch model.testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let version):
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(version)
        case .failure(let message):
            Label("Failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(message)
                .copyableError(message)
        }
    }

    private func save() {
        let id = model.id
        let existing = try? modelContext.fetch(FetchDescriptor<SavedConnection>(predicate: #Predicate { $0.id == id })).first
        let connection = existing ?? SavedConnection(id: id, config: model.resultingConfig)
        if existing == nil { modelContext.insert(connection) }
        model.save(into: connection)
        try? modelContext.save()
        dismiss()
    }
}

private extension View {
    /// Adds a context menu to copy the full error text.
    func copyableError(_ message: String) -> some View {
        self.contextMenu {
            Button("Copy Error") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }
}
