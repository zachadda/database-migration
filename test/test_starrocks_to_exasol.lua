--[[
  Checks for starrocks_to_exasol.sql.

  Run: lua test/test_starrocks_to_exasol.lua
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

local sr_lua = extract_lua_block("starrocks_to_exasol.sql")

local function run_starrocks(overrides)
    overrides = overrides or {}
    local calls = {}
    local env = {
        CONNECTION_NAME = overrides.connection or "STARROCKS_CONNECTION",
        IDENTIFIER_CASE_INSENSITIVE = overrides.case == nil and true or overrides.case,
        SCHEMA_FILTER = overrides.schema or "smokedb",
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

    local fn, err = load(sr_lua, "starrocks_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))

    local result_rows = fn()
    return {
        rows = result_rows,
        sql = calls[1],
        calls = calls,
    }
end

print("=== Lua Syntax Validation ===")

test("Lua block in starrocks_to_exasol.sql has valid syntax", function()
    local fn, err = load(sr_lua)
    assert(fn, "Lua syntax error in starrocks_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== Generation Tests ===")

test("interpolates connection + filters into generated SQL", function()
    local r = run_starrocks({
        connection = "SR_JDBC",
        schema = "smokedb",
        table = "fact_sales",
    })
    assert_contains(r.sql, "import from jdbc at SR_JDBC statement")
    assert_contains(r.sql, "table_schema like ''smokedb''")
    assert_contains(r.sql, "table_name like ''fact_sales''")
end)

test("excludes information_schema, _statistics_, sys schemas", function()
    local r = run_starrocks()
    assert_contains(r.sql, "''information_schema''")
    assert_contains(r.sql, "''_statistics_''")
    assert_contains(r.sql, "''sys''")
end)

test("emits upper() wrapping when IDENTIFIER_CASE_INSENSITIVE=true", function()
    local r = run_starrocks({case = true})
    assert_contains(r.sql, 'upper(table_schema)')
    assert_contains(r.sql, 'upper(column_name)')
end)

test("LARGEINT maps to VARCHAR(40) on CREATE TABLE side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'LARGEINT'")
    assert_contains(r.sql, "'VARCHAR(40) '")
end)

test("LARGEINT cast to VARCHAR(40) on IMPORT SELECT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "cast(`' || column_name || '` as VARCHAR(40))")
end)

test("integer types map to DECIMAL widths", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'TINYINT'")
    assert_contains(r.sql, "'DECIMAL(4,0) '")
    assert_contains(r.sql, "upper(data_type) = 'INT'")
    assert_contains(r.sql, "'DECIMAL(11,0) '")
    assert_contains(r.sql, "upper(data_type) = 'BIGINT'")
    assert_contains(r.sql, "'DECIMAL(19,0) '")
end)

test("DECIMAL64 / DECIMAL128 fall back to DECIMAL with capped precision", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'DECIMAL64'")
    assert_contains(r.sql, "upper(data_type) = 'DECIMAL128'")
    assert_contains(r.sql, "case when numeric_precision > 36 then 36 else numeric_precision end")
end)

test("DATETIME maps to TIMESTAMP", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'DATETIME'")
    assert_contains(r.sql, "'TIMESTAMP '")
end)

test("BOOLEAN preserved", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'BOOLEAN'")
    assert_contains(r.sql, "'BOOLEAN '")
end)

test("STRING/TEXT map to VARCHAR(2000000)", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'STRING'")
    assert_contains(r.sql, "upper(data_type) = 'TEXT'")
    assert_contains(r.sql, "'VARCHAR(2000000) '")
end)

test("BITMAP / HLL / PERCENTILE map to VARCHAR(2000000) on CREATE TABLE side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'BITMAP'")
    assert_contains(r.sql, "upper(data_type) = 'HLL'")
    assert_contains(r.sql, "upper(data_type) = 'PERCENTILE'")
end)

test("BITMAP serialized via bitmap_to_string on IMPORT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "bitmap_to_string(`")
end)

test("HLL serialized via hll_to_string on IMPORT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "hll_to_string(`")
end)

test("ARRAY / MAP / STRUCT cast to JSON on IMPORT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'ARRAY'")
    assert_contains(r.sql, "upper(data_type) = 'MAP'")
    assert_contains(r.sql, "upper(data_type) = 'STRUCT'")
    assert_contains(r.sql, "cast(`' || column_name || '` as JSON)")
end)

test("JSON type pass-through cast to VARCHAR on IMPORT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "upper(data_type) = 'JSON'")
    assert_contains(r.sql, "cast(`' || column_name || '` as VARCHAR)")
end)

test("BINARY / VARBINARY hex-encoded on IMPORT side", function()
    local r = run_starrocks()
    assert_contains(r.sql, "hex(`' || column_name || '`)")
end)

test("uses MySQL-style backtick quoting for source identifiers", function()
    local r = run_starrocks()
    assert_contains(r.sql, "from `' || table_schema || '`.`' || table_name || '`")
end)

test("emits UNKNOWN_DATATYPE comment for unrecognized types", function()
    local r = run_starrocks()
    assert_contains(r.sql, "--UNKNOWN_DATATYPE:")
end)

test("error surfaces failed query via res.error_message", function()
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
            error_message = "Access denied for user 'demo'@'localhost'",
            statement_text = "select ...",
        }
    end
    local fn, err = load(sr_lua, "starrocks_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise on pquery failure")
    assert_contains(perr, "Access denied for user 'demo'@'localhost'")
    assert_contains(perr, "Caught while executing:")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
