--[[
  Checks for dremio_to_exasol.sql.

  Run: lua test/test_dremio_to_exasol.lua
]]

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " -- " .. tostring(err))
    end
end

local function assert_contains(actual, pattern, msg)
    if not tostring(actual):find(pattern, 1, true) then
        error((msg or "missing expected text") .. ": " .. pattern .. " in " .. tostring(actual))
    end
end

local function read_file(path)
    local f = io.open(path, "r")
    assert(f, "Could not open " .. path)
    local content = f:read("*a")
    f:close()
    return content
end

local function extract_lua_block(path)
    local content = read_file(path)
    local lua_block = content:match("%) RETURNS TABLE%s*\nAS\n(.-)\n/\n")
    assert(lua_block, "Could not extract Lua block from " .. path)
    return lua_block
end

local dr_lua = extract_lua_block("dremio_to_exasol.sql")

local function run_dremio(overrides)
    overrides = overrides or {}
    local calls = {}
    local env = {
        CONNECTION_NAME = overrides.connection or "DREMIO_CONN",
        IDENTIFIER_CASE_INSENSITIVE = overrides.case == nil and true or overrides.case,
        DB_FILTER = overrides.db or "@dremio",
        SCHEMA_FILTER = overrides.schema or "smoke",
        TABLE_FILTER = overrides.table or "smoke",
        string = string,
        table = table,
        tostring = tostring,
        type = type,
        error = error,
    }
    env.pquery = function(sql)
        calls[#calls + 1] = sql
        return true, {{SQL_TEXT = "-- ### SCHEMAS ###"}}
    end
    local fn, err = load(dr_lua, "dremio_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))
    local rows = fn()
    return {rows = rows, sql = calls[1], calls = calls}
end

print("=== Lua Syntax Validation ===")

test("Lua block in dremio_to_exasol.sql has valid syntax", function()
    local fn, err = load(dr_lua)
    assert(fn, "Lua syntax error in dremio_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== Generation Tests ===")

test("interpolates connection + source + filters into generated SQL", function()
    local r = run_dremio({
        connection = "DREMIO_JDBC",
        db = "samples",
        schema = "tpch",
        table = "lineitem",
    })
    assert_contains(r.sql, "import from jdbc at DREMIO_JDBC statement")
    assert_contains(r.sql, "TABLE_SCHEMA = ''samples''")
    assert_contains(r.sql, "TABLE_SCHEMA LIKE ''samples.%''")
    assert_contains(r.sql, "TABLE_SCHEMA like ''%tpch%''")
    assert_contains(r.sql, "TABLE_NAME like ''lineitem''")
end)

test("aliases ANSI info_schema columns with quoted uppercase identifiers", function()
    local r = run_dremio()
    assert_contains(r.sql, '"TABLE_CATALOG"')
    assert_contains(r.sql, '"TABLE_SCHEMA"')
    assert_contains(r.sql, '"COLUMN_NAME"')
    assert_contains(r.sql, '"DATA_TYPE"')
    assert_contains(r.sql, '"NOT_NULL_CONSTRAINT"')
end)

test("excludes INFORMATION_SCHEMA + sys from source schemas", function()
    local r = run_dremio()
    assert_contains(r.sql, "''INFORMATION_SCHEMA''")
    assert_contains(r.sql, "''sys''")
end)

test("derives base_type by stripping parens and uppercasing", function()
    local r = run_dremio()
    assert_contains(r.sql, "upper(regexp_replace(data_type, '\\(.*?\\)', ''))")
end)

test("DB_FILTER missing raises a descriptive error", function()
    local calls = {}
    local env = {
        CONNECTION_NAME = "CONN",
        IDENTIFIER_CASE_INSENSITIVE = true,
        DB_FILTER = "%",
        SCHEMA_FILTER = "%",
        TABLE_FILTER = "%",
        string = string, table = table, tostring = tostring, type = type, error = error,
    }
    env.pquery = function(sql) calls[#calls + 1] = sql; return true, {} end
    local fn, err = load(dr_lua, "dremio_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise when DB_FILTER is missing")
    assert_contains(perr, "DB_FILTER is required for DREMIO")
end)

test("integer family maps to DECIMAL widths matching Arrow ranges", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'TINYINT'")
    assert_contains(r.sql, "'DECIMAL(3,0) '")
    assert_contains(r.sql, "base_type = 'SMALLINT'")
    assert_contains(r.sql, "'DECIMAL(5,0) '")
    assert_contains(r.sql, "base_type = 'INTEGER'")
    assert_contains(r.sql, "'DECIMAL(11,0) '")
    assert_contains(r.sql, "base_type = 'BIGINT'")
    assert_contains(r.sql, "'DECIMAL(19,0) '")
end)

test("decimal precision/scale parsed from data_type via regexp_substr with cap at 36", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'DECIMAL'")
    assert_contains(r.sql, "regexp_substr(data_type, '\\d+', 1, 1)")
    assert_contains(r.sql, "regexp_substr(data_type, '\\d+', 1, 2)")
    assert_contains(r.sql, "type_param_1 <= 36 then type_param_1")
    assert_contains(r.sql, "type_param_1 > 36 then 36")
end)

test("float/real → FLOAT, double → DOUBLE", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'FLOAT'")
    assert_contains(r.sql, "base_type = 'REAL'")
    assert_contains(r.sql, "'FLOAT '")
    assert_contains(r.sql, "base_type = 'DOUBLE'")
    assert_contains(r.sql, "'DOUBLE '")
end)

test("date → DATE, timestamp → TIMESTAMP, time → VARCHAR(20)", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'DATE'")
    assert_contains(r.sql, "'DATE '")
    assert_contains(r.sql, "base_type = 'TIMESTAMP'")
    assert_contains(r.sql, "'TIMESTAMP '")
    assert_contains(r.sql, "base_type = 'TIME'")
    assert_contains(r.sql, "'VARCHAR(20) '")
end)

test("intervals (all variants) → VARCHAR(50)", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'INTERVAL'")
    assert_contains(r.sql, "base_type = 'INTERVAL DAY'")
    assert_contains(r.sql, "base_type = 'INTERVAL YEAR'")
    assert_contains(r.sql, "base_type = 'INTERVAL DAY TO SECOND'")
    assert_contains(r.sql, "base_type = 'INTERVAL YEAR TO MONTH'")
    assert_contains(r.sql, "'VARCHAR(50) '")
end)

test("varchar width parsed from data_type with 2M cap; unsized → 2M", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'VARCHAR'")
    assert_contains(r.sql, "type_param_1 is null then 2000000")
    assert_contains(r.sql, "type_param_1 > 2000000 then 2000000")
end)

test("LIST/STRUCT/MAP/ROW/ARRAY → VARCHAR(2000000)", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'LIST'")
    assert_contains(r.sql, "base_type = 'STRUCT'")
    assert_contains(r.sql, "base_type = 'MAP'")
    assert_contains(r.sql, "base_type = 'ROW'")
    assert_contains(r.sql, "base_type = 'ARRAY'")
end)

test("BINARY family → VARCHAR(2000000)", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'BINARY'")
    assert_contains(r.sql, "base_type = 'VARBINARY'")
    assert_contains(r.sql, "base_type = 'BINARY VARYING'")
end)

test("IMPORT SELECT uses CONVERT_TO(...,'JSON') for complex/binary types", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type in ('LIST','ARRAY','STRUCT','ROW','MAP','ANY','MIXED')")
    assert_contains(r.sql, "CONVERT_TO(\"' || column_name || '\", ''JSON'')")
    assert_contains(r.sql, "base_type in ('BINARY','VARBINARY','BINARY VARYING')")
end)

test("IMPORT SELECT casts TIME and INTERVAL family to VARCHAR on source side", function()
    local r = run_dremio()
    assert_contains(r.sql, "base_type = 'TIME' then 'CAST(\"' || column_name || '\" AS VARCHAR)'")
    assert_contains(r.sql, "base_type like 'INTERVAL%' then 'CAST(\"' || column_name || '\" AS VARCHAR)'")
end)

test("uses double-quote quoting for Dremio source identifiers", function()
    local r = run_dremio()
    assert_contains(r.sql, "from \"' || table_schema || '\".\"' || table_name || '\"")
end)

test("emits UNKNOWN_DATATYPE comment for unrecognized types", function()
    local r = run_dremio()
    assert_contains(r.sql, "--UNKNOWN_DATATYPE:")
end)

test("error surfaces failed query via res.error_message", function()
    local calls = {}
    local env = {
        CONNECTION_NAME = "CONN",
        IDENTIFIER_CASE_INSENSITIVE = true,
        DB_FILTER = "@dremio",
        SCHEMA_FILTER = "%",
        TABLE_FILTER = "%",
        string = string, table = table, tostring = tostring, type = type, error = error,
    }
    env.pquery = function(sql)
        calls[#calls + 1] = sql
        return false, {
            error_message = "PERMISSION ERROR: User does not have access",
            statement_text = "select ...",
        }
    end
    local fn, err = load(dr_lua, "dremio_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise on pquery failure")
    assert_contains(perr, "PERMISSION ERROR")
    assert_contains(perr, "Caught while executing:")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
