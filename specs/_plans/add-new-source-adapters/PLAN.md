# Plan: Add DuckDB, StarRocks, ClickHouse source adapters

## Status
Drafted 2026-05-16. Blocked on PR #42 (`harden-master-migration-entrypoint`) merge — these are additive features that should not stack onto the wrapper-hardening review surface.

## Motivation
- Maglev demo: SQLCube wants more source-diversity options when demoing the wrapper-driven ingest path.
- Customer asks: prospects on each of the three platforms have requested Exasol migration paths.
- OSS coverage: rounds out `exasol/database-migration` source matrix; current matrix is heavy on legacy enterprise sources (Oracle, DB2, Vertica, SQL Server) and light on modern OLAP/analytical (DuckDB, ClickHouse, StarRocks).
- Matrix completeness: simplifies future "all sources supported" claims.

## Sequencing
Land PR #42 first, then ship as 5 separate follow-up PRs (one source per PR — reviewable independently, deployable independently). Build order DuckDB → StarRocks → ClickHouse → Dremio → Trino, rationale below.

DuckDB is already implemented locally on branch `feat/duckdb-source-adapter` (commit `406abbf`); held there until PR #42 merges so the new branch can be rebased onto a clean upstream master.

StarRocks is also implemented and **live-verified** on branch `feat/starrocks-source-adapter` (commits `7d41968` + `da7f3c5`). Adapter, wrapper dispatch, Lua tests (20 cases), wrapper dispatch test (41 total), and runtime mock smoke (18 dispatches) all green. Local live smoke is blocked on Apple Silicon (the only public StarRocks image `starrocks/allin1-ubuntu` is amd64-only and the BE binary SIGSEGVs repeatedly under qemu emulation, same class as Oracle XE 21 / SQL Server 2022 on arm64) — so the live smoke was run against Frankfurt EC2 (`zaad-ubuntu-v8`, 52.28.97.243), where native x86_64 boots cleanly. EC2 run: preview 7 rows, execute 7 rows, 2 rows loaded into SMOKEDB.SMOKE. Smoke surfaced + fixed two StarRocks-specific quirks now baked into the adapter: (1) force-upper aliases on the IMPORT SELECT because StarRocks JDBC returns lower-case column names, and (2) skip `information_schema.tables` join because the `table_catalog` values diverge across that view and `information_schema.columns`.

## Per-source design

### 1. DuckDB (first — easiest)
- **Why first**: smallest type space, JDBC stable, single-process embedded DB → smoke is trivial (write a .duckdb file or in-memory then SELECT via JDBC).
- **JDBC driver**: `org.duckdb:duckdb_jdbc` (Maven Central). Main class `org.duckdb.DuckDBDriver`. URL form `jdbc:duckdb:<path-to-file>` or `jdbc:duckdb::memory:`.
- **Wrapper dispatch signature**: 4 args, mirror MYSQL — `(CONNECTION_NAME, IDENTIFIER_CASE_INSENSITIVE, SCHEMA_FILTER, TABLE_FILTER)`. No DB_FILTER (DuckDB is single-DB-per-file).
- **Adapter file**: `duckdb_to_exasol.sql` with `DUCKDB_TO_EXASOL` script. Datatype mapping: DuckDB types are mostly SQL-standard (INTEGER, BIGINT, DOUBLE, VARCHAR, DATE, TIMESTAMP, BOOLEAN, DECIMAL) — map straight. Special handling for `STRUCT`/`LIST`/`MAP` → cast to `::VARCHAR`. `UUID` → `HASHTYPE(16 BYTE)` or `VARCHAR(36)`. `BLOB` → `VARCHAR(2000000)` text-cast (Exasol has no native BLOB).
- **Smoke**: harness needs the DuckDB file shipped into the Nano container or accessible at a path the JDBC driver in Nano can reach. Simplest: write `.duckdb` file on host, `docker cp` into Nano at `/tmp/smoke.duckdb`, URL `jdbc:duckdb:/tmp/smoke.duckdb`.
- **Test plan**: `test/test_duckdb_to_exasol.lua` covering quoting, datatype branches, SCHEMA/TABLE filter substitution. Live smoke entry in `_reference/live_smoke.py` under `SOURCES["duckdb"]`.

### 2. StarRocks (second — MySQL-compat reuse)
- **Why second**: MySQL wire protocol → can subclass `mysql_to_exasol.sql` as a starting point and adjust only where StarRocks-specific types diverge.
- **JDBC driver**: MariaDB JDBC driver (`org.mariadb.jdbc:mariadb-java-client`) — StarRocks officially supports it. Already in Nano `/exa/jdbc/MARIADB/`. Reuse: either point a new `STARROCKS` driver dir at the same jar with `PREFIX=jdbc:mariadb:` (URL form same as MySQL), or just use the MARIADB driver with `jdbc:mariadb://<sr-fe>:9030/<db>`.
- **Wrapper dispatch signature**: 4 args, mirror MYSQL.
- **Adapter file**: `starrocks_to_exasol.sql`. Starting point: copy `mysql_to_exasol.sql`, rename script to `STARROCKS_TO_EXASOL`, change `information_schema.columns` filters to skip StarRocks-internal schemas (`_statistics_`, `information_schema`, `sys`). Datatype: StarRocks supports `BITMAP`, `HLL`, `LARGEINT`, `JSON`, `ARRAY<T>`, `MAP<K,V>`, `STRUCT<...>`, `PERCENTILE` — none of which exist in Exasol. Cast to `::VARCHAR` in the IMPORT SELECT. `DATETIME` → `TIMESTAMP`. `LARGEINT` (128-bit) → `DECIMAL(36,0)` or `VARCHAR(40)` (Exasol max is `DECIMAL(36,0)`).
- **Docker image**: `starrocks/allin1-ubuntu` (FE + BE in one container). Default user `root` no password. SQL port 9030 (MySQL-compat). Ready marker: `Frontend started.`
- **Smoke**: seed via MariaDB CLI (already used for mariadb smoke). Wrapper call `MIGRATE_TO_EXASOL('STARROCKS', 'STARROCKS_JDBC', 'JDBC', '%', 'smokedb', 'smoke', NULL, TRUE, debug, '')`.
- **Test plan**: `test/test_starrocks_to_exasol.lua` covering StarRocks-specific datatype cast branches (BITMAP, HLL, LARGEINT, JSON, ARRAY, MAP). Live smoke entry in `_reference/live_smoke.py`.

### 3. ClickHouse (third — heaviest types)
- **Why last**: largest datatype surface to map; LowCardinality wrapper and Nullable wrapper need stripping before mapping the inner type; Array/Tuple/Map need cast-to-VARCHAR; Decimal128/Decimal256/UInt64 don't fit cleanly into Exasol DECIMAL(36,0).
- **JDBC driver**: `com.clickhouse:clickhouse-jdbc` (uber-jar, `clickhouse-jdbc-X.X.X-all.jar`). Main class `com.clickhouse.jdbc.ClickHouseDriver`. URL `jdbc:clickhouse://<host>:8123/<db>?ssl=false` (HTTP) or `jdbc:clickhouse://<host>:9000/<db>` (native).
- **Wrapper dispatch signature**: 4 args, mirror MYSQL. ClickHouse has DBs but each catalog == one DB, so SCHEMA_FILTER aligns to ClickHouse "database".
- **Adapter file**: `clickhouse_to_exasol.sql`. Datatype mapping is the bulk of work:
  - Strip `LowCardinality(T)` and `Nullable(T)` wrappers in a CTE before the case expression.
  - `UInt8/UInt16/UInt32` → `INTEGER` / `BIGINT` / `DECIMAL(18,0)`.
  - `UInt64` → `DECIMAL(20,0)` (fits in Exasol DECIMAL(36,0)).
  - `Decimal128`/`Decimal256` → cast `::VARCHAR(80)` in IMPORT SELECT (precision exceeds Exasol max).
  - `Int128`/`Int256` → cast `::VARCHAR(80)`.
  - `String`/`FixedString(N)` → `VARCHAR`.
  - `Date`/`Date32`/`DateTime`/`DateTime64` → `DATE`/`TIMESTAMP`.
  - `Array(T)`/`Tuple(...)`/`Map(K,V)`/`Nested(...)` → cast `::String` in IMPORT.
  - `Enum8`/`Enum16` → cast to underlying string repr via `toString`.
  - `UUID` → `HASHTYPE(16 BYTE)` or `VARCHAR(36)`.
  - `IPv4`/`IPv6` → cast to `::String`.
- **Docker image**: `clickhouse/clickhouse-server:latest` (arm64 native). HTTP 8123, native 9000. Default user `default` no password. Ready marker: `Ready for connections.`
- **Smoke**: seed via `clickhouse-client` Docker image (`clickhouse/clickhouse-client`) — pattern matches existing seeds. Wrapper call signature aligned with MYSQL.
- **Test plan**: `test/test_clickhouse_to_exasol.lua` with explicit cases for LowCardinality/Nullable unwrap, each datatype branch, Decimal128 cast-to-VARCHAR, Array cast-to-String. Live smoke entry in `_reference/live_smoke.py`.

### 4. Dremio (fourth)
- **Why fourth**: lakehouse semantic layer, accelerated query over data lakes (Iceberg/Delta/Parquet). Customers running Dremio as their "semantic gateway" want Exasol performance behind that same surface for hot/governed marts. Type space is Arrow-derived (INTEGER/BIGINT/VARCHAR/DATE/TIMESTAMP/INTERVAL/LIST/STRUCT) — close to DuckDB; can reuse much of that mapping logic.
- **JDBC driver**: `com.dremio.jdbc:dremio-jdbc-driver` (uber-jar from Dremio's Maven repo, not Central). Main class `com.dremio.jdbc.Driver`. URL form `jdbc:dremio:direct=<host>:31010;schema=<space>` (Arrow Flight via port 32010 also supported but slower for migration use).
- **Wrapper dispatch signature**: 5 args, mirror SQLSERVER/DATABRICKS — `(CONNECTION_NAME, IDENTIFIER_CASE_INSENSITIVE, DB_FILTER, SCHEMA_FILTER, TABLE_FILTER)`. Dremio uses 3-tier naming: source/space → folder/schema → physical-dataset/virtual-dataset.
- **Adapter file**: `dremio_to_exasol.sql` with `DREMIO_TO_EXASOL` script. Pull metadata from `INFORMATION_SCHEMA."COLUMNS"` (Dremio keeps quoted upper-case). Datatype mapping: INTEGER/BIGINT → DECIMAL(11,0)/DECIMAL(19,0); FLOAT/DOUBLE pass-through; DECIMAL(p,s) cap at 36; VARCHAR pass-through; DATE/TIMESTAMP pass-through; INTERVAL → VARCHAR(50); LIST/STRUCT/MAP → cast to VARCHAR via `CONVERT_TO(col, 'JSON')` on Dremio side; BINARY/VARBINARY → VARCHAR cast.
- **Docker image**: `dremio/dremio-oss:latest` (~3 GB OSS edition). Default web admin port 9047, JDBC 31010, Arrow Flight 32010. Bootstrap: needs initial admin user creation via REST. Wait marker: `"Dremio OSS is up"` in logs.
- **Smoke**: seed via JDBC after bootstrap — create space, create dataset from inline `VALUES`. Or simpler: skip Dremio's seeding complexity, write the smoke as standalone (`_reference/live_dremio.py`) that uses `pydremio`/`pyarrow.flight` for seed + Exasol JDBC for migration. Tradeoff: Dremio bootstrap (admin user + space + dataset registration) is heavier than the postgres/mysql pattern.
- **Architectural caveat to document**: Dremio is a query gateway. Migrations execute through Dremio's connector layer to the underlying source (S3/Iceberg/etc.). Migration performance depends on the underlying connector and Dremio reflection state, not Dremio's engine. Document explicitly in adapter header comment.
- **Test plan**: `test/test_dremio_to_exasol.lua` covering Dremio-specific datatype branches (INTERVAL, LIST/STRUCT JSON cast, DECIMAL cap), virtual-vs-physical dataset SCHEMA filter expectations. Live smoke entry.

### 5. Trino (fifth)
- **Why last**: federated SQL engine. Less self-contained than Dremio (no built-in storage). Smoke is more about proving the JDBC + wrapper handshake than the type space (Trino's JDBC normalizes most types to standard SQL).
- **JDBC driver**: `io.trino:trino-jdbc` (Maven Central). Main class `io.trino.jdbc.TrinoDriver`. URL form `jdbc:trino://<host>:8080/<catalog>/<schema>`.
- **Wrapper dispatch signature**: 5 args, mirror SQLSERVER — `(CONNECTION_NAME, IDENTIFIER_CASE_INSENSITIVE, DB_FILTER, SCHEMA_FILTER, TABLE_FILTER)`. Trino 3-tier: catalog (connector instance) → schema → table.
- **Adapter file**: `trino_to_exasol.sql` with `TRINO_TO_EXASOL` script. Pull from `<catalog>.information_schema.columns`. Datatype mapping: standard SQL types pass through; ARRAY/MAP/ROW/JSON → cast to VARCHAR via `CAST(col AS VARCHAR)` on Trino side; UUID/INTERVAL → VARCHAR; HyperLogLog/QDigest/TDigest sketch types → cast to VARCHAR (lossy but no analytic equivalent in Exasol).
- **Docker image**: `trinodb/trino:latest`. Default JDBC 8080. No-auth default. Ready marker: `"======== SERVER STARTED ========"`. Smoke needs to point Trino at a connector with data — easiest is the bundled `memory` connector (Trino-internal in-memory tables), seeded via `trino-cli` Docker.
- **Smoke**: seed via `trinodb/trino` itself (`docker exec ... trino --catalog memory --schema default --execute "CREATE TABLE smoke ..."`). Wrapper call uses catalog `memory` as DB_FILTER, schema `default` as SCHEMA_FILTER.
- **Architectural caveat to document**: same as Dremio. Trino "tables" are views over downstream connector tables. Migration perf depends on the connector — fast for `memory`/`mysql`/`postgresql` connectors, slow for `hive` cold queries. Document.
- **Test plan**: `test/test_trino_to_exasol.lua` covering ARRAY/MAP/ROW VARCHAR casts, JSON cast, catalog/schema 3-tier dispatch, HLL/QDigest fallback.

## Shared infrastructure changes
- `migrate_to_exasol.sql` source-name alias map (around current line 142 `elseif source == 'SAP_HANA' or source == 'SAPHANA' then`): add `'CLICKHOUSE'`, `'STARROCKS'`, `'DUCKDB'`, `'DREMIO'`, `'TRINO'` as canonical names (no aliases needed; these names are already unambiguous). PrestoDB legacy: add `'PRESTO'` → `'TRINO'` alias since PrestoDB and Trino share JDBC interface lineage.
- `migrate_to_exasol.sql` dispatch block (around current line 320+): five new `elseif source == '...' then` branches following appropriate template (MYSQL for DuckDB/StarRocks/ClickHouse — 4 args; SQLSERVER for Dremio/Trino — 5 args with DB_FILTER).
- `_reference/live_smoke.py` `SOURCES` dict: entries that fit the container model (StarRocks, ClickHouse, Trino). DuckDB and Dremio get standalone scripts in `_reference/live_<source>.py` (DuckDB because it's file-based; Dremio because bootstrap is too involved for SourceSmoke's lifecycle).
- `drivers/jdbc/manifest.md`: five new entries with driver versions and download sources. Note: Dremio driver lives on Dremio's Maven repo (`https://maven.dremio.com/free/`), not Central.

## Verification plan per source
Each follow-up PR includes:
1. Lua unit test file (test_<source>_to_exasol.lua) — datatype + quoting coverage.
2. Runtime mock smoke entry in `test/test_migrate_to_exasol_runtime.py` — proves wrapper dispatch.
3. Live smoke run via `_reference/live_smoke.py <source>` against local Docker container — proves end-to-end JDBC + IMPORT.
4. Update `specs/_plans/<plan>/verification-report.md` with PASS/FAIL evidence including row counts.

## Driver staging order
1. DuckDB JDBC into `/exa/jdbc/DUCKDB/` (~5 MB jar).
2. StarRocks reuses MARIADB driver (no new staging needed) OR new `/exa/jdbc/STARROCKS/` symlink pattern (decide during impl).
3. ClickHouse uber-jar into `/exa/jdbc/CLICKHOUSE/` (~30 MB jar).

## Open questions
- Should StarRocks reuse the MARIADB driver dir (cleaner, no duplicate jar) or get its own `/exa/jdbc/STARROCKS/` for clarity in `EXA_DRIVER_LOG`? Lean toward separate dir for clarity — driver dirs are nominally per-source-DB-product.
- ClickHouse Decimal128/256 precision overflow: cast to `VARCHAR` (lossless string, no math) or `DECIMAL(36, scale)` with documented truncation? Lean toward `VARCHAR` cast since arithmetic on these in Exasol post-migration is unlikely.
- ClickHouse cluster mode (replicated tables `ReplicatedMergeTree`): for live smoke, single-node is sufficient; cluster validation is a separate follow-up.
- DuckDB ingest of large files: the Nano container path access pattern (`docker cp` then file URL) limits us to small smoke loads. Production users will want HTTPFS or S3 file-URL ingest — defer to a v2.

## Effort estimate
- DuckDB: 2-4 hours (smallest type space, simplest smoke) — **DONE** locally on branch `feat/duckdb-source-adapter` (commit `406abbf`).
- StarRocks: 4-6 hours (MySQL-compat lets us start from `mysql_to_exasol.sql`; extra time for SR-specific types) — **DONE** and **live-verified** on branch `feat/starrocks-source-adapter` (commits `7d41968` + `da7f3c5`). Live smoke executed against Frankfurt EC2 (`starrocks/allin1-ubuntu` is amd64-only and SIGSEGVs under qemu on Apple Silicon, so EC2 stand-in).
- ClickHouse: 4-6 hours (largest type-mapping surface) — **DONE** and **live-verified** on branch `feat/clickhouse-source-adapter` (commit `ea0f6c8`). Local live smoke against `clickhouse/clickhouse-server:latest` (arm64 native). Seeded via HTTP POSTs through `curlimages/curl` because the `clickhouse/clickhouse-client` image is amd64-only and segfaults under qemu on Apple Silicon. JDBC: `clickhouse-jdbc-0.9.8-all-dependencies.jar` (the plain `-all` variant does not bundle SLF4J).
- Dremio: 4-6 hours (3-tier dispatch + Arrow-style types + bootstrap-heavy live smoke).
- Trino: 4-6 hours (3-tier dispatch + standard SQL types + `memory` connector smoke).
- Combined remaining (StarRocks + ClickHouse + Dremio + Trino): ~2-3 days of focused work.

## Build trigger
After PR #42 is reviewed and merged:
1. Rebase `feat/duckdb-source-adapter` onto fresh upstream `master`, push, open PR #43.
2. Switch to Haiku model for the mechanical adapter + test wiring on subsequent sources.
3. Ship PRs in build-order sequence (StarRocks → ClickHouse → Dremio → Trino), one branch per source for reviewability.
