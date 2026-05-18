# Feature: Master Migration Wrapper Hardening

The master migration wrapper provides one `MIGRATE_TO_EXASOL` entry point that dispatches to source-specific migration scripts while preserving their generated-SQL workflow.

## Background

Most source adapters return generated SQL rows through an Exasol `RETURNS TABLE` script.
The wrapper previews those rows when `DEBUG = TRUE` and executes executable generated statements when `DEBUG = FALSE`.
S3 remains outside the wrapper because it uses a separate loader shape.

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

### Scenario: Report No Generated Executable SQL

* *GIVEN* a supported source adapter returns only comments or no rows
* *WHEN* a user executes `MIGRATE_TO_EXASOL` with `DEBUG = FALSE`
* *THEN* the wrapper MUST report that no executable SQL statements were generated
* *AND* the wrapper MUST NOT report a successful execution summary when no statements ran

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
