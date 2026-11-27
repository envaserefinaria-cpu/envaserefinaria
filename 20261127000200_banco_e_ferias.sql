begin;

create function public.panel_team_today() returns date language sql stable set search_path=''
as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create function public.panel_team_alert_managers(target_sector text,target_shift text,title text,content text)
returns integer language plpgsql security definer set search_path=''
as $$
declare delivered integer;
begin
 insert into public.panel_notices(recipient_id,kind,sector,subject,body)
 select m.user_id,'operation',target_sector,title,content from public.panel_team_members m
 where m.role='coordinator' or (m.role='assistant' and m.sector=target_sector and m.shift=target_shift);
 get diagnostics delivered=row_count;
 return delivered;
end;
$$;

create function public.panel_team_schedule_entry(entry_id uuid,person public.panel_staff,entry_type text,start_day date,end_day date)
returns uuid language plpgsql security definer set search_path=''
as $$
declare entry_payload jsonb; result uuid:=coalesce(entry_id,gen_random_uuid());
begin
 perform pg_advisory_xact_lock(hashtextextended(person.registration,0));
 if exists(select 1 from public.panel_schedule_public n where n.sector=person.sector and n.id<>result
   and n.payload->>'employeeId'=person.registration and n.payload->>'type' not in ('shift','event')
   and n.payload->>'start'<=end_day::text and n.payload->>'end'>=start_day::text) then
   raise exception 'Já existe um lançamento publicado neste período' using errcode='22023';
 end if;
 entry_payload:=jsonb_build_object('type',entry_type,'title',person.full_name,'employeeId',person.registration,
   'shift',person.shift,'position',person.position,'start',start_day,'end',end_day,'teamSource',true);
 insert into public.panel_schedule_drafts(id,sector,payload) values(result,person.sector,entry_payload)
 on conflict(id) do update set payload=excluded.payload,updated_at=now();
 insert into public.panel_schedule_public(id,sector,payload,published_by) values(result,person.sector,entry_payload,auth.uid())
 on conflict(id) do update set payload=excluded.payload,published_at=now(),published_by=excluded.published_by;
 return result;
end;
$$;

create or replace function public.panel_notice_on_schedule_change()
returns trigger language plpgsql security definer set search_path=''
as $$
declare affected_sector text; previous_payload jsonb; next_payload jsonb;
begin
 if tg_op='UPDATE' and old.payload is not distinct from new.payload then return null; end if;
 if tg_op<>'INSERT' then affected_sector:=old.sector; previous_payload:=old.payload; end if;
 if tg_op<>'DELETE' then affected_sector:=new.sector; next_payload:=new.payload; end if;
 -- The workflow sends its own private notice to the employee.
 if coalesce(next_payload,previous_payload)->'teamSource'='true'::jsonb then return null; end if;
 insert into public.panel_notices(recipient_id,sender_id,kind,sector,subject,body)
 select p.user_id,auth.uid(),'schedule',affected_sector,'A escala foi atualizada','Consulte a versão publicada em Escala e agenda.'
 from public.panel_profiles p left join public.panel_staff s on s.user_id=p.user_id and s.sector=affected_sector
 where p.approved and p.role='operator' and p.sector=affected_sector and (
  'all' in (previous_payload->>'shift',next_payload->>'shift') or s.shift in (previous_payload->>'shift',next_payload->>'shift')
  or s.registration in (previous_payload->>'employeeId',next_payload->>'employeeId')
 );
 return null;
end;
$$;

create function public.panel_protect_team_draft() returns trigger language plpgsql set search_path=''
as $$
begin
 if current_user='authenticated' and old.payload->'teamSource'='true'::jsonb then
   raise exception 'Use Banco de horas ou Programação de férias para alterar este lançamento' using errcode='42501';
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end;
$$;
create trigger panel_team_draft_protection before update or delete on public.panel_schedule_drafts
for each row execute function public.panel_protect_team_draft();

create or replace function public.panel_publish_schedule(entry_id uuid, visible boolean)
returns void language plpgsql security definer set search_path=''
as $$
declare draft public.panel_schedule_drafts%rowtype;
begin
 if not public.panel_schedule_is_manager() then raise exception 'Somente gestão aprovada pode publicar escalas' using errcode='42501'; end if;
 select * into strict draft from public.panel_schedule_drafts d where d.id=entry_id for update;
 if draft.payload->'teamSource'='true'::jsonb then raise exception 'Use Banco de horas ou Programação de férias' using errcode='42501'; end if;
 if visible is false then delete from public.panel_schedule_public where id=entry_id; return;
 elsif visible is not true then raise exception 'Informe se o lançamento deve ficar visível' using errcode='22023'; end if;
 insert into public.panel_schedule_public(id,sector,payload,published_by)
 values(draft.id,draft.sector,jsonb_strip_nulls(jsonb_build_object(
  'type',draft.payload->'type','title',draft.payload->'title','employeeId',draft.payload->'employeeId',
  'position',draft.payload->'position','shift',draft.payload->'shift','start',draft.payload->'start',
  'end',draft.payload->'end','time',draft.payload->'time','details',draft.payload->'details',
  'cycle',draft.payload->'cycle','fixedDay',draft.payload->'fixedDay','extraDay',draft.payload->'extraDay',
  'code',draft.payload->'code')),auth.uid())
 on conflict(id) do update set payload=excluded.payload,published_by=excluded.published_by,published_at=now();
end;
$$;

create table public.panel_bank_requests (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.panel_profiles(user_id) on delete cascade,
 registration text not null,
 sector text not null,
 shift text not null,
 employee_name text not null,
 requested_date date not null,
 note text not null check(length(note)<=300),
 requested_at timestamptz not null default now(),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 approved_date date,
 decided_by uuid references public.panel_profiles(user_id) on delete set null,
 decided_at timestamptz,
 reason text check(length(reason)<=300),
 schedule_id uuid references public.panel_schedule_public(id)
);
create unique index panel_bank_one_pending_day on public.panel_bank_requests(user_id,requested_date) where status='pending';
create index panel_bank_scope on public.panel_bank_requests(sector,shift,requested_at desc);
alter table public.panel_bank_requests enable row level security;
revoke all on public.panel_bank_requests from public,anon,authenticated;

create function public.panel_bank_list(target_sector text)
returns setof public.panel_bank_requests language sql stable security definer set search_path=''
as $$
 select r.* from public.panel_bank_requests r where r.sector=target_sector
 and (public.panel_team_can_plan(r.sector,r.shift) or (r.user_id=auth.uid()
   and public.panel_team_context(r.sector)->>'role'='operator')) order by r.requested_at desc limit 100;
$$;

create function public.panel_bank_request(target_sector text,request_day date,message text default '')
returns uuid language plpgsql security definer set search_path=''
as $$
declare employee public.panel_team_members%rowtype; result uuid;
begin
 select * into strict employee from public.panel_team_members where user_id=auth.uid() and role='operator'
   and sector=target_sector and registration is not null and shift is not null;
 if request_day is null or request_day<public.panel_team_today() then raise exception 'Informe uma data atual ou futura' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(employee.registration,0));
 if exists(select 1 from public.panel_schedule_public p where p.sector=target_sector
   and p.payload->>'employeeId'=employee.registration and p.payload->>'type' not in ('shift','event')
   and p.payload->>'start'<=request_day::text and p.payload->>'end'>=request_day::text) then
   raise exception 'Já há um lançamento publicado neste dia' using errcode='22023';
 end if;
 insert into public.panel_bank_requests(user_id,registration,sector,shift,employee_name,requested_date,note)
 values(employee.user_id,employee.registration,employee.sector,employee.shift,employee.name,request_day,btrim(coalesce(message,''))) returning id into result;
 perform public.panel_team_alert_managers(employee.sector,employee.shift,'Solicitação de banco de horas',
   employee.name||' solicitou BH em '||to_char(request_day,'DD/MM/YYYY')||'. Confira em Escala e agenda.');
 return result;
end;
$$;

create function public.panel_bank_decide(request_id uuid,decision text,chosen_date date default null,comments text default '')
returns void language plpgsql security definer set search_path=''
as $$
declare r public.panel_bank_requests%rowtype; employee public.panel_staff%rowtype; entry uuid;
begin
 select * into strict r from public.panel_bank_requests where id=request_id for update;
 if not public.panel_team_can_plan(r.sector,r.shift) then raise exception 'A aprovação cabe ao assistente do turno ou à Coordenação' using errcode='42501'; end if;
 if r.status<>'pending' then raise exception 'Esta solicitação já foi decidida' using errcode='22023'; end if;
 if decision='approved' then
   if chosen_date is null or chosen_date<public.panel_team_today() then raise exception 'Informe uma data atual ou futura' using errcode='22023'; end if;
   select * into strict employee from public.panel_staff where user_id=r.user_id and registration=r.registration and sector=r.sector and shift=r.shift;
   entry:=public.panel_team_schedule_entry(null,employee,'bank',chosen_date,chosen_date);
 elsif decision is distinct from 'rejected' or nullif(btrim(comments),'') is null then
   raise exception 'Informe o motivo da reprovação' using errcode='22023';
 end if;
 update public.panel_bank_requests set status=decision,approved_date=case when entry is not null then chosen_date end,
   schedule_id=entry,decided_by=auth.uid(),decided_at=now(),reason=btrim(comments) where id=r.id;
 insert into public.panel_notices(recipient_id,sender_id,kind,sector,subject,body)
 values(r.user_id,auth.uid(),'operation',r.sector,case when entry is null then 'Banco de horas reprovado' else 'Banco de horas aprovado' end,
   case when entry is null then 'Solicitação de '||to_char(r.requested_date,'DD/MM/YYYY')||'. Motivo: '||btrim(comments)
   else 'BH publicado para '||to_char(chosen_date,'DD/MM/YYYY')||'.'||coalesce(' '||nullif(btrim(comments),''),'') end);
end;
$$;

create table public.panel_vacation_periods (
 id uuid primary key default gen_random_uuid(),
 registration text not null references public.panel_staff(registration),
 admission_date date not null,
 accrual_start date not null,
 deadline date not null,
 vacation_start date,
 vacation_end date,
 schedule_id uuid references public.panel_schedule_public(id) deferrable initially deferred,
 requested_at timestamptz,
 request_date date,
 request_note text check(length(request_note)<=300),
 warning_at timestamptz,
 urgent_at timestamptz,
 check (accrual_start>=admission_date and deadline>=accrual_start+interval '12 months'),
 check ((vacation_start is null)=(vacation_end is null)),
 check (vacation_start is null or (vacation_start>=accrual_start+interval '12 months' and vacation_end>=vacation_start and vacation_end<=deadline)),
 unique(registration,accrual_start)
);
alter table public.panel_vacation_periods enable row level security;
revoke all on public.panel_vacation_periods from public,anon,authenticated;

create function public.panel_vacation_people(target_sector text)
returns table(registration text,full_name text,shift text)
language sql stable security definer set search_path=''
as $$
 select s.registration,s.full_name,s.shift from public.panel_staff s
 where s.sector=target_sector and public.panel_team_can_plan(s.sector,s.shift) order by s.full_name;
$$;

create function public.panel_vacation_list(target_sector text)
returns table(id uuid,registration text,full_name text,shift text,admission_date date,accrual_start date,deadline date,
 vacation_start date,vacation_end date,requested_at timestamptz,request_date date,request_note text,priority text)
language sql stable security definer set search_path=''
as $$
 select v.id,s.registration,s.full_name,s.shift,v.admission_date,v.accrual_start,v.deadline,v.vacation_start,v.vacation_end,
   v.requested_at,v.request_date,v.request_note,
   case when v.vacation_start is not null then 'planned' when public.panel_team_today()>v.deadline then 'overdue'
    when public.panel_team_today()>=v.deadline-interval '2 months' then 'urgent'
    when public.panel_team_today()>=v.deadline-interval '6 months' then 'warning' else 'normal' end
 from public.panel_vacation_periods v join public.panel_staff s using(registration)
 where s.sector=target_sector and (public.panel_team_can_plan(s.sector,s.shift)
   or (s.user_id=auth.uid() and public.panel_team_context(s.sector)->>'role'='operator'))
 order by v.deadline,s.full_name;
$$;

create function public.panel_vacation_save(period_id uuid,target_registration text,admission date,accrual date,limit_day date,
 start_day date default null,end_day date default null)
returns uuid language plpgsql security definer set search_path=''
as $$
declare employee public.panel_staff%rowtype; v public.panel_vacation_periods%rowtype; entry uuid; result uuid;
begin
 select * into strict employee from public.panel_staff where registration=target_registration and sector is not null for update;
 if not public.panel_team_can_plan(employee.sector,employee.shift) then raise exception 'Gestão do turno necessária' using errcode='42501'; end if;
 if period_id is not null then
   select * into strict v from public.panel_vacation_periods where id=period_id and registration=target_registration for update;
 end if;
 if admission is null or accrual<admission or accrual is null or limit_day is null or limit_day<accrual+interval '12 months'
   or (start_day is null)<>(end_day is null) or (start_day is not null and
    (start_day<accrual+interval '12 months' or end_day<start_day or end_day>limit_day or
     (start_day<public.panel_team_today() and (start_day,end_day) is distinct from (v.vacation_start,v.vacation_end)))) then
   raise exception 'Confira o aquisitivo e programe o fim das férias até a data limite' using errcode='22023';
 end if;
 if v.schedule_id is not null and start_day is null then
   raise exception 'Informe o novo período completo para alterar férias já publicadas' using errcode='22023';
 end if;
 entry:=v.schedule_id;
 if start_day is not null and (start_day,end_day) is distinct from (v.vacation_start,v.vacation_end) then
   entry:=public.panel_team_schedule_entry(entry,employee,'vacation',start_day,end_day);
 end if;
 insert into public.panel_vacation_periods(id,registration,admission_date,accrual_start,deadline,vacation_start,vacation_end,schedule_id)
 values(coalesce(period_id,gen_random_uuid()),employee.registration,admission,accrual,limit_day,start_day,end_day,entry)
 on conflict(id) do update set admission_date=excluded.admission_date,accrual_start=excluded.accrual_start,deadline=excluded.deadline,
   vacation_start=excluded.vacation_start,vacation_end=excluded.vacation_end,schedule_id=excluded.schedule_id,
   warning_at=case when panel_vacation_periods.deadline=excluded.deadline then panel_vacation_periods.warning_at end,
   urgent_at=case when panel_vacation_periods.deadline=excluded.deadline then panel_vacation_periods.urgent_at end
 returning id into result;
 if start_day is not null and employee.user_id is not null and (start_day,end_day) is distinct from (v.vacation_start,v.vacation_end) then
   insert into public.panel_notices(recipient_id,sender_id,kind,sector,subject,body)
   values(employee.user_id,auth.uid(),'operation',employee.sector,'Férias programadas',
      'Período publicado: '||to_char(start_day,'DD/MM/YYYY')||' a '||to_char(end_day,'DD/MM/YYYY')||'.');
 end if;
 return result;
end;
$$;

create function public.panel_vacation_request(period_id uuid,preferred_date date default null,message text default '')
returns void language plpgsql security definer set search_path=''
as $$
declare employee public.panel_team_members%rowtype; v public.panel_vacation_periods%rowtype;
begin
 select * into strict employee from public.panel_team_members where user_id=auth.uid() and role='operator' and registration is not null;
 select * into strict v from public.panel_vacation_periods where id=period_id and registration=employee.registration for update;
 if v.vacation_start is not null or v.requested_at is not null or preferred_date<v.accrual_start+interval '12 months'
   or preferred_date>v.deadline or preferred_date<public.panel_team_today() then
   raise exception 'Já existe programação ou a data fica fora do período disponível' using errcode='22023';
 end if;
 update public.panel_vacation_periods set requested_at=now(),request_date=preferred_date,request_note=btrim(coalesce(message,'')) where id=v.id;
 perform public.panel_team_alert_managers(employee.sector,employee.shift,'Pedido de programação de férias',
   employee.name||' solicitou a programação. Limite em '||to_char(v.deadline,'DD/MM/YYYY')||'. Confira em Programação de férias.');
end;
$$;

create function public.panel_vacation_alerts() returns integer language plpgsql security definer set search_path=''
as $$
declare v record; today date:=public.panel_team_today(); urgent boolean; deliveries integer; total integer:=0;
begin
 for v in select p.*,s.full_name,s.sector,s.shift from public.panel_vacation_periods p join public.panel_staff s using(registration)
   where p.vacation_start is null and s.sector is not null and (
     (today>=p.deadline-interval '2 months' and p.urgent_at is null)
     or (today<p.deadline-interval '2 months' and today>=p.deadline-interval '6 months' and p.warning_at is null))
   for update of p skip locked
 loop
   urgent:=today>=v.deadline-interval '2 months';
   deliveries:=public.panel_team_alert_managers(v.sector,v.shift,
     case when urgent then 'Urgente · Programar férias' else 'Planejamento de férias · 6 meses' end,
     v.full_name||' · Turno '||v.shift||'. Prazo em '||to_char(v.deadline,'DD/MM/YYYY')||'. Confira em Programação de férias.');
   if deliveries>0 then
     update public.panel_vacation_periods set warning_at=coalesce(warning_at,now()),
       urgent_at=case when urgent then now() else urgent_at end where id=v.id;
     total:=total+deliveries;
   end if;
 end loop;
 return total;
end;
$$;

revoke all on function public.panel_team_today(),public.panel_team_alert_managers(text,text,text,text),
 public.panel_team_schedule_entry(uuid,public.panel_staff,text,date,date),public.panel_protect_team_draft(),
 public.panel_bank_list(text),public.panel_bank_request(text,date,text),public.panel_bank_decide(uuid,text,date,text),
 public.panel_vacation_people(text),public.panel_vacation_list(text),public.panel_vacation_save(uuid,text,date,date,date,date,date),
 public.panel_vacation_request(uuid,date,text),public.panel_vacation_alerts() from public,anon,authenticated;
grant execute on function public.panel_bank_list(text),public.panel_bank_request(text,date,text),public.panel_bank_decide(uuid,text,date,text),
 public.panel_vacation_people(text),public.panel_vacation_list(text),public.panel_vacation_save(uuid,text,date,date,date,date,date),
 public.panel_vacation_request(uuid,date,text) to authenticated;

commit;
