# Plan: UNIQUE_NUM split strategy

## Status

Drafted 2026-05-18. **Not started.** Item 3 of the Speq 2 follow-up backlog. Builds on (and assumes shipped) `pk-range-between-pushdown` (item 2).

## Summary

The recorded `parallel-split-dispatcher` spec lists `UNIQUE_NUM` as hierarchy step 3 — `"WHERE pk BETWEEN lo AND hi on a numeric singleton unique index when no PK"`. The shipped `pick_split_strategy` does NOT have a UNIQUE_NUM branch (only `PK_RANGE` falls through to `DATE_BUCKET` directly), and the metadata cache does not carry a `src_unique_num_col` field. This plan extends the cache, adds the strategy branch, and wires the new strategy through the BETWEEN bucket math from item 2.

## Design

### Context

- Today: source has no numeric PK → strategy walks PK_RANGE → DATE_BUCKET. Sources where the only numeric singleton column is a non-PK unique index (e.g. `LEGACY_ID` carrying business-key uniqueness) cannot parallelize on that column even though it has a unique B-tree index that BETWEEN would exploit.
- The recorded scenario `"At-or-above-threshold IMPORT with no PK + numeric unique picks UNIQUE_NUM"` is currently unreachable because `pick_split_strategy` returns `DATE_BUCKET` (or further down the hierarchy) before ever testing for a unique-num column.
- Item 2 makes BETWEEN the canonical PK_RANGE shape. UNIQUE_NUM reuses the same builder — strategy carries `lo`/`hi`/`key` and `build_where_for_split` is dialect-uniform.

Goals
- Cache extension: add `src_unique_num_col VARCHAR(2000)`, `src_unique_num_type VARCHAR(200)`, `src_unique_num_min DECIMAL(36,0)`, `src_unique_num_max DECIMAL(36,0)`. Cache schema grows from 10 (after item 2) to 14 columns.
- `pick_split_strategy` AUTO mode: between PK_RANGE and DATE_BUCKET, inserts a UNIQUE_NUM step that fires when `src_pk_col` is NULL but `src_unique_num_col` is non-NULL and `is_numeric_pk_type(src_unique_num_type)`.
- Forced `PARALLEL_SPLIT=UNIQUE_NUM` directive accepted (currently rejected as unsupported mode).
- `build_where_for_split` UNIQUE_NUM branch dispatches through the same `pk_between` builder added in item 2; NULL min/max falls back to MOD identically.
- Per-source SQL extension: discover one numeric singleton unique-index column NOT identified as the PK. Sources without sufficient catalog visibility (Snowflake, Databricks) may return NULL — splitter then walks past UNIQUE_NUM to DATE_BUCKET as today.

Non-Goals
- Not relaxing the "singleton" constraint. Composite unique indexes remain ignored.
- Not preferring UNIQUE_NUM over PK_RANGE when both exist. PK_RANGE always wins.
- Not modifying DATE_BUCKET / HASH_NUM / ROWID.
- Not implementing UNIQUE_NUM detection for sources whose catalogs cannot cheaply expose unique-index column lists (`SOURCE_METADATA_BY_SOURCE` entry returns NULL — strategy falls through gracefully).

### Decision

#### Cache schema extension (delta on top of item 2's 10-col)

```sql
import into (
  src_schema varchar(2000), src_table varchar(2000),
  src_rows decimal(36,0),
  src_pk_col varchar(2000), src_pk_type varchar(200),
  src_pk_min decimal(36,0), src_pk_max decimal(36,0),
  src_unique_num_col  varchar(2000), src_unique_num_type varchar(200),         -- NEW
  src_unique_num_min  decimal(36,0), src_unique_num_max  decimal(36,0),        -- NEW
  src_date_col varchar(2000), src_num_col varchar(2000),
  src_partitioned boolean
) from jdbc at <conn> statement '<source-specific SQL>'
```

#### Per-source SQL — POSTGRES (illustrative)

Already discovers PK via `pg_constraint`. New subquery joins `pg_indexes` + `pg_class` + `pg_attribute` for `(indisunique AND NOT indisprimary AND single-column AND numeric)` and returns first match.

#### `pick_split_strategy` insertion

```lua
if directive.mode == 'AUTO' then
    if meta == nil then return nil, 'metadata cache empty' end
    if meta.src_pk_col and is_numeric_pk_type(meta.src_pk_type) then
        return { strategy = 'PK_RANGE', key = meta.src_pk_col,
                 lo = meta.src_pk_min, hi = meta.src_pk_max }
    end
    if meta.src_unique_num_col and is_numeric_pk_type(meta.src_unique_num_type) then
        return { strategy = 'UNIQUE_NUM', key = meta.src_unique_num_col,
                 lo = meta.src_unique_num_min, hi = meta.src_unique_num_max }
    end
    if meta.src_date_col then ...
```

Forced mode `directive.mode == 'UNIQUE_NUM'` accepts an optional column name override (`PARALLEL_SPLIT=UNIQUE_NUM:LEGACY_ID`).

`build_where_for_split` is unchanged from item 2 — the dispatch on `decision.strategy == 'PK_RANGE' or decision.strategy == 'UNIQUE_NUM'` already routes both through the same builder.

## Tasks

1. Author spec deltas
   - `migrate-to-exasol/source-metadata-roundtrip/spec.md` (4 new cache cols + per-source NULL contract)
   - `migrate-to-exasol/parallel-split-dispatcher/spec.md` (UNIQUE_NUM hierarchy step + forced directive)
2. TDD red: ~6 new Lua scenarios (AUTO picks UNIQUE_NUM, forced picks UNIQUE_NUM, missing unique falls through to DATE_BUCKET, NULL min/max falls back to MOD via item 2's contract, MySQL backtick, SQL Server bracket).
3. Extend `transform_for_metadata` outer SQL to 14 cols.
4. Update each `SOURCE_METADATA_BY_SOURCE` entry that can supply unique-index info: POSTGRES, MYSQL, SQLSERVER, ORACLE, DB2, REDSHIFT, VERTICA, HANA, NETEZZA, TERADATA. SNOWFLAKE, BIGQUERY, DATABRICKS, MARIADB→MYSQL alias return NULL columns.
5. Add UNIQUE_NUM branch to `pick_split_strategy` (both AUTO and forced).
6. Run Lua tests to green.
7. py-runtime smoke.
8. Live smoke against Postgres legacy table without PK but with unique numeric column.
9. `speq plan validate` PASS.
10. Commit, push, `speq record`.
