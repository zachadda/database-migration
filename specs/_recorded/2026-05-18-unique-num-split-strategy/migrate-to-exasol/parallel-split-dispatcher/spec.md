# Feature: parallel-split-dispatcher (delta: UNIQUE_NUM hierarchy step + forced directive)

This delta makes the `UNIQUE_NUM` strategy reachable. AUTO mode tests for `src_unique_num_col` between PK_RANGE and DATE_BUCKET in the hierarchy. A new forced directive `PARALLEL_SPLIT=UNIQUE_NUM[:col]` is accepted. UNIQUE_NUM dispatches through the same BETWEEN builder shipped in `pk-range-between-pushdown` — MOD fallback when min/max NULL.

## Background

* `pick_split_strategy` AUTO order after this delta: PARTITION → **PK_RANGE → UNIQUE_NUM** → DATE_BUCKET → HASH_NUM → ROWID → SINGLE+INFO.
* AUTO picks UNIQUE_NUM iff `meta.src_pk_col` is NULL AND `meta.src_unique_num_col` is non-NULL AND `is_numeric_pk_type(meta.src_unique_num_type)`.
* Forced directive `PARALLEL_SPLIT=UNIQUE_NUM` uses `meta.src_unique_num_col` (or soft-fails with INFO row if NULL). Forced directive `PARALLEL_SPLIT=UNIQUE_NUM:<col>` overrides the cached column name (operator-supplied) — the splitter trusts the operator and emits BETWEEN buckets without re-validating type.
* `build_where_for_split` for `decision.strategy == 'UNIQUE_NUM'` is identical to PK_RANGE: BETWEEN when `lo`+`hi` populated, MOD fallback otherwise. The audit row's `SPLIT_STRATEGY` carries `'UNIQUE_NUM'`.

## Scenarios

### Scenario: AUTO picks UNIQUE_NUM when no PK but unique numeric col present

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.LEGACY_ORDERS`
* *AND* the metadata cache reports `src_pk_col = NULL`, `src_unique_num_col = 'LEGACY_ID'`, `src_unique_num_type = 'INT4'`, `src_unique_num_min = 1`, `src_unique_num_max = 2000000`, `src_date_col = 'CREATED_AT'`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 4 `statement '...'` clauses carrying `"LEGACY_ID" BETWEEN <lo> AND <hi>` selectors (per item 2's bucket math)
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'UNIQUE_NUM'`, `SPLIT_KEY = 'LEGACY_ID'`, `PARALLEL_EFFECTIVE = 4`
* *AND* the splitter MUST NOT fall through to DATE_BUCKET on `CREATED_AT`

### Scenario: AUTO falls through to DATE_BUCKET when no PK and no unique-num

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.LOGS`
* *AND* the metadata cache reports `src_pk_col = NULL`, `src_unique_num_col = NULL`, `src_date_col = 'TS'`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the audit row SHALL carry `SPLIT_STRATEGY = 'DATE_BUCKET'`, `SPLIT_KEY = 'TS'`

### Scenario: Forced UNIQUE_NUM directive uses cached column

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.HYBRID_T`
* *AND* the metadata cache reports `src_pk_col = 'ID'` AND `src_unique_num_col = 'TRACE_NUM'` AND `src_unique_num_min = 1, src_unique_num_max = 100`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=UNIQUE_NUM`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 2 `statement '...'` clauses keyed on `"TRACE_NUM"` (not `"ID"`)
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'UNIQUE_NUM'`, `SPLIT_KEY = 'TRACE_NUM'`

### Scenario: Forced UNIQUE_NUM:col overrides cached column

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.OPS_AUDIT`
* *AND* the metadata cache reports `src_unique_num_col = NULL` (catalog did not discover one)
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=UNIQUE_NUM:OPS_SEQ`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the splitter SHALL emit 4 `statement '...'` clauses keyed on `"OPS_SEQ"`
* *AND* the splitter MUST NOT re-validate `OPS_SEQ`'s type from the cache (operator-supplied)
* *AND* without `lo`/`hi` from the cache the dispatcher MUST fall back to the dialect's MOD builder per item 2's contract

### Scenario: Forced UNIQUE_NUM soft-fails when no col known and no override supplied

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.MYSTERY_T`
* *AND* the metadata cache reports `src_unique_num_col = NULL`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=UNIQUE_NUM`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT raise the migration as failed
* *AND* the IMPORT MUST pass through unchanged
* *AND* an `INFO` audit row SHALL be emitted noting `PARALLEL_SPLIT=UNIQUE_NUM` requested but no unique-num col known and no override supplied
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'SINGLE'`, `PARALLEL_EFFECTIVE = 1`

### Scenario: UNIQUE_NUM honors MOD fallback when min/max NULL

* *GIVEN* the metadata cache reports `src_unique_num_col = 'LEGACY_ID', src_unique_num_min = NULL, src_unique_num_max = NULL`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `MYSQL`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 4 `statement '...'` clauses, each carrying `` (`LEGACY_ID` MOD 4) = k `` (MySQL's existing pk_where builder)
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'UNIQUE_NUM'`, `SPLIT_KEY = 'LEGACY_ID'`, `PARALLEL_EFFECTIVE = 4`
