# Datatype Matrix

Local tracker for adapter datatype smoke coverage. Vertica is the first live source.

## Vertica

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| timestamp | FIXED / PASS | before fix: generated `CREATED_AT varchar(14)` and failed with `ETL-3003` truncation; after fix: generated `CREATED_AT TIMESTAMP` and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| core | PASS | live run generated `ID DECIMAL(11,0), NAME VARCHAR(50)` and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| boolean | PASS | live run generated `BOOLEAN` columns and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| binary | FIXED / PASS | before fix: `binary(4)`/`varbinary(16)` were unknown and raw JDBC binary failed with `ETL-5402`; after fix: generated hex text via `TO_HEX`, `char(8)`/`varchar(32)`, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| null | FIXED / PASS | before fix: `numeric(12,2)` emitted `UNKNOWN_DATATYPE` varchar; after fix: generated `decimal(12,2)` and loaded 2 all-null rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| mixed_case_identifier | FIXED / PASS | after quote fix: generated source import with `"OrderID"`, `"CustomerName"`, `"CreatedAt"`, and `"MixedCaseOrders"`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |
| reserved_ish_identifier | FIXED / PASS | before fix: reserved source identifiers loaded 0 rows; after quote fix: generated `"select"`, `"from"`, `"group"`, and `"order"` source quoting; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `5433` SG rule revoked |

## Postgres

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | PASS | live run generated integer, smallint, bigint, decimal, double, bool, char, varchar, text, date, timestamp, bytea-as-varchar, and nullable varchar; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| boolean | PASS | live run generated `bool` columns for true/false/null flags and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| binary | PASS | live run generated `bytea` columns as `varchar(2000000)`, imported `::text`, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| null | PASS | live run generated nullable text/decimal/date/timestamp columns and loaded 2 all-null rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| mixed_case_identifier | FIXED / PASS | unit regression first failed because generated imports used raw Postgres identifiers; fix generated `"OrderID"`, `"CustomerName"`, `"CreatedAt"`, and `"MixedCaseOrders"` source quoting; live run loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| reserved_ish_identifier | FIXED / PASS | live run generated quoted source identifiers for `"order"`, `"select"`, `"from"`, and `"group"`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |

## MySQL

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | PASS | live run generated DECIMAL mappings for integer family, decimal, double, text, date, timestamp, time-as-varchar, varbinary-as-varchar, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| boolean | PASS | live run generated `BIT(1)` as `DECIMAL(1,0)`, cast bit values to decimal, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| binary | PASS | live run generated `binary(4)` as `char(4)`, `varbinary(16)` as `varchar(16)`, cast source bytes to char, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| null | PASS | live run generated nullable text/decimal/date/timestamp columns and loaded 2 all-null rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| mixed_case_identifier | PASS | live run generated backticked source columns and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| reserved_ish_identifier | PASS | live run generated backticked source columns for `select`, `from`, and `group`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |

## MariaDB

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | PASS | live run generated DECIMAL mappings for integer family, decimal, double, text, date, timestamp, time-as-varchar, varbinary-as-varchar, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| boolean | PASS | live run generated `BIT(1)` as `DECIMAL(1,0)`, cast bit values to decimal, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| binary | PASS | live run generated `binary(4)` as `char(4)`, `varbinary(16)` as `varchar(16)`, cast source bytes to char, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| null | PASS | live run generated nullable text/decimal/date/timestamp columns and loaded 2 all-null rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| mixed_case_identifier | PASS | live run generated backticked source columns and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| reserved_ish_identifier | PASS | live run generated backticked source columns for `select`, `from`, and `group`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |

## SQL Server

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | PASS | live run generated decimal mappings for integer family, decimal, double, bit-as-decimal, char, varchar, varchar(max), date, datetime2, and loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `1433` SG rule revoked |
| mixed_case_identifier | PASS | live run generated bracket-quoted source identifiers `[ORDERID]`, `[CUSTOMERNAME]`, `[CREATEDAT]`, and `[MixedCaseOrders]`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `1433` SG rule revoked |
| reserved_ish_identifier | PASS | live run generated bracket-quoted source identifiers `[SELECT]`, `[FROM]`, `[GROUP]`, and `[order]`; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped, temp `1433` SG rule revoked |

## DB2

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | PASS / DEFERRED RERUN | earlier live run generated decimal mappings for integer family, double/real, char, varchar, clob-as-varchar, date, timestamp, and loaded 2 rows; latest post-identifier-fix reruns were blocked before SQL generation by local Docker DB2 TCP listener errors (`Connection refused` / `Insufficient data`), so stable-endpoint rerun is deferred | source container removed, Exasol schema dropped, Exasol connection dropped |
| mixed_case_identifier | FIXED / PASS | after DB2 filter/source-quote fix: generated `"ORDERID"`, `"CUSTOMERNAME"`, `"CREATEDAT"`, and `"MixedCaseOrders"` source quoting; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |
| reserved_ish_identifier | FIXED / PASS | after DB2 filter/source-quote fix: generated `"SELECT"`, `"FROM"`, `"GROUP"`, and `"ORDER"` source quoting; loaded 2 rows | source container removed, Exasol schema dropped, Exasol connection dropped |

## Oracle

| Case | Status | Evidence | Cleanup |
|------|--------|----------|---------|
| core | BLOCKED | Oracle 23c source booted on Frankfurt EC2 after freeing Docker disk and adding temp swap. First wrapper run previewed successfully, but `DEBUG=FALSE` failed inside existing `ORACLE_TO_EXASOL` with Exasol internal server error at line 815. Rerun failed during preview with `Internal error - At least one tool did not finish correctly` around line 258. | source container removed, temp `1521` SG rule revoked, temp swap removed, Oracle image removed |
| minimal | BLOCKED | Added diagnostic table with only `NUMBER(10,0)` and `VARCHAR2(50)`. Wrapper preview still stalled/crashed local ExaNano connection server; this points to the existing Oracle adapter/JDBC path or Nano runtime stability, not the datatype payload. | source container removed, temp `1521` SG rule revoked; manual cleanup dropped leftover `ORACLE_DATATYPE_SMOKE` connection and restarted `db-migration-nano` |

## Self-tests

| Check | Result |
|-------|--------|
| canonical-cases | PASS |
| result-shape | PASS |
| failure-preserves-error | PASS |
| cleanup-record | PASS |
| script-extraction | PASS |

## Live commands

```bash
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case timestamp
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case boolean
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case binary
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case null
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source vertica --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case boolean
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case binary
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case null
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source postgres --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case boolean
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case binary
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case null
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mysql --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case boolean
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case binary
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case null
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source mariadb --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source sqlserver --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source sqlserver --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source sqlserver --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source db2 --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source db2 --case mixed_case_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source db2 --case reserved_ish_identifier
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source oracle --case core
python3 specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py --source oracle --case minimal
```

Observed:

- `timestamp`: exit 0 before fix as expected failure; exit 0 after fix with `CREATED_AT TIMESTAMP`, execute 7 rows, loaded 2 rows.
- Vertica `core`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- Vertica `boolean`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- Vertica `binary`: exit 0 after binary mapping fix; preview 6 rows, execute 7 rows, loaded 2 rows.
- Vertica `null`: exit 0 after numeric pattern fix; preview 6 rows, execute 7 rows, loaded 2 rows.
- Vertica `mixed_case_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- Vertica `reserved_ish_identifier`: exit 0 after source-identifier quote fix; preview 6 rows, execute 7 rows, loaded 2 rows.
- Postgres `core`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- Postgres `boolean`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- Postgres `binary`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- Postgres `null`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- Postgres `mixed_case_identifier`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- Postgres `reserved_ish_identifier`: exit 0; preview 3 rows, execute 4 rows, loaded 2 rows.
- MySQL `core`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MySQL `boolean`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MySQL `binary`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MySQL `null`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MySQL `mixed_case_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MySQL `reserved_ish_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `core`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `boolean`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `binary`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `null`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `mixed_case_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- MariaDB `reserved_ish_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- SQL Server `core`: exit 0; preview 7 rows, execute 8 rows, loaded 2 rows.
- SQL Server `mixed_case_identifier`: exit 0; preview 7 rows, execute 8 rows, loaded 2 rows.
- SQL Server `reserved_ish_identifier`: exit 0; preview 7 rows, execute 8 rows, loaded 2 rows.
- DB2 `core`: exit 0 earlier; stable-endpoint rerun deferred because local Docker DB2 listener is slow/flaky and DB2 is lower priority.
- DB2 `mixed_case_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- DB2 `reserved_ish_identifier`: exit 0; preview 6 rows, execute 7 rows, loaded 2 rows.
- Oracle `core`: blocked; Oracle source booted, then existing Oracle adapter path hit Exasol internal server errors during wrapper preview/execute.
- Oracle `minimal`: blocked; minimal NUMBER/VARCHAR2 source table still stalled/crashed local ExaNano connection server.
