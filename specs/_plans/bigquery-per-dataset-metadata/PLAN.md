# Plan: BigQuery per-dataset metadata round-trip

## Status

Drafted 2026-05-18. **Not started.** Item 5 of the Speq 2 follow-up backlog. Smallest scope of the four. Driver-level workaround for a BigQuery JDBC limitation. Independent of items 2 / 3 / 4 (it sits one layer below `transform_for_metadata` and is invisible to the splitter).

## Summary

The shared metadata round-trip issues exactly one `IMPORT FROM JDBC at <CONN> statement '...'` per migration. For most sources this works because `INFORMATION_SCHEMA` (or its equivalent) is global per connection. **BigQuery `INFORMATION_SCHEMA.TABLES` is per-dataset** — a query against `INFORMATION_SCHEMA.TABLES` returns only tables in the dataset the query is qualified for. The shared template therefore returns zero rows for every table outside the default dataset, and `src_pk_col` / `src_rows` / all the rest come back NULL. This plan refactors `transform_for_metadata` so that for `SOURCE_TYPE = BIGQUERY` the round-trip is fanned out to one round-trip per distinct source dataset present in the adapter's emitted IMPORTs, with the per-dataset `<dataset>.INFORMATION_SCHEMA` qualifier baked into each statement.

## Design

### Context

- `INFORMATION_SCHEMA` in BQ is dataset-scoped. `SELECT * FROM \`project.dataset.INFORMATION_SCHEMA.TABLES\`` lists tables IN dataset only. There is no cross-dataset projection without UNION ALL across all relevant datasets.
- Today's metadata SQL for BIGQUERY would either fail at compile-time (unknown `INFORMATION_SCHEMA` reference) or return empty (depending on driver behavior). Either way the cache is unpopulated and the gate + splitter silently no-op on BigQuery.
- The fix is dispatcher-side, not adapter-side, and stays inside the master-script architecture principle.
- Other sources retain exactly one round-trip — fan-out is BigQuery-specific.

Goals
- `transform_for_metadata` detects `source_type == 'BIGQUERY'`, partitions the adapter's IMPORT list by source dataset, and issues one `IMPORT FROM JDBC` per dataset against the same connection.
- Per-dataset SQL template is a NEW entry shape in `SOURCE_METADATA_BY_SOURCE.BIGQUERY` — instead of being a single SQL string, it is a function `(dataset, schema_table_pairs) -> sql_string` that generates a dataset-qualified statement.
- All per-dataset results are unioned into the same cache table the rest of the pipeline reads.
- A migration that targets a single dataset issues exactly ONE round-trip (no regression). A migration that targets K datasets issues K round-trips. Per-row metadata semantics unchanged downstream.

Non-Goals
- Not extending this fan-out behavior to other sources. Postgres/Oracle/etc. remain one round-trip.
- Not parallelizing the K round-trips. Sequential is fine — BQ INFORMATION_SCHEMA queries are sub-second each and K is usually 1-3.
- Not addressing BQ partitioned-table metadata (handled in item 4 PARTITION v2 via the same per-dataset round-trip).
- Not addressing BQ driver `setAutoCommit` issues — that is an Exasol IMPORT compatibility bug, not a metadata round-trip bug.

### Decision

#### Dispatch shape change

`SOURCE_METADATA_BY_SOURCE.BIGQUERY` becomes:

```lua
SOURCE_METADATA_BY_SOURCE.BIGQUERY = {
    kind = 'per_dataset',
    build_sql = function(dataset, table_filters)
        -- table_filters = list of {schema, table} pairs in this dataset
        -- returns a fully-qualified BQ SQL string against `<project>.<dataset>.INFORMATION_SCHEMA`
        ...
    end,
}
```

All other sources retain the current shape (`kind = 'shared'`, sql is a single string).

#### `transform_for_metadata` change

```lua
local dispatch = SOURCE_METADATA_BY_SOURCE[source_type]
if dispatch and dispatch.kind == 'per_dataset' then
    local by_dataset = group_imports_by_dataset(imports)
    local merged = { rows = {} }
    for dataset, pairs in pairs(by_dataset) do
        local sql = dispatch.build_sql(dataset, pairs)
        local result = run_jdbc_query(connection_name, sql)
        merge_into(merged.rows, parse(result))
    end
    return merged
end

-- existing path for shared dispatch:
local sql = dispatch.sql or dispatch  -- legacy string entry
...
```

`group_imports_by_dataset` reads the source-side `(schema, table)` pair from each adapter IMPORT exactly as it does today, then keys the dataset by `schema` (BigQuery's schema part IS the dataset).

## Tasks

1. Author one spec delta on `migrate-to-exasol/source-metadata-roundtrip/spec.md` (`per_dataset` dispatch kind + fan-out contract).
2. TDD red: ~4 new Lua scenarios (single-dataset BQ = 1 round-trip, three-dataset BQ = 3 round-trips, BQ round-trips merge into one cache, non-BQ source retains 1 round-trip).
3. Add `kind = 'per_dataset'` discriminator support to `SOURCE_METADATA_BY_SOURCE` lookup.
4. Add `BIGQUERY.build_sql(dataset, pairs)` returning a SQL string using `\`project.dataset.INFORMATION_SCHEMA.TABLES\`` + `COLUMNS` + `KEY_COLUMN_USAGE` joins. (BigQuery has no native `pg_constraint`-like PK view; `INFORMATION_SCHEMA.TABLE_CONSTRAINTS` + `KEY_COLUMN_USAGE` cover it.)
5. Refactor `transform_for_metadata` to branch on `dispatch.kind`.
6. `group_imports_by_dataset` helper.
7. Run Lua tests.
8. py-runtime smoke (BQ branch can be mocked — no live BQ required for unit coverage).
9. Live smoke is BLOCKED by the same Exasol/BQ-JDBC `setAutoCommit` driver issue documented in the existing PR-#42 verification report. Mark live-smoke as deferred and document.
10. `speq plan validate` PASS.
11. Commit, push, `speq record`.
