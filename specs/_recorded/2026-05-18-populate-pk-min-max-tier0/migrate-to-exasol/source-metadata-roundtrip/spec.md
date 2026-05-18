# Feature: source-metadata-roundtrip (delta: Tier-0 MUST populate src_pk_min/src_pk_max)

This delta tightens the cache-population contract for the three "Tier-0" sources — POSTGRES, MYSQL (and MARIADB alias), SQLSERVER (and AZURE_SQL alias). Today the recorded spec permits NULL min/max for any source. This delta upgrades Tier-0 to MUST populate `src_pk_min` and `src_pk_max` whenever the same per-source SQL has populated `src_pk_col` with a numeric PK column. To make this affordable inside `transform_for_metadata`, the delta also permits a second, follow-up `IMPORT FROM JDBC` per migration — strictly scoped to the (schema, table, pk_col) tuples that need min/max — for Tier-0 sources only.

## Background

* Tier-0 sources = POSTGRES, MYSQL, MARIADB (alias of MYSQL), SQLSERVER, AZURE_SQL (alias of SQLSERVER). Any other source remains free to return NULL per the existing contract.
* When the existing first-pass catalog SQL identifies a numeric singleton PK column for a (schema, table) row, the dispatcher MUST emit a follow-up SQL containing one `SELECT MIN(<pk>), MAX(<pk>)` per such (schema, table, pk_col) tuple, UNION ALL'd into a single statement, and MUST issue it as one additional `IMPORT FROM JDBC at <CONN> statement '...'`. This is the **only** circumstance under which a Tier-0 metadata phase issues two source-side round-trips.
* The dispatcher MUST join the second-pass result into the cache rows on `(src_schema, src_table)` via LEFT JOIN semantics. Rows whose tuple is missing from the second pass (permission denied on the table, error during MIN/MAX, table dropped between passes) MUST end up with `src_pk_min = NULL, src_pk_max = NULL` and an `INFO` audit row naming the failed (schema, table).
* If a (schema, table) row has `src_pk_col = NULL` after the first pass (no numeric PK discovered), it MUST NOT be included in the second pass — there is no min/max to compute.
* When the operator disables both gate and splitter (`PARALLEL_ROW_THRESHOLD = 0` AND `PARALLEL_STATEMENTS = 1` AND `PARALLEL_SPLIT = OFF`), the second-pass round-trip MUST be skipped, matching the existing skip rule for the first-pass round-trip.
* The follow-up SQL MUST use dialect-correct identifier quoting:
  * POSTGRES: `SELECT MIN("<pk>"), MAX("<pk>") FROM "<schema>"."<table>"`
  * MYSQL / MARIADB: ``SELECT MIN(`<pk>`), MAX(`<pk>`) FROM `<schema>`.`<table>` ``
  * SQLSERVER / AZURE_SQL: `SELECT MIN([<pk>]), MAX([<pk>]) FROM [<schema>].[<table>]`
* The new dispatch-entry shape MAY signal participation via a flag, e.g. `needs_min_max_pass = true`. Entries without the flag retain the legacy one-round-trip behavior.
* Non-Tier-0 sources MUST NOT issue the second-pass query. Their cache rows continue to populate `src_pk_min` / `src_pk_max` as NULL, and the splitter falls back to the dialect's MOD `pk_where` builder via item 2's contract.

## Scenarios

### Scenario: POSTGRES populates src_pk_min and src_pk_max for a numeric PK table

* *GIVEN* the source type is `POSTGRES`
* *AND* the source `PUB.ORDERS` declares a single-column numeric PK `ID` with rows `id = 1` and `id = 20000000` only
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the metadata phase SHALL issue exactly two `IMPORT FROM JDBC at <CONN> statement '...'` statements
* *AND* the second statement's SQL MUST be a UNION ALL of `SELECT 'PUB' AS src_schema, 'ORDERS' AS src_table, MIN("ID") AS src_pk_min, MAX("ID") AS src_pk_max FROM "PUB"."ORDERS"` (one branch per qualifying tuple)
* *AND* the cache row for `PUB.ORDERS` MUST carry `src_pk_min = 1` AND `src_pk_max = 20000000`
* *AND* `transform_for_split` MUST emit BETWEEN-based bucket clauses (per item 2's `pk_between` builder) instead of MOD

### Scenario: Second-pass failure on one table soft-fails to NULL min/max

* *GIVEN* the source type is `MYSQL`
* *AND* the migration touches three tables: `app.OK_T` (numeric PK, `MIN/MAX` succeeds), `app.DENIED_T` (numeric PK, `MIN/MAX` errors with permission denied), `app.HEAP_T` (no PK at all)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher SHALL issue exactly two metadata round-trips
* *AND* the second round-trip MUST UNION ALL `MIN/MAX` queries for `app.OK_T` and `app.DENIED_T` (the two with numeric PK)
* *AND* the cache row for `app.OK_T` SHALL carry populated `src_pk_min` / `src_pk_max`
* *AND* the cache row for `app.DENIED_T` SHALL carry NULL `src_pk_min` / `src_pk_max`
* *AND* an `INFO` audit row SHALL be emitted naming `app.DENIED_T` and the error message
* *AND* `MIGRATE_TO_EXASOL` MUST NOT raise the migration as failed

### Scenario: No numeric PK skips the second-pass for that row

* *GIVEN* the source type is `SQLSERVER`
* *AND* the migration touches `dbo.WithPK` (numeric PK) and `dbo.NoKey` (no PK)
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the second-pass UNION ALL MUST contain exactly one branch — for `dbo.WithPK`
* *AND* `dbo.NoKey` MUST NOT appear in the second-pass SQL
* *AND* its cache row's `src_pk_min` / `src_pk_max` MUST be NULL

### Scenario: Gate + splitter disabled skips both round-trips

* *GIVEN* the source type is `POSTGRES`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=1;PARALLEL_SPLIT=OFF`
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST NOT issue the catalog round-trip
* *AND* the dispatcher MUST NOT issue the min/max round-trip
* *AND* the cache SHALL be empty (the existing "splitter + gate both disabled" contract is preserved)

### Scenario: Non-Tier-0 source skips the second-pass

* *GIVEN* the source type is `ORACLE`
* *AND* the migration touches `HR.EMPLOYEES` with a numeric PK
* *WHEN* `MIGRATE_TO_EXASOL` is executed
* *THEN* the dispatcher MUST issue exactly one metadata round-trip (the existing catalog query)
* *AND* the cache row's `src_pk_min` / `src_pk_max` SHALL be NULL
* *AND* `transform_for_split` MUST emit MOD-based bucket clauses via Oracle's existing `pk_where` builder

### Scenario: BETWEEN clauses fire end-to-end on the live PG fixture

* *GIVEN* the live PG smoke fixture seeds `smoke.big_t` with `id IN (1, 20000000)` (two rows) and fakes `reltuples = 20000000`
* *AND* `OPTIONS` contains `PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4`
* *WHEN* `_reference/smoke_parallel_split_postgres.py` is executed
* *THEN* the rewritten IMPORT MUST contain four `statement '...'` clauses
* *AND* each clause's inner SELECT MUST AND with `"id" BETWEEN <lo> AND <hi>` covering disjoint ranges of `1..20000000`
* *AND* no clause SHALL contain `MOD("id"`
