--[[
  Checks for trino_to_exasol.sql.

  Run: lua test/test_trino_to_exasol.lua
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

local tr_lua = extract_lua_block("trino_to_exasol.sql")

local function run_trino(overrides)
    overrides = overrides or {}
    local calls = {}
    local env = {
        CONNECTION_NAME = overrides.connection or "TRINO_CONN",
        IDENTIFIER_CASE_INSENSITIVE = overrides.case == nil and true or overrides.case,
        DB_FILTER = overrides.db or "memory",
        SCHEMA_FILTER = overrides.schema or "default",
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
    local fn, err = load(tr_lua, "trino_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))
    local rows = fn()
    return {rows = rows, sql = calls[1], calls = calls}
end

print("=== Lua Syntax Validation ===")

test("Lua block in trino_to_exasol.sql has valid syntax", function()
    local fn, err = load(tr_lua)
    assert(fn, "Lua syntax error in trino_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== Generation Tests ===")

test("interpolates connection + catalog + filters into generated SQL", function()
    local r = run_trino({
        connection = "TRINO_JDBC",
        db = "mysql_prod",
        schema = "sales",
        table = "fact_orders",
    })
    assert_contains(r.sql, "import from jdbc at TRINO_JDBC statement")
    assert_contains(r.sql, '"mysql_prod".information_schema.columns')
    assert_contains(r.sql, "table_schema like ''sales''")
    assert_contains(r.sql, "table_name like ''fact_orders''")
end)

test("aliases ANSI info_schema columns with quoted uppercase identifiers", function()
    local r = run_trino()
    assert_contains(r.sql, '"TABLE_CATALOG"')
    assert_contains(r.sql, '"TABLE_SCHEMA"')
    assert_contains(r.sql, '"COLUMN_NAME"')
    assert_contains(r.sql, '"DATA_TYPE"')
    assert_contains(r.sql, '"NOT_NULL_CONSTRAINT"')
end)

test("excludes information_schema from source schemas", function()
    local r = run_trino()
    assert_contains(r.sql, "''information_schema''")
end)

test("derives base_type by stripping parens + time-zone modifier", function()
    local r = run_trino()
    assert_contains(r.sql, "regexp_replace(data_type, '\\(.*?\\)', '')")
    assert_contains(r.sql, "'\\s+with\\s+time\\s+zone$'")
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
    local fn, err = load(tr_lua, "trino_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise when DB_FILTER is missing")
    assert_contains(perr, "DB_FILTER is required for TRINO")
end)

test("integer family maps to DECIMAL with width matching range", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'tinyint'")
    assert_contains(r.sql, "'DECIMAL(3,0) '")
    assert_contains(r.sql, "base_type = 'smallint'")
    assert_contains(r.sql, "'DECIMAL(5,0) '")
    assert_contains(r.sql, "base_type = 'integer'")
    assert_contains(r.sql, "'DECIMAL(10,0) '")
    assert_contains(r.sql, "base_type = 'bigint'")
    assert_contains(r.sql, "'DECIMAL(19,0) '")
end)

test("decimal precision/scale parsed from data_type via regexp_substr with cap at 36", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'decimal'")
    assert_contains(r.sql, "regexp_substr(data_type, '\\d+', 1, 1)")
    assert_contains(r.sql, "regexp_substr(data_type, '\\d+', 1, 2)")
    assert_contains(r.sql, "type_param_1 <= 36 then type_param_1")
    assert_contains(r.sql, "type_param_1 > 36 then 36")
end)

test("real → FLOAT, double → DOUBLE", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'real'")
    assert_contains(r.sql, "'FLOAT '")
    assert_contains(r.sql, "base_type = 'double'")
    assert_contains(r.sql, "'DOUBLE '")
end)

test("date → DATE, timestamp → TIMESTAMP, time → VARCHAR(20)", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'date'")
    assert_contains(r.sql, "'DATE '")
    assert_contains(r.sql, "base_type = 'timestamp'")
    assert_contains(r.sql, "'TIMESTAMP '")
    assert_contains(r.sql, "base_type = 'time'")
    assert_contains(r.sql, "'VARCHAR(20) '")
end)

test("intervals → VARCHAR(50)", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'interval day to second'")
    assert_contains(r.sql, "base_type = 'interval year to month'")
    assert_contains(r.sql, "'VARCHAR(50) '")
end)

test("varchar width parsed from data_type with 2M cap; unsized → 2M", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'varchar'")
    assert_contains(r.sql, "type_param_1 is null then 2000000")
    assert_contains(r.sql, "type_param_1 > 2000000 then 2000000")
end)

test("uuid/ipaddress explicit VARCHAR widths", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'uuid'")
    assert_contains(r.sql, "'VARCHAR(36) '")
    assert_contains(r.sql, "base_type = 'ipaddress'")
    assert_contains(r.sql, "'VARCHAR(45) '")
end)

test("array/map/row/json → VARCHAR(2000000)", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'array'")
    assert_contains(r.sql, "base_type = 'map'")
    assert_contains(r.sql, "base_type = 'row'")
    assert_contains(r.sql, "base_type = 'json'")
end)

test("sketch types hyperloglog/qdigest/tdigest → VARCHAR(2000000)", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'hyperloglog'")
    assert_contains(r.sql, "base_type = 'qdigest'")
    assert_contains(r.sql, "base_type = 'tdigest'")
end)

test("IMPORT SELECT CASTs complex/identifier/sketch types to VARCHAR on source side", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'array' then 'CAST(\"' || column_name || '\" AS VARCHAR)'")
    assert_contains(r.sql, "base_type = 'uuid'      then 'CAST(\"' || column_name || '\" AS VARCHAR)'")
    assert_contains(r.sql, "base_type = 'hyperloglog' then 'CAST(\"' || column_name || '\" AS VARCHAR)'")
end)

test("IMPORT SELECT to_hex casts varbinary on source side", function()
    local r = run_trino()
    assert_contains(r.sql, "base_type = 'varbinary' then 'to_hex(\"' || column_name || '\")'")
end)

test("uses double-quote quoting for Trino source identifiers (catalog.schema.table)", function()
    local r = run_trino({ db = "mysql_prod" })
    assert_contains(r.sql, "from \"mysql_prod\".\"' || table_schema || '\".\"' || table_name || '\"")
end)

test("emits UNKNOWN_DATATYPE comment for unrecognized types", function()
    local r = run_trino()
    assert_contains(r.sql, "--UNKNOWN_DATATYPE:")
end)

test("error surfaces failed query via res.error_message", function()
    local calls = {}
    local env = {
        CONNECTION_NAME = "CONN",
        IDENTIFIER_CASE_INSENSITIVE = true,
        DB_FILTER = "memory",
        SCHEMA_FILTER = "%",
        TABLE_FILTER = "%",
        string = string, table = table, tostring = tostring, type = type, error = error,
    }
    env.pquery = function(sql)
        calls[#calls + 1] = sql
        return false, {
            error_message = "Catalog 'bogus' not found",
            statement_text = "select ...",
        }
    end
    local fn, err = load(tr_lua, "trino_to_exasol.lua", "t", env)
    assert(fn, "load: " .. tostring(err))
    local ok, perr = pcall(fn)
    assert(not ok, "expected adapter to raise on pquery failure")
    assert_contains(perr, "Catalog 'bogus' not found")
    assert_contains(perr, "Caught while executing:")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
