# Tasks: add-adapter-datatype-smoke-matrix

## Phase 1: Plan

- [x] 1.1 Create Speq plan and datatype smoke scenarios.
- [x] 1.2 Validate plan.

## Phase 2: Vertica Harness

- [x] 2.1 Build local datatype smoke tool under this plan.
- [x] 2.2 Add self-tests for canonical cases, result shape, error preservation, and cleanup records.
- [x] 2.3 Add live Vertica timestamp expected-failure case.
- [x] 2.4 Add live Vertica core datatype pass case.
- [x] 2.5 Record Vertica matrix evidence.

## Phase 3: Next Sources

- [x] 3.1 Add Postgres core datatype case.
- [x] 3.2 Add MySQL/MariaDB core datatype cases.
- [x] 3.3 Add SQL Server core datatype case.
- [x] 3.4 Add DB2 core datatype case.

## Phase 4: Decision

- [x] 4.1 Decide first adapter fix from evidence.
- [x] 4.2 Generate verification report.

## Phase 5: Edge Cases

- [x] 5.1 Add Postgres mixed/reserved identifier smoke.
- [x] 5.2 Fix Postgres source identifier quoting after regression test.
- [x] 5.3 Add Postgres boolean/binary/null focused smokes.
- [x] 5.4 Record Postgres edge-case matrix evidence.
- [x] 5.5 Add MySQL/MariaDB edge identifier smokes.
- [x] 5.6 Add Vertica edge identifier smokes.

## Phase 6: Remaining Edge Data Cases

- [x] 6.1 Add Vertica boolean/binary/null focused smokes.
- [x] 6.2 Add MySQL/MariaDB boolean/binary/null focused smokes.
- [x] 6.3 Add and run SQL Server identifier edge smokes.
- [x] 6.4 Add and run DB2 identifier edge smokes.

## Deferred

- [ ] Revisit DB2 core rerun later on a stable DB2 endpoint. Local Docker DB2 is too slow/flaky for this iteration, and DB2 is lower priority than the other adapters.
- [ ] Revisit Oracle on a stronger/stable Exasol runtime. Oracle 23c source booted on the Frankfurt EC2 with temp swap, but even a minimal Oracle wrapper preview can crash/stall the local ExaNano connection server through the existing Oracle adapter/JDBC path.
