-- Example Athena queries against the Iceberg `events` table.
--
-- Athena reads the table directly from the Glue catalog — no extra setup
-- once terraform/iceberg has been applied and the Spark job has created
-- the table. Run these from the Athena console with workgroup that has
-- query results location configured.

-- Switch to the Glue database that holds the Iceberg table.
USE gharchive_iceberg;


-- ── 1. Row count per day ─────────────────────────────────────────────────
-- Filter on created_at directly — Iceberg prunes to the days(created_at)
-- partitions automatically (hidden partitioning). No event_date column
-- needs to exist on the table.

SELECT
    DATE(created_at) AS event_date
  , COUNT(*)         AS event_count
  FROM events
 WHERE created_at >= TIMESTAMP '2026-04-01 00:00:00'
   AND created_at <  TIMESTAMP '2026-04-15 00:00:00'
 GROUP BY DATE(created_at)
 ORDER BY event_date;


-- ── 2. Top 10 event types across the range ───────────────────────────────

SELECT
    type
  , COUNT(*) AS event_count
  FROM events
 WHERE created_at >= TIMESTAMP '2026-04-01 00:00:00'
   AND created_at <  TIMESTAMP '2026-04-15 00:00:00'
 GROUP BY type
 ORDER BY event_count DESC
 LIMIT 10;


-- ── 3. Iceberg snapshot history ──────────────────────────────────────────
-- $snapshots is one of Iceberg's metadata tables, accessible in Athena as
-- <table>$snapshots. Every commit (initial write, subsequent overwrites,
-- compactions) produces a new row here. Useful for:
--   - auditing when the table was last written
--   - picking a snapshot_id for time-travel queries (FOR VERSION AS OF …)
--   - spotting unexpected writes
-- Time-travel queries themselves are Phase 3 scope — this is just a peek.

SELECT
    committed_at
  , snapshot_id
  , operation
  , summary
  FROM "events$snapshots"
 ORDER BY committed_at DESC;
