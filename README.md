# DB Explorer

A free, native macOS app to explore PostgreSQL and Supabase databases.

Connect to any PostgreSQL server, or to a Supabase project with just its ref and an access token, then browse
schemas, read and edit table data, run SQL, and look inside Supabase Storage buckets. Built with SwiftUI and
[PostgresNIO](https://github.com/vapor/postgres-nio): no Electron, no JVM, no account.

## Features

### Connections

- **PostgreSQL**: a form and a `postgresql://` URL kept in sync, so pasting a connection URL fills in the form.
- **Supabase**: only a project ref (or any project URL) and a personal access token. The database, Storage and
  Edge Functions are all resolved from them when you connect.
- TLS modes from `disable` to `verify-full`, with an optional custom root certificate.
- SSH tunnels with password authentication.
- Unix-socket connections (for example `/tmp`).
- Color tags to tell production from development at a glance.
- Passwords and tokens are stored in the macOS Keychain, never on disk or in URLs.

### Browsing and editing

- Schemas, tables, views, materialized views and foreign tables in a filterable sidebar.
- Structure view: columns, types, defaults, indexes and constraints.
- Data grid with server-side paging, sorting and `WHERE` filters, plus an inspector for the selected row.
- Edit cells, insert and delete rows, then save everything in a single transaction, with undo.
- Export results as CSV or JSON.

### SQL editor

- One tab per query, each with its own connection, so `BEGIN` … `COMMIT` spans several runs.
- Run the selection, the current statement, or the whole script; cancel long-running queries.
- Query history per connection.

### Supabase, without the dashboard layer

A Supabase project is shown as its underlying building blocks:

- **Postgres**: the whole database, including the `auth`, `storage`, `realtime` and `vault` schemas as plain
  tables. The app connects through the project's connection pooler with a temporary login role created
  through the Supabase Management API, so no database password is needed.
- **Storage**: buckets and objects through the S3-compatible endpoint. Browse folders, inspect object headers,
  preview images and text, and download files. Storage is read-only.
- **Edge Functions**: the deployed functions and their metadata.

Supabase connections run as the `postgres` role, so Row Level Security does not hide any rows. Treat them as
admin access.

## Requirements

- macOS 27 or later
- Xcode 27 to build from source

## Install

Download `DBExplorer.zip` from the [Releases](https://github.com/cedric-arnoult/db-explorer/releases) page, unzip it and move `DBExplorer.app` to
`/Applications`. Releases are signed with a Developer ID and notarized by Apple.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New connection | ⌘N |
| Show connections | ⌘0 |
| New query | ⌘T |
| Run statement or selection | ⌘↩ |
| Run all | ⇧⌘↩ |
| Cancel query | ⌘. |
| Refresh | ⌘R |
| Save changes | ⌘S |
| Discard changes | ⌥⌘S |
| Add row | ⌥⌘N |
| Close tab | ⇧⌘W |

## Building from source

```sh
git clone https://github.com/cedric-arnoult/db-explorer.git
cd db-explorer
open DBExplorer.xcodeproj
```

Run the `DBExplorer` scheme. To sign with your own account, change the team under Signing & Capabilities.

### Project layout

- `App/`: the SwiftUI application.
- `Packages/DBCore/`: everything that can be tested without a UI. That covers connection strings, catalog
  introspection, binary value decoding, the change set to SQL translation, the SQL statement splitter,
  export, SSH tunnels, the S3 client and the Supabase Management API client.
- `scripts/`: tests and release packaging.
- `Design/`: the source of the app icon.

### Tests

```sh
scripts/test.sh               # DBCore unit tests and an unsigned Release build
scripts/test-integration.sh   # integration tests against postgres:18 in Docker
```

Supabase integration tests run against a real project. They only read data, apart from creating the
temporary login role:

```sh
cd Packages/DBCore
SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… swift test --filter SupabaseIntegrationTests
```

### Releasing

`scripts/release.sh` archives the app, exports it with a Developer ID certificate, notarizes it and staples
the ticket. It needs an App Store Connect API key, set through environment variables or a local
`scripts/release.env` file. The expected variables are documented at the top of the script.

## Notes

- Everything is stored per macOS user, and the app itself ships with no connections. Saved connections and query
  history are in `~/Library/Application Support/dev.dbexplorer.DBExplorer/`. Passwords and access tokens are in
  the login Keychain.
- SSH host keys are trusted on first use and remembered.
- The app is not sandboxed, so that Unix-socket connections keep working.

## License

DB Explorer is released under the [MIT License](LICENSE): you are free to use, copy, modify and distribute it.
