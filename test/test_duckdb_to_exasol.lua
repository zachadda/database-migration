--[[
  Checks for duckdb_to_exasol.sql.

  Run: lua test/test_duckdb_to_exasol.lua
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

local duckdb_lua = extract_lua_block("duckdb_to_exasol.sql")

local function run_duckdb(overrides)
    overrides = overrides or {}
    local calls = {}
    local env = {
        CONNECTION_NAME = overrides.connection or "DUCKDB_CONNECTION",
        IDENTIFIER_CASE_INSENSITIVE = overrides.case == nil and true or overrides.case,
        SCHEMA_FILTER = overrides.schema or "main",
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

    local fn, err = load(duckdb_lua, "duckdb_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))

    local result_rows = fn()
    return {
        rows = result_rows,
        sql = calls[1],
        calls = calls,
    }
end

print("=== Lua Syntax Validation ===")

test("Lua block in duckdb_to_exasol.sql has valid syntax", function()
    local fn, err = load(duckdb_lua)
    assert(fn, "Lua syntax error in duckdb_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== Generation Tests ===")

test("interpolates connection + filters into generated SQL", function()
    local r = run_duckdb({
        connection = "DUCKDB_FILE_JDBC",
        schema = "main",
        table = "fact_sales",
    })
    assert_contains(r.sql, "import from jdbc at DUCKDB_FILE_JDBC statement")
    assert_contains(r.sql, "table_schema like ''main''")
    assert_contains(r.sql, "table_name like ''fact_sales''")
end)

test("emits upper() wrapping when IDENTIFIER_CASE_INSENSITIVE=true", function()
    local r = run_duckdb({case = true})
    assert_contains(r.sql, 'upper(table_schema)')
    assert_contains(r.sql, 'upper(column_name)')
end)

test("omits upper() wrapping when IDENTIFIER_CASE_INSENSITIVE=false", function()
    local r = run_duckdb({case = false})
    -- direct reference, no upper() wrapping
    assert_contains(r.sql, 'as "exa_table_schema"')
    if r.sql:find('upper%(table_schema%)') then
        error("upper() wrapper should not appear when case=false")
    end
end)

test("strips parameterized type names via regexp_replace before case branches", function()
    local r = run_duckdb()
    assert_contains(r.sql, "regexp_replace(data_type")
    assert_contains(r.sql, "as base_type")
end)

test("integer types map to DECIMAL widths", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'TINYINT'")
    assert_contains(r.sql, "'DECIMAL(4,0) '")
    assert_contains(r.sql, "base_type = 'INTEGER'")
    assert_contains(r.sql, "'DECIMAL(11,0) '")
    assert_contains(r.sql, "base_type = 'BIGINT'")
    assert_contains(r.sql, "'DECIMAL(19,0) '")
end)

test("HUGEINT and UHUGEINT map to VARCHAR(40)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'HUGEINT'")
    assert_contains(r.sql, "base_type = 'UHUGEINT'")
    -- the only VARCHAR(40) entries belong to HUGEINT/UHUGEINT/TIMESTAMP WITH TIME ZONE/TIMESTAMPTZ
    assert_contains(r.sql, "'VARCHAR(40) '")
end)

test("unsigned integers map to DECIMAL with correct width", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'UTINYINT'")
    assert_contains(r.sql, "'DECIMAL(3,0) '")
    assert_contains(r.sql, "base_type = 'UBIGINT'")
    assert_contains(r.sql, "'DECIMAL(20,0) '")
end)

test("DECIMAL caps precision at 36 to fit Exasol max", function()
    local r = run_duckdb()
    assert_contains(r.sql, "case when numeric_precision > 36 then 36 else numeric_precision end")
end)

test("TIMESTAMP maps to native TIMESTAMP; TIMESTAMP WITH TIME ZONE goes to VARCHAR", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'TIMESTAMP' ")
    assert_contains(r.sql, "'TIMESTAMP '")
    assert_contains(r.sql, "base_type = 'TIMESTAMP WITH TIME ZONE'")
    assert_contains(r.sql, "base_type = 'TIMESTAMPTZ'")
end)

test("complex types (LIST/STRUCT/MAP/UNION/ARRAY) map to VARCHAR(2000000)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'LIST'")
    assert_contains(r.sql, "base_type = 'STRUCT'")
    assert_contains(r.sql, "base_type = 'MAP'")
    assert_contains(r.sql, "base_type = 'UNION'")
    assert_contains(r.sql, "base_type = 'ARRAY'")
    assert_contains(r.sql, "'VARCHAR(2000000) '")
end)

test("UUID maps to VARCHAR(36)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'UUID'")
    assert_contains(r.sql, "'VARCHAR(36) '")
end)

test("INTERVAL maps to VARCHAR(50)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'INTERVAL'")
    assert_contains(r.sql, "'VARCHAR(50) '")
end)

test("BOOLEAN preserved", function()
    local r = run_duckdb()
    assert_contains(r.sql, "base_type = 'BOOLEAN'")
    assert_contains(r.sql, "'BOOLEAN '")
end)

test("IMPORT SELECT casts HUGEINT/UHUGEINT to VARCHAR(40)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "cast(\"' || column_name || '\" as VARCHAR(40))")
end)

test("IMPORT SELECT serializes complex types via to_json", function()
    local r = run_duckdb()
    assert_contains(r.sql, "to_json(\"' || column_name || '\")")
end)

test("IMPORT SELECT casts TIME to VARCHAR(15) and INTERVAL to VARCHAR(50)", function()
    local r = run_duckdb()
    assert_contains(r.sql, "cast(\"' || column_name || '\" as VARCHAR(15))")
    assert_contains(r.sql, "cast(\"' || column_name || '\" as VARCHAR(50))")
end)

test("excludes information_schema, pg_catalog, system schemas", function()
    local r = run_duckdb()
    assert_contains(r.sql, "table_schema not in (''information_schema'',''pg_catalog''")
end)

test("emits UNKNOWN_DATATYPE comment for unrecognized types", function()
    local r = run_duckdb()
    assert_contains(r.sql, "--UNKNOWN_DATATYPE:")
end)

test("error surfaces failed query via res.error_message", function()
    -- simulate pquery returning failure
    local calls = {}
    local env = {
        CONNECTION_NAME = "CONN",
        IDENTIFIER_CASE_INSENSITIVE = true,
        SCHEMA_FILTER = "%",
        TABLE_FILTER = "%",
        string = string, table = table, tostring = tostring, type = type, error = error,
    }
    env.pquery = function(sql)
        calls[#calls + 1] = sql
        return false, {
            error_message = "permission denied on table sys.columns",
            statement_text = "select ...",
        }
    end
    local fn, err = load(duckdb_lua, "duckdb_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise on pquery failure")
    assert_contains(perr, "permission denied on table sys.columns")
    assert_contains(perr, "Caught while executing:")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
