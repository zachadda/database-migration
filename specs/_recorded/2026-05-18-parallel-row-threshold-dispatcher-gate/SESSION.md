# SESSION — parallel-row-threshold-dispatcher-gate

Resume context for a fresh agent. Last touched: 2026-05-17 evening.

## What this plan does

Refactor of the `PARALLEL_ROW_THRESHOLD` gate from **per-adapter** (`oracle_to_exasol.sql`) to **dispatcher-only** (`migrate_to_exasol.sql`). One implementation auto-applies to every current and future adapter that emits multi-statement parallel IMPORTs. Adapters never touched.

- Plan: `specs/_plans/parallel-row-threshold-dispatcher-gate/plan.md`
- Spec: `specs/_plans/parallel-row-threshold-dispatcher-gate/migrate-to-exasol/parallel-row-threshold-gate/spec.md` (11 scenarios, validates clean via `speq plan validate`)
- Sibling v1 plan to **roll back**: `specs/_plans/parallel-row-threshold-gate/PLAN.md`

## State on disk (CRITICAL — read before any edit)

Working dir: `/Users/zachary.adda/Documents/GitHub/database-migration`
Branch: `feat/parallel-row-threshold`
Branch position: 6 commits ahead of `fork/master` (= the 6 PR-#42 wrapper commits, fast-forwarded into the gate branch on 2026-05-17 because the plan dispatcher file `migrate_to_exasol.sql` only exists on the wrapper branch).

**The v1 gate is ALREADY implemented in the working tree, uncommitted.** Files touched by v1:

| File | v1 diff |
|---|---|
| `migrate_to_exasol.sql` | 1 line added: `PARALLEL_ROW_THRESHOLD` positional plumb on ORACLE dispatch branch |
| `oracle_to_exasol.sql` | +126 lines: new param + num_rows fetch + `t_no_parallel` + `is_parallel_eligible` + `sql_ora_no_parallel` builder + `ora_no_parallel` CTE injection + `ora_stmt_part_oh` rewrite + example invocation |
| `test/test_migrate_to_exasol.lua` | +24 lines: 2 added option tests + updated Oracle dispatch expected string |
| `test/test_migrate_to_exasol_runtime.py` | 1 line: `ORACLE` param list |
| `test/test_oracle_to_exasol.lua` | 268 lines NEW: 11 gate test cases |
| `_reference/smoke_parallel_row_threshold.py` | NEW (gitignored): live smoke harness for Oracle Free |

**This v1 diff is fully tested and green:**
- 11/11 oracle gate tests PASS (`lua test/test_oracle_to_exasol.lua`)
- 41/41 migrate tests PASS (`lua test/test_migrate_to_exasol.lua`)
- Python runtime test PASS (`python3 test/test_migrate_to_exasol_runtime.py`)
- Live smoke vs Oracle Free PASS: `EXASOL.SMALL_T` → 1 statement under threshold, `EXASOL.BIG_T` → 4 statements; both 4 under `=0` (legacy)

Plan dictates this v1 diff be **reverted** as Task 1, then the dispatcher-only design built on the clean wrapper-branch baseline.

`oracle_to_exasol.sql` ships with **CRLF line endings** (every other repo file is LF). Edits preserve CRLF; extract regex must `gsub("\r\n", "\n")` before matching `\n/\n` (see `test/test_oracle_to_exasol.lua` line 51-57 for the pattern that worked).

## Rollback recipe (Task 1)

```bash
cd /Users/zachary.adda/Documents/GitHub/database-migration
git checkout master-migration-entrypoint-upstream-pr -- migrate_to_exasol.sql oracle_to_exasol.sql test/test_migrate_to_exasol.lua test/test_migrate_to_exasol_runtime.py
rm test/test_oracle_to_exasol.lua
# (do NOT remove _reference/smoke_parallel_row_threshold.py — reused in Task 6.
# do NOT remove specs/_plans/parallel-row-threshold-gate/ — preserved as v1 design record.)
```

Verify rollback clean:

```bash
git diff master-migration-entrypoint-upstream-pr -- migrate_to_exasol.sql oracle_to_exasol.sql test/test_migrate_to_exasol.lua test/test_migrate_to_exasol_runtime.py
# expect: empty
```

## Implementation order (from plan.md)

1. **Rollback v1** (see recipe above). Verify all existing tests still pass.
2. **Add `ROW_COUNT_SQL_BY_SOURCE` dispatch table** in `migrate_to_exasol.sql`. Plan §Design has the per-source SQL strings. ORACLE/POSTGRES/MYSQL/MARIADB/SQLSERVER/AZURE_SQL/SNOWFLAKE/BIGQUERY/REDSHIFT/VERTICA/DB2/HANA/NETEZZA/TERADATA/DATABRICKS. Trino/Dremio/ClickHouse/DuckDB deferred.
3. **Implement `transform_for_gate(rows, source_type, conn, schema_filter, table_filter, options)`** in `migrate_to_exasol.sql`. Walk rows once, count `statement '...'` clauses per IMPORT, parse `from "OWNER"."TABLE"` source ref from inner SELECT, lazy `IMPORT FROM JDBC at <CONN> statement '...'` row-count fetch only if any IMPORT has >1 clause, regex-rewrite below-threshold IMPORTs to retain only first `statement '...'` clause. Soft-fail on lookup error (INFO row + skip).
4. **Wire `transform_for_gate`** into `execute_adapter` before both `normalize_rows` (preview) and `execute_generated_sql` (execute) paths.
5. **Tests**: add 11 cases in `test/test_migrate_to_exasol.lua` matching spec scenarios. See plan.md §Verification §Scenario Coverage for exact test names.
6. **Smoke**: `python3 _reference/smoke_parallel_row_threshold.py` against Oracle Free. Same fixture (EXASOL.SMALL_T + EXASOL.BIG_T with `DBMS_STATS.SET_TABLE_STATS numrows=5000000` for BIG_T). Expect identical PASS as v1.

## Key design constraints (do not rediscover)

- **Param surface**: `PARALLEL_ROW_THRESHOLD` via `OPTIONS` (`'PARALLEL_ROW_THRESHOLD=1000000'`), NOT a positional `MIGRATE_TO_EXASOL` argument. Default `1000000`. `0` or NULL → disable gate.
- **Source-side reference parsing**: lookup key is the `OWNER.TABLE` parsed from the inner SELECT's `from "..."."..."`. Robust to all rename modes (`TARGET_SCHEMA`, `IDENTIFIER_CASE_INSENSITIVE`, Databricks `CATALOG2SCHEMA`, BigQuery 3-level). Do NOT use the target `IMPORT INTO "..."."..."` ref.
- **One round-trip per migration**: fetch all source row counts in a single `IMPORT FROM JDBC at <CONN> statement '<row-count SQL>'`. Filter on `SCHEMA_STR` / `TABLE_STR` already built by the dispatcher.
- **Soft fail**: any `pquery` error in the lookup or in the rewrite must NOT raise the migration. Emit an `INFO` row, leave IMPORTs unchanged.
- **No audit-table columns**: `ROW_COUNT_APPROX` and `IMPORT_MODE` are explicitly OUT of scope. Deferred to a separate plan.
- **No parallel-emission ports**: Speq 2 (`parallel-import-source-optimization/`) covers adding multi-statement parallel emission to PG/SQLServer/MySQL/Snowflake/BQ. NOT this plan.

## Tooling on this machine

- ExaNano: `exanano-sqlcube` container, `localhost:8564`, `sys/exasol`, profile `sqlcube-nano` (verify with `exapump sql -p sqlcube-nano "SELECT 1"`).
- Oracle JDBC driver already loaded into ExaNano at `/exa/jdbc/ORACLE/ojdbc11-23.26.1.0.0.jar`.
- Oracle Free image present on disk (`gvenzl/oracle-free:23-slim-faststart`). Boot via the smoke harness, not by hand — harness handles the `dbm-net` bridge connect.
- Smoke harness uses Oracle's `exasol/oracle` APP_USER as both connecting user AND schema owner. Do not try to `CREATE USER smoke` — insufficient privilege as `exasol` user (this is fixed in the current harness; mentioning so a fresh attempt does not regress it).

## Test commands

```bash
# Lua tests (all adapters)
cd /Users/zachary.adda/Documents/GitHub/database-migration
for t in test/test_*.lua; do echo "=== $t ==="; lua "$t" || break; done

# Python runtime test
python3 test/test_migrate_to_exasol_runtime.py

# Live smoke (boots Oracle Free, ~2 min first time)
python3 _reference/smoke_parallel_row_threshold.py
```

## Memory file hooks

`~/.claude/projects/-Users-zachary-adda-Documents-GitHub-exasol-zemantic-layer/memory/`

- `project_database_migration_master_wrapper.md` — PR #42 closed status, wrapper branch table. Update when this plan ships.
- `feedback_destructive_git_hook.md` — destructive ops (force-push, branch-delete) blocked via AskUserQuestion. Use `gh api` or script files; never `&&`-chain destructive steps.
- `feedback_exanano_log_tuning.md` — `/exa/logs` grows uncapped; tune `LOG_LEVEL`+rotation if container stays up long.
- `reference_exasol_jdbc_smoke_quirks.md` — per-source quirks for JDBC smoke harness.

## Branch sanity check on resume

```bash
cd /Users/zachary.adda/Documents/GitHub/database-migration
git status
git branch --show-current      # expect: feat/parallel-row-threshold
git log --oneline -8            # top should be 35fdacd "fix(postgres): handle NULL DEST_SCHEMA from wrapper"
ls migrate_to_exasol.sql oracle_to_exasol.sql   # both must exist (proves FF onto wrapper branch worked)
```

If `migrate_to_exasol.sql` is missing, the FF-merge onto `master-migration-entrypoint-upstream-pr` got lost — re-apply with `git merge --ff-only master-migration-entrypoint-upstream-pr`. Branch had zero own commits at cut time so FF is lossless.

## Live smoke that already passed (v1)

```
=== PARALLEL_ROW_THRESHOLD gate smoke ===
  oracledb@172.20.0.3 ready
  seeding oracle (EXASOL.SMALL_T + EXASOL.BIG_T with fake stats)...
    seeded.
  preview with PARALLEL_STATEMENTS=4;PARALLEL_ROW_THRESHOLD=1000000
    imports: ['EXASOL.SMALL_T', 'EXASOL.BIG_T']
    EXASOL.SMALL_T statements: 1
    EXASOL.BIG_T   statements: 4
  preview with PARALLEL_STATEMENTS=4;PARALLEL_ROW_THRESHOLD=0 (legacy)
    EXASOL.SMALL_T statements: 4
    EXASOL.BIG_T   statements: 4
  PASS
```

This output is the target behavior after the dispatcher-only refactor: the new gate must produce the SAME observable result (`PARALLEL_STATEMENTS` stays as the adapter-level OPTIONS knob since Oracle adapter still owns the parallel emission; the gate just collapses sub-threshold IMPORTs back to one statement).
