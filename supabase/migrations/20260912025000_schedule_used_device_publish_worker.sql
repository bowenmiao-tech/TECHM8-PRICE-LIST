-- Drain the website queue every five minutes.
--
-- The POS button publishes a device immediately, but the queue also fills on
-- its own: a device sold at the counter queues a withdrawal, and nobody is
-- going to open the device screen to push it. Without a schedule a sold device
-- would sit on the website until the next manual publish.
--
-- Five minutes is chosen against the failure it prevents: the window in which
-- a customer can see, and try to buy, something already sold. The job only
-- calls out when there is something waiting, so an idle shop makes no requests.

create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'used-device-publish-drain',
  '*/5 * * * *',
  $cron$
    select extensions.net_http_post(
      url := 'https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-used-device-publish',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := '{"limit": 20}'::jsonb,
      timeout_milliseconds := 55000
    )
    where exists (
      select 1 from public.pos_used_device_publish_queue
      where completed_at is null and attempts < 5
    );
  $cron$
);
