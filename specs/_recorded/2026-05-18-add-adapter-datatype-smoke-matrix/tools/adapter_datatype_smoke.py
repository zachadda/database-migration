#!/usr/bin/env python3
"""Datatype smoke harness for live adapter mapping checks.

Start with Vertica because the TIMESTAMP mapping bug is already known.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import socket
import ssl
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen


REPO = Path(__file__).resolve().parents[4]
EXA_DSN = os.environ.get("EXA_DSN", "localhost:8566")
EXA_USER = os.environ.get("EXA_USER", "sys")
EXA_PASSWORD = os.environ.get("EXA_PASSWORD", "exasol")
EXA_ENCRYPTION = os.environ.get("EXA_ENCRYPTION", "true").lower() != "false"
VERTICA_HOST = os.environ.get("VERTICA_HOST", "52.28.97.243")
VERTICA_SSH_USER = os.environ.get("VERTICA_SSH_USER", "ubuntu")
VERTICA_SSH_KEY = os.environ.get(
    "VERTICA_SSH_KEY",
    "/Users/zachary.adda/Documents/GitHub/exa-intro-demo/zaad-frankfurt-keypair-pem.pem",
)
VERTICA_CONTAINER = os.environ.get("VERTICA_CONTAINER", "db-migration-vertica-datatype")
VERTICA_DB = os.environ.get("VERTICA_DB", "docker")
VERTICA_VSQL = "/opt/vertica/bin/vsql"
VERTICA_JDBC_URL = os.environ.get(
    "VERTICA_JDBC_URL",
    f"jdbc:vertica://{VERTICA_HOST}:5433/{VERTICA_DB}",
)
VERTICA_CONNECTION_USER = os.environ.get("VERTICA_CONNECTION_USER", "dbadmin")
VERTICA_CONNECTION_PASSWORD = os.environ.get("VERTICA_CONNECTION_PASSWORD", "")
VERTICA_SCHEMA = "wrap_vertica_datatypes"
EXASOL_SCHEMA = "WRAP_VERTICA_DATATYPES"
EXASOL_CONNECTION_NAME = "VERTICA_DATATYPE_SMOKE"
POSTGRES_CONTAINER = os.environ.get("POSTGRES_CONTAINER", "db-migration-postgres-datatype")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "postgres")
POSTGRES_USER = os.environ.get("POSTGRES_USER", "postgres")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "postgres")
POSTGRES_SCHEMA = "wrap_postgres_datatypes"
POSTGRES_EXASOL_SCHEMA = "WRAP_POSTGRES_DATATYPES"
POSTGRES_CONNECTION_NAME = "POSTGRES_DATATYPE_SMOKE"
MYSQL_CONTAINER = os.environ.get("MYSQL_CONTAINER", "db-migration-mysql-datatype")
MYSQL_DB = os.environ.get("MYSQL_DB", "wrap_mysql_datatypes")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASSWORD = os.environ.get("MYSQL_PASSWORD", "mysql")
MYSQL_CONNECTION_NAME = "MYSQL_DATATYPE_SMOKE"
MARIADB_CONTAINER = os.environ.get("MARIADB_CONTAINER", "db-migration-mariadb-datatype")
MARIADB_DB = os.environ.get("MARIADB_DB", "wrap_mariadb_datatypes")
MARIADB_USER = os.environ.get("MARIADB_USER", "root")
MARIADB_PASSWORD = os.environ.get("MARIADB_PASSWORD", "mariadb")
MARIADB_CONNECTION_NAME = "MARIADB_DATATYPE_SMOKE"
SQLSERVER_CONTAINER = os.environ.get("SQLSERVER_CONTAINER", "db-migration-sqlserver-datatype")
SQLSERVER_DB = os.environ.get("SQLSERVER_DB", "WRAPSQLTYPES")
SQLSERVER_SCHEMA = "wrap_sql_datatypes"
SQLSERVER_EXASOL_SCHEMA = "WRAP_SQLSERVER_DATATYPES"
SQLSERVER_CONNECTION_NAME = "SQLSERVER_DATATYPE_SMOKE"
SQLSERVER_USER = os.environ.get("SQLSERVER_USER", "sa")
SQLSERVER_PASSWORD = os.environ.get("SQLSERVER_PASSWORD", "ExasolSmoke!234")
SQLSERVER_PORT = 1433
DB2_CONTAINER = os.environ.get("DB2_CONTAINER", "db-migration-db2-datatype")
DB2_DB = os.environ.get("DB2_DB", "WRAPDB2")
DB2_SCHEMA = "DB2DT"
DB2_EXASOL_SCHEMA = "DB2DT"
DB2_CONNECTION_NAME = "DB2_DATATYPE_SMOKE"
DB2_USER = os.environ.get("DB2_USER", "db2inst1")
DB2_PASSWORD = os.environ.get("DB2_PASSWORD", "ExasolSmoke!234")
DB2_HOST = os.environ.get("DB2_HOST")
DB2_PORT = int(os.environ.get("DB2_PORT", "50000"))
ORACLE_CONTAINER = os.environ.get("ORACLE_CONTAINER", "db-migration-oracle-datatype")
ORACLE_SCHEMA = os.environ.get("ORACLE_SCHEMA", "ORADT")
ORACLE_PASSWORD = os.environ.get("ORACLE_PASSWORD", "ExasolSmoke234")
ORACLE_SERVICE = os.environ.get("ORACLE_SERVICE", "FREEPDB1")
ORACLE_PORT = 1521
ORACLE_CONNECTION_NAME = "ORACLE_DATATYPE_SMOKE"
AWS_REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "eu-central-1"))
SG_ID = os.environ.get("VERTICA_SECURITY_GROUP_ID", "sg-09420c6ebfd49c0b3")
SG_PORT = 5433
SG_PROTOCOL = "tcp"
PUBLIC_IP_ENV = os.environ.get("CURRENT_PUBLIC_IP")


CANONICAL_CASES = [
    {"name": "numeric", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb", "sqlserver", "db2", "oracle"], "description": "decimal/integer coverage"},
    {"name": "text", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb", "sqlserver", "db2", "oracle"], "description": "varchar/char coverage"},
    {"name": "date_time", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb", "sqlserver", "db2", "oracle"], "description": "date/timestamp coverage"},
    {"name": "boolean", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb", "sqlserver"], "description": "boolean coverage"},
    {"name": "binary", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb"], "description": "binary/varbinary coverage"},
    {"name": "null", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb"], "description": "null-only coverage"},
    {"name": "mixed_case_identifier", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb"], "description": "quoted identifier coverage"},
    {"name": "reserved_ish_identifier", "status": "planned", "supported_sources": ["vertica", "postgres", "mysql", "mariadb"], "description": "identifier collision coverage"},
]

VERTICA_CASES = {
    "timestamp": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "timestamp_case",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "TIMESTAMP_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "expected_error_patterns": ["truncation", "string length", "varchar(14)", "value too long"],
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f'create table {VERTICA_SCHEMA}.timestamp_case (id int, created_at timestamp)',
            f"insert into {VERTICA_SCHEMA}.timestamp_case values (1, timestamp '2024-01-01 10:11:12')",
            f"insert into {VERTICA_SCHEMA}.timestamp_case values (2, timestamp '2024-01-02 13:14:15')",
            "commit",
        ],
    },
    "core": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "core_case",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "CORE_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f'create table {VERTICA_SCHEMA}.core_case (id int, name varchar(50))',
            f"insert into {VERTICA_SCHEMA}.core_case values (1, 'alpha')",
            f"insert into {VERTICA_SCHEMA}.core_case values (2, 'beta')",
            "commit",
        ],
    },
    "boolean": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "boolean_case",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "BOOLEAN_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f"create table {VERTICA_SCHEMA}.boolean_case (id int, is_true boolean, is_false boolean, nullable_flag boolean)",
            f"insert into {VERTICA_SCHEMA}.boolean_case values (1, true, false, null)",
            f"insert into {VERTICA_SCHEMA}.boolean_case values (2, false, true, true)",
            "commit",
        ],
    },
    "binary": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "binary_case",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "BINARY_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f"create table {VERTICA_SCHEMA}.binary_case (id int, fixed_payload binary(4), payload varbinary(16), optional_payload varbinary(16))",
            f"insert into {VERTICA_SCHEMA}.binary_case values (1, HEX_TO_BINARY('0xDEADBEEF'), HEX_TO_BINARY('0xCAFE'), null)",
            f"insert into {VERTICA_SCHEMA}.binary_case values (2, HEX_TO_BINARY('0xFACEB00C'), HEX_TO_BINARY('0xBABE'), HEX_TO_BINARY('0xABCD'))",
            "commit",
        ],
    },
    "null": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "null_case",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "NULL_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f"create table {VERTICA_SCHEMA}.null_case (id int, nullable_text varchar(50), nullable_number numeric(12,2), nullable_date date, nullable_timestamp timestamp)",
            f"insert into {VERTICA_SCHEMA}.null_case values (1, null, null, null, null)",
            f"insert into {VERTICA_SCHEMA}.null_case values (2, null, null, null, null)",
            "commit",
        ],
    },
    "mixed_case_identifier": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "MixedCaseOrders",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "MIXEDCASEORDERS",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f'create table {VERTICA_SCHEMA}."MixedCaseOrders" ("OrderID" int, "CustomerName" varchar(50), "CreatedAt" timestamp)',
            f"insert into {VERTICA_SCHEMA}.\"MixedCaseOrders\" values (1, 'alpha', timestamp '2024-01-01 10:11:12')",
            f"insert into {VERTICA_SCHEMA}.\"MixedCaseOrders\" values (2, 'beta', timestamp '2024-01-02 13:14:15')",
            "commit",
        ],
    },
    "reserved_ish_identifier": {
        "source_schema": VERTICA_SCHEMA,
        "source_table": "order",
        "target_schema": EXASOL_SCHEMA,
        "target_table": "ORDER",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {VERTICA_SCHEMA} cascade",
            f"create schema if not exists {VERTICA_SCHEMA}",
            f'create table {VERTICA_SCHEMA}."order" ("select" int, "from" varchar(50), "group" boolean)',
            f"insert into {VERTICA_SCHEMA}.\"order\" values (1, 'alpha', true)",
            f"insert into {VERTICA_SCHEMA}.\"order\" values (2, 'beta', false)",
            "commit",
        ],
    },
}

POSTGRES_CASES = {
    "core": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "core_case",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "CORE_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}.core_case (
                id integer,
                small_value smallint,
                big_value bigint,
                amount numeric(12,2),
                ratio double precision,
                is_active boolean,
                code char(3),
                name varchar(50),
                notes text,
                created_on date,
                created_at timestamp without time zone,
                payload bytea,
                nullable_text varchar(20)
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}.core_case values
                (1, 7, 9000000000, 123.45, 1.25, true, 'ABC', 'alpha', 'first row', date '2024-01-01', timestamp '2024-01-01 10:11:12', decode('DEADBEEF', 'hex'), null),
                (2, 8, 9000000001, 678.90, 2.50, false, 'XYZ', 'beta', 'second row', date '2024-01-02', timestamp '2024-01-02 13:14:15', decode('CAFE', 'hex'), 'present')
            """,
        ],
    },
    "boolean": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "boolean_case",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "BOOLEAN_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}.boolean_case (
                id integer,
                is_true boolean,
                is_false boolean,
                nullable_flag boolean
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}.boolean_case values
                (1, true, false, null),
                (2, false, true, true)
            """,
        ],
    },
    "binary": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "binary_case",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "BINARY_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}.binary_case (
                id integer,
                payload bytea,
                optional_payload bytea
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}.binary_case values
                (1, decode('DEADBEEF', 'hex'), null),
                (2, decode('CAFE', 'hex'), decode('FACE', 'hex'))
            """,
        ],
    },
    "null": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "null_case",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "NULL_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}.null_case (
                id integer,
                nullable_text varchar(50),
                nullable_number numeric(12,2),
                nullable_date date,
                nullable_timestamp timestamp without time zone
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}.null_case values
                (1, null, null, null, null),
                (2, null, null, null, null)
            """,
        ],
    },
    "mixed_case_identifier": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "MixedCaseOrders",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "MIXEDCASEORDERS",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}."MixedCaseOrders" (
                "OrderID" integer,
                "CustomerName" varchar(50),
                "CreatedAt" timestamp without time zone
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}."MixedCaseOrders" values
                (1, 'alpha', timestamp '2024-01-01 10:11:12'),
                (2, 'beta', timestamp '2024-01-02 13:14:15')
            """,
        ],
    },
    "reserved_ish_identifier": {
        "source_schema": POSTGRES_SCHEMA,
        "source_table": "order",
        "target_schema": POSTGRES_EXASOL_SCHEMA,
        "target_table": "ORDER",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"drop schema if exists {POSTGRES_SCHEMA} cascade",
            f"create schema {POSTGRES_SCHEMA}",
            f"""
            create table {POSTGRES_SCHEMA}."order" (
                "select" integer,
                "from" varchar(50),
                "group" boolean
            )
            """,
            f"""
            insert into {POSTGRES_SCHEMA}."order" values
                (1, 'alpha', true),
                (2, 'beta', false)
            """,
        ],
    },
}

def mysql_like_cases(database_name: str) -> dict[str, dict[str, Any]]:
    return {
        "core": {
            "source_schema": database_name,
            "source_table": "core_case",
            "target_schema": database_name.upper(),
            "target_table": "CORE_CASE",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`core_case`",
                f"""
                create table `{database_name}`.`core_case` (
                    id int,
                    small_value smallint,
                    medium_value mediumint,
                    big_value bigint,
                    amount decimal(12,2),
                    ratio double,
                    is_active tinyint(1),
                    code char(3),
                    name varchar(50),
                    notes text,
                    created_on date,
                    created_at datetime,
                    event_time time,
                    payload varbinary(16),
                    nullable_text varchar(20)
                )
                """,
                f"""
                insert into `{database_name}`.`core_case` values
                    (1, 7, 700, 9000000000, 123.45, 1.25, 1, 'ABC', 'alpha', 'first row', date '2024-01-01', timestamp '2024-01-01 10:11:12', time '10:11:12', 'abc', null),
                    (2, 8, 800, 9000000001, 678.90, 2.50, 0, 'XYZ', 'beta', 'second row', date '2024-01-02', timestamp '2024-01-02 13:14:15', time '13:14:15', 'xyz', 'present')
                """,
            ],
        },
        "mixed_case_identifier": {
            "source_schema": database_name,
            "source_table": "MixedCaseOrders",
            "target_schema": database_name.upper(),
            "target_table": "MIXEDCASEORDERS",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`MixedCaseOrders`",
                f"""
                create table `{database_name}`.`MixedCaseOrders` (
                    `OrderID` int,
                    `CustomerName` varchar(50),
                    `CreatedAt` datetime
                )
                """,
                f"""
                insert into `{database_name}`.`MixedCaseOrders` values
                    (1, 'alpha', timestamp '2024-01-01 10:11:12'),
                    (2, 'beta', timestamp '2024-01-02 13:14:15')
                """,
            ],
        },
        "boolean": {
            "source_schema": database_name,
            "source_table": "boolean_case",
            "target_schema": database_name.upper(),
            "target_table": "BOOLEAN_CASE",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`boolean_case`",
                f"""
                create table `{database_name}`.`boolean_case` (
                    id int,
                    is_true bit(1),
                    is_false bit(1),
                    nullable_flag bit(1)
                )
                """,
                f"""
                insert into `{database_name}`.`boolean_case` values
                    (1, b'1', b'0', null),
                    (2, b'0', b'1', b'1')
                """,
            ],
        },
        "binary": {
            "source_schema": database_name,
            "source_table": "binary_case",
            "target_schema": database_name.upper(),
            "target_table": "BINARY_CASE",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`binary_case`",
                f"""
                create table `{database_name}`.`binary_case` (
                    id int,
                    fixed_payload binary(4),
                    payload varbinary(16),
                    optional_payload varbinary(16)
                )
                """,
                f"""
                insert into `{database_name}`.`binary_case` values
                    (1, unhex('DEADBEEF'), unhex('CAFE'), null),
                    (2, unhex('FACEB00C'), unhex('BABE'), unhex('ABCD'))
                """,
            ],
        },
        "null": {
            "source_schema": database_name,
            "source_table": "null_case",
            "target_schema": database_name.upper(),
            "target_table": "NULL_CASE",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`null_case`",
                f"""
                create table `{database_name}`.`null_case` (
                    id int,
                    nullable_text varchar(50),
                    nullable_number decimal(12,2),
                    nullable_date date,
                    nullable_timestamp datetime
                )
                """,
                f"""
                insert into `{database_name}`.`null_case` values
                    (1, null, null, null, null),
                    (2, null, null, null, null)
                """,
            ],
        },
        "reserved_ish_identifier": {
            "source_schema": database_name,
            "source_table": "order",
            "target_schema": database_name.upper(),
            "target_table": "ORDER",
            "expected_failure": False,
            "expected_rows": 2,
            "seed_sql": [
                f"create database if not exists `{database_name}`",
                f"drop table if exists `{database_name}`.`order`",
                f"""
                create table `{database_name}`.`order` (
                    `select` int,
                    `from` varchar(50),
                    `group` tinyint(1)
                )
                """,
                f"""
                insert into `{database_name}`.`order` values
                    (1, 'alpha', 1),
                    (2, 'beta', 0)
                """,
            ],
        },
    }

MYSQL_CASES = mysql_like_cases(MYSQL_DB)
MARIADB_CASES = mysql_like_cases(MARIADB_DB)

SQLSERVER_CASES = {
    "core": {
        "source_schema": SQLSERVER_SCHEMA,
        "source_table": "core_case",
        "target_schema": SQLSERVER_EXASOL_SCHEMA,
        "target_table": "CORE_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": f"""
        IF DB_ID(N'{SQLSERVER_DB}') IS NULL CREATE DATABASE [{SQLSERVER_DB}];
        """,
        "table_sql": f"""
        USE [{SQLSERVER_DB}];
        IF SCHEMA_ID(N'{SQLSERVER_SCHEMA}') IS NULL EXEC(N'CREATE SCHEMA [{SQLSERVER_SCHEMA}]');
        DROP TABLE IF EXISTS [{SQLSERVER_SCHEMA}].[core_case];
        CREATE TABLE [{SQLSERVER_SCHEMA}].[core_case] (
            [id] int NULL,
            [small_value] smallint NULL,
            [big_value] bigint NULL,
            [amount] decimal(12,2) NULL,
            [ratio] float NULL,
            [is_active] bit NULL,
            [code] char(3) NULL,
            [name] varchar(50) NULL,
            [notes] varchar(max) NULL,
            [created_on] date NULL,
            [created_at] datetime2 NULL,
            [nullable_text] varchar(20) NULL
        );
        INSERT INTO [{SQLSERVER_SCHEMA}].[core_case] VALUES
            (1, 7, 9000000000, 123.45, 1.25, 1, 'ABC', 'alpha', 'first row', '2024-01-01', '2024-01-01T10:11:12', NULL),
            (2, 8, 9000000001, 678.90, 2.50, 0, 'XYZ', 'beta', 'second row', '2024-01-02', '2024-01-02T13:14:15', 'present');
        """,
    },
    "mixed_case_identifier": {
        "source_schema": SQLSERVER_SCHEMA,
        "source_table": "MixedCaseOrders",
        "target_schema": SQLSERVER_EXASOL_SCHEMA,
        "target_table": "MIXEDCASEORDERS",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": f"""
        IF DB_ID(N'{SQLSERVER_DB}') IS NULL CREATE DATABASE [{SQLSERVER_DB}];
        """,
        "table_sql": f"""
        USE [{SQLSERVER_DB}];
        IF SCHEMA_ID(N'{SQLSERVER_SCHEMA}') IS NULL EXEC(N'CREATE SCHEMA [{SQLSERVER_SCHEMA}]');
        DROP TABLE IF EXISTS [{SQLSERVER_SCHEMA}].[MixedCaseOrders];
        CREATE TABLE [{SQLSERVER_SCHEMA}].[MixedCaseOrders] (
            [OrderID] int NULL,
            [CustomerName] varchar(50) NULL,
            [CreatedAt] datetime2 NULL
        );
        INSERT INTO [{SQLSERVER_SCHEMA}].[MixedCaseOrders] VALUES
            (1, 'alpha', '2024-01-01T10:11:12'),
            (2, 'beta', '2024-01-02T13:14:15');
        """,
    },
    "reserved_ish_identifier": {
        "source_schema": SQLSERVER_SCHEMA,
        "source_table": "order",
        "target_schema": SQLSERVER_EXASOL_SCHEMA,
        "target_table": "ORDER",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": f"""
        IF DB_ID(N'{SQLSERVER_DB}') IS NULL CREATE DATABASE [{SQLSERVER_DB}];
        """,
        "table_sql": f"""
        USE [{SQLSERVER_DB}];
        IF SCHEMA_ID(N'{SQLSERVER_SCHEMA}') IS NULL EXEC(N'CREATE SCHEMA [{SQLSERVER_SCHEMA}]');
        DROP TABLE IF EXISTS [{SQLSERVER_SCHEMA}].[order];
        CREATE TABLE [{SQLSERVER_SCHEMA}].[order] (
            [select] int NULL,
            [from] varchar(50) NULL,
            [group] bit NULL
        );
        INSERT INTO [{SQLSERVER_SCHEMA}].[order] VALUES
            (1, 'alpha', 1),
            (2, 'beta', 0);
        """,
    },
}

DB2_CASES = {
    "core": {
        "source_schema": DB2_SCHEMA,
        "source_table": "CORE_CASE",
        "target_schema": DB2_EXASOL_SCHEMA,
        "target_table": "CORE_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"CREATE SCHEMA {DB2_SCHEMA}",
            f"""
            CREATE TABLE {DB2_SCHEMA}.CORE_CASE (
                ID INTEGER,
                SMALL_VALUE SMALLINT,
                BIG_VALUE BIGINT,
                AMOUNT DECIMAL(12,2),
                RATIO DOUBLE,
                REAL_VALUE REAL,
                CODE CHARACTER(3),
                NAME CHARACTER VARYING(50),
                NOTES CLOB(1000),
                CREATED_ON DATE,
                CREATED_AT TIMESTAMP
            )
            """,
            f"""
            INSERT INTO {DB2_SCHEMA}.CORE_CASE VALUES
                (1, 7, 9000000000, 123.45, 1.25, 1.5, 'ABC', 'alpha', 'first row', DATE('2024-01-01'), TIMESTAMP('2024-01-01 10:11:12')),
                (2, 8, 9000000001, 678.90, 2.50, 2.5, 'XYZ', 'beta', 'second row', DATE('2024-01-02'), TIMESTAMP('2024-01-02 13:14:15'))
            """,
        ],
    },
    "mixed_case_identifier": {
        "source_schema": DB2_SCHEMA,
        "source_table": "MixedCaseOrders",
        "target_schema": DB2_EXASOL_SCHEMA,
        "target_table": "MIXEDCASEORDERS",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"CREATE SCHEMA {DB2_SCHEMA}",
            f"""
            CREATE TABLE {DB2_SCHEMA}."MixedCaseOrders" (
                "OrderID" INTEGER,
                "CustomerName" CHARACTER VARYING(50),
                "CreatedAt" TIMESTAMP
            )
            """,
            f"""
            INSERT INTO {DB2_SCHEMA}."MixedCaseOrders" VALUES
                (1, 'alpha', TIMESTAMP('2024-01-01 10:11:12')),
                (2, 'beta', TIMESTAMP('2024-01-02 13:14:15'))
            """,
        ],
    },
    "reserved_ish_identifier": {
        "source_schema": DB2_SCHEMA,
        "source_table": "ORDER",
        "target_schema": DB2_EXASOL_SCHEMA,
        "target_table": "ORDER",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": [
            f"CREATE SCHEMA {DB2_SCHEMA}",
            f"""
            CREATE TABLE {DB2_SCHEMA}."ORDER" (
                "SELECT" INTEGER,
                "FROM" CHARACTER VARYING(50),
                "GROUP" SMALLINT
            )
            """,
            f"""
            INSERT INTO {DB2_SCHEMA}."ORDER" VALUES
                (1, 'alpha', 1),
                (2, 'beta', 0)
            """,
        ],
    },
}

ORACLE_CASES = {
    "minimal": {
        "source_schema": ORACLE_SCHEMA,
        "source_table": "MINIMAL_CASE",
        "target_schema": ORACLE_SCHEMA,
        "target_table": "MINIMAL_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": f"""
        whenever sqlerror exit failure
        begin
            execute immediate 'drop user {ORACLE_SCHEMA} cascade';
        exception
            when others then
                if sqlcode != -1918 then raise; end if;
        end;
        /
        create user {ORACLE_SCHEMA} identified by "{ORACLE_PASSWORD}";
        grant create session, create table to {ORACLE_SCHEMA};
        alter user {ORACLE_SCHEMA} quota unlimited on users;
        create table {ORACLE_SCHEMA}.MINIMAL_CASE (
            ID number(10,0),
            NAME varchar2(50)
        );
        insert into {ORACLE_SCHEMA}.MINIMAL_CASE values (1, 'alpha');
        insert into {ORACLE_SCHEMA}.MINIMAL_CASE values (2, 'beta');
        commit;
        exit;
        """,
    },
    "core": {
        "source_schema": ORACLE_SCHEMA,
        "source_table": "CORE_CASE",
        "target_schema": ORACLE_SCHEMA,
        "target_table": "CORE_CASE",
        "expected_failure": False,
        "expected_rows": 2,
        "seed_sql": f"""
        whenever sqlerror exit failure
        begin
            execute immediate 'drop table {ORACLE_SCHEMA}.CORE_CASE purge';
        exception
            when others then
                if sqlcode != -942 then raise; end if;
        end;
        /
        begin
            execute immediate 'drop user {ORACLE_SCHEMA} cascade';
        exception
            when others then
                if sqlcode != -1918 then raise; end if;
        end;
        /
        create user {ORACLE_SCHEMA} identified by "{ORACLE_PASSWORD}";
        grant create session, create table to {ORACLE_SCHEMA};
        alter user {ORACLE_SCHEMA} quota unlimited on users;
        create table {ORACLE_SCHEMA}.CORE_CASE (
            ID number(10,0),
            SMALL_VALUE number(5,0),
            BIG_VALUE number(19,0),
            AMOUNT number(12,2),
            RATIO binary_double,
            REAL_VALUE binary_float,
            CODE char(3),
            NAME varchar2(50),
            NOTES clob,
            CREATED_ON date,
            CREATED_AT timestamp(6),
            PAYLOAD raw(8),
            NULLABLE_TEXT varchar2(20)
        );
        insert into {ORACLE_SCHEMA}.CORE_CASE values (
            1,
            7,
            9000000000,
            123.45,
            1.25,
            1.5,
            'ABC',
            'alpha',
            'first row',
            date '2024-01-01',
            timestamp '2024-01-01 10:11:12',
            hextoraw('DEADBEEF'),
            null
        );
        insert into {ORACLE_SCHEMA}.CORE_CASE values (
            2,
            8,
            9000000001,
            678.90,
            2.50,
            2.5,
            'XYZ',
            'beta',
            'second row',
            date '2024-01-02',
            timestamp '2024-01-02 13:14:15',
            hextoraw('CAFEBABE'),
            'present'
        );
        commit;
        exit;
        """,
    },
}


class SmokeError(RuntimeError):
    pass


@dataclass
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str


def compact_json(data: Any) -> str:
    return json.dumps(data, separators=(",", ":"), sort_keys=True)


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeError(message)


def extract_create_script(path: Path, script_name: str) -> str:
    content = path.read_text().replace("\r\n", "\n")
    pattern = rf"create or replace script database_migration\.{script_name}\s*\(.*?\n/\n"
    match = re.search(pattern, content, flags=re.IGNORECASE | re.DOTALL)
    if not match:
        raise SmokeError(f"Could not extract {script_name} from {path}")
    return match.group(0)


def sql_string(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def connect_exasol():
    try:
        import pyexasol
    except Exception as exc:  # pragma: no cover - import failure is a runtime env issue
        raise SmokeError(f"pyexasol import failed: {exc}") from exc

    return pyexasol.connect(
        dsn=EXA_DSN,
        user=EXA_USER,
        password=EXA_PASSWORD,
        encryption=EXA_ENCRYPTION,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def run_command(command: list[str], timeout: int = 600, check: bool = True) -> CommandResult:
    proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    result = CommandResult(command=command, returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    if check and proc.returncode != 0:
        raise SmokeError(format_command_failure(result))
    return result


def format_command_failure(result: CommandResult) -> str:
    return f"Command failed ({result.returncode}): {shlex.join(result.command)}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"


def ssh_command(remote_command: str, timeout: int = 600, check: bool = True) -> CommandResult:
    command = [
        "ssh",
        "-i",
        VERTICA_SSH_KEY,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"{VERTICA_SSH_USER}@{VERTICA_HOST}",
        "bash",
        "-lc",
        remote_command,
    ]
    return run_command(command, timeout=timeout, check=check)


def remote_vsql(sql: str, timeout: int = 600, check: bool = True) -> CommandResult:
    remote = (
        "set -euo pipefail; "
        f"docker exec -u dbadmin {shlex.quote(VERTICA_CONTAINER)} "
        f"{VERTICA_VSQL} -d {shlex.quote(VERTICA_DB)} -c {shlex.quote(sql)}"
    )
    return ssh_command(remote, timeout=timeout, check=check)


def ensure_public_ip() -> str:
    if PUBLIC_IP_ENV:
        return PUBLIC_IP_ENV.strip()

    for endpoint in ("https://checkip.amazonaws.com", "https://api.ipify.org"):
        try:
            with urlopen(endpoint, timeout=15) as response:
                value = response.read().decode("utf-8").strip()
                if value:
                    return value
        except URLError:
            continue

    raise SmokeError(
        "Could not resolve current public IP. Set CURRENT_PUBLIC_IP and rerun the live Vertica smoke."
    )


def aws_command(*args: str, timeout: int = 120, check: bool = True) -> CommandResult:
    command = ["aws", "--region", AWS_REGION, "ec2", *args]
    return run_command(command, timeout=timeout, check=check)


def authorize_security_group(ipv4: str, port: int = SG_PORT) -> dict[str, Any]:
    cidr = f"{ipv4}/32"
    command = [
        "authorize-security-group-ingress",
        "--group-id",
        SG_ID,
        "--protocol",
        SG_PROTOCOL,
        "--port",
        str(port),
        "--cidr",
        cidr,
    ]
    result = aws_command(*command, check=False)
    if result.returncode != 0 and "InvalidPermission.Duplicate" not in result.stderr:
        raise SmokeError(
            "Failed to authorize Vertica security-group rule:\n"
            f"CMD: {shlex.join(result.command)}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return {"group_id": SG_ID, "cidr": cidr, "port": port, "status": "authorized"}


def revoke_security_group(ipv4: str, port: int = SG_PORT) -> dict[str, Any]:
    cidr = f"{ipv4}/32"
    command = [
        "revoke-security-group-ingress",
        "--group-id",
        SG_ID,
        "--protocol",
        SG_PROTOCOL,
        "--port",
        str(port),
        "--cidr",
        cidr,
    ]
    result = aws_command(*command, check=False)
    if result.returncode != 0 and "InvalidPermission.NotFound" not in result.stderr:
        return {
            "group_id": SG_ID,
            "cidr": cidr,
            "port": port,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"group_id": SG_ID, "cidr": cidr, "port": port, "status": "revoked"}


def deploy_wrapper_scripts(conn: Any) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / "vertica_to_exasol.sql", "VERTICA_TO_EXASOL"))


def deploy_postgres_scripts(conn: Any) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / "postgres_to_exasol.sql", "POSTGRES_TO_EXASOL"))


def deploy_mysql_like_scripts(conn: Any, adapter_name: str, script_file: str) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / script_file, adapter_name))


def deploy_sqlserver_scripts(conn: Any) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / "sqlserver_to_exasol.sql", "SQLSERVER_TO_EXASOL"))


def deploy_db2_scripts(conn: Any) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / "db2_to_exasol.sql", "DB2_TO_EXASOL"))


def deploy_oracle_scripts(conn: Any) -> None:
    conn.execute("create schema if not exists database_migration")
    conn.execute(extract_create_script(REPO / "migrate_to_exasol.sql", "MIGRATE_TO_EXASOL"))
    conn.execute(extract_create_script(REPO / "oracle_to_exasol.sql", "ORACLE_TO_EXASOL"))


def create_exasol_connection(conn: Any, connection_name: str, jdbc_url: str) -> None:
    conn.execute(
        "create or replace connection "
        f'"{connection_name}" to {sql_string(jdbc_url)} user {sql_string(VERTICA_CONNECTION_USER)} '
        f"identified by {sql_string(VERTICA_CONNECTION_PASSWORD)}"
    )


def create_postgres_exasol_connection(conn: Any, jdbc_url: str) -> None:
    conn.execute(
        "create or replace connection "
        f'"{POSTGRES_CONNECTION_NAME}" to {sql_string(jdbc_url)} '
        f"user {sql_string(POSTGRES_USER)} identified by {sql_string(POSTGRES_PASSWORD)}"
    )


def create_mysql_like_exasol_connection(conn: Any, connection_name: str, jdbc_url: str, user: str, password: str) -> None:
    conn.execute(
        "create or replace connection "
        f'"{connection_name}" to {sql_string(jdbc_url)} '
        f"user {sql_string(user)} identified by {sql_string(password)}"
    )


def drop_exasol_connection(conn: Any, connection_name: str) -> None:
    conn.execute(f'drop connection if exists "{connection_name}"')


def drop_exasol_schema(conn: Any, schema_name: str) -> None:
    conn.execute(f'drop schema if exists "{schema_name}" cascade')


def run_exasol_cleanup_with_retry(conn: Any, cleanup_action: Any) -> None:
    try:
        cleanup_action(conn)
        return
    except Exception as first_exc:
        fresh_conn = connect_exasol()
        try:
            cleanup_action(fresh_conn)
        except Exception as retry_exc:
            raise retry_exc from first_exc
        finally:
            try:
                fresh_conn.close()
            except Exception:
                pass


def ensure_source_container() -> dict[str, Any]:
    remote = (
        "set -euo pipefail; "
        f"docker rm -f {shlex.quote(VERTICA_CONTAINER)} >/dev/null 2>&1 || true; "
        f"docker run -d --name {shlex.quote(VERTICA_CONTAINER)} -p 5433:5433 jbfavre/vertica:latest >/dev/null; "
        "for _ in $(seq 1 90); do "
        f"docker exec -u dbadmin {shlex.quote(VERTICA_CONTAINER)} {VERTICA_VSQL} -d {shlex.quote(VERTICA_DB)} -c 'select 1' >/dev/null 2>&1 && exit 0; "
        "sleep 5; "
        "done; "
        "exit 1"
    )
    ssh_command(remote, timeout=1200)
    return {"name": VERTICA_CONTAINER, "status": "running"}


def ensure_postgres_container() -> dict[str, Any]:
    run_command(["docker", "rm", "-f", POSTGRES_CONTAINER], check=False)
    run_command([
        "docker",
        "run",
        "-d",
        "--name",
        POSTGRES_CONTAINER,
        "-e",
        f"POSTGRES_PASSWORD={POSTGRES_PASSWORD}",
        "-e",
        f"POSTGRES_USER={POSTGRES_USER}",
        "-e",
        f"POSTGRES_DB={POSTGRES_DB}",
        "postgres:16-alpine",
    ])
    for _ in range(90):
        result = run_command([
            "docker",
            "exec",
            POSTGRES_CONTAINER,
            "pg_isready",
            "-U",
            POSTGRES_USER,
            "-d",
            POSTGRES_DB,
        ], timeout=30, check=False)
        if result.returncode == 0:
            return {"name": POSTGRES_CONTAINER, "status": "running"}
        run_command(["sleep", "1"])
    raise SmokeError("Postgres container did not become ready")


def ensure_mysql_like_container(source: str) -> dict[str, Any]:
    if source == "mysql":
        container = MYSQL_CONTAINER
        image = "mysql:8.4"
        root_password = MYSQL_PASSWORD
        env = [
            f"MYSQL_ROOT_PASSWORD={root_password}",
            f"MYSQL_DATABASE={MYSQL_DB}",
        ]
        ping_cmd = ["mysqladmin", "ping", "-h", "127.0.0.1", "-u", MYSQL_USER, f"-p{root_password}"]
    elif source == "mariadb":
        container = MARIADB_CONTAINER
        image = "mariadb:11"
        root_password = MARIADB_PASSWORD
        env = [
            f"MARIADB_ROOT_PASSWORD={root_password}",
            f"MARIADB_DATABASE={MARIADB_DB}",
        ]
        ping_cmd = ["mariadb-admin", "ping", "-h", "127.0.0.1", "-u", MARIADB_USER, f"-p{root_password}"]
    else:
        raise SmokeError(f"Unsupported MySQL-family source: {source}")

    run_command(["docker", "rm", "-f", container], check=False)
    command = ["docker", "run", "-d", "--name", container]
    for item in env:
        command.extend(["-e", item])
    command.append(image)
    run_command(command)

    for _ in range(120):
        result = run_command(["docker", "exec", container, *ping_cmd], timeout=30, check=False)
        if result.returncode == 0:
            return {"name": container, "status": "running"}
        run_command(["sleep", "1"])
    raise SmokeError(f"{source} container did not become ready")


def postgres_container_ip() -> str:
    result = run_command([
        "docker",
        "inspect",
        "-f",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        POSTGRES_CONTAINER,
    ])
    ip_addr = result.stdout.strip()
    if not ip_addr:
        raise SmokeError("Could not resolve Postgres container IP")
    return ip_addr


def postgres_jdbc_url() -> str:
    return os.environ.get("POSTGRES_JDBC_URL", f"jdbc:postgresql://{postgres_container_ip()}:5432/{POSTGRES_DB}")


def mysql_like_container_ip(container: str) -> str:
    result = run_command([
        "docker",
        "inspect",
        "-f",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        container,
    ])
    ip_addr = result.stdout.strip()
    if not ip_addr:
        raise SmokeError(f"Could not resolve {container} IP")
    return ip_addr


def mysql_like_jdbc_url(source: str) -> str:
    if source == "mysql":
        return os.environ.get(
            "MYSQL_JDBC_URL",
            f"jdbc:mysql://{mysql_like_container_ip(MYSQL_CONTAINER)}:3306/{MYSQL_DB}",
        )
    if source == "mariadb":
        return os.environ.get(
            "MARIADB_JDBC_URL",
            f"jdbc:mariadb://{mysql_like_container_ip(MARIADB_CONTAINER)}:3306/{MARIADB_DB}",
        )
    raise SmokeError(f"Unsupported MySQL-family source: {source}")


def seed_source_case(case_name: str) -> dict[str, Any]:
    case = VERTICA_CASES[case_name]
    remote_vsql("; ".join(case["seed_sql"]))
    return {
        "schema": case["source_schema"],
        "table": case["source_table"],
        "rows": case.get("expected_rows", 2),
        "status": "seeded",
    }


def seed_postgres_case(case_name: str) -> dict[str, Any]:
    case = POSTGRES_CASES[case_name]
    sql = "; ".join(statement.strip() for statement in case["seed_sql"])
    run_command([
        "docker",
        "exec",
        "-e",
        f"PGPASSWORD={POSTGRES_PASSWORD}",
        POSTGRES_CONTAINER,
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        POSTGRES_USER,
        "-d",
        POSTGRES_DB,
        "-c",
        sql,
    ])
    return {
        "schema": case["source_schema"],
        "table": case["source_table"],
        "rows": case["expected_rows"],
        "status": "seeded",
    }


def seed_mysql_like_case(source: str, case_name: str) -> dict[str, Any]:
    if source == "mysql":
        container = MYSQL_CONTAINER
        user = MYSQL_USER
        password = MYSQL_PASSWORD
        database = MYSQL_DB
        cases = MYSQL_CASES
        client = "mysql"
    elif source == "mariadb":
        container = MARIADB_CONTAINER
        user = MARIADB_USER
        password = MARIADB_PASSWORD
        database = MARIADB_DB
        cases = MARIADB_CASES
        client = "mariadb"
    else:
        raise SmokeError(f"Unsupported MySQL-family source: {source}")

    case = cases[case_name]
    sql = "; ".join(statement.strip() for statement in case["seed_sql"])
    run_command([
        "docker",
        "exec",
        container,
        client,
        "-u",
        user,
        f"-p{password}",
        "-e",
        sql,
    ])
    return {
        "schema": database,
        "table": case["source_table"],
        "rows": case["expected_rows"],
        "status": "seeded",
    }


def cleanup_source_schema() -> dict[str, Any]:
    result = remote_vsql(f"drop schema if exists {VERTICA_SCHEMA} cascade", check=False)
    if result.returncode != 0:
        return {
            "schema": VERTICA_SCHEMA,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"schema": VERTICA_SCHEMA, "status": "dropped"}


def cleanup_source_container() -> dict[str, Any]:
    remote = f"set -euo pipefail; docker rm -f {shlex.quote(VERTICA_CONTAINER)} >/dev/null 2>&1 || true"
    result = ssh_command(remote, timeout=120, check=False)
    if result.returncode != 0:
        return {
            "name": VERTICA_CONTAINER,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": VERTICA_CONTAINER, "status": "removed"}


def cleanup_postgres_container() -> dict[str, Any]:
    result = run_command(["docker", "rm", "-f", POSTGRES_CONTAINER], timeout=120, check=False)
    if result.returncode != 0 and "No such container" not in result.stderr:
        return {
            "name": POSTGRES_CONTAINER,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": POSTGRES_CONTAINER, "status": "removed"}


def cleanup_mysql_like_container(source: str) -> dict[str, Any]:
    container = MYSQL_CONTAINER if source == "mysql" else MARIADB_CONTAINER
    result = run_command(["docker", "rm", "-f", container], timeout=120, check=False)
    if result.returncode != 0 and "No such container" not in result.stderr:
        return {
            "name": container,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": container, "status": "removed"}


def sqlserver_exec(sql: str, database: str = "master", timeout: int = 600, check: bool = True) -> CommandResult:
    remote = (
        "set -euo pipefail; "
        f"docker exec {shlex.quote(SQLSERVER_CONTAINER)} /opt/mssql-tools18/bin/sqlcmd "
        f"-C -S localhost -U {shlex.quote(SQLSERVER_USER)} -P {shlex.quote(SQLSERVER_PASSWORD)} "
        f"-d {shlex.quote(database)} -Q {shlex.quote(sql)}"
    )
    return ssh_command(remote, timeout=timeout, check=check)


def ensure_sqlserver_container() -> dict[str, Any]:
    remote = (
        "set -euo pipefail; "
        f"docker rm -f {shlex.quote(SQLSERVER_CONTAINER)} >/dev/null 2>&1 || true; "
        "docker run -d "
        f"--name {shlex.quote(SQLSERVER_CONTAINER)} "
        "-e ACCEPT_EULA=Y "
        f"-e MSSQL_SA_PASSWORD={shlex.quote(SQLSERVER_PASSWORD)} "
        "-e MSSQL_PID=Developer "
        "-e MSSQL_MEMORY_LIMIT_MB=1200 "
        "-p 1433:1433 "
        "mcr.microsoft.com/mssql/server:2022-latest >/dev/null"
    )
    ssh_command(remote, timeout=300)
    for _ in range(120):
        result = sqlserver_exec("SELECT 1", timeout=30, check=False)
        if result.returncode == 0:
            return {"name": SQLSERVER_CONTAINER, "status": "running"}
        run_command(["sleep", "2"])
    raise SmokeError("SQL Server container did not become ready")


def seed_sqlserver_case(case_name: str) -> dict[str, Any]:
    case = SQLSERVER_CASES[case_name]
    sqlserver_exec(case["seed_sql"], database="master")
    sqlserver_exec(case["table_sql"], database=SQLSERVER_DB)
    return {
        "schema": case["source_schema"],
        "table": case["source_table"],
        "rows": case["expected_rows"],
        "status": "seeded",
    }


def cleanup_sqlserver_container() -> dict[str, Any]:
    remote = f"set -euo pipefail; docker rm -f {shlex.quote(SQLSERVER_CONTAINER)} >/dev/null 2>&1 || true"
    result = ssh_command(remote, timeout=120, check=False)
    if result.returncode != 0:
        return {
            "name": SQLSERVER_CONTAINER,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": SQLSERVER_CONTAINER, "status": "removed"}


def oracle_exec(sql: str, timeout: int = 600, check: bool = True) -> CommandResult:
    remote = (
        "set -euo pipefail; "
        f"printf %s {shlex.quote(sql)} | "
        f"docker exec -i {shlex.quote(ORACLE_CONTAINER)} "
        f"sqlplus -s system/{shlex.quote(ORACLE_PASSWORD)}@localhost:{ORACLE_PORT}/{shlex.quote(ORACLE_SERVICE)}"
    )
    return ssh_command(remote, timeout=timeout, check=check)


def ensure_oracle_container() -> dict[str, Any]:
    remote = (
        "set -euo pipefail; "
        f"docker rm -f {shlex.quote(ORACLE_CONTAINER)} >/dev/null 2>&1 || true; "
        "docker run -d "
        f"--name {shlex.quote(ORACLE_CONTAINER)} "
        f"-e ORACLE_PASSWORD={shlex.quote(ORACLE_PASSWORD)} "
        f"-p {ORACLE_PORT}:1521 "
        "gvenzl/oracle-free:23-slim-faststart >/dev/null"
    )
    ssh_command(remote, timeout=600)
    for _ in range(180):
        result = oracle_exec("select 1 from dual;\nexit;\n", timeout=60, check=False)
        if result.returncode == 0 and "1" in result.stdout:
            return {"name": ORACLE_CONTAINER, "status": "running"}
        run_command(["sleep", "5"])
    raise SmokeError("Oracle container did not become ready")


def oracle_jdbc_url() -> str:
    return os.environ.get(
        "ORACLE_JDBC_URL",
        f"jdbc:oracle:thin:@//{VERTICA_HOST}:{ORACLE_PORT}/{ORACLE_SERVICE}",
    )


def seed_oracle_case(case_name: str) -> dict[str, Any]:
    case = ORACLE_CASES[case_name]
    oracle_exec(case["seed_sql"], timeout=600)
    return {
        "schema": case["source_schema"],
        "table": case["source_table"],
        "rows": case["expected_rows"],
        "status": "seeded",
    }


def cleanup_oracle_container() -> dict[str, Any]:
    remote = f"set -euo pipefail; docker rm -f {shlex.quote(ORACLE_CONTAINER)} >/dev/null 2>&1 || true"
    result = ssh_command(remote, timeout=180, check=False)
    if result.returncode != 0:
        return {
            "name": ORACLE_CONTAINER,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": ORACLE_CONTAINER, "status": "removed"}


def wait_for_db2_container() -> dict[str, Any]:
    for _ in range(240):
        logs = run_command(["docker", "logs", DB2_CONTAINER], timeout=30, check=False)
        log_text = logs.stdout + logs.stderr
        if "Setup has completed" not in log_text:
            run_command(["sleep", "5"])
            continue
        result = run_command([
            "docker",
            "exec",
            DB2_CONTAINER,
            "su",
            "-",
            DB2_USER,
            "-c",
            f"db2 connect to {DB2_DB}",
        ], timeout=60, check=False)
        if result.returncode == 0 and "Database Connection Information" in result.stdout:
            for _ in range(60):
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.settimeout(2)
                    if sock.connect_ex(("127.0.0.1", DB2_PORT)) == 0:
                        run_command(["sleep", "90"])
                        return {"name": DB2_CONTAINER, "status": "running"}
                run_command(["sleep", "2"])
        run_command(["sleep", "5"])
    raise SmokeError("DB2 container did not become ready")


def ensure_db2_container() -> dict[str, Any]:
    existing = run_command(
        ["docker", "inspect", "-f", "{{.State.Running}}", DB2_CONTAINER],
        timeout=30,
        check=False,
    )
    if existing.returncode == 0 and existing.stdout.strip() == "true":
        port_check = run_command(["docker", "port", DB2_CONTAINER, "50000/tcp"], timeout=30, check=False)
        if port_check.returncode == 0 and port_check.stdout.strip():
            return wait_for_db2_container()

    run_command(["docker", "rm", "-f", DB2_CONTAINER], check=False)
    run_command([
        "docker",
        "run",
        "-d",
        "--platform",
        "linux/amd64",
        "--privileged=true",
        "--name",
        DB2_CONTAINER,
        "-p",
        f"{DB2_PORT}:50000",
        "-e",
        "LICENSE=accept",
        "-e",
        f"DB2INST1_PASSWORD={DB2_PASSWORD}",
        "-e",
        f"DBNAME={DB2_DB}",
        "icr.io/db2_community/db2:latest",
    ], timeout=300)
    return wait_for_db2_container()


def db2_container_ip() -> str:
    result = run_command([
        "docker",
        "inspect",
        "-f",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        DB2_CONTAINER,
    ])
    ip_addr = result.stdout.strip()
    if not ip_addr:
        raise SmokeError("Could not resolve DB2 container IP")
    return ip_addr


def db2_jdbc_url() -> str:
    if "DB2_JDBC_URL" in os.environ:
        return os.environ["DB2_JDBC_URL"]
    if DB2_HOST:
        return f"jdbc:db2://{DB2_HOST}:{DB2_PORT}/{DB2_DB}"
    return f"jdbc:db2://{db2_container_ip()}:50000/{DB2_DB}"


def seed_db2_case(case_name: str) -> dict[str, Any]:
    case = DB2_CASES[case_name]
    for statement in case["seed_sql"]:
        sql = " ".join(statement.strip() for statement in statement.splitlines())
        command = [
            "docker",
            "exec",
            DB2_CONTAINER,
            "su",
            "-",
            DB2_USER,
            "-c",
            f"db2 connect to {DB2_DB}; db2 -v \"{sql}\"",
        ]
        for _ in range(24):
            result = run_command(command, timeout=600, check=False)
            output = result.stdout + result.stderr
            if result.returncode == 0:
                break
            if "SQL6036N" in output or "SQL1024N" in output:
                run_command(["sleep", "10"])
                continue
            raise SmokeError(format_command_failure(result))
        else:
            raise SmokeError(format_command_failure(result))
    return {
        "schema": case["source_schema"],
        "table": case["source_table"],
        "rows": case["expected_rows"],
        "status": "seeded",
    }


def cleanup_db2_container() -> dict[str, Any]:
    result = run_command(["docker", "rm", "-f", DB2_CONTAINER], timeout=180, check=False)
    if result.returncode != 0 and "No such container" not in result.stderr:
        return {
            "name": DB2_CONTAINER,
            "status": "failed",
            "error": result.stderr.strip() or result.stdout.strip(),
        }
    return {"name": DB2_CONTAINER, "status": "removed"}


def normalize_rows(rows: list[tuple[Any, ...]]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for row in rows:
        sql_text = row[0] if len(row) > 0 else None
        success = row[1] if len(row) > 1 else None
        error_message = row[2] if len(row) > 2 else None
        normalized.append({"sql_text": sql_text, "success": success, "error_message": error_message})
    return normalized


def fetch_exasol_rows_with_retry(conn: Any, sql: str) -> list[dict[str, Any]]:
    try:
        return normalize_rows(conn.execute(sql).fetchall())
    except Exception:
        run_command(["sleep", "30"])
        fresh_conn = connect_exasol()
        try:
            return normalize_rows(fresh_conn.execute(sql).fetchall())
        finally:
            try:
                fresh_conn.close()
            except Exception:
                pass


def first_non_empty_sql_text(rows: list[dict[str, Any]]) -> str | None:
    for row in rows:
        text = row.get("sql_text")
        if text and not str(text).startswith("--"):
            return str(text)
    return None


def format_execute_result(rows: list[dict[str, Any]]) -> dict[str, Any]:
    failures = [row for row in rows if str(row.get("success", "")).upper() == "FALSE"]
    return {
        "row_count": len(rows),
        "rows": rows,
        "failures": failures,
        "failed": bool(failures),
    }


def query_target_row_count(conn: Any, schema_name: str, table_name: str) -> int | None:
    try:
        return int(conn.execute(f'select count(*) from "{schema_name}"."{table_name}"').fetchval())
    except Exception:
        return None


def run_wrapper_case(conn: Any, case_name: str) -> dict[str, Any]:
    case = VERTICA_CASES[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string('vertica')},"
        f"{sql_string(EXASOL_CONNECTION_NAME)},"
        f"{sql_string('JDBC')},"
        f"{sql_string('%')},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        f"{sql_string(case['target_schema'])},"
        "TRUE,"
        "TRUE,"
        f"{sql_string('')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = fetch_exasol_rows_with_retry(conn, preview_sql)
    run_command(["sleep", "30"])
    execute_conn = connect_exasol()
    try:
        execute_rows = fetch_exasol_rows_with_retry(execute_conn, execute_sql)
        loaded_rows = query_target_row_count(execute_conn, case["target_schema"], case["target_table"])
    finally:
        try:
            execute_conn.close()
        except Exception:
            pass

    result: dict[str, Any] = {
        "source": "vertica",
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": EXASOL_CONNECTION_NAME,
            "jdbc_url": VERTICA_JDBC_URL,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    if case["expected_failure"]:
        error_blob = " ".join(
            str(row.get("error_message") or "")
            for row in result["execute"]["failures"]
        ).lower()
        assert_true(
            any(pattern in error_blob for pattern in case["expected_error_patterns"]),
            f"Expected Vertica timestamp failure message to mention one of {case['expected_error_patterns']}, got: {error_blob}",
        )
        result["execute"]["status"] = "expected_failure"
        result["loaded_rows"] = query_target_row_count(conn, case["target_schema"], case["target_table"])
        return result

    assert_true(
        not result["execute"]["failed"],
        "Expected no execute failures for "
        + case_name
        + ", got "
        + compact_json({"failures": result["execute"]["failures"], "preview": result["preview"]}),
    )
    assert_true(
        loaded_rows == case["expected_rows"],
        "Vertica row count mismatch: "
        + compact_json(
            {
                "case": case_name,
                "expected_rows": case["expected_rows"],
                "loaded_rows": loaded_rows,
                "preview": result["preview"],
                "execute": result["execute"],
            }
        ),
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def run_postgres_wrapper_case(conn: Any, case_name: str, jdbc_url: str) -> dict[str, Any]:
    case = POSTGRES_CASES[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string('postgres')},"
        f"{sql_string(POSTGRES_CONNECTION_NAME)},"
        f"{sql_string('JDBC')},"
        f"{sql_string('%')},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        f"{sql_string(case['target_schema'])},"
        "TRUE,"
        "TRUE,"
        f"{sql_string('')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = fetch_exasol_rows_with_retry(conn, preview_sql)
    execute_rows = normalize_rows(conn.execute(execute_sql).fetchall())
    result: dict[str, Any] = {
        "source": "postgres",
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": POSTGRES_CONNECTION_NAME,
            "jdbc_url": jdbc_url,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    loaded_rows = query_target_row_count(conn, case["target_schema"], case["target_table"])
    assert_true(
        loaded_rows == case["expected_rows"],
        f"Expected {case['expected_rows']} loaded rows for postgres {case_name}, got {loaded_rows}",
    )
    assert_true(
        not result["execute"]["failed"],
        f"Expected no execute failures for postgres {case_name}, got {result['execute']['failures']}",
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def run_mysql_like_wrapper_case(conn: Any, source: str, case_name: str, jdbc_url: str) -> dict[str, Any]:
    if source == "mysql":
        cases = MYSQL_CASES
        connection_name = MYSQL_CONNECTION_NAME
    elif source == "mariadb":
        cases = MARIADB_CASES
        connection_name = MARIADB_CONNECTION_NAME
    else:
        raise SmokeError(f"Unsupported MySQL-family source: {source}")

    case = cases[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string(source)},"
        f"{sql_string(connection_name)},"
        f"{sql_string('JDBC')},"
        f"{sql_string('%')},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        "NULL,"
        "TRUE,"
        "TRUE,"
        f"{sql_string('')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = normalize_rows(conn.execute(preview_sql).fetchall())
    execute_rows = normalize_rows(conn.execute(execute_sql).fetchall())
    result: dict[str, Any] = {
        "source": source,
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": connection_name,
            "jdbc_url": jdbc_url,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    loaded_rows = query_target_row_count(conn, case["target_schema"], case["target_table"])
    assert_true(
        loaded_rows == case["expected_rows"],
        f"Expected {case['expected_rows']} loaded rows for {source} {case_name}, got {loaded_rows}",
    )
    assert_true(
        not result["execute"]["failed"],
        f"Expected no execute failures for {source} {case_name}, got {result['execute']['failures']}",
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def sqlserver_jdbc_url() -> str:
    return os.environ.get(
        "SQLSERVER_JDBC_URL",
        f"jdbc:sqlserver://{VERTICA_HOST}:{SQLSERVER_PORT};databaseName={SQLSERVER_DB};encrypt=false;trustServerCertificate=true",
    )


def run_sqlserver_wrapper_case(conn: Any, case_name: str, jdbc_url: str) -> dict[str, Any]:
    case = SQLSERVER_CASES[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string('sqlserver')},"
        f"{sql_string(SQLSERVER_CONNECTION_NAME)},"
        f"{sql_string('JDBC')},"
        f"{sql_string(SQLSERVER_DB)},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        f"{sql_string(case['target_schema'])},"
        "TRUE,"
        "TRUE,"
        f"{sql_string('DB2SCHEMA=false')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = normalize_rows(conn.execute(preview_sql).fetchall())
    execute_rows = normalize_rows(conn.execute(execute_sql).fetchall())
    result: dict[str, Any] = {
        "source": "sqlserver",
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": SQLSERVER_CONNECTION_NAME,
            "jdbc_url": jdbc_url,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    assert_true(
        not result["execute"]["failed"],
        "Expected no execute failures for sqlserver "
        + case_name
        + ", got "
        + compact_json({"failures": result["execute"]["failures"], "preview": result["preview"]}),
    )
    loaded_rows = query_target_row_count(conn, case["target_schema"], case["target_table"])
    assert_true(
        loaded_rows == case["expected_rows"],
        "SQL Server row count mismatch: "
        + compact_json(
            {
                "case": case_name,
                "expected_rows": case["expected_rows"],
                "loaded_rows": loaded_rows,
                "preview": result["preview"],
                "execute": result["execute"],
            }
        ),
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def run_db2_wrapper_case(conn: Any, case_name: str, jdbc_url: str) -> dict[str, Any]:
    case = DB2_CASES[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string('db2')},"
        f"{sql_string(DB2_CONNECTION_NAME)},"
        f"{sql_string('JDBC')},"
        f"{sql_string('%')},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        "NULL,"
        "TRUE,"
        "TRUE,"
        f"{sql_string('')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = fetch_exasol_rows_with_retry(conn, preview_sql)
    run_command(["sleep", "30"])
    execute_conn = connect_exasol()
    try:
        execute_rows = fetch_exasol_rows_with_retry(execute_conn, execute_sql)
        loaded_rows = query_target_row_count(execute_conn, case["target_schema"], case["target_table"])
    finally:
        try:
            execute_conn.close()
        except Exception:
            pass
    result: dict[str, Any] = {
        "source": "db2",
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": DB2_CONNECTION_NAME,
            "jdbc_url": jdbc_url,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    assert_true(
        not result["execute"]["failed"],
        f"Expected no execute failures for db2 {case_name}, got {result['execute']['failures']}",
    )
    assert_true(
        loaded_rows == case["expected_rows"],
        "DB2 row count mismatch: "
        + compact_json(
            {
                "expected_rows": case["expected_rows"],
                "loaded_rows": loaded_rows,
                "preview": result["preview"],
                "execute": result["execute"],
            }
        ),
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def run_oracle_wrapper_case(conn: Any, case_name: str, jdbc_url: str) -> dict[str, Any]:
    case = ORACLE_CASES[case_name]
    preview_sql = (
        "execute script database_migration.MIGRATE_TO_EXASOL("
        f"{sql_string('oracle')},"
        f"{sql_string(ORACLE_CONNECTION_NAME)},"
        f"{sql_string('JDBC')},"
        f"{sql_string('%')},"
        f"{sql_string(case['source_schema'])},"
        f"{sql_string(case['source_table'])},"
        "NULL,"
        "TRUE,"
        "TRUE,"
        f"{sql_string('PARALLEL_STATEMENTS=1;CREATE_PK=false;CREATE_FK=false;CHECK_MIGRATION=false')}"
        ")"
    )
    execute_sql = preview_sql.replace(",TRUE,TRUE,", ",TRUE,FALSE,")

    preview_rows = fetch_exasol_rows_with_retry(conn, preview_sql)
    execute_rows = normalize_rows(conn.execute(execute_sql).fetchall())
    result: dict[str, Any] = {
        "source": "oracle",
        "case": case_name,
        "expected_failure": case["expected_failure"],
        "connection": {
            "name": ORACLE_CONNECTION_NAME,
            "jdbc_url": jdbc_url,
        },
        "preview": {
            "row_count": len(preview_rows),
            "rows": preview_rows,
            "ddl": [row["sql_text"] for row in preview_rows if row.get("sql_text")],
            "first_statement": first_non_empty_sql_text(preview_rows),
        },
        "execute": format_execute_result(execute_rows),
        "cleanup": {},
    }

    assert_true(
        not result["execute"]["failed"],
        "Expected no execute failures for oracle "
        + case_name
        + ", got "
        + compact_json({"failures": result["execute"]["failures"], "preview": result["preview"]}),
    )
    loaded_rows = query_target_row_count(conn, case["target_schema"], case["target_table"])
    assert_true(
        loaded_rows == case["expected_rows"],
        "Oracle row count mismatch: "
        + compact_json(
            {
                "case": case_name,
                "expected_rows": case["expected_rows"],
                "loaded_rows": loaded_rows,
                "preview": result["preview"],
                "execute": result["execute"],
            }
        ),
    )
    result["execute"]["status"] = "loaded"
    result["loaded_rows"] = loaded_rows
    return result


def build_cleanup_result(
    *,
    source_ip: str,
    sg_result: dict[str, Any],
    source_container: dict[str, Any],
    source_schema: dict[str, Any],
    exasol_schema: dict[str, Any],
    exasol_connection: dict[str, Any],
) -> dict[str, Any]:
    entries = {
        "security_group_rule": sg_result,
        "source_container": source_container,
        "source_schema": source_schema,
        "exasol_schema": exasol_schema,
        "exasol_connection": exasol_connection,
    }
    status = "completed"
    for item in entries.values():
        if item.get("status") == "failed":
            status = "completed_with_errors"
            break
    return {"public_ip": source_ip, "status": status, **entries}


def live_vertica_case(case_name: str) -> dict[str, Any]:
    public_ip = ensure_public_ip()
    sg_result = authorize_security_group(public_ip)
    source_container: dict[str, Any] = {"name": VERTICA_CONTAINER, "status": "not_started"}
    source_schema: dict[str, Any] = {"schema": VERTICA_SCHEMA, "status": "not_cleaned"}
    exasol_schema: dict[str, Any] = {"schema": EXASOL_SCHEMA, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": EXASOL_CONNECTION_NAME, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_source_container()
        seed_info = seed_source_case(case_name)
        conn = connect_exasol()
        deploy_wrapper_scripts(conn)
        create_exasol_connection(conn, EXASOL_CONNECTION_NAME, VERTICA_JDBC_URL)

        if case_name == "timestamp":
            drop_exasol_schema(conn, EXASOL_SCHEMA)
        elif case_name == "core":
            drop_exasol_schema(conn, EXASOL_SCHEMA)

        run_result = run_wrapper_case(conn, case_name)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        run_result["security_group_rule"] = sg_result
        return run_result
    finally:
        if conn is not None:
            try:
                drop_exasol_schema(conn, EXASOL_SCHEMA)
                exasol_schema = {"schema": EXASOL_SCHEMA, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": EXASOL_SCHEMA, "status": "failed", "error": str(exc)}

            try:
                drop_exasol_connection(conn, EXASOL_CONNECTION_NAME)
                exasol_connection = {"name": EXASOL_CONNECTION_NAME, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": EXASOL_CONNECTION_NAME, "status": "failed", "error": str(exc)}

        try:
            source_schema = cleanup_source_schema()
        except Exception as exc:
            source_schema = {"schema": VERTICA_SCHEMA, "status": "failed", "error": str(exc)}

        try:
            source_container = cleanup_source_container()
        except Exception as exc:
            source_container = {"name": VERTICA_CONTAINER, "status": "failed", "error": str(exc)}

        sg_cleanup = revoke_security_group(public_ip)
        cleanup = build_cleanup_result(
            source_ip=public_ip,
            sg_result=sg_cleanup,
            source_container=source_container,
            source_schema=source_schema,
            exasol_schema=exasol_schema,
            exasol_connection=exasol_connection,
        )

        if run_result is not None:
            run_result["cleanup"] = cleanup
            run_result["cleanup"]["status"] = cleanup["status"]
            run_result["cleanup"]["security_group_rule"] = cleanup["security_group_rule"]
            run_result["cleanup"]["source_container"] = cleanup["source_container"]
            run_result["cleanup"]["source_schema"] = cleanup["source_schema"]
            run_result["cleanup"]["exasol_schema"] = cleanup["exasol_schema"]
            run_result["cleanup"]["exasol_connection"] = cleanup["exasol_connection"]
            run_result["cleanup"]["public_ip"] = cleanup["public_ip"]

        if cleanup["status"] != "completed":
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def live_postgres_case(case_name: str) -> dict[str, Any]:
    source_container: dict[str, Any] = {"name": POSTGRES_CONTAINER, "status": "not_started"}
    exasol_schema: dict[str, Any] = {"schema": POSTGRES_EXASOL_SCHEMA, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": POSTGRES_CONNECTION_NAME, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_postgres_container()
        jdbc_url = postgres_jdbc_url()
        seed_info = seed_postgres_case(case_name)
        conn = connect_exasol()
        deploy_postgres_scripts(conn)
        drop_exasol_schema(conn, POSTGRES_EXASOL_SCHEMA)
        create_postgres_exasol_connection(conn, jdbc_url)
        run_result = run_postgres_wrapper_case(conn, case_name, jdbc_url)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        return run_result
    finally:
        if conn is not None:
            try:
                drop_exasol_schema(conn, POSTGRES_EXASOL_SCHEMA)
                exasol_schema = {"schema": POSTGRES_EXASOL_SCHEMA, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": POSTGRES_EXASOL_SCHEMA, "status": "failed", "error": str(exc)}

            try:
                drop_exasol_connection(conn, POSTGRES_CONNECTION_NAME)
                exasol_connection = {"name": POSTGRES_CONNECTION_NAME, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": POSTGRES_CONNECTION_NAME, "status": "failed", "error": str(exc)}

        source_container = cleanup_postgres_container()
        cleanup = {
            "status": "completed",
            "source_container": source_container,
            "exasol_schema": exasol_schema,
            "exasol_connection": exasol_connection,
        }
        if source_container.get("status") == "failed" or exasol_schema.get("status") == "failed" or exasol_connection.get("status") == "failed":
            cleanup["status"] = "completed_with_errors"

        if run_result is not None:
            run_result["cleanup"] = cleanup

        if cleanup["status"] != "completed":
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def live_mysql_like_case(source: str, case_name: str) -> dict[str, Any]:
    if source == "mysql":
        connection_name = MYSQL_CONNECTION_NAME
        script_name = "MYSQL_TO_EXASOL"
        script_file = "mysql_to_exasol.sql"
        user = MYSQL_USER
        password = MYSQL_PASSWORD
        target_schema = MYSQL_DB.upper()
    elif source == "mariadb":
        connection_name = MARIADB_CONNECTION_NAME
        script_name = "MARIADB_TO_EXASOL"
        script_file = "mariadb_to_exasol.sql"
        user = MARIADB_USER
        password = MARIADB_PASSWORD
        target_schema = MARIADB_DB.upper()
    else:
        raise SmokeError(f"Unsupported MySQL-family source: {source}")

    source_container: dict[str, Any] = {"name": source, "status": "not_started"}
    exasol_schema: dict[str, Any] = {"schema": target_schema, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": connection_name, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_mysql_like_container(source)
        jdbc_url = mysql_like_jdbc_url(source)
        seed_info = seed_mysql_like_case(source, case_name)
        conn = connect_exasol()
        deploy_mysql_like_scripts(conn, script_name, script_file)
        drop_exasol_schema(conn, target_schema)
        create_mysql_like_exasol_connection(conn, connection_name, jdbc_url, user, password)
        run_result = run_mysql_like_wrapper_case(conn, source, case_name, jdbc_url)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        return run_result
    finally:
        if conn is not None:
            try:
                drop_exasol_schema(conn, target_schema)
                exasol_schema = {"schema": target_schema, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": target_schema, "status": "failed", "error": str(exc)}

            try:
                drop_exasol_connection(conn, connection_name)
                exasol_connection = {"name": connection_name, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": connection_name, "status": "failed", "error": str(exc)}

        source_container = cleanup_mysql_like_container(source)
        cleanup = {
            "status": "completed",
            "source_container": source_container,
            "exasol_schema": exasol_schema,
            "exasol_connection": exasol_connection,
        }
        if source_container.get("status") == "failed" or exasol_schema.get("status") == "failed" or exasol_connection.get("status") == "failed":
            cleanup["status"] = "completed_with_errors"

        if run_result is not None:
            run_result["cleanup"] = cleanup

        if cleanup["status"] != "completed":
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def live_sqlserver_case(case_name: str) -> dict[str, Any]:
    public_ip = ensure_public_ip()
    sg_result = authorize_security_group(public_ip, SQLSERVER_PORT)
    source_container: dict[str, Any] = {"name": SQLSERVER_CONTAINER, "status": "not_started"}
    exasol_schema: dict[str, Any] = {"schema": SQLSERVER_EXASOL_SCHEMA, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": SQLSERVER_CONNECTION_NAME, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_sqlserver_container()
        jdbc_url = sqlserver_jdbc_url()
        seed_info = seed_sqlserver_case(case_name)
        conn = connect_exasol()
        deploy_sqlserver_scripts(conn)
        drop_exasol_schema(conn, SQLSERVER_EXASOL_SCHEMA)
        create_mysql_like_exasol_connection(conn, SQLSERVER_CONNECTION_NAME, jdbc_url, SQLSERVER_USER, SQLSERVER_PASSWORD)
        run_result = run_sqlserver_wrapper_case(conn, case_name, jdbc_url)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        run_result["security_group_rule"] = sg_result
        return run_result
    finally:
        if conn is not None:
            try:
                drop_exasol_schema(conn, SQLSERVER_EXASOL_SCHEMA)
                exasol_schema = {"schema": SQLSERVER_EXASOL_SCHEMA, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": SQLSERVER_EXASOL_SCHEMA, "status": "failed", "error": str(exc)}

            try:
                drop_exasol_connection(conn, SQLSERVER_CONNECTION_NAME)
                exasol_connection = {"name": SQLSERVER_CONNECTION_NAME, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": SQLSERVER_CONNECTION_NAME, "status": "failed", "error": str(exc)}

        source_container = cleanup_sqlserver_container()
        sg_cleanup = revoke_security_group(public_ip, SQLSERVER_PORT)
        cleanup = {
            "status": "completed",
            "public_ip": public_ip,
            "security_group_rule": sg_cleanup,
            "source_container": source_container,
            "exasol_schema": exasol_schema,
            "exasol_connection": exasol_connection,
        }
        if source_container.get("status") == "failed" or sg_cleanup.get("status") == "failed" or exasol_schema.get("status") == "failed" or exasol_connection.get("status") == "failed":
            cleanup["status"] = "completed_with_errors"

        if run_result is not None:
            run_result["cleanup"] = cleanup

        if cleanup["status"] != "completed":
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def live_oracle_case(case_name: str) -> dict[str, Any]:
    public_ip = ensure_public_ip()
    sg_result = authorize_security_group(public_ip, ORACLE_PORT)
    source_container: dict[str, Any] = {"name": ORACLE_CONTAINER, "status": "not_started"}
    exasol_schema: dict[str, Any] = {"schema": ORACLE_SCHEMA, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": ORACLE_CONNECTION_NAME, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_oracle_container()
        jdbc_url = oracle_jdbc_url()
        seed_info = seed_oracle_case(case_name)
        conn = connect_exasol()
        deploy_oracle_scripts(conn)
        drop_exasol_schema(conn, ORACLE_SCHEMA)
        create_mysql_like_exasol_connection(conn, ORACLE_CONNECTION_NAME, jdbc_url, ORACLE_SCHEMA, ORACLE_PASSWORD)
        run_result = run_oracle_wrapper_case(conn, case_name, jdbc_url)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        run_result["security_group_rule"] = sg_result
        return run_result
    finally:
        if conn is not None:
            try:
                drop_exasol_schema(conn, ORACLE_SCHEMA)
                exasol_schema = {"schema": ORACLE_SCHEMA, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": ORACLE_SCHEMA, "status": "failed", "error": str(exc)}

            try:
                drop_exasol_connection(conn, ORACLE_CONNECTION_NAME)
                exasol_connection = {"name": ORACLE_CONNECTION_NAME, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": ORACLE_CONNECTION_NAME, "status": "failed", "error": str(exc)}

        source_container = cleanup_oracle_container()
        sg_cleanup = revoke_security_group(public_ip, ORACLE_PORT)
        cleanup = {
            "status": "completed",
            "public_ip": public_ip,
            "security_group_rule": sg_cleanup,
            "source_container": source_container,
            "exasol_schema": exasol_schema,
            "exasol_connection": exasol_connection,
        }
        if source_container.get("status") == "failed" or sg_cleanup.get("status") == "failed" or exasol_schema.get("status") == "failed" or exasol_connection.get("status") == "failed":
            cleanup["status"] = "completed_with_errors"

        if run_result is not None:
            run_result["cleanup"] = cleanup

        if cleanup["status"] != "completed":
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def live_db2_case(case_name: str) -> dict[str, Any]:
    source_container: dict[str, Any] = {"name": DB2_CONTAINER, "status": "not_started"}
    exasol_schema: dict[str, Any] = {"schema": DB2_EXASOL_SCHEMA, "status": "not_cleaned"}
    exasol_connection: dict[str, Any] = {"name": DB2_CONNECTION_NAME, "status": "not_cleaned"}
    conn = None
    run_result: dict[str, Any] | None = None

    try:
        source_container = ensure_db2_container()
        jdbc_url = db2_jdbc_url()
        seed_info = seed_db2_case(case_name)
        conn = connect_exasol()
        deploy_db2_scripts(conn)
        drop_exasol_schema(conn, DB2_EXASOL_SCHEMA)
        create_mysql_like_exasol_connection(conn, DB2_CONNECTION_NAME, jdbc_url, DB2_USER, DB2_PASSWORD)
        run_result = run_db2_wrapper_case(conn, case_name, jdbc_url)
        run_result["seed"] = seed_info
        run_result["source_container"] = source_container
        return run_result
    finally:
        primary_exc = sys.exc_info()[1]
        if conn is not None:
            try:
                run_exasol_cleanup_with_retry(conn, lambda cleanup_conn: drop_exasol_schema(cleanup_conn, DB2_EXASOL_SCHEMA))
                exasol_schema = {"schema": DB2_EXASOL_SCHEMA, "status": "dropped"}
            except Exception as exc:
                exasol_schema = {"schema": DB2_EXASOL_SCHEMA, "status": "failed", "error": str(exc)}

            try:
                run_exasol_cleanup_with_retry(conn, lambda cleanup_conn: drop_exasol_connection(cleanup_conn, DB2_CONNECTION_NAME))
                exasol_connection = {"name": DB2_CONNECTION_NAME, "status": "dropped"}
            except Exception as exc:
                exasol_connection = {"name": DB2_CONNECTION_NAME, "status": "failed", "error": str(exc)}

        source_container = cleanup_db2_container()
        cleanup = {
            "status": "completed",
            "source_container": source_container,
            "exasol_schema": exasol_schema,
            "exasol_connection": exasol_connection,
        }
        if source_container.get("status") == "failed" or exasol_schema.get("status") == "failed" or exasol_connection.get("status") == "failed":
            cleanup["status"] = "completed_with_errors"

        if run_result is not None:
            run_result["cleanup"] = cleanup

        if cleanup["status"] != "completed" and primary_exc is None:
            raise SmokeError(f"Cleanup completed with errors: {compact_json(cleanup)}")


def self_test_canonical_cases() -> dict[str, Any]:
    names = [case["name"] for case in CANONICAL_CASES]
    required = {
        "numeric",
        "text",
        "date_time",
        "boolean",
        "binary",
        "null",
        "mixed_case_identifier",
        "reserved_ish_identifier",
    }
    assert_true(required.issubset(set(names)), f"Missing canonical cases: {sorted(required - set(names))}")
    return {"self_test": "canonical-cases", "status": "pass", "cases": CANONICAL_CASES}


def self_test_result_shape() -> dict[str, Any]:
    sample = {
        "source": "vertica",
        "case": "core",
        "expected_failure": False,
        "connection": {"name": EXASOL_CONNECTION_NAME, "jdbc_url": VERTICA_JDBC_URL},
        "preview": {
            "row_count": 2,
            "rows": [
                {"sql_text": "create schema \"WRAP_VERTICA_DATATYPES\";", "success": "PREVIEW", "error_message": None},
                {"sql_text": "create or replace table ...", "success": "PREVIEW", "error_message": None},
            ],
            "ddl": ['create schema "WRAP_VERTICA_DATATYPES";', "create or replace table ..."],
            "first_statement": 'create schema "WRAP_VERTICA_DATATYPES";',
        },
        "execute": {
            "row_count": 3,
            "rows": [
                {"sql_text": "-- The following statements were executed successfully.", "success": "SKIPPED", "error_message": None},
                {"sql_text": "create schema \"WRAP_VERTICA_DATATYPES\";", "success": "TRUE", "error_message": None},
                {"sql_text": "import into ...", "success": "TRUE", "error_message": None},
            ],
            "failures": [],
            "failed": False,
            "status": "loaded",
        },
        "loaded_rows": 2,
        "cleanup": {
            "status": "completed",
            "public_ip": "203.0.113.10",
            "security_group_rule": {"status": "revoked"},
            "source_container": {"status": "removed"},
            "source_schema": {"status": "dropped"},
            "exasol_schema": {"status": "dropped"},
            "exasol_connection": {"status": "dropped"},
        },
    }
    assert_true(sample["preview"]["row_count"] == len(sample["preview"]["rows"]), "Preview row count mismatch")
    assert_true(sample["execute"]["status"] == "loaded", "Expected loaded execute status")
    assert_true(sample["loaded_rows"] == 2, "Expected loaded row count")
    return {"self_test": "result-shape", "status": "pass", "result": sample}


def self_test_failure_preserves_error() -> dict[str, Any]:
    sample = {
        "source": "vertica",
        "case": "timestamp",
        "expected_failure": True,
        "preview": {
            "ddl": ['create or replace table "WRAP_VERTICA_DATATYPES"."TIMESTAMP_CASE" ("ID" DECIMAL(11,0), "CREATED_AT" VARCHAR(14));']
        },
        "execute": {
            "row_count": 2,
            "rows": [
                {"sql_text": "import into ...", "success": "FALSE", "error_message": "String length exceeded for column CREATED_AT"},
            ],
            "failures": [
                {"sql_text": "import into ...", "success": "FALSE", "error_message": "String length exceeded for column CREATED_AT"},
            ],
            "failed": True,
            "status": "expected_failure",
        },
        "cleanup": {
            "status": "completed",
            "security_group_rule": {"status": "revoked"},
            "source_container": {"status": "removed"},
            "source_schema": {"status": "dropped"},
            "exasol_schema": {"status": "dropped"},
            "exasol_connection": {"status": "dropped"},
        },
    }
    error_blob = " ".join(row["error_message"] for row in sample["execute"]["failures"]).lower()
    assert_true("string length" in error_blob, "Expected the adapter error to be preserved")
    assert_true("varchar(14)" in sample["preview"]["ddl"][0].lower(), "Expected generated DDL to be preserved")
    return {"self_test": "failure-preserves-error", "status": "pass", "result": sample}


def self_test_cleanup_record() -> dict[str, Any]:
    cleanup = build_cleanup_result(
        source_ip="203.0.113.10",
        sg_result={"status": "revoked", "cidr": "203.0.113.10/32"},
        source_container={"status": "removed"},
        source_schema={"status": "dropped"},
        exasol_schema={"status": "dropped"},
        exasol_connection={"status": "dropped"},
    )
    assert_true(cleanup["status"] == "completed", "Expected cleanup to be recorded as completed")
    assert_true(cleanup["security_group_rule"]["status"] == "revoked", "Expected SG cleanup status")
    return {"self_test": "cleanup-record", "status": "pass", "cleanup": cleanup}


def self_test_script_extraction() -> dict[str, Any]:
    db2_script = extract_create_script(REPO / "db2_to_exasol.sql", "DB2_TO_EXASOL")
    assert_true("DB2_TO_EXASOL" in db2_script, "Expected DB2 script extraction")
    assert_true("execute script" not in db2_script.lower(), "Expected only CREATE SCRIPT body")
    return {"self_test": "script-extraction", "status": "pass", "script": "DB2_TO_EXASOL"}


def run_self_test(name: str) -> dict[str, Any]:
    if name == "canonical-cases":
        return self_test_canonical_cases()
    if name == "result-shape":
        return self_test_result_shape()
    if name == "failure-preserves-error":
        return self_test_failure_preserves_error()
    if name == "cleanup-record":
        return self_test_cleanup_record()
    if name == "script-extraction":
        return self_test_script_extraction()
    if name == "all":
        return {
            "self_test": "all",
            "status": "pass",
            "results": [
                self_test_canonical_cases(),
                self_test_result_shape(),
                self_test_failure_preserves_error(),
                self_test_cleanup_record(),
                self_test_script_extraction(),
            ],
        }
    raise SmokeError(f"Unknown self-test: {name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--self-test",
        choices=["canonical-cases", "result-shape", "failure-preserves-error", "cleanup-record", "script-extraction", "all"],
        help="Run a self-test without contacting live infrastructure.",
    )
    group.add_argument("--source", choices=["vertica", "postgres", "mysql", "mariadb", "sqlserver", "db2", "oracle"], help="Live source to smoke.")
    parser.add_argument(
        "--case",
        choices=[
            "timestamp",
            "core",
            "boolean",
            "binary",
            "null",
            "mixed_case_identifier",
            "reserved_ish_identifier",
            "minimal",
        ],
        help="Live case to run for the selected source.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        if args.self_test:
            result = run_self_test(args.self_test)
        else:
            if not args.case:
                raise SmokeError("--case is required with --source")
            if args.source == "vertica":
                if args.case not in VERTICA_CASES:
                    raise SmokeError(f"Vertica supports --case {', '.join(sorted(VERTICA_CASES))}")
                result = live_vertica_case(args.case)
            elif args.source == "postgres":
                if args.case not in POSTGRES_CASES:
                    raise SmokeError(f"Postgres supports --case {', '.join(sorted(POSTGRES_CASES))}")
                result = live_postgres_case(args.case)
            elif args.source in ("mysql", "mariadb"):
                cases = MYSQL_CASES if args.source == "mysql" else MARIADB_CASES
                if args.case not in cases:
                    raise SmokeError(f"{args.source} supports --case {', '.join(sorted(cases))}")
                result = live_mysql_like_case(args.source, args.case)
            elif args.source == "sqlserver":
                if args.case not in SQLSERVER_CASES:
                    raise SmokeError(f"sqlserver supports --case {', '.join(sorted(SQLSERVER_CASES))}")
                result = live_sqlserver_case(args.case)
            elif args.source == "oracle":
                if args.case not in ORACLE_CASES:
                    raise SmokeError(f"oracle supports --case {', '.join(sorted(ORACLE_CASES))}")
                result = live_oracle_case(args.case)
            elif args.source == "db2":
                if args.case not in DB2_CASES:
                    raise SmokeError(f"db2 supports --case {', '.join(sorted(DB2_CASES))}")
                result = live_db2_case(args.case)
            else:
                raise SmokeError(f"Unsupported source: {args.source}")

        print(compact_json(result))
        return 0
    except SmokeError as exc:
        print(compact_json({"status": "error", "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
