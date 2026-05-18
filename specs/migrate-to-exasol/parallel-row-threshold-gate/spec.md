# Feature: parallel-row-threshold-gate

The dispatcher (`MIGRATE_TO_EXASOL`) inspects every IMPORT statement an adapter emits, looks up the source-side row count for the corresponding table, and rewrites multi-statement parallel IMPORTs into single-statement IMPORTs whenever the row count is below a configurable threshold. The gate lives entirely inside `migrate_to_exasol.sql`; adapter scripts are not modified, so any current or future adapter that emits multi-statement parallel IMPORTs benefits automatically.

## Background

* All scenarios use `MIGRATE_TO_EXASOL` as the entry point.
* `PARALLEL_ROW_THRESHOLD` is provided as an `OPTIONS` key (e.g. `OPTIONS = 'PARALLEL_ROW_THRESHOLD=1000000'`). Default value is `1000000`. Value `0` or `NULL` disables the gate entirely.
* A "multi-statement IMPORT" is an `IMPORT INTO ... statement '...' statement '...' ...` form with two or more `statement '...'` clauses. A "single-statement IMPORT" has exactly one.
* The dispatcher already runs the adapter and classifies emitted rows (`STEP_KIND`, `TARGET_OBJ`, etc.); gating is layered as a post-processing pass between adapter return and the existing `normalize_rows` / `execute_generated_sql` paths.
* Source-side row counts are fetched via one `IMPORT FROM JDBC at <CONN> statement '<per-source SQL>'` round-trip for the entire migration. Per-source row-count SQL is selected by `SOURCE_TYPE`.
* The dispatcher parses the source-side `from "SCHEMA"."TABLE"` quoted reference out of an IMPORT's inner SELECT to look up the row count; this is robust to target-side renaming (`TARGET_SCHEMA`, `IDENTIFIER_CASE_INSENSITIVE`, Databricks `CATALOG2SCHEMA`, BigQuery 3-level naming).

## Scenarios

### Scenario: Below-threshold table emits a single statement

* *GIVEN* an adapter emits a 4-way multi-statement parallel IMPORT for source `SMOKE.SMALL_T`
* *AND* the source row-count lookup returns `num_rows = 500000` for `SMOKE.SMALL_T`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL rewrite the IMPORT to retain exactly the first `statement '...'` clause
* *AND* the dispatcher MUST NOT modify the IMPORT's target schema, target table, or column list

### Scenario: At-or-above-threshold table passes through unchanged

* *GIVEN* an adapter that emits a 4-way multi-statement parallel IMPORT for source table `SMOKE.BIG_T`
* *AND* the source `SMOKE.BIG_T` reports `num_rows = 5000000`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL pass the IMPORT through unchanged
* *AND* all four `statement '...'` clauses MUST be preserved in the order the adapter emitted them

### Scenario: Single-statement IMPORT passes through regardless of row count

* *GIVEN* an adapter that emits a single-statement IMPORT (one `statement '...'` clause)
* *AND* `OPTIONS` contains a non-zero `PARALLEL_ROW_THRESHOLD`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL pass the IMPORT through unchanged
* *AND* the dispatcher MUST NOT issue a row-count lookup against the source for that table

### Scenario: NULL row count is treated as below threshold

* *GIVEN* an adapter that emits a multi-statement parallel IMPORT for source table `SMOKE.NO_STATS`
* *AND* the row-count lookup returns `NULL` for `SMOKE.NO_STATS` (no source-side statistics gathered)
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL rewrite the IMPORT to a single statement
* *AND* the dispatcher MUST treat NULL row counts as `0` for threshold comparison

### Scenario: PARALLEL_ROW_THRESHOLD = 0 disables the gate

* *GIVEN* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0`
* *AND* an adapter emits any combination of single- and multi-statement IMPORTs
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue any row-count lookup
* *AND* every emitted IMPORT SHALL pass through unchanged

### Scenario: PARALLEL_ROW_THRESHOLD omitted defaults to 1000000

* *GIVEN* `OPTIONS` does not contain a `PARALLEL_ROW_THRESHOLD` key
* *WHEN* `MIGRATE_TO_EXASOL` is executed for a source whose adapter emits multi-statement IMPORTs
* *THEN* the dispatcher SHALL apply the default threshold `1000000` to every parsed IMPORT
* *AND* tables with `num_rows < 1000000` SHALL be rewritten to single statement

### Scenario: Row-count lookup failure leaves IMPORTs unchanged

* *GIVEN* an adapter emits at least one multi-statement IMPORT
* *AND* the source-side row-count lookup fails (network error, missing privilege, or unsupported metadata table)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT raise the migration as failed solely because of the row-count lookup
* *AND* the dispatcher SHALL log a `STEP_KIND = INFO` row noting that the gate was skipped for this run
* *AND* every emitted IMPORT SHALL pass through unchanged

### Scenario: Adapter emits no IMPORT rows

* *GIVEN* an adapter returns only DDL rows (no `IMPORT INTO ...` statements)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue any row-count lookup
* *AND* the dispatcher SHALL pass adapter output through to `normalize_rows` / `execute_generated_sql` unchanged

### Scenario: Source type without a row-count SQL skips the gate

* *GIVEN* `SOURCE_TYPE` resolves to an adapter for which the dispatcher does not ship a row-count SQL (e.g. `EXASOL`, `VECTORWISE`, `S3`)
* *AND* `OPTIONS` contains a non-zero `PARALLEL_ROW_THRESHOLD`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL log a `STEP_KIND = INFO` row noting that the gate is not configured for this source type
* *AND* every emitted IMPORT SHALL pass through unchanged

### Scenario: Source-side reference parsed from inner SELECT, not target rename

* *GIVEN* the adapter emits `IMPORT INTO "DST"."ORDERS" (...) from JDBC at SRC statement 'select … from "PUBLIC"."orders"' statement '... from "PUBLIC"."orders" ...'` under `OPTIONS = 'TARGET_SCHEMA=DST;PARALLEL_ROW_THRESHOLD=1000000'`
* *AND* the row-count lookup returns `num_rows = 100` for source `PUBLIC.orders`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL key the row-count lookup on `PUBLIC.orders` (the source identifier parsed from the inner SELECT's `from "..."."..."` clause)
* *AND* the dispatcher SHALL rewrite the IMPORT to retain only its first `statement '...'` clause
* *AND* the target-side reference `"DST"."ORDERS"` MUST NOT influence the lookup key

### Scenario: Multiple IMPORTs in one migration are gated independently

* *GIVEN* an adapter emits three IMPORTs in one run: `SMOKE.SMALL_T` (4-way parallel, `num_rows = 500`), `SMOKE.BIG_T` (4-way parallel, `num_rows = 5000000`), and `SMOKE.MED_T` (single-statement)
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL rewrite `SMOKE.SMALL_T`'s IMPORT to a single statement, pass `SMOKE.BIG_T`'s IMPORT through with four `statement '...'` clauses, and pass `SMOKE.MED_T`'s IMPORT through unchanged
* *AND* the dispatcher SHALL issue exactly one source-side row-count lookup for the run (covering all three tables in a single round-trip)
