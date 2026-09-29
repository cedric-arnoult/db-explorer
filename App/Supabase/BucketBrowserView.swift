import DBCore
import SwiftUI
import UniformTypeIdentifiers

/// Objects of one S3 bucket, one prefix level at a time, with an inspector for the selected object.
struct BucketBrowserView: View {
    @Bindable var model: BucketTabModel
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if let error = model.error {
                ContentUnavailableView("Could Not List \(model.bucket)", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                grid
            }
            Divider()
            statusBar
        }
        .inspector(isPresented: $showInspector) {
            ObjectInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
        }
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button("Up", systemImage: "chevron.up") {
                let parent = model.breadcrumbs.dropLast().last?.1 ?? ""
                Task { await model.open(prefix: parent) }
            }
            .labelStyle(.iconOnly)
            .disabled(model.prefix.isEmpty)
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary) }
                Button(crumb.0) { Task { await model.open(prefix: crumb.1) } }
                    .buttonStyle(.plain)
                    .fontWeight(crumb.1 == model.prefix ? .semibold : .regular)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .font(.callout.monospaced())
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
            }
            .width(min: 160, ideal: 320)
            TableColumn("Size") { entry in
                if let object = entry.object {
                    Text(object.size.formatted(.byteCount(style: .file))).monospacedDigit()
                }
            }
            .width(min: 60, ideal: 90)
            TableColumn("Last Modified") { entry in
                if let date = entry.object?.lastModified {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
            .width(min: 120, ideal: 170)
            TableColumn("ETag") { entry in
                Text(entry.object?.eTag ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string)
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, model.entries.first(where: { $0.id == id })?.isFolder == true {
                Task { await model.open(prefix: id) }
            } else {
                showInspector = true
            }
        }
    }

    private var statusBar: some View {
        HStack {
            let folders = model.entries.count(where: \.isFolder)
            Text("\(folders) folders, \(model.entries.count - folders) objects")
                .foregroundStyle(.secondary)
            Spacer()
            if model.nextToken != nil {
                Button("Load More") { Task { await model.loadMore() } }
                    .disabled(model.isLoading)
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct ObjectInspector: View {
    let model: BucketTabModel
    @State private var download: DataDocument?
    @State private var downloadError: String?

    var body: some View {
        if let object = model.selectedObject {
            Form {
                Section("Object") {
                    LabeledContent("Key") { Text(object.key).textSelection(.enabled) }
                    LabeledContent("Size", value: object.size.formatted(.byteCount(style: .file)))
                    Button("Download…") { Task { await fetch(object) } }
                    if let downloadError { Text(downloadError).foregroundStyle(.red).font(.caption) }
                }
                if let error = model.inspectError {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let preview = model.preview {
                    Section("Preview") { PreviewView(preview: preview) }
                }
                if let head = model.head {
                    Section("Headers") {
                        ForEach(head.headers) { header in
                            LabeledContent(header.key) { Text(header.value).textSelection(.enabled) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fileExporter(
                isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } }),
                document: download, contentType: .data,
                defaultFilename: object.key.split(separator: "/").last.map(String.init)
            ) { _ in download = nil }
        } else {
            ContentUnavailableView("No Object Selected", systemImage: "doc",
                                   description: Text("Select an object to see its headers and a preview."))
        }
    }

    private func fetch(_ object: S3Object) async {
        do {
            download = DataDocument(data: try await model.download(object))
            downloadError = nil
        } catch {
            downloadError = error.fullDescription
        }
    }
}

private struct PreviewView: View {
    let preview: BucketTabModel.Preview

    var body: some View {
        switch preview {
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
        case .text(let text):
            ScrollView {
                Text(text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary)
        }
    }
}

/// Raw bytes written by `.fileExporter`.
struct DataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
