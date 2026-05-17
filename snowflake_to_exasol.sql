--/
create or replace script EXA_DB_MIGRATION.SNOWFLAKE_TO_EXASOL(
    CONNECTION_NAME
    , DB2SCHEMA
    , DB_FILTER
    , SCHEMA_FILTER
    , TARGET_SCHEMA
    , TABLE_FILTER
    , IDENTIFIER_CASE_INSENSITIVE
    , EXECUTION_MODE
    , PARALLEL_CONNECTIONS
    , LOGGING_SCHEMA
) RETURNS TABLE
AS

-- Delegating shim to MIGRATE_TO_EXASOL
-- This script maintains backward compatibility with the legacy SNOWFLAKE_TO_EXASOL signature
-- and translates calls to the new unified MIGRATE_TO_EXASOL UDF.

-- Call the new unified migration UDF with empty options
local success, migr_res = pquery([[
    EXECUTE SCRIPT EXA_DB_MIGRATION.MIGRATE_TO_EXASOL(
        'snowflake',
        ']] .. CONNECTION_NAME .. [[',
        ']] .. (DB_FILTER or '%') .. [[',
        ']] .. (SCHEMA_FILTER or '%') .. [[',
        ']] .. (TARGET_SCHEMA or '') .. [[',
        ']] .. (TABLE_FILTER or '%') .. [[',
        ]] .. (IDENTIFIER_CASE_INSENSITIVE and 'true' or 'false') .. [[,
        ']] .. (EXECUTION_MODE or 'DEBUG') .. [[',
        ]] .. (PARALLEL_CONNECTIONS and tostring(PARALLEL_CONNECTIONS) or 'null') .. [[,
        ]] .. (DB2SCHEMA and 'true' or 'false') .. [[,
        '{}'
    )
]])

-- Project 7-column audit result to legacy 3-column (SQL_TEXT, SUCCESS, ERROR_MESSAGE) format
local legacy_result = {}

-- Prepend deprecation warning
table.insert(legacy_result, {
    NULL,
    'FALSE',
    'WARNING: SNOWFLAKE_TO_EXASOL is deprecated; use MIGRATE_TO_EXASOL(\'snowflake\', ...).'
})

if success and migr_res then
    for _, audit_row in ipairs(migr_res) do
        local step_kind = audit_row.STEP_KIND or audit_row[1]
        local target_obj = audit_row.TARGET_OBJ or audit_row[2]
        local rows_affected = audit_row.ROWS_AFFECTED or audit_row[3]
        local elapsed_ms = audit_row.ELAPSED_MS or audit_row[4]
        local result_flag = audit_row.RESULT_FLAG or audit_row[5]
        local sql_text = audit_row.SQL_TEXT or audit_row[6]
        local error_message = audit_row.ERROR_MESSAGE or audit_row[7]

        -- Map RESULT_FLAG values to legacy SUCCESS format
        local legacy_success = result_flag
        if result_flag == 'OK' or result_flag == 'SKIPPED' then
            legacy_success = 'TRUE'
        elseif result_flag == 'ERROR' then
            legacy_success = 'FALSE'
        elseif result_flag == 'PREVIEW' then
            legacy_success = 'PREVIEW'
        end

        table.insert(legacy_result, {
            sql_text,
            legacy_success,
            error_message
        })
    end
end

return legacy_result, "SQL_TEXT VARCHAR(2000000), SUCCESS VARCHAR(10), ERROR_MESSAGE VARCHAR(20000)"
/
