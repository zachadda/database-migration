# Feature: source-metadata-roundtrip (delta: native partition list)

This delta adds one cache column — `src_partitions VARCHAR(2000000)` — carrying a JSON-encoded array of `{name, predicate}` objects when the source table is natively partitioned. Sources that cannot cheaply enumerate partitions (or where the table is not partitioned) return NULL. Cache schema grows by one column (the exact column count after this delta depends on whether items 2 and 3 have shipped first).

## Background

* `src_partitions` is a string-encoded JSON array. Each element MUST be of the form `{"name":"<partition name>","predicate":"<dialect-specific SQL fragment>"}`. The fragment is concatenated as-is into the STATEMENT's inner SELECT `WHERE` clause; the dispatcher MUST NOT re-quote it.
* If a source table is not partitioned, `src_partitions` MUST be NULL (not an empty array).
* If a source supports partitioning but the per-source SQL cannot cheaply enumerate it (catalog permission denied, partition count exceeds `VARCHAR(2000000)`), the SQL MUST return NULL and an `INFO` audit row MUST be emitted per the soft-fail contract.
* Per-source dialects in v2 scope: `POSTGRES` (declarative partitioning via `pg_inherits`), `ORACLE` (`all_tab_partitions`), `SQLSERVER` (`sys.partitions`), `BIGQUERY` (`INFORMATION_SCHEMA.PARTITIONS`), `VERTICA` (`partitions` system view), `DATABRICKS` (`SHOW PARTITIONS` via a separate IMPORT FROM JDBC fallback when the metadata round-trip cannot inline it).
* Sources NOT in v2 scope (MYSQL, REDSHIFT, SNOWFLAKE, DB2, HANA, NETEZZA, TERADATA, MARIADB) MUST return `src_partitions = NULL` and the splitter falls through to subsequent hierarchy steps.
* The metadata round-trip remains one `IMPORT FROM JDBC` per migration for sources where partition discovery can be inlined. Databricks may issue one extra `IMPORT FROM JDBC at <CONN> statement 'SHOW PARTITIONS ...'` per source table whose `src_partitioned = TRUE`; this extra round-trip is counted as part of the metadata phase and MUST run before `transform_for_gate` / `transform_for_split` fire.

## Scenarios

### Scenario: Postgres declarative partitioned table populates src_partitions

* *GIVEN* the source type is `POSTGRES`
* *AND* the source `PUB.LOGS` is declared `PARTITION BY RANGE (ts)` with quarterly child tables `LOGS_2026Q1`, `LOGS_2026Q2`, `LOGS_2026Q3`, `LOGS_2026Q4`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `PUB.LOGS` SHALL carry `src_partitioned = TRUE`
* *AND* `src_partitions` SHALL be a JSON array of exactly 4 objects, each with `name` matching a child table and `predicate` carrying `tableoid::regclass = '<name>'::regclass`

### Scenario: Non-partitioned table emits src_partitions = NULL

* *GIVEN* the source type is `POSTGRES`
* *AND* `PUB.ORDERS` is a plain non-partitioned table
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry `src_partitions = NULL`
* *AND* `src_partitioned` SHALL be `FALSE`

### Scenario: Sources outside v2 scope return NULL without raising

* *GIVEN* the source type is `MYSQL`
* *AND* the source has user-defined partitions
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry `src_partitions = NULL`
* *AND* the metadata round-trip MUST succeed
* *AND* the dispatcher MAY skip emitting an INFO row for out-of-scope sources

### Scenario: Permission denied on partition catalog yields NULL + INFO row

* *GIVEN* the source type is `ORACLE`
* *AND* the migration user lacks `SELECT` on `ALL_TAB_PARTITIONS` for `SCHEMA_X.T`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `SCHEMA_X.T` SHALL carry `src_partitions = NULL`
* *AND* the metadata round-trip MUST succeed
* *AND* an `INFO` audit row SHALL be emitted noting partition discovery failure for `SCHEMA_X.T`

### Scenario: Databricks side-channel SHOW PARTITIONS round-trip

* *GIVEN* the source type is `DATABRICKS`
* *AND* `RAW.EVENTS` is `PARTITIONED BY (event_date DATE)`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata phase SHALL issue one main `IMPORT FROM JDBC` carrying `src_partitioned` per the existing contract
* *AND* the metadata phase MAY issue one additional `IMPORT FROM JDBC at <CONN> statement 'SHOW PARTITIONS RAW.EVENTS'` per partitioned source table to populate `src_partitions`
* *AND* both round-trips MUST complete before `transform_for_gate` / `transform_for_split` see the cache
