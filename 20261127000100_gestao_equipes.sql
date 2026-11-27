begin;

create table public.panel_team_assignments (
  user_id uuid primary key references public.panel_profiles(user_id) on delete cascade,
  registration text not null references public.panel_staff(registration) on delete cascade,
  role text not null check (role in ('supervisor','assistant')),
  sector text not null check (sector in ('envase','refinaria')),
  shift text check (shift in ('A','B','C','G')),
  check ((role='assistant')=(shift is not null))
);
create unique index panel_team_one_supervisor on public.panel_team_assignments(sector) where role='supervisor';
create unique index panel_team_one_assistant on public.panel_team_assignments(sector,shift) where role='assistant';
alter table public.panel_team_assignments enable row level security;
revoke all on public.panel_team_assignments from public, anon, authenticated;

create view public.panel_team_members as
select p.user_id, p.sector, s.registration, s.shift, s.position,
 coalesce(nullif(btrim(s.full_name),''),nullif(btrim(u.raw_user_meta_data->>'name'),''),u.email::text) as name,
 case when p.role='management' then 'coordinator' else coalesce(a.role,'operator') end as role
from public.panel_profiles p join auth.users u on u.id=p.user_id and u.email_confirmed_at is not null
left join public.panel_staff s on s.user_id=p.user_id and (p.role='management' or s.sector=p.sector)
left join public.panel_team_assignments a on a.user_id=p.user_id and a.registration=s.registration and a.sector=s.sector
  and (a.role='supervisor' or a.shift=s.shift)
where p.approved;
revoke all on public.panel_team_members from public, anon, authenticated;

create function public.panel_team_context(target_sector text)
returns jsonb language sql stable security definer set search_path=''
as $$
 select coalesce((select jsonb_build_object('role',m.role,'shift',m.shift,'registration',m.registration)
 from public.panel_team_members m where m.user_id=auth.uid()
   and (m.role='coordinator' or m.sector=target_sector)), '{}'::jsonb);
$$;

create function public.panel_team_can_plan(target_sector text, target_shift text)
returns boolean language sql stable set search_path=''
as $$
 select exists (select 1 from public.panel_team_members m where m.user_id=auth.uid()
 and (m.role='coordinator' or (m.role='assistant' and m.sector=target_sector and m.shift=target_shift)));
$$;

create function public.panel_team_assign(target_user uuid, team_role text)
returns void language plpgsql security definer set search_path=''
as $$
declare employee public.panel_team_members%rowtype;
begin
 if not public.panel_schedule_is_manager() then raise exception 'Coordenação necessária' using errcode='42501'; end if;
 select * into strict employee from public.panel_team_members where user_id=target_user
   and role<>'coordinator' and registration is not null and sector is not null and shift is not null;
 if team_role='operator' then
   delete from public.panel_team_assignments where user_id=target_user;
 elsif team_role in ('assistant','supervisor') then
   insert into public.panel_team_assignments(user_id,registration,role,sector,shift)
   values(target_user,employee.registration,team_role,employee.sector,case when team_role='assistant' then employee.shift end)
   on conflict(user_id) do update set registration=excluded.registration,role=excluded.role,sector=excluded.sector,shift=excluded.shift;
 else raise exception 'Função inválida' using errcode='22023';
 end if;
end;
$$;

create function public.panel_team_directory(target_sector text)
returns table (user_id uuid,name text,role text,sector text,shift text,"position" text,linked boolean)
language sql stable security definer set search_path=''
as $$
 select m.user_id,m.name,m.role,m.sector,m.shift,m.position,m.registration is not null
 from public.panel_team_members m
 where exists(select 1 from public.panel_team_members me where me.user_id=auth.uid()
   and me.role in ('coordinator','supervisor','assistant')
   and (me.role='coordinator' or me.sector=target_sector))
 and (m.role='coordinator' or m.sector=target_sector)
 order by m.role,m.shift,m.name;
$$;

create or replace function public.panel_operation_recipients(target_sector text)
returns table(user_id uuid,name text,shift text)
language sql stable security definer set search_path=''
as $$
 select recipient.user_id,recipient.name,recipient.shift
 from public.panel_team_members sender join public.panel_team_members recipient on recipient.sector=target_sector
 where sender.user_id=auth.uid() and (
  (sender.role='coordinator' and recipient.role in ('supervisor','assistant'))
  or (sender.role='supervisor' and sender.sector=target_sector and recipient.role='assistant')
  or (sender.role='assistant' and sender.sector=target_sector and recipient.role='operator' and sender.shift=recipient.shift)
 )
 order by recipient.name,recipient.user_id;
$$;

alter table public.panel_operation_dispatches add column sender_id uuid references public.panel_profiles(user_id) on delete set null;
update public.panel_operation_dispatches d set sender_id=(select n.sender_id from public.panel_notices n where n.operation_dispatch_id=d.id limit 1);

create or replace function public.panel_send_operation_notice(target_sector text,audience text,target_shift text,target_users uuid[],message_subject text,message_body text)
returns integer language plpgsql security definer set search_path=''
as $$
declare sent integer; dispatch uuid;
begin
 if not exists(select 1 from public.panel_team_members where user_id=auth.uid() and role in ('coordinator','assistant','supervisor')
   and (role='coordinator' or sector=target_sector)) then raise exception 'Gestão do setor necessária' using errcode='42501'; end if;
 if target_sector is null or target_sector not in ('envase','refinaria') or audience is null or audience not in ('people','shift','all')
   or (audience='shift' and (target_shift is null or target_shift not in ('A','B','C','G')))
   or (audience='people' and coalesce(cardinality(target_users),0)=0) then
   raise exception 'Destinatários inválidos' using errcode='22023';
 end if;
 insert into public.panel_operation_dispatches(sector,audience,target_shift,subject,body,sender_id)
 values(target_sector,audience,case when audience='shift' then target_shift end,btrim(message_subject),btrim(message_body),auth.uid()) returning id into dispatch;
 insert into public.panel_notices(recipient_id,sender_id,kind,sector,subject,body,operation_dispatch_id,operation_recipient_name,operation_recipient_shift)
 select r.user_id,auth.uid(),'operation',target_sector,btrim(message_subject),btrim(message_body),dispatch,r.name,r.shift
 from public.panel_operation_recipients(target_sector) r
 where audience='all' or (audience='shift' and r.shift=target_shift) or (audience='people' and r.user_id=any(target_users));
 get diagnostics sent=row_count;
 if sent=0 or (audience='people' and sent<>(select count(distinct v.id) from unnest(target_users) v(id))) then
   raise exception 'Destinatário fora da sua hierarquia ou sem conta ativa' using errcode='22023';
 end if;
 return sent;
end;
$$;

create or replace function public.panel_send_message(target_user uuid,message_subject text,message_body text)
returns void language plpgsql security definer set search_path=''
as $$
declare destination text;
begin
 select sector into destination from public.panel_team_members where user_id=target_user;
 if destination is null or not exists(select 1 from public.panel_operation_recipients(destination) where user_id=target_user) then
   raise exception 'Destinatário fora da sua hierarquia' using errcode='42501';
 end if;
 perform public.panel_send_operation_notice(destination,'people',null,array[target_user],message_subject,message_body);
end;
$$;

create or replace function public.panel_operation_history(target_sector text,before_created_at timestamptz default null,before_id uuid default null)
returns table(id uuid,subject text,body text,audience text,target_shift text,created_at timestamptz,recipients jsonb)
language plpgsql stable security definer set search_path=''
as $$
declare team jsonb:=public.panel_team_context(target_sector);
begin
 if coalesce(team->>'role','operator') not in ('coordinator','assistant','supervisor') then
   raise exception 'Gestão necessária' using errcode='42501';
 end if;
 return query with page as (
   select d.* from public.panel_operation_dispatches d where d.sector=target_sector
     and (team->>'role'='coordinator' or d.sender_id=auth.uid())
     and (before_created_at is null or (d.created_at,d.id)<(before_created_at,before_id))
   order by d.created_at desc,d.id desc limit 11
 )
 select p.id,p.subject,p.body,p.audience,p.target_shift,p.created_at,
   coalesce(jsonb_agg(jsonb_build_object('name',coalesce(n.operation_recipient_name,'Colaborador'),
     'shift',n.operation_recipient_shift,'read_at',n.read_at) order by n.operation_recipient_name,n.id)
     filter (where n.id is not null),'[]'::jsonb)
 from page p left join public.panel_notices n on n.operation_dispatch_id=p.id
 group by p.id,p.subject,p.body,p.audience,p.target_shift,p.created_at order by p.created_at desc,p.id desc;
end;
$$;

alter policy panel_notices_recipient on public.panel_notices using (
 recipient_id=(select auth.uid()) and (read_at is null or read_at>now()-interval '24 hours') and exists(
  select 1 from public.panel_profiles p where p.user_id=(select auth.uid()) and p.approved
  and (panel_notices.kind not in ('schedule','operation') or p.role='management' or p.sector=panel_notices.sector)
 )
);
alter policy panel_notices_recipient_read on public.panel_notices using (
 recipient_id=(select auth.uid()) and read_at is null and exists(
  select 1 from public.panel_profiles p where p.user_id=(select auth.uid()) and p.approved
  and (panel_notices.kind not in ('schedule','operation') or p.role='management' or p.sector=panel_notices.sector)
 )
) with check (recipient_id=(select auth.uid()) and read_at is not null);

create function public.panel_stamp_notice_read()
returns trigger language plpgsql set search_path=''
as $$
begin
 if current_user='authenticated' then new.read_at:=coalesce(old.read_at,clock_timestamp()); end if;
 return new;
end;
$$;
create trigger panel_notice_read_stamp before update of read_at on public.panel_notices
for each row execute function public.panel_stamp_notice_read();

create function public.panel_team_forwardable(target_sector text)
returns table(id uuid,subject text,body text)
language sql stable security definer set search_path=''
as $$
 select n.id,n.subject,n.body from public.panel_notices n
 where n.recipient_id=auth.uid() and n.sector=target_sector and n.operation_dispatch_id is not null
   and (n.read_at is null or n.read_at>now()-interval '24 hours')
   and public.panel_team_context(target_sector)->>'role' in ('supervisor','assistant')
 order by n.created_at desc,n.id desc limit 25;
$$;

revoke all on function public.panel_team_can_plan(text,text),public.panel_stamp_notice_read(),
 public.panel_team_context(text),public.panel_team_directory(text),public.panel_team_assign(uuid,text),
 public.panel_team_forwardable(text) from public,anon,authenticated;
grant execute on function public.panel_team_context(text),public.panel_team_directory(text),public.panel_team_assign(uuid,text),
 public.panel_team_forwardable(text) to authenticated;

commit;
