# Tasks: harden-master-migration-entrypoint

## Phase 1: Planning
- [x] 1.1 Restore Speq mission context on clean branch
- [x] 1.2 Create hardening plan and wrapper spec
- [x] 1.3 Validate Speq plan

## Phase 2: Implementation
- [x] 2.1 Add regression tests for no executable generated SQL
- [x] 2.2 Fix `DEBUG = FALSE` no-op summary in `MIGRATE_TO_EXASOL`
- [x] 2.3 Add Exasol runtime smoke test with mock adapters

## Phase 3: Verification
- [x] 3.1 Run wrapper Lua tests
- [x] 3.2 Run Databricks Lua tests
- [x] 3.3 Run Python AST check
- [x] 3.4 Run Speq plan validation
- [x] 3.5 Run runtime mock smoke
- [x] 3.6 Run live Databricks wrapper smoke
- [x] 3.7 Run whitespace diff check
