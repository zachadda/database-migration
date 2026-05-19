create schema if not exists database_migration;
/*
    This script will generate create schema, create table and create import statements
    to load all needed data from a DuckDB database. Automatic datatype conversion is
    applied whenever needed. Feel free to adjust it.

    Notes on DuckDB types:
      - HUGEINT / UHUGEINT (int128 / uint128) exceed Exasol DECIMAL(36,0) range
        and are stored as VARCHAR(40).
      - Complex types (LIST, STRUCT, MAP, UNION, ARRAY) are JSON-serialized via
        to_json(col) on the source side and stored as VARCHAR(2000000).
      - TIMESTAMP WITH TIME ZONE, INTERVAL, UUID, BIT, BLOB go to VARCHAR with
        appropriate length on the source side cast.
      - The DuckDB JDBC driver returns parameterized type names in
        information_schema.columns.data_type (e.g. 'DECIMAL(18,3)',
        'TIMESTAMP WITH TIME ZONE', 'VARCHAR'). Base type detection uses
        regexp_replace to strip parameters before the case branches.
*/
--/
create or replace script database_migration.DUCKDB_TO_EXASOL(
CONNECTION_NAME              -- name of the database connection inside exasol -> e.g. duckdb_db
,IDENTIFIER_CASE_INSENSITIVE -- true if identifiers should be stored case-insensitiv (will be stored upper_case)
,SCHEMA_FILTER               -- filter for the schemas to generate and load (except information_schema) -> '%' to load all
,TABLE_FILTER                -- filter for the tables to generate and load -> '%' to load all
) RETURNS TABLE
AS

exa_upper_begin=''
exa_upper_end=''

if IDENTIFIER_CASE_INSENSITIVE == true then
    exa_upper_begin='upper('
    exa_upper_end=')'
end

suc, res = pquery([[

with vv_duckdb_columns as (
    select ]]..exa_upper_begin..[[table_catalog]]..exa_upper_end..[[ as "exa_table_catalog",
           ]]..exa_upper_begin..[[table_schema]]..exa_upper_end..[[ as "exa_table_schema",
           ]]..exa_upper_begin..[[table_name]]..exa_upper_end..[[ as "exa_table_name",
           ]]..exa_upper_begin..[[column_name]]..exa_upper_end..[[ as "exa_column_name",
           regexp_replace(data_type, '\(.*$', '') as base_type,
           data_type as raw_type,
           column_name,
           table_schema,
           table_name,
           ordinal_position,
           not_null_constraint,
           numeric_precision,
           numeric_scale,
           character_maximum_length
      from ( import from jdbc at ]]..CONNECTION_NAME..[[ statement
        '-- DuckDB normalizes unquoted identifiers to lowercase; quote aliases
         -- with uppercase so that the JDBC result columns arrive uppercased
         -- (Exasol IMPORT preserves case as-delivered).
         select table_catalog              as "TABLE_CATALOG",
                table_schema               as "TABLE_SCHEMA",
                table_name                 as "TABLE_NAME",
                column_name                as "COLUMN_NAME",
                ordinal_position           as "ORDINAL_POSITION",
                case when is_nullable = ''NO'' then ''NOT NULL'' else ''NULL'' end as "NOT_NULL_CONSTRAINT",
                upper(data_type)           as "DATA_TYPE",
                numeric_precision          as "NUMERIC_PRECISION",
                numeric_scale              as "NUMERIC_SCALE",
                character_maximum_length   as "CHARACTER_MAXIMUM_LENGTH"
           from information_schema.columns
          where table_schema not in (''information_schema'',''pg_catalog'',''system'')
            AND table_schema like '']]..SCHEMA_FILTER..[[''
            AND table_name like '']]..TABLE_FILTER..[[''
        '
    ) as duckdb
)

,vv_create_schemas as (
    SELECT 'create schema if not exists "' || "exa_table_schema" || '";' as sql_text
      from vv_duckdb_columns
     group by "exa_table_catalog","exa_table_schema"
     order by "exa_table_catalog","exa_table_schema"
)

,vv_create_tables as (
    select 'create or replace table "' || "exa_table_schema" || '"."' || "exa_table_name" || '" (' || group_concat(
    case
    -- ### signed integer types ###
    when base_type = 'TINYINT'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(4,0) '   || not_null_constraint
    when base_type = 'SMALLINT'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '   || not_null_constraint
    when base_type = 'INTEGER'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) '  || not_null_constraint
    when base_type = 'INT'       then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) '  || not_null_constraint
    when base_type = 'BIGINT'    then '"' || "exa_column_name" || '" ' || 'DECIMAL(19,0) '  || not_null_constraint
    when base_type = 'HUGEINT'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '    || not_null_constraint

    -- ### unsigned integer types ###
    when base_type = 'UTINYINT'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(3,0) '   || not_null_constraint
    when base_type = 'USMALLINT' then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '   || not_null_constraint
    when base_type = 'UINTEGER'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(10,0) '  || not_null_constraint
    when base_type = 'UBIGINT'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(20,0) '  || not_null_constraint
    when base_type = 'UHUGEINT'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '    || not_null_constraint

    -- ### floating point + decimal ###
    when base_type = 'FLOAT'     then '"' || "exa_column_name" || '" ' || 'FLOAT '          || not_null_constraint
    when base_type = 'REAL'      then '"' || "exa_column_name" || '" ' || 'FLOAT '          || not_null_constraint
    when base_type = 'DOUBLE'    then '"' || "exa_column_name" || '" ' || 'DOUBLE '         || not_null_constraint
    when base_type = 'DECIMAL'   then '"' || "exa_column_name" || '" ' || 'decimal(' ||
            case when numeric_precision > 36 then 36 else numeric_precision end || ',' ||
            case when numeric_scale > numeric_precision then numeric_precision
                 when numeric_scale < 0 then 0
                 else numeric_scale end || ') ' || not_null_constraint
    when base_type = 'NUMERIC'   then '"' || "exa_column_name" || '" ' || 'decimal(' ||
            case when numeric_precision > 36 then 36 else numeric_precision end || ',' ||
            case when numeric_scale > numeric_precision then numeric_precision
                 when numeric_scale < 0 then 0
                 else numeric_scale end || ') ' || not_null_constraint

    -- ### boolean ###
    when base_type = 'BOOLEAN'   then '"' || "exa_column_name" || '" ' || 'BOOLEAN '        || not_null_constraint
    when base_type = 'BOOL'      then '"' || "exa_column_name" || '" ' || 'BOOLEAN '        || not_null_constraint
    when base_type = 'BIT'       then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### date and time types ###
    when base_type = 'DATE'      then '"' || "exa_column_name" || '" ' || 'DATE '           || not_null_constraint
    when base_type = 'TIME'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(15) '    || not_null_constraint
    when base_type = 'TIMESTAMP' then '"' || "exa_column_name" || '" ' || 'TIMESTAMP '      || not_null_constraint
    when base_type = 'TIMESTAMP WITH TIME ZONE'
                                 then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '    || not_null_constraint
    when base_type = 'TIMESTAMPTZ'
                                 then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '    || not_null_constraint
    when base_type = 'INTERVAL'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) '    || not_null_constraint

    -- ### string + binary types ###
    when base_type = 'VARCHAR'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'STRING'    then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'TEXT'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'CHAR'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'BLOB'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'BYTEA'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'UUID'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(36) '      || not_null_constraint

    -- ### complex types (serialized to JSON on source side) ###
    when base_type = 'LIST'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'STRUCT'    then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'MAP'       then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'UNION'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'ARRAY'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'JSON'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    end
    order by ordinal_position) || ');'

    -- ### unknown types ###
    || group_concat (
        case
        when base_type not in (
            'TINYINT','SMALLINT','INTEGER','INT','BIGINT','HUGEINT',
            'UTINYINT','USMALLINT','UINTEGER','UBIGINT','UHUGEINT',
            'FLOAT','REAL','DOUBLE','DECIMAL','NUMERIC',
            'BOOLEAN','BOOL','BIT',
            'DATE','TIME','TIMESTAMP','TIMESTAMP WITH TIME ZONE','TIMESTAMPTZ','INTERVAL',
            'VARCHAR','STRING','TEXT','CHAR','BLOB','BYTEA','UUID',
            'LIST','STRUCT','MAP','UNION','ARRAY','JSON'
        )
        then '--UNKNOWN_DATATYPE: "'|| "exa_column_name" || '" ' || base_type
        end
    ) || ' ' as sql_text
    from vv_duckdb_columns
    group by "exa_table_catalog","exa_table_schema","exa_table_name"
    order by "exa_table_catalog","exa_table_schema","exa_table_name"
)

,vv_imports as (
    select 'import into "' || "exa_table_schema" || '"."' || "exa_table_name" || '" from jdbc at ]]..CONNECTION_NAME..[[ statement ''select '
           || group_concat(
                case
                -- ### pass-through types (numeric, boolean, date, normal strings) ###
                when base_type in ('TINYINT','SMALLINT','INTEGER','INT','BIGINT','UTINYINT','USMALLINT','UINTEGER','UBIGINT','FLOAT','REAL','DOUBLE','DECIMAL','NUMERIC','BOOLEAN','BOOL','DATE','TIMESTAMP','VARCHAR','STRING','TEXT','CHAR')
                    then '"' || column_name || '"'

                -- ### cast to VARCHAR on source side ###
                when base_type = 'HUGEINT'   then 'cast("' || column_name || '" as VARCHAR(40))'
                when base_type = 'UHUGEINT'  then 'cast("' || column_name || '" as VARCHAR(40))'
                when base_type = 'BIT'       then 'cast("' || column_name || '" as VARCHAR)'
                when base_type = 'TIME'      then 'cast("' || column_name || '" as VARCHAR(15))'
                when base_type = 'TIMESTAMP WITH TIME ZONE'
                                             then 'cast("' || column_name || '" as VARCHAR(40))'
                when base_type = 'TIMESTAMPTZ'
                                             then 'cast("' || column_name || '" as VARCHAR(40))'
                when base_type = 'INTERVAL'  then 'cast("' || column_name || '" as VARCHAR(50))'
                when base_type = 'UUID'      then 'cast("' || column_name || '" as VARCHAR(36))'
                when base_type = 'BLOB'      then 'cast("' || column_name || '" as VARCHAR)'
                when base_type = 'BYTEA'     then 'cast("' || column_name || '" as VARCHAR)'

                -- ### complex types: JSON-serialize on source side ###
                when base_type = 'LIST'      then 'to_json("' || column_name || '")'
                when base_type = 'STRUCT'    then 'to_json("' || column_name || '")'
                when base_type = 'MAP'       then 'to_json("' || column_name || '")'
                when base_type = 'UNION'     then 'to_json("' || column_name || '")'
                when base_type = 'ARRAY'     then 'to_json("' || column_name || '")'
                when base_type = 'JSON'      then 'cast("' || column_name || '" as VARCHAR)'
                end
                order by ordinal_position)
           || ' from "' || table_schema || '"."' || table_name || '"'';' as sql_text
    from vv_duckdb_columns
    group by "exa_table_catalog","exa_table_schema","exa_table_name", table_schema, table_name
    order by "exa_table_catalog","exa_table_schema","exa_table_name", table_schema, table_name
)

select SQL_TEXT from (
    select 1 as ord, cast('-- ### SCHEMAS ###' as varchar(2000000)) SQL_TEXT
    union all
    select 2, a.* from vv_create_schemas a
    union all
    select 3, cast('-- ### TABLES ###' as varchar(2000000)) SQL_TEXT
    union all
    select 4, b.* from vv_create_tables b
    WHERE b.SQL_TEXT NOT LIKE '%();%'
    union all
    select 5, cast('-- ### IMPORTS ###' as varchar(2000000)) SQL_TEXT
    union all
    select 6, c.* from vv_imports c
    WHERE c.SQL_TEXT NOT LIKE '%select  from%'
) order by ord
]],{})

if not suc then
    error('"'..res.error_message..'" Caught while executing: "'..res.statement_text..'"')
end

return(res)

/


create or replace connection duckdb_conn
to 'jdbc:duckdb:/path/to/your.duckdb'
user 'admin'
identified by '';

execute script database_migration.DUCKDB_TO_EXASOL('duckdb_conn'
,TRUE
,'%'
,'%'
);
