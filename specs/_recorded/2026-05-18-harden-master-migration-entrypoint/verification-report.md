# Verification Report: harden-master-migration-entrypoint

## Verdict

**PASS** — `MIGRATE_TO_EXASOL` is all green on the testable surface today.
17/17 source dispatches green in runtime mock smoke against local Exasol.
12 of 17 sources have evidence at the live-source level (9 prior + Oracle + Redshift + Azure SQL today).
1 attempted-blocked at driver layer (BigQuery — Simba hangs from Nano, Google JDBC incompatible with Exasol IMPORT).
4 remain pending behind cloud accounts or licensed images.

## Wrapper Regression Pass (2026-05-16, second sweep)

Full `_reference/live_smoke.py all` against fresh-restart Nano (after JDBC driver install)
surfaced 3 regressions vs. prior pass. All 3 fixed and re-verified; 5/5 local smokes
PASS on second run.

| Source | First-pass verdict | Root cause | Fix |
|--------|--------------------|------------|-----|
| postgres | FAIL `attempt to concatenate userdata 'DEST_SCHEMA'` | Wrapper passes literal SQL `NULL` for `TARGET_SCHEMA`; adapter's `if DEST_SCHEMA then` is truthy on Exasol null sentinel (userdata, not Lua nil) | `postgres_to_exasol.sql`: change guard to `DEST_SCHEMA ~= nil and DEST_SCHEMA ~= null`. Tests added: 3 new cases in `test/test_postgres_to_exasol.lua` (nil, null sentinel, literal value). |
| mariadb | FAIL `ERROR 2002 (HY000): Can't connect (115)` | `ready_marker="ready for connections."` matches MariaDB's init-phase startup (socket only, `port: 0`), seed runs before TCP listener is up on real restart | `_reference/live_smoke.py`: tightened to `"mariadb.org binary distribution"` — only logged in the real (non-init) startup. Harness-only, gitignored. |
| oracle | FAIL `ORA-03405: End of query reached` | Oracle 23 sqlplus stricter than 21; multi-statement single-line input (`CREATE...; INSERT...; COMMIT;`) trips the parser at the first `;` | `_reference/live_smoke.py`: split seed SQL across newlines, `EXIT;` on its own line. Harness-only, gitignored. |

Re-run results: oracle/postgres/mariadb all PASS (preview + execute + loaded 2 rows).
mysql/sqlserver remained PASS from first pass. Lua suite updated: 39+9+3+5+5 = 61 cases
across 5 files, 0 failed (postgres jumped 2→5 with the new DEST_SCHEMA coverage).

Notable: postgres/mariadb prior PASS in the ledger below was direct adapter call,
**not** wrapper-driven. Today's pass is the first wrapper-driven live verification for
those two sources. Oracle prior PASS was wrapper-driven but on a different Oracle 23
image hash that did not trip the sqlplus parser.

## Today's Run (2026-05-16) — Local ExaNano Docker

Target: `exanano-sqlcube` container, `localhost:8564` via `exapump` profile
`sqlcube-nano` and `pyexasol` with `cert_reqs=CERT_NONE`.

| Check | Result |
|-------|--------|
| `lua test/test_migrate_to_exasol.lua` | PASS: 39 passed, 0 failed |
| `lua test/test_databricks_to_exasol.lua` | PASS: 9 passed, 0 failed |
| `lua test/test_db2_to_exasol.lua` | PASS: 3 passed, 0 failed |
| `lua test/test_postgres_to_exasol.lua` | PASS: 5 passed, 0 failed (incl. NULL/nil/literal DEST_SCHEMA cases) |
| `lua test/test_vertica_to_exasol.lua` | PASS: 5 passed, 0 failed (incl. `TIMESTAMP` → `TIMESTAMP`) |
| Python AST check (test/*.py) | PASS |
| `git diff --check` | PASS |
| `python3 test/test_migrate_to_exasol_runtime.py` | PASS: 17 preview dispatches, 4 execute representatives, no-op, adapter error, S3 rejection, alias dispatch |
| Live Oracle smoke (new) | PASS: direct JDBC 1 row, wrapper preview 10 rows, execute 11 rows incl. success banner, loaded 2 rows in `EXASOL.SMOKE` |

### Live Source Coverage

| Source | Live smoke | Notes |
|--------|------------|-------|
| Databricks | PASS (prior) | direct JDBC 1, preview 6, execute 7, loaded 25 |
| Exasol → Exasol | PASS (prior) | preview 9, execute 10, loaded 2 |
| Postgres | **PASS (today, wrapper-driven, post-fix)** | First wrapper-driven verification. Adapter patched for NULL `DEST_SCHEMA` (see Wrapper Regression Pass). preview 7, execute 7, loaded 2 into `PUBLIC.SMOKE`. |
| MySQL | PASS (prior + today wrapper-driven) | preview 7, execute 7, loaded 2 |
| Snowflake | PASS (prior) | direct JDBC 1, preview 7, execute 8, loaded 25; needs `JDBC_QUERY_RESULT_FORMAT=JSON` on Java 17 |
| MariaDB | **PASS (today, wrapper-driven, post-fix)** | First wrapper-driven verification. Ready-marker tightened to skip MariaDB init-phase startup (see Wrapper Regression Pass). preview 7, execute 7, loaded 2 into `SMOKEDB.SMOKE`. |
| DB2 | PASS (prior) | direct JDBC 1, preview 6, execute 7, loaded 2 |
| SQL Server | PASS (prior + today local arm64) | EC2 x86 SQL Server 2022 container; **today: local arm64-native via `mcr.microsoft.com/azure-sql-edge` — closes prior Apple Silicon gap, 2 rows loaded into `DBO.SMOKE`** |
| Vertica | PASS (prior) | EC2 x86 Vertica; `TIMESTAMP` adapter mapping since fixed (Lua test confirms `TIMESTAMP` → `TIMESTAMP`) |
| **Oracle** | **PASS (today)** | `gvenzl/oracle-free:23-slim-faststart` (arm64 native). `gvenzl/oracle-xe:21-slim` fails `ORA-00443 PMON did not start` under amd64 emulation on Apple Silicon. |
| **Redshift** | **PASS (today)** | `compare-redshift-exasol` AWS cluster (eu-central-1). Resumed for smoke, paused after. URL needed `?ssl=false` to bypass PKIX validation in Nano JDBC. 2 rows loaded into `PUBLIC.SMOKE`. |
| **BigQuery** | **ATTEMPTED-BLOCKED** | SA key `zaad-gcp-exasol-integration@zaad-demo.iam.gserviceaccount.com` valid (gcloud `SELECT 1` works). Simba driver loaded into `/exa/jdbc/BIGQUERY/` (75 jars), TCP to `bigquery.googleapis.com:443` OK from Nano container, but `IMPORT FROM JDBC AT BQ_MIGRATE STATEMENT 'SELECT 1'` hangs >4 min (no error, no return). Google official JDBC errors `setAutoCommit method` — incompatible with Exasol IMPORT autocommit handling. Wrapper dispatch proven via runtime mock smoke. |
| **Azure SQL** | **PASS (today)** | Azure SQL Basic DB `smokedb` on disposable server `dbm-smoke-974964.database.windows.net` (RG `solution_engineering`, region `westeurope`). Provisioned via `az sql server/db create`, firewall opened to host IP, seeded 2 rows in `dbo.smoke` via `mcr.microsoft.com/mssql-tools`, ran wrapper, dropped server after. Wrapper preview 7 rows, execute 8 rows, loaded 2 rows into `DBO.SMOKE`. |
| Teradata | PENDING | Vantage Express not on Docker Hub freely; needs Teradata Developers account + ~25 GB VirtualBox image |
| Netezza | PENDING | IBM Netezza Performance Server image not freely available |
| HANA | **ATTEMPTED-BLOCKED** | SAP BTP Trial → HANA Cloud free tier (`hana-free` plan, instance `hana-test`, SQL endpoint `<guid>.hna1.prod-us10.hanacloud.ondemand.com:443`) provisioned 2026-05-16. Driver `ngdbc-2.28.7.jar` from Maven Central staged in Nano `/exa/jdbc/HANA/` + `settings.cfg`; Nano restart picked it up. Adapter `sap_hana_to_exasol.sql` + wrapper dispatch (`'HANA'`/`'SAP_HANA'`/`'SAPHANA'`) ready. Smoke script `_reference/live_hana_cloud.py` ready (uses `hdbcli` for seed). **Blocker**: `hana-free` plan locks Allowed Connections to "IP addresses from Cloud Foundry in this BTP region" only; "Allow all"/specific-IP/PrivateLink/Cloud Connector all paid-tier-gated. External smoke from local Nano therefore impossible without (a) paid upgrade or (b) CF-app proxy in same region. Same posture as BigQuery: wrapper HANA dispatch proven via runtime mock smoke; live verification deferred. |
| Vectorwise | **BLOCKED** | `actian/actianx:ii12.1.0` on Docker Hub is a 973 MB bootstrap/installer image, not a runnable DB. `/opt/Actian/IngresII/ingres/bin/ingstart` does not exist; the named volume directories (`/ingres/database`, `/ingres/log`, `/opt/Actian/IngresII/ingres/files`) are empty placeholders. Image expects a separate installer run + commit-as-new-image, plus amd64 emulation overhead on Apple Silicon (no arm64 tag). No free turn-key Actian Vector/X image available. Closing locally infeasible without licensed Actian Vector OnDemand or vendor-supplied pre-baked image. Wrapper dispatch proven via runtime mock smoke (covers VECTORWISE source path). |
| S3 | N/A | wrapper deliberately rejects and points to `DATABASE_MIGRATION.S3_PARALLEL_READ` |

## Scenario Coverage

| Scenario | Evidence |
|----------|----------|
| Preview generated SQL | Lua dispatch tests + runtime mock preview across 17 sources + 10 live preview passes |
| Execute generated SQL | Lua execution tests + runtime execute checks for MYSQL/SNOWFLAKE/DATABRICKS/ORACLE mocks + 10 live execute passes |
| Report no generated executable SQL | Lua no-op test + runtime `EMPTY` mock check |
| Preserve adapter errors | Lua adapter-error test + runtime `ADAPTER_FAIL` mock check |
| Reject S3 in master wrapper | Lua S3 rejection test + runtime S3 rejection check |

## Oracle Smoke Detail

Source container: `gvenzl/oracle-free:23-slim-faststart` on bridge network
`dbm-net`, sharing the network with `exanano-sqlcube` so the Nano JDBC import
can reach Oracle at the container IP.

Seed schema (`EXASOL` user / `FREEPDB1` PDB):

```sql
CREATE TABLE smoke (id NUMBER(10), name VARCHAR2(50), ts TIMESTAMP);
INSERT INTO smoke VALUES (1, 'alpha', SYSTIMESTAMP);
INSERT INTO smoke VALUES (2, 'beta',  SYSTIMESTAMP);
COMMIT;
```

Wrapper call:

```sql
EXECUTE SCRIPT database_migration.MIGRATE_TO_EXASOL(
    'ORACLE','ORACLE_JDBC','JDBC','%','EXASOL','SMOKE',
    NULL, TRUE, FALSE, '');
```

Result: 11-row summary, first row `'-- The following statements were executed
successfully.'`, target schema `"EXASOL"` created, table `"EXASOL"."SMOKE"`
loaded with 2 rows matching source values.

Connection name must be uppercase (`ORACLE_JDBC`) because the Oracle adapter
re-uses the bare identifier in IMPORT clauses without quoting; lowercase was
rejected by ORACLE_TO_EXASOL line 70.

Teardown removed `oracledb`, the `ORACLE_JDBC` Exasol connection, the
`EXASOL` schema, and the `dbm-net` bridge network.

## Manual Replay

```bash
lua test/test_migrate_to_exasol.lua
lua test/test_databricks_to_exasol.lua
lua test/test_db2_to_exasol.lua
lua test/test_postgres_to_exasol.lua
lua test/test_vertica_to_exasol.lua
python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ('test/create_script.py','test/export_res.py','test/mock_test.py','test/test_migrate_to_exasol_runtime.py')]"
EXA_DSN=localhost:8564 EXA_USER=sys EXA_PASSWORD=exasol python3 test/test_migrate_to_exasol_runtime.py
git diff --check
```

Expected: all exit 0. Runtime smoke prints
`preview_dispatch=17 execute_representative=4 empty_execution=pass
adapter_error=pass s3_rejection=pass alias_dispatch=pass`.

## Notes

Runtime mock smoke replaces scripts in `DATABASE_MIGRATION` on the target
Exasol database. Run only against a disposable local Nano.

`exanano-sqlcube` is the SQLCube-isolated Docker Nano documented in
`exasol-maglev/docs/ops/exanano-local-runtime.md`. It exposes SQL on `8564`,
maps `/exa/jdbc` for driver layout, and uses the `java` provision stack with
a deb822-aware override.

The Vertica `TIMESTAMP` truncation noted in the previous report has since
been fixed: the adapter now maps `TIMESTAMP` to Exasol `TIMESTAMP`
(`test/test_vertica_to_exasol.lua` covers this).

Seven sources remain PENDING strictly because their database image or
endpoint requires a cloud account or license we do not have today. None
block consolidation of `MIGRATE_TO_EXASOL` itself: the wrapper dispatch is
proven for all 17 sources via runtime mock smoke.
