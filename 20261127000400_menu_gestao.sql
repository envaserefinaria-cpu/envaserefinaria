begin;

alter table public.panel_notices add column expires_at timestamptz;
grant select (expires_at) on public.panel_notices to authenticated;

create or replace function public.panel_send_operation_notice(target_sector text,audience text,target_shift text,target_users uuid[],message_subject text,message_body text, duration_hours integer)
returns integer language plpgsql security definer set search_path=''
as $$
declare sent integer; dispatch uuid; expiry timestamptz;
begin
 if not exists(select 1 from public.panel_team_members where user_id=auth.uid() and role in ('coordinator','assistant','supervisor')
   and (role='coordinator' or sector=target_sector)) then raise exception 'Gestão do setor necessária' using errcode='42501'; end if;
 if target_sector is null or target_sector not in ('envase','refinaria') or audience is null or audience not in ('people','shift','all')
   or (audience='shift' and (target_shift is null or target_shift not in ('A','B','C','G')))
   or (audience='people' and coalesce(cardinality(target_users),0)=0) then
   raise exception 'Destinatários inválidos' using errcode='22023';
 end if;
 if duration_hours is null or duration_hours not between 1 and 720 then
   raise exception 'Informe uma duração de 1 a 720 horas' using errcode='22023';
 end if;
 expiry:=now()+make_interval(hours=>duration_hours);
 insert into public.panel_operation_dispatches(sector,audience,target_shift,subject,body,sender_id)
 values(target_sector,audience,case when audience='shift' then target_shift end,btrim(message_subject),btrim(message_body),auth.uid()) returning id into dispatch;
 insert into public.panel_notices(recipient_id,sender_id,kind,sector,subject,body,operation_dispatch_id,operation_recipient_name,operation_recipient_shift,expires_at)
 select r.user_id,auth.uid(),'operation',target_sector,btrim(message_subject),btrim(message_body),dispatch,r.name,r.shift,expiry
 from public.panel_operation_recipients(target_sector) r
 where audience='all' or (audience='shift' and r.shift=target_shift) or (audience='people' and r.user_id=any(target_users));
 get diagnostics sent=row_count;
 if sent=0 or (audience='people' and sent<>(select count(distinct v.id) from unnest(target_users) v(id))) then
   raise exception 'Destinatário fora da sua hierarquia ou sem conta ativa' using errcode='22023';
 end if;
 return sent;
end;
$$;

create or replace function public.panel_send_message(target_user uuid,message_subject text,message_body text, duration_hours integer)
returns void language plpgsql security definer set search_path=''
as $$
declare destination text;
begin
 select sector into destination from public.panel_team_members where user_id=target_user;
 if destination is null or not exists(select 1 from public.panel_operation_recipients(destination) where user_id=target_user) then
   raise exception 'Destinatário fora da sua hierarquia' using errcode='42501';
 end if;
 perform public.panel_send_operation_notice(destination,'people',null,array[target_user],message_subject,message_body,duration_hours);
end;
$$;


-- Preserve older clients during deployment. New clients always pass a duration.
create or replace function public.panel_send_operation_notice(target_sector text,audience text,target_shift text,target_users uuid[],message_subject text,message_body text)
returns integer language sql security invoker set search_path=''
as $$ select public.panel_send_operation_notice(target_sector,audience,target_shift,target_users,message_subject,message_body,72); $$;

create or replace function public.panel_send_message(target_user uuid,message_subject text,message_body text)
returns void language sql security invoker set search_path=''
as $$ select public.panel_send_message(target_user,message_subject,message_body,72); $$;
alter policy panel_notices_recipient on public.panel_notices using (
 recipient_id=(select auth.uid()) and (case when expires_at is not null then expires_at>now() else read_at is null or read_at>now()-interval '24 hours' end) and exists(
  select 1 from public.panel_profiles p where p.user_id=(select auth.uid()) and p.approved
  and (panel_notices.kind not in ('schedule','operation') or p.role='management' or p.sector=panel_notices.sector)
 )
);
alter policy panel_notices_recipient_read on public.panel_notices using (
 recipient_id=(select auth.uid()) and read_at is null and (expires_at is null or expires_at>now()) and exists(
  select 1 from public.panel_profiles p where p.user_id=(select auth.uid()) and p.approved
  and (panel_notices.kind not in ('schedule','operation') or p.role='management' or p.sector=panel_notices.sector)
 )
) with check (recipient_id=(select auth.uid()) and read_at is not null);

create or replace function public.panel_team_forwardable(target_sector text)
returns table(id uuid,subject text,body text)
language sql stable security definer set search_path=''
as $$
 select n.id,n.subject,n.body from public.panel_notices n
 where n.recipient_id=auth.uid() and n.sector=target_sector and n.operation_dispatch_id is not null
   and (case when expires_at is not null then expires_at>now() else read_at is null or read_at>now()-interval '24 hours' end)
   and public.panel_team_context(target_sector)->>'role' in ('supervisor','assistant')
 order by n.created_at desc,n.id desc limit 25;
$$;


create table public.panel_leadership_posts (
 id uuid primary key default gen_random_uuid(),
 sector text not null check(sector in ('envase','refinaria')),
 author_id uuid references public.panel_profiles(user_id) on delete set null default auth.uid(),
 kind text not null check(kind in ('conversation','notice','meeting')),
 subject text check(length(btrim(subject)) between 1 and 100),
 body text not null check(length(btrim(body)) between 1 and 2000),
 created_at timestamptz not null default now(),
 expires_at timestamptz,
 meeting_at timestamptz,
 check((kind='notice')=(expires_at is not null)),
 check((kind='meeting')=(meeting_at is not null)),
 check((kind='conversation')=(subject is null))
);
create index panel_leadership_posts_feed on public.panel_leadership_posts(sector,created_at desc,id desc);
alter table public.panel_leadership_posts enable row level security;
revoke all on public.panel_leadership_posts from public,anon,authenticated;

create function public.panel_leadership_list(target_sector text, before_created_at timestamptz default null, before_id uuid default null)
returns table(id uuid,kind text,subject text,body text,created_at timestamptz,expires_at timestamptz,meeting_at timestamptz,author text)
language plpgsql stable security definer set search_path=''
as $$
begin
 if coalesce(public.panel_team_context(target_sector)->>'role','operator') not in ('coordinator','supervisor','assistant') then
   raise exception 'Acesso restrito à Gestão do setor' using errcode='42501';
 end if;
 return query select p.id,p.kind,p.subject,p.body,p.created_at,p.expires_at,p.meeting_at,
   coalesce((select min(m.name) from public.panel_team_members m where m.user_id=p.author_id),'Conta inativa')
 from public.panel_leadership_posts p
 where p.sector=target_sector and (p.expires_at is null or p.expires_at>now())
   and (before_created_at is null or (p.created_at,p.id)<(before_created_at,before_id))
 order by p.created_at desc,p.id desc limit 31;
end;
$$;

create function public.panel_leadership_send(target_sector text, post_kind text, post_subject text, post_body text,
 meeting_time timestamptz, duration_hours integer)
returns uuid language plpgsql security definer set search_path=''
as $$
declare result uuid;
begin
 if coalesce(public.panel_team_context(target_sector)->>'role','operator') not in ('coordinator','supervisor','assistant') then
   raise exception 'Acesso restrito à Gestão do setor' using errcode='42501';
 end if;
 if post_kind is null or post_kind not in ('conversation','notice','meeting') or coalesce(length(btrim(post_body)),0) not between 1 and 2000
   or (post_kind<>'conversation' and coalesce(length(btrim(post_subject)),0) not between 1 and 100)
   or (post_kind='meeting' and (meeting_time is null or meeting_time<=now()))
   or (post_kind='notice' and (duration_hours is null or duration_hours not between 1 and 720)) then
   raise exception 'Confira os dados antes de publicar' using errcode='22023';
 end if;
 insert into public.panel_leadership_posts(sector,kind,subject,body,meeting_at,expires_at)
 values(target_sector,post_kind,case when post_kind<>'conversation' then btrim(post_subject) end,btrim(post_body),
   case when post_kind='meeting' then meeting_time end,case when post_kind='notice' then now()+make_interval(hours=>duration_hours) end)
 returning id into result;
 return result;
end;
$$;

revoke all on function public.panel_leadership_list(text,timestamptz,uuid),public.panel_leadership_send(text,text,text,text,timestamptz,integer),
 public.panel_send_operation_notice(text,text,text,uuid[],text,text,integer),public.panel_send_message(uuid,text,text,integer)
 from public,anon,authenticated;
grant execute on function public.panel_leadership_list(text,timestamptz,uuid),public.panel_leadership_send(text,text,text,text,timestamptz,integer),
 public.panel_send_operation_notice(text,text,text,uuid[],text,text,integer),public.panel_send_message(uuid,text,text,integer)
 to authenticated;

commit;

