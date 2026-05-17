--/
create or replace script EXA_DB_MIGRATION.TERADATA_TO_EXASOL(
    CONNECTION_NAME
    , IDENTIFIER_CASE_INSENSITIVE
    , SCHEMA_FILTER
    , TABLE_FILTER
    , CHECK_MIGRATION
) RETURNS TABLE
AS

-- Delegating shim to MIGRATE_TO_EXASOL
-- This script maintains backward compatibility with the legacy TERADATA_TO_EXASOL signature
-- and translates calls to the new unified MIGRATE_TO_EXASOL UDF.
-- Note: CHECK_MIGRATION flag is passed in options as opaque JSON for Teradata-specific handling.

local options_json = '{"check_migration":' .. (CHECK_MIGRATION and 'true' or 'false') .. '}'

-- Call the new unified migration UDF with Teradata-specific options
local success, migr_res = pquery([[
    EXECUTE SCRIPT EXA_DB_MIGRATION.MIGRATE_TO_EXASOL(
        'teradata',
        ']] .. CONNECTION_NAME .. [[',
        '%',
        ']] .. (SCHEMA_FILTER or '%') .. [[',
        '',
        ']] .. (TABLE_FILTER or '%') .. [[',
        ]] .. (IDENTIFIER_CASE_INSENSITIVE and 'true' or 'false') .. [[,
        'DEBUG',
        null,
        false,
        ']] .. options_json .. [['
    )
]])

-- Project 7-column audit result to legacy 3-column (SQL_TEXT, SUCCESS, ERROR_MESSAGE) format
local legacy_result = {}

-- Prepend deprecation warning
table.insert(legacy_result, {
    NULL,
    'FALSE',
    'WARNING: TERADATA_TO_EXASOL is deprecated; use MIGRATE_TO_EXASOL(\'teradata\', ...).'
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
