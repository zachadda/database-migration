# Feature: parallel-split-dispatcher (delta: SQL Server PARTITION strategy reachable)

This delta makes the existing AUTO PARTITION step — already shipped by `2026-05-18-partition-split-v2` and reachable for POSTGRES — reachable for SQL Server. No dispatcher Lua change is required: `DIALECT_BY_SOURCE.SQLSERVER.partition_predicate` already returns `p.predicate` verbatim, and `pick_split_strategy`'s AUTO branch already short-circuits to PARTITION when `meta.src_partitions` is non-NULL and the dialect exposes a `partition_predicate` builder. This delta enumerates the scenarios that now hit the PARTITION branch once SQL Server's cache row is populated by the `source-metadata-roundtrip` delta in the same plan.

## Background

* All scenarios use `MIGRATE_TO_EXASOL` as the entry point.
* The AUTO split-strategy hierarchy from `2026-05-18-partition-split-v2` is unchanged: PARTITION → PK_RANGE → UNIQUE_NUM → DATE_BUCKET → HASH_NUM → ROWID → SINGLE+INFO.
* PARTITION is reached only when `meta.src_partitions` is non-NULL parseable JSON and `DIALECT_BY_SOURCE[source_type].partition_predicate` is a function. Both prerequisites hold for SQLSERVER (and its `AZURE_SQL` alias) after the source-metadata-roundtrip delta in this plan lands.
* The forced-`PARALLEL_SPLIT=PARTITION` soft-fail contract from the recorded plan applies uniformly to every source whose cache reports `src_partitions = NULL`; the SQLSERVER scenario below is a sanity-anchor of that contract on this source, not a new behavior.
* SQL Server identifier quoting via `[...]` is preserved verbatim out of the cache JSON; the dispatcher reads the `predicate` string byte-for-byte and does not re-quote.
* Multi-statement IMPORTs are not produced by the SQL Server adapter today, so the `MULTI_PASSTHROUGH` path from the permanent spec is not exercised here.

## Scenarios

<!-- DELTA:NEW -->
### Scenario: SQL Server AUTO picks PARTITION when partitions present

* *GIVEN* the source type is `SQLSERVER`
* *AND* an adapter emits a single-statement IMPORT for `dbo.partitioned_t`
* *AND* the metadata cache reports `src_partitions = '[{"name":"1","predicate":"$partition.pf_partitioned_t([id]) = 1"},{"name":"2","predicate":"$partition.pf_partitioned_t([id]) = 2"},{"name":"3","predicate":"$partition.pf_partitioned_t([id]) = 3"},{"name":"4","predicate":"$partition.pf_partitioned_t([id]) = 4"}]'`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=50;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 4 `statement '...'` clauses
* *AND* clause `k` MUST AND its inner SELECT's WHERE with `$partition.pf_partitioned_t([id]) = <k+1>` (the predicate from cache JSON element `k`, passed through verbatim by `DIALECT_BY_SOURCE.SQLSERVER.partition_predicate`)
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'PARTITION'`, `PARALLEL_EFFECTIVE = 4`
* *AND* NONE of the emitted clauses MAY contain `IS NULL` (PARTITION boundaries are exhaustive at the source)
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server AUTO falls through to PK_RANGE when src_partitions NULL

* *GIVEN* the source type is `SQLSERVER`
* *AND* an adapter emits a single-statement IMPORT for `dbo.big_t`
* *AND* the metadata cache reports `src_partitions = NULL` AND `src_pk_col = 'id'` with `src_pk_type = 'int'` and populated min/max
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=50;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the audit row SHALL carry `SPLIT_STRATEGY = 'PK_RANGE'`, `SPLIT_KEY = 'id'`
* *AND* no INFO row about PARTITION SHALL be emitted (silent fall-through)
* *AND* the existing BETWEEN bucket emission per `2026-05-18-pk-range-between-pushdown` SHALL be preserved byte-for-byte against the pre-delta smoke baseline
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server PARTITION predicate passed through verbatim

* *GIVEN* the source type is `SQLSERVER`
* *AND* the metadata cache reports a `src_partitions` whose first element's `predicate` is the literal string `$partition.pf_x([id]) = 1` (note the `$` and `[` characters)
* *AND* `OPTIONS` requests AUTO with `PARALLEL_STATEMENTS=2`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the emitted first `statement '...'` body MUST contain the substring `$partition.pf_x([id]) = 1` byte-for-byte
* *AND* the dispatcher MUST NOT re-quote, escape, or otherwise rewrite the `$` or `[` characters
* *AND* the dispatcher MUST NOT prepend or append any `"` quoting around the predicate
<!-- /DELTA:NEW -->

<!-- DELTA:NEW -->
### Scenario: SQL Server forced PARALLEL_SPLIT=PARTITION soft-fails on non-partitioned table

* *GIVEN* the source type is `SQLSERVER`
* *AND* the metadata cache reports `src_partitions = NULL` for `dbo.big_t`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=PARTITION`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the IMPORT MUST pass through unchanged
* *AND* an `INFO` audit row SHALL note that PARTITION was requested but the source has no known partitions
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'SINGLE'`, `PARALLEL_EFFECTIVE = 1`
<!-- /DELTA:NEW -->
