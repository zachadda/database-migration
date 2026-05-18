# Feature: source-metadata-roundtrip (delta: numeric singleton unique-index columns)

This delta adds four cache columns covering a numeric singleton unique-index column when no PK is declared on the source table: `src_unique_num_col`, `src_unique_num_type`, `src_unique_num_min`, `src_unique_num_max`. The cache schema grows from 10 (after `pk-range-between-pushdown` lands) to 14 columns. Per-source SQL templates that can cheaply identify a non-PK unique index populate them; sources that cannot return NULL and the strategy hierarchy walks past `UNIQUE_NUM` without raising.

## Background

* Cache schema (post-item-2) is 10 columns. This delta inserts four new columns **between `src_pk_max` and `src_date_col`** in the outer SQL `import into (...)` column list.
* Final post-delta order: `src_schema, src_table, src_rows, src_pk_col, src_pk_type, src_pk_min, src_pk_max, src_unique_num_col, src_unique_num_type, src_unique_num_min, src_unique_num_max, src_date_col, src_num_col, src_partitioned`.
* `src_unique_num_col` MUST be populated only when a single-column unique index exists, the indexed column is of a numeric type satisfying `is_numeric_pk_type`, and the column is NOT the primary key. If multiple unique indexes qualify, the first by deterministic catalog order is chosen (e.g. lowest index OID for Postgres). If none qualify the column is NULL.
* `src_unique_num_min` / `src_unique_num_max` follow the same NULL-fallback contract as `src_pk_min` / `src_pk_max` from `pk-range-between-pushdown`: sources that cannot cheaply compute the min/max MAY return NULL and the splitter MUST fall back to MOD.
* Round-trip remains exactly one `IMPORT FROM JDBC` per migration. Per-source SQL is responsible for emitting the four new columns inline.
* Sources where the catalog cannot expose unique-index column lists efficiently (SNOWFLAKE, DATABRICKS, BIGQUERY) return NULL for all four columns. The splitter walks past UNIQUE_NUM to DATE_BUCKET / HASH_NUM / ROWID exactly as it does today.

## Scenarios

### Scenario: Cache exposes unique-index column when PK is absent

* *GIVEN* the source type is `POSTGRES`
* *AND* the source `PUB.LEGACY_ORDERS` has no primary key
* *AND* `PUB.LEGACY_ORDERS` has a single-column `UNIQUE` index on `LEGACY_ID INTEGER` with value range `1..2_000_000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row for `PUB.LEGACY_ORDERS` SHALL carry `src_pk_col = NULL`, `src_unique_num_col = 'LEGACY_ID'`, `src_unique_num_type = 'INT4'`, `src_unique_num_min = 1`, `src_unique_num_max = 2000000`

### Scenario: PK takes precedence over unique index

* *GIVEN* the source type is `POSTGRES`
* *AND* the source `PUB.ORDERS` has a numeric PK `ID` AND a separate unique index on `BUSINESS_KEY`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry `src_pk_col = 'ID'` with min/max populated
* *AND* `src_unique_num_col` SHALL ALSO be populated (the cache is descriptive, not prescriptive — `pick_split_strategy` chooses)

### Scenario: Composite unique index is ignored

* *GIVEN* the source type is `MYSQL`
* *AND* the source has no PK but a unique index on `(tenant_id, customer_id)`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry `src_unique_num_col = NULL` and `src_unique_num_min = NULL` and `src_unique_num_max = NULL`

### Scenario: Non-numeric unique index is ignored

* *GIVEN* the source type is `POSTGRES`
* *AND* the source has no PK but a unique index on `email VARCHAR(254)`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry `src_unique_num_col = NULL`

### Scenario: Sources without catalog visibility return all NULL

* *GIVEN* the source type is `SNOWFLAKE`
* *AND* the source `PUB.HEAP_T` has no PK
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the cache row SHALL carry NULL for all four `src_unique_num_*` columns
* *AND* the per-source SQL MUST NOT raise

### Scenario: Cache lifetime unchanged — still one round-trip per migration

* *GIVEN* an adapter emits five IMPORTs covering five distinct tables
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* exactly one metadata `IMPORT FROM JDBC` SHALL fire
* *AND* the returned cache MUST contain all five rows with the 14-column schema
