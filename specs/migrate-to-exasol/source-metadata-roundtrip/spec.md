# Feature: source-metadata-roundtrip

The dispatcher (`MIGRATE_TO_EXASOL`) batches every per-table fact it needs from the source database into a single `IMPORT FROM JDBC` query per migration. The fetched cache is keyed by source `(schema, table)` and consumed by `transform_for_gate` (Speq 1) and `transform_for_split` (this speq). The round-trip is dispatched off a per-source SQL table (`SOURCE_METADATA_BY_SOURCE`) that supersedes Speq 1's narrower `ROW_COUNT_SQL_BY_SOURCE`. The round-trip is soft-failing: on any error the cache is populated with all-NULL rows, an `INFO` row is emitted, and the migration continues with single-statement IMPORTs.

## Background

* All scenarios use `MIGRATE_TO_EXASOL` as the entry point.
* The cache schema is one row per `(src_schema, src_table)` pair containing:
  * `src_schema   VARCHAR`
  * `src_table    VARCHAR`
  * `src_rows     DECIMAL(36,0)`
  * `src_pk_col   VARCHAR`
  * `src_pk_type  VARCHAR`
  * `src_date_col VARCHAR`
  * `src_num_col  VARCHAR`
  * `src_partitioned BOOLEAN`
* `SOURCE_METADATA_BY_SOURCE` is a Lua dispatch table inside `migrate_to_exasol.sql` keyed by `SOURCE_TYPE` (e.g. `POSTGRES`, `MYSQL`, `SQLSERVER`, `AZURE_SQL`, `SNOWFLAKE`, `BIGQUERY`, `REDSHIFT`, `VERTICA`, `DB2`, `HANA`, `NETEZZA`, `TERADATA`, `DATABRICKS`, `ORACLE`).
* Each entry is a SQL template returning the 8-column schema above. The dispatcher binds the requested `(schema, table)` pairs as an `OR`-of-equality predicate inside one `IMPORT FROM JDBC at <CONN> statement '<SQL>'`.
* Sources that cannot supply a given column (e.g. Databricks cannot supply `src_rows`) MUST return `NULL` for that column; the dispatcher MUST NOT treat the row as a fetch failure.
* `transform_for_metadata` runs before `transform_for_gate` and `transform_for_split`. The gate (Speq 1) reads `src_rows` from this cache instead of issuing its own row-count query; the splitter reads the remaining columns.
* `PARALLEL_ROW_THRESHOLD=0` (Speq 1) disables the gate; it does NOT disable the metadata round-trip — the splitter still needs the cache. `PARALLEL_STATEMENTS=1` AND `PARALLEL_SPLIT=OFF` together disable both consumers; in that case `transform_for_metadata` MUST be skipped to spare the source-side query.
* Source-side `(schema, table)` references are parsed out of each IMPORT's inner SELECT (`from "<schema>"."<table>"`), reusing the helper introduced in Speq 1. Target-side identifiers (`TARGET_SCHEMA`, `IDENTIFIER_CASE_INSENSITIVE`, `CATALOG2SCHEMA`) MUST NOT influence the cache key.

## Scenarios

### Scenario: One round-trip per migration regardless of table count

* *GIVEN* an adapter emits five IMPORTs covering five distinct source tables in one run
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one `IMPORT FROM JDBC at <CONN> statement '...'` against the source for metadata gathering
* *AND* the single query's WHERE clause MUST enumerate all five `(schema, table)` pairs (e.g. via `OR`-of-equality on `(schema_name, table_name)`)

### Scenario: Cache is consumed by both gate and splitter

* *GIVEN* an adapter emits one multi-statement IMPORT for `SMOKE.SMALL_T` and one single-statement IMPORT for `SMOKE.BIG_T`
* *AND* the metadata round-trip returns `src_rows = 500` for `SMOKE.SMALL_T` and `src_rows = 20000000, src_pk_col = 'ID', src_pk_type = 'NUMBER'` for `SMOKE.BIG_T`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* `transform_for_gate` SHALL collapse `SMOKE.SMALL_T`'s IMPORT to a single statement using `src_rows = 500` from the cache
* *AND* `transform_for_split` SHALL rewrite `SMOKE.BIG_T`'s IMPORT into 4 `statement '...'` clauses using `src_pk_col = 'ID'` from the same cache
* *AND* the dispatcher MUST NOT issue a second source-side metadata query

### Scenario: Per-source SQL dispatched from SOURCE_METADATA_BY_SOURCE

* *GIVEN* the source type is `POSTGRES`
* *AND* an adapter emits at least one IMPORT for `PUBLIC.ORDERS`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata round-trip SHALL use the `POSTGRES` entry of `SOURCE_METADATA_BY_SOURCE`
* *AND* the per-source SQL SHALL join `pg_class`, `pg_namespace`, `pg_constraint`, and `pg_attribute` to populate all eight cache columns
* *AND* swapping `SOURCE_TYPE` to `MYSQL` for the same fixture SHALL instead dispatch the `MYSQL` entry (joining `information_schema.tables`, `key_column_usage`, `columns`) without any other code path change

### Scenario: Sources without per-column support return NULL not error

* *GIVEN* the source type is `DATABRICKS`
* *AND* an adapter emits one IMPORT for `MAIN.DEFAULT.EVENTS`
* *AND* the `DATABRICKS` entry of `SOURCE_METADATA_BY_SOURCE` does not expose a per-table row count
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata round-trip MUST complete without raising
* *AND* the cache entry for `MAIN.DEFAULT.EVENTS` SHALL carry `src_rows = NULL`
* *AND* downstream `transform_for_gate` MUST treat NULL `src_rows` per Speq 1 semantics
* *AND* downstream `transform_for_split` MUST skip the splitter for the row (NULL row count → cannot decide threshold eligibility)

### Scenario: Round-trip failure populates all-NULL cache and emits INFO row

* *GIVEN* an adapter emits at least one IMPORT
* *AND* the metadata round-trip fails (network error, missing privilege, or unsupported metadata view)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT raise the migration as failed solely because of the round-trip failure
* *AND* the dispatcher SHALL populate the cache with all-NULL rows for every requested `(schema, table)` pair
* *AND* the dispatcher SHALL emit one `STEP_KIND = 'INFO'` row describing that source-side metadata fetch was skipped
* *AND* `transform_for_gate` SHALL pass every IMPORT through unchanged
* *AND* `transform_for_split` SHALL pass every IMPORT through unchanged

### Scenario: Source type with no SOURCE_METADATA_BY_SOURCE entry skips fetch

* *GIVEN* `SOURCE_TYPE` resolves to an adapter for which the dispatcher does not ship a metadata SQL (e.g. `EXASOL`, `VECTORWISE`, `S3`)
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue any source-side metadata query
* *AND* the dispatcher SHALL emit one `STEP_KIND = 'INFO'` row noting that the metadata cache is not configured for this source type
* *AND* every emitted IMPORT SHALL pass through `transform_for_gate` and `transform_for_split` unchanged

### Scenario: Adapter emits no IMPORTs at all skips the round-trip

* *GIVEN* an adapter returns only DDL rows (no `IMPORT INTO ...` statements)
* *AND* `OPTIONS` contains a non-zero `PARALLEL_ROW_THRESHOLD`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue any source-side metadata query
* *AND* the dispatcher SHALL pass adapter output through to `normalize_rows` / `execute_generated_sql` unchanged

### Scenario: Cache key uses source identifier not target rename

* *GIVEN* an adapter emits `IMPORT INTO "DST"."ORDERS" (...) from JDBC at SRC statement 'select ... from "PUBLIC"."orders"'` under `OPTIONS = 'TARGET_SCHEMA=DST;PARALLEL_ROW_THRESHOLD=1000000'`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata round-trip's WHERE clause SHALL key on `(PUBLIC, orders)` (the source identifier parsed from the inner SELECT's `from "..."."..."` clause)
* *AND* the target-side identifier `(DST, ORDERS)` MUST NOT appear in the metadata round-trip's WHERE clause

### Scenario: Duplicate source tables in adapter output produce one cache row

* *GIVEN* an adapter emits two IMPORTs both targeting source `PUBLIC.orders` (e.g. one full-table, one filtered subset)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata round-trip's WHERE clause MUST contain `(PUBLIC, orders)` exactly once
* *AND* the cache MUST yield a single row keyed on `(PUBLIC, orders)`
* *AND* both downstream IMPORTs MUST resolve to the same cache entry

### Scenario: Per-source SQL is a pure dispatch lookup, not a code branch

* *GIVEN* a new source type `<NEW_SRC>` is added to `SOURCE_METADATA_BY_SOURCE` with a SQL template returning the 8-column schema
* *AND* no other change is made to `migrate_to_exasol.sql`
* *AND* no `<new_src>_to_exasol.sql` adapter file is modified
* *WHEN* `MIGRATE_TO_EXASOL` is executed against the new source
* *THEN* `transform_for_metadata` SHALL dispatch the new SQL successfully via the table lookup
* *AND* `transform_for_gate` and `transform_for_split` SHALL consume the resulting cache without any source-specific branching

### Scenario: Splitter + gate both disabled skips the round-trip

* *GIVEN* an adapter emits at least one IMPORT
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=1;PARALLEL_SPLIT=OFF`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue any source-side metadata query
* *AND* every emitted IMPORT SHALL pass through unchanged
* *AND* the audit rows SHALL carry `SPLIT_STRATEGY = 'SINGLE'` and `PARALLEL_EFFECTIVE = 1` for every IMPORT

### Scenario: SQL Server partitioned table populates src_partitions JSON

* *GIVEN* the source type is `SQLSERVER`
* *AND* `dbo.partitioned_t` is created against a partition function `pf_partitioned_t` keyed on numeric column `id` with three range boundaries (`50`, `100`, `150`) producing four non-empty partitions numbered `1` through `4`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `dbo.partitioned_t` SHALL carry `src_partitioned = TRUE`
* *AND* `src_partitions` SHALL be a JSON array of exactly four objects
* *AND* each element SHALL have the shape `{"name":"<partition_number>","predicate":"$partition.<func>([<col>]) = <partition_number>"}`
* *AND* the `<func>` token SHALL be the SQL Server partition function name (`pf_partitioned_t`)
* *AND* the `<col>` token SHALL be the partition column name (`id`)
* *AND* the column SHALL be quoted with `[...]` square brackets per the SQL Server dialect

### Scenario: SQL Server table without partition function emits src_partitions = NULL

* *GIVEN* the source type is `SQLSERVER`
* *AND* `dbo.big_t` is a heap or clustered-index table with no partition function attached (i.e. all rows live in `partition_number = 1`)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `dbo.big_t` SHALL carry `src_partitioned = FALSE`
* *AND* `src_partitions` SHALL be `NULL`
* *AND* the AUTO split hierarchy SHALL fall through to PK_RANGE per the existing `parallel-split-dispatcher` contract

### Scenario: SQL Server multi-column partition function soft-fails to NULL

* *GIVEN* the source type is `SQLSERVER`
* *AND* `dbo.multi_part_t` is partitioned by a function whose `sys.partition_parameters` lists two or more columns
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `dbo.multi_part_t` SHALL carry `src_partitions = NULL`
* *AND* the metadata round-trip MUST succeed
* *AND* an `INFO` audit row MAY be emitted noting that multi-column partition functions are out of v2 scope; emission of the INFO row is OPTIONAL because multi-column partitioning is rare and the fall-through to PK_RANGE is a benign optimization downgrade

### Scenario: SQL Server STRING_AGG aggregation runs in one metadata round-trip

* *GIVEN* the source type is `SQLSERVER`
* *AND* an adapter emits five IMPORTs covering five distinct source tables, two of which are partitioned
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one `IMPORT FROM JDBC at <CONN> statement '...'` against the source for metadata gathering
* *AND* the per-table `src_partitions` JSON for each of the two partitioned tables SHALL be produced inside that single query via `STRING_AGG` aggregation over `sys.partitions` / `sys.partition_functions` / `sys.partition_parameters` / `sys.index_columns`
* *AND* no side-channel `IMPORT FROM JDBC at <CONN> statement '...'` SHALL be issued for partition discovery

### Scenario: ORACLE template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `ORACLE`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14, BOOLEAN) or `src_partitions` (col 15, VARCHAR(2000000))
* *AND* the SQL string SHALL contain explicit `cast(NULL as boolean)` (or an equivalent ORACLE-portable cast that the JDBC type-resolver accepts as BOOLEAN-typed, e.g. `cast(0 as number(1))` if BOOLEAN is unsupported by the driver) at col 14's position
* *AND* the SQL string SHALL contain explicit `cast(NULL as varchar2(4000))` (the widest portable Oracle string type, widened to `varchar(2000000)` by the outer schema) at col 15's position
* *AND* `src_partitioned` SHALL still resolve to `NULL` / `FALSE` and `src_partitions` SHALL still resolve to `NULL` for every cache row — this delta does NOT yet populate the values, only fixes the cast

### Scenario: VERTICA template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `VERTICA`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14) or `src_partitions` (col 15)
* *AND* the SQL string SHALL contain `cast(NULL as boolean)` at col 14's position
* *AND* the SQL string SHALL contain `cast(NULL as varchar(2000000))` at col 15's position
* *AND* `src_partitioned` SHALL still resolve to `NULL` and `src_partitions` SHALL still resolve to `NULL` for every cache row

### Scenario: DATABRICKS template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `DATABRICKS`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14) or `src_partitions` (col 15)
* *AND* the SQL string SHALL contain `cast(NULL as boolean)` at col 14's position
* *AND* the SQL string SHALL contain `cast(NULL as string)` at col 15's position (Databricks SQL's widest string type; widens to `varchar(2000000)` via the outer schema)
* *AND* `src_partitioned` SHALL still resolve to `NULL` and `src_partitions` SHALL still resolve to `NULL` for every cache row

### Scenario: Cast hardening preserves no-regression in tier-0 + BETWEEN paths

* *GIVEN* the source type is `MYSQL` (already cast-safe per the 2026-05-18 tier-0 cast fix)
* *AND* a live smoke fixture exercising the BETWEEN-based PK_RANGE bucket emission
* *WHEN* `_reference/smoke_parallel_split_mysql.py` is executed
* *THEN* every `SPLIT_STRATEGY` value SHALL match the pre-delta baseline byte-for-byte
* *AND* the `available` field of the metadata cache SHALL remain `TRUE` for every cache row (no ETL-1202 regression)
