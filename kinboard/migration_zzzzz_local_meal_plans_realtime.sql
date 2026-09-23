-- Local override, not an upstream migration. Mounted into the webapp at
-- /app/migrations/ by kinboard/docker-compose.override.yml, so the upstream
-- entrypoint applies it on every start, after upstream's migration.sql has
-- re-added meal_plans to the publication (it does so on every boot). Named
-- migration_zzzzz_* to sort after upstream's migration_zzzz_* files.
--
-- Why: useMealPlan() upserts meal_plans on every read, and use-realtime.ts
-- refetches that query on any meal_plans event, so two open clients feed each
-- other a write storm (2.4M UPDATEs on 5 rows by 2026-09-23, up to 405/s) that
-- trips realtime's 100 msg/s limit and spikes the kiosk to ~1.6 of 1.8 GB.
-- Nothing is lost: meal_plan_entries, which carries the actual meals, stays
-- published and invalidates the same ["meal-plans"] query.
-- See kinboard/README.md, "Local override: meal_plans realtime".
--
-- Must never fail: the entrypoint retries a failed migration forever.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public' AND tablename = 'meal_plans'
    ) THEN
        ALTER PUBLICATION supabase_realtime DROP TABLE public.meal_plans;
    END IF;
END $$;
