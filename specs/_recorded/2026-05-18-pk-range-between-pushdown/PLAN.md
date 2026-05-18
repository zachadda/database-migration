# Plan: PK_RANGE BETWEEN pushdown

## Status

Drafted 2026-05-18. **Not started.** Item 2 of the Speq 2 follow-up backlog.

## Summary

The recorded `parallel-split-dispatcher` spec already mandates `WHERE "pk" BETWEEN lo AND hi` for the `PK_RANGE` and `UNIQUE_NUM` strategies, but the shipped impl emits `MOD("pk", N) = K` instead. MOD forces the source engine to full-scan and apply a filter per partition; BETWEEN lets it use a B-tree range scan and is the only path to real parallel speedup on OLTP sources. This plan brings the impl up to the recorded spec, extends the metadata round-trip with `src_pk_min` / `src_pk_max`, and adds per-dialect identifier quoting for the BETWEEN builder.

## Design

### Context

- `parallel-split-dispatcher/spec.md` line 16 mandates `BETWEEN lo AND hi` for PK_RANGE; line 17 mandates the same shape for UNIQUE_NUM.
- `source-metadata-roundtrip/spec.md` defines an 8-column cache schema (`src_schema, src_table, src_rows, src_pk_col, src_pk_type, src_date_col, src_num_col, src_partitioned`) which does NOT carry `min(pk)` / `max(pk)`.
- `build_where_for_split` (`migrate_to_exasol.sql:1006`) currently dispatches PK_RANGE and UNIQUE_NUM through each dialect's `pk_where(col, N, K)` builder, which everywhere returns a MOD expression.
- 14 entries in `SOURCE_METADATA_BY_SOURCE` need a parallel extension to return min/max of the PK column when one exists.

Goals
- Cache schema becomes 10 columns: add `src_pk_min DECIMAL(36,0)` and `src_pk_max DECIMAL(36,0)`.
- New per-dialect builder `pk_between(col, lo, hi)` that emits `"col" BETWEEN lo AND hi` (or backtick-quoted for MySQL/MariaDB; bracket-quoted for SQL Server/Azure SQL).
- `build_where_for_split` chooses BETWEEN when the cache has non-NULL `src_pk_min` + `src_pk_max`; falls back to existing MOD when min/max are NULL (preserves behavior for sources that cannot supply them).
- Bucket boundary math: `width = ceil((max - min + 1) / N)`. For `k` in `0..N-1`, `lo_k = min + k*width`, `hi_k = min((k+1)*width - 1 + min, max)`. Last bucket extends to `max` inclusive.
- Edge cases (1-row table where min=max, very wide range with N > range, NULL PK rows) explicitly tested per the new scenarios.

Non-Goals
- Not changing UNIQUE_NUM detection — item 3 (`unique-num-split-strategy`) handles that.
- Not adding PARTITION v2 — item 4.
- Not modifying the date-bucket / hash-num / rowid builders.
- Not introducing skew correction. Uniform-width buckets only. Future work can add sampling-based bucket boundaries.

### Decision

#### Cache schema extension

`transform_for_metadata` outer SQL grows from 8-col to 10-col:

```sql
import into (
  src_schema varchar(2000), src_table varchar(2000),
  src_rows decimal(36,0),
  src_pk_col varchar(2000), src_pk_type varchar(200),
  src_pk_min decimal(36,0), src_pk_max decimal(36,0),     -- NEW
  src_date_col varchar(2000), src_num_col varchar(2000),
  src_partitioned boolean
) from jdbc at <conn> statement '<source-specific SQL>'
```

Each per-source SQL in `SOURCE_METADATA_BY_SOURCE` returns the 10 columns. Sources that already discover a numeric PK column (Postgres, MySQL, SQL Server, etc.) extend their template with two correlated subqueries on the discovered column. Sources where the PK discovery returns NULL emit `NULL, NULL` for the min/max pair.

Per-source SQL is generated at metadata-fetch time. The dispatcher MUST emit one min/max pair per row, lazily — if the per-source SQL cannot cheaply compute min/max (BigQuery cost-per-query, Snowflake credit consumption), it MAY return NULL and `build_where_for_split` MUST fall back to MOD.

#### `pk_between` dialect builders

Add per-dialect:

```lua
DIALECT_BY_SOURCE.POSTGRES.pk_between = function(col, lo, hi)
    return '"' .. col .. '" BETWEEN ' .. lo .. ' AND ' .. hi
end
DIALECT_BY_SOURCE.MYSQL.pk_between = function(col, lo, hi)
    return '`' .. col .. '` BETWEEN ' .. lo .. ' AND ' .. hi
end
DIALECT_BY_SOURCE.SQLSERVER.pk_between = function(col, lo, hi)
    return '[' .. col .. '] BETWEEN ' .. lo .. ' AND ' .. hi
end
-- ...etc for every dialect
```

`pk_between` is added to: POSTGRES, MYSQL (and MARIADB alias), SQLSERVER (and AZURE_SQL alias), SNOWFLAKE, REDSHIFT, VERTICA, ORACLE, DB2, HANA, NETEZZA, TERADATA, DATABRICKS, BIGQUERY.

#### Splitter dispatch

`build_where_for_split` (migrate_to_exasol.sql:1006):

```lua
if decision.strategy == 'PK_RANGE' or decision.strategy == 'UNIQUE_NUM' then
    if decision.lo ~= nil and decision.hi ~= nil and dialect and dialect.pk_between then
        local width = math.ceil((decision.hi - decision.lo + 1) / n)
        local lo_k  = decision.lo + k * width
        local hi_k  = (k == n - 1) and decision.hi or (decision.lo + (k + 1) * width - 1)
        if lo_k > decision.hi then return nil end  -- empty bucket; caller skips
        return dialect.pk_between(decision.key, lo_k, hi_k)
    end
    -- Fallback when min/max unavailable
    if dialect and dialect.pk_where then
        return dialect.pk_where(decision.key, n, k)
    end
    return 'MOD("' .. decision.key .. '", ' .. n .. ') = ' .. k
end
```

`pick_split_strategy` is extended to attach `lo`/`hi` to the decision object when the cache supplies them.

Edge cases
- `src_pk_min == src_pk_max`: single bucket k=0 spans `BETWEEN min AND max`; remaining k=1..N-1 buckets return `nil`. Splitter SHALL collapse such an IMPORT to single-statement with `PARALLEL_EFFECTIVE=1` and emit an `INFO` row noting the degenerate range.
- `width = 1` (range smaller than N): same — buckets beyond `(max - min)` return `nil`. PARALLEL_EFFECTIVE = actual non-nil count.
- `src_pk_min` and/or `src_pk_max` is NULL: fall back to MOD (current behavior preserved).
- NULL rows in the PK column: BETWEEN excludes NULL by SQL semantics. Bucket 0 SHALL append `OR "pk" IS NULL` so NULL rows still ship.

#### Test surface

Lua test changes
- Existing tests asserting `MOD("ORDER_ID", 4) = 0` rewritten to assert `"ORDER_ID" BETWEEN <lo> AND <hi>` for PK_RANGE.
- New scenarios per the spec deltas below: width math, last-bucket inclusivity, degenerate ranges, NULL handling, MOD-fallback when min/max NULL.

Live-smoke
- Postgres ORDERS table loaded with 4M rows, ID 1..4_000_000. Smoke verifies 4 BETWEEN clauses ship complete row count.
- MySQL identical smoke with backtick quoting.

## Tasks

1. Author spec deltas
   - `migrate-to-exasol/source-metadata-roundtrip/spec.md` (add 2 cache cols + per-source NULL fallback contract)
   - `migrate-to-exasol/parallel-split-dispatcher/spec.md` (BETWEEN bucket math + edge cases + MOD fallback)
2. TDD red: rewrite + add Lua tests (~10 new cases).
3. Extend `transform_for_metadata` outer SQL to 10 cols. Update each `SOURCE_METADATA_BY_SOURCE` entry.
4. Add `pk_between` per-dialect builder.
5. Rewrite `build_where_for_split` PK_RANGE branch.
6. Extend `pick_split_strategy` to attach `lo`/`hi`.
7. Run Lua tests to green.
8. Run py-runtime smoke.
9. Live smoke against Postgres + MySQL.
10. `speq plan validate` PASS.
11. Commit, push, `speq record`.
