<!-- CHANGED -->
# Feature: Master Migration Wrapper Hardening

The master migration wrapper provides one `MIGRATE_TO_EXASOL` entry point that dispatches to source-specific migration scripts while preserving their generated-SQL workflow and keeping adapter scripts frozen.

## Background

* All scenarios use `MIGRATE_TO_EXASOL` as the entry point.
* `ADAPTER_SCHEMA` is a master-only parameter used only to qualify the `EXECUTE SCRIPT` target. When omitted, it defaults to `database_migration`.
* The wrapper MUST forward the original adapter argument list unchanged. A custom adapter schema may change the script lookup target, but it MUST NOT add, remove, or reorder adapter parameters.
* The wrapper MUST preserve adapter-generated rows byte-for-byte except for the wrapper's own normalization rows and the existing audit columns.
* Any `INFO` rows emitted by upstream transforms indicate a soft-fail or skipped optimization. The final `SUMMARY` row MUST make that condition visible in its summary text so callers can distinguish clean success from success-with-warnings.
* S3 remains outside the wrapper because it uses a separate loader shape.

## Scenarios

### Scenario: Preview Generated SQL

* *GIVEN* a supported source adapter returns generated SQL rows
* *WHEN* a user executes `MIGRATE_TO_EXASOL` with `DEBUG = TRUE`
* *THEN* the wrapper MUST return the generated SQL rows without executing them

### Scenario: Execute Generated SQL

* *GIVEN* a supported source adapter returns executable SQL rows and comment rows
* *WHEN* a user executes `MIGRATE_TO_EXASOL` with `DEBUG = FALSE`
* *THEN* the wrapper MUST execute executable SQL rows in order
* *AND* the wrapper MUST mark comment or empty rows as skipped
* *AND* the wrapper MUST return one status row per generated row

### Scenario: Dispatch Adapter From Custom Schema

* *GIVEN* `ADAPTER_SCHEMA = 'custom_schema'`
* *AND* a supported source adapter is installed in `custom_schema`
* *WHEN* a user executes `MIGRATE_TO_EXASOL`
* *THEN* the wrapper MUST resolve the adapter via `custom_schema`
* *AND* the wrapper MUST pass the adapter's original argument list unchanged
* *AND* the wrapper MUST NOT alter the adapter's generated rows or parameter order

### Scenario: Report No Generated Executable SQL

* *GIVEN* a supported source adapter returns only comments or no rows
* *WHEN* a user executes `MIGRATE_TO_EXASOL` with `DEBUG = FALSE`
* *THEN* the wrapper MUST report that no executable SQL statements were generated
* *AND* the wrapper MUST NOT report a successful execution summary when no statements ran

### Scenario: Report Warnings In Summary

* *GIVEN* the wrapper emits one or more `INFO` rows from metadata, gate, or split transforms
* *WHEN* the wrapper emits its final `SUMMARY` row
* *THEN* the summary text MUST indicate that the run completed with warnings
* *AND* the wrapper MUST preserve the existing success or preview result flag for the underlying run mode

### Scenario: Preserve Adapter Errors

* *GIVEN* a supported source adapter fails
* *WHEN* a user executes `MIGRATE_TO_EXASOL`
* *THEN* the wrapper MUST include the adapter error message
* *AND* the wrapper MUST include the adapter `EXECUTE SCRIPT` statement

### Scenario: Reject S3 In Master Wrapper

* *GIVEN* a user requests `SOURCE_TYPE = 'S3'`
* *WHEN* the wrapper validates the source
* *THEN* the wrapper MUST reject the request
* *AND* the wrapper MUST direct the user to `DATABASE_MIGRATION.S3_PARALLEL_READ`
<!-- /CHANGED -->
