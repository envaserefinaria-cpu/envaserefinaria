begin;
create extension if not exists pg_cron;
select cron.schedule('coamo-alertas-ferias', '15 3 * * *', 'select public.panel_vacation_alerts()');
commit;
