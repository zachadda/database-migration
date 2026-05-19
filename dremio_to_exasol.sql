create schema if not exists database_migration;
/*
    This script generates create-schema / create-table / IMPORT statements
    to migrate all selected datasets from a Dremio source into Exasol.

    Notes on Dremio and Arrow-derived types:

      - Dremio is a lakehouse query gateway. Datasets are views over
        underlying connectors (Iceberg / Delta / Parquet / RDBMS via
        sources). Migration throughput depends on the connector backing
        each dataset and on reflection state, not on Dremio's engine.

      - Dremio's INFORMATION_SCHEMA.COLUMNS returns ANSI-style uppercase
        column names already, but the result column delivered through
        JDBC may be normalised by the driver. The IMPORT SELECT aliases
        each pulled column with a quoted upper-case identifier to keep
        the outer-SQL refs unambiguous.

      - Dremio's INFORMATION_SCHEMA.COLUMNS does NOT expose numeric
        precision / scale or character length as separate columns
        reliably across versions. Parse them from the parameterised
        DATA_TYPE string (e.g. 'DECIMAL(18, 3)', 'VARCHAR(50)') via
        REGEXP_SUBSTR on the Exasol side.

      - Dremio uses 3-tier naming: <source/space> . <folder/schema> . <dataset>.
        The wrapper passes the source/space as DB_FILTER (single value,
        wildcards not supported), SCHEMA_FILTER as the folder, and
        TABLE_FILTER as the dataset name.

      - Complex Arrow types (LIST, STRUCT, MAP) and BINARY are converted
        to JSON / hex strings on the Dremio side via CONVERT_TO so the
        JDBC layer delivers plain VARCHAR.

      - INTERVAL types map to VARCHAR(50); Dremio returns ISO-8601 style
        strings.
*/
--/
create or replace script database_migration.DREMIO_TO_EXASOL(
CONNECTION_NAME              -- name of the database connection inside exasol -> e.g. dremio_db
,IDENTIFIER_CASE_INSENSITIVE -- true if identifiers should be stored case-insensitiv (will be stored upper_case)
,DB_FILTER                   -- Dremio source/space name (single value, wildcards not supported)
,SCHEMA_FILTER               -- Dremio folder/schema filter -> '%' to load all
,TABLE_FILTER                -- Dremio dataset filter -> '%' to load all
) RETURNS TABLE
AS

exa_upper_begin=''
exa_upper_end=''

if IDENTIFIER_CASE_INSENSITIVE == true then
    exa_upper_begin='upper('
    exa_upper_end=')'
end

if DB_FILTER == nil or DB_FILTER == '' or DB_FILTER == '%' then
    error('DB_FILTER is required for DREMIO and must name a single Dremio source or space (e.g. "@dremio", "samples"). Wildcards are not supported.')
end

suc, res = pquery([[

with vv_dremio_columns as (
    select ]]..exa_upper_begin..[[table_catalog]]..exa_upper_end..[[ as "exa_table_catalog",
           ]]..exa_upper_begin..[[table_schema]]..exa_upper_end..[[  as "exa_table_schema",
           ]]..exa_upper_begin..[[table_name]]..exa_upper_end..[[   as "exa_table_name",
           ]]..exa_upper_begin..[[column_name]]..exa_upper_end..[[  as "exa_column_name",
           -- Strip parens and trailing whitespace to derive the base
           -- type name (e.g. 'DECIMAL(18, 3)' -> 'DECIMAL',
           -- 'VARCHAR(50)' -> 'VARCHAR', 'INTERVAL DAY' kept multi-word).
           upper(regexp_replace(data_type, '\(.*?\)', '')) as base_type,
           data_type as raw_type,
           -- Dremio's information_schema columns precision/scale columns
           -- are inconsistent across versions; parse from the data_type
           -- string instead.
           to_number(regexp_substr(data_type, '\d+', 1, 1)) as type_param_1,
           to_number(regexp_substr(data_type, '\d+', 1, 2)) as type_param_2,
           column_name,
           table_schema,
           table_name,
           ordinal_position,
           not_null_constraint
      from ( import from jdbc at ]]..CONNECTION_NAME..[[ statement
        '-- Dremio INFORMATION_SCHEMA.COLUMNS. The TABLE_SCHEMA column
         -- holds the dotted source.folder path; filter by LIKE against
         -- it. Force quoted uppercase aliases for the JDBC handshake.
         select TABLE_CATALOG            as "TABLE_CATALOG",
                TABLE_SCHEMA             as "TABLE_SCHEMA",
                TABLE_NAME               as "TABLE_NAME",
                COLUMN_NAME              as "COLUMN_NAME",
                ORDINAL_POSITION         as "ORDINAL_POSITION",
                case when IS_NULLABLE = ''YES'' then ''NULL'' else ''NOT NULL'' end as "NOT_NULL_CONSTRAINT",
                DATA_TYPE                as "DATA_TYPE"
           from INFORMATION_SCHEMA."COLUMNS"
          where TABLE_SCHEMA not in (''INFORMATION_SCHEMA'', ''sys'')
            AND (TABLE_SCHEMA = '']]..DB_FILTER..[['' OR TABLE_SCHEMA LIKE '']]..DB_FILTER..[[.%'')
            AND TABLE_SCHEMA like ''%]]..SCHEMA_FILTER..[[%''
            AND TABLE_NAME like '']]..TABLE_FILTER..[[''
        '
    ) as dremio
)

,vv_create_schemas as (
    SELECT 'create schema if not exists "' || "exa_table_schema" || '";' as sql_text
      from vv_dremio_columns
     group by "exa_table_catalog","exa_table_schema"
     order by "exa_table_catalog","exa_table_schema"
)

,vv_create_tables as (
    select 'create or replace table "' || "exa_table_schema" || '"."' || "exa_table_name" || '" (' || group_concat(
    case
    -- ### signed integers (Arrow widths) ###
    when base_type = 'TINYINT'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(3,0) '  || not_null_constraint
    when base_type = 'SMALLINT' then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '  || not_null_constraint
    when base_type = 'INTEGER'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) ' || not_null_constraint
    when base_type = 'INT'      then '"' || "exa_column_name" || '" ' || 'DECIMAL(11,0) ' || not_null_constraint
    when base_type = 'BIGINT'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(19,0) ' || not_null_constraint

    -- ### floating point ###
    when base_type = 'FLOAT'            then '"' || "exa_column_name" || '" ' || 'FLOAT '  || not_null_constraint
    when base_type = 'REAL'             then '"' || "exa_column_name" || '" ' || 'FLOAT '  || not_null_constraint
    when base_type = 'DOUBLE'           then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || not_null_constraint
    when base_type = 'DOUBLE PRECISION' then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || not_null_constraint

    -- ### decimal (precision capped at 36) ###
    when base_type = 'DECIMAL' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
        case
          when type_param_1 is not null and type_param_1 <= 36 then type_param_1
          when type_param_1 > 36 then 36
          else 18
        end || ',' ||
        case
          when type_param_2 is null then 0
          when type_param_2 < 0 then 0
          when type_param_2 > 36 then 36
          else type_param_2
        end || ') ' || not_null_constraint

    -- ### boolean ###
    when base_type = 'BOOLEAN' then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || not_null_constraint

    -- ### date and time ###
    when base_type = 'DATE'      then '"' || "exa_column_name" || '" ' || 'DATE '      || not_null_constraint
    when base_type = 'TIMESTAMP' then '"' || "exa_column_name" || '" ' || 'TIMESTAMP ' || not_null_constraint
    when base_type = 'TIME'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(20) ' || not_null_constraint

    -- ### intervals (VARCHAR; Dremio emits ISO-style strings) ###
    when base_type = 'INTERVAL'           then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint
    when base_type = 'INTERVAL DAY'       then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint
    when base_type = 'INTERVAL YEAR'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint
    when base_type = 'INTERVAL DAY TO SECOND'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint
    when base_type = 'INTERVAL YEAR TO MONTH'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint

    -- ### character types (length parsed from data_type; unsized -> 2M) ###
    when base_type = 'VARCHAR' then '"' || "exa_column_name" || '" ' || 'VARCHAR(' ||
        case
          when type_param_1 is null then 2000000
          when type_param_1 > 2000000 then 2000000
          else type_param_1
        end || ') ' || not_null_constraint
    when base_type = 'CHARACTER VARYING' then '"' || "exa_column_name" || '" ' || 'VARCHAR(' ||
        case
          when type_param_1 is null then 2000000
          when type_param_1 > 2000000 then 2000000
          else type_param_1
        end || ') ' || not_null_constraint
    when base_type = 'CHAR' then '"' || "exa_column_name" || '" ' || 'CHAR(' ||
        case
          when type_param_1 is null then 2000
          when type_param_1 > 2000 then 2000
          else type_param_1
        end || ') ' || not_null_constraint
    when base_type = 'CHARACTER' then '"' || "exa_column_name" || '" ' || 'CHAR(' ||
        case
          when type_param_1 is null then 2000
          when type_param_1 > 2000 then 2000
          else type_param_1
        end || ') ' || not_null_constraint

    -- ### binary (hex-encoded on source side) ###
    when base_type = 'BINARY'        then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'VARBINARY'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'BINARY VARYING' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### complex Arrow types (JSON-serialized on source side) ###
    when base_type = 'LIST'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'ARRAY'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'STRUCT' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'ROW'    then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'MAP'    then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### MIXED / ANY (Dremio's catch-all) ###
    when base_type = 'ANY'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'MIXED' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    end
    order by ordinal_position) || ');'

    -- ### unknown types ###
    || group_concat (
        case
        when base_type not in (
            'TINYINT','SMALLINT','INTEGER','INT','BIGINT',
            'FLOAT','REAL','DOUBLE','DOUBLE PRECISION',
            'DECIMAL',
            'BOOLEAN',
            'DATE','TIMESTAMP','TIME',
            'INTERVAL','INTERVAL DAY','INTERVAL YEAR','INTERVAL DAY TO SECOND','INTERVAL YEAR TO MONTH',
            'VARCHAR','CHARACTER VARYING','CHAR','CHARACTER',
            'BINARY','VARBINARY','BINARY VARYING',
            'LIST','ARRAY','STRUCT','ROW','MAP',
            'ANY','MIXED'
        )
        then '--UNKNOWN_DATATYPE: "' || "exa_column_name" || '" ' || raw_type
        end
    ) || ' ' as sql_text
    from vv_dremio_columns
    group by "exa_table_catalog","exa_table_schema","exa_table_name"
    order by "exa_table_catalog","exa_table_schema","exa_table_name"
)

,vv_imports as (
    select 'import into "' || "exa_table_schema" || '"."' || "exa_table_name" || '" from jdbc at ]]..CONNECTION_NAME..[[ statement ''select '
           || group_concat(
                case
                -- pass-through scalar types
                when base_type in ('TINYINT','SMALLINT','INTEGER','INT','BIGINT','FLOAT','REAL','DOUBLE','DOUBLE PRECISION','BOOLEAN','DATE','TIMESTAMP','VARCHAR','CHARACTER VARYING','CHAR','CHARACTER')
                    then '"' || column_name || '"'

                -- decimal passes through
                when base_type = 'DECIMAL' then '"' || column_name || '"'

                -- time + intervals: cast to VARCHAR on source side
                when base_type = 'TIME' then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type like 'INTERVAL%' then 'CAST("' || column_name || '" AS VARCHAR)'

                -- binary: hex on source side
                when base_type in ('BINARY','VARBINARY','BINARY VARYING')
                    then 'CONVERT_TO("' || column_name || '", ''JSON'')'

                -- complex Arrow types: JSON-serialize on source side
                when base_type in ('LIST','ARRAY','STRUCT','ROW','MAP','ANY','MIXED')
                    then 'CONVERT_TO("' || column_name || '", ''JSON'')'

                end
                order by ordinal_position)
           || ' from "' || table_schema || '"."' || table_name || '"'';' as sql_text
    from vv_dremio_columns
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


create or replace connection dremio_conn
to 'jdbc:dremio:direct=192.168.137.5:31010'
user 'dremio'
identified by 'dremio123';

execute script database_migration.DREMIO_TO_EXASOL('dremio_conn'
,TRUE
,'@dremio'
,'%'
,'%'
);
