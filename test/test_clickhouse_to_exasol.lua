--[[
  Checks for clickhouse_to_exasol.sql.

  Run: lua test/test_clickhouse_to_exasol.lua
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

local ch_lua = extract_lua_block("clickhouse_to_exasol.sql")

local function run_clickhouse(overrides)
    overrides = overrides or {}
    local calls = {}
    local env = {
        CONNECTION_NAME = overrides.connection or "CLICKHOUSE_CONN",
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
    local fn, err = load(ch_lua, "clickhouse_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))
    local rows = fn()
    return {rows = rows, sql = calls[1], calls = calls}
end

print("=== Lua Syntax Validation ===")

test("Lua block in clickhouse_to_exasol.sql has valid syntax", function()
    local fn, err = load(ch_lua)
    assert(fn, "Lua syntax error in clickhouse_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== Generation Tests ===")

test("interpolates connection + filters into generated SQL", function()
    local r = run_clickhouse({
        connection = "CH_JDBC",
        schema = "smokedb",
        table = "fact_sales",
    })
    assert_contains(r.sql, "import from jdbc at CH_JDBC statement")
    assert_contains(r.sql, "table_schema like ''smokedb''")
    assert_contains(r.sql, "table_name like ''fact_sales''")
end)

test("aliases ANSI info_schema columns with quoted uppercase identifiers", function()
    local r = run_clickhouse()
    assert_contains(r.sql, '"TABLE_CATALOG"')
    assert_contains(r.sql, '"TABLE_SCHEMA"')
    assert_contains(r.sql, '"COLUMN_NAME"')
    assert_contains(r.sql, '"DATA_TYPE"')
    assert_contains(r.sql, '"NOT_NULL_CONSTRAINT"')
end)

test("excludes system + INFORMATION_SCHEMA + information_schema", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "''system''")
    assert_contains(r.sql, "''INFORMATION_SCHEMA''")
    assert_contains(r.sql, "''information_schema''")
end)

test("strips LowCardinality and Nullable wrappers via regexp_replace", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "regexp_replace(data_type, '^LowCardinality\\(")
    assert_contains(r.sql, "'^Nullable\\(")
end)

test("Int128/Int256 → VARCHAR(40/80) on CREATE TABLE side", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'Int128'")
    assert_contains(r.sql, "inner_base_type = 'Int256'")
    assert_contains(r.sql, "'VARCHAR(40) '")
    assert_contains(r.sql, "'VARCHAR(80) '")
end)

test("UInt64 → DECIMAL(20,0) (fits in Exasol DECIMAL(36,0))", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'UInt64'")
    assert_contains(r.sql, "'DECIMAL(20,0) '")
end)

test("Decimal with precision cap at 36", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type like 'Decimal%'")
    assert_contains(r.sql, "numeric_precision <= 36 then numeric_precision")
    assert_contains(r.sql, "numeric_precision > 36 then 36")
end)

test("DateTime + DateTime64 map to TIMESTAMP", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'DateTime'")
    assert_contains(r.sql, "inner_base_type = 'DateTime64'")
    assert_contains(r.sql, "'TIMESTAMP '")
end)

test("UUID/IPv4/IPv6 explicit VARCHAR widths", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'UUID'")
    assert_contains(r.sql, "'VARCHAR(36) '")
    assert_contains(r.sql, "inner_base_type = 'IPv4'")
    assert_contains(r.sql, "'VARCHAR(15) '")
    assert_contains(r.sql, "inner_base_type = 'IPv6'")
    assert_contains(r.sql, "'VARCHAR(45) '")
end)

test("Array/Tuple/Map/Nested/Variant/JSON map to VARCHAR(2000000)", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'Array'")
    assert_contains(r.sql, "inner_base_type = 'Tuple'")
    assert_contains(r.sql, "inner_base_type = 'Map'")
    assert_contains(r.sql, "inner_base_type = 'Nested'")
    assert_contains(r.sql, "inner_base_type = 'Variant'")
    assert_contains(r.sql, "inner_base_type = 'JSON'")
    assert_contains(r.sql, "'VARCHAR(2000000) '")
end)

test("Enum8/Enum16 → VARCHAR(2000000)", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'Enum8'")
    assert_contains(r.sql, "inner_base_type = 'Enum16'")
end)

test("IMPORT SELECT casts Int128/256 / UInt128/256 to toString", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'Int128'  then 'toString")
    assert_contains(r.sql, "inner_base_type = 'UInt256' then 'toString")
end)

test("IMPORT SELECT casts UUID/IPv4/IPv6/Enum to toString", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'UUID'    then 'toString")
    assert_contains(r.sql, "inner_base_type = 'IPv4'    then 'toString")
    assert_contains(r.sql, "inner_base_type = 'Enum8'   then 'toString")
end)

test("IMPORT SELECT JSON-serializes complex types via toJSONString", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "inner_base_type = 'Array'   then 'toJSONString")
    assert_contains(r.sql, "inner_base_type = 'Map'     then 'toJSONString")
    assert_contains(r.sql, "inner_base_type = 'Tuple'   then 'toJSONString")
end)

test("uses backtick quoting for ClickHouse source identifiers", function()
    local r = run_clickhouse()
    assert_contains(r.sql, "from `' || table_schema || '`.`' || table_name || '`")
end)

test("emits UNKNOWN_DATATYPE comment for unrecognized types", function()
    local r = run_clickhouse()
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
            error_message = "Authentication failed: password is incorrect",
            statement_text = "select ...",
        }
    end
    local fn, err = load(ch_lua, "clickhouse_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise on pquery failure")
    assert_contains(perr, "Authentication failed: password is incorrect")
    assert_contains(perr, "Caught while executing:")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
