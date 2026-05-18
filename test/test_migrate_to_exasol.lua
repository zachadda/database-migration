--[[
  Checks for migrate_to_exasol.sql.

  Run: lua test/test_migrate_to_exasol.lua
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

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
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

local migrate_lua = extract_lua_block("migrate_to_exasol.sql")

local function run_migrate(params)
    local calls = {}
    local adapter_rows = params.adapter_rows or {{SQL_TEXT = "select 1"}}
    local execute_results = params.execute_results or {}

    local env = {
        SOURCE_TYPE = params.source_type,
        CONNECTION_NAME = params.connection_name or "SRC_CONN",
        CONNECTION_TYPE = params.connection_type,
        DB_FILTER = params.db_filter,
        SCHEMA_FILTER = params.schema_filter,
        TABLE_FILTER = params.table_filter,
        TARGET_SCHEMA = params.target_schema,
        IDENTIFIER_CASE_INSENSITIVE = params.identifier_case_insensitive,
        DEBUG = params.debug,
        OPTIONS = params.options,
        string = string,
        table = table,
        math = math,
        os = os,
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        error = error,
        ipairs = ipairs,
        pairs = pairs,
        pcall = pcall,
        select = select,
    }

    local execute_call_index = 0
    env.pquery = function(sql)
        calls[#calls + 1] = sql
        if #calls == 1 then
            if params.adapter_error then
                return false, {
                    error_message = params.adapter_error,
                    statement_text = sql,
                }
            end
            return true, adapter_rows
        end

        if sql:find("import into (src_schema", 1, true) then
            if params.gate_lookup_error then
                return false, {error_message = params.gate_lookup_error}
            end
            return true, params.gate_lookup_rows or {}
        end

        execute_call_index = execute_call_index + 1
        local result = execute_results[execute_call_index]
        if result and result.success == false then
            return false, {error_message = result.error_message or "execution failed"}
        end
        local affected = (result and result.rows_affected) or 0
        return true, {rows_affected = affected}
    end

    local fn, err = load(migrate_lua, "migrate_to_exasol.lua", "t", env)
    assert(fn, "Lua load failed: " .. tostring(err))

    local rows, columns = fn()
    return {
        rows = rows,
        columns = columns,
        calls = calls,
        adapter_sql = calls[1],
    }
end

local AUDIT_COLUMNS = "STEP_KIND VARCHAR(40), TARGET_OBJ VARCHAR(2000), ROWS_AFFECTED DECIMAL(18,0), ELAPSED_MS DECIMAL(18,0), RESULT_FLAG VARCHAR(20), SQL_TEXT VARCHAR(2000000), ERROR_MESSAGE VARCHAR(20000), SPLIT_STRATEGY VARCHAR(32), SPLIT_KEY VARCHAR(256), PARALLEL_REQUESTED VARCHAR(16), PARALLEL_EFFECTIVE DECIMAL(4,0)"

local function default_case(source_type, expected_sql)
    test("dispatches " .. source_type, function()
        local result = run_migrate({
            source_type = source_type,
            connection_type = "JDBC",
            db_filter = "DB",
            schema_filter = "SCH",
            table_filter = "TBL",
            target_schema = "DST",
            identifier_case_insensitive = true,
            debug = true,
            options = "",
        })
        assert_eq(result.adapter_sql, expected_sql)
        assert_eq(result.rows[1][1], "OTHER")
        assert_eq(result.rows[1][5], "PREVIEW")
        assert_eq(result.rows[1][6], "select 1")
        assert_eq(result.rows[2][1], "SUMMARY")
        assert_eq(result.rows[2][5], "PREVIEW")
        assert_eq(result.columns, AUDIT_COLUMNS)
    end)
end

print("=== Lua Syntax Validation ===")

test("Lua block in migrate_to_exasol.sql has valid syntax", function()
    local fn, err = load(migrate_lua)
    assert(fn, "Lua syntax error in migrate_to_exasol.sql: " .. tostring(err))
end)

print("")
print("=== MIGRATE_TO_EXASOL Dispatch Tests ===")

default_case("MYSQL", "EXECUTE SCRIPT database_migration.MYSQL_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("MARIADB", "EXECUTE SCRIPT database_migration.MARIADB_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("POSTGRES", "EXECUTE SCRIPT database_migration.POSTGRES_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL','DST')")
default_case("REDSHIFT", "EXECUTE SCRIPT database_migration.REDSHIFT_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("DB2", "EXECUTE SCRIPT database_migration.DB2_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("VERTICA", "EXECUTE SCRIPT database_migration.VERTICA_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("HANA", "EXECUTE SCRIPT database_migration.HANA_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL')")
default_case("AZURE_SQL", "EXECUTE SCRIPT database_migration.AZURE_SQL_TO_EXASOL('SRC_CONN','SCH','TBL',TRUE)")
default_case("BIGQUERY", "EXECUTE SCRIPT database_migration.BIGQUERY_TO_EXASOL('SRC_CONN',TRUE,'DB','SCH','TBL')")
default_case("DATABRICKS", "EXECUTE SCRIPT database_migration.DATABRICKS_TO_EXASOL('SRC_CONN',TRUE,'DB','SCH','DST','TBL',TRUE)")
default_case("SQLSERVER", "EXECUTE SCRIPT database_migration.SQLSERVER_TO_EXASOL('SRC_CONN',FALSE,'DB','SCH','DST','TBL',TRUE)")
default_case("SNOWFLAKE", "EXECUTE SCRIPT database_migration.SNOWFLAKE_TO_EXASOL('SRC_CONN',FALSE,'DB','SCH','DST','TBL',TRUE)")
default_case("ORACLE", "EXECUTE SCRIPT database_migration.ORACLE_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL',1,FALSE,FALSE,FALSE)")
default_case("TERADATA", "EXECUTE SCRIPT database_migration.TERADATA_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL',FALSE)")
default_case("EXASOL", "EXECUTE SCRIPT database_migration.EXASOL_TO_EXASOL('SRC_CONN','JDBC',TRUE,'SCH','TBL','FALSE','%','DISABLE')")
default_case("NETEZZA", "EXECUTE SCRIPT database_migration.NETEZZA_TO_EXASOL('SRC_CONN','DB','SCH','TBL',TRUE)")
default_case("VECTORWISE", "EXECUTE SCRIPT database_migration.VECTORWISE_TO_EXASOL('SRC_CONN',TRUE,'TBL')")

print("")
print("=== Alias And Option Tests ===")

test("source aliases normalize before dispatch", function()
    local result = run_migrate({
        source_type = "sql server",
        db_filter = "DB",
        schema_filter = "SCH",
        table_filter = "TBL",
        target_schema = "DST",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.SQLSERVER_TO_EXASOL('SRC_CONN',FALSE,'DB','SCH','DST','TBL',TRUE)")
end)

test("Databricks aliases normalize before dispatch", function()
    local result = run_migrate({
        source_type = "databricks sql",
        db_filter = "CAT",
        schema_filter = "SCH",
        table_filter = "TBL",
        target_schema = "DST",
        options = "CATALOG2SCHEMA=false",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.DATABRICKS_TO_EXASOL('SRC_CONN',FALSE,'CAT','SCH','DST','TBL',TRUE)")
end)

test("string literals are escaped in generated adapter calls", function()
    local result = run_migrate({
        source_type = "MYSQL",
        connection_name = "CONN'X",
        schema_filter = "S'CH",
        table_filter = "T'BL",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.MYSQL_TO_EXASOL('CONN''X',TRUE,'S''CH','T''BL')")
end)

test("Snowflake DB2SCHEMA option is forwarded", function()
    local result = run_migrate({
        source_type = "SNOWFLAKE",
        db_filter = "DB",
        schema_filter = "SCH",
        table_filter = "TBL",
        target_schema = "DST",
        options = "DB2SCHEMA=true",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.SNOWFLAKE_TO_EXASOL('SRC_CONN',TRUE,'DB','SCH','DST','TBL',TRUE)")
end)

test("Oracle options are forwarded", function()
    local result = run_migrate({
        source_type = "ORACLE",
        schema_filter = "SCH",
        table_filter = "TBL",
        options = "PARALLEL_STATEMENTS=4;CREATE_PK=yes;CREATE_FK=1;CHECK_MIGRATION=true",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.ORACLE_TO_EXASOL('SRC_CONN',TRUE,'SCH','TBL',4,TRUE,TRUE,TRUE)")
end)

test("Exasol options and connection type are forwarded", function()
    local result = run_migrate({
        source_type = "EXASOL",
        connection_type = "exa",
        schema_filter = "SCH",
        table_filter = "TBL",
        options = "GENERATE_VIEWS=TRUE;VIEW_FILTER=VW%;PK_SETTING=ENABLE",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.EXASOL_TO_EXASOL('SRC_CONN','EXA',TRUE,'SCH','TBL','TRUE','VW%','ENABLE')")
end)

test("BigQuery PROJECT_ID option overrides DB_FILTER", function()
    local result = run_migrate({
        source_type = "BIGQUERY",
        db_filter = "DB",
        schema_filter = "SCH",
        table_filter = "TBL",
        options = "PROJECT_ID=PROJECT",
    })
    assert_eq(result.adapter_sql, "EXECUTE SCRIPT database_migration.BIGQUERY_TO_EXASOL('SRC_CONN',TRUE,'PROJECT','SCH','TBL')")
end)

print("")
print("=== Execution Mode Tests ===")

test("DEBUG false runs generated statements for non-native adapters", function()
    local result = run_migrate({
        source_type = "MYSQL",
        schema_filter = "SCH",
        table_filter = "TBL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = "-- comment"},
            {SQL_TEXT = "create table t(c int)"},
        },
    })

    assert_eq(#result.calls, 2)
    assert_eq(result.calls[2], "create table t(c int)")
    assert_eq(result.rows[1][1], "INFO")
    assert_eq(result.rows[1][5], "SKIPPED")
    assert_eq(result.rows[2][1], "CREATE_TABLE")
    assert_eq(result.rows[2][5], "OK")
    assert_eq(result.rows[3][1], "SUMMARY")
    assert_eq(result.rows[3][5], "OK")
end)

test("DEBUG false runs Snowflake generated statements", function()
    local result = run_migrate({
        source_type = "SNOWFLAKE",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = "create table t(c int)"},
        },
    })

    assert_eq(#result.calls, 2)
    assert_eq(result.calls[2], "create table t(c int)")
    assert_eq(result.rows[1][1], "CREATE_TABLE")
    assert_eq(result.rows[1][5], "OK")
    assert_eq(result.rows[2][1], "SUMMARY")
    assert_eq(result.rows[2][5], "OK")
end)

test("DEBUG false reports no executable generated statements", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = "-- ### SCHEMAS ###"},
            {SQL_TEXT = "-- ### TABLES ###"},
        },
    })

    assert_eq(#result.calls, 1)
    assert_eq(result.rows[1][1], "INFO")
    assert_eq(result.rows[1][5], "SKIPPED")
    assert_eq(result.rows[2][1], "INFO")
    assert_eq(result.rows[2][5], "SKIPPED")
    assert_eq(result.rows[3][1], "SUMMARY")
    assert_eq(result.rows[3][2], "No executable SQL generated")
    assert_eq(result.rows[3][5], "SKIPPED")
end)

test("DEBUG false reports empty adapter output", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {},
    })

    assert_eq(#result.calls, 1)
    assert_eq(#result.rows, 1)
    assert_eq(result.rows[1][1], "SUMMARY")
    assert_eq(result.rows[1][2], "No executable SQL generated")
    assert_eq(result.rows[1][5], "SKIPPED")
end)

test("STEP_KIND classifies CREATE_SCHEMA / CREATE_TABLE / IMPORT", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = 'create schema if not exists "MART"'},
            {SQL_TEXT = 'create or replace table "MART"."ORDERS" ("ID" DECIMAL(18,0))'},
            {SQL_TEXT = 'import into "MART"."ORDERS" from jdbc at SRC_CONN statement \'select id from orders\''},
        },
    })

    assert_eq(result.rows[1][1], "CREATE_SCHEMA")
    assert_eq(result.rows[1][2], "MART")
    assert_eq(result.rows[2][1], "CREATE_TABLE")
    assert_eq(result.rows[2][2], "MART.ORDERS")
    assert_eq(result.rows[3][1], "IMPORT")
    assert_eq(result.rows[3][2], "MART.ORDERS")
    assert_eq(result.rows[4][1], "SUMMARY")
end)

test("ROWS_AFFECTED captured for IMPORT in execute mode", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = 'import into "M"."T" from jdbc at SRC statement \'select 1\''},
        },
        execute_results = {[1] = {success = true, rows_affected = 42}},
    })

    assert_eq(result.rows[1][1], "IMPORT")
    assert_eq(result.rows[1][3], 42)
    assert_eq(result.rows[2][1], "SUMMARY")
    assert_eq(result.rows[2][3], 42)
end)

test("Errors mark RESULT_FLAG ERROR and SUMMARY ERROR", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = 'create table "T" ("c" INT)'},
        },
        execute_results = {[1] = {success = false, error_message = "boom"}},
    })

    assert_eq(result.rows[1][5], "ERROR")
    assert_eq(result.rows[1][7], "boom")
    assert_eq(result.rows[2][1], "SUMMARY")
    assert_eq(result.rows[2][5], "ERROR")
end)

print("")
print("=== Error Handling Tests ===")

test("unsupported source raises a clear error", function()
    local ok, err = pcall(run_migrate, {source_type = "UNKNOWN"})
    assert_eq(ok, false)
    assert_contains(err, "Unsupported SOURCE_TYPE")
end)

test("S3 points users to the direct loader", function()
    local ok, err = pcall(run_migrate, {source_type = "S3"})
    assert_eq(ok, false)
    assert_contains(err, "S3 is not supported by MIGRATE_TO_EXASOL")
    assert_contains(err, "S3_PARALLEL_READ")
end)

test("missing connection raises a clear error", function()
    local ok, err = pcall(run_migrate, {source_type = "MYSQL", connection_name = ""})
    assert_eq(ok, false)
    assert_contains(err, "CONNECTION_NAME is required")
end)

test("BigQuery requires PROJECT_ID when DB_FILTER is wildcard", function()
    local ok, err = pcall(run_migrate, {
        source_type = "BIGQUERY",
        db_filter = "%",
        schema_filter = "SCH",
        table_filter = "TBL",
    })
    assert_eq(ok, false)
    assert_contains(err, "OPTIONS PROJECT_ID for BIGQUERY is required")
end)

test("invalid boolean option raises a clear error", function()
    local ok, err = pcall(run_migrate, {
        source_type = "SNOWFLAKE",
        options = "DB2SCHEMA=maybe",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid boolean for DB2SCHEMA")
end)

test("invalid DEBUG raises a clear error", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        debug = "maybe",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid boolean for DEBUG")
end)

test("adapter errors include source statement", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        adapter_error = "adapter failed",
    })
    assert_eq(ok, false)
    assert_contains(err, "adapter failed")
    assert_contains(err, "MYSQL_TO_EXASOL")
end)

print("")
print("=== PARALLEL_ROW_THRESHOLD Gate Tests ===")

local function multi_stmt_import(target_schema, target_table, src_schema, src_table, n)
    local s = 'IMPORT INTO "' .. target_schema .. '"."' .. target_table
        .. '" ("ID") FROM JDBC AT SRC_CONN'
    for i = 1, n do
        s = s .. " STATEMENT 'select \"ID\" from \"" .. src_schema .. '"."' .. src_table
            .. "\" where mod(\"ID\"," .. n .. ")=" .. (i - 1) .. "'"
    end
    return s
end

local function single_stmt_import(target_schema, target_table, src_schema, src_table)
    return 'IMPORT INTO "' .. target_schema .. '"."' .. target_table
        .. '" ("ID") FROM JDBC AT SRC_CONN STATEMENT \'select "ID" from "'
        .. src_schema .. '"."' .. src_table .. '"\''
end

local function find_import_row(rows, target)
    for i = 1, #rows do
        if rows[i][1] == "IMPORT" and rows[i][2] == target then
            return rows[i]
        end
    end
    return nil
end

test("gate rewrites multi-statement IMPORT below threshold", function()
    local sql = multi_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        schema_filter = "SMOKE",
        table_filter = "SMALL_T",
        options = "PARALLEL_STATEMENTS=4;PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500000}},
    })
    assert_eq(#result.calls, 2)
    local row = find_import_row(result.rows, "DST.SMALL_T")
    assert(row, "IMPORT row missing")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 1, "expected exactly one STATEMENT clause after rewrite, got " .. count)
    assert_contains(row[6], '"DST"."SMALL_T"')
    assert_contains(row[6], '"SMOKE"."SMALL_T"')
end)

test("gate keeps multi-statement IMPORT at or above threshold", function()
    local sql = multi_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_STATEMENTS=4;PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 5000000}},
    })
    local row = find_import_row(result.rows, "DST.BIG_T")
    assert(row, "IMPORT row missing")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 4, "expected all four STATEMENT clauses preserved, got " .. count)
end)

test("gate + splitter off leaves single-statement IMPORT untouched", function()
    local sql = single_stmt_import("DST", "MED_T", "SMOKE", "MED_T")
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=1;PARALLEL_SPLIT=OFF",
        adapter_rows = {{SQL_TEXT = sql}},
    })
    assert_eq(#result.calls, 1, "no metadata lookup should fire when splitter and gate are both inactive on single-stmt IMPORTs")
    local row = find_import_row(result.rows, "DST.MED_T")
    assert(row, "IMPORT row missing")
    assert_eq(row[6], sql)
end)

test("gate treats NULL num_rows as below threshold", function()
    local sql = multi_stmt_import("DST", "NO_STATS", "SMOKE", "NO_STATS", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "NO_STATS", SRC_ROWS = nil}},
    })
    local row = find_import_row(result.rows, "DST.NO_STATS")
    assert(row, "IMPORT row missing")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 1, "NULL row count should be treated as below threshold; got " .. count)
end)

test("gate disabled by PARALLEL_ROW_THRESHOLD=0", function()
    local sql_multi = multi_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T", 4)
    local sql_single = single_stmt_import("DST", "MED_T", "SMOKE", "MED_T")
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=0",
        adapter_rows = {{SQL_TEXT = sql_multi}, {SQL_TEXT = sql_single}},
    })
    assert_eq(#result.calls, 1, "PARALLEL_ROW_THRESHOLD=0 must issue no row-count lookup")
    local row = find_import_row(result.rows, "DST.SMALL_T")
    assert(row, "multi-stmt IMPORT row missing")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 4, "all clauses preserved under threshold=0")
end)

test("gate default threshold is 1000000", function()
    local sql = multi_stmt_import("DST", "T", "SMOKE", "T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "T", SRC_ROWS = 999999}},
    })
    local row = find_import_row(result.rows, "DST.T")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 1, "default threshold 1000000 should rewrite 999999-row table; got " .. count)
end)

test("gate soft-fails on row-count lookup error", function()
    local sql = multi_stmt_import("DST", "T", "SMOKE", "T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_error = "ORA-00942: table or view does not exist",
    })
    local row = find_import_row(result.rows, "DST.T")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 4, "soft-fail must leave all statement clauses intact")
    local info_found = false
    for i = 1, #result.rows do
        if result.rows[i][1] == "INFO" and tostring(result.rows[i][6]):find("gate skipped", 1, true) then
            info_found = true
            break
        end
    end
    assert(info_found, "expected INFO row noting gate skip on lookup error")
end)

test("gate skips lookup when adapter emits no IMPORTs", function()
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {
            {SQL_TEXT = 'create schema if not exists "DST"'},
            {SQL_TEXT = 'create or replace table "DST"."T" ("ID" DECIMAL(18,0))'},
        },
    })
    assert_eq(#result.calls, 1, "no IMPORTs -> no lookup")
end)

test("gate skips unsupported source type with INFO row", function()
    local sql = multi_stmt_import("DST", "T", "SMOKE", "T", 4)
    local result = run_migrate({
        source_type = "EXASOL",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
    })
    assert_eq(#result.calls, 1, "unsupported source must not issue lookup")
    local row = find_import_row(result.rows, "DST.T")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 4, "IMPORT preserved when gate not configured")
    local info_found = false
    for i = 1, #result.rows do
        if result.rows[i][1] == "INFO" and tostring(result.rows[i][6]):find("no row-count SQL configured", 1, true) then
            info_found = true
            break
        end
    end
    assert(info_found, "expected INFO row noting unconfigured source")
end)

test("gate keys lookup on source schema parsed from inner SELECT", function()
    local sql = 'IMPORT INTO "DST"."ORDERS" ("ID") FROM JDBC AT SRC_CONN'
        .. " STATEMENT 'select \"ID\" from \"PUBLIC\".\"orders\" where mod(\"ID\",2)=0'"
        .. " STATEMENT 'select \"ID\" from \"PUBLIC\".\"orders\" where mod(\"ID\",2)=1'"
    local lookup_sql_seen = nil
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 100}},
    })
    for i = 1, #result.calls do
        if tostring(result.calls[i]):find("import into (src_schema", 1, true) then
            lookup_sql_seen = result.calls[i]
        end
    end
    assert(lookup_sql_seen, "row-count lookup SQL not seen")
    assert_contains(lookup_sql_seen, "PUBLIC")
    assert_contains(lookup_sql_seen, "orders")
    assert(not lookup_sql_seen:find("\"DST\"", 1, true), "lookup must NOT key on target schema DST")
    local row = find_import_row(result.rows, "DST.ORDERS")
    local _, count = string.gsub(row[6], "STATEMENT '", "STATEMENT '")
    assert_eq(count, 1, "below-threshold IMPORT must be rewritten to single statement")
end)

test("gate applies per-table within one migration with one lookup", function()
    local sql_small = multi_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T", 4)
    local sql_big = multi_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T", 4)
    local sql_med = single_stmt_import("DST", "MED_T", "SMOKE", "MED_T")
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {
            {SQL_TEXT = sql_small},
            {SQL_TEXT = sql_big},
            {SQL_TEXT = sql_med},
        },
        gate_lookup_rows = {
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500},
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 5000000},
        },
    })
    local lookup_count = 0
    for i = 1, #result.calls do
        if tostring(result.calls[i]):find("import into (src_schema", 1, true) then
            lookup_count = lookup_count + 1
        end
    end
    assert_eq(lookup_count, 1, "exactly one row-count lookup per migration")
    local small = find_import_row(result.rows, "DST.SMALL_T")
    local big = find_import_row(result.rows, "DST.BIG_T")
    local med = find_import_row(result.rows, "DST.MED_T")
    local _, small_count = string.gsub(small[6], "STATEMENT '", "STATEMENT '")
    local _, big_count = string.gsub(big[6], "STATEMENT '", "STATEMENT '")
    local _, med_count = string.gsub(med[6], "STATEMENT '", "STATEMENT '")
    assert_eq(small_count, 1, "SMALL_T should be rewritten to 1 statement")
    assert_eq(big_count, 4, "BIG_T should retain 4 statements")
    assert_eq(med_count, 1, "MED_T single-stmt unchanged")
end)

print("")
print("=== PARALLEL_SPLIT Dispatcher Tests ===")

local function count_clauses(sql)
    local _, n = string.gsub(sql, "STATEMENT '", "STATEMENT '")
    return n
end

test("splitter expands single-statement IMPORT on numeric PK (PK_RANGE) with BETWEEN", function()
    local sql = single_stmt_import("DST", "ORDERS", "PUBLIC", "orders")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 4000000, SRC_PK_COL = "ORDER_ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 4000000}},
    })
    local row = find_import_row(result.rows, "DST.ORDERS")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 4, "expected 4 STATEMENT clauses; got " .. count_clauses(row[6]))
    assert_contains(row[6], '"ORDER_ID" BETWEEN 1 AND 1000000')
    assert_contains(row[6], '"ORDER_ID" BETWEEN 1000001 AND 2000000')
    assert_contains(row[6], '"ORDER_ID" BETWEEN 2000001 AND 3000000')
    assert_contains(row[6], '"ORDER_ID" BETWEEN 3000001 AND 4000000')
    assert_contains(row[6], '"PUBLIC"."orders"')
    assert_contains(row[6], '"DST"."ORDERS"')
end)

test("splitter expands single-statement IMPORT on date column (DATE_BUCKET, quarter)", function()
    local sql = single_stmt_import("DST", "EVENTS", "SMOKE", "EVENTS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "EVENTS", SRC_ROWS = 20000000, SRC_DATE_COL = "EVENT_DT"}},
    })
    local row = find_import_row(result.rows, "DST.EVENTS")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 4)
    assert_contains(row[6], 'EXTRACT(MONTH FROM "EVENT_DT") IN (1, 2, 3)')
    assert_contains(row[6], 'EXTRACT(MONTH FROM "EVENT_DT") IN (10, 11, 12)')
    assert_contains(row[6], '"EVENT_DT" IS NULL')
end)

test("splitter falls through to HASH_NUM when no PK + no date col", function()
    local sql = single_stmt_import("DST", "SESSIONS", "SMOKE", "SESSIONS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SESSIONS", SRC_ROWS = 20000000, SRC_NUM_COL = "CUSTOMER_ID"}},
    })
    local row = find_import_row(result.rows, "DST.SESSIONS")
    assert_eq(count_clauses(row[6]), 4)
    assert_contains(row[6], 'HASHTEXT("CUSTOMER_ID"')
end)

test("splitter picks ROWID when no PK/date/num and source supports it", function()
    local sql = single_stmt_import("DST", "HEAP_T", "SMOKE", "HEAP_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HEAP_T", SRC_ROWS = 20000000}},
    })
    local row = find_import_row(result.rows, "DST.HEAP_T")
    assert_eq(count_clauses(row[6]), 4)
    assert_contains(row[6], 'HASHTEXT(ctid::text)')
end)

test("splitter falls back to SINGLE + INFO row when no usable column (no ROWID support)", function()
    local sql = single_stmt_import("DST", "MYSTERY_T", "SMOKE", "MYSTERY_T")
    local result = run_migrate({
        source_type = "SNOWFLAKE",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "MYSTERY_T", SRC_ROWS = 20000000}},
    })
    local row = find_import_row(result.rows, "DST.MYSTERY_T")
    assert_eq(count_clauses(row[6]), 1, "IMPORT must remain single-statement when no split column")
    assert_eq(row[6], sql)
    local info_found = false
    for i = 1, #result.rows do
        if result.rows[i][1] == "INFO" and tostring(result.rows[i][6]):find("SMOKE.MYSTERY_T", 1, true) then
            info_found = true
            break
        end
    end
    assert(info_found, "expected INFO row noting splitter SINGLE fallback")
end)

test("splitter ignores single-stmt IMPORT below threshold", function()
    local sql = single_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.SMALL_T")
    assert_eq(count_clauses(row[6]), 1, "below-threshold IMPORT must stay single-statement")
    assert_eq(row[6], sql)
end)

test("splitter leaves multi-statement IMPORTs unchanged (pass-through)", function()
    local sql = multi_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 20000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "NUMBER"}},
    })
    local row = find_import_row(result.rows, "DST.BIG_T")
    assert_eq(count_clauses(row[6]), 4, "multi-stmt IMPORT must retain its 4 STATEMENT clauses")
end)

test("PARALLEL_SPLIT=OFF disables splitter despite usable metadata", function()
    local sql = single_stmt_import("DST", "ORDERS", "PUBLIC", "orders")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=OFF",
        adapter_rows = {{SQL_TEXT = sql}},
    })
    assert_eq(#result.calls, 1, "no metadata lookup should fire when PARALLEL_SPLIT=OFF and no multi-stmt IMPORTs")
    local row = find_import_row(result.rows, "DST.ORDERS")
    assert_eq(row[6], sql)
end)

test("PARALLEL_SPLIT=DATE:col:grain forces named column and grain", function()
    local sql = single_stmt_import("DST", "EVENTS", "SMOKE", "EVENTS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=DATE:CREATED_AT:QUARTER",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "EVENTS", SRC_ROWS = 20000000, SRC_PK_COL = "EVENT_ID", SRC_PK_TYPE = "int8", SRC_DATE_COL = "EVENT_DT"}},
    })
    local row = find_import_row(result.rows, "DST.EVENTS")
    assert_eq(count_clauses(row[6]), 4)
    assert_contains(row[6], 'EXTRACT(MONTH FROM "CREATED_AT")')
    assert(not row[6]:find('EVENT_DT'), "named override must not consult cache.src_date_col")
    assert(not row[6]:find('EVENT_ID'), "named override must not consult cache.src_pk_col")
end)

test("PARALLEL_SPLIT=HASH:col forces named column", function()
    local sql = single_stmt_import("DST", "SESSIONS", "SMOKE", "SESSIONS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=HASH:CUSTOMER_ID",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SESSIONS", SRC_ROWS = 20000000, SRC_PK_COL = "SESSION_ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.SESSIONS")
    assert_eq(count_clauses(row[6]), 4)
    assert_contains(row[6], 'HASHTEXT("CUSTOMER_ID"')
end)

test("splitter preserves IMPORT target + column list during rewrite", function()
    local sql = 'IMPORT INTO "DST"."ORDERS" ("A","B","C") FROM JDBC AT SRC_CONN STATEMENT \'select "A","B","C" from "PUBLIC"."orders"\''
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 5000000, SRC_PK_COL = "A", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.ORDERS")
    assert_contains(row[6], 'IMPORT INTO "DST"."ORDERS" ("A","B","C")')
    assert_contains(row[6], 'select "A","B","C" from "PUBLIC"."orders"')
    assert_eq(count_clauses(row[6]), 2)
end)

test("metadata round-trip fires once for mixed single/multi-stmt IMPORTs", function()
    local sql_multi = multi_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T", 4)
    local sql_single = single_stmt_import("DST", "ORDERS", "PUBLIC", "orders")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql_multi}, {SQL_TEXT = sql_single}},
        gate_lookup_rows = {
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 500},
            {SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 20000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"},
        },
    })
    local lookup_count = 0
    for i = 1, #result.calls do
        if tostring(result.calls[i]):find("import into (src_schema", 1, true) then
            lookup_count = lookup_count + 1
        end
    end
    assert_eq(lookup_count, 1, "exactly one metadata round-trip across gate + splitter")
    local multi_row = find_import_row(result.rows, "DST.BIG_T")
    local single_row = find_import_row(result.rows, "DST.ORDERS")
    assert_eq(count_clauses(multi_row[6]), 1, "below-threshold multi-stmt collapsed by gate")
    assert_eq(count_clauses(single_row[6]), 4, "above-threshold single-stmt expanded by splitter")
end)

print("")
print("=== PARALLEL_AUTO_CEILING + Audit Tests ===")

test("AUTO resolves to ceil(rows/5M) under default ceiling 12", function()
    local sql = single_stmt_import("DST", "MID_T", "SMOKE", "MID_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "MID_T", SRC_ROWS = 20000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.MID_T")
    assert_eq(count_clauses(row[6]), 4, "20M rows / 5M = 4 stmts")
    assert_eq(row[8], "PK_RANGE")
    assert_eq(row[9], "ID")
    assert_eq(row[10], "AUTO")
    assert_eq(row[11], 4)
end)

test("AUTO caps at default ceiling 12 for large tables", function()
    local sql = single_stmt_import("DST", "HUGE_T", "SMOKE", "HUGE_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HUGE_T", SRC_ROWS = 100000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.HUGE_T")
    assert_eq(count_clauses(row[6]), 12, "100M rows -> capped at 12 stmts")
    assert_eq(row[11], 12)
end)

test("PARALLEL_AUTO_CEILING=24 raises the AUTO cap", function()
    local sql = single_stmt_import("DST", "HUGE_T", "SMOKE", "HUGE_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO;PARALLEL_AUTO_CEILING=24",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HUGE_T", SRC_ROWS = 100000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.HUGE_T")
    assert_eq(count_clauses(row[6]), 20, "100M / 5M = 20 stmts, under raised cap 24")
    assert_eq(row[11], 20)
end)

test("explicit PARALLEL_STATEMENTS bypasses ceiling", function()
    local sql = single_stmt_import("DST", "HUGE_T", "SMOKE", "HUGE_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=24",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HUGE_T", SRC_ROWS = 100000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.HUGE_T")
    assert_eq(count_clauses(row[6]), 24)
    assert_eq(row[10], "24")
    assert_eq(row[11], 24)
end)

test("AUTO with NULL src_rows resolves to 1", function()
    local sql = single_stmt_import("DST", "UNK_T", "SMOKE", "UNK_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "UNK_T", SRC_ROWS = nil, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.UNK_T")
    assert_eq(row[6], sql, "NULL src_rows must leave IMPORT single-stmt")
    assert_eq(row[8], "SINGLE")
    assert_eq(row[11], 1)
end)

test("AUTO below threshold resolves to 1 and marks SINGLE", function()
    local sql = single_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.SMALL_T")
    assert_eq(row[6], sql)
    assert_eq(row[8], "SINGLE")
    assert_eq(row[10], "AUTO")
    assert_eq(row[11], 1)
end)

test("audit cols populated MULTI_PASSTHROUGH on adapter multi-stmt above threshold", function()
    local sql = multi_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 20000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "NUMBER"}},
    })
    local row = find_import_row(result.rows, "DST.BIG_T")
    assert_eq(row[8], "MULTI_PASSTHROUGH")
    assert_eq(row[11], 4)
end)

test("audit cols NULL for non-IMPORT rows", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = false,
        adapter_rows = {
            {SQL_TEXT = 'create schema if not exists "DST"'},
            {SQL_TEXT = 'create or replace table "DST"."T" ("c" INT)'},
        },
    })
    for i = 1, #result.rows do
        local r = result.rows[i]
        if r[1] ~= "IMPORT" then
            assert_eq(r[8], NULL, "non-IMPORT row " .. r[1] .. " audit strategy must be NULL")
            assert_eq(r[9], NULL, "non-IMPORT row " .. r[1] .. " audit key must be NULL")
            assert_eq(r[10], NULL, "non-IMPORT row " .. r[1] .. " audit requested must be NULL")
            assert_eq(r[11], NULL, "non-IMPORT row " .. r[1] .. " audit effective must be NULL")
        end
    end
end)

test("invalid PARALLEL_STATEMENTS raises before adapter SQL", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        options = "PARALLEL_STATEMENTS=banana",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid PARALLEL_STATEMENTS")
end)

test("PARALLEL_STATEMENTS=0 raises", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        options = "PARALLEL_STATEMENTS=0",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid PARALLEL_STATEMENTS")
end)

test("invalid PARALLEL_AUTO_CEILING raises", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        options = "PARALLEL_AUTO_CEILING=many",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid PARALLEL_AUTO_CEILING")
end)

test("PARALLEL_AUTO_CEILING=0 raises", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        options = "PARALLEL_AUTO_CEILING=0",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid PARALLEL_AUTO_CEILING")
end)

test("invalid PARALLEL_SPLIT raises", function()
    local ok, err = pcall(run_migrate, {
        source_type = "MYSQL",
        options = "PARALLEL_SPLIT=NONSENSE",
    })
    assert_eq(ok, false)
    assert_contains(err, "Invalid PARALLEL_SPLIT")
end)

test("per-IMPORT AUTO resolution differs across one migration", function()
    local sql_small = single_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T")
    local sql_mid = single_stmt_import("DST", "MID_T", "SMOKE", "MID_T")
    local sql_huge = single_stmt_import("DST", "HUGE_T", "SMOKE", "HUGE_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {
            {SQL_TEXT = sql_small},
            {SQL_TEXT = sql_mid},
            {SQL_TEXT = sql_huge},
        },
        gate_lookup_rows = {
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"},
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "MID_T", SRC_ROWS = 20000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"},
            {SRC_SCHEMA = "SMOKE", SRC_TABLE = "HUGE_T", SRC_ROWS = 100000000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8"},
        },
    })
    local small = find_import_row(result.rows, "DST.SMALL_T")
    local mid = find_import_row(result.rows, "DST.MID_T")
    local huge = find_import_row(result.rows, "DST.HUGE_T")
    assert_eq(small[11], 1)
    assert_eq(mid[11], 4)
    assert_eq(huge[11], 12)
    assert_eq(small[10], "AUTO")
    assert_eq(mid[10], "AUTO")
    assert_eq(huge[10], "AUTO")
end)

print("")
print("=== Phase 4 spec-coverage tests ===")

test("PARALLEL_SPLIT=ROWID on unsupported source falls back to SINGLE + INFO", function()
    local sql = single_stmt_import("DST", "HEAP_T", "SMOKE", "HEAP_T")
    local result = run_migrate({
        source_type = "SNOWFLAKE",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=ROWID",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HEAP_T", SRC_ROWS = 20000000}},
    })
    local row = find_import_row(result.rows, "DST.HEAP_T")
    assert_eq(row[6], sql, "forced ROWID on Snowflake must leave IMPORT untouched")
    assert_eq(row[8], "SINGLE")
    assert_eq(row[11], 1)
    local info_found = false
    for i = 1, #result.rows do
        if result.rows[i][1] == "INFO" and tostring(result.rows[i][6]):find("ROWID unsupported", 1, true) then
            info_found = true
            break
        end
    end
    assert(info_found, "expected INFO row noting ROWID unsupported for SNOWFLAKE")
end)

test("duplicate source tables collapse to one cache lookup pair", function()
    local sql1 = single_stmt_import("DST", "ORDERS_A", "PUBLIC", "orders")
    local sql2 = single_stmt_import("DST", "ORDERS_B", "PUBLIC", "orders")
    local lookup_sql_seen = nil
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql1}, {SQL_TEXT = sql2}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 20000000, SRC_PK_COL = "id", SRC_PK_TYPE = "int8"}},
    })
    for i = 1, #result.calls do
        if tostring(result.calls[i]):find("import into (src_schema", 1, true) then
            lookup_sql_seen = result.calls[i]
        end
    end
    assert(lookup_sql_seen, "metadata lookup must fire")
    -- The outer IMPORT-FROM-JDBC SQL wraps the inner metadata SQL in a single-
    -- quoted literal, so every `'PUBLIC'` becomes `''PUBLIC''`. Count occurrences.
    local _, pair_count = string.gsub(lookup_sql_seen, "c%.relname = ''orders''", "")
    assert_eq(pair_count, 1, "duplicate source tables must appear exactly once in WHERE; got " .. pair_count)
end)

test("Databricks-style NULL src_rows leaves IMPORT single-stmt without raising", function()
    local sql = single_stmt_import("DST", "EVENTS", "MAIN_DEFAULT", "EVENTS")
    local result = run_migrate({
        source_type = "DATABRICKS",
        db_filter = "CAT",
        schema_filter = "MAIN_DEFAULT",
        table_filter = "EVENTS",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "MAIN_DEFAULT", SRC_TABLE = "EVENTS", SRC_ROWS = nil}},
    })
    local row = find_import_row(result.rows, "DST.EVENTS")
    assert_eq(row[6], sql)
    assert_eq(row[8], "SINGLE")
    assert_eq(row[11], 1)
end)

test("per-source metadata SQL switches by SOURCE_TYPE", function()
    local pg_sql = single_stmt_import("DST", "ORDERS", "PUBLIC", "orders")
    local pg_result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = pg_sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 20000000, SRC_PK_COL = "id", SRC_PK_TYPE = "int8"}},
    })
    local pg_lookup = nil
    for i = 1, #pg_result.calls do
        if tostring(pg_result.calls[i]):find("import into (src_schema", 1, true) then
            pg_lookup = pg_result.calls[i]
        end
    end
    assert(pg_lookup, "PG lookup SQL not seen")
    assert_contains(pg_lookup, "pg_class")
    assert_contains(pg_lookup, "pg_namespace")

    local my_sql = single_stmt_import("DST", "ORDERS", "MYDB", "orders")
    local my_result = run_migrate({
        source_type = "MYSQL",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = my_sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "MYDB", SRC_TABLE = "orders", SRC_ROWS = 20000000, SRC_PK_COL = "id", SRC_PK_TYPE = "bigint"}},
    })
    local my_lookup = nil
    for i = 1, #my_result.calls do
        if tostring(my_result.calls[i]):find("import into (src_schema", 1, true) then
            my_lookup = my_result.calls[i]
        end
    end
    assert(my_lookup, "MySQL lookup SQL not seen")
    assert_contains(my_lookup, "information_schema.tables")
end)

test("gate-collapsed multi-stmt IMPORT below threshold records SINGLE audit", function()
    local sql = multi_stmt_import("DST", "SMALL_T", "SMOKE", "SMALL_T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SMALL_T", SRC_ROWS = 500}},
    })
    local row = find_import_row(result.rows, "DST.SMALL_T")
    assert_eq(row[8], "SINGLE", "gate-collapsed must record SINGLE strategy")
    assert_eq(row[9], NULL)
    assert_eq(row[10], "AUTO")
    assert_eq(row[11], 1)
end)

test("INFO rows carry NULL audit columns", function()
    local sql = multi_stmt_import("DST", "T", "SMOKE", "T", 4)
    local result = run_migrate({
        source_type = "ORACLE",
        options = "PARALLEL_ROW_THRESHOLD=1000000",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_error = "ORA-00942",
    })
    local info_count = 0
    for i = 1, #result.rows do
        if result.rows[i][1] == "INFO" then
            info_count = info_count + 1
            assert_eq(result.rows[i][8], NULL, "INFO row strategy must be NULL")
            assert_eq(result.rows[i][9], NULL, "INFO row key must be NULL")
            assert_eq(result.rows[i][10], NULL, "INFO row requested must be NULL")
            assert_eq(result.rows[i][11], NULL, "INFO row effective must be NULL")
        end
    end
    assert(info_count >= 1, "expected at least one INFO row from soft-fail")
end)

test("SUMMARY row carries NULL audit columns", function()
    local result = run_migrate({
        source_type = "MYSQL",
        debug = true,
        adapter_rows = {{SQL_TEXT = "select 1"}},
    })
    local summary = result.rows[#result.rows]
    assert_eq(summary[1], "SUMMARY")
    assert_eq(summary[8], NULL)
    assert_eq(summary[9], NULL)
    assert_eq(summary[10], NULL)
    assert_eq(summary[11], NULL)
end)

test("every output row exposes 11 positional slots matching OUT_COLUMNS shape", function()
    -- Lua's `#` is undefined for tables with trailing nil holes, so the
    -- 11-tuple guarantee is instead asserted by reading slot 11 on every row
    -- (must be either NULL or a non-nil audit value -- never index out of range).
    local result = run_migrate({
        source_type = "MYSQL",
        debug = true,
        adapter_rows = {
            {SQL_TEXT = 'create schema if not exists "DST"'},
            {SQL_TEXT = 'create or replace table "DST"."T" ("c" INT)'},
            {SQL_TEXT = 'IMPORT INTO "DST"."T" ("c") FROM JDBC AT SRC STATEMENT \'select "c" from "S"."T"\''},
        },
    })
    for i = 1, #result.rows do
        local r = result.rows[i]
        -- Slots 1..7 are always populated (STEP_KIND, TARGET_OBJ, etc.).
        assert(r[1] ~= nil, "row " .. i .. " STEP_KIND slot must exist")
        -- Slots 8..11 are NULL for non-IMPORT rows; for any row, accessing
        -- slot 11 must not error and must equal NULL or a number.
        local v11 = r[11]
        if r[1] == "IMPORT" then
            assert(v11 ~= nil, "IMPORT row " .. i .. " PARALLEL_EFFECTIVE must be populated")
        else
            assert_eq(v11, NULL, "non-IMPORT row " .. i .. " PARALLEL_EFFECTIVE must be NULL")
        end
    end
    assert_contains(result.columns, "SPLIT_STRATEGY VARCHAR(32)")
    assert_contains(result.columns, "SPLIT_KEY VARCHAR(256)")
    assert_contains(result.columns, "PARALLEL_REQUESTED VARCHAR(16)")
    assert_contains(result.columns, "PARALLEL_EFFECTIVE DECIMAL(4,0)")
end)

test("PARALLEL_REQUESTED records explicit integer literally", function()
    local sql = single_stmt_import("DST", "BIG_T", "SMOKE", "BIG_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=1000000;PARALLEL_STATEMENTS=8",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "BIG_T", SRC_ROWS = 20000000, SRC_PK_COL = "id", SRC_PK_TYPE = "int8"}},
    })
    local row = find_import_row(result.rows, "DST.BIG_T")
    assert_eq(row[10], "8", "PARALLEL_REQUESTED must be raw literal '8'")
    assert_eq(row[11], 8)
    assert_eq(count_clauses(row[6]), 8)
end)

print("")
print("=== PK_RANGE BETWEEN Pushdown Tests ===")

test("PK_RANGE BETWEEN with width rounding: 1..10 into 3 buckets", function()
    local sql = single_stmt_import("DST", "LEDGER", "SMOKE", "LEDGER")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=3;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "LEDGER", SRC_ROWS = 10, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 10}},
    })
    local row = find_import_row(result.rows, "DST.LEDGER")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 3, "expected 3 STATEMENT clauses")
    assert_contains(row[6], '"ID" BETWEEN 1 AND 4')
    assert_contains(row[6], '"ID" BETWEEN 5 AND 8')
    assert_contains(row[6], '"ID" BETWEEN 9 AND 10')
    assert_eq(row[11], 3, "PARALLEL_EFFECTIVE should be 3")
end)

test("PK_RANGE BETWEEN degenerate range (min == max) emits one bucket", function()
    local sql = single_stmt_import("DST", "SINGLETON", "SMOKE", "SINGLETON")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "SINGLETON", SRC_ROWS = 1, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 42, SRC_PK_MAX = 42}},
    })
    local row = find_import_row(result.rows, "DST.SINGLETON")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 1, "degenerate range should emit 1 clause")
    assert_contains(row[6], '"ID" BETWEEN 42 AND 42')
    assert_eq(row[11], 1, "PARALLEL_EFFECTIVE should be 1")
end)

test("PK_RANGE BETWEEN NULL PK rows: k=0 appends 'OR ... IS NULL'", function()
    local sql = single_stmt_import("DST", "ORDERS", "PUBLIC", "orders")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "PUBLIC", SRC_TABLE = "orders", SRC_ROWS = 100, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 100}},
    })
    local row = find_import_row(result.rows, "DST.ORDERS")
    assert_contains(row[6], '("ID" BETWEEN 1 AND 50 OR "ID" IS NULL)', "k=0 should append IS NULL check")
    assert_contains(row[6], '"ID" BETWEEN 51 AND 100', "k=1 should not have IS NULL")
end)

test("PK_RANGE BETWEEN range smaller than N: 1..2 into 4 buckets yields 2 clauses", function()
    local sql = single_stmt_import("DST", "TINY", "SMOKE", "TINY")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "TINY", SRC_ROWS = 2, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 2}},
    })
    local row = find_import_row(result.rows, "DST.TINY")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 2, "range 1..2 should yield 2 buckets (not 4)")
    assert_eq(row[11], 2, "PARALLEL_EFFECTIVE should be 2")
end)

test("PK_RANGE MOD fallback when src_pk_min is NULL", function()
    local sql = single_stmt_import("DST", "HEAP_T", "SMOKE", "HEAP_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "SMOKE", SRC_TABLE = "HEAP_T", SRC_ROWS = 1000, SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = nil, SRC_PK_MAX = nil}},
    })
    local row = find_import_row(result.rows, "DST.HEAP_T")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 4, "expected 4 MOD clauses (fallback)")
    assert_contains(row[6], 'MOD("ID", 4) = 0', "should use Postgres double-quote MOD fallback")
    assert_eq(row[8], "PK_RANGE", "SPLIT_STRATEGY should still be PK_RANGE")
end)

test("PK_RANGE BETWEEN MySQL backtick quoting", function()
    local sql = single_stmt_import("DST", "orders", "app", "orders")
    local result = run_migrate({
        source_type = "MYSQL",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "app", SRC_TABLE = "orders", SRC_ROWS = 100, SRC_PK_COL = "id", SRC_PK_TYPE = "int", SRC_PK_MIN = 1, SRC_PK_MAX = 100}},
    })
    local row = find_import_row(result.rows, "DST.orders")
    assert_contains(row[6], '`id` BETWEEN 1 AND 50', "MySQL should use backtick BETWEEN")
    assert_contains(row[6], '(`id` BETWEEN 1 AND 50 OR `id` IS NULL)', "k=0 with MySQL backticks")
end)

test("PK_RANGE BETWEEN SQL Server bracket quoting", function()
    local sql = single_stmt_import("DST", "Orders", "dbo", "Orders")
    local result = run_migrate({
        source_type = "SQLSERVER",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{SRC_SCHEMA = "dbo", SRC_TABLE = "Orders", SRC_ROWS = 100, SRC_PK_COL = "Id", SRC_PK_TYPE = "int", SRC_PK_MIN = 1, SRC_PK_MAX = 100}},
    })
    local row = find_import_row(result.rows, "DST.Orders")
    assert_contains(row[6], '[Id] BETWEEN 1 AND 50', "SQL Server should use bracket BETWEEN")
end)

-- UNIQUE_NUM tests (new strategy, item 3)

test("UNIQUE_NUM: AUTO picks UNIQUE_NUM when no PK but unique numeric col present", function()
    local sql = single_stmt_import("DST", "LEGACY_ORDERS", "PUB", "LEGACY_ORDERS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "LEGACY_ORDERS", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = "LEGACY_ID", SRC_UNIQUE_NUM_TYPE = "INT4", SRC_UNIQUE_NUM_MIN = 1, SRC_UNIQUE_NUM_MAX = 2000000,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.LEGACY_ORDERS")
    assert(row, "IMPORT row missing")
    assert_eq(count_clauses(row[6]), 4, "expected 4 BETWEEN clauses")
    assert_contains(row[6], '"LEGACY_ID" BETWEEN', "should use BETWEEN on unique col")
    assert_eq(row[8], "UNIQUE_NUM", "SPLIT_STRATEGY should be UNIQUE_NUM")
    assert_eq(row[9], "LEGACY_ID", "SPLIT_KEY should be LEGACY_ID")
end)

test("UNIQUE_NUM: AUTO falls through to DATE_BUCKET when no PK and no unique-num", function()
    local sql = single_stmt_import("DST", "LOGS", "PUB", "LOGS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "LOGS", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = "TS", SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.LOGS")
    assert_eq(row[8], "DATE_BUCKET", "SPLIT_STRATEGY should fall through to DATE_BUCKET")
    assert_eq(row[9], "TS", "SPLIT_KEY should be TS")
end)

test("UNIQUE_NUM: Forced PARALLEL_SPLIT=UNIQUE_NUM uses cached column", function()
    local sql = single_stmt_import("DST", "HYBRID_T", "PUB", "HYBRID_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=UNIQUE_NUM",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "HYBRID_T", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = "TRACE_NUM", SRC_UNIQUE_NUM_TYPE = "INT4", SRC_UNIQUE_NUM_MIN = 1, SRC_UNIQUE_NUM_MAX = 100,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.HYBRID_T")
    assert_eq(count_clauses(row[6]), 2, "expected 2 BETWEEN clauses")
    assert_contains(row[6], '"TRACE_NUM" BETWEEN', "should use TRACE_NUM not ID")
    assert_eq(row[8], "UNIQUE_NUM", "SPLIT_STRATEGY should be UNIQUE_NUM")
    assert_eq(row[9], "TRACE_NUM", "SPLIT_KEY should be TRACE_NUM")
end)

test("UNIQUE_NUM: Forced PARALLEL_SPLIT=UNIQUE_NUM:col overrides cached column", function()
    local sql = single_stmt_import("DST", "OPS_AUDIT", "PUB", "OPS_AUDIT")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=UNIQUE_NUM:OPS_SEQ",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "OPS_AUDIT", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.OPS_AUDIT")
    assert_eq(count_clauses(row[6]), 4, "expected 4 clauses (MOD fallback, no lo/hi)")
    assert_contains(row[6], 'MOD("OPS_SEQ", 4)', "should use MOD on operator-supplied column")
    assert_eq(row[8], "UNIQUE_NUM", "SPLIT_STRATEGY should be UNIQUE_NUM")
end)

test("UNIQUE_NUM: Forced UNIQUE_NUM soft-fails when no col known and no override supplied", function()
    local sql = single_stmt_import("DST", "MYSTERY_T", "PUB", "MYSTERY_T")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=UNIQUE_NUM",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "MYSTERY_T", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.MYSTERY_T")
    assert(row, "IMPORT row must be present (soft-fail)")
    assert_eq(count_clauses(row[6]), 1, "should pass through unchanged (single statement)")
    assert_eq(row[8], "SINGLE", "SPLIT_STRATEGY should be SINGLE (soft-fail)")
    -- verify INFO row was emitted
    local has_info = false
    for _, r in ipairs(result.rows) do
        if r[1] == "INFO" and r[7] and r[7]:find("PARALLEL_SPLIT=UNIQUE_NUM") then
            has_info = true
            break
        end
    end
    assert(has_info, "INFO audit row missing for soft-fail")
end)

test("UNIQUE_NUM: MOD fallback when src_unique_num_min/max NULL", function()
    local sql = single_stmt_import("DST", "legacy_data", "app", "legacy_data")
    local result = run_migrate({
        source_type = "MYSQL",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "app", SRC_TABLE = "legacy_data", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = "LEGACY_ID", SRC_UNIQUE_NUM_TYPE = "int", SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false
        }},
    })
    local row = find_import_row(result.rows, "DST.legacy_data")
    assert_eq(count_clauses(row[6]), 4, "expected 4 MOD clauses (no lo/hi)")
    assert_contains(row[6], '(`LEGACY_ID` MOD 4) = 0', "should use MySQL backtick MOD fallback")
    assert_eq(row[8], "UNIQUE_NUM", "SPLIT_STRATEGY should be UNIQUE_NUM")
end)

print("=== PARTITION split v2 tests ===")

test("PARTITION: AUTO picks PARTITION when src_partitions non-NULL even if pk_col present", function()
    local sql = single_stmt_import("DST", "LOGS", "PUB", "LOGS")
    local part_json = '[{"name":"LOGS_2026Q1","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q1' .. "'" .. '::regclass"},{"name":"LOGS_2026Q2","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q2' .. "'" .. '::regclass"},{"name":"LOGS_2026Q3","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q3' .. "'" .. '::regclass"},{"name":"LOGS_2026Q4","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q4' .. "'" .. '::regclass"}]'
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "LOGS", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = true,
            SRC_PARTITIONS = part_json
        }},
    })
    local row = find_import_row(result.rows, "DST.LOGS")
    assert_eq(count_clauses(row[6]), 4, "expected 4 PARTITION clauses")
    assert_contains(row[6], "tableoid::regclass = ''LOGS_2026Q1''::regclass", "should contain partition 1 predicate")
    assert_contains(row[6], "tableoid::regclass = ''LOGS_2026Q2''::regclass", "should contain partition 2 predicate")
    assert_eq(row[8], "PARTITION", "SPLIT_STRATEGY should be PARTITION")
    assert_eq(row[11], 4, "PARALLEL_EFFECTIVE should be 4")
end)

test("PARTITION: Fewer partitions than N collapses to N_effective = #partitions", function()
    local sql = single_stmt_import("DST", "LOGS", "PUB", "LOGS")
    local part_json = '[{"name":"LOGS_2026Q1","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q1' .. "'" .. '::regclass"},{"name":"LOGS_2026Q2","predicate":"tableoid::regclass = ' .. "'" .. 'LOGS_2026Q2' .. "'" .. '::regclass"}]'
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "LOGS", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = true,
            SRC_PARTITIONS = part_json
        }},
    })
    local row = find_import_row(result.rows, "DST.LOGS")
    assert_eq(count_clauses(row[6]), 2, "expected 2 PARTITION clauses (fewer than N=4)")
    assert_eq(row[8], "PARTITION", "SPLIT_STRATEGY should be PARTITION")
    assert_eq(row[11], 2, "PARALLEL_EFFECTIVE should be 2")
end)

test("PARTITION: More partitions than N chunks via OR-of-predicates", function()
    local sql = single_stmt_import("DST", "EVENTS", "RAW", "EVENTS")
    local part_json = '[{"name":"P0","predicate":"col = 0"},{"name":"P1","predicate":"col = 1"},{"name":"P2","predicate":"col = 2"},{"name":"P3","predicate":"col = 3"},{"name":"P4","predicate":"col = 4"},{"name":"P5","predicate":"col = 5"},{"name":"P6","predicate":"col = 6"},{"name":"P7","predicate":"col = 7"},{"name":"P8","predicate":"col = 8"},{"name":"P9","predicate":"col = 9"}]'
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "RAW", SRC_TABLE = "EVENTS", SRC_ROWS = 10000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = true,
            SRC_PARTITIONS = part_json
        }},
    })
    local row = find_import_row(result.rows, "DST.EVENTS")
    assert_eq(count_clauses(row[6]), 4, "expected 4 STATEMENT clauses (chunked from 10 partitions)")
    assert_eq(row[8], "PARTITION", "SPLIT_STRATEGY should be PARTITION")
    assert_eq(row[11], 4, "PARALLEL_EFFECTIVE should be 4")
end)

test("PARTITION: AUTO falls through to PK_RANGE when src_partitions NULL", function()
    local sql = single_stmt_import("DST", "ORDERS", "PUB", "ORDERS")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "ORDERS", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false,
            SRC_PARTITIONS = nil
        }},
    })
    local row = find_import_row(result.rows, "DST.ORDERS")
    assert_eq(row[8], "PK_RANGE", "SPLIT_STRATEGY should fall through to PK_RANGE")
    assert_eq(row[9], "ID", "SPLIT_KEY should be ID")
    -- verify no INFO row about PARTITION was emitted
    local has_partition_info = false
    for _, r in ipairs(result.rows) do
        if r[1] == "INFO" and r[7] and r[7]:find("PARTITION") then
            has_partition_info = true
            break
        end
    end
    assert(not has_partition_info, "should not emit INFO for silent fall-through")
end)

test("PARTITION: Forced PARALLEL_SPLIT=PARTITION soft-fails on non-partitioned source", function()
    local sql = single_stmt_import("DST", "SIMPLE", "PUB", "SIMPLE")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=PARTITION",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "SIMPLE", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = false,
            SRC_PARTITIONS = nil
        }},
    })
    local row = find_import_row(result.rows, "DST.SIMPLE")
    assert(row, "IMPORT row must be present (soft-fail)")
    assert_eq(count_clauses(row[6]), 1, "should pass through unchanged (single statement)")
    assert_eq(row[8], "SINGLE", "SPLIT_STRATEGY should be SINGLE (soft-fail)")
    -- verify INFO row was emitted
    local has_info = false
    for _, r in ipairs(result.rows) do
        if r[1] == "INFO" and r[7] and r[7]:find("PARTITION") then
            has_info = true
            break
        end
    end
    assert(has_info, "INFO audit row missing for soft-fail")
end)

test("PARTITION: Corrupt src_partitions JSON soft-fails to next step", function()
    local sql = single_stmt_import("DST", "CORRUPTED", "PUB", "CORRUPTED")
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=4;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "CORRUPTED", SRC_ROWS = 1000,
            SRC_PK_COL = "ID", SRC_PK_TYPE = "int8", SRC_PK_MIN = 1, SRC_PK_MAX = 1000,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = true,
            SRC_PARTITIONS = 'not valid json'
        }},
    })
    local row = find_import_row(result.rows, "DST.CORRUPTED")
    assert_eq(row[8], "PK_RANGE", "SPLIT_STRATEGY should fall through to PK_RANGE")
    -- verify INFO row was emitted about parse failure
    local has_info = false
    for _, r in ipairs(result.rows) do
        if r[1] == "INFO" and r[7] and r[7]:find("partition") then
            has_info = true
            break
        end
    end
    assert(has_info, "INFO audit row missing for corrupt JSON parse")
end)

test("PARTITION: emits no IS NULL OR clause", function()
    local sql = single_stmt_import("DST", "PARTITIONED_T", "PUB", "PARTITIONED_T")
    local part_json = '[{"name":"P1","predicate":"col >= 1 AND col < 10"},{"name":"P2","predicate":"col >= 10 AND col < 20"}]'
    local result = run_migrate({
        source_type = "POSTGRES",
        target_schema = "DST",
        options = "PARALLEL_ROW_THRESHOLD=0;PARALLEL_STATEMENTS=2;PARALLEL_SPLIT=AUTO",
        adapter_rows = {{SQL_TEXT = sql}},
        gate_lookup_rows = {{
            SRC_SCHEMA = "PUB", SRC_TABLE = "PARTITIONED_T", SRC_ROWS = 1000,
            SRC_PK_COL = nil, SRC_PK_TYPE = nil, SRC_PK_MIN = nil, SRC_PK_MAX = nil,
            SRC_UNIQUE_NUM_COL = nil, SRC_UNIQUE_NUM_TYPE = nil, SRC_UNIQUE_NUM_MIN = nil, SRC_UNIQUE_NUM_MAX = nil,
            SRC_DATE_COL = nil, SRC_NUM_COL = nil, SRC_PARTITIONED = true,
            SRC_PARTITIONS = part_json
        }},
    })
    local row = find_import_row(result.rows, "DST.PARTITIONED_T")
    assert_eq(count_clauses(row[6]), 2, "expected 2 PARTITION clauses")
    assert(not row[6]:find("IS NULL"), "partition predicates should not include IS NULL clause")
end)

print("")
print(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
