# Plan: harden-master-migration-entrypoint

## Goal

Make `MIGRATE_TO_EXASOL` reliable enough to use as the master entry point before opening an upstream PR.

## Features

| Feature | Status | Spec |
|---------|--------|------|
| Master migration wrapper hardening | NEW | `migration/wrapper/spec.md` |

## Design

### Context

`MIGRATE_TO_EXASOL` dispatches to existing source-specific scripts. Most adapters return generated SQL rows. In `DEBUG = TRUE`, the wrapper previews those rows. In `DEBUG = FALSE`, the wrapper executes generated statements.

### Decision

Keep the wrapper thin: dispatch, normalize adapter rows, execute generated SQL, and report status. Do not change source-specific scripts or add S3 support to the wrapper.

### Consequences

The wrapper must handle empty/no-op adapter output clearly, preserve adapter errors, and have a runtime smoke harness that proves Exasol can execute the wrapper against representative adapter scripts.

## Implementation

1. Add regression tests for `DEBUG = FALSE` when adapters return no executable statements.
2. Update the wrapper summary so no-op output is reported as no generated executable SQL instead of successful execution.
3. Add an optional Exasol runtime smoke test using mock adapters with real `EXECUTE SCRIPT` calls.
4. Re-run Lua tests, syntax checks, diff checks, and local live smoke.

## Verification

### Scenario Coverage

| Scenario | Test |
|----------|------|
| Preview returns generated SQL rows | `test/test_migrate_to_exasol.lua` dispatch and preview cases |
| Execute mode runs generated SQL and skips comments | `test/test_migrate_to_exasol.lua` execution mode cases |
| Execute mode reports no generated executable SQL | `test/test_migrate_to_exasol.lua` no-op execution case |
| Adapter errors include source statement | `test/test_migrate_to_exasol.lua` adapter error case |
| Runtime wrapper works in Exasol with mock adapters | `test/test_migrate_to_exasol_runtime.py` |

### Manual Testing

```bash
lua test/test_migrate_to_exasol.lua
lua test/test_databricks_to_exasol.lua
python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ('test/create_script.py','test/export_res.py','test/mock_test.py','test/test_migrate_to_exasol_runtime.py')]"
python3 test/test_migrate_to_exasol_runtime.py
git diff --check
```

Expected: all commands exit 0. Runtime smoke prints passing preview, execute, failure, S3, and dispatch checks.

### Checklist

- Build: Python AST check exits 0.
- Test: Lua wrapper and Databricks tests exit 0.
- Runtime: optional Exasol mock smoke exits 0 when local Exasol is reachable.
- Lint/format: `git diff --check` exits 0.
