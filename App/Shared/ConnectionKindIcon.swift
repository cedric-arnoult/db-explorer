import DBCore
import SwiftUI

/// Small icon telling a Postgres server from a Supabase project.
struct ConnectionKindIcon: View {
    let isSupabase: Bool

    init(config: ConnectionConfig) {
        isSupabase = config.supabase != nil
    }

    var body: some View {
        Image(systemName: isSupabase ? "bolt.fill" : "cylinder.split.1x2")
            .foregroundStyle(isSupabase ? Color.green : Color.blue)
            .help(isSupabase ? "Supabase" : "PostgreSQL")
    }
}
