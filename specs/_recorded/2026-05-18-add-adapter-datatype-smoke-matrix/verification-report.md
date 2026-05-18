# Verification Report: add-adapter-datatype-smoke-matrix

## Verdict

PARTIAL PASS. The datatype smoke harness covers Vertica, Postgres, MySQL, MariaDB, SQL Server, and DB2 core cases plus focused boolean/binary/null/identifier edges. Evidence-driven fixes were made for Vertica `TIMESTAMP`, DB2 padded catalog filters, Postgres source identifier quoting, Vertica source identifier quoting, Vertica binary mapping, Vertica parameterized numeric mapping, and DB2 mixed/reserved source identifiers. SQL Server and DB2 identifier edges now live-load successfully. DB2 core passed earlier, but latest post-identifier-fix reruns were blocked by the local Docker DB2 TCP listener before SQL generation. Oracle 23c source booted on the Frankfurt EC2, but the existing Oracle adapter/JDBC path destabilized the local ExaNano connection server even for a minimal NUMBER/VARCHAR2 table; Oracle is deferred until tested on a stronger/stable Exasol runtime.

## Evidence

| Check | Result |
|-------|--------|
| `python3 -m py_compile specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py` | PASS |
| `python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --self-test all` | PASS |
| Live Vertica timestamp case before fix | PASS as expected failure: generated `CREATED_AT varchar(14)`, execute reported `ETL-3003` string truncation, loaded 0 rows |
| Live Vertica timestamp case after fix | PASS: generated `CREATED_AT TIMESTAMP`, execute 7 rows, loaded 2 rows |
| Live Vertica core case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Vertica source identifier regression test | PASS after fix: `lua test/test_vertica_to_exasol.lua`; red before fix because imports used raw source identifiers |
| Live Vertica boolean case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Vertica binary case | PASS after fix: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Vertica null case | PASS after numeric mapping fix: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Vertica mixed-case identifier case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Vertica reserved-ish identifier case | PASS after fix: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Postgres core case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Postgres source identifier regression test | PASS after fix: `lua test/test_postgres_to_exasol.lua`; red before fix because imports used raw source identifiers |
| Live Postgres boolean case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Live Postgres binary case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Live Postgres null case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Live Postgres mixed-case identifier case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Live Postgres reserved-ish identifier case | PASS: preview 3 rows, execute 4 rows, loaded 2 rows |
| Live MySQL core case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live MySQL boolean/binary/null cases | PASS: each previewed 6 rows, executed 7 rows, loaded 2 rows |
| Live MySQL mixed-case identifier case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live MySQL reserved-ish identifier case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live MariaDB core case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live MariaDB boolean/binary/null cases | PASS: each previewed 6 rows, executed 7 rows, loaded 2 rows |
| Live MariaDB mixed-case identifier case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live MariaDB reserved-ish identifier case | PASS: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live SQL Server core case | PASS: preview 7 rows, execute 8 rows, loaded 2 rows |
| Live SQL Server mixed-case identifier case | PASS: preview 7 rows, execute 8 rows, loaded 2 rows |
| Live SQL Server reserved-ish identifier case | PASS: preview 7 rows, execute 8 rows, loaded 2 rows |
| Live DB2 core case | PASS earlier; stable-endpoint rerun deferred due local Docker DB2 TCP listener flake |
| Live DB2 mixed-case identifier case | PASS after filter/source-quote fix: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live DB2 reserved-ish identifier case | PASS after filter/source-quote fix: preview 6 rows, execute 7 rows, loaded 2 rows |
| Live Oracle core case | BLOCKED: Oracle 23c source booted, first wrapper preview succeeded but execute failed inside `ORACLE_TO_EXASOL` at line 815 with Exasol internal server error; rerun failed during preview around line 258 with `At least one tool did not finish correctly` |
| Live Oracle minimal case | BLOCKED: NUMBER/VARCHAR2-only table still stalled/crashed local ExaNano connection server, so issue is adapter/JDBC runtime path rather than full datatype payload |
| Vertica cleanup | PASS: source container removed and temp `5433` security group rule revoked |
| Postgres cleanup | PASS: source container removed |
| MySQL/MariaDB cleanup | PASS: source containers removed |
| SQL Server cleanup | PASS: EC2 source container removed and temp `1433` security group rule revoked |
| DB2 cleanup | PASS: source container removed |
| Oracle cleanup | PASS after manual cleanup: EC2 source container removed, temp `1521` security group rule revoked, temp swap removed, Oracle image removed, leftover Exasol connection dropped, local `db-migration-nano` restarted healthy |

## Scenario Coverage

| Scenario | Evidence |
|----------|----------|
| Define Canonical Datatype Cases | `--self-test canonical-cases` included numeric, text, date/time, boolean, binary, null, mixed-case identifier, and reserved-ish identifier groups |
| Record Preview And Execute Evidence | Live runs record preview rows, execute rows, generated DDL, and loaded row count |
| Preserve Mapping Or Import Failures | Pre-fix live Vertica timestamp run preserved source case, generated `varchar(14)` DDL, and `ETL-3003` truncation error; pre-fix DB2 run preserved generated comments-only SQL from zero catalog rows |
| Clean Up Live Smoke Resources | Live runs remove source containers and revoke temporary security group rules where used |
| Gate Adapter Fixes On Failing Evidence | Vertica timestamp failure, DB2 zero-table catalog evidence, Postgres source-identifier regression failure, Vertica reserved-identifier live failure, Vertica binary live failure, and Vertica numeric unknown-type live evidence were documented before changing adapter SQL |
| Postgres Core Datatype Smoke | Live Postgres core run covered integer, smallint, bigint, numeric, double precision, boolean, char, varchar, text, date, timestamp, bytea, and null handling |
| Postgres Edge Datatype Smoke | Live Postgres edge runs covered focused boolean, binary, null-only rows, mixed-case identifiers, and reserved-ish identifiers |
| Vertica Edge Datatype Smoke | Live Vertica edge runs covered focused boolean, binary, null-only rows, mixed-case identifiers, and reserved-ish identifiers |
| MySQL/MariaDB Edge Datatype Smoke | Live MySQL and MariaDB edge runs covered focused boolean, binary, null-only rows, mixed-case identifiers, and reserved-ish identifiers |
| Identifier Edge Smoke | Live Vertica/Postgres/MySQL/MariaDB runs covered mixed-case and reserved-ish source identifiers |
| MySQL/MariaDB Core Datatype Smoke | Live MySQL and MariaDB core runs covered integer family, decimal, double, tinyint, char, varchar, text, date, datetime, time, varbinary, and null handling |
| SQL Server Core Datatype Smoke | Live SQL Server core run covered int, smallint, bigint, decimal, float, bit, char, varchar, varchar(max), date, datetime2, and null handling |
| SQL Server Identifier Edge Smoke | Live SQL Server runs covered mixed-case and reserved-ish source identifiers |
| DB2 Core Datatype Smoke | Earlier live DB2 core run covered integer, smallint, bigint, decimal, double, real, char, varchar, clob, date, and timestamp handling; stable-endpoint rerun is deferred |
| DB2 Identifier Edge Smoke | Live DB2 runs covered mixed-case and reserved-ish source identifiers after filter/source-quote fix |
| Oracle Smoke Triage | Oracle 23c boot and JDBC connection setup reached the wrapper path, but existing `ORACLE_TO_EXASOL` destabilized local ExaNano during preview/execute; deferred pending stronger/stable runtime |
