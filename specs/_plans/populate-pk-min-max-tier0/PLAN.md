# Plan: populate src_pk_min / src_pk_max for Tier-0 sources

## Status

Drafted 2026-05-18. **Not started.** Follow-up to `pk-range-between-pushdown` (item 2 of Speq 2 backlog). Surfaced during live-smoke verification 2026-05-18: although item 2 extended the cache schema and added per-dialect `pk_between` builders, **the per-source metadata SQL templates hard-code NULL** for the new `src_pk_min` / `src_pk_max` columns. As a result every BETWEEN-eligible IMPORT falls back to MOD bucket math, so the recorded BETWEEN scenarios never fire against any live source.

The recorded spec on `source-metadata-roundtrip` permits NULL (`Sources that decline to compute min/max populate them with NULL without failing`), so the gap is technically compliant. But the operational intent of item 2 — B-tree range scans on OLTP sources — is unrealized until at least the Tier-0 sources (POSTGRES, MYSQL, SQLSERVER) populate min/max. This plan tightens the spec for Tier-0 from "MAY return NULL" to "MUST populate when `src_pk_col` is non-NULL" and ships the per-source SQL changes.

## Design

### Context

- Live smoke 2026-05-18 against the local Postgres container `postgresdb` showed `MIGRATE_TO_EXASOL(..., PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO)` emitting `WHERE MOD("id", 4) = K` clauses for the BIG_T fixture rather than the BETWEEN clauses item 2's spec mandates. Strategy + key + effective bucket count are all correct — only the WHERE shape differs.
- Cause: `SOURCE_METADATA_BY_SOURCE.POSTGRES.template` returns `NULL, NULL` at the `src_pk_min`, `src_pk_max` positions. MYSQL and SQLSERVER do the same.
- Item 2's record permits this: every source's per-row min/max is allowed to be NULL with a stated reason (cost, complexity, no PK). But Tier-0 sources have a discovered numeric PK in the SAME template; computing `MIN(<pk>)` and `MAX(<pk>)` is one extra correlated subquery per source.

Goals
- POSTGRES, MYSQL (incl. MARIADB alias), SQLSERVER (incl. AZURE_SQL alias) per-source SQL templates emit `(SELECT MIN("<pk>") FROM "<schema>"."<table>")` and `(SELECT MAX("<pk>") FROM "<schema>"."<table>")` correlated subqueries when `src_pk_col` is non-NULL.
- Subqueries are scoped per row (one per cache row) so that a permission failure on one source table populates that row's min/max with NULL without failing the rest of the round-trip.
- Spec is tightened: a new scenario `"Tier-0 sources populate src_pk_min / src_pk_max when src_pk_col is non-NULL"` is added so future regressions surface in CI.
- Live smoke re-runs against the same fixtures (with seeded distinct PK values) and verifies BETWEEN clauses in the emitted SQL.

Non-Goals
- Not extending min/max to ORACLE, DB2, SNOWFLAKE, REDSHIFT, VERTICA, HANA, NETEZZA, TERADATA, DATABRICKS, BIGQUERY. They remain allowed to return NULL (MOD fallback intact).
- Not changing `src_unique_num_min` / `src_unique_num_max` behavior (item 3 — same NULL contract preserved).
- Not changing `src_pk_col` discovery logic. Only the min/max subqueries change.
- Not touching the bucket math, builder, or splitter. Item 2's `pk_between` builder is unchanged.

### Decision

#### Per-source SQL changes

POSTGRES — the existing template already has the PK discovery subquery. Wrap it as a CTE OR reuse it inline:
```sql
SELECT n.nspname, c.relname, c.reltuples,
  (<existing src_pk_col subquery>) AS src_pk_col,
  (<existing src_pk_type subquery>) AS src_pk_type,
  (SELECT MIN(<pk col reference>) FROM <schema>.<table>) AS src_pk_min,    -- NEW
  (SELECT MAX(<pk col reference>) FROM <schema>.<table>) AS src_pk_max,    -- NEW
  ...
FROM pg_class c JOIN pg_namespace n ON ...
```

Because PG correlated subqueries can't directly reference `n.nspname`/`c.relname` as identifiers inside a derived `FROM` clause, the min/max needs dynamic SQL OR a side-channel. Pragmatic implementations:
- **Inline format()**: Build the min/max sub-SQL at SOURCE_METADATA dispatch time per-table, not via correlated subquery. Already how the dispatcher generates per-table predicates — extend to also emit min/max sub-SELECTs.
- **PL/pgSQL function**: Define a small immutable function in the source DB that takes a schema/table/col name and returns `MIN`/`MAX`. Rejected — adds a side-effect on the source DB.
- Recommended: emit min/max as a separate UNION ALL'd query per (schema, table, pk_col), batched together with the main template. Slightly more complex SQL but stays in the master script.

MYSQL — `information_schema` doesn't allow correlated subqueries against the actual tables. Same pattern: emit a UNION ALL of `(SELECT '<schema>' AS s, '<table>' AS t, MIN(\`pk\`) AS pk_min, MAX(\`pk\`) AS pk_max FROM \`<schema>\`.\`<table>\`)` queries per (schema, table) pair that has a numeric PK, then join into the main template via LEFT JOIN on (s, t).

SQLSERVER — similar pattern.

This means the dispatcher's `transform_for_metadata` per-source SQL builder needs a second pass:
1. Run the main per-table catalog template (returns the discovered PK col per table).
2. Build a follow-up SQL that does `SELECT '<schema>' AS s, '<table>' AS t, MIN(<pk>) AS lo, MAX(<pk>) AS hi FROM <schema>.<table>` UNION ALL'd across all (schema, table, pk_col) tuples where the first pass found a numeric PK.
3. Issue the follow-up as a second `IMPORT FROM JDBC` and join into the cache rows by (schema, table).

#### Round-trip count

This is one MORE round-trip per source per migration (so two total for Tier-0 sources: catalog + min/max). The recorded `source-metadata-roundtrip` spec says "one round-trip per migration". This delta amends Tier-0 sources only: catalog + min/max = two queries total. Spec scenario clarifies that a second JDBC query specifically for min/max is permitted for Tier-0 sources.

If the operator disables both gate AND splitter (`PARALLEL_ROW_THRESHOLD=0` AND `PARALLEL_STATEMENTS=1` AND `PARALLEL_SPLIT=OFF`), the second round-trip MUST be skipped (the cache is unused anyway — same as the existing skip rule for the first round-trip).

#### Soft-fail contract

If any (schema, table) in the min/max round-trip fails (permission denied), that row's `src_pk_min` / `src_pk_max` is populated with NULL via LEFT JOIN miss — no exception bubbles. An `INFO` audit row names the failed table.

## Tasks

1. Author one spec delta on `migrate-to-exasol/source-metadata-roundtrip/spec.md` (Tier-0 MUST populate; two-query round-trip permitted; soft-fail contract).
2. TDD red: 4-6 new Lua scenarios (PG fixture with id=1..10000 → min=1, max=10000; PG fixture with permission-denied on min/max query → NULL row, INFO; MYSQL backtick; SQLSERVER bracket; combined gate+splitter disable skips second round-trip).
3. Implement two-query metadata fetch in `transform_for_metadata` for `kind = 'shared'` Tier-0 entries. Add a flag on the dispatch entry indicating "needs min/max round-trip" (`needs_min_max_pass = true`).
4. POSTGRES: build min/max SQL per-table at dispatch time.
5. MYSQL/MARIADB: same.
6. SQLSERVER/AZURE_SQL: same.
7. Run Lua tests to green.
8. Re-run `_reference/smoke_parallel_split_postgres.py` after updating fixture to seed distinct PK values (BIG_T inserts id=1 + id=20000000 instead of single row); assert WHERE clauses now contain BETWEEN.
9. `speq plan validate populate-pk-min-max-tier0` PASS.
10. Commit, push, `speq record`.
