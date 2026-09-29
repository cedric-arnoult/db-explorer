import DBCore
import SwiftUI

struct RelationTabView: View {
    @Bindable var model: RelationTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $model.mode) {
                    ForEach(RelationTabModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(model.relation.qualifiedName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()

            if let error = model.error {
                ContentUnavailableView("Could Not Load \(model.relation.name)", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let structure = model.structure {
                switch model.mode {
                case .data:
                    if let data = model.data { TableDataView(model: data) }
                case .structure:
                    StructureView(structure: structure)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
