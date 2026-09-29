import DBCore
import SwiftUI

/// Every field the Management API returns for a deployed Edge Function.
struct EdgeFunctionView: View {
    let function: SupabaseFunction

    var body: some View {
        Table(function.fields) {
            TableColumn("Field") { Text($0.key).font(.body.monospaced()) }
                .width(min: 120, ideal: 180, max: 260)
            TableColumn("Value") { Text($0.value).font(.body.monospaced()).textSelection(.enabled) }
        }
    }
}
