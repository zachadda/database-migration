# Oracle Adapter — Session Handoff

Source: Codex investigation note, plan `add-adapter-datatype-smoke-matrix`. Oracle smoke deferred (see `verification-report.md` rows 43–44, 50, 71). Pick up from runtime-crash diagnosis, not SQL logic.

## Status

- Oracle 23c source booted on Frankfurt EC2, JDBC connection setup reached the wrapper.
- `database_migration.ORACLE_TO_EXASOL` (`oracle_to_exasol.sql:13`) preview succeeded once, then **execute crashed local ExaNano** at line 815; rerun crashed during preview around line 258 (`At least one tool did not finish correctly`).
- Minimal `NUMBER` / `VARCHAR2` table still destabilized ExaNano. Not a SQL/datatype mapping bug.
- All resources cleaned up (EC2 container removed, SG rule revoked, swap removed, Oracle image removed, leftover Exasol connection dropped, `db-migration-nano` restarted healthy).
- Driver in place: `drivers/jdbc/oracle/ojdbc11-23.26.1.0.0.jar`.

## Hypothesis (ranked)

1. **ExaNano runtime bug on Oracle JDBC import inside Lua script.** Most likely. Minimal `NUMBER`/`VARCHAR2` table killed it.
2. **Oracle JDBC driver mismatch.** `ojdbc11-23.26.1.0.0.jar` may be incompatible with ExaNano Java/ETL path. Try `ojdbc8` or older `ojdbc11`.
3. **Nano resource pressure.** Prior `SQL process` signal 137 = OOM. Oracle metadata + IMPORT path may be heavy enough to tip Nano over.
4. **Oracle 23c metadata/NLS quirks.** `oracle_to_exasol.sql` written for older Oracle; new `ALL_TAB_COLUMNS` / NLS values may hit a bad path.

Less likely: master wrapper bug, CLOB/RAW/date mapping, OCI (JDBC-only path).

## Symptoms (Nano logs, prior run)

- `EtlProcess`, `SqlProcess`, then `ConnectionServer` exit with signal **134** (abort) during Oracle execute.
- Clients then see TLS EOF / connection closed.
- Earlier related: `SqlProcess` signal **137** (OOM kill).

## Next Steps (small → big probes)

Run direct `IMPORT FROM JDBC` probes against the Oracle source. **Do not** use the `ORACLE_TO_EXASOL` wrapper for diagnosis — it imports several `ALL_*` metadata queries in sequence and obscures which one crashes.

1. `IMPORT INTO (...) FROM JDBC AT <conn> STATEMENT 'SELECT 1 FROM dual'`
2. `... STATEMENT 'SELECT owner, table_name FROM all_tables WHERE owner=''ORADT'''`
3. `... STATEMENT 'SELECT <minimal cols> FROM all_tab_columns WHERE owner=''ORADT'''`
4. Repeat 1–3 swapping driver: `ojdbc8` (LTS), then older `ojdbc11` (e.g. 21.x).
5. If still crashing on (1): driver/runtime combo is bad → escalate to real/full Exasol cluster or OCI path.
6. If (1) passes but (2)/(3) crash: bug is in metadata query path. Capture exact failing `ALL_*` query and Nano log signal.

Decision rule:
- `SELECT 1 FROM dual` works → driver baseline OK; problem is metadata/IMPORT path.
- `SELECT 1 FROM dual` crashes → driver/runtime combo bad; swap driver before anything else.

## Env / Endpoints

- Local ExaNano: `db-migration-nano` (restart with standard exapump start; see `~/.claude/projects/.../project_exanano_deploy.md`).
- Oracle source previously on **Frankfurt EC2** (EXADesk relay region). Stand up fresh container when rerunning; re-add temp SG rule for 1521 and **revoke after**.
- Strong runtime option for escalation: real Exasol cluster (Ohio = SQLCube app server). Nano is the suspect, not Oracle.

## Files

- Adapter wrapper: `oracle_to_exasol.sql` (Lua, 864 lines; crash sites previously hit ~line 815 execute, ~line 258 preview)
- Driver: `drivers/jdbc/oracle/ojdbc11-23.26.1.0.0.jar`, `drivers/jdbc/oracle/settings.cfg`
- Old harness (Docker oracle-12c, OCI path): `test/testing_files/test_oracle.sh`
- Datatype probe schema: `test/testing_files/oracle_datatypes_test.sql`
- Smoke harness: `specs/_plans/add-adapter-datatype-smoke-matrix/tools/adapter_datatype_smoke.py` (use `--self-test all` to confirm canonical cases unchanged)
- Plan + tasks: `specs/_plans/add-adapter-datatype-smoke-matrix/plan.md`, `tasks.md`
- Verification report (Oracle rows 43–44, 71): `specs/_plans/add-adapter-datatype-smoke-matrix/verification-report.md`

## Out of Scope This Session

- Rewriting `ORACLE_TO_EXASOL` Lua. SQL logic not implicated yet.
- CLOB/RAW/date mapping fixes. Adapter never got far enough to exercise them.
- OCI driver path. Crash was JDBC-only.

## Done When

- Either: driver swap + minimal IMPORT proves Nano-Oracle JDBC stable → resume full smoke matrix on Nano.
- Or: reproducible crash documented with Nano log signal + failing query → move Oracle smoke to stronger Exasol runtime and mark Nano path unsupported in `verification-report.md`.
