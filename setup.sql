-- 후~ 케이크 쪽지 저장소. Supabase > SQL Editor에 통째로 붙여넣고 Run.
-- 테이블은 RLS로 잠그고 정책을 두지 않는다. 브라우저는 아래 함수로만 접근하므로
-- 비밀 쪽지 내용은 주인공 키가 맞을 때만 서버 밖으로 나간다.

create table if not exists cakes (
  id text primary key default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  owner_key text not null default replace(gen_random_uuid()::text, '-', ''),
  data jsonb not null check (octet_length(data::text) < 4000),
  created_at timestamptz not null default now()
);

create table if not exists notes (
  id bigint generated always as identity primary key,
  cake_id text not null references cakes (id) on delete cascade,
  sender text not null check (char_length(sender) between 1 and 8),
  body text not null check (char_length(body) between 1 and 200),
  color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
  secret boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notes_cake_idx on notes (cake_id, id);

alter table cakes enable row level security;
alter table notes enable row level security;

create or replace function create_cake(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r cakes;
begin
  insert into cakes (data) values (p_data) returning * into r;
  return jsonb_build_object('id', r.id, 'key', r.owner_key);
end $$;

create or replace function get_cake(p_id text, p_key text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c cakes; is_owner boolean;
begin
  select * into c from cakes where id = p_id;
  if not found then return null; end if;
  is_owner := p_key is not null and c.owner_key = p_key;
  return jsonb_build_object(
    'data', c.data,
    'owner', is_owner,
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'from', n.sender, 'c', n.color, 'secret', n.secret,
        'text', case when n.secret and not is_owner then null else n.body end
      ) order by n.id)
      from notes n where n.cake_id = p_id
    ), '[]'::jsonb)
  );
end $$;

create or replace function add_note(p_id text, p_from text, p_text text, p_color text, p_secret boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  perform 1 from cakes where id = p_id for update; -- 동시에 써도 200장 제한이 지켜지게
  if not found then raise exception 'cake_not_found'; end if;
  if (select count(*) from notes where cake_id = p_id) >= 200 then raise exception 'cake_full'; end if;
  insert into notes (cake_id, sender, body, color, secret)
  values (p_id, p_from, p_text, p_color, coalesce(p_secret, false))
  returning id into new_id;
  return new_id;
end $$;

create or replace function delete_note(p_id text, p_key text, p_note bigint) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from cakes where id = p_id and owner_key = p_key) then return false; end if;
  delete from notes where id = p_note and cake_id = p_id;
  return found;
end $$;

revoke all on function create_cake(jsonb) from public;
revoke all on function get_cake(text, text) from public;
revoke all on function add_note(text, text, text, text, boolean) from public;
revoke all on function delete_note(text, text, bigint) from public;
grant execute on function create_cake(jsonb) to anon;
grant execute on function get_cake(text, text) to anon;
grant execute on function add_note(text, text, text, text, boolean) to anon;
grant execute on function delete_note(text, text, bigint) to anon;
