import DBCore
import SwiftUI
import UniformTypeIdentifiers

/// Text file written by `.fileExporter` (CSV or JSON export of a result).
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]

    var text: String

    init(resultSet: ResultSet, format: ResultExporter.Format) {
        text = ResultExporter.export(resultSet, as: format)
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension ResultExporter.Format {
    var contentType: UTType { self == .csv ? .commaSeparatedText : .json }
    var label: String { self == .csv ? "CSV" : "JSON" }
}

/// Menu + exporter for a result set.
struct ExportMenu: View {
    let resultSet: () -> ResultSet?
    let filename: String
    @State private var document: ExportDocument?
    @State private var format: ResultExporter.Format = .csv

    var body: some View {
        Menu("Export", systemImage: "square.and.arrow.up") {
            ForEach(ResultExporter.Format.allCases) { format in
                Button("Export as \(format.label)…") {
                    guard let result = resultSet() else { return }
                    self.format = format
                    document = ExportDocument(resultSet: result, format: format)
                }
            }
        }
        .fileExporter(
            isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
            document: document,
            contentType: format.contentType,
            defaultFilename: "\(filename).\(format.fileExtension)"
        ) { _ in document = nil }
    }
}
