--/
create or replace script EXA_DB_MIGRATION.MIGRATE_TO_EXASOL(
    source_type
    , connection_name
    , db_filter
    , schema_filter
    , target_schema
    , table_filter
    , identifier_case_insensitive
    , execution_mode
    , parallel_connections
    , db2schema
    , options
) RETURNS TABLE
AS

-- Initialize case-insensitive identifier handling
exa_upper_begin = ''
exa_upper_end = ''
if identifier_case_insensitive == true then
    exa_upper_begin = 'upper('
    exa_upper_end = ')'
end

-- Parse execution mode
local debug = true
if execution_mode == null or execution_mode == NULL then
    debug = true
elseif string.upper(execution_mode) == 'EXECUTE' then
    debug = false
elseif string.upper(execution_mode) == 'DEBUG' then
    debug = true
else
    error([[Invalid execution_mode. Use 'DEBUG' or 'EXECUTE']])
end

-- Normalize source_type to lowercase for adapter lookup
local source_type_lower = string.lower(source_type or '')

-- ─────────────────────────────────────────────────────────────────
-- SOURCE_ADAPTERS table: Each adapter implements 4 functions
-- ─────────────────────────────────────────────────────────────────

local SOURCE_ADAPTERS = {}

-- ─────────────────────────────────────────────────────────────────
-- SNOWFLAKE ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['snowflake'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        -- Build filter conditions (single quotes doubled for outer STATEMENT string)
        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        -- Query databases from Snowflake
        local query = [[
            SELECT DATABASE_NAME FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES
            WHERE DATABASE_NAME ]] .. db_str

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        if not success or #res < 1 then
            return {}
        end

        return res
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        -- Build filter conditions (single quotes doubled for outer STATEMENT string)
        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        -- Get list of databases first
        local db_query = [[
            SELECT DATABASE_NAME FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES
            WHERE DATABASE_NAME ]] .. db_str

        local db_success, db_res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. db_query .. [[')
        ]])

        if not db_success or #db_res < 1 then
            return {}
        end

        -- Build UNION ALL query for all databases
        local query_parts = {}
        for i, db_row in ipairs(db_res) do
            local db_name = db_row[1]
            local part = [[
                SELECT
                    '']] .. db_name .. [['' as DB_NAME,
                    s.SCHEMA_NAME as SCHEMA_NAME,
                    t.TABLE_NAME as TABLE_NAME,
                    cast(c.ORDINAL_POSITION as NUMBER(36,0)) as COLUMN_ID,
                    ]] .. upper_begin .. [[c.COLUMN_NAME]] .. upper_end .. [[ as COLUMN_NAME,
                    c.COLUMN_NAME as SOURCE_COLUMN_NAME,
                    cast(c.CHARACTER_MAXIMUM_LENGTH as NUMBER(36,0)) as COL_MAX_LENGTH,
                    cast(c.NUMERIC_PRECISION as NUMBER(36,0)) as PRECISION,
                    cast(c.NUMERIC_SCALE as NUMBER(36,0)) as SCALE,
                    c.IS_NULLABLE as IS_NULLABLE,
                    c.IS_IDENTITY as IS_IDENTITY,
                    c.DATA_TYPE as DATA_TYPE
                FROM ]] .. db_name .. [[.INFORMATION_SCHEMA.SCHEMATA s
                JOIN ]] .. db_name .. [[.INFORMATION_SCHEMA.TABLES t ON s.SCHEMA_NAME = t.TABLE_SCHEMA
                JOIN ]] .. db_name .. [[.INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME AND c.TABLE_SCHEMA = s.SCHEMA_NAME
                WHERE s.SCHEMA_NAME ]] .. schema_str .. [[ AND t.TABLE_NAME ]] .. table_str .. [[
            ]]
            table.insert(query_parts, part)
        end

        local full_query = table.concat(query_parts, ' UNION ALL ')

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. full_query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token, precision, scale, max_len)
        local t = source_type_token or ''
        if t == 'NUMBER' or t == 'NUMERIC' or t == 'DECIMAL' then
            local p = (precision and precision > 0 and precision <= 36) and precision or 36
            local s = (scale and scale >= 0) and math.min(scale, p) or 0
            return 'DECIMAL(' .. p .. ',' .. s .. ')'
        elseif t == 'FLOAT' or t == 'DOUBLE' or t == 'REAL' then
            return 'DOUBLE PRECISION'
        elseif t == 'TEXT' or t == 'VARCHAR' or t == 'CHAR' or t == 'STRING' then
            local len = (max_len and max_len > 0) and math.min(max_len, 2000000) or 2000000
            return 'VARCHAR(' .. len .. ')'
        elseif t == 'BINARY' then
            return 'VARCHAR(20)'
        elseif t == 'BOOLEAN' then
            return 'BOOLEAN'
        elseif t == 'GEOMETRY' then
            return 'GEOMETRY'
        elseif t == 'GEOGRAPHY' then
            return 'GEOMETRY(4326)'
        elseif t == 'TIMESTAMP_LTZ' then
            return 'TIMESTAMP WITH LOCAL TIME ZONE'
        elseif t == 'TIMESTAMP' or t == 'TIMESTAMP_NTZ' or t == 'DATETIME' or t == 'DATE' or t == 'TIME' then
            return 'TIMESTAMP'
        elseif t == 'VARIANT' or t == 'OBJECT' or t == 'ARRAY' then
            return 'VARCHAR(2000000)'
        end
        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '"' .. final_name .. '"'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- POSTGRES ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['postgres'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT table_schema, table_name FROM information_schema.tables
            WHERE table_schema ]] .. schema_str .. [[ AND table_type = 'BASE TABLE'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                table_schema, table_name, ordinal_position, column_name,
                data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable
            FROM information_schema.columns
            WHERE table_schema ]] .. schema_str .. [[ AND table_name ]] .. table_str .. [[
            ORDER BY table_schema, table_name, ordinal_position
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['bigint'] = 'BIGINT',
            ['boolean'] = 'BOOLEAN',
            ['character'] = 'CHAR(2000)',
            ['character varying'] = 'VARCHAR(2000000)',
            ['date'] = 'DATE',
            ['double precision'] = 'DOUBLE PRECISION',
            ['integer'] = 'INTEGER',
            ['numeric'] = 'DECIMAL(36,0)',
            ['real'] = 'DOUBLE PRECISION',
            ['smallint'] = 'SMALLINT',
            ['text'] = 'VARCHAR(2000000)',
            ['timestamp without time zone'] = 'TIMESTAMP',
            ['timestamp with time zone'] = 'TIMESTAMP WITH LOCAL TIME ZONE',
            ['time without time zone'] = 'TIMESTAMP',
            ['time with time zone'] = 'TIMESTAMP WITH LOCAL TIME ZONE',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '"' .. final_name .. '"'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- MYSQL ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['mysql'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA ]] .. db_str .. [[ AND TABLE_TYPE = 'BASE TABLE'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                TABLE_SCHEMA as db_name, TABLE_NAME as table_name, ORDINAL_POSITION as col_pos, COLUMN_NAME as col_name,
                COLUMN_TYPE as col_type, CHARACTER_MAXIMUM_LENGTH as max_len, NUMERIC_PRECISION as precision, NUMERIC_SCALE as scale, IS_NULLABLE as nullable
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA ]] .. db_str .. [[ AND TABLE_NAME ]] .. table_str .. [[
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['INT'] = 'INTEGER',
            ['BIGINT'] = 'BIGINT',
            ['SMALLINT'] = 'SMALLINT',
            ['TINYINT'] = 'TINYINT',
            ['DECIMAL'] = 'DECIMAL(36,0)',
            ['NUMERIC'] = 'DECIMAL(36,0)',
            ['FLOAT'] = 'FLOAT',
            ['DOUBLE'] = 'DOUBLE PRECISION',
            ['BOOLEAN'] = 'BOOLEAN',
            ['BOOL'] = 'BOOLEAN',
            ['CHAR'] = 'CHAR(2000)',
            ['VARCHAR'] = 'VARCHAR(2000000)',
            ['TEXT'] = 'VARCHAR(2000000)',
            ['DATE'] = 'DATE',
            ['DATETIME'] = 'TIMESTAMP',
            ['TIMESTAMP'] = 'TIMESTAMP',
            ['TIME'] = 'TIMESTAMP',
            ['JSON'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '`' .. final_name .. '`'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- MARIADB ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['mariadb'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA ]] .. db_str .. [[ AND TABLE_TYPE = 'BASE TABLE'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local db_str = ''
        if string.match(db_filt, '%%') then
            db_str = [[LIKE '']] .. db_filt .. [['']]
        else
            db_str = [[IN ('']] .. db_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                TABLE_SCHEMA as db_name, TABLE_NAME as table_name, ORDINAL_POSITION as col_pos, COLUMN_NAME as col_name,
                COLUMN_TYPE as col_type, CHARACTER_MAXIMUM_LENGTH as max_len, NUMERIC_PRECISION as precision, NUMERIC_SCALE as scale, IS_NULLABLE as nullable
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA ]] .. db_str .. [[ AND TABLE_NAME ]] .. table_str .. [[
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['INT'] = 'INTEGER',
            ['BIGINT'] = 'BIGINT',
            ['SMALLINT'] = 'SMALLINT',
            ['TINYINT'] = 'TINYINT',
            ['DECIMAL'] = 'DECIMAL(36,0)',
            ['NUMERIC'] = 'DECIMAL(36,0)',
            ['FLOAT'] = 'FLOAT',
            ['DOUBLE'] = 'DOUBLE PRECISION',
            ['BOOLEAN'] = 'BOOLEAN',
            ['BOOL'] = 'BOOLEAN',
            ['CHAR'] = 'CHAR(2000)',
            ['VARCHAR'] = 'VARCHAR(2000000)',
            ['TEXT'] = 'VARCHAR(2000000)',
            ['DATE'] = 'DATE',
            ['DATETIME'] = 'TIMESTAMP',
            ['TIMESTAMP'] = 'TIMESTAMP',
            ['TIME'] = 'TIMESTAMP',
            ['JSON'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '`' .. final_name .. '`'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- AZURE_SQL ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['azure_sql'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA ]] .. schema_str .. [[ AND TABLE_TYPE = 'BASE TABLE'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME,
                DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA ]] .. schema_str .. [[ AND TABLE_NAME ]] .. table_str .. [[
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['int'] = 'INTEGER',
            ['bigint'] = 'BIGINT',
            ['smallint'] = 'SMALLINT',
            ['tinyint'] = 'TINYINT',
            ['numeric'] = 'DECIMAL(36,0)',
            ['decimal'] = 'DECIMAL(36,0)',
            ['float'] = 'FLOAT',
            ['real'] = 'DOUBLE PRECISION',
            ['bit'] = 'BOOLEAN',
            ['char'] = 'CHAR(2000)',
            ['varchar'] = 'VARCHAR(2000000)',
            ['text'] = 'VARCHAR(2000000)',
            ['date'] = 'DATE',
            ['datetime'] = 'TIMESTAMP',
            ['datetime2'] = 'TIMESTAMP',
            ['time'] = 'TIMESTAMP',
            ['datetimeoffset'] = 'TIMESTAMP WITH LOCAL TIME ZONE',
            ['json'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '[' .. final_name .. ']'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- BIGQUERY ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['bigquery'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT table_schema, table_name FROM INFORMATION_SCHEMA.TABLES
            WHERE table_schema ]] .. schema_str .. [[ AND table_type = 'BASE TABLE'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                table_schema, table_name, ordinal_position, column_name,
                data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema ]] .. schema_str .. [[ AND table_name ]] .. table_str .. [[
            ORDER BY table_schema, table_name, ordinal_position
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['INT64'] = 'BIGINT',
            ['INT32'] = 'INTEGER',
            ['INT16'] = 'SMALLINT',
            ['NUMERIC'] = 'DECIMAL(36,0)',
            ['BIGNUMERIC'] = 'DECIMAL(36,0)',
            ['FLOAT64'] = 'DOUBLE PRECISION',
            ['FLOAT32'] = 'FLOAT',
            ['BOOL'] = 'BOOLEAN',
            ['STRING'] = 'VARCHAR(2000000)',
            ['BYTES'] = 'VARCHAR(2000000)',
            ['DATE'] = 'DATE',
            ['TIME'] = 'TIMESTAMP',
            ['DATETIME'] = 'TIMESTAMP',
            ['TIMESTAMP'] = 'TIMESTAMP WITH LOCAL TIME ZONE',
            ['STRUCT'] = 'VARCHAR(2000000)',
            ['ARRAY'] = 'VARCHAR(2000000)',
            ['GEOGRAPHY'] = 'GEOMETRY(4326)',
            ['JSON'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '`' .. final_name .. '`'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- TERADATA ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['teradata'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT schemaname, tablename FROM dbc.tables
            WHERE schemaname ]] .. schema_str .. [[ AND tablekind = 'T'
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                schemaname, tablename, columnposition, columnname,
                columntype, columnnumber
            FROM dbc.columns
            WHERE schemaname ]] .. schema_str .. [[ AND tablename ]] .. table_str .. [[
            ORDER BY schemaname, tablename, columnposition
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['BIGINT'] = 'BIGINT',
            ['INTEGER'] = 'INTEGER',
            ['SMALLINT'] = 'SMALLINT',
            ['NUMERIC'] = 'DECIMAL(36,0)',
            ['DECIMAL'] = 'DECIMAL(36,0)',
            ['FLOAT'] = 'DOUBLE PRECISION',
            ['BOOLEAN'] = 'BOOLEAN',
            ['CHAR'] = 'CHAR(2000)',
            ['VARCHAR'] = 'VARCHAR(2000000)',
            ['DATE'] = 'DATE',
            ['TIME'] = 'TIMESTAMP',
            ['TIMESTAMP'] = 'TIMESTAMP',
            ['INTERVAL'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '"' .. final_name .. '"'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- VERTICA ADAPTER
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['vertica'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT table_schema, table_name FROM v_catalog.tables
            WHERE table_schema ]] .. schema_str

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        local upper_begin = case_insensitive and 'upper(' or ''
        local upper_end = case_insensitive and ')' or ''

        local schema_str = ''
        if string.match(schema_filt, '%%') then
            schema_str = [[LIKE '']] .. schema_filt .. [['']]
        else
            schema_str = [[IN ('']] .. schema_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local table_str = ''
        if string.match(table_filt, '%%') then
            table_str = [[LIKE '']] .. table_filt .. [['']]
        else
            table_str = [[IN ('']] .. table_filt:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*', "'',''") .. [['')]]
        end

        local query = [[
            SELECT
                table_schema, table_name, ordinal_position, column_name,
                data_type, character_maximum_length, numeric_precision, numeric_scale
            FROM v_catalog.columns
            WHERE table_schema ]] .. schema_str .. [[ AND table_name ]] .. table_str .. [[
            ORDER BY table_schema, table_name, ordinal_position
        ]]

        local success, res = pquery([[
            SELECT * FROM (IMPORT FROM JDBC AT ]] .. conn_name .. [[ STATEMENT ']] .. query .. [[')
        ]])

        return success and res or {}
    end,

    map_type = function(source_type_token)
        local mapping = {
            ['BIGINT'] = 'BIGINT',
            ['INTEGER'] = 'INTEGER',
            ['SMALLINT'] = 'SMALLINT',
            ['NUMERIC'] = 'DECIMAL(36,0)',
            ['DECIMAL'] = 'DECIMAL(36,0)',
            ['FLOAT'] = 'DOUBLE PRECISION',
            ['BOOLEAN'] = 'BOOLEAN',
            ['CHAR'] = 'CHAR(2000)',
            ['VARCHAR'] = 'VARCHAR(2000000)',
            ['DATE'] = 'DATE',
            ['TIME'] = 'TIMESTAMP',
            ['TIMESTAMP'] = 'TIMESTAMP',
            ['INTERVAL'] = 'VARCHAR(2000000)',
        }

        local mapped = mapping[source_type_token]
        if mapped then
            return mapped
        end

        return nil
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '"' .. final_name .. '"'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- S3 ADAPTER (Stub: notes that full S3 IMPORT FROM is out of scope)
-- ─────────────────────────────────────────────────────────────────
SOURCE_ADAPTERS['s3'] = {
    probe_tables = function(conn_type, conn_name, db_filt, schema_filt, case_insensitive)
        return {}
    end,

    probe_columns = function(conn_type, conn_name, db_filt, schema_filt, table_filt, case_insensitive)
        return {}
    end,

    map_type = function(source_type_token)
        return 'VARCHAR(2000000)'
    end,

    quote_identifier = function(name, case_insensitive)
        local final_name = name
        if case_insensitive then
            final_name = string.upper(name)
        end
        return '"' .. final_name .. '"'
    end
}

-- ─────────────────────────────────────────────────────────────────
-- VALIDATE source_type
-- ─────────────────────────────────────────────────────────────────

local adapter = SOURCE_ADAPTERS[source_type_lower]
if not adapter then
    local supported_types = {}
    for key in pairs(SOURCE_ADAPTERS) do
        table.insert(supported_types, key)
    end
    table.sort(supported_types)
    local error_msg = 'Unsupported source_type: ' .. source_type .. '. Supported types: ' .. table.concat(supported_types, ', ')
    return {
        {'VALIDATE', 'source_type', 0, 0, 'ERROR', NULL, error_msg}
    }, 'STEP_KIND VARCHAR(40), TARGET_OBJ VARCHAR(2000), ROWS_AFFECTED DECIMAL(18,0), ELAPSED_MS DECIMAL(18,0), RESULT_FLAG VARCHAR(20), SQL_TEXT VARCHAR(2000000), ERROR_MESSAGE VARCHAR(20000)'
end

-- ─────────────────────────────────────────────────────────────────
-- ORCHESTRATOR: Run probes, emit plan rows, execute if not DEBUG
-- ─────────────────────────────────────────────────────────────────

local result_rows = {}
local total_rows_affected = 0
local had_error = false

-- Normalize filter arguments
if not db_filter or db_filter == '' then
    db_filter = '%'
end
if not schema_filter or schema_filter == '' then
    schema_filter = '%'
end
if not table_filter or table_filter == '' then
    table_filter = '%'
end

-- Probe tables
local probe_tables_result = adapter.probe_tables(source_type_lower, connection_name, db_filter, schema_filter, identifier_case_insensitive)

-- If empty probe result, emit CREATE_SCHEMA and SUMMARY only
if not probe_tables_result or #probe_tables_result == 0 then
    table.insert(result_rows, {
        'CREATE_SCHEMA',
        target_schema or 'DEFAULT',
        0,
        0,
        debug and 'PREVIEW' or 'SKIPPED',
        NULL,
        NULL
    })
    table.insert(result_rows, {
        'SUMMARY',
        'No tables matched filters',
        0,
        0,
        'OK',
        NULL,
        NULL
    })
    return result_rows, 'STEP_KIND VARCHAR(40), TARGET_OBJ VARCHAR(2000), ROWS_AFFECTED DECIMAL(18,0), ELAPSED_MS DECIMAL(18,0), RESULT_FLAG VARCHAR(20), SQL_TEXT VARCHAR(2000000), ERROR_MESSAGE VARCHAR(20000)'
end

-- Emit CREATE_SCHEMA row
table.insert(result_rows, {
    'CREATE_SCHEMA',
    target_schema or (probe_tables_result[1] and probe_tables_result[1][1]) or 'DEFAULT',
    0,
    0,
    debug and 'PREVIEW' or 'OK',
    NULL,
    NULL
})

-- Build map of tables for probe
local tables_by_key = {}
local probe_columns_result = adapter.probe_columns(source_type_lower, connection_name, db_filter, schema_filter, table_filter, identifier_case_insensitive)

for _, col_row in ipairs(probe_columns_result or {}) do
    local db_name = col_row.DB_NAME or col_row[1] or ''
    local schema_name = col_row.SCHEMA_NAME or col_row[2] or ''
    local table_name = col_row.TABLE_NAME or col_row[3] or ''
    local col_key = db_name .. '.' .. schema_name .. '.' .. table_name

    if not tables_by_key[col_key] then
        tables_by_key[col_key] = {db_name, schema_name, table_name, {}}
    end
    table.insert(tables_by_key[col_key][4], col_row)
end

-- Emit (and in EXECUTE mode, run) CREATE_TABLE + IMPORT for each table
local mapped_unmapped_warning = {}
local tables_count = 0
local tables_created = 0
local total_rows_affected = 0
local had_error = false

for col_key, table_info in pairs(tables_by_key) do
    tables_count = tables_count + 1
    local db_name = table_info[1]
    local schema_name = table_info[2]
    local table_name = table_info[3]
    local columns = table_info[4]
    local target_table = adapter.quote_identifier(target_schema or schema_name, identifier_case_insensitive) .. '.' .. adapter.quote_identifier(table_name, identifier_case_insensitive)

    -- Build CREATE TABLE
    local col_defs = {}
    local select_cols = {}
    local source_cols = {}
    for _, col_row in ipairs(columns) do
        local col_name = col_row.COLUMN_NAME or col_row.column_name or col_row[5] or ''
        local source_col = col_row.SOURCE_COLUMN_NAME or col_row.source_column_name or col_row[6] or col_name
        local data_type = col_row.DATA_TYPE or col_row.data_type or col_row[12] or ''
        local precision = tonumber(col_row.PRECISION or col_row.precision or col_row[8])
        local scale = tonumber(col_row.SCALE or col_row.scale or col_row[9])
        local max_len = tonumber(col_row.COL_MAX_LENGTH or col_row.col_max_length or col_row[7])

        local target_type = adapter.map_type(data_type, precision, scale, max_len)
        if not target_type then
            target_type = 'VARCHAR(2000000)'
            table.insert(mapped_unmapped_warning, data_type .. ' (' .. table_name .. '.' .. col_name .. ')')
        end

        table.insert(col_defs, adapter.quote_identifier(col_name, identifier_case_insensitive) .. ' ' .. target_type)
        table.insert(select_cols, '"' .. source_col .. '"')
        table.insert(source_cols, adapter.quote_identifier(col_name, identifier_case_insensitive))
    end
    local create_sql = 'CREATE OR REPLACE TABLE ' .. target_table .. ' (' .. table.concat(col_defs, ', ') .. ')'

    local create_flag = debug and 'PREVIEW' or 'OK'
    local create_err = NULL
    local create_elapsed = 0
    if not debug then
        local t0 = os.clock()
        local create_ok, create_res = pquery(create_sql)
        create_elapsed = math.floor((os.clock() - t0) * 1000)
        if not create_ok then
            create_flag = 'ERROR'
            create_err = create_res.error_message or 'CREATE TABLE failed'
            had_error = true
        else
            tables_created = tables_created + 1
        end
    end

    table.insert(result_rows, {
        'CREATE_TABLE',
        (target_schema or schema_name) .. '.' .. table_name,
        0,
        create_elapsed,
        create_flag,
        create_sql,
        create_err
    })

    if #mapped_unmapped_warning > 0 then
        for _, warn_msg in ipairs(mapped_unmapped_warning) do
            table.insert(result_rows, {
                'INFO',
                (target_schema or schema_name) .. '.' .. table_name,
                0, 0, 'OK', NULL,
                'Unmapped source type: ' .. warn_msg
            })
        end
        mapped_unmapped_warning = {}
    end

    -- Build IMPORT — fully-qualified Snowflake source, projected via SELECT
    local select_stmt = 'SELECT ' .. table.concat(select_cols, ', ') .. ' FROM "' .. db_name .. '"."' .. schema_name .. '"."' .. table_name .. '"'
    local import_sql = 'IMPORT INTO ' .. target_table .. ' (' .. table.concat(source_cols, ', ') .. ') FROM JDBC AT ' .. connection_name .. " STATEMENT '" .. select_stmt:gsub("'", "''") .. "'"

    local import_flag = debug and 'PREVIEW' or 'OK'
    local import_err = NULL
    local import_elapsed = 0
    local import_rows = 0
    if not debug and create_flag ~= 'ERROR' then
        local t0 = os.clock()
        local import_ok, import_res = pquery(import_sql)
        import_elapsed = math.floor((os.clock() - t0) * 1000)
        if not import_ok then
            import_flag = 'ERROR'
            import_err = import_res.error_message or 'IMPORT failed'
            had_error = true
        else
            import_rows = tonumber(import_res.rows_affected or 0) or 0
            total_rows_affected = total_rows_affected + import_rows
        end
    elseif create_flag == 'ERROR' then
        import_flag = 'SKIPPED'
        import_err = 'Upstream CREATE_TABLE failed'
    end

    table.insert(result_rows, {
        'IMPORT',
        (target_schema or schema_name) .. '.' .. table_name,
        import_rows,
        import_elapsed,
        import_flag,
        import_sql,
        import_err
    })
end

-- Emit SUMMARY row
local summary_flag = debug and 'PREVIEW' or (had_error and 'ERROR' or 'OK')
local summary_obj
if debug then
    summary_obj = 'Plan: ' .. tostring(tables_count) .. ' tables'
else
    summary_obj = 'Completed: ' .. tostring(tables_created) .. '/' .. tostring(tables_count) .. ' tables, ' .. tostring(total_rows_affected) .. ' rows'
end

table.insert(result_rows, {
    'SUMMARY',
    summary_obj,
    total_rows_affected,
    0,
    summary_flag,
    NULL,
    NULL
})

return result_rows, 'STEP_KIND VARCHAR(40), TARGET_OBJ VARCHAR(2000), ROWS_AFFECTED DECIMAL(18,0), ELAPSED_MS DECIMAL(18,0), RESULT_FLAG VARCHAR(20), SQL_TEXT VARCHAR(2000000), ERROR_MESSAGE VARCHAR(20000)'
/
