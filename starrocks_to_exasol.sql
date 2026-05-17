create schema if not exists database_migration;
/*
    This script will generate create schema, create table and create import statements
    to load all needed data from a StarRocks database. Automatic datatype conversion is
    applied whenever needed. Feel free to adjust it.

    StarRocks speaks the MySQL wire protocol, so the MARIADB JDBC driver is
    reused (PREFIX=jdbc:mariadb:, port 9030 on the FE node). Its
    information_schema is MySQL-compatible with the addition of
    StarRocks-specific types: LARGEINT, BITMAP, HLL, PERCENTILE, JSON,
    ARRAY, MAP, STRUCT. Those that have no analytic equivalent in Exasol are
    serialized to VARCHAR on the source side:

      - LARGEINT (int128) → VARCHAR(40); exceeds Exasol DECIMAL(36,0).
      - BITMAP/HLL/PERCENTILE sketch types → VARCHAR(2000000) via
        bitmap_to_string()/hll_serialize()/percentile_approx() (lossy; no
        analytic equivalent in Exasol).
      - ARRAY/MAP/STRUCT/JSON → cast(col AS JSON)/CAST(col AS VARCHAR)
        depending on type. The IMPORT SELECT serializes them on the source
        side and Exasol stores the JSON text.
*/
--/
create or replace script database_migration.STARROCKS_TO_EXASOL(
CONNECTION_NAME              -- name of the database connection inside exasol -> e.g. starrocks_db
,IDENTIFIER_CASE_INSENSITIVE -- true if identifiers should be stored case-insensitiv (will be stored upper_case)
,SCHEMA_FILTER               -- filter for the schemas to generate and load (except information_schema/_statistics_/sys) -> '%' to load all
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

with vv_starrocks_columns as (
    select ]]..exa_upper_begin..[[table_catalog]]..exa_upper_end..[[ as "exa_table_catalog", ]]..exa_upper_begin..[[table_schema]]..exa_upper_end..[[ as "exa_table_schema", ]]..exa_upper_begin..[[table_name]]..exa_upper_end..[[ as "exa_table_name", ]]..exa_upper_begin..[[column_name]]..exa_upper_end..[[ as "exa_column_name", starrocks.* from
    ( import from jdbc at ]]..CONNECTION_NAME..[[ statement
        '-- StarRocks MySQL-protocol JDBC returns information_schema columns
         -- in lower case; Exasol IMPORT preserves the case it receives and
         -- unquoted outer refs would normalize to upper case, so force
         -- upper here with quoted aliases.
         select table_catalog            as `TABLE_CATALOG`,
                table_schema             as `TABLE_SCHEMA`,
                table_name               as `TABLE_NAME`,
                column_name              as `COLUMN_NAME`,
                ordinal_position         as `ORDINAL_POSITION`,
                column_default           as `COLUMN_DEFAULT`,
                case when is_nullable = ''NO'' then ''NOT NULL'' else ''NULL'' end as `NOT_NULL_CONSTRAINT`,
                lower(data_type)         as `DATA_TYPE`,
                column_type              as `COLUMN_TYPE`,
                character_maximum_length as `CHARACTER_MAXIMUM_LENGTH`,
                numeric_precision        as `NUMERIC_PRECISION`,
                numeric_scale            as `NUMERIC_SCALE`
           from information_schema.columns
          -- StarRocks: do NOT join information_schema.tables here. In some
          -- versions the table_catalog column reports different values
          -- across the two views (`default_catalog` in tables vs NULL/empty
          -- in columns), which makes the USING(...) join drop user rows.
          -- Excluding the three known system schemas is sufficient here.
          where table_schema not in (''information_schema'', ''_statistics_'', ''sys'')
            AND table_schema like '']]..SCHEMA_FILTER..[[''
            AND table_name like '']]..TABLE_FILTER..[[''
        '
    ) as starrocks
)

,vv_create_schemas as (
    SELECT 'create schema if not exists "' || "exa_table_schema" || '";' as sql_text
      from vv_starrocks_columns
     group by "exa_table_catalog","exa_table_schema"
     order by "exa_table_catalog","exa_table_schema"
)

,vv_create_tables as (
    select 'create or replace table "' || "exa_table_schema" || '"."' || "exa_table_name" || '" (' || group_concat(
    case
    -- ### signed integer types ###
    when upper(data_type) = 'TINYINT'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(4,0) '  || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'SMALLINT' then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '  || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'INT'      then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) ' || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'INTEGER'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) ' || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'BIGINT'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(19,0) ' || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'LARGEINT' then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '   || case when column_default is not NULL then 'DEFAULT ''' || column_default || ''' ' end || NOT_NULL_CONSTRAINT

    -- ### floating point + decimal ###
    when upper(data_type) = 'FLOAT'   then '"' || "exa_column_name" || '" ' || 'FLOAT '  || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'DOUBLE'  then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'DECIMAL' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
            case when numeric_precision > 36 then 36 else numeric_precision end || ',' ||
            case when numeric_scale > numeric_precision then numeric_precision
                 when numeric_scale < 0 then 0
                 else numeric_scale end || ') ' || case when column_default is not NULL then 'DEFAULT ' || column_default || ' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'DECIMAL64' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
            case when numeric_precision > 36 then 36 else numeric_precision end || ',' ||
            case when numeric_scale > numeric_precision then numeric_precision
                 when numeric_scale < 0 then 0
                 else numeric_scale end || ') ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'DECIMAL128' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
            case when numeric_precision > 36 then 36 else numeric_precision end || ',' ||
            case when numeric_scale > numeric_precision then numeric_precision
                 when numeric_scale < 0 then 0
                 else numeric_scale end || ') ' || NOT_NULL_CONSTRAINT

    -- ### boolean ###
    when upper(data_type) = 'BOOLEAN' then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'BOOL'    then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || NOT_NULL_CONSTRAINT

    -- ### date and time types ###
    when upper(data_type) = 'DATE'     then '"' || "exa_column_name" || '" ' || 'DATE '      || case when column_default is not NULL then 'DEFAULT ''' || column_default || ''' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'DATETIME' then '"' || "exa_column_name" || '" ' || 'TIMESTAMP ' || case when column_default is not NULL then 'DEFAULT ''' || column_default || ''' ' end || NOT_NULL_CONSTRAINT

    -- ### string types ###
    when upper(data_type) = 'CHAR'        then '"' || "exa_column_name" || '" ' || upper(column_type) || ' ' || case when column_default is not NULL then 'DEFAULT ''' || column_default || ''' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'VARCHAR'     then '"' || "exa_column_name" || '" ' || upper(column_type) || ' ' || case when column_default is not NULL then 'DEFAULT ''' || column_default || ''' ' end || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'STRING'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'TEXT'        then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'BINARY'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'VARBINARY'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT

    -- ### StarRocks-specific analytical / complex types (serialized to VARCHAR on source side) ###
    when upper(data_type) = 'JSON'        then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'ARRAY'       then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'MAP'         then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'STRUCT'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'BITMAP'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'HLL'         then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT
    when upper(data_type) = 'PERCENTILE'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || NOT_NULL_CONSTRAINT

    end
    order by ordinal_position) || ');'

    -- ### unknown types ###
    || group_concat (
        case
        when upper(data_type) not in (
            'TINYINT','SMALLINT','INT','INTEGER','BIGINT','LARGEINT',
            'FLOAT','DOUBLE','DECIMAL','DECIMAL64','DECIMAL128',
            'BOOLEAN','BOOL',
            'DATE','DATETIME',
            'CHAR','VARCHAR','STRING','TEXT','BINARY','VARBINARY',
            'JSON','ARRAY','MAP','STRUCT','BITMAP','HLL','PERCENTILE'
        )
        then '--UNKNOWN_DATATYPE: "' || "exa_column_name" || '" ' || upper(data_type)
        end
    ) || ' ' as sql_text
    from vv_starrocks_columns
    group by "exa_table_catalog","exa_table_schema","exa_table_name"
    order by "exa_table_catalog","exa_table_schema","exa_table_name"
)

,vv_imports as (
    select 'import into "' || "exa_table_schema" || '"."' || "exa_table_name" || '" from jdbc at ]]..CONNECTION_NAME..[[ statement ''select '
           || group_concat(
                case
                -- ### pass-through (numeric, boolean, date, normal strings) ###
                when upper(data_type) in ('TINYINT','SMALLINT','INT','INTEGER','BIGINT','FLOAT','DOUBLE','DECIMAL','DECIMAL64','DECIMAL128','BOOLEAN','BOOL','DATE','DATETIME','CHAR','VARCHAR','STRING','TEXT')
                    then '`' || column_name || '`'

                -- ### LARGEINT exceeds 64-bit, send as string ###
                when upper(data_type) = 'LARGEINT'    then 'cast(`' || column_name || '` as VARCHAR(40))'

                -- ### binary blobs as hex strings ###
                when upper(data_type) = 'BINARY'      then 'hex(`' || column_name || '`)'
                when upper(data_type) = 'VARBINARY'   then 'hex(`' || column_name || '`)'

                -- ### complex types: serialize to JSON string on source side ###
                when upper(data_type) = 'JSON'        then 'cast(`' || column_name || '` as VARCHAR)'
                when upper(data_type) = 'ARRAY'       then 'cast(`' || column_name || '` as JSON)'
                when upper(data_type) = 'MAP'         then 'cast(`' || column_name || '` as JSON)'
                when upper(data_type) = 'STRUCT'      then 'cast(`' || column_name || '` as JSON)'

                -- ### sketch types: lossy string serialization (no Exasol analytic equivalent) ###
                when upper(data_type) = 'BITMAP'      then 'bitmap_to_string(`' || column_name || '`)'
                when upper(data_type) = 'HLL'         then 'hll_to_string(`' || column_name || '`)'
                when upper(data_type) = 'PERCENTILE'  then 'cast(`' || column_name || '` as VARCHAR)'
                end
                order by ordinal_position)
           || ' from `' || table_schema || '`.`' || table_name || '`'';' as sql_text
    from vv_starrocks_columns
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


create or replace connection starrocks_conn
to 'jdbc:mariadb://192.168.137.5:9030'
user 'root'
identified by '';

execute script database_migration.STARROCKS_TO_EXASOL('starrocks_conn'
,TRUE
,'%'
,'%'
);
