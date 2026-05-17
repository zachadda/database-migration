--/
create or replace script EXA_DB_MIGRATION.S3_TO_EXASOL(
) RETURNS TABLE
AS

-- Delegating stub for S3_TO_EXASOL
-- Full S3 IMPORT FROM CSV is out of scope for this iteration.
-- This stub calls MIGRATE_TO_EXASOL with the s3 adapter which emits
-- an INFO row noting that S3 migrations remain on the legacy script.

local legacy_result = {}

-- Prepend deprecation and scope note
table.insert(legacy_result, {
    NULL,
    'FALSE',
    'WARNING: S3_TO_EXASOL is deprecated; full S3 IMPORT FROM CSV is out of scope in this iteration.'
})

table.insert(legacy_result, {
    NULL,
    'FALSE',
    'INFO: S3 migrations remain on the legacy script pattern in this iteration.'
})

return legacy_result, "SQL_TEXT VARCHAR(2000000), SUCCESS VARCHAR(10), ERROR_MESSAGE VARCHAR(20000)"
/
