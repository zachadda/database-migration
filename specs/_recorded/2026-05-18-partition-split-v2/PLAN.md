# Plan: PARTITION split v2

## Status

Drafted 2026-05-18. **Not started.** Item 4 of the Speq 2 follow-up backlog. Independent of items 2 and 3 (partition strategy uses its own decision shape, not BETWEEN buckets).

## Summary

Today `pick_split_strategy` returns the error `"PARALLEL_SPLIT=PARTITION not supported in v1"` and AUTO never tries PARTITION. This plan implements step 1 of the hierarchy: discover each table's native source partitions and emit one `STATEMENT '...'` clause per partition, with the source engine's native partition-prune clause. Native partitions are always the cheapest possible parallel split — they map onto the source's physical files / segments — so PARTITION SHALL win over PK_RANGE / UNIQUE_NUM / DATE_BUCKET / HASH_NUM / ROWID whenever it is available.

## Design

### Context

- Partitioned tables on Postgres (declarative + inheritance), Oracle, SQL Server, BigQuery, Snowflake (micro-partitions are NOT user-addressable; out of scope), Vertica, Databricks (Hive-style), Redshift (sort keys, not real partitions; out of scope) all expose their partition definition through catalog queries.
- Currently `src_partitioned BOOLEAN` exists in the cache but is unused. This plan extends it to a structured per-partition list: `src_partitions VARCHAR(2000000)` carrying a JSON array of `{name, predicate}` pairs.
- One STATEMENT per partition is the canonical shape. If `N_partitions > PARALLEL_STATEMENTS_max`, the splitter MUST collapse multiple partitions into one STATEMENT each (chunking) to respect the ceiling. If `N_partitions < PARALLEL_STATEMENTS`, the splitter MUST emit `N_partitions` STATEMENTS only.
- Partition predicates are source-dialect-specific (`tableoid` for PG, `PARTITION (p_name)` hint for Oracle, `WHERE _PARTITIONTIME` for BQ ingestion-time, `WHERE pcol = 'p1'` for Vertica/Databricks hash-style). Per-dialect builder `partition_predicate(partition_descriptor)` encapsulates this.

Goals
- New cache column `src_partitions` (JSON string).
- Per-source SQL extension that lists partitions for partitioned tables; returns NULL for non-partitioned.
- `pick_split_strategy` AUTO hierarchy makes PARTITION step 1.
- `build_where_for_split` PARTITION branch emits `WHERE` from the dialect's `partition_predicate` helper.
- Forced `PARALLEL_SPLIT=PARTITION` honored; soft-fails with INFO when no partitions known.

Non-Goals
- Snowflake micro-partitions (not user-addressable).
- Redshift (sort keys, not real partitions).
- Sub-partitioning (one level of partitioning only).
- Cross-partition rebalancing if partitions are wildly skewed. Operators can override with `PARALLEL_SPLIT=PK_RANGE` etc.
- Streaming the partition list when it exceeds `VARCHAR(2000000)` (rare in practice; if hit, splitter soft-fails to next hierarchy step with INFO).

### Decision

#### Cache schema extension (delta on top of items 2 + 3 — 14 cols)

Add `src_partitions VARCHAR(2000000)`. Final post-delta column list ends with `..., src_date_col, src_num_col, src_partitioned, src_partitions`.

#### Per-source partition discovery

| Source | Partition source SQL (illustrative) |
|---|---|
| POSTGRES | `select c.relname, pg_get_expr(c.relpartbound, c.oid) from pg_class p join pg_inherits inh on inh.inhparent = p.oid join pg_class c on c.oid = inh.inhrelid where p.relname = '<t>'` → JSON list of `{name, predicate}` where predicate is `tableoid::regclass = '<name>'::regclass` |
| ORACLE | `select partition_name, high_value from all_tab_partitions where table_name = '<T>' order by partition_position` → `PARTITION (<name>)` hint or `WHERE` predicate from `high_value` |
| SQLSERVER | `sys.partitions` + `sys.partition_range_values` |
| BIGQUERY | `INFORMATION_SCHEMA.PARTITIONS` for ingestion-time / column-partitioned tables |
| VERTICA | `select partition_key from partitions where projection_name = '<P>' group by 1` |
| DATABRICKS | `SHOW PARTITIONS <schema>.<table>` (returned via JDBC; aggregated client-side into JSON) |

Sources not in this list return NULL — splitter walks past PARTITION to PK_RANGE etc.

#### Splitter dispatch

```lua
function pick_split_strategy(meta, options, dialect, source_type)
    ...
    if directive.mode == 'AUTO' then
        if meta and meta.src_partitions and dialect and dialect.partition_predicate then
            return { strategy = 'PARTITION', partitions = parse_partitions(meta.src_partitions) }
        end
        -- then PK_RANGE, UNIQUE_NUM, ...
    end
    if directive.mode == 'PARTITION' then ... end
end
```

`build_where_for_split` PARTITION branch uses `n` and `k` to slice the parsed partition list. If `#partitions >= n`, partition `k` covers `partitions[ceil(k * #partitions / n) .. ceil((k+1) * #partitions / n)]` joined with `OR`. If `#partitions < n`, emit one STATEMENT per partition with `n_effective = #partitions`.

## Tasks

1. Author spec deltas
   - `migrate-to-exasol/source-metadata-roundtrip/spec.md` (new `src_partitions` JSON column)
   - `migrate-to-exasol/parallel-split-dispatcher/spec.md` (PARTITION hierarchy step + chunking math + soft-fail contract)
2. TDD red: ~8 new Lua scenarios (PG partitioned table, Oracle PARTITION hint, BQ _PARTITIONTIME, fewer-partitions-than-N, more-partitions-than-N chunking, non-partitioned source falls through to PK_RANGE, forced PARTITION soft-fail on non-partitioned, `partition_predicate` helper unit tests).
3. Extend `transform_for_metadata` outer SQL.
4. Per-source partition discovery SQL for POSTGRES, ORACLE, SQLSERVER, BIGQUERY, VERTICA, DATABRICKS. Others return NULL.
5. Per-dialect `partition_predicate` helper.
6. `pick_split_strategy` PARTITION branch (AUTO + forced).
7. `build_where_for_split` PARTITION branch + chunking math.
8. Run Lua tests.
9. py-runtime smoke.
10. Live smoke: PG partitioned table + Databricks partitioned table.
11. `speq plan validate` PASS.
12. Commit, push, `speq record`.
