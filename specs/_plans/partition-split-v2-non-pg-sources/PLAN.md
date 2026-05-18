# Plan: partition-split-v2-non-pg-sources

## Summary

Extend native-partition discovery — already shipped for POSTGRES in `specs/_recorded/2026-05-18-partition-split-v2/` — to SQL Server, the next-highest-value source with an active adapter and live-green BETWEEN smoke. Slice 0 hardens the bare-`NULL` cast in ORACLE, VERTICA, and DATABRICKS metadata templates so the cache column added by v2 stops being a latent ETL-1202 once those sources are exercised.

## Design

### Context

`SOURCE_METADATA_BY_SOURCE` (master script `migrate_to_exasol.sql` line 328) returns one row per `(src_schema, src_table)` with 15 cache columns. Column 15 — `src_partitions VARCHAR(2000000)` — was added by the recorded plan `2026-05-18-partition-split-v2`. The outer IMPORT schema in `transform_for_metadata` (lines 952 + 994) declares that column as `varchar(2000000)`.

The JDBC outer-schema cast invariant (durable rule, confirmed by the 2026-05-18 tier-0 cast-fix incident): every column in every per-source template MUST cast to the outer-declared type, otherwise JDBC type inference rejects the inner SQL, the inner `IMPORT FROM JDBC` aborts with `ETL-1202`, the metadata phase silently returns `available = false`, and every table for that source degrades to `strategy = SINGLE` without an INFO row. Lua mock tests cannot detect this — the failure mode is JDBC-level.

Today:

- POSTGRES template populates `src_partitions` for real via `pg_inherits` + `string_agg` + `quote_literal`.
- MYSQL and SQLSERVER templates already returned `cast(NULL as varchar(8000))` after the tier-0 cast fix (smoke-green 2026-05-18). They are cast-safe but do not yet enumerate partitions.
- ORACLE, VERTICA, DATABRICKS templates still return bare `NULL` for column 15 (and 14). They have not been exercised by the parallel-split smoke matrix yet, but the moment they are, ETL-1202 will silently disable the splitter for every table.
- DIALECT_BY_SOURCE already exposes `partition_predicate = function(p) return p.predicate end` for POSTGRES, SQLSERVER, ORACLE, VERTICA, DATABRICKS, BIGQUERY. The dispatcher contract reads the predicate string verbatim from cache JSON; no Lua change is needed once a source populates the column with the canonical `[{"name":...,"predicate":...}, ...]` shape.

Per the master-script architecture invariant: all of this work lives in `migrate_to_exasol.sql`. Adapter scripts (`sqlserver_to_exasol.sql`, `oracle_to_exasol.sql`, etc.) are frozen and MUST NOT be touched.

- **Goals**
  - SQLSERVER metadata template populates `src_partitions` JSON for tables whose `partition_number > 1` (i.e. real range/list partitioning, not the implicit single-partition default).
  - ORACLE, VERTICA, DATABRICKS metadata templates are made cast-safe for `src_partitioned` (column 14, BOOLEAN) and `src_partitions` (column 15, VARCHAR(2000000)) without changing what they return semantically — both still resolve to NULL/FALSE, just via explicit casts to the outer-declared type.
  - SQLSERVER AUTO hierarchy now reaches PARTITION as step 1 when the cache has a non-empty `src_partitions`, matching POSTGRES's existing behavior.
  - A `_reference/smoke_parallel_split_sqlserver.py` extension verifies the PARTITION path end-to-end against `sqlserverdb` on `dbm-net`.

- **Non-Goals**
  - ORACLE / VERTICA / DATABRICKS native-partition discovery — deferred to per-source follow-up plans. Slice 0 here only fixes the cast invariant; it does not populate the partition list.
  - BIGQUERY native-partition discovery — blocked at the JDBC level per recorded plan `2026-05-18-bigquery-per-dataset-metadata`; deferred until that recorded plan ships.
  - SQLSERVER multi-column partition functions (rare; `sys.partition_parameters` shows single-column only in the v2 supported shape). Multi-column partition functions soft-fail to NULL → silent fall-through to PK_RANGE.
  - Streaming partition lists larger than `varchar(2000000)`. Cache JSON > 2 MB soft-fails to NULL per the v1 partition-split-v2 contract.
  - Changing the `DIALECT_BY_SOURCE.SQLSERVER.partition_predicate` implementation — already returns `p.predicate` verbatim, which is the canonical contract.

### Decision

#### Architecture

```
┌───────────────────────────────┐    ┌───────────────────────────────┐
│ SOURCE_METADATA_BY_SOURCE     │    │ DIALECT_BY_SOURCE             │
│   SQLSERVER.template          │    │   SQLSERVER.partition_predicate│
│     col 14 src_partitioned    │    │   (already returns p.predicate)│
│     col 15 src_partitions     │    └───────────────────────────────┘
│       ← JSON list of          │                  │
│         {name, predicate}     │                  ▼
│   ORACLE/VERTICA/DATABRICKS   │    ┌───────────────────────────────┐
│     cols 14+15 cast-hardened  │    │ pick_split_strategy           │
│     (still NULL/FALSE)        │    │   AUTO → PARTITION when       │
└───────────────────────────────┘    │   src_partitions present and  │
              │                       │   dialect has partition_pred  │
              ▼                       └───────────────────────────────┘
┌───────────────────────────────┐
│ transform_for_metadata        │
│   IMPORT FROM JDBC outer cast │  (unchanged — varchar(2000000) for col 15,
│   schema declares col types   │   boolean for col 14)
└───────────────────────────────┘
```

#### Patterns

| Pattern | Where | Why |
|---|---|---|
| Inline JSON-array aggregation in source SQL | SQLSERVER template col 15 | Single-statement metadata round-trip is the v1 contract; avoid the Databricks-style side-channel `IMPORT FROM JDBC at <CONN> statement 'SHOW PARTITIONS'` round-trip for SQL Server (the catalog views support the aggregation directly via `FOR JSON PATH` or `STRING_AGG`). |
| `$partition.<func>([<col>]) = N` per-partition predicate | SQLSERVER `partitions[].predicate` | Pushdown-clean; SQL Server's partition pruning recognizes `$partition.func(col)` exactly. Alternative range predicates from `sys.partition_range_values` would require per-table boundary math; the partition-function reference is one literal per partition. |
| `cast(NULL as <outer-type>)` for not-yet-populated columns | ORACLE / VERTICA / DATABRICKS templates cols 14 + 15 | JDBC outer-schema cast invariant. Identical pattern to the 2026-05-18 tier-0 cast fix for MYSQL + SQLSERVER. |
| Source-side `WHERE` enumeration of `(schema, table)` pairs | SQLSERVER template (unchanged) | Existing `pair` template + `<PREDICATE>` substitution remain authoritative. |

#### Consequences

| Decision | Alternatives Considered | Rationale |
|---|---|---|
| `$partition.<func>([col]) = N` for SQLSERVER partition predicate | Column-range `[col] >= lo AND [col] < hi` parsed from `sys.partition_range_values` | `$partition` is one literal per partition with zero boundary math, recognized natively by SQL Server's partition-elimination optimizer. The range form would require per-table reads of `sys.partition_functions` + `sys.partition_range_values` to compute boundaries. |
| Use `STRING_AGG(... , ',')` inside the existing SQLSERVER row | Per-partition side-channel `IMPORT FROM JDBC` | Keeps the v1 contract of one metadata round-trip per migration; `STRING_AGG` is available in SQL Server 2017+ and azure-sql-edge (the smoke image). |
| Slice 0 covers ORACLE + VERTICA + DATABRICKS only | Cover all bare-NULL templates (also SNOWFLAKE, REDSHIFT, DB2, HANA, NETEZZA, TERADATA) | The user-confirmed scope is the v2-partition-eligible set (ORACLE/VERTICA/DATABRICKS/BIGQUERY). The other six sources have no `partition_predicate` dialect entry and remain bare-NULL until each gains one; a separate audit-and-harden plan can cover them when those slices land. Documented as known-latent in this design. |
| Defer SQLSERVER non-azure-sql-edge variants (Synapse, Azure SQL DB) | Make slice 1 unblock all `SQLSERVER`-aliased sources | Slice 1 already covers `AZURE_SQL` automatically via the existing `SOURCE_METADATA_BY_SOURCE.AZURE_SQL = SOURCE_METADATA_BY_SOURCE.SQLSERVER` alias. Synapse uses a different partition catalog (`sys.pdw_*`) and stays out of scope. |
| Defer ORACLE / VERTICA / DATABRICKS partition discovery to follow-up plans | One mega-plan with all four sources | SQLSERVER is the only non-PG source whose live smoke matrix is wired up today. ORACLE adapter is active but no parallel-split live smoke exists yet. VERTICA + DATABRICKS adapters exist but neither has a `_reference/smoke_parallel_split_<src>.py`. Adding partition discovery without a smoke matrix risks the JDBC invariant going undetected. |

## Features

| Feature | Status | Spec |
|---|---|---|
| source-metadata-roundtrip | CHANGED | `migrate-to-exasol/source-metadata-roundtrip/spec.md` |
| parallel-split-dispatcher | CHANGED | `migrate-to-exasol/parallel-split-dispatcher/spec.md` |

The deltas are layered on top of the recorded plan `2026-05-18-partition-split-v2`, which has shipped in code (HEAD `093d2d0`) but is not yet merged into permanent specs.

## Dependencies

- Recorded plan `2026-05-18-partition-split-v2` already shipped in code: dialect `partition_predicate` helpers and `pick_split_strategy` AUTO PARTITION branch are present. This plan adds the source-side metadata that those helpers consume.
- `sqlserverdb` container on `dbm-net` bridge (azure-sql-edge image), reused by `_reference/smoke_parallel_split_sqlserver.py`. SQL Server 2017+ `STRING_AGG` is available.
- No new Exasol-side capability required.

## Implementation Tasks

1. **Slice 0 — cast hardening** (prerequisite for any future partition-discovery plan touching these sources)
   - In `migrate_to_exasol.sql`, replace bare `NULL` in cols 14 + 15 of the ORACLE template with `cast(NULL as varchar(2000)) /* src_partitioned placeholder, replaced when slice ships */` — actually `cast(NULL as boolean)` for col 14 and `cast(NULL as varchar(2000000))` for col 15. Same fix for VERTICA and DATABRICKS templates.
   - (No semantic change — they still resolve to NULL → splitter falls through.)
2. **Slice 1 — SQLSERVER partition discovery**
   - Replace `cast(NULL as varchar(8000)) as src_partitions` in the SQLSERVER template with the inlined `STRING_AGG` aggregation specified in the source-metadata-roundtrip delta below. Keep cast width at `varchar(2000000)` to match the outer schema.
   - Verify `DIALECT_BY_SOURCE.SQLSERVER.partition_predicate` still reads `p.predicate` verbatim — no change.
3. **Lua mock coverage**
   - `test/test_migrate_to_exasol.lua` — add 4 scenarios:
     - SQLSERVER partitioned table populates `src_partitions` JSON; AUTO picks PARTITION; cache JSON predicates are passed through verbatim.
     - SQLSERVER non-partitioned table emits `src_partitions = NULL`; AUTO falls through to PK_RANGE.
     - ORACLE template renders without bare-`NULL` in cols 14 + 15 (regex-grep assertion on the rendered template).
     - VERTICA + DATABRICKS templates render without bare-`NULL` in cols 14 + 15.
4. **Live smoke**
   - Extend `_reference/smoke_parallel_split_sqlserver.py` with a `partitioned_t` fixture: a 4-partition partition function on a numeric column, 200 rows distributed across partitions, threshold = 50 so the splitter fires.
   - Run; assert `SPLIT_STRATEGY = 'PARTITION'`, `PARALLEL_EFFECTIVE = 4`, and that the 4 emitted STATEMENT bodies each contain `$partition.<func>([col]) = <N>`.
5. **No-regression checks**
   - Re-run existing `_reference/smoke_parallel_split_postgres.py` + `smoke_parallel_split_mysql.py` + `smoke_parallel_split_sqlserver.py` (non-partitioned tables) to confirm no regression in tier-0 + BETWEEN paths.
   - Run `lua test/test_migrate_to_exasol.lua` and `python3 test/test_migrate_to_exasol_runtime.py`.

## Parallelization

| Parallel Group | Tasks |
|---|---|
| Group A | Slice 0 (cast hardening — single-file edit per source, mechanically independent) |
| Group B | Slice 1 (SQLSERVER partition discovery) + Lua mock additions |
| Group C | Live smoke extension + execution |

Sequential dependencies:
- Group A → Group B (cast hardening should land first to keep slice 1 commits noise-free)
- Group B → Group C (live smoke needs the new template in place)

## Dead Code Removal

| Type | Location | Reason |
|---|---|---|
| Bare-`NULL` template fragment | `migrate_to_exasol.sql` ORACLE / VERTICA / DATABRICKS templates cols 14 + 15 | Replaced by explicit `cast(NULL as <outer-type>)` per JDBC outer-schema cast invariant |
| `cast(NULL as varchar(8000)) as src_partitions` for SQLSERVER | `migrate_to_exasol.sql` SQLSERVER template col 15 | Replaced by inlined `STRING_AGG` JSON aggregation |

## Verification

### Scenario Coverage

| Scenario | Test Type | Test Location | Test Name |
|---|---|---|---|
| SQL Server partitioned table populates src_partitions | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_partitioned_t_picks_partition_strategy` (new) |
| SQL Server non-partitioned table emits src_partitions = NULL | Integration | `_reference/smoke_parallel_split_sqlserver.py` | existing `big_t` BETWEEN path (re-asserted) |
| AUTO picks PARTITION when SQL Server cache reports partitions | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_partitioned_t_picks_partition_strategy` (new) |
| ORACLE / VERTICA / DATABRICKS template cast-safe for cols 14 + 15 | Unit | `test/test_migrate_to_exasol.lua` | `test_metadata_template_no_bare_null_cols_14_15` (new) |
| SQL Server partitioned-table SQL renders via SOURCE_METADATA_BY_SOURCE dispatch | Unit | `test/test_migrate_to_exasol.lua` | `test_sqlserver_metadata_template_contains_string_agg_for_src_partitions` (new) |
| SQL Server multi-column partition function soft-fails to NULL | Integration | `_reference/smoke_parallel_split_sqlserver.py` | `test_multi_column_partition_falls_through_to_pk_range` (new) |

Unit tests are appropriate for the template-shape scenarios because they test pure string composition with no source-side I/O. The end-to-end partition-strategy emission requires a real SQL Server, so it is integration.

### Manual Testing

| Feature | Command | Expected Output |
|---|---|---|
| source-metadata-roundtrip (SQLSERVER partition discovery) | `python3 _reference/smoke_parallel_split_sqlserver.py` | Stdout contains `partitioned_t -> SPLIT_STRATEGY=PARTITION, PARALLEL_EFFECTIVE=4`; each emitted STATEMENT body matches `\$partition\.\w+\(\[\w+\]\) = \d` |
| source-metadata-roundtrip (cast hardening) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && grep -nE "(ORACLE|VERTICA|DATABRICKS).*from\b" migrate_to_exasol.sql -A 0 -B 4 \| grep -E ', NULL,\s*NULL'` | Empty output (no bare-NULL pairs remaining in the partition columns of those three templates) |
| parallel-split-dispatcher (SQLSERVER AUTO PARTITION) | `python3 _reference/smoke_parallel_split_sqlserver.py 2>&1 \| grep "partitioned_t"` | Single line showing `SPLIT_STRATEGY=PARTITION` (not `PK_RANGE`, not `SINGLE`) |

### Checklist

| Step | Command | Expected |
|---|---|---|
| Build | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ('test/create_script.py','test/export_res.py','test/mock_test.py')]"` | Exit 0 |
| Test (Lua) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && lua test/test_migrate_to_exasol.lua` | 0 failures |
| Test (py-runtime) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 test/test_migrate_to_exasol_runtime.py` | 0 failures |
| Live smoke (SQLSERVER) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 _reference/smoke_parallel_split_sqlserver.py` | All assertions PASS, exit 0 |
| Regression smoke (PG) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 _reference/smoke_parallel_split_postgres.py` | All assertions PASS, exit 0 |
| Regression smoke (MySQL) | `cd /Users/zachary.adda/Documents/GitHub/database-migration && python3 _reference/smoke_parallel_split_mysql.py` | All assertions PASS, exit 0 |
| Lint | `cd /Users/zachary.adda/Documents/GitHub/database-migration && git diff --check` | 0 errors/warnings |
| Format | (no formatter defined for this repo per mission.md) | n/a |
