# Feature: source-metadata-roundtrip (delta: BigQuery per-dataset fan-out)

This delta introduces a new dispatch shape `kind = 'per_dataset'` in `SOURCE_METADATA_BY_SOURCE`. For sources whose `INFORMATION_SCHEMA` (or equivalent) is dataset-scoped (BigQuery), the metadata round-trip fans out into one `IMPORT FROM JDBC` per distinct source dataset present in the adapter-emitted IMPORTs. Results are merged into the same per-table cache the rest of the pipeline reads. All other sources retain the v1 single-round-trip dispatch shape (`kind = 'shared'`).

## Background

* `SOURCE_METADATA_BY_SOURCE.BIGQUERY` becomes an object `{ kind = 'per_dataset', build_sql = function(dataset, table_filters) end }`. The legacy single-string entry shape used by all other sources is now treated as `kind = 'shared'` for backward compatibility.
* `transform_for_metadata` branches on `dispatch.kind`:
  * `kind = 'shared'` (or absent): one `IMPORT FROM JDBC` per migration. Unchanged.
  * `kind = 'per_dataset'`: group adapter IMPORTs by source `schema` (== BigQuery dataset), issue one `IMPORT FROM JDBC at <CONN> statement '...'` per distinct dataset, merge rows into the cache.
* Datasets are derived from the source-side `(schema, table)` pairs parsed out of each adapter IMPORT's inner SELECT, exactly as for the v1 shared dispatch.
* Per-dataset round-trips are issued **sequentially** to keep BQ slot consumption bounded. Sequential ordering is the dataset name's lexicographic order so retries are deterministic.
* If a single dataset's round-trip fails, the dispatcher MUST continue with the remaining datasets, populate the failed dataset's tables with all-NULL cache rows, and emit one `INFO` audit row per failed dataset naming the dataset and the BQ error message. The migration is NOT failed as a whole.
* For a migration that targets a single dataset, the fan-out reduces to exactly one round-trip — no regression versus a shared dispatch.

## Scenarios

### Scenario: Single-dataset BQ migration issues one round-trip

* *GIVEN* the source type is `BIGQUERY`
* *AND* the adapter emits three IMPORTs all in dataset `analytics`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one `IMPORT FROM JDBC at <CONN> statement '...'` for metadata
* *AND* the statement's SQL MUST reference `` `<project>.analytics.INFORMATION_SCHEMA.TABLES` ``
* *AND* the cache MUST contain three rows, one per adapter-emitted table

### Scenario: Three-dataset BQ migration issues three round-trips

* *GIVEN* the source type is `BIGQUERY`
* *AND* the adapter emits IMPORTs across datasets `raw`, `staging`, `analytics`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly three `IMPORT FROM JDBC` statements
* *AND* the three statements MUST be issued in lexicographic dataset order: `analytics`, `raw`, `staging`
* *AND* the cache MUST contain rows from all three datasets merged

### Scenario: Failing one dataset round-trip does not fail the migration

* *GIVEN* the source type is `BIGQUERY`
* *AND* the adapter emits IMPORTs in datasets `ok_ds` and `denied_ds`
* *AND* the BQ user lacks `bigquery.tables.get` on `denied_ds`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the round-trip against `ok_ds` SHALL succeed and populate cache rows for its tables
* *AND* the round-trip against `denied_ds` SHALL emit an `INFO` audit row carrying the BQ error message
* *AND* cache rows for `denied_ds` tables SHALL be all-NULL (apart from `src_schema` + `src_table`)
* *AND* `MIGRATE_TO_EXASOL` MUST NOT raise

### Scenario: Non-BQ sources retain shared dispatch

* *GIVEN* the source type is `POSTGRES`
* *AND* the adapter emits IMPORTs across schemas `public`, `analytics`, `staging`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly one `IMPORT FROM JDBC at <CONN> statement '...'` for metadata (the existing `shared` behavior)
* *AND* the fan-out logic for BIGQUERY MUST NOT alter the Postgres path

### Scenario: BQ dispatch entry exposes dataset-aware SQL builder

* *GIVEN* the developer is editing `SOURCE_METADATA_BY_SOURCE.BIGQUERY`
* *WHEN* the entry is inspected at runtime
* *THEN* it SHALL be an object with `kind = 'per_dataset'`
* *AND* the entry SHALL expose a `build_sql(dataset, table_filters)` function returning a SQL string referencing `<project>.<dataset>.INFORMATION_SCHEMA`
* *AND* the function MUST emit `WHERE table_name IN (...)` to scope to only the tables the migration touches
