begin;

create table public.panel_roster_slots (
 sector text not null check (sector in ('envase','refinaria')),
 slot text not null check (slot in ('coordinator','supervisor','A','B','C','G')),
 registration text references public.panel_staff(registration) on delete cascade,
 contact_name text,
 contact_email text check (contact_email is null or contact_email ~* '^[^[:space:]@]+@coamo[.]com[.]br$'),
 check (registration is not null or nullif(btrim(contact_name),'') is not null),
 primary key (sector,slot),
 unique (sector,registration)
);
alter table public.panel_roster_slots enable row level security;
revoke all on public.panel_roster_slots from public,anon,authenticated;

create function public.panel_roster(target_sector text)
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
      (case when r.slot='coordinator' then p.role='management'
       else a.sector=r.sector and a.role=(case when r.slot='supervisor' then 'supervisor' else 'assistant' end)
       and (r.slot='supervisor' or (a.shift=r.slot and s.shift=r.slot)) end),false)))
   from public.panel_roster_slots r left join public.panel_staff s on s.registration=r.registration
   left join public.panel_profiles p on p.user_id=s.user_id
   left join auth.users u on u.id=p.user_id
   left join public.panel_team_assignments a on a.user_id=p.user_id and a.registration=s.registration
   where r.sector=target_sector
  ),'[]'::jsonb)
 );
end;
$$;

create function public.panel_roster_assign(target_sector text, target_slot text, employee_registration text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare person public.panel_staff%rowtype; access_role text; selected_role text; current_user_id uuid;
begin
 if not public.panel_schedule_is_manager() then
  raise exception 'A Coordenação deve atribuir os responsáveis' using errcode='42501';
 end if;
 if target_sector is null or target_sector not in ('envase','refinaria')
  or target_slot is null or target_slot not in ('coordinator','supervisor','A','B','C','G') then
  raise exception 'Setor ou função inválida' using errcode='22023';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('roster:'||target_sector,0));
 if employee_registration is not null then
  select * into person from public.panel_staff s where registration=employee_registration;
  select p.role into access_role from public.panel_profiles p join auth.users u on u.id=p.user_id
   where p.user_id=person.user_id and p.approved and u.email_confirmed_at is not null;
  if person.registration is null or (
   person.sector is distinct from target_sector and (target_slot<>'coordinator' or access_role is distinct from 'management'))
   or (target_slot in ('A','B','C','G') and person.shift is distinct from target_slot) then
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
  or (sender.role='assistant' and sender.sector=target_sector and recipient.role='operator' and sender.shift=recipient.shift)
 )
 order by recipient.name,recipient.user_id;
$$;

revoke all on function public.panel_roster(text),public.panel_roster_assign(text,text,text) from public,anon,authenticated;
grant execute on function public.panel_roster(text),public.panel_roster_assign(text,text,text) to authenticated;
commit;
