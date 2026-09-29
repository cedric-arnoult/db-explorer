import DBCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: DatabaseModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                Label("New Query", systemImage: "plus.rectangle.on.rectangle")
                    .tag(SidebarItem.newQuery)
            }
            if let error = model.catalogError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                }
            }
            Section("Schemas") {
                ForEach(model.visibleSchemas) { schema in
                    DisclosureGroup(isExpanded: expansion(for: schema.name)) {
                        let relations = model.filteredRelations(in: schema.name)
                        if relations.isEmpty, model.relationsBySchema[schema.name] != nil {
                            Text("No tables").foregroundStyle(.secondary).font(.caption)
                        }
                        ForEach(relations) { relation in
                            Label(relation.name, systemImage: relation.kind.systemImage)
                                .help("\(relation.kind.label) \(relation.qualifiedName)")
                                .tag(SidebarItem.relation(relation))
                                .contextMenu {
                                    Button("Open") { model.open(.relation(relation)) }
                                    Button("Select Top 100") {
                                        model.newQuery(text: "SELECT * FROM \(relation.qualifiedName) LIMIT 100;")
                                    }
                                    Button("Copy Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(relation.qualifiedName, forType: .string)
                                    }
                                }
                        }
                    } label: {
                        Label(schema.name, systemImage: schema.isSystem ? "gearshape" : "folder")
                    }
                }
            }
            if let supabase = model.supabase {
                Section("Storage (S3)") {
                    if let error = supabase.storageError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                    }
                    ForEach(supabase.buckets) { bucket in
                        Label(bucket.name, systemImage: "archivebox")
                            .tag(SidebarItem.bucket(bucket.name))
                    }
                }
                Section("Edge Functions") {
                    if let error = supabase.functionsError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                    }
                    ForEach(supabase.functions) { function in
                        Label(function.slug, systemImage: "function")
                            .tag(SidebarItem.edgeFunction(function.slug))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.sidebarFilter, placement: .sidebar, prompt: "Filter tables")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("System schemas", isOn: $model.showSystemSchemas)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                if let version = model.serverVersion {
                    Text(version.split(separator: " ").prefix(2).joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(version)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: model.showSystemSchemas) { Task { await model.reloadCatalog() } }
    }

    private func expansion(for schema: String) -> Binding<Bool> {
        Binding {
            !model.sidebarFilter.isEmpty || model.expandedSchemas.contains(schema)
        } set: { expanded in
            if expanded {
                model.expandedSchemas.insert(schema)
                Task { await model.loadRelations(schema: schema) }
            } else {
                model.expandedSchemas.remove(schema)
            }
        }
    }
}
