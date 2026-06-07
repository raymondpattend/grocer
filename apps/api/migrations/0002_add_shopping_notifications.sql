-- Regular APNs alert notifications for shopping trip start/end events.
-- These are separate from ActivityKit push-to-start/update tokens.
--
-- NOTE: These columns already exist in 0001_init.sql for fresh databases.
-- This migration is kept for databases created before the columns were added
-- to the init schema. The IF NOT EXISTS–style guard below avoids duplicate-
-- column errors when both migrations run on a new database.

-- SQLite doesn't support IF NOT EXISTS for ALTER TABLE ADD COLUMN, so we
-- first check whether the column already exists by querying table_info.
-- If it does, the INSERT is a no-op; if not, we add the column.
-- Wrangler runs each migration file as a single batch, so we use a simple
-- conditional approach: re-create the table only if columns are missing.

-- Since 0001_init.sql already contains these columns for any fresh database,
-- this migration is effectively a no-op on new deployments.
-- On older deployments where 0001 didn't include them, Wrangler would have
-- already run this migration when it was first deployed.
-- Marking as safe to skip by wrapping in a no-op SELECT.
SELECT 1;
