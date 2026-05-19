create schema if not exists database_migration;
/*
    This script generates create-schema / create-table / IMPORT statements
    to migrate all selected tables from a ClickHouse source database into
    Exasol.

    Notes on ClickHouse types:

      - Nullable(T) and LowCardinality(T) are wrappers. ClickHouse forbids
        Nullable(LowCardinality(T)) but allows LowCardinality(Nullable(T)),
        so the adapter strips LowCardinality first, then Nullable, to get
        the inner base type.

      - Int128 / Int256 / UInt128 / UInt256 exceed Exasol DECIMAL(36,0) and
        are mapped to VARCHAR(40 or 80); cast to String on source side.

      - Decimal(p, s) / Decimal32(s) / Decimal64(s) / Decimal128(s) /
        Decimal256(s): precision capped at 36. ClickHouse Decimal type
        string is `Decimal(P, S)` or `DecimalNN(S)`; both forms recognized.

      - Complex types (Array, Tuple, Map, Nested, Variant) and the JSON
        type are serialized to JSON on the source side via
        toJSONString(col) and stored as VARCHAR(2000000).

      - DateTime(<tz>) and DateTime64(p, <tz>) are mapped to TIMESTAMP;
        the timezone is dropped (lossy but Exasol stores absolute time).

      - UUID, IPv4, IPv6, Enum8, Enum16 → VARCHAR with appropriate length;
        cast via toString() on the source side so the JDBC client doesn't
        try to convert these to BigInteger / InetAddress / etc.

      - The IMPORT SELECT aliases all information_schema columns with
        quoted upper-case identifiers so that the JDBC result column names
        match Exasol's unquoted-identifier normalization (otherwise the
        outer SQL would fail with `object TABLE_CATALOG not found`).
*/
--/
create or replace script database_migration.CLICKHOUSE_TO_EXASOL(
CONNECTION_NAME              -- name of the database connection inside exasol -> e.g. clickhouse_db
,IDENTIFIER_CASE_INSENSITIVE -- true if identifiers should be stored case-insensitiv (will be stored upper_case)
,SCHEMA_FILTER               -- filter for the ClickHouse databases to generate and load -> '%' to load all
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

with vv_clickhouse_columns as (
    select ]]..exa_upper_begin..[[table_catalog]]..exa_upper_end..[[ as "exa_table_catalog",
           ]]..exa_upper_begin..[[table_schema]]..exa_upper_end..[[ as "exa_table_schema",
           ]]..exa_upper_begin..[[table_name]]..exa_upper_end..[[ as "exa_table_name",
           ]]..exa_upper_begin..[[column_name]]..exa_upper_end..[[ as "exa_column_name",
           regexp_replace(data_type, '\(.*$', '') as base_type,
           regexp_replace(
             regexp_replace(data_type, '^LowCardinality\((.*)\)$', '\1'),
             '^Nullable\((.*)\)$', '\1'
           ) as stripped_type,
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
        '-- ClickHouse information_schema.columns is ANSI-style (lower case
         -- column names). Force uppercase aliases so Exasol IMPORT
         -- delivers identifiers that match unquoted outer refs.
         select table_catalog            as "TABLE_CATALOG",
                table_schema             as "TABLE_SCHEMA",
                table_name               as "TABLE_NAME",
                column_name              as "COLUMN_NAME",
                ordinal_position         as "ORDINAL_POSITION",
                case when is_nullable = ''YES'' then ''NULL'' else ''NOT NULL'' end as "NOT_NULL_CONSTRAINT",
                data_type                as "DATA_TYPE",
                numeric_precision        as "NUMERIC_PRECISION",
                numeric_scale            as "NUMERIC_SCALE",
                character_maximum_length as "CHARACTER_MAXIMUM_LENGTH"
           from information_schema.columns
          where table_schema not in (''system'', ''INFORMATION_SCHEMA'', ''information_schema'')
            AND table_schema like '']]..SCHEMA_FILTER..[[''
            AND table_name like '']]..TABLE_FILTER..[[''
        '
    ) as clickhouse
)

,vv_create_schemas as (
    SELECT 'create schema if not exists "' || "exa_table_schema" || '";' as sql_text
      from vv_clickhouse_columns
     group by "exa_table_catalog","exa_table_schema"
     order by "exa_table_catalog","exa_table_schema"
)

,vv_stripped as (
    -- Re-strip Nullable/LowCardinality at the outer level so the case
    -- branches below can pattern-match on the inner base type. Two more
    -- passes catch any residue from LowCardinality(Nullable(...)).
    select v.*,
           regexp_replace(
             regexp_replace(stripped_type, '^LowCardinality\((.*)\)$', '\1'),
             '^Nullable\((.*)\)$', '\1'
           ) as inner_type,
           regexp_replace(
             regexp_replace(
               regexp_replace(stripped_type, '^LowCardinality\((.*)\)$', '\1'),
               '^Nullable\((.*)\)$', '\1'
             ),
             '\(.*$', ''
           ) as inner_base_type
      from vv_clickhouse_columns v
)

,vv_create_tables as (
    select 'create or replace table "' || "exa_table_schema" || '"."' || "exa_table_name" || '" (' || group_concat(
    case
    -- ### signed integers ###
    when inner_base_type = 'Int8'    then '"' || "exa_column_name" || '" ' || 'DECIMAL(3,0) '  || not_null_constraint
    when inner_base_type = 'Int16'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '  || not_null_constraint
    when inner_base_type = 'Int32'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(10,0) ' || not_null_constraint
    when inner_base_type = 'Int64'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(19,0) ' || not_null_constraint
    when inner_base_type = 'Int128'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '   || not_null_constraint
    when inner_base_type = 'Int256'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(80) '   || not_null_constraint

    -- ### unsigned integers ###
    when inner_base_type = 'UInt8'   then '"' || "exa_column_name" || '" ' || 'DECIMAL(3,0) '  || not_null_constraint
    when inner_base_type = 'UInt16'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(5,0) '  || not_null_constraint
    when inner_base_type = 'UInt32'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(10,0) ' || not_null_constraint
    when inner_base_type = 'UInt64'  then '"' || "exa_column_name" || '" ' || 'DECIMAL(20,0) ' || not_null_constraint
    when inner_base_type = 'UInt128' then '"' || "exa_column_name" || '" ' || 'VARCHAR(40) '   || not_null_constraint
    when inner_base_type = 'UInt256' then '"' || "exa_column_name" || '" ' || 'VARCHAR(80) '   || not_null_constraint

    -- ### floating point ###
    when inner_base_type = 'Float32' then '"' || "exa_column_name" || '" ' || 'FLOAT '  || not_null_constraint
    when inner_base_type = 'Float64' then '"' || "exa_column_name" || '" ' || 'DOUBLE ' || not_null_constraint

    -- ### decimal (precision capped at 36) ###
    when inner_base_type like 'Decimal%' then '"' || "exa_column_name" || '" ' || 'decimal(' ||
        case
          when numeric_precision is not null and numeric_precision <= 36 then numeric_precision
          when numeric_precision > 36 then 36
          else 18
        end || ',' ||
        case
          when numeric_scale is null then 0
          when numeric_scale < 0 then 0
          when numeric_scale > 36 then 36
          else numeric_scale
        end || ') ' || not_null_constraint

    -- ### boolean ###
    when inner_base_type = 'Bool'    then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || not_null_constraint
    when inner_base_type = 'Boolean' then '"' || "exa_column_name" || '" ' || 'BOOLEAN ' || not_null_constraint

    -- ### date and time ###
    when inner_base_type = 'Date'        then '"' || "exa_column_name" || '" ' || 'DATE '      || not_null_constraint
    when inner_base_type = 'Date32'      then '"' || "exa_column_name" || '" ' || 'DATE '      || not_null_constraint
    when inner_base_type = 'DateTime'    then '"' || "exa_column_name" || '" ' || 'TIMESTAMP ' || not_null_constraint
    when inner_base_type = 'DateTime64'  then '"' || "exa_column_name" || '" ' || 'TIMESTAMP ' || not_null_constraint

    -- ### string ###
    when inner_base_type = 'String'       then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'FixedString'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### identifier / network ###
    when inner_base_type = 'UUID'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(36) ' || not_null_constraint
    when inner_base_type = 'IPv4'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(15) ' || not_null_constraint
    when inner_base_type = 'IPv6'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(45) ' || not_null_constraint

    -- ### enums ###
    when inner_base_type = 'Enum8'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Enum16' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    -- ### complex types (JSON-serialized on source side) ###
    when inner_base_type = 'Array'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Tuple'   then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Map'     then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Nested'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Variant' then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'JSON'    then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint
    when inner_base_type = 'Object'  then '"' || "exa_column_name" || '" ' || 'VARCHAR(2000000) ' || not_null_constraint

    end
    order by ordinal_position) || ');'

    -- ### unknown types ###
    || group_concat (
        case
        when inner_base_type not in (
            'Int8','Int16','Int32','Int64','Int128','Int256',
            'UInt8','UInt16','UInt32','UInt64','UInt128','UInt256',
            'Float32','Float64',
            'Bool','Boolean',
            'Date','Date32','DateTime','DateTime64',
            'String','FixedString',
            'UUID','IPv4','IPv6',
            'Enum8','Enum16',
            'Array','Tuple','Map','Nested','Variant','JSON','Object'
        ) and inner_base_type not like 'Decimal%'
        then '--UNKNOWN_DATATYPE: "' || "exa_column_name" || '" ' || inner_base_type
        end
    ) || ' ' as sql_text
    from vv_stripped
    group by "exa_table_catalog","exa_table_schema","exa_table_name"
    order by "exa_table_catalog","exa_table_schema","exa_table_name"
)

,vv_imports as (
    select 'import into "' || "exa_table_schema" || '"."' || "exa_table_name" || '" from jdbc at ]]..CONNECTION_NAME..[[ statement ''select '
           || group_concat(
                case
                -- pass-through types (numeric, boolean, date, normal strings) ##
                when inner_base_type in ('Int8','Int16','Int32','Int64','UInt8','UInt16','UInt32','UInt64','Float32','Float64','Bool','Boolean','Date','Date32','DateTime','DateTime64','String','FixedString')
                    then '`' || column_name || '`'

                -- decimals pass through; if 128/256 may overflow we let CH return BigDecimal
                when inner_base_type like 'Decimal%' then '`' || column_name || '`'

                -- big ints: cast to String on source side
                when inner_base_type = 'Int128'  then 'toString(`' || column_name || '`)'
                when inner_base_type = 'Int256'  then 'toString(`' || column_name || '`)'
                when inner_base_type = 'UInt128' then 'toString(`' || column_name || '`)'
                when inner_base_type = 'UInt256' then 'toString(`' || column_name || '`)'

                -- identifier-ish scalars: explicit string cast on source side
                when inner_base_type = 'UUID'    then 'toString(`' || column_name || '`)'
                when inner_base_type = 'IPv4'    then 'toString(`' || column_name || '`)'
                when inner_base_type = 'IPv6'    then 'toString(`' || column_name || '`)'

                -- enums: explicit string cast on source side
                when inner_base_type = 'Enum8'   then 'toString(`' || column_name || '`)'
                when inner_base_type = 'Enum16'  then 'toString(`' || column_name || '`)'

                -- complex types: JSON-serialize on source side
                when inner_base_type = 'Array'   then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'Tuple'   then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'Map'     then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'Nested'  then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'Variant' then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'JSON'    then 'toJSONString(`' || column_name || '`)'
                when inner_base_type = 'Object'  then 'toJSONString(`' || column_name || '`)'
                end
                order by ordinal_position)
           || ' from `' || table_schema || '`.`' || table_name || '`'';' as sql_text
    from vv_stripped
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


create or replace connection clickhouse_conn
to 'jdbc:clickhouse://192.168.137.5:8123/default'
user 'default'
identified by 'clickhouse';

execute script database_migration.CLICKHOUSE_TO_EXASOL('clickhouse_conn'
,TRUE
,'%'
,'%'
);
