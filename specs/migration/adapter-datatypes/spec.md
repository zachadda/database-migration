# Feature: Adapter Datatype Smoke Matrix

The adapter datatype smoke matrix proves source-specific datatype mappings through live `MIGRATE_TO_EXASOL` preview and execute paths.

## Background

Migration adapters inspect source metadata and generate Exasol DDL plus `IMPORT` statements. Wrapper smoke tests prove dispatch and execution flow, but source-specific type mappings need separate coverage because each source exposes different metadata strings and import behavior.

## Scenarios

### Scenario: Define Canonical Datatype Cases

* *GIVEN* the project needs comparable smoke coverage across source systems
* *WHEN* datatype smoke cases are defined
* *THEN* the case set MUST include numeric, text, date/time, boolean, binary, null, mixed-case identifier, and reserved-ish identifier coverage where supported by the source
* *AND* unsupported source datatypes MUST be recorded as not applicable instead of failed

### Scenario: Record Preview And Execute Evidence

* *GIVEN* a source database contains a datatype smoke table
* *WHEN* `MIGRATE_TO_EXASOL` runs with `DEBUG = TRUE` and then `DEBUG = FALSE`
* *THEN* the smoke result MUST record generated DDL rows
* *AND* the smoke result MUST record import execution status
* *AND* the smoke result MUST record loaded row count for each tested table

### Scenario: Preserve Mapping Or Import Failures

* *GIVEN* an adapter maps a source datatype to invalid or lossy Exasol DDL
* *WHEN* the generated SQL fails during wrapper execute mode
* *THEN* the smoke result MUST preserve the source datatype
* *AND* the smoke result MUST preserve the generated Exasol DDL
* *AND* the smoke result MUST preserve the adapter or import error message

### Scenario: Clean Up Live Smoke Resources

* *GIVEN* a live datatype smoke creates source containers, cloud security group rules, Exasol schemas, or connection objects
* *WHEN* the smoke run completes or fails
* *THEN* cleanup status MUST be recorded
* *AND* temporary source containers and network rules MUST be removed unless explicitly marked as pre-existing

### Scenario: Gate Adapter Fixes On Failing Evidence

* *GIVEN* a datatype smoke exposes a source adapter bug
* *WHEN* production adapter SQL is changed
* *THEN* the change MUST be backed by a failing smoke result from before the fix
* *AND* the fixed smoke case MUST pass after the adapter change
