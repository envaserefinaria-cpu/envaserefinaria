begin;

create or replace view public.panel_team_members as
select p.user_id,p.sector,coalesce(s.registration,roster.registration) as registration,
 coalesce(s.shift,roster.shift) as shift,coalesce(s.position,roster.position) as position,
 coalesce(nullif(btrim(s.full_name),''),roster.name,nullif(btrim(u.raw_user_meta_data->>'name'),''),u.email::text) as name,
 case when p.role='management' then 'coordinator'
      when u.is_sso_user is not true and roster.slot='supervisor' then 'supervisor'
      when u.is_sso_user is not true and roster.slot in ('A','B','C') then 'assistant'
      else coalesce(a.role,'operator') end as role
from public.panel_profiles p join auth.users u on u.id=p.user_id and u.email_confirmed_at is not null
left join public.panel_staff s on s.user_id=p.user_id and (p.role='management' or s.sector=p.sector)
left join public.panel_team_assignments a on a.user_id=p.user_id and a.registration=s.registration and a.sector=s.sector
 and (a.role='supervisor' or a.shift=s.shift)
left join lateral (
 select r.slot,employee.registration,employee.shift,employee.position,coalesce(employee.full_name,r.contact_name) as name
 from public.panel_roster_slots r left join public.panel_staff employee on employee.registration=r.registration
 where p.role='operator' and r.sector=p.sector and lower(r.contact_email)=lower(u.email)
  and (r.slot='supervisor' and (r.registration is null or r.registration=s.registration)
    or r.slot in ('A','B','C') and employee.sector=r.sector and employee.shift=r.slot
      and (employee.user_id is null or employee.user_id=p.user_id) and (s.registration is null or s.registration=employee.registration))
 order by r.slot limit 1
) roster on true
where p.approved;

create or replace function public.panel_roster(target_sector text)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare manager boolean:=public.panel_schedule_is_manager();
begin
 if target_sector is null or target_sector not in ('envase','refinaria')
  or coalesce(public.panel_team_context(target_sector)->>'role','operator') not in ('coordinator','supervisor','assistant') then
  raise exception 'Gestão do setor necessária' using errcode='42501';
 end if;
 return jsonb_build_object(
  'people',coalesce((
   select jsonb_agg(jsonb_build_object('registration',s.registration,'name',s.full_name,'shift',s.shift,
    'position',s.position,'sector',s.sector,'manager',coalesce(p.role='management' and p.approved,false))
    order by s.full_name,s.registration)
   from public.panel_staff s left join public.panel_profiles p on p.user_id=s.user_id
   where s.sector=target_sector or (manager and p.role='management' and p.approved)
  ),'[]'::jsonb),
  'slots',coalesce((
   select jsonb_agg(jsonb_build_object('slot',r.slot,'registration',r.registration,'name',coalesce(s.full_name,r.contact_name),
    'email',case when manager then r.contact_email end,
    'active',coalesce(p.approved and u.email_confirmed_at is not null and
      (case when by_email.id is not null then true
       when r.slot='coordinator' then p.role='management'
       else a.sector=r.sector and a.role=(case when r.slot='supervisor' then 'supervisor' else 'assistant' end)
       and (r.slot='supervisor' or (a.shift=r.slot and s.shift=r.slot)) end),false)))
   from public.panel_roster_slots r left join public.panel_staff s on s.registration=r.registration
   left join lateral (
    select m.user_id as id from public.panel_team_members m join auth.users account on account.id=m.user_id
    where lower(account.email)=lower(r.contact_email) and (
      (r.slot='coordinator' and m.role='coordinator') or
      (r.slot='supervisor' and m.sector=r.sector and m.role='supervisor') or
      (r.slot in ('A','B','C') and m.sector=r.sector and m.shift=r.slot and m.role='assistant'))
    order by m.user_id limit 1
   ) by_email on true
   left join public.panel_profiles p on p.user_id=coalesce(s.user_id,by_email.id)
   left join auth.users u on u.id=p.user_id
   left join public.panel_team_assignments a on a.user_id=p.user_id and a.registration=s.registration
   where r.sector=target_sector
  ),'[]'::jsonb)
 );
end;
$$;

create or replace function public.panel_roster_assign(target_sector text, target_slot text, employee_registration text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare person public.panel_staff%rowtype; access_role text; selected_role text; current_user_id uuid;
begin
 if not public.panel_schedule_is_manager() then
  raise exception 'A Coordenação deve atribuir os responsáveis' using errcode='42501';
 end if;
 if target_sector is null or target_sector not in ('envase','refinaria')
  or target_slot is null or target_slot not in ('coordinator','supervisor','A','B','C') then
  raise exception 'Setor ou função inválida' using errcode='22023';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('roster:'||target_sector,0));
 if employee_registration is not null then
  select * into person from public.panel_staff s where registration=employee_registration;
  select p.role into access_role from public.panel_profiles p join auth.users u on u.id=p.user_id
   where p.user_id=person.user_id and p.approved and u.email_confirmed_at is not null;
  if person.registration is null or (
   person.sector is distinct from target_sector and (target_slot<>'coordinator' or access_role is distinct from 'management'))
   or (target_slot in ('A','B','C') and person.shift is distinct from target_slot) then
   raise exception 'Escolha um colaborador do setor e do turno da função' using errcode='22023';
  end if;
 end if;
 selected_role:=case when target_slot='supervisor' then 'supervisor' else 'assistant' end;
 select s.user_id into current_user_id from public.panel_roster_slots r join public.panel_staff s using(registration)
   where r.sector=target_sector and r.slot=target_slot;
 if target_slot<>'coordinator' and current_user_id is not null and current_user_id is distinct from person.user_id then
  delete from public.panel_team_assignments a where a.user_id=current_user_id and a.sector=target_sector
   and a.role=selected_role and a.shift is not distinct from (case when selected_role='assistant' then target_slot end);
 end if;
 if employee_registration is null then
  delete from public.panel_roster_slots r where r.sector=target_sector and r.slot=target_slot;
  return false;
 end if;
 insert into public.panel_roster_slots(sector,slot,registration) values(target_sector,target_slot,employee_registration)
 on conflict(sector,slot) do update set registration=excluded.registration,
  contact_email=case when panel_roster_slots.registration=excluded.registration or
    lower(panel_roster_slots.contact_email)=(select lower(email) from auth.users where id=person.user_id)
    then panel_roster_slots.contact_email end,
  contact_name=null;
 if target_slot='coordinator' then return coalesce(access_role='management',false); end if;
 if access_role is null then return false; end if;
 insert into public.panel_team_assignments(user_id,registration,role,sector,shift)
 values(person.user_id,person.registration,selected_role,target_sector,case when selected_role='assistant' then target_slot end)
 on conflict(user_id) do update set registration=excluded.registration,role=excluded.role,sector=excluded.sector,shift=excluded.shift;
 return true;
end;
$$;

create or replace function public.panel_team_can_plan(target_sector text, target_shift text)
returns boolean language sql stable set search_path=''
as $$
 select exists (select 1 from public.panel_team_members m where m.user_id=auth.uid()
 and (m.role='coordinator' or (m.role='assistant' and m.sector=target_sector and m.shift=case when target_shift='G' then 'A' else target_shift end)));
$$;

create or replace function public.panel_team_alert_managers(target_sector text,target_shift text,title text,content text)
returns integer language plpgsql security definer set search_path=''
as $$
declare delivered integer;
begin
 insert into public.panel_notices(recipient_id,kind,sector,subject,body)
 select m.user_id,'operation',target_sector,title,content from public.panel_team_members m
 where m.role='coordinator' or (m.role='assistant' and m.sector=target_sector and m.shift=case when target_shift='G' then 'A' else target_shift end);
 get diagnostics delivered=row_count;
 return delivered;
end;
$$;

create or replace function public.panel_operation_recipients(target_sector text)
returns table(user_id uuid,name text,shift text)
language sql stable security definer set search_path=''
as $$
 select recipient.user_id,recipient.name,recipient.shift
 from public.panel_team_members sender cross join public.panel_team_members recipient
 left join public.panel_team_assignments a on a.user_id=recipient.user_id and a.registration=recipient.registration
  and a.sector=target_sector and (a.role='supervisor' or a.shift=recipient.shift)
 where sender.user_id=auth.uid() and sender.user_id<>recipient.user_id
   and (recipient.sector=target_sector or a.sector=target_sector) and (
  (sender.role='coordinator' and coalesce(a.role,recipient.role) in ('supervisor','assistant'))
  or (sender.role='supervisor' and sender.sector=target_sector and coalesce(a.role,recipient.role)='assistant')
  or (sender.role='assistant' and sender.sector=target_sector and recipient.role='operator' and sender.shift=case when recipient.shift='G' then 'A' else recipient.shift end)
 )
 order by recipient.name,recipient.user_id;
$$;

commit;
