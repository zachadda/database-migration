# Feature: parallel-split-dispatcher (delta: BETWEEN bucket math)

This delta pins down how `transform_for_split` builds the `WHERE` clause for the `PK_RANGE` and `UNIQUE_NUM` strategies. The recorded spec already mandates `WHERE "pk" BETWEEN lo AND hi`; this delta specifies the bucket math, last-bucket inclusivity, edge cases (degenerate range, NULL PK rows, range smaller than `N`), and the MOD fallback contract when `src_pk_min` or `src_pk_max` is NULL.

## Background

* Bucket math (when both `src_pk_min` and `src_pk_max` are populated):
  * `min = src_pk_min`, `max = src_pk_max`, `N = PARALLEL_EFFECTIVE` (resolved per `parallel-auto-ceiling`).
  * `width = ceil((max - min + 1) / N)`.
  * For `k` in `0..N-1`: `lo_k = min + k*width`, `hi_k = min(min + (k+1)*width - 1, max)`.
  * The last bucket (`k = N-1`) MUST always extend to `max` inclusive (cover any rows beyond the last full bucket).
  * Bucket `k` is emitted only if `lo_k <= max`. Buckets beyond `max` MUST be elided (not emitted as a STATEMENT clause).
* NULL PK rows: bucket `k = 0` MUST append `OR "pk" IS NULL` to its WHERE clause so rows with a NULL PK still ship.
* Degenerate range (`min == max`): only `k = 0` SHALL emit, with `WHERE "pk" BETWEEN min AND max OR "pk" IS NULL`. `PARALLEL_EFFECTIVE` SHALL be `1`. An `INFO` audit row SHALL note the degenerate range.
* Range smaller than `N` (`max - min + 1 < N`): only `(max - min + 1)` buckets emit; remaining are elided. `PARALLEL_EFFECTIVE` equals the number of emitted buckets.
* MOD fallback: when EITHER `src_pk_min` or `src_pk_max` is NULL, `build_where_for_split` MUST fall back to the dialect's existing `pk_where(col, N, K)` MOD builder. This keeps every source that cannot supply min/max (BigQuery, Snowflake on cold tables, sources without a numeric PK) working with the v1 behavior — no regression — and is the only path that lets new sources opt into BETWEEN by extending their per-source metadata SQL.
* Identifier quoting in `BETWEEN` is dialect-specific and emitted by the new per-dialect `pk_between(col, lo, hi)` builder:
  * POSTGRES / SQLSERVER (legacy `"col"` quoting) / ORACLE / DB2 / SNOWFLAKE / REDSHIFT / VERTICA / HANA / NETEZZA / TERADATA: `"col" BETWEEN lo AND hi`
  * MYSQL / MARIADB: `` `col` BETWEEN lo AND hi ``
  * SQLSERVER / AZURE_SQL (bracket form): `[col] BETWEEN lo AND hi`
  * DATABRICKS: backtick form (`` `col` ``)
  * BIGQUERY: backtick form (`` `col` ``)
* The decision object returned by `pick_split_strategy` for `PK_RANGE` or `UNIQUE_NUM` gains two optional fields `lo` and `hi` carrying the cache values when present.

## Scenarios

### Scenario: PK_RANGE with min/max emits BETWEEN buckets with last bucket inclusive

* *GIVEN* an adapter emits a single-statement IMPORT for `SMOKE.ORDERS`
* *AND* the metadata cache reports `src_rows = 4000000`, `src_pk_col = 'ID'`, `src_pk_type = 'INT4'`, `src_pk_min = 1`, `src_pk_max = 4000000`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL rewrite the IMPORT into exactly 4 `statement '...'` clauses
* *AND* the four clauses' inner SELECTs MUST AND with `"ID" BETWEEN 1 AND 1000000`, `"ID" BETWEEN 1000001 AND 2000000`, `"ID" BETWEEN 2000001 AND 3000000`, `"ID" BETWEEN 3000001 AND 4000000` respectively
* *AND* the `k = 0` clause MUST additionally OR with `"ID" IS NULL`
* *AND* the last clause's upper bound MUST be exactly `4000000` (the cached `src_pk_max`)

### Scenario: PK_RANGE width rounds up so last bucket covers the tail

* *GIVEN* an adapter emits a single-statement IMPORT for `SMOKE.LEDGER`
* *AND* the metadata cache reports `src_pk_col = 'ID'`, `src_pk_min = 1`, `src_pk_max = 10`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=3;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 3 `statement '...'` clauses
* *AND* the three buckets MUST be `"ID" BETWEEN 1 AND 4`, `"ID" BETWEEN 5 AND 8`, `"ID" BETWEEN 9 AND 10`
* *AND* `PARALLEL_EFFECTIVE` in the audit row SHALL be `3`

### Scenario: Degenerate range emits one bucket and INFO row

* *GIVEN* an adapter emits a single-statement IMPORT for `SMOKE.SINGLETON`
* *AND* the metadata cache reports `src_pk_col = 'ID'`, `src_pk_min = 42`, `src_pk_max = 42`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit exactly 1 `statement '...'` clause carrying `"ID" BETWEEN 42 AND 42 OR "ID" IS NULL`
* *AND* `PARALLEL_EFFECTIVE` in the audit row SHALL be `1`
* *AND* an `INFO` audit row SHALL be emitted noting that `SMOKE.SINGLETON` has a degenerate PK range

### Scenario: Range smaller than N elides empty buckets

* *GIVEN* an adapter emits a single-statement IMPORT for `SMOKE.TINY`
* *AND* the metadata cache reports `src_pk_col = 'ID'`, `src_pk_min = 1`, `src_pk_max = 2`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 2 `statement '...'` clauses (`"ID" BETWEEN 1 AND 1 OR "ID" IS NULL`, `"ID" BETWEEN 2 AND 2`)
* *AND* `PARALLEL_EFFECTIVE` in the audit row SHALL be `2`

### Scenario: MOD fallback when src_pk_min is NULL

* *GIVEN* an adapter emits a single-statement IMPORT for `SMOKE.BIGQUERY_T`
* *AND* the metadata cache reports `src_pk_col = 'ID'`, `src_pk_type = 'INT64'`, `src_pk_min = NULL`, `src_pk_max = NULL`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `BIGQUERY`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 4 `statement '...'` clauses, each carrying `MOD(\`ID\`, 4) = k` for `k` in `{0,1,2,3}` (BigQuery backtick quoting via the v1 `pk_where` builder)
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'PK_RANGE'`, `SPLIT_KEY = 'ID'`, `PARALLEL_EFFECTIVE = 4`
* *AND* an `INFO` audit row SHALL note that BETWEEN bounds were unavailable and MOD fallback was used

### Scenario: MySQL backtick quoting in BETWEEN

* *GIVEN* an adapter emits a single-statement IMPORT for `app.orders`
* *AND* the metadata cache reports `src_pk_col = 'id'`, `src_pk_min = 1`, `src_pk_max = 100`
* *AND* the source type is `MYSQL`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the two emitted `statement '...'` clauses MUST carry `` `id` BETWEEN 1 AND 50 `` and `` `id` BETWEEN 51 AND 100 ``
* *AND* the `k = 0` clause MUST additionally OR with `` `id` IS NULL ``

### Scenario: SQL Server bracket quoting in BETWEEN

* *GIVEN* an adapter emits a single-statement IMPORT for `dbo.Orders`
* *AND* the metadata cache reports `src_pk_col = 'Id'`, `src_pk_min = 1`, `src_pk_max = 100`
* *AND* the source type is `SQLSERVER`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the two emitted `statement '...'` clauses MUST carry `[Id] BETWEEN 1 AND 50` and `[Id] BETWEEN 51 AND 100`

### Scenario: PARALLEL_SPLIT=PK with min/max still honors BETWEEN

* *GIVEN* `OPTIONS` contains `PARALLEL_SPLIT=PK;PARALLEL_STATEMENTS=4`
* *AND* the metadata cache reports a numeric PK plus min/max for the table
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the forced PK directive SHALL produce BETWEEN buckets per the auto path (forced directives use the same builder)

### Scenario: PARALLEL_SPLIT=PK with NULL min/max falls back to MOD without raising

* *GIVEN* `OPTIONS` contains `PARALLEL_SPLIT=PK;PARALLEL_STATEMENTS=4`
* *AND* the metadata cache reports a numeric PK but NULL `src_pk_min` / `src_pk_max`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the forced PK directive SHALL still rewrite the IMPORT (no soft-fail) using the dialect's MOD `pk_where` builder
* *AND* an `INFO` audit row SHALL note the fallback
