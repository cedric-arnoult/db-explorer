#!/bin/sh
# Runs DBCore integration tests against postgres:18 in Docker.
set -eu
cd "$(dirname "$0")/../Packages/DBCore"
NAME=dbexplorer-test-postgres
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:18 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT
until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
DBEXPLORER_TEST_DATABASE_URL="postgresql://postgres:postgres@localhost:55432/postgres?sslmode=disable" swift test "$@"
