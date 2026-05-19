# Plan: partition-split-v2-sqlserver-live-smoke-unblock

## Summary

Execute Group C (deferred live smoke testing) from archived plan `2026-05-18-partition-split-v2-non-pg-sources`. Slice 0 + Slice 1 are shipped in code (HEAD `c45fa43`). Group C was blocked on external JDBC pquery wrapper returning zero rows; unblock via jTDS driver (pure-Java JDBC driver for SQL Server). Verify:

1. SQLSERVER partitioned tables emit PARTITION strategy + execute correctly
2. ORACLE, VERTICA, DATABRICKS cast-hardening works under real load (metadata templates render, JDBC accepts cast-safe NULL columns)
3. Tier-0 regression suite (PG, MySQL, SQLSERVER non-partitioned, Lua, Python runtime) passes unchanged

## Design

### Context

Archived plan `2026-05-18-partition-split-v2-non-pg-sources` completed Slice 0 (cast hardening) and Slice 1 (SQLSERVER partition discovery). Group C live smoke tests were deferred due to external blocker: JDBC pquery wrapper used for SQLSERVER smoke tests returned zero rows, preventing execution.

Root cause: SQL Server's native JDBC driver issue in Exasol's JDBC harness.

**Resolution:** Use jTDS driver (open-source pure-Java JDBC 4.0 implementation for SQL Server) instead. No SQLSERVER prefix dependency; driver handles connection string directly. Skip waiting for Microsoft JDBC fix.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│ Test Infrastructure: jTDS Driver                    │
│   smoke_parallel_split_*.py uses jTDS driver        │
│   (no sqlserver: prefix, direct JDBC URL)           │
└─────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────┐
│ Live Smoke Tests (New)                              │
│  - ORACLE: cast-hardening under load                │
│  - VERTICA: cast-hardening under load               │
│  - DATABRICKS: cast-hardening under load            │
│  - SQLSERVER: partitioned table PARTITION strategy  │
└─────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────┐
│ Tier-0 Regression Suite (Unchanged)                 │
│  - PG / MySQL / SQLSERVER (non-partitioned)         │
│  - Lua mocks + Python runtime                       │
│  - Lint + build                                     │
└─────────────────────────────────────────────────────┘
```

### Patterns

| Pattern | Where | Why |
|---|---|---|
| jTDS driver for SQLSERVER smoke tests | All `_reference/smoke_parallel_split_*.py` | Native Microsoft JDBC blocked on pquery wrapper; jTDS is battle-tested pure-Java JDBC 4.0, no external driver version dependency |
| Shared fixture schema across sources | ORACLE/VERTICA/DATABRICKS smoke tests | Mirrors SQLSERVER `big_t` (200 rows, threshold=50) structure; validates cast-hardening works under identical test conditions |
| Explicit cast-safe NULL assertions | ORACLE/VERTICA/DATABRICKS smoke logs | Verify template rendering produces `cast(NULL as <type>)` not bare `NULL`; grep for cast patterns in metadata roundtrip output |

### Consequences

| Decision | Alternatives Considered | Rationale |
|---|---|---|
| Use jTDS driver immediately | Wait for Microsoft JDBC fix | jTDS is production-ready (Apache 2.0, actively maintained). Unblocks Group C now without external dependencies. Exasol can migrate to Microsoft driver later if needed (JDBC is driver-agnostic). |
| Test ORACLE/VERTICA/DATABRICKS with same fixture as SQLSERVER non-partitioned | Per-source custom fixtures | Simplicity: cast-hardening is the invariant being tested. Identical conditions confirm no source-specific regressions. |
| Run full tier-0 regression suite | Skip regressions, run only new smoke tests | Slice 0 + 1 shipped 2026-05-18. Verifying no regression in PG/MySQL paths confirms no silent metadata/JDBC breaks. |

## Features

| Feature | Status | Spec |
|---|---|---|
| source-metadata-roundtrip | (inherited) | `specs/_recorded/2026-05-18-partition-split-v2-non-pg-sources/migrate-to-exasol/source-metadata-roundtrip/spec.md` |
| parallel-split-dispatcher | (inherited) | `specs/_recorded/2026-05-18-partition-split-v2-non-pg-sources/migrate-to-exasol/parallel-split-dispatcher/spec.md` |

This plan verifies the specs from the recorded plan via live smoke integration tests. No new spec deltas — testing existing behavior.

## Dependencies

- jTDS driver JAR (or Maven dependency in smoke harness)
- Live ORACLE, VERTICA, DATABRICKS containers on `dbm-net` bridge (same as existing CI)
- SQLSERVER `sqlserverdb` container with jTDS driver configured
- Exasol NanoDb instance to run migrations

## Implementation Tasks

### Task 1: Configure jTDS Driver in Smoke Harness

- Update `_reference/smoke_parallel_split_sqlserver.py` to use jTDS driver connection string (e.g., `jdbc:jtds:sqlserver://host:port/database`)
- Verify existing non-partitioned tests (big_t, BETWEEN path) still pass with jTDS
- Document jTDS version pinned in smoke harness

### Task 2: Create ORACLE Live Smoke Test

- Create `_reference/smoke_parallel_split_oracle.py`
- Fixture: `big_t` (200 rows, non-partitioned, threshold=50 → SINGLE or PK_RANGE strategy)
- Assertions:
  - Metadata roundtrip succeeds (JDBC accepts cast-safe NULL)
  - `SPLIT_STRATEGY` is `SINGLE` or `PK_RANGE` (not ERROR)
  - No bare-NULL errors in metadata template

### Task 3: Create VERTICA Live Smoke Test

- Create `_reference/smoke_parallel_split_vertica.py`
- Fixture: `big_t` (identical to ORACLE)
- Assertions: Same as ORACLE

### Task 4: Create DATABRICKS Live Smoke Test

- Create `_reference/smoke_parallel_split_databricks.py`
- Fixture: `big_t` (identical to ORACLE/VERTICA)
- Assertions: Same as ORACLE

### Task 5: Extend SQLSERVER Live Smoke Test

- Add `partitioned_t` fixture to `_reference/smoke_parallel_split_sqlserver.py` (4-partition range function, 200 rows, threshold=50)
- Assertions:
  - `SPLIT_STRATEGY = 'PARTITION'` (not `PK_RANGE`, not `SINGLE`)
  - `PARALLEL_EFFECTIVE = 4`
  - Each emitted STATEMENT body contains `$partition.<func>([col]) = <N>`

### Task 6: Verify Tier-0 Regressions

Run full regression suite:
- `lua test/test_migrate_to_exasol.lua` (includes Slice 0 + 1 Lua mock assertions)
- `python3 test/test_migrate_to_exasol_runtime.py`
- `python3 _reference/smoke_parallel_split_postgres.py`
- `python3 _reference/smoke_parallel_split_mysql.py`
- `python3 _reference/smoke_parallel_split_sqlserver.py` (non-partitioned only, before running partitioned_t)
- `git diff --check`

## Parallelization

Tasks 2–5 (new smoke tests for ORACLE/VERTICA/DATABRICKS/SQLSERVER partitioned) can run in parallel after Task 1 completes.

| Parallel Group | Tasks |
|---|---|
| Group A | Task 1 (jTDS driver config) |
| Group B | Tasks 2, 3, 4, 5 (new/extended smoke tests) — parallel |
| Group C | Task 6 (regression suite) — sequential after Group B |

## Verification

### Scenario Coverage

| Scenario | Test Type | Test Location | Test Name | Status |
|---|---|---|---|---|
| ORACLE cast-hardening under load | Integration | `_reference/smoke_parallel_split_oracle.py` | `test_big_t_metadata_roundtrip_succeeds` | NEW |
| VERTICA cast-hardening under load | Integration | `_reference/smoke_parallel_split_vertica.py` | `test_big_t_metadata_roundtrip_succeeds` | NEW |
| DATABRICKS cast-hardening under load | Integration | `_reference/smoke_parallel_split_databricks.py` | `test_big_t_metadata_roundtrip_succeeds` | NEW |
| SQLSERVER partitioned table picks PARTITION strategy | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_partitioned_t_picks_partition_strategy` | (inherited from archived plan) |
| SQLSERVER partitioned table executes with jTDS driver | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_partitioned_t_executes_4_parallel_statements` | (inherited from archived plan) |
| Tier-0 PG regression | Integration | `_reference/smoke_parallel_split_postgres.py` | all | EXISTING |
| Tier-0 MySQL regression | Integration | `_reference/smoke_parallel_split_mysql.py` | all | EXISTING |
| Tier-0 SQLSERVER non-partitioned regression | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_big_t_*` | EXISTING |
| Lua mock coverage (Slice 0 + 1) | Unit | `test/test_migrate_to_exasol.lua` | all | EXISTING |
| Python runtime coverage | Unit | `test/test_migrate_to_exasol_runtime.py` | all | EXISTING |

### Manual Testing

| Feature | Command | Expected Output |
|---|---|---|
| ORACLE cast-hardening | `python3 _reference/smoke_parallel_split_oracle.py` | `big_t -> SPLIT_STRATEGY=(SINGLE\|PK_RANGE), metadata_roundtrip=OK` |
| VERTICA cast-hardening | `python3 _reference/smoke_parallel_split_vertica.py` | `big_t -> SPLIT_STRATEGY=(SINGLE\|PK_RANGE), metadata_roundtrip=OK` |
| DATABRICKS cast-hardening | `python3 _reference/smoke_parallel_split_databricks.py` | `big_t -> SPLIT_STRATEGY=(SINGLE\|PK_RANGE), metadata_roundtrip=OK` |
| SQLSERVER partitioned (jTDS) | `python3 _reference/smoke_parallel_split_sqlserver.py` | `partitioned_t -> SPLIT_STRATEGY=PARTITION, PARALLEL_EFFECTIVE=4`; each STATEMENT matches `\$partition\.\w+\(\[\w+\]\) = \d` |
| All regressions | `cd /Users/zachary.adda/Documents/GitHub/database-migration && lua test/test_migrate_to_exasol.lua && python3 test/test_migrate_to_exasol_runtime.py && python3 _reference/smoke_parallel_split_postgres.py && python3 _reference/smoke_parallel_split_mysql.py && python3 _reference/smoke_parallel_split_sqlserver.py` | All exit 0 |

### Checklist

| Step | Command | Expected |
|---|---|---|
| Build | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ('test/create_script.py','test/export_res.py','test/mock_test.py','_reference/smoke_parallel_split_oracle.py','_reference/smoke_parallel_split_vertica.py','_reference/smoke_parallel_split_databricks.py')]"` | Exit 0 |
| Test (Lua) | `lua test/test_migrate_to_exasol.lua` | All 124 assertions pass |
| Test (py-runtime) | `python3 test/test_migrate_to_exasol_runtime.py` | 6/6 tests pass |
| Live smoke (ORACLE) | `python3 _reference/smoke_parallel_split_oracle.py` | All assertions PASS, exit 0 |
| Live smoke (VERTICA) | `python3 _reference/smoke_parallel_split_vertica.py` | All assertions PASS, exit 0 |
| Live smoke (DATABRICKS) | `python3 _reference/smoke_parallel_split_databricks.py` | All assertions PASS, exit 0 |
| Live smoke (SQLSERVER) | `python3 _reference/smoke_parallel_split_sqlserver.py` | All assertions PASS (both big_t and partitioned_t), exit 0 |
| Regression smoke (PG) | `python3 _reference/smoke_parallel_split_postgres.py` | All assertions PASS, exit 0 |
| Regression smoke (MySQL) | `python3 _reference/smoke_parallel_split_mysql.py` | All assertions PASS, exit 0 |
| Lint | `git diff --check` | 0 errors/warnings |

## Notes

- **jTDS driver location**: Confirm maven dep or JAR path in smoke harness before running Task 1. If not present, add to build/test requirements.
- **Container availability**: ORACLE/VERTICA/DATABRICKS containers must be on `dbm-net` bridge. Verify via `docker ps` before running Tasks 2–4.
- **SQLSERVER containers**: `sqlserverdb` must have jTDS driver JAR available or Maven auto-fetch enabled.
- **No spec deltas**: This plan tests existing specs from archived plan. No new feature specs; verification only.
