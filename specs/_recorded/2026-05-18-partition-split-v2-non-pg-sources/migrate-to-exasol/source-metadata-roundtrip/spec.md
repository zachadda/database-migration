# Feature: source-metadata-roundtrip (delta: SQL Server partition discovery + non-PG cast hardening)

This delta extends the cache column `src_partitions VARCHAR(2000000)` — introduced by `2026-05-18-partition-split-v2` for POSTGRES only — to populate from real SQL Server catalog views, and hardens the bare-`NULL` placeholders for `src_partitioned` and `src_partitions` in the ORACLE, VERTICA, and DATABRICKS templates so the JDBC outer-schema cast invariant is preserved across the metadata round-trip. The cast hardening is a defensive prerequisite: those three sources still resolve to `NULL` semantically, but via explicit casts to the outer-declared types, eliminating the latent `ETL-1202 → silent splitter death` path the moment any of them is exercised against a real source.

## Background

* All scenarios use `MIGRATE_TO_EXASOL` as the entry point.
* The 15-column cache schema from `2026-05-18-partition-split-v2` is the baseline; this delta does not change column count, only what cols 14 (`src_partitioned BOOLEAN`) and 15 (`src_partitions VARCHAR(2000000)`) resolve to per source.
* The outer IMPORT schema in `transform_for_metadata` declares col 14 as `boolean` and col 15 as `varchar(2000000)`. The JDBC outer-schema cast invariant requires every per-source template to cast both columns to types JDBC accepts as boolean / varchar(2000000), or the inner IMPORT aborts with `ETL-1202` and the metadata phase silently returns `available = false` for that migration.
* `STRING_AGG` is available in SQL Server 2017+ and the `mcr.microsoft.com/azure-sql-edge:latest` smoke image, so the SQLSERVER partition aggregation can run inside the single metadata round-trip without a side channel.
* `DIALECT_BY_SOURCE.SQLSERVER.partition_predicate` already returns `p.predicate` verbatim from the recorded plan `2026-05-18-partition-split-v2`; this delta does not modify the dispatcher Lua at all.
* `SOURCE_METADATA_BY_SOURCE.AZURE_SQL = SOURCE_METADATA_BY_SOURCE.SQLSERVER` per `migrate_to_exasol.sql` line 442, so every SQLSERVER scenario below applies unchanged to AZURE_SQL.

## Scenarios

<!-- DELTA:NEW -->
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
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server table without partition function emits src_partitions = NULL

* *GIVEN* the source type is `SQLSERVER`
* *AND* `dbo.big_t` is a heap or clustered-index table with no partition function attached (i.e. all rows live in `partition_number = 1`)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `dbo.big_t` SHALL carry `src_partitioned = FALSE`
* *AND* `src_partitions` SHALL be `NULL`
* *AND* the AUTO split hierarchy SHALL fall through to PK_RANGE per the existing `parallel-split-dispatcher` contract
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server multi-column partition function soft-fails to NULL

* *GIVEN* the source type is `SQLSERVER`
* *AND* `dbo.multi_part_t` is partitioned by a function whose `sys.partition_parameters` lists two or more columns
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `dbo.multi_part_t` SHALL carry `src_partitions = NULL`
* *AND* the metadata round-trip MUST succeed
* *AND* an `INFO` audit row MAY be emitted noting that multi-column partition functions are out of v2 scope; emission of the INFO row is OPTIONAL because multi-column partitioning is rare and the fall-through to PK_RANGE is a benign optimization downgrade
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server STRING_AGG aggregation runs in one metadata round-trip

* *GIVEN* the source type is `SQLSERVER`
* *AND* an adapter emits five IMPORTs covering five distinct source tables, two of which are partitioned
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one `IMPORT FROM JDBC at <CONN> statement '...'` against the source for metadata gathering
* *AND* the per-table `src_partitions` JSON for each of the two partitioned tables SHALL be produced inside that single query via `STRING_AGG` aggregation over `sys.partitions` / `sys.partition_functions` / `sys.partition_parameters` / `sys.index_columns`
* *AND* no side-channel `IMPORT FROM JDBC at <CONN> statement '...'` SHALL be issued for partition discovery
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: ORACLE template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `ORACLE`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14, BOOLEAN) or `src_partitions` (col 15, VARCHAR(2000000))
* *AND* the SQL string SHALL contain explicit `cast(NULL as boolean)` (or an equivalent ORACLE-portable cast that the JDBC type-resolver accepts as BOOLEAN-typed, e.g. `cast(0 as number(1))` if BOOLEAN is unsupported by the driver) at col 14's position
* *AND* the SQL string SHALL contain explicit `cast(NULL as varchar2(4000))` (the widest portable Oracle string type, widened to `varchar(2000000)` by the outer schema) at col 15's position
* *AND* `src_partitioned` SHALL still resolve to `NULL` / `FALSE` and `src_partitions` SHALL still resolve to `NULL` for every cache row — this delta does NOT yet populate the values, only fixes the cast
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: VERTICA template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `VERTICA`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14) or `src_partitions` (col 15)
* *AND* the SQL string SHALL contain `cast(NULL as boolean)` at col 14's position
* *AND* the SQL string SHALL contain `cast(NULL as varchar(2000000))` at col 15's position
* *AND* `src_partitioned` SHALL still resolve to `NULL` and `src_partitions` SHALL still resolve to `NULL` for every cache row
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: DATABRICKS template cast-hardens src_partitioned + src_partitions

* *GIVEN* the source type is `DATABRICKS`
* *AND* the adapter emits at least one IMPORT
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the SQL string sent inside the metadata `IMPORT FROM JDBC at <CONN> statement '...'` MUST NOT contain a bare `NULL` literal at the column positions corresponding to outer-schema columns `src_partitioned` (col 14) or `src_partitions` (col 15)
* *AND* the SQL string SHALL contain `cast(NULL as boolean)` at col 14's position
* *AND* the SQL string SHALL contain `cast(NULL as string)` at col 15's position (Databricks SQL's widest string type; widens to `varchar(2000000)` via the outer schema)
* *AND* `src_partitioned` SHALL still resolve to `NULL` and `src_partitions` SHALL still resolve to `NULL` for every cache row
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: Cast hardening preserves no-regression in tier-0 + BETWEEN paths

* *GIVEN* the source type is `MYSQL` (already cast-safe per the 2026-05-18 tier-0 cast fix)
* *AND* a live smoke fixture exercising the BETWEEN-based PK_RANGE bucket emission
* *WHEN* `_reference/smoke_parallel_split_mysql.py` is executed
* *THEN* every `SPLIT_STRATEGY` value SHALL match the pre-delta baseline byte-for-byte
* *AND* the `available` field of the metadata cache SHALL remain `TRUE` for every cache row (no ETL-1202 regression)
<!-- /DELTA:NEW -->
