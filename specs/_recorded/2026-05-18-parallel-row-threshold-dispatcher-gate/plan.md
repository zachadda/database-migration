# Plan: parallel-row-threshold-dispatcher-gate

## Summary

Move the `PARALLEL_ROW_THRESHOLD` gate from the Oracle adapter into the dispatcher (`migrate_to_exasol.sql`) so the same gate applies to every current and future adapter that emits multi-statement parallel IMPORTs, without any per-adapter code change.

## Design

### Context

The v1 design (sibling plan `parallel-row-threshold-gate/`, already implemented end-to-end on branch `feat/parallel-row-threshold` but uncommitted) placed gate logic inside `oracle_to_exasol.sql`. Live smoke against Oracle Free passed (small table → 1 statement, big table → 4 statements; legacy mode preserved). That implementation is correct but in the wrong layer:

- Each new adapter that ports multi-statement parallel emission (`postgres_to_exasol.sql`, `sqlserver_to_exasol.sql`, `mysql_to_exasol.sql`, ... — the sibling plan `parallel-import-source-optimization/`) would have to duplicate the gate logic.
- The gate is orthogonal to emission. The natural seam is at the dispatcher, which already classifies adapter output (`classify_step`, `extract_target_obj`) and post-processes it before returning.

The pivot lifts the gate above adapters entirely. Adapters keep emitting whatever parallel form they support; the dispatcher decides whether to keep the parallel statements or collapse to one.

- **Goals** — One gate implementation; behaviorally identical to the Oracle smoke result for ORACLE source; auto-extends to other sources the moment they gain multi-statement emission (Speq 2 work).
- **Non-Goals** — Adding multi-statement parallel emission to adapters that lack it (Speq 2). Audit-table column additions (`ROW_COUNT_APPROX`, `IMPORT_MODE`) — deferred to a separate plan.

### Decision

#### Architecture

```
                      ┌────────────────────────────────────┐
caller ─────────────▶ │ MIGRATE_TO_EXASOL (dispatcher)     │
OPTIONS=              │                                    │
PARALLEL_ROW_THRESHOLD│  ┌───────────────────────────┐     │
                      │  │ run adapter, capture rows │     │
                      │  └─────────────┬─────────────┘     │
                      │                ▼                   │
                      │  ┌───────────────────────────┐     │
                      │  │ scan rows: any IMPORT     │     │
                      │  │ with >1 `statement '...'`?│     │
                      │  └─────────────┬─────────────┘     │
                      │       yes ─────┼──── no            │
                      │                ▼                   │
                      │  ┌───────────────────────────┐     │
                      │  │ source row-count lookup   │     │
                      │  │ via IMPORT FROM JDBC      │     │
                      │  │ (per-source dispatch SQL) │     │
                      │  └─────────────┬─────────────┘     │
                      │                ▼                   │
                      │  ┌───────────────────────────┐     │
                      │  │ rewrite IMPORTs whose     │     │
                      │  │ source num_rows < threshold│    │
                      │  │ to retain first `statement│     │
                      │  │ '...'` clause only        │     │
                      │  └─────────────┬─────────────┘     │
                      │                ▼                   │
                      │  ┌───────────────────────────┐     │
                      │  │ normalize_rows (preview)  │     │
                      │  │ execute_generated_sql     │     │
                      │  │ (existing paths)          │     │
                      │  └───────────────────────────┘     │
                      └────────────────────────────────────┘
```

Per-source row-count SQL table (dispatcher-owned, keyed by normalized `SOURCE_TYPE`):

| Source | Row-count SQL (executed via `IMPORT FROM JDBC at <CONN> statement '...'`) | Notes |
|---|---|---|
| ORACLE | `select owner, table_name, num_rows from all_tables where owner <SCHEMA_STR> and table_name <TABLE_STR>` | Uses `DBA_TABLES.NUM_ROWS` populated by `DBMS_STATS.GATHER_*`. NULL → treated as 0. |
| POSTGRES | `select n.nspname, c.relname, c.reltuples::bigint from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname <SCHEMA_STR> and c.relname <TABLE_STR> and c.relkind in ('r','p')` | `reltuples` is approximate; updated by ANALYZE / autovacuum. |
| MYSQL / MARIADB | `select table_schema, table_name, table_rows from information_schema.tables where table_schema <SCHEMA_STR> and table_name <TABLE_STR>` | InnoDB approximate. |
| SQLSERVER | `select s.name, t.name, sum(ps.row_count) from sys.tables t join sys.schemas s on s.schema_id=t.schema_id join sys.dm_db_partition_stats ps on ps.object_id=t.object_id and ps.index_id in (0,1) where s.name <SCHEMA_STR> and t.name <TABLE_STR> group by s.name, t.name` | Heap (`index_id=0`) or clustered (`index_id=1`). |
| SNOWFLAKE | `select table_schema, table_name, row_count from information_schema.tables where table_schema <SCHEMA_STR> and table_name <TABLE_STR>` | Exact, free. |
| BIGQUERY | `select table_schema, table_name, row_count from \`<PROJECT_ID>.<DATASET>.__TABLES__\`` | Per-dataset; OPTIONS PROJECT_ID required for source connect anyway. |
| VERTICA | `select projection_schema, anchor_table_name, row_count from projection_storage where projection_schema <SCHEMA_STR> and anchor_table_name <TABLE_STR>` | |
| REDSHIFT | `select schema, "table", tbl_rows from svv_table_info where schema <SCHEMA_STR> and "table" <TABLE_STR>` | |
| DB2 | `select tabschema, tabname, card from syscat.tables where tabschema <SCHEMA_STR> and tabname <TABLE_STR>` | `RUNSTATS` populated. |
| TERADATA | `select databasename, tablename, currentpermspace from dbc.tablesizev where databasename <SCHEMA_STR> and tablename <TABLE_STR>` | Bytes proxy — not row count; document as approximate gate input. |
| HANA | `select schema_name, table_name, record_count from sys.m_tables where schema_name <SCHEMA_STR> and table_name <TABLE_STR>` | |
| NETEZZA | `select database, schema, tablename, reltuples from _v_table where schema <SCHEMA_STR> and tablename <TABLE_STR>` | |
| AZURE_SQL | Same as SQLSERVER | |
| DATABRICKS | `select table_schema, table_name, /* row count not generally available */ NULL from information_schema.tables where table_schema <SCHEMA_STR> and table_name <TABLE_STR>` | Document as no-stats; gate falls through to single-statement IMPORT. |
| TRINO / DREMIO / CLICKHOUSE / DUCKDB | per-source equivalents | Defer initial implementation. |
| EXASOL / VECTORWISE / S3 | _not configured_ | Documented no-op; `INFO` row noting gate is not configured. |

Mapping from a parsed IMPORT to the row-count lookup key uses the **source-side** reference parsed from the inner SELECT (`from "OWNER"."TABLE"`), not the target-side `IMPORT INTO "EXA_SCHEMA"."EXA_TABLE"`. This avoids depending on target-rename semantics (`TARGET_SCHEMA`, `IDENTIFIER_CASE_INSENSITIVE`, `CATALOG2SCHEMA`).

#### Patterns

| Pattern | Where | Why |
|---------|-------|-----|
| Post-processing transform | Dispatcher `transform_for_gate` Lua function, called between adapter return and `normalize_rows` / `execute_generated_sql` | Keeps the gate orthogonal to emission |
| Source-type dispatch table | Lua `ROW_COUNT_SQL_BY_SOURCE` table inside `migrate_to_exasol.sql` | One place to add new sources |
| Lazy lookup | Skip the row-count `IMPORT FROM JDBC` round-trip when no IMPORT in the adapter output has more than one `statement '...'` clause | Adapters that never emit parallel pay zero cost |
| Soft-fail on lookup error | `pquery` failure leaves emitted IMPORTs unchanged + logs an `INFO` row | The gate is an optimization; a stats-lookup outage must never break a migration |

### Consequences

| Decision | Alternatives Considered | Rationale |
|----------|------------------------|-----------|
| Gate lives in dispatcher | (a) per-adapter gate (v1 design, working but duplicated per source); (b) external orchestrator | Dispatcher already classifies adapter output; one implementation auto-applies to every source |
| `PARALLEL_ROW_THRESHOLD` exposed via `OPTIONS` (not a new positional arg) | New 11th positional arg | OPTIONS is the established place for source-tunable knobs; avoids breaking the `MIGRATE_TO_EXASOL` call surface |
| Look up source row counts in one round-trip per migration | Per-table lookups; no lookup at all (use a static "assume large") | One round-trip is cheap; per-table multiplies network cost; static assumption breaks the gate's purpose |
| Parse source schema/table from the IMPORT inner SELECT | Use target schema/table + reverse-rename | Inner SELECT references are unambiguous across all rename modes (`IDENTIFIER_CASE_INSENSITIVE`, `TARGET_SCHEMA`, `CATALOG2SCHEMA`, BigQuery 3-level) |
| Soft-fail on lookup error | Hard-fail | Gate is an optimization, not a correctness requirement |
| Default threshold `1000000` | `0` (off-by-default); some per-source heuristic | `1000000` matches v1 default + crossover benchmark from upstream comparable tools; users can tune via OPTIONS |

## Features

| Feature | Status | Spec |
|---------|--------|------|
| parallel-row-threshold-gate | NEW | `migrate-to-exasol/parallel-row-threshold-gate/spec.md` |

## Dependencies

- Builds on the wrapper branch `master-migration-entrypoint-upstream-pr` (six PR-#42 commits already fast-forwarded into `feat/parallel-row-threshold`). PR #42 is currently CLOSED upstream; this plan does NOT require it to reopen.
- Sibling plan `parallel-row-threshold-gate/` (v1) — its uncommitted diff is the rollback target for this plan's first task.

## Migration

| Current (v1 design, uncommitted on `feat/parallel-row-threshold`) | New |
|---|---|
| `oracle_to_exasol.sql` declares `PARALLEL_ROW_THRESHOLD` as a 6th adapter param, fetches `all_tables.num_rows`, injects `ora_no_parallel` CTE, rewrites `ora_stmt_part_oh` to gate the hash modulo branch. | Oracle adapter reverts to wrapper-branch baseline. Gate logic moves into `migrate_to_exasol.sql`. |
| `migrate_to_exasol.sql` plumbs `PARALLEL_ROW_THRESHOLD` to the Oracle dispatch branch only. | `migrate_to_exasol.sql` reads `PARALLEL_ROW_THRESHOLD` from `OPTIONS` for every source. New `transform_for_gate(rows, source_type, options, connection_name)` post-processes adapter output. |
| `test/test_oracle_to_exasol.lua` covers 11 gate scenarios via adapter SQL inspection. | File is deleted. New gate coverage lives in `test/test_migrate_to_exasol.lua`. |
| `test/test_migrate_to_exasol.lua` Oracle dispatch expected string includes `PARALLEL_ROW_THRESHOLD` positional. Two Oracle-option tests cover threshold override / `=0`. | Oracle dispatch expected string reverts to wrapper-branch baseline (no extra positional). New tests cover dispatcher-level gate behavior across multiple source types. |
| `test/test_migrate_to_exasol_runtime.py` `ORACLE` param list includes `PARALLEL_ROW_THRESHOLD`. | Reverted to wrapper-branch baseline. |
| `_reference/smoke_parallel_row_threshold.py` exercises the Oracle-adapter gate. | Reused unchanged; the gate now lives one layer up but the observable behavior (SMALL_T 1-stmt, BIG_T 4-stmt under threshold; both 4-stmt under `=0`) is identical. |

## Implementation Tasks

1. Revert v1 changes:
   - `oracle_to_exasol.sql`: remove `PARALLEL_ROW_THRESHOLD` from signature; delete num_rows fetch, `t_no_parallel` builder, `is_parallel_eligible` helper, `sql_ora_no_parallel`, the `ora_no_parallel` CTE injection, the `ora_stmt_part_oh` rewrite, and the updated example invocation. Restore wrapper-branch content byte-for-byte.
   - `migrate_to_exasol.sql`: revert the `PARALLEL_ROW_THRESHOLD` plumb on the Oracle dispatch branch.
   - `test/test_migrate_to_exasol.lua`: revert `default_case("ORACLE", ...)`, revert the "Oracle options are forwarded" test, delete the two new option tests.
   - `test/test_migrate_to_exasol_runtime.py`: revert `ORACLE` param list.
   - Delete `test/test_oracle_to_exasol.lua`.
2. Add `ROW_COUNT_SQL_BY_SOURCE` dispatch table inside `migrate_to_exasol.sql` covering ORACLE, POSTGRES, MYSQL, MARIADB, SQLSERVER, AZURE_SQL, SNOWFLAKE, BIGQUERY, REDSHIFT, VERTICA, DB2, HANA, NETEZZA, TERADATA, DATABRICKS. Document Trino/Dremio/ClickHouse/DuckDB as deferred.
3. Implement `transform_for_gate(rows, source_type, connection_name, schema_filter, table_filter, options)` in `migrate_to_exasol.sql`:
   - Parse `PARALLEL_ROW_THRESHOLD` from options. 0 / NULL / absent (default 1000000) → choose semantics per spec.
   - Walk `rows` once; for any row that is an IMPORT, count `statement '...'` clauses and parse source `OWNER.TABLE` from inner SELECT.
   - If any IMPORT has >1 clause and threshold > 0:
     - Pick the row-count SQL for `source_type`. If absent → emit an `INFO` row + skip gate.
     - `IMPORT FROM JDBC at <CONN> statement '<row-count SQL>'` into a temp table or into a Lua table directly via subselect; cache into a Lua lookup.
     - On `pquery` failure, emit an `INFO` row + skip gate.
   - For each IMPORT with >1 clause whose source row count is NULL or `< threshold`, regex-rewrite the IMPORT to retain only its first `statement '...'` clause.
   - Return the (possibly rewritten) rows.
4. Wire `transform_for_gate` into `execute_adapter` before `normalize_rows` (preview path) and before `execute_generated_sql` (execute path).
5. Add new test coverage in `test/test_migrate_to_exasol.lua`:
   - Multi-statement IMPORT below threshold rewritten
   - Multi-statement IMPORT at/above threshold passed through
   - Single-statement IMPORT passes through unchanged
   - NULL row count treated as below threshold
   - `PARALLEL_ROW_THRESHOLD=0` disables gate
   - Default `1000000` applies when option omitted
   - Row-count lookup failure → IMPORTs unchanged + INFO row
   - Adapter emits no IMPORT rows → no lookup, no gate
   - Source type without row-count SQL → INFO row + skip
   - Source-side reference parsed from inner SELECT (not target)
   - Multiple IMPORTs gated independently in one run, single lookup round-trip
6. Re-run `_reference/smoke_parallel_row_threshold.py` against Oracle Free; expect identical PASS as v1 (SMALL_T 1-stmt + BIG_T 4-stmt under threshold; 4/4 under `=0`).

## Dead Code Removal

| Type | Location | Reason |
|------|----------|--------|
| Lua block | `oracle_to_exasol.sql` (v1 gate additions) | Logic moves to dispatcher |
| Param | `oracle_to_exasol.sql` `PARALLEL_ROW_THRESHOLD` parameter | Param now lives at dispatcher level only |
| Param plumb | `migrate_to_exasol.sql` Oracle dispatch branch `PARALLEL_ROW_THRESHOLD` positional | Param is now dispatcher-level via OPTIONS, not per-adapter positional |
| Test file | `test/test_oracle_to_exasol.lua` | Gate behavior no longer lives in the adapter |
| Test cases | `test/test_migrate_to_exasol.lua` Oracle PARALLEL_ROW_THRESHOLD option tests (2 cases) | Replaced by dispatcher-level tests |

## Verification

### Scenario Coverage

| Scenario | Test Type | Test Location | Test Name |
|----------|-----------|---------------|-----------|
| Below-threshold table emits a single statement | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate rewrites multi-statement IMPORT below threshold` |
| At-or-above-threshold table passes through unchanged | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate keeps multi-statement IMPORT at or above threshold` |
| Single-statement IMPORT passes through regardless of row count | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate leaves single-statement IMPORT untouched` |
| NULL row count is treated as below threshold | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate treats NULL num_rows as below threshold` |
| PARALLEL_ROW_THRESHOLD = 0 disables the gate | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate disabled by PARALLEL_ROW_THRESHOLD=0` |
| PARALLEL_ROW_THRESHOLD omitted defaults to 1000000 | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate default threshold is 1000000` |
| Row-count lookup failure leaves IMPORTs unchanged | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate soft-fails on row-count lookup error` |
| Adapter emits no IMPORT rows | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate skips lookup when adapter emits no IMPORTs` |
| Source type without a row-count SQL skips the gate | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate skips unsupported source type with INFO row` |
| Source-side reference parsed from inner SELECT, not target rename | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate keys lookup on source schema parsed from inner SELECT` |
| Multiple IMPORTs in one migration are gated independently | Integration (Lua) | `test/test_migrate_to_exasol.lua` | `gate applies per-table within one migration with one lookup` |

### Manual Testing

| Feature | Command | Expected Output |
|---------|---------|-----------------|
| parallel-row-threshold-gate | `python3 _reference/smoke_parallel_row_threshold.py` | `EXASOL.SMALL_T statements: 1` and `EXASOL.BIG_T statements: 4` under `PARALLEL_ROW_THRESHOLD=1000000`; both `4` under `PARALLEL_ROW_THRESHOLD=0`; final `PASS` |

### Checklist

| Step | Command | Expected |
|------|---------|----------|
| Build | `python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ('test/create_script.py','test/export_res.py','test/mock_test.py')]"` | Exit 0 |
| Test (Lua, all adapters) | `for t in test/test_*.lua; do lua "$t" || exit 1; done` | All passing |
| Test (Python runtime) | `python3 test/test_migrate_to_exasol_runtime.py` | Exit 0 |
| Live smoke | `python3 _reference/smoke_parallel_row_threshold.py` | `PASS` |
| Lint | `git diff --check` | No errors |
