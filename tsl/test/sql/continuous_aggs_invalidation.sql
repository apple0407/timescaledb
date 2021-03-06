-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

-- Disable background workers since we are testing manual refresh
\c :TEST_DBNAME :ROLE_SUPERUSER
SELECT _timescaledb_internal.stop_background_workers();
SET ROLE :ROLE_DEFAULT_PERM_USER;
SET datestyle TO 'ISO, YMD';
SET timezone TO 'UTC';

CREATE TABLE conditions (time bigint NOT NULL, device int, temp float);
SELECT create_hypertable('conditions', 'time', chunk_time_interval => 10);

CREATE TABLE measurements (time int NOT NULL, device int, temp float);
SELECT create_hypertable('measurements', 'time', chunk_time_interval => 10);

CREATE OR REPLACE FUNCTION cond_now()
RETURNS bigint LANGUAGE SQL STABLE AS
$$
    SELECT coalesce(max(time), 0)
    FROM conditions
$$;

CREATE OR REPLACE FUNCTION measure_now()
RETURNS int LANGUAGE SQL STABLE AS
$$
    SELECT coalesce(max(time), 0)
    FROM measurements
$$;

SELECT set_integer_now_func('conditions', 'cond_now');
SELECT set_integer_now_func('measurements', 'measure_now');

INSERT INTO conditions
SELECT t, ceil(abs(timestamp_hash(to_timestamp(t)::timestamp))%4)::int,
       abs(timestamp_hash(to_timestamp(t)::timestamp))%40
FROM generate_series(1, 100, 1) t;

INSERT INTO measurements
SELECT * FROM conditions;

-- Show the most recent data
SELECT * FROM conditions
ORDER BY time DESC, device
LIMIT 10;

-- Create two continuous aggregates on the same hypertable to test
-- that invalidations are handled correctly across both of them.
CREATE MATERIALIZED VIEW cond_10
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true)
AS
SELECT time_bucket(BIGINT '10', time) AS bucket, device, avg(temp) AS avg_temp
FROM conditions
GROUP BY 1,2;

CREATE MATERIALIZED VIEW cond_20
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true)
AS
SELECT time_bucket(BIGINT '20', time) AS bucket, device, avg(temp) AS avg_temp
FROM conditions
GROUP BY 1,2;

CREATE MATERIALIZED VIEW measure_10
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true)
AS
SELECT time_bucket(10, time) AS bucket, device, avg(temp) AS avg_temp
FROM measurements
GROUP BY 1,2;

-- There should be three continuous aggregates, two on one hypertable
-- and one on the other:
SELECT mat_hypertable_id, raw_hypertable_id, user_view_name
FROM _timescaledb_catalog.continuous_agg;

-- The continuous aggregates should be empty
SELECT * FROM cond_10
ORDER BY 1 DESC, 2;

SELECT * FROM cond_20
ORDER BY 1 DESC, 2;

SELECT * FROM measure_10
ORDER BY 1 DESC, 2;


-- Must refresh to move the invalidation threshold, or no
-- invalidations will be generated. Initially, there is no threshold
-- set:
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;

-- There should be only "infinite" invalidations in the cagg
-- invalidation log:
SELECT * FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
ORDER BY 1,2,3;

-- Now refresh up to 50, and the threshold should be updated accordingly:
CALL refresh_continuous_aggregate('cond_10', 1, 50);
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;

-- Invalidations should be cleared for the refresh window:
SELECT * FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
ORDER BY 1,2,3;

-- Refreshing below the threshold does not move it:
CALL refresh_continuous_aggregate('cond_10', 20, 49);
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;

-- Nothing changes with invalidations either since the region was
-- already refreshed and no new invalidations have been generated:
SELECT * FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
ORDER BY 1,2,3;

-- Refreshing measure_10 moves the threshold only for the other hypertable:
CALL refresh_continuous_aggregate('measure_10', 1, 30);
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;
SELECT * FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
ORDER BY 1,2,3;

-- Refresh on the second continuous aggregate, cond_20, on the first
-- hypertable moves the same threshold as when refreshing cond_10:
CALL refresh_continuous_aggregate('cond_20', 60, 100);
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;
SELECT * FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
ORDER BY 1,2,3;

-- There should be no hypertable invalidations initially:
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Create invalidations across different ranges. Some of these should
-- be deleted and others cut in different ways when a refresh is
-- run. Note that the refresh window is inclusive in the start of the
-- window but exclusive at the end.

-- Entries that should be left unmodified:
INSERT INTO conditions VALUES (10, 4, 23.7);
INSERT INTO conditions VALUES (10, 5, 23.8), (19, 3, 23.6);
INSERT INTO conditions VALUES (60, 3, 23.7), (70, 4, 23.7);

-- Should see some invaliations in the hypertable invalidation log:
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- Generate some invalidations for the other hypertable
INSERT INTO measurements VALUES (20, 4, 23.7);
INSERT INTO measurements VALUES (30, 5, 23.8), (80, 3, 23.6);

-- Should now see invalidations for both hypertables
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- First refresh a window where we don't have any invalidations. This
-- allows us to see only the copying of the invalidations to the per
-- cagg log without additional processing.
CALL refresh_continuous_aggregate('cond_10', 20, 60);
-- Invalidation threshold remains at 100:
SELECT * FROM _timescaledb_catalog.continuous_aggs_invalidation_threshold
ORDER BY 1,2;

-- Invalidations should be moved from the hypertable invalidation log
-- to the continuous aggregate log, but only for the hypertable that
-- the refreshed aggregate belongs to:
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Now add more invalidations to test a refresh that overlaps with them.
-- Entries that should be deleted:
INSERT INTO conditions VALUES (30, 1, 23.4), (59, 1, 23.4);
INSERT INTO conditions VALUES (20, 1, 23.4), (30, 1, 23.4);
-- Entries that should be cut to the right, leaving an invalidation to
-- the left of the refresh window:
INSERT INTO conditions VALUES (1, 4, 23.7), (25, 1, 23.4);
INSERT INTO conditions VALUES (19, 4, 23.7), (59, 1, 23.4);
-- Entries that should be cut to the left and right, leaving two
-- invalidation entries on each side of the refresh window:
INSERT INTO conditions VALUES (2, 2, 23.5), (60, 1, 23.4);
INSERT INTO conditions VALUES (3, 2, 23.5), (80, 1, 23.4);
-- Entries that should be cut to the left, leaving an invalidation to
-- the right of the refresh window:
INSERT INTO conditions VALUES (60, 3, 23.6), (90, 3, 23.6);
INSERT INTO conditions VALUES (20, 5, 23.8), (100, 3, 23.6);

-- New invalidations in the hypertable invalidation log:
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- But nothing has yet changed in the cagg invalidation log:
SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Refresh to process invalidations for daily temperature:
CALL refresh_continuous_aggregate('cond_10', 20, 60);

-- Invalidations should be moved from the hypertable invalidation log
-- to the continuous aggregate log.
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- Only the cond_10 cagg should have its entries cut:
SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Refresh also cond_20:
CALL refresh_continuous_aggregate('cond_20', 20, 60);

-- The cond_20 cagg should also have its entries cut:
SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Refresh cond_10 to completely remove an invalidation:
CALL refresh_continuous_aggregate('cond_10', 1, 20);

-- The 1-19 invalidation should be deleted:
SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Clear everything between 0 and 100 to make way for new
-- invalidations
CALL refresh_continuous_aggregate('cond_10', 0, 100);

-- Test refreshing with non-overlapping invalidations
INSERT INTO conditions VALUES (20, 1, 23.4), (25, 1, 23.4);
INSERT INTO conditions VALUES (30, 1, 23.4), (46, 1, 23.4);

CALL refresh_continuous_aggregate('cond_10', 1, 40);

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Refresh whithout cutting (in area where there are no
-- invalidations). Merging of overlapping entries should still happen:
INSERT INTO conditions VALUES (15, 1, 23.4), (42, 1, 23.4);

CALL refresh_continuous_aggregate('cond_10', 90, 100);

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

-- Test max refresh window
CALL refresh_continuous_aggregate('cond_10', NULL, NULL);

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       ORDER BY 1,2,3;

SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- TRUNCATE the hypertable to invalidate all its continuous aggregates
TRUNCATE conditions;

-- Now empty
SELECT * FROM conditions;

-- Should see an infinite invalidation entry for conditions
SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- Aggregates still hold data
SELECT * FROM cond_10
ORDER BY 1,2
LIMIT 5;

SELECT * FROM cond_20
ORDER BY 1,2
LIMIT 5;

CALL refresh_continuous_aggregate('cond_10', NULL, NULL);
CALL refresh_continuous_aggregate('cond_20', NULL, NULL);

-- Both should now be empty after refresh
SELECT * FROM cond_10
ORDER BY 1,2;

SELECT * FROM cond_20
ORDER BY 1,2;

-- Insert new data again and refresh
INSERT INTO conditions VALUES
       (1, 1, 23.4), (4, 3, 14.3), (5, 1, 13.6),
       (6, 2, 17.9), (12, 1, 18.3), (19, 3, 28.2),
       (10, 3, 22.3), (11, 2, 34.9), (15, 2, 45.6),
       (21, 1, 15.3), (22, 2, 12.3), (29, 3, 16.3);

CALL refresh_continuous_aggregate('cond_10', NULL, NULL);
CALL refresh_continuous_aggregate('cond_20', NULL, NULL);

-- Should now hold data again
SELECT * FROM cond_10
ORDER BY 1,2;

SELECT * FROM cond_20
ORDER BY 1,2;

-- Truncate one of the aggregates, but first test that we block
-- TRUNCATE ONLY
\set ON_ERROR_STOP 0
TRUNCATE ONLY cond_20;
\set ON_ERROR_STOP 1
TRUNCATE cond_20;

-- Should now be empty
SELECT * FROM cond_20
ORDER BY 1,2;

-- Other aggregate is not affected
SELECT * FROM cond_10
ORDER BY 1,2;

-- Refresh again to bring data back
CALL refresh_continuous_aggregate('cond_20', NULL, NULL);

-- The aggregate should be populated again
SELECT * FROM cond_20
ORDER BY 1,2;

-------------------------------------------------------
-- Test corner cases against a minimal bucket aggregate
-------------------------------------------------------

-- First, clear the table and aggregate
TRUNCATE conditions;
SELECT * FROM conditions;

CALL refresh_continuous_aggregate('cond_10', NULL, NULL);

SELECT * FROM cond_10
ORDER BY 1,2;

CREATE MATERIALIZED VIEW cond_1
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true)
AS
SELECT time_bucket(BIGINT '1', time) AS bucket, device, avg(temp) AS avg_temp
FROM conditions
GROUP BY 1,2;

SELECT mat_hypertable_id AS cond_1_id
FROM _timescaledb_catalog.continuous_agg
WHERE user_view_name = 'cond_1' \gset

-- Test invalidations with bucket size 1
INSERT INTO conditions VALUES (0, 1, 1.0);

SELECT hypertable_id AS hyper_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log
       ORDER BY 1,2,3;

-- Refreshing around the bucket should not update the aggregate
CALL refresh_continuous_aggregate('cond_1', -1, 0);
SELECT * FROM cond_1
ORDER BY 1,2;
CALL refresh_continuous_aggregate('cond_1', 1, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Refresh only the invalidated bucket
CALL refresh_continuous_aggregate('cond_1', 0, 1);

SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       WHERE materialization_id = :cond_1_id
       ORDER BY 1,2,3;

SELECT * FROM cond_1
ORDER BY 1,2;

-- Refresh 1 extra bucket on the left
INSERT INTO conditions VALUES (0, 1, 2.0);
CALL refresh_continuous_aggregate('cond_1', -1, 1);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Refresh 1 extra bucket on the right
INSERT INTO conditions VALUES (0, 1, 3.0);
CALL refresh_continuous_aggregate('cond_1', 0, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Refresh 1 extra bucket on each side
INSERT INTO conditions VALUES (0, 1, 4.0);
CALL refresh_continuous_aggregate('cond_1', -1, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Clear to reset aggregate
TRUNCATE conditions;
CALL refresh_continuous_aggregate('cond_1', NULL, NULL);

-- Test invalidation of size 2
INSERT INTO conditions VALUES (0, 1, 1.0), (1, 1, 2.0);

-- Refresh one bucket at a time
CALL refresh_continuous_aggregate('cond_1', 0, 1);
SELECT * FROM cond_1
ORDER BY 1,2;

CALL refresh_continuous_aggregate('cond_1', 1, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Repeat the same thing but refresh the whole invalidation at once
TRUNCATE conditions;
CALL refresh_continuous_aggregate('cond_1', NULL, NULL);

INSERT INTO conditions VALUES (0, 1, 1.0), (1, 1, 2.0);
CALL refresh_continuous_aggregate('cond_1', 0, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Test invalidation of size 3
TRUNCATE conditions;
CALL refresh_continuous_aggregate('cond_1', NULL, NULL);

INSERT INTO conditions VALUES (0, 1, 1.0), (1, 1, 2.0), (2, 1, 3.0);

-- Invalidation extends beyond the refresh window on both ends
CALL refresh_continuous_aggregate('cond_1', 1, 2);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Should leave one invalidation on each side of the refresh window
SELECT materialization_id AS cagg_id,
       lowest_modified_value AS start,
       greatest_modified_value AS end
       FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log
       WHERE materialization_id = :cond_1_id
       ORDER BY 1,2,3;

-- Refresh the two remaining invalidations
CALL refresh_continuous_aggregate('cond_1', 0, 1);
SELECT * FROM cond_1
ORDER BY 1,2;

CALL refresh_continuous_aggregate('cond_1', 2, 3);
SELECT * FROM cond_1
ORDER BY 1,2;

-- Clear and repeat but instead refresh the whole range in one go. The
-- result should be the same as the three partial refreshes. Use
-- DELETE instead of TRUNCATE to clear this time.
DELETE FROM conditions;
CALL refresh_continuous_aggregate('cond_1', NULL, NULL);
INSERT INTO conditions VALUES (0, 1, 1.0), (1, 1, 2.0), (2, 1, 3.0);

CALL refresh_continuous_aggregate('cond_1', 0, 3);
SELECT * FROM cond_1
ORDER BY 1,2;
