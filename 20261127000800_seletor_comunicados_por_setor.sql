begin;

create or replace function public.panel_operation_recipients(target_sector text)
returns table(user_id uuid,name text,shift text)
language sql stable security definer set search_path=''
as $$
 select distinct recipient.user_id,recipient.name,
  case when recipient.role='coordinator' and staff.sector is distinct from target_sector
       then null else recipient.shift end
 from public.panel_team_members recipient
 left join public.panel_staff staff on staff.registration=recipient.registration
 join auth.users account on account.id=recipient.user_id
 where target_sector in ('envase','refinaria')
   and public.panel_team_context(target_sector)->>'role' in ('coordinator','supervisor','assistant')
   and recipient.user_id<>auth.uid()
   and (
     recipient.sector=target_sector or
     (recipient.role='coordinator' and (staff.sector=target_sector or exists(
       select 1 from public.panel_roster_slots slot
       where slot.sector=target_sector and slot.slot='coordinator'
         and (slot.registration=recipient.registration or lower(slot.contact_email)=lower(account.email))
     )))
   )
 order by 2,1;
$$;

create function public.panel_operation_recipient_directory(target_sector text)
returns table(user_id uuid,name text,shift text)
language sql stable security definer set search_path=''
as $$
 with active as materialized (
  select * from public.panel_operation_recipients(target_sector)
 )
 select a.user_id,a.name,a.shift from active a
 union all
 select null::uuid,s.full_name,s.shift
 from public.panel_staff s
 where s.sector=target_sector and s.user_id is distinct from auth.uid()
   and public.panel_team_context(target_sector)->>'role' in ('coordinator','supervisor','assistant')
   and not exists(
    select 1 from active a join public.panel_team_members member on member.user_id=a.user_id
    where member.registration=s.registration
   )
 order by 2,1;
$$;

revoke all on function public.panel_operation_recipient_directory(text) from public,anon,authenticated;
grant execute on function public.panel_operation_recipient_directory(text) to authenticated;

commit;
