# Tasks: partition-split-v2-non-pg-sources

## Phase 2: Implementation (Group A — Cast Hardening)

- [x] 2.1 Harden ORACLE template cols 14+15 in migrate_to_exasol.sql (replace bare NULL with `cast(NULL as boolean)` and `cast(NULL as varchar(2000000))`)
- [x] 2.2 Harden VERTICA template cols 14+15 in migrate_to_exasol.sql (same casts)
- [x] 2.3 Harden DATABRICKS template cols 14+15 in migrate_to_exasol.sql (same casts)

## Phase 2: Implementation (Group B — SQLSERVER Partition Discovery + Lua)

- [ ] 2.4 Replace SQLSERVER template col 15 cast(NULL...) with inlined STRING_AGG JSON aggregation in migrate_to_exasol.sql
- [ ] 2.5 Add Lua test: SQLSERVER partitioned table populates src_partitions JSON (test_migrate_to_exasol.lua)
- [ ] 2.6 Add Lua test: SQLSERVER non-partitioned table emits src_partitions = NULL (test_migrate_to_exasol.lua)
- [ ] 2.7 Add Lua test: ORACLE/VERTICA/DATABRICKS templates render without bare-NULL (test_migrate_to_exasol.lua)
- [ ] 2.8 Add Lua test: SQLSERVER metadata template contains STRING_AGG for src_partitions (test_migrate_to_exasol.lua)

## Phase 2: Implementation (Group C — Live Smoke + Regression)

- [ ] 2.9 Extend _reference/smoke_parallel_split_sqlserver.py with partitioned_t fixture (4-partition function, 200 rows, threshold=50)
- [ ] 2.10 Run live smoke SQLSERVER (new partitioned_t path) and assert SPLIT_STRATEGY=PARTITION, PARALLEL_EFFECTIVE=4
- [ ] 2.11 Run regression smoke: POSTGRES, MySQL, SQLSERVER (non-partitioned)

## Phase 3: Verification

- [ ] 3.1 Run `python3 -c "import ast, pathlib; [ast.parse(...)]"` — build check
- [ ] 3.2 Run `lua test/test_migrate_to_exasol.lua` — Lua tests
- [ ] 3.3 Run `python3 test/test_migrate_to_exasol_runtime.py` — py-runtime tests
- [ ] 3.4 Run `git diff --check` — lint
- [ ] 3.5 Verify no bare-NULL in ORACLE/VERTICA/DATABRICKS partition columns (grep assertion)

## Phase 4: Completion

- [ ] 4.1 Generate verification report
- [ ] 4.2 Ready for /speq:record
