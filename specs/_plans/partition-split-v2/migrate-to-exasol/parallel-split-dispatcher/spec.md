# Feature: parallel-split-dispatcher (delta: PARTITION hierarchy step)

This delta makes PARTITION the first reachable step of the AUTO split hierarchy. When the metadata cache reports a partitioned source table and the dialect has a `partition_predicate` builder, the splitter emits one `STATEMENT '...'` clause per partition (chunked if `N_partitions > PARALLEL_STATEMENTS_max`). PARTITION wins over PK_RANGE / UNIQUE_NUM / DATE_BUCKET / HASH_NUM / ROWID whenever it fires.

## Background

* AUTO hierarchy order after this delta: **PARTITION** → PK_RANGE → UNIQUE_NUM → DATE_BUCKET → HASH_NUM → ROWID → SINGLE+INFO.
* Forced directive `PARALLEL_SPLIT=PARTITION` accepts no column override; partitions are dialect-defined.
* Chunking math (when `#partitions != N`):
  * `n_effective = min(#partitions, N)`.
  * If `#partitions <= N`: emit exactly `#partitions` STATEMENTs, one per partition. `PARALLEL_EFFECTIVE = #partitions`.
  * If `#partitions > N`: chunk partitions into `N` groups via `slice = ceil(#partitions / N)`. Group `k` covers `partitions[k*slice .. min((k+1)*slice, #partitions) - 1]`. Each STATEMENT's WHERE is the `OR` of the chunk's partition predicates. `PARALLEL_EFFECTIVE = N`.
* The `partition_predicate` is read verbatim from the cache JSON; the splitter MUST NOT mutate it. The cache JSON itself is the dialect-specific source of truth.
* NULL handling: PARTITION boundaries are exhaustive at the source — no `OR "col" IS NULL` is appended.
* Soft-fail contracts:
  * Forced `PARALLEL_SPLIT=PARTITION` on a source whose cache `src_partitions = NULL` MUST pass the IMPORT through unchanged and emit `INFO` noting "PARTITION requested but source not partitioned".
  * AUTO with `src_partitions = NULL` walks to PK_RANGE silently (no INFO row — partition not having a hit is normal).
  * Cache JSON parse failure (corrupt string) MUST soft-fail to PK_RANGE with INFO.

## Scenarios

### Scenario: AUTO picks PARTITION when partitions present

* *GIVEN* an adapter emits a single-statement IMPORT for `PUB.LOGS`
* *AND* the cache reports `src_partitions = '[{"name":"LOGS_2026Q1","predicate":"tableoid::regclass = ''LOGS_2026Q1''::regclass"}, {"name":"LOGS_2026Q2","predicate":"tableoid::regclass = ''LOGS_2026Q2''::regclass"}, {"name":"LOGS_2026Q3","predicate":"tableoid::regclass = ''LOGS_2026Q3''::regclass"}, {"name":"LOGS_2026Q4","predicate":"tableoid::regclass = ''LOGS_2026Q4''::regclass"}]'`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *AND* the source type is `POSTGRES`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit 4 `statement '...'` clauses, each AND-ing the inner SELECT's WHERE with the matching partition's `predicate` exactly as carried in the cache
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'PARTITION'`, `PARALLEL_EFFECTIVE = 4`

### Scenario: Fewer partitions than N collapses to N_effective = #partitions

* *GIVEN* the cache reports `src_partitions` is a 2-element list
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit exactly 2 `statement '...'` clauses (one per partition)
* *AND* the audit row SHALL carry `PARALLEL_EFFECTIVE = 2`

### Scenario: More partitions than N chunks via OR-of-predicates

* *GIVEN* the cache reports `src_partitions` is a 10-element list
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL emit exactly 4 `statement '...'` clauses
* *AND* clause 0 SHALL AND with `(<p0_predicate>) OR (<p1_predicate>) OR (<p2_predicate>)` (3 partitions)
* *AND* clause 1 SHALL AND with `(<p3>) OR (<p4>) OR (<p5>)`
* *AND* clauses 2 and 3 SHALL each cover the remaining 2 partitions
* *AND* the audit row SHALL carry `PARALLEL_EFFECTIVE = 4`

### Scenario: AUTO falls through to PK_RANGE when src_partitions NULL

* *GIVEN* the cache reports `src_partitions = NULL` AND `src_pk_col = 'ID'` with min/max populated
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the audit row SHALL carry `SPLIT_STRATEGY = 'PK_RANGE'`, `SPLIT_KEY = 'ID'`
* *AND* no INFO row about PARTITION SHALL be emitted (silent fall-through)

### Scenario: Forced PARALLEL_SPLIT=PARTITION soft-fails on non-partitioned source

* *GIVEN* the cache reports `src_partitions = NULL`
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=PARTITION`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the IMPORT MUST pass through unchanged
* *AND* an `INFO` audit row SHALL note that PARTITION was requested but the source has no known partitions
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'SINGLE'`, `PARALLEL_EFFECTIVE = 1`

### Scenario: Corrupt src_partitions JSON soft-fails to next step

* *GIVEN* the cache reports `src_partitions = '<not-valid-json>'`
* *AND* the cache ALSO reports `src_pk_col = 'ID'` with min/max populated
* *AND* `OPTIONS` contains `PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL fall through to PK_RANGE BETWEEN-based bucket emission per item 2
* *AND* the audit row SHALL carry `SPLIT_STRATEGY = 'PK_RANGE'`
* *AND* an `INFO` audit row SHALL note that the partition cache string was unparseable

### Scenario: PARTITION emits no IS NULL OR clause

* *GIVEN* the cache reports a non-empty `src_partitions` and `OPTIONS` requests PARTITION
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* none of the emitted STATEMENT clauses SHALL contain `IS NULL`
* *AND* the dispatcher MUST rely on the per-partition predicates being exhaustive at the source by construction
