# Feature: source-metadata-roundtrip (delta: PK min/max columns)

This delta extends the shared per-table metadata cache with two new columns — `src_pk_min` and `src_pk_max` — so that `transform_for_split` can produce `BETWEEN`-based bucket selectors instead of `MOD`. The cache schema grows from 8 columns to 10. Sources that can cheaply compute the min/max of the discovered numeric PK column populate them; sources that cannot return `NULL` and the splitter falls back to MOD without raising.

## Background

* Recorded cache schema is 8 columns: `src_schema`, `src_table`, `src_rows`, `src_pk_col`, `src_pk_type`, `src_date_col`, `src_num_col`, `src_partitioned`. This delta adds `src_pk_min DECIMAL(36,0)` and `src_pk_max DECIMAL(36,0)`, inserted **after `src_pk_type` and before `src_date_col`** in the outer SQL `import into (...)` column list.
* The metadata round-trip remains a single `IMPORT FROM JDBC at <CONN> statement '...'` per migration.
* Each per-source SQL template in `SOURCE_METADATA_BY_SOURCE` MUST return the 10-column shape. Sources where the same template already discovers a numeric singleton PK column (Postgres, MySQL, MariaDB, SQL Server, Azure SQL, Snowflake, Redshift, Vertica, Oracle, DB2, HANA, Netezza, Teradata, Databricks) extend the template with two correlated subqueries against the discovered column. Per-source SQL is the only place that knows how to quote the column name and which catalog table identifies it.
* When the per-source PK discovery returns NULL (no PK, non-numeric PK, composite PK), the same row's `src_pk_min` and `src_pk_max` MUST be NULL. The per-source SQL MUST NOT raise.
* When a source CAN discover a numeric singleton PK but CANNOT cheaply compute its min/max (BigQuery cost-per-query, Snowflake warehouse credit, Databricks Photon scan), the per-source SQL MUST return NULL for `src_pk_min`/`src_pk_max`. The splitter MUST treat NULL min/max as a directive to fall back to its existing MOD-based bucket builder.
* Cache rows where the min/max correlated subquery itself errors MUST NOT fail the whole metadata round-trip. The per-source SQL SHALL guard the subqueries with a `try / nullif / coalesce` pattern appropriate to the source dialect; on any per-row failure the row is returned with `src_pk_min = NULL, src_pk_max = NULL` and the rest of the cache is unaffected.

## Scenarios

### Scenario: Cache schema is 10 columns when PK min/max are available

* *GIVEN* the source type is `POSTGRES`
* *AND* the source `PUBLIC.ORDERS` declares a single-column numeric primary key `ID` with value range `1..4_000_000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed with `OPTIONS = 'PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4'`
* *THEN* the metadata round-trip SHALL emit one `IMPORT FROM JDBC` statement with a 10-column `import into (...)` target
* *AND* the cache row for `PUBLIC.ORDERS` MUST carry `src_pk_col = 'ID'`, `src_pk_type = 'INT4'` (or equivalent), `src_pk_min = 1`, `src_pk_max = 4000000`
* *AND* the column order MUST be `src_schema, src_table, src_rows, src_pk_col, src_pk_type, src_pk_min, src_pk_max, src_date_col, src_num_col, src_partitioned`

### Scenario: Sources without numeric PK populate min/max with NULL

* *GIVEN* the source type is `SNOWFLAKE`
* *AND* the source `PUB.HEAP_T` has no primary key
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `PUB.HEAP_T` SHALL carry `src_pk_col = NULL, src_pk_type = NULL, src_pk_min = NULL, src_pk_max = NULL`
* *AND* the per-source SQL MUST NOT raise

### Scenario: Sources that decline to compute min/max populate them with NULL without failing

* *GIVEN* the source type is `BIGQUERY`
* *AND* the per-source SQL template chooses NOT to compute `MIN(ID)` / `MAX(ID)` because each correlated subquery would scan a billed partitioned table
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for the BigQuery table SHALL carry `src_pk_col`, `src_pk_type`, and `src_rows` populated as before
* *AND* both `src_pk_min` and `src_pk_max` SHALL be NULL
* *AND* the splitter MUST fall back to its existing MOD-based bucket builder for that row

### Scenario: Per-row min/max failure does not fail the round-trip

* *GIVEN* two source tables `OK_T` and `BAD_T` in one migration
* *AND* the per-source SQL's min/max correlated subquery succeeds for `OK_T` and raises for `BAD_T` (e.g. permission denied on `BAD_T`)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `OK_T` SHALL carry `src_pk_min` + `src_pk_max` populated
* *AND* the cache row for `BAD_T` SHALL carry `src_pk_min = NULL, src_pk_max = NULL`
* *AND* the round-trip itself MUST succeed (no exception bubbled out of `transform_for_metadata`)
* *AND* an `INFO` audit row MUST be emitted naming `BAD_T` and the per-row reason

### Scenario: Cache lifetime unchanged — one round-trip per migration

* *GIVEN* an adapter emits five IMPORTs covering five distinct source tables
* *AND* three of the five tables have a numeric singleton PK and two do not
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one metadata `IMPORT FROM JDBC` against the source
* *AND* the returned cache MUST contain all five rows with appropriate min/max fill (three populated, two NULL)
* *AND* the dispatcher MUST NOT issue any second source-side query to compute min/max separately
