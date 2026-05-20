create schema if not exists database_migration;
/*
    This script generates create-schema / create-table / IMPORT statements
    to migrate all selected tables from a Trino source catalog into Exasol.

    Notes on Trino types and behaviour:

      - Trino is a federated SQL engine. Its `information_schema` is per
        catalog, so the wrapper passes a catalog name as DB_FILTER and the
        adapter queries `<catalog>.information_schema.columns`.

      - `information_schema.columns` returns ANSI-style lower-case result
        column names. The IMPORT SELECT aliases each pulled column with a
        quoted upper-case identifier so the JDBC result column names match
        Exasol's unquoted-identifier normalization (otherwise the outer
        SQL fails with `object TABLE_CATALOG not found`).

      - Trino datatype names from `data_type` are lower case and may carry
        parameters (e.g. `decimal(18,3)`, `varchar(50)`, `timestamp(6) with
        time zone`). The adapter strips parameters/modifiers on the Exasol
        side to derive a base type.

      - Complex types (`array(...)`, `map(...)`, `row(...)`, `json`),
        identifier types (`uuid`, `ipaddress`), interval types and the
        sketch types (`hyperloglog`, `qdigest`, `tdigest`) are cast to
        VARCHAR on the source side because the JDBC driver would otherwise
        deliver them as Java objects Exasol can't ingest.

      - Source identifiers are double-quoted (ANSI standard). Trino uses
        backticks only as identifier delimiters in older PrestoDB grammar
        and accepts double quotes today.
*/
--/
create or replace script database_migration.TRINO_TO_EXASOL(
CONNECTION_NAME              -- name of the database connection inside exasol -> e.g. trino_db
,IDENTIFIER_CASE_INSENSITIVE -- true if identifiers should be stored case-insensitiv (will be stored upper_case)
,DB_FILTER                   -- Trino catalog name (single catalog per call, e.g. 'memory', 'mysql_prod')
,SCHEMA_FILTER               -- filter for the Trino schemas to generate and load -> '%' to load all
,TABLE_FILTER                -- filter for the tables to generate and load -> '%' to load all
) RETURNS TABLE
AS

exa_upper_begin=''
exa_upper_end=''

if IDENTIFIER_CASE_INSENSITIVE == true then
    exa_upper_begin='upper('
    exa_upper_end=')'
end

if DB_FILTER == nil or DB_FILTER == '' or DB_FILTER == '%' then
    error('DB_FILTER is required for TRINO and must name a single Trino catalog (e.g. "memory"). Wildcards are not supported because information_schema is per-catalog.')
end

suc, res = pquery([[

with vv_trino_columns as (
    select ]]..exa_upper_begin..[[table_catalog]]..exa_upper_end..[[ as "exa_table_catalog",
           ]]..exa_upper_begin..[[table_schema]]..exa_upper_end..[[  as "exa_table_schema",
           ]]..exa_upper_begin..[[table_name]]..exa_upper_end..[[   as "exa_table_name",
           ]]..exa_upper_begin..[[column_name]]..exa_upper_end..[[  as "exa_column_name",
           -- Strip parens, time-zone modifier and trailing whitespace
           -- to derive the base type name (e.g. 'varchar(50)' -> 'varchar',
           -- 'timestamp(6) with time zone' -> 'timestamp', 'interval day
           -- to second' -> 'interval day to second' kept multi-word).
           lower(regexp_replace(regexp_replace(data_type, '\(.*?\)', ''), '\s+with\s+time\s+zone$', '')) as base_type,
           data_type as raw_type,
           -- Trino's information_schema.columns does NOT expose
           -- numeric_precision/numeric_scale/character_maximum_length;
           -- parse them from the parameterised data_type string instead
           -- (e.g. 'decimal(18,3)', 'varchar(50)', 'char(8)').
           to_number(regexp_substr(data_type, '\d+', 1, 1)) as type_param_1,
           to_number(regexp_substr(data_type, '\d+', 1, 2)) as type_param_2,
           column_name,
           table_schema,
           table_name,
           ordinal_position,
           not_null_constraint
      from ( import from jdbc at ]]..CONNECTION_NAME..[[ statement
        '-- Trino information_schema.columns is ANSI-style (lower case
         -- column names). Force uppercase aliases so Exasol IMPORT
         -- delivers identifiers that match unquoted outer refs.
         select table_catalog            as "TABLE_CATALOG",
                table_schema             as "TABLE_SCHEMA",
                table_name               as "TABLE_NAME",
                column_name              as "COLUMN_NAME",
                ordinal_position         as "ORDINAL_POSITION",
                case when is_nullable = ''YES'' then ''NULL'' else ''NOT NULL'' end as "NOT_NULL_CONSTRAINT",
                data_type                as "DATA_TYPE"
           from "]]..DB_FILTER..[[".information_schema.columns
          where table_schema not in (''information_schema'')
            AND table_schema like '']]..SCHEMA_FILTER..[[''
            AND table_name like '']]..TABLE_FILTER..[[''
        '
    ) as trino
)

,vv_create_schemas as (
    SELECT 'create schema if not exists "' || "exa_table_schema" || '";' as sql_text
      from vv_trino_columns
     group by "exa_table_catalog","exa_table_schema"
     order by "exa_table_catalog","exa_table_schema"
)

,vv_create_tables as (
    select 'create or replace table "' || "exa_table_schema" || '"."' || "exa_table_name" || '" (' || group_concat(
    case
    -- ### signed integers ###
    when base_type = 'tinyint'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(3,0) '  || not_null_constraint
    when base_type = 'smallint' then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '  || not_null_constraint
    when base_type = 'integer'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(10,0) ' || not_null_constraint
    when base_type = 'bigint'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(19,0) ' || not_null_constraint

    -- ### floating point ###
    when base_type = 'real'             then '"' || "exa_column_name" || '" ' || 'FLOAT '  || not_null_constraint
    when base_type = 'double'           then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || not_null_constraint
    when base_type = 'double precision' then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || not_null_constraint

    -- ### decimal (precision capped at 36; params parsed from data_type) ###
    when base_type = 'decimal' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
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
    when base_type = 'boolean' then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || not_null_constraint

    -- ### date and time ###
    when base_type = 'date'      then '"' || "exa_column_name" || '" ' || 'DATE '      || not_null_constraint
    when base_type = 'timestamp' then '"' || "exa_column_name" || '" ' || 'TIMESTAMP ' || not_null_constraint
    when base_type = 'time'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(20) ' || not_null_constraint

    -- ### intervals (always VARCHAR; Trino emits ISO-style strings) ###
    when base_type = 'interval day to second'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint
    when base_type = 'interval year to month'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(50) ' || not_null_constraint

    -- ### character types (length parsed from data_type; unsized -> 2M) ###
    when base_type = 'varchar' then '"' || "exa_column_name" || '" ' || 'VARCHAR(' ||
        case
          when type_param_1 is null then 2000000
          when type_param_1 > 2000000 then 2000000
          else type_param_1
        end || ') ' || not_null_constraint
    when base_type = 'char' then '"' || "exa_column_name" || '" ' || 'CHAR(' ||
        case
          when type_param_1 is null then 2000
          when type_param_1 > 2000 then 2000
          else type_param_1
        end || ') ' || not_null_constraint

    -- ### binary ###
    when base_type = 'varbinary' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### identifier / network ###
    when base_type = 'uuid'      then '"' || "exa_column_name" || '" ' || 'VARCHAR(36) ' || not_null_constraint
    when base_type = 'ipaddress' then '"' || "exa_column_name" || '" ' || 'VARCHAR(45) ' || not_null_constraint

    -- ### sketch types (lossy: Exasol has no analytic equivalent) ###
    when base_type = 'hyperloglog' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'qdigest'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'tdigest'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### complex types (cast to VARCHAR on source side) ###
    when base_type = 'array' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'map'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'row'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when base_type = 'json'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    end
    order by ordinal_position) || ');'

    -- ### unknown types ###
    || group_concat (
        case
        when base_type not in (
            'tinyint','smallint','integer','bigint',
            'real','double','double precision',
            'decimal',
            'boolean',
            'date','timestamp','time',
            'interval day to second','interval year to month',
            'varchar','char','varbinary',
            'uuid','ipaddress',
            'hyperloglog','qdigest','tdigest',
            'array','map','row','json'
        )
        then '--UNKNOWN_DATATYPE: "' || "exa_column_name" || '" ' || raw_type
        end
    ) || ' ' as sql_text
    from vv_trino_columns
    group by "exa_table_catalog","exa_table_schema","exa_table_name"
    order by "exa_table_catalog","exa_table_schema","exa_table_name"
)

,vv_imports as (
    select 'import into "' || "exa_table_schema" || '"."' || "exa_table_name" || '" from jdbc at ]]..CONNECTION_NAME..[[ statement ''select '
           || group_concat(
                case
                -- pass-through scalar types
                when base_type in ('tinyint','smallint','integer','bigint','real','double','double precision','boolean','date','timestamp','varchar','char')
                    then '"' || column_name || '"'

                -- decimal passes through; numeric scale preserved
                when base_type = 'decimal' then '"' || column_name || '"'

                -- time + intervals: cast to VARCHAR on source side (lossless ISO string)
                when base_type = 'time'                     then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'interval day to second'   then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'interval year to month'   then 'CAST("' || column_name || '" AS VARCHAR)'

                -- binary: hex-encode on source side
                when base_type = 'varbinary' then 'to_hex("' || column_name || '")'

                -- identifier-ish scalars: explicit string cast on source side
                when base_type = 'uuid'      then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'ipaddress' then 'CAST("' || column_name || '" AS VARCHAR)'

                -- sketch types: cast to VARCHAR (lossy; the binary sketch
                -- is not portable to Exasol, but the round-trippable
                -- string form keeps the row intact)
                when base_type = 'hyperloglog' then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'qdigest'     then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'tdigest'     then 'CAST("' || column_name || '" AS VARCHAR)'

                -- complex types: cast to VARCHAR on source side
                when base_type = 'array' then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'map'   then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'row'   then 'CAST("' || column_name || '" AS VARCHAR)'
                when base_type = 'json'  then 'CAST("' || column_name || '" AS VARCHAR)'
                end
                order by ordinal_position)
           || ' from "]]..DB_FILTER..[["."' || table_schema || '"."' || table_name || '"'';' as sql_text
    from vv_trino_columns
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


create or replace connection trino_conn
to 'jdbc:trino://192.168.137.5:8080/memory/default'
user 'admin'
identified by '';

execute script database_migration.TRINO_TO_EXASOL('trino_conn'
,TRUE
,'memory'
,'%'
,'%'
);
