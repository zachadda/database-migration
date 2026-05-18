# Plan: add-adapter-datatype-smoke-matrix

## Goal

Create live datatype smoke coverage for migration adapters so wrapper readiness is measured against realistic source column types, not only tiny happy-path tables.

## Features

| Feature | Status | Spec |
|---------|--------|------|
| Adapter datatype smoke matrix | NEW | `migration/adapter-datatypes/spec.md` |

## Design

### Context

`MIGRATE_TO_EXASOL` now proves dispatch, preview, and execute paths across several live sources. Those smokes use narrow tables and do not prove source-specific type mappings. Vertica already exposed a real adapter issue: a `TIMESTAMP` source column maps to `varchar(14)`, causing import truncation.

### Decision

Build a local-only datatype smoke matrix that creates representative source tables, runs the existing adapter through `MIGRATE_TO_EXASOL`, records generated Exasol DDL, executes imports, and stores pass/fail evidence by source/type. Keep the upstream PR code unchanged until a specific adapter fix is justified by a failing datatype smoke.

### Consequences

The matrix can separate three outcomes: wrapper bug, adapter type-mapping bug, and source/container limitation. Broad adapter fixes will be handled as source-specific follow-up changes with a failing smoke first.

## Implementation

1. Define a canonical datatype case set for numeric, text, date/time, boolean, binary, nulls, mixed-case identifiers, and reserved-ish identifiers.
2. Add a local smoke harness that can run one source at a time and emit a compact matrix result.
3. Start with Vertica because the timestamp failure is already reproduced.
4. Add easy live sources next: Postgres, MySQL, MariaDB, SQL Server, and DB2.
5. Add cloud-backed sources after local sources: Snowflake and Databricks.
6. Record source-specific failures and recommended handling in a local matrix report.
7. Only change production adapter SQL when a failing datatype case has a small, defensible fix.

## Verification

### Scenario Coverage

| Scenario | Test |
|----------|------|
| Canonical datatype cases are defined once | `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --self-test canonical-cases` |
| A source datatype smoke records generated DDL and load result | `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --self-test result-shape` |
| A mapping/import failure is recorded without hiding the adapter error | `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --self-test failure-preserves-error` |
| Live Vertica timestamp regression is covered | `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case timestamp` |
| Live source resources are cleaned up after a smoke | `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --self-test cleanup-record` |

### Manual Testing

```bash
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case timestamp
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case core
git diff --check
```

Expected: commands exit 0 for passing cases. Known mapping failures exit 0 only when they are recorded as expected failures with source, datatype, generated DDL, adapter/import error, and cleanup status.

### Checklist

- Build: Python AST check exits 0 for existing Python test utilities and the datatype smoke harness.
- Test: targeted datatype smoke tests exit 0 for implemented source cases.
- Runtime: live Exasol plus source DB smoke commands produce matrix rows.
- Lint/format: `git diff --check` exits 0.
