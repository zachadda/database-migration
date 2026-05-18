# Master Wrapper Smoke Matrix

Local tracker for `MIGRATE_TO_EXASOL` live smoke coverage. Keep out of upstream PR unless explicitly requested.

| Source | Adapter | Live status | Evidence |
|--------|---------|-------------|----------|
| Databricks | `DATABRICKS_TO_EXASOL` | PASS | direct JDBC 1 row, preview 6, execute 7, loaded 25 |
| Exasol | `EXASOL_TO_EXASOL` | PASS | preview 9, execute 10, loaded 2 |
| Postgres | `POSTGRES_TO_EXASOL` | PASS | direct JDBC 1 row, preview 3, execute 4, loaded 2 |
| MySQL | `MYSQL_TO_EXASOL` | PASS | direct JDBC 1 row, preview 6, execute 7, loaded 2 |
| MariaDB | `MARIADB_TO_EXASOL` | PASS | direct JDBC 1 row, preview 6, execute 7, loaded 2 |
| Snowflake | `SNOWFLAKE_TO_EXASOL` | PASS | direct JDBC 1 row, preview 7, execute 8, loaded 25; PAT-as-password plus `JDBC_QUERY_RESULT_FORMAT=JSON` |
| SQL Server | `SQLSERVER_TO_EXASOL` | PASS | EC2 x86 SQL Server 2022 container: direct JDBC 1 row, preview 7, execute 8, loaded 2; container removed and temp SG rule revoked |
| DB2 | `DB2_TO_EXASOL` | PASS | direct JDBC 1 row, preview 6, execute 7, loaded 2 |
| Vertica | `VERTICA_TO_EXASOL` | PASS | EC2 x86 Vertica container: direct JDBC 1 row, preview 6, execute 7, loaded 2; container removed and temp SG rule revoked; timestamp probe exposed existing adapter truncation issue |
| HANA | `HANA_TO_EXASOL` | PENDING | driver exists, source container pending |
| Azure SQL | `AZURE_SQL_TO_EXASOL` | PENDING | likely same family as SQL Server, separate smoke needed |
| BigQuery | `BIGQUERY_TO_EXASOL` | PENDING | driver exists, creds/source pending |
| Oracle | `ORACLE_TO_EXASOL` | PENDING | driver exists, source container pending |
| Teradata | `TERADATA_TO_EXASOL` | PENDING | driver exists, source container pending |
| Netezza | `NETEZZA_TO_EXASOL` | PENDING | driver/source pending |
| Vectorwise | `VECTORWISE_TO_EXASOL` | PENDING | driver exists, source container pending |
| Redshift | `REDSHIFT_TO_EXASOL` | PENDING | driver exists, source/service pending |
| S3 | direct loader | EXCLUDED | wrapper rejects and points to `S3_PARALLEL_READ` |
