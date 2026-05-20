# Plan: Harden master wrapper contract

## Status
Drafted 2026-05-20. This plan hardens the master wrapper boundary without changing frozen adapter scripts.

## Motivation
- Keep `ADAPTER_SCHEMA` strictly master-only so direct adapter callers stay byte-for-byte stable.
- Make soft-fail and skipped-optimization behavior visible in the wrapper return payload instead of relying on INFO rows alone.
- Preserve the existing architecture rule that cross-cutting behavior belongs in `migrate_to_exasol.sql`, not in adapter scripts.

## Features

| Feature | Status | Spec |
|---------|--------|------|
| Master wrapper contract hardening | NEW | `migration/wrapper/spec.md` |

## Design

### Context

`MIGRATE_TO_EXASOL` dispatches to source-specific scripts, normalizes their generated SQL rows, and emits a final `SUMMARY` row.
The current architecture already treats adapter scripts as frozen and keeps cross-cutting behavior in the wrapper.

### Decision

Keep the wrapper as the only place that resolves `ADAPTER_SCHEMA`, executes adapter scripts, and summarizes the run.
Do not add adapter-side schema plumbing or change adapter argument lists.
When any upstream transform emits an `INFO` row, make the final `SUMMARY` row explicitly say the run completed with warnings.

### Consequences

The wrapper remains the stable compatibility layer for both direct adapter callers and orchestrated migration runs.
Soft-fail behavior stays non-fatal, but it becomes visible in the returned row stream rather than being inferred only from `INFO` rows.

## Verification

### Scenario Coverage

| Scenario | Test |
|----------|------|
| Preview generates rows from the resolved adapter script | `test/test_migrate_to_exasol.lua` wrapper dispatch cases |
| `ADAPTER_SCHEMA` defaults to `database_migration` | `test/test_migrate_to_exasol.lua` dispatch default case |
| `ADAPTER_SCHEMA` changes only the `EXECUTE SCRIPT` target, not the adapter args | `test/test_migrate_to_exasol.lua` custom-schema dispatch case |
| INFO rows surface as a warning summary | `test/test_migrate_to_exasol.lua` soft-fail summary case |
| Runtime wrapper dispatch still works end to end | `test/test_migrate_to_exasol_runtime.py` |

### Manual Testing

```bash
lua test/test_migrate_to_exasol.lua
python3 test/test_migrate_to_exasol_runtime.py
git diff --check
```

Expected: the Lua and runtime suites exit 0, and the wrapper summary text distinguishes clean success from success-with-warnings when INFO rows are present.

### Checklist

- Build: Lua syntax validation exits 0.
- Test: wrapper unit tests and runtime smoke exit 0.
- Lint/format: `git diff --check` exits 0.
