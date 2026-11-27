begin;

alter table public.panel_staff add column admission_date date
 check (admission_date is null or admission_date >= date '1900-01-01' and admission_date <= (now() at time zone 'America/Sao_Paulo')::date);
grant update (admission_date) on public.panel_staff to authenticated;

create function public.panel_vacation_people_with_admission(target_sector text)
returns table(registration text,full_name text,shift text,admission_date date)
language sql stable security definer set search_path=''
as $$
 select s.registration,s.full_name,s.shift,s.admission_date from public.panel_staff s
 where s.sector=target_sector and public.panel_team_can_plan(s.sector,s.shift) order by s.full_name;
$$;
revoke all on function public.panel_vacation_people_with_admission(text) from public,anon,authenticated;
grant execute on function public.panel_vacation_people_with_admission(text) to authenticated;

create function public.panel_staff_activation_target(manager_id uuid, employee_registration text, corporate_email text, attach_user uuid default null)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare target jsonb;
begin
 target:=public.panel_staff_login_target(manager_id,employee_registration,corporate_email);
 if exists(select 1 from public.panel_roster_slots r where r.registration=employee_registration
   and r.contact_email is not null and lower(r.contact_email)<>corporate_email) then
  raise exception 'O e-mail difere do contato vinculado ao cargo' using errcode='23505';
 end if;
 if target->>'id' is not null and not exists(
  select 1 from auth.users u where u.id=(target->>'id')::uuid and u.email_confirmed_at is not null) then
   raise exception 'O e-mail da conta existente ainda não foi confirmado' using errcode='23505';
 end if;
 if attach_user is not null then
  return public.panel_staff_login_target(manager_id,employee_registration,corporate_email,attach_user);
 end if;
 return target;
end;
$$;
revoke all on function public.panel_staff_activation_target(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.panel_staff_activation_target(uuid,text,text,uuid) to service_role;
commit;
