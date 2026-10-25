-- =====================================================================
--  リアルタイム投票システム  データベース定義（Supabase / PostgreSQL）
--  Supabase の SQL Editor に貼り付けて、1回だけ実行する。
--  何度実行しても壊れないように書いてある（関数・ポリシーは上書き）。
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. テーブル
-- ---------------------------------------------------------------------

-- 管理者（Supabase Auth に登録したユーザーのうち、ここに載せた人だけが管理可能）
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  created_at timestamptz not null default now()
);

-- セッション（＝1つのシンポジウム）
create table if not exists public.events (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,            -- 参加コード（URLに入る）
  title              text not null,
  projector_key      text not null default encode(gen_random_bytes(12), 'hex'), -- 投影画面用の鍵
  active_question_id uuid,                            -- いま聴衆に表示中の質問
  is_open            boolean not null default true,   -- 参加受付中か
  created_at         timestamptz not null default now()
);

-- プロジェクト（＝1つのPowerPoint・1つのシンポジウム）の番号・暗号・デザイン
create sequence if not exists public.project_no_seq start 1;
alter table public.events add column if not exists project_no text;
alter table public.events add column if not exists theme      jsonb not null default '{}'::jsonb;
alter table public.events add column if not exists require_nickname boolean not null default true;
update public.events set project_no = 'P-' || lpad(nextval('public.project_no_seq')::text, 4, '0') where project_no is null;
do $$ begin
  alter table public.events add constraint events_project_no_key unique (project_no);
exception when duplicate_object or duplicate_table then null; end $$;

-- 暗号（ハッシュのみ保存。平文は保存しない）。画面からは読めない別表に置く
create table if not exists public.project_secrets (
  event_id  uuid primary key references public.events(id) on delete cascade,
  pass_hash text not null
);

-- 編集者（プロジェクトごと）。role：owner＝メイン編集者／editor＝共同編集者。編集できる範囲は同じ
create table if not exists public.project_members (
  event_id  uuid not null references public.events(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  email     text,
  role      text not null default 'editor' check (role in ('owner','editor')),
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
-- 利用を許可された人（全体管理者＝伊東が許可したメールアドレスだけが、アドインと管理画面を使える）
create table if not exists public.approved_users (
  email       text primary key,             -- 小文字で保存
  note        text,                          -- 氏名・所属などのメモ
  approved_by text,
  approved_at timestamptz not null default now()
);

-- 暗号の総当たり対策（1時間に10回まで）
create table if not exists public.join_attempts (
  user_id uuid not null, at timestamptz not null default now()
);
-- 背景画像（スライドの背景に敷く。画像は縮小してから保存）
create table if not exists public.backgrounds (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  name       text,
  data       text not null,           -- data URL（JPEG）
  created_at timestamptz not null default now(),
  check (char_length(data) < 1500000)
);

-- 質問
create table if not exists public.questions (
  id               uuid primary key default gen_random_uuid(),
  event_id         uuid not null references public.events(id) on delete cascade,
  qkey             text not null,                     -- スライド埋め込み用の短い名前（例: Q1）
  sort_order       int  not null default 0,
  type             text not null,                     -- single / multiple / text / rank / rating / qa / ideas
  title            text not null,
  description      text,
  min_select       int  not null default 1,           -- 複数選択の最小数
  max_select       int  not null default 1,           -- 複数選択の最大数
  rank_count       int,                               -- 順位付けする数（null＝全選択肢）
  max_text_answers int  not null default 3,           -- 自由記載：1人あたり投稿数
  max_text_length  int  not null default 40,          -- 自由記載：文字数上限
  voting_open      boolean not null default true,     -- 投票受付中か
  results_visible  boolean not null default true,     -- 投影画面に結果を出すか
  display_mode     text not null default 'both'     check (display_mode in ('percent','count','both')),
  sort_mode        text not null default 'original' check (sort_mode in ('original','desc')),
  text_view        text not null default 'cloud'    check (text_view in ('cloud','list')),
  allow_change     boolean not null default true,     -- 投票のやり直しを許すか
  created_at       timestamptz not null default now(),
  unique (event_id, qkey),
  check (min_select >= 1 and max_select >= min_select),
  check (rank_count is null or rank_count >= 1),
  check (max_text_answers between 1 and 20),
  check (max_text_length between 5 and 200)
);

-- 形式の制約（評価＝rating を追加。既存の環境に再実行しても安全）
alter table public.questions drop constraint if exists questions_type_check;
alter table public.questions add constraint questions_type_check
  check (type in ('single','multiple','text','rank','rating','qa','ideas'));
-- Q&A・アイデア募集の、スライドへの出し方（pick＝選んだ投稿だけ／top＝賛同の多い順）
alter table public.questions add column if not exists board_mode text not null default 'pick';
do $$ begin
  alter table public.questions add constraint questions_board_mode_check check (board_mode in ('pick','top'));
exception when duplicate_object then null; end $$;

-- 票のリセット回数（聴衆の画面を未投票に戻す合図。既存の環境に再実行しても安全）
alter table public.questions add column if not exists reset_count int not null default 0;

do $$ begin
  alter table public.events
    add constraint events_active_question_fk
    foreign key (active_question_id) references public.questions(id) on delete set null;
exception when duplicate_object then null; end $$;

-- 選択肢
create table if not exists public.options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  sort_order  int  not null default 0,
  label       text not null
);

-- クイズ（正解つき選択式）。既存の環境に再実行しても安全
alter table public.questions add column if not exists quiz   boolean not null default false; -- クイズとして出すか
alter table public.questions add column if not exists reveal boolean not null default false; -- 正解を公開したか
alter table public.options   add column if not exists is_correct boolean not null default false;

-- 回答者による選択肢の追加（「その他」を自分で書く）。既存の環境に再実行しても安全
alter table public.questions add column if not exists allow_add boolean not null default false;
alter table public.options   add column if not exists user_added boolean not null default false;

-- 上限：作成者が作る選択肢は10件まで、複数選択の上限も10件まで
do $$ begin
  alter table public.questions add constraint questions_max_select_limit check (max_select <= 10);
exception when duplicate_object then null; end $$;

create or replace function public._limit_options() returns trigger
language plpgsql as $$
begin
  if not new.user_added and
     (select count(*) from public.options where question_id = new.question_id and not user_added
        and id is distinct from new.id) >= 10 then
    raise exception 'too_many_options';
  end if;
  return new;
end $$;
drop trigger if exists trg_limit_options on public.options;
create trigger trg_limit_options before insert or update of user_added, question_id on public.options
  for each row execute function public._limit_options();

-- 参加者（個人情報は持たない。nickname が null なら匿名）
create table if not exists public.participants (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  token      text not null default encode(gen_random_bytes(16), 'hex'),
  nickname   text,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);

-- 選択式の投票（単一・複数・順位付け）
create table if not exists public.choice_votes (
  question_id    uuid not null references public.questions(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  option_id      uuid not null references public.options(id) on delete cascade,
  rank           int,                                 -- 順位付けのみ（1＝1位）
  created_at     timestamptz not null default now(),
  primary key (question_id, participant_id, option_id)
);

-- 自由記載
create table if not exists public.text_answers (
  id             uuid primary key default gen_random_uuid(),
  question_id    uuid not null references public.questions(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  body           text not null,
  hidden         boolean not null default false,      -- モデレーションで非表示
  created_at     timestamptz not null default now()
);

-- Q&A・アイデア募集：スライドに出す印・回答済みの印・賛同（いいね）
alter table public.text_answers add column if not exists featured boolean not null default false;
alter table public.text_answers add column if not exists answered boolean not null default false;
create table if not exists public.reactions (
  answer_id      uuid not null references public.text_answers(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (answer_id, participant_id)
);

create index if not exists idx_questions_event on public.questions(event_id, sort_order);
create index if not exists idx_options_q       on public.options(question_id, sort_order);
create index if not exists idx_votes_q         on public.choice_votes(question_id);
create index if not exists idx_votes_opt       on public.choice_votes(option_id);
create index if not exists idx_texts_q         on public.text_answers(question_id);
create index if not exists idx_part_event      on public.participants(event_id);
create index if not exists idx_react_answer    on public.reactions(answer_id);

-- ---------------------------------------------------------------------
-- 2. 権限（RLS）
--    聴衆（anon）はテーブルを直接読み書きできない。下の関数経由のみ。
--    管理者（admins に登録された authenticated ユーザー）は全操作可能。
-- ---------------------------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

alter table public.admins       enable row level security;
alter table public.events       enable row level security;
alter table public.questions    enable row level security;
alter table public.options      enable row level security;
alter table public.participants enable row level security;
alter table public.choice_votes enable row level security;
alter table public.text_answers enable row level security;
alter table public.reactions    enable row level security;

-- （旧版の互換用）個別の利用許可は使わない。ログインしていれば true
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$ select auth.uid() is not null; $$;
-- 編集できるか：全体管理者、またはそのプロジェクトのメンバー（メイン編集者・共同編集者）
create or replace function public.can_edit(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.project_members m where m.event_id = p_event and m.user_id = auth.uid());
$$;
create or replace function public.q_event(p_q uuid) returns uuid
language sql stable security definer set search_path = public as $$ select event_id from public.questions where id = p_q; $$;
create or replace function public.a_event(p_a uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select q.event_id from public.text_answers t join public.questions q on q.id = t.question_id where t.id = p_a; $$;

alter table public.project_members enable row level security;
alter table public.join_attempts   enable row level security;
alter table public.backgrounds     enable row level security;
alter table public.project_secrets enable row level security;
alter table public.approved_users  enable row level security;   -- 方針を作らない＝関数経由以外では誰も読めない

drop policy if exists admins_self        on public.admins;
drop policy if exists events_admin       on public.events;
drop policy if exists questions_admin    on public.questions;
drop policy if exists options_admin      on public.options;
drop policy if exists participants_admin on public.participants;
drop policy if exists votes_admin        on public.choice_votes;
drop policy if exists texts_admin        on public.text_answers;
drop policy if exists reactions_admin    on public.reactions;
drop policy if exists events_edit        on public.events;
drop policy if exists events_admin_ins   on public.events;
drop policy if exists questions_edit     on public.questions;
drop policy if exists options_edit       on public.options;
drop policy if exists participants_edit  on public.participants;
drop policy if exists votes_edit         on public.choice_votes;
drop policy if exists texts_edit         on public.text_answers;
drop policy if exists reactions_edit     on public.reactions;
drop policy if exists members_view       on public.project_members;
drop policy if exists backgrounds_edit   on public.backgrounds;
drop policy if exists events_upd         on public.events;
drop policy if exists approved_admin     on public.approved_users;
drop policy if exists events_del         on public.events;

create policy admins_self       on public.admins          for select to authenticated using (public.is_admin() or user_id = auth.uid());
-- プロジェクト本体：メンバーは閲覧・更新、削除は全体管理者のみ（作成は create_project 関数経由）
create policy events_edit       on public.events          for select to authenticated using (public.can_edit(id));
create policy events_upd        on public.events          for update to authenticated using (public.can_edit(id)) with check (public.can_edit(id));
create policy events_del        on public.events          for delete to authenticated using (public.is_admin());
create policy questions_edit    on public.questions       for all to authenticated using (public.can_edit(event_id)) with check (public.can_edit(event_id));
create policy options_edit      on public.options         for all to authenticated using (public.can_edit(public.q_event(question_id))) with check (public.can_edit(public.q_event(question_id)));
create policy participants_edit on public.participants    for all to authenticated using (public.can_edit(event_id)) with check (public.can_edit(event_id));
create policy votes_edit        on public.choice_votes    for all to authenticated using (public.can_edit(public.q_event(question_id))) with check (public.can_edit(public.q_event(question_id)));
create policy texts_edit        on public.text_answers    for all to authenticated using (public.can_edit(public.q_event(question_id))) with check (public.can_edit(public.q_event(question_id)));
create policy reactions_edit    on public.reactions       for all to authenticated using (public.can_edit(public.a_event(answer_id))) with check (public.can_edit(public.a_event(answer_id)));
create policy members_view      on public.project_members for select to authenticated using (public.can_edit(event_id));
create policy backgrounds_edit  on public.backgrounds     for all to authenticated using (public.can_edit(event_id)) with check (public.can_edit(event_id));
create policy approved_admin    on public.approved_users  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 3. 関数（聴衆・投影画面が使う窓口）
-- ---------------------------------------------------------------------

-- 内部用：参加者の確認。正しければ event_id を返す
create or replace function public._participant_event(p_pid uuid, p_token text) returns uuid
language sql stable security definer set search_path = public as $$
  select event_id from public.participants where id = p_pid and token = p_token;
$$;

-- 参加（ニックネームは空なら匿名）
create or replace function public.join_event(p_code text, p_nickname text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event public.events;
  v_part  public.participants;
  v_nick  text := nullif(btrim(coalesce(p_nickname, '')), '');
begin
  select * into v_event from public.events where upper(code) = upper(btrim(p_code));
  if v_event.id is null then raise exception 'event_not_found'; end if;
  if not v_event.is_open then raise exception 'event_closed'; end if;
  if v_nick is null and v_event.require_nickname then raise exception 'nickname_required'; end if;
  if v_nick is not null then v_nick := left(v_nick, 20); end if;
  insert into public.participants(event_id, nickname) values (v_event.id, v_nick) returning * into v_part;
  return json_build_object('participant_id', v_part.id, 'token', v_part.token,
                           'nickname', v_part.nickname, 'event_title', v_event.title);
end $$;

-- 参加者の画面状態（いま表示中の質問と、自分の回答）
create or replace function public.get_state(p_code text, p_pid uuid, p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event public.events;
  v_part  public.participants;
  v_q     public.questions;
begin
  select * into v_event from public.events where upper(code) = upper(btrim(p_code));
  if v_event.id is null then raise exception 'event_not_found'; end if;

  select * into v_part from public.participants
   where id = p_pid and token = p_token and event_id = v_event.id;
  if v_part.id is null then
    return json_build_object('event', json_build_object('title', v_event.title, 'is_open', v_event.is_open,
                                     'theme', v_event.theme - 'bg', 'require_nickname', v_event.require_nickname),
                             'participant', null, 'question', null);
  end if;

  -- 最終アクセス時刻は30秒に1回だけ更新（書き込み負荷の抑制）
  if v_part.last_seen < now() - interval '30 seconds' then
    update public.participants set last_seen = now() where id = v_part.id;
  end if;

  select * into v_q from public.questions where id = v_event.active_question_id;

  return json_build_object(
    'event', json_build_object('title', v_event.title, 'is_open', v_event.is_open, 'theme', v_event.theme - 'bg'),
    'participant', json_build_object('nickname', v_part.nickname),
    'question', case when v_q.id is null then null else json_build_object(
        'id', v_q.id, 'type', v_q.type, 'title', v_q.title, 'description', v_q.description,
        'min_select', v_q.min_select, 'max_select', v_q.max_select,
        'rank_count', least(coalesce(v_q.rank_count, 1000000), (select count(*) from public.options where question_id = v_q.id)),
        'max_text_answers', v_q.max_text_answers, 'max_text_length', v_q.max_text_length,
        'voting_open', v_q.voting_open, 'allow_change', v_q.allow_change, 'reset_count', v_q.reset_count,
        'quiz', v_q.quiz, 'reveal', v_q.quiz and v_q.reveal, 'allow_add', v_q.allow_add,
        'options', coalesce((select json_agg(json_build_object('id', o.id, 'label', o.label, 'user_added', o.user_added,
                                    'correct', case when v_q.quiz and v_q.reveal then o.is_correct else null end) order by o.sort_order, o.label)
                               from public.options o where o.question_id = v_q.id), '[]'::json),
        'my_choices', coalesce((select json_agg(json_build_object('option_id', cv.option_id, 'rank', cv.rank) order by cv.rank nulls last)
                                  from public.choice_votes cv where cv.question_id = v_q.id and cv.participant_id = v_part.id), '[]'::json),
        'my_texts', coalesce((select json_agg(t.body order by t.created_at)
                                from public.text_answers t where t.question_id = v_q.id and t.participant_id = v_part.id), '[]'::json),
        'board', case when v_q.type in ('qa','ideas') then coalesce((
            select json_agg(b order by b.likes desc, b.created_at desc) from (
              select t.id, t.body, t.created_at, t.featured, t.answered,
                     (select count(*) from public.reactions r where r.answer_id = t.id) as likes,
                     exists (select 1 from public.reactions r where r.answer_id = t.id and r.participant_id = v_part.id) as liked,
                     t.participant_id = v_part.id as mine
                from public.text_answers t
               where t.question_id = v_q.id and not t.hidden
               order by t.created_at desc limit 200) b), '[]'::json) else null end
      ) end);
end $$;

-- 選択式の投票。順位付けは配列の順番がそのまま順位になる
create or replace function public.submit_choice(p_pid uuid, p_token text, p_qid uuid, p_option_ids uuid[])
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid := public._participant_event(p_pid, p_token);
  v_q        public.questions;
  v_n        int := coalesce(array_length(p_option_ids, 1), 0);
  v_valid    int;
  v_total    int;
  v_exists   boolean;
begin
  if v_event_id is null then raise exception 'invalid_participant'; end if;
  select * into v_q from public.questions where id = p_qid and event_id = v_event_id;
  if v_q.id is null then raise exception 'question_not_found'; end if;
  if v_q.type = 'text' then raise exception 'wrong_type'; end if;
  if not exists (select 1 from public.events where id = v_event_id and active_question_id = v_q.id) then
    raise exception 'question_not_active'; end if;
  if not v_q.voting_open then raise exception 'voting_closed'; end if;

  -- 重複なし・その質問の選択肢であること
  if v_n = 0 then raise exception 'no_selection'; end if;
  if v_n <> (select count(distinct x) from unnest(p_option_ids) x) then raise exception 'duplicate_option'; end if;
  select count(*) into v_valid from public.options where question_id = v_q.id and id = any(p_option_ids);
  if v_valid <> v_n then raise exception 'invalid_option'; end if;

  -- 選択数の検証
  select count(*) into v_total from public.options where question_id = v_q.id;
  if v_q.type in ('single','rating') and v_n <> 1 then raise exception 'select_exactly_one'; end if;
  if v_q.type = 'multiple' and (v_n < v_q.min_select or v_n > v_q.max_select) then raise exception 'select_count_out_of_range'; end if;
  if v_q.type = 'rank' and v_n <> least(coalesce(v_q.rank_count, v_total), v_total) then raise exception 'rank_count_mismatch'; end if;

  select exists (select 1 from public.choice_votes where question_id = v_q.id and participant_id = p_pid) into v_exists;
  if v_exists and not v_q.allow_change then raise exception 'already_voted'; end if;

  delete from public.choice_votes where question_id = v_q.id and participant_id = p_pid;
  insert into public.choice_votes(question_id, participant_id, option_id, rank)
  select v_q.id, p_pid, x.id, case when v_q.type = 'rank' then x.ord::int else null end
    from unnest(p_option_ids) with ordinality as x(id, ord);

  return json_build_object('ok', true, 'changed', v_exists);
end $$;

-- 自由記載の投稿
create or replace function public.submit_text(p_pid uuid, p_token text, p_qid uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid := public._participant_event(p_pid, p_token);
  v_q        public.questions;
  v_body     text := regexp_replace(btrim(coalesce(p_body, '')), '\s+', ' ', 'g');
  v_count    int;
begin
  if v_event_id is null then raise exception 'invalid_participant'; end if;
  select * into v_q from public.questions where id = p_qid and event_id = v_event_id;
  if v_q.id is null then raise exception 'question_not_found'; end if;
  if v_q.type not in ('text','qa','ideas') then raise exception 'wrong_type'; end if;
  if not exists (select 1 from public.events where id = v_event_id and active_question_id = v_q.id) then
    raise exception 'question_not_active'; end if;
  if not v_q.voting_open then raise exception 'voting_closed'; end if;
  if v_body = '' then raise exception 'empty_text'; end if;
  if char_length(v_body) > v_q.max_text_length then raise exception 'text_too_long'; end if;

  select count(*) into v_count from public.text_answers where question_id = v_q.id and participant_id = p_pid;
  if v_count >= v_q.max_text_answers then raise exception 'text_limit_reached'; end if;

  insert into public.text_answers(question_id, participant_id, body) values (v_q.id, p_pid, v_body);
  return json_build_object('ok', true, 'remaining', v_q.max_text_answers - v_count - 1);
end $$;

-- 回答者が選択肢を追加する（上限なし）。同じ文言の選択肢があればそれを使う
create or replace function public.add_option(p_pid uuid, p_token text, p_qid uuid, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid := public._participant_event(p_pid, p_token);
  v_q        public.questions;
  v_label    text := regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g');
  v_opt      public.options;
begin
  if v_event_id is null then raise exception 'invalid_participant'; end if;
  select * into v_q from public.questions where id = p_qid and event_id = v_event_id;
  if v_q.id is null then raise exception 'question_not_found'; end if;
  if v_q.type not in ('single','multiple') or v_q.quiz or not v_q.allow_add then raise exception 'add_not_allowed'; end if;
  if not exists (select 1 from public.events where id = v_event_id and active_question_id = v_q.id) then
    raise exception 'question_not_active'; end if;
  if not v_q.voting_open then raise exception 'voting_closed'; end if;
  if v_label = '' then raise exception 'empty_text'; end if;
  if char_length(v_label) > 40 then raise exception 'text_too_long'; end if;

  select * into v_opt from public.options
   where question_id = v_q.id and lower(regexp_replace(label, '\s', '', 'g')) = lower(regexp_replace(v_label, '\s', '', 'g'))
   limit 1;
  if v_opt.id is not null then
    return json_build_object('id', v_opt.id, 'label', v_opt.label, 'existed', true);
  end if;
  insert into public.options(question_id, sort_order, label, user_added)
  values (v_q.id, 1000 + (select count(*) from public.options where question_id = v_q.id), v_label, true)
  returning * into v_opt;
  return json_build_object('id', v_opt.id, 'label', v_opt.label, 'existed', false);
end $$;

-- 賛同（いいね）の付け外し。自分の投稿には付けられない
create or replace function public.toggle_reaction(p_pid uuid, p_token text, p_answer_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid := public._participant_event(p_pid, p_token);
  v_t        public.text_answers;
  v_liked    boolean;
begin
  if v_event_id is null then raise exception 'invalid_participant'; end if;
  select t.* into v_t from public.text_answers t join public.questions q on q.id = t.question_id
   where t.id = p_answer_id and q.event_id = v_event_id and q.type in ('qa','ideas') and not t.hidden;
  if v_t.id is null then raise exception 'post_not_found'; end if;
  if v_t.participant_id = p_pid then raise exception 'own_post'; end if;
  if exists (select 1 from public.reactions where answer_id = p_answer_id and participant_id = p_pid) then
    delete from public.reactions where answer_id = p_answer_id and participant_id = p_pid; v_liked := false;
  else
    insert into public.reactions(answer_id, participant_id) values (p_answer_id, p_pid); v_liked := true;
  end if;
  return json_build_object('liked', v_liked,
    'likes', (select count(*) from public.reactions where answer_id = p_answer_id));
end $$;

-- 内部用：鍵の確認（投影画面の鍵、または管理者ログイン）
create or replace function public._event_by_key(p_code text, p_key text) returns public.events
language plpgsql stable security definer set search_path = public as $$
declare v_event public.events;
begin
  select * into v_event from public.events where upper(code) = upper(btrim(p_code));
  if v_event.id is null then raise exception 'event_not_found'; end if;
  if not (public.can_edit(v_event.id) or v_event.projector_key = p_key) then raise exception 'forbidden'; end if;
  return v_event;
end $$;

-- 集計結果（投影画面・管理画面用）。p_qkey が空なら表示中の質問
create or replace function public.get_results(p_code text, p_key text, p_qkey text default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_event  public.events := public._event_by_key(p_code, p_key);
  v_q      public.questions;
  v_voters int;
  v_k      int;
  v_admin  boolean := public.can_edit(v_event.id);
begin
  if p_qkey is null or p_qkey = '' then
    select * into v_q from public.questions where id = v_event.active_question_id;
  else
    select * into v_q from public.questions where event_id = v_event.id and upper(qkey) = upper(p_qkey);
  end if;

  if v_q.id is null then
    return json_build_object('event', json_build_object('title', v_event.title, 'code', v_event.code, 'theme', v_event.theme),
      'question', null,
      'participants', (select count(*) from public.participants where event_id = v_event.id));
  end if;

  if v_q.type in ('text','qa','ideas') then
    select count(distinct participant_id) into v_voters from public.text_answers where question_id = v_q.id;
  else
    select count(distinct participant_id) into v_voters from public.choice_votes where question_id = v_q.id;
  end if;

  select least(coalesce(v_q.rank_count, count(*)), count(*)) into v_k from public.options where question_id = v_q.id;

  return json_build_object(
    'event', json_build_object('title', v_event.title, 'code', v_event.code, 'theme', v_event.theme),
    'participants', (select count(*) from public.participants where event_id = v_event.id),
    'is_active', v_event.active_question_id is not distinct from v_q.id,
    'question', json_build_object(
      'id', v_q.id, 'qkey', v_q.qkey, 'type', v_q.type, 'title', v_q.title, 'description', v_q.description,
      'min_select', v_q.min_select, 'max_select', v_q.max_select, 'rank_count', v_k,
      'voting_open', v_q.voting_open, 'results_visible', v_q.results_visible,
      'display_mode', v_q.display_mode, 'sort_mode', v_q.sort_mode, 'text_view', v_q.text_view,
      'quiz', v_q.quiz, 'reveal', v_q.quiz and v_q.reveal, 'board_mode', v_q.board_mode, 'allow_add', v_q.allow_add),
    'voters', v_voters,
    'options', coalesce((
      select json_agg(json_build_object(
               'id', o.id, 'label', o.label, 'sort_order', o.sort_order, 'user_added', o.user_added,
               'correct', case when v_q.quiz and (v_q.reveal or v_admin) then o.is_correct else null end,
               'count',  (select count(*) from public.choice_votes cv where cv.option_id = o.id),
               'first',  (select count(*) from public.choice_votes cv where cv.option_id = o.id and cv.rank = 1),
               'points', (select coalesce(sum(v_k - cv.rank + 1), 0) from public.choice_votes cv where cv.option_id = o.id and cv.rank is not null)
             ) order by o.sort_order, o.label)
        from public.options o where o.question_id = v_q.id), '[]'::json),
    'texts', case when v_q.type in ('text','qa','ideas') then coalesce((
      select json_agg(json_build_object('id', t.id, 'body', t.body, 'hidden', t.hidden,
                                        'created_at', t.created_at, 'featured', t.featured, 'answered', t.answered,
                                        'likes', (select count(*) from public.reactions r where r.answer_id = t.id),
                                        'nickname', case when v_admin then p.nickname else null end)
                      order by t.created_at desc)
        from public.text_answers t join public.participants p on p.id = t.participant_id
       where t.question_id = v_q.id and (not t.hidden or v_admin)), '[]'::json)
      else '[]'::json end
  );
end $$;

-- 投影画面から質問を切り替える（スライド連動用）
create or replace function public.activate_question(p_code text, p_key text, p_qkey text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_event public.events := public._event_by_key(p_code, p_key);
  v_qid   uuid;
begin
  select id into v_qid from public.questions where event_id = v_event.id and upper(qkey) = upper(p_qkey);
  if v_qid is null then raise exception 'question_not_found'; end if;
  update public.events set active_question_id = v_qid where id = v_event.id;
  return json_build_object('ok', true, 'question_id', v_qid);
end $$;

-- ---------------------------------------------------------------------
-- 4. リセット（管理者のみ）
-- ---------------------------------------------------------------------

-- 1つの質問の票と回答を消去
create or replace function public.reset_question_votes(p_qid uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_votes int; v_texts int;
begin
  if not public.can_edit(public.q_event(p_qid)) then raise exception 'forbidden'; end if;
  delete from public.choice_votes where question_id = p_qid; get diagnostics v_votes = row_count;
  delete from public.text_answers where question_id = p_qid; get diagnostics v_texts = row_count;
  delete from public.options where question_id = p_qid and user_added;
  update public.questions set reset_count = reset_count + 1, reveal = false where id = p_qid;
  return json_build_object('ok', true, 'votes', v_votes, 'texts', v_texts);
end $$;

-- セッション全体のリセット
--   p_include_participants = false：全質問の票と回答だけを消去（参加者はそのまま）
--   p_include_participants = true ：参加者も消去し、表示中の質問も解除（本番用にまっさらにする）
create or replace function public.reset_event(p_event_id uuid, p_include_participants boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare v_votes int; v_texts int; v_parts int := 0;
begin
  if not public.can_edit(p_event_id) then raise exception 'forbidden'; end if;
  delete from public.choice_votes cv using public.questions q
   where q.id = cv.question_id and q.event_id = p_event_id;
  get diagnostics v_votes = row_count;
  delete from public.text_answers t using public.questions q
   where q.id = t.question_id and q.event_id = p_event_id;
  get diagnostics v_texts = row_count;
  delete from public.options o using public.questions q
   where q.id = o.question_id and q.event_id = p_event_id and o.user_added;
  update public.questions set reset_count = reset_count + 1, reveal = false where event_id = p_event_id;
  if p_include_participants then
    delete from public.participants where event_id = p_event_id;
    get diagnostics v_parts = row_count;
    update public.events set active_question_id = null where id = p_event_id;
  end if;
  return json_build_object('ok', true, 'votes', v_votes, 'texts', v_texts, 'participants', v_parts);
end $$;

-- ---------------------------------------------------------------------
-- 5. プロジェクト（番号＋暗号）と共同編集者
-- ---------------------------------------------------------------------

-- 内部用：暗号の生成（読み間違えやすい文字を除いた英数字＋記号、12文字）
create or replace function public._new_passphrase() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789#%+=@';
  b bytea := gen_random_bytes(12); r text := ''; i int;
begin
  for i in 0..11 loop r := r || substr(a, (get_byte(b, i) % length(a)) + 1, 1); end loop;
  return substr(r,1,4) || '-' || substr(r,5,4) || '-' || substr(r,9,4);
end $$;

-- 最初の全体管理者の登録（管理者が1人もいないときだけ、ログイン中の本人を登録）
create or replace function public.claim_first_admin() returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if exists (select 1 from public.admins) then raise exception 'admin_exists'; end if;
  insert into public.admins(user_id, email) select id, email from auth.users where id = auth.uid();
  return json_build_object('ok', true);
end $$;

-- プロジェクトの作成（ログインしている人なら誰でも。作成者がメイン編集者になる）
--   p_pass：共同編集者に伝えるパスワード（8文字以上）。空なら自動で作る。平文は作成時にだけ返す
drop function if exists public.create_project(text, text);
create or replace function public.create_project(p_title text, p_code text, p_pass text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_e public.events; v_code text := upper(btrim(p_code));
  v_pass text := nullif(btrim(coalesce(p_pass, '')), '');
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if v_code !~ '^[A-Z0-9_-]{2,16}$' then raise exception 'bad_code'; end if;
  if v_pass is null then v_pass := public._new_passphrase();
  elsif char_length(v_pass) < 8 then raise exception 'pass_too_short'; end if;
  insert into public.events(code, title, project_no)
  values (v_code, btrim(p_title), 'P-' || lpad(nextval('public.project_no_seq')::text, 4, '0'))
  returning * into v_e;
  insert into public.project_secrets(event_id, pass_hash) values (v_e.id, crypt(v_pass, gen_salt('bf')));
  insert into public.project_members(event_id, user_id, email, role)
  select v_e.id, id, email, 'owner' from auth.users where id = auth.uid();
  return json_build_object('id', v_e.id, 'project_no', v_e.project_no, 'passphrase', v_pass, 'code', v_e.code);
end $$;

-- 共同編集者として参加（プロジェクト番号＋暗号）
create or replace function public.join_project(p_project_no text, p_passphrase text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_e public.events;
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  delete from public.join_attempts where at < now() - interval '1 hour';
  if (select count(*) from public.join_attempts where user_id = auth.uid()) >= 10 then raise exception 'too_many_attempts'; end if;
  insert into public.join_attempts(user_id) values (auth.uid());
  select e.* into v_e from public.events e join public.project_secrets ps on ps.event_id = e.id
   where upper(e.project_no) = upper(btrim(p_project_no))
     and ps.pass_hash = crypt(btrim(p_passphrase), ps.pass_hash);
  -- 失敗時は例外にせず結果を返す（例外にすると試行回数の記録まで取り消され、回数制限が効かないため）
  if v_e.id is null then return json_build_object('ok', false, 'error', 'bad_project_or_pass'); end if;
  insert into public.project_members(event_id, user_id, email, role)
  select v_e.id, id, email, 'editor' from auth.users where id = auth.uid()
  on conflict (event_id, user_id) do nothing;
  return json_build_object('ok', true, 'id', v_e.id, 'project_no', v_e.project_no, 'title', v_e.title, 'code', v_e.code);
end $$;

-- パスワードの変更（メイン編集者または全体管理者）。空なら自動で作る。参加済みの人はそのまま
drop function if exists public.rotate_passphrase(uuid);
create or replace function public.rotate_passphrase(p_event_id uuid, p_new text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_pass text := nullif(btrim(coalesce(p_new, '')), '');
begin
  if not (public.is_admin() or exists (select 1 from public.project_members
          where event_id = p_event_id and user_id = auth.uid() and role = 'owner')) then raise exception 'forbidden'; end if;
  if v_pass is null then v_pass := public._new_passphrase();
  elsif char_length(v_pass) < 8 then raise exception 'pass_too_short'; end if;
  insert into public.project_secrets(event_id, pass_hash) values (p_event_id, crypt(v_pass, gen_salt('bf')))
  on conflict (event_id) do update set pass_hash = excluded.pass_hash;
  return json_build_object('passphrase', v_pass);
end $$;

-- 編集者の除外・メイン編集者の交代（メイン編集者または全体管理者）
create or replace function public.set_member(p_event_id uuid, p_user_id uuid, p_role text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or exists (select 1 from public.project_members
          where event_id = p_event_id and user_id = auth.uid() and role = 'owner')) then raise exception 'forbidden'; end if;
  if p_role = 'remove' then
    delete from public.project_members where event_id = p_event_id and user_id = p_user_id;
  elsif p_role in ('owner','editor') then
    update public.project_members set role = p_role where event_id = p_event_id and user_id = p_user_id;
  else raise exception 'bad_role'; end if;
  return json_build_object('ok', true);
end $$;

-- 自分が編集できるプロジェクトの一覧
create or replace function public.my_projects() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'is_admin', public.is_admin(),
    'approved', public.is_approved(),
    'email', (select email from auth.users where id = auth.uid()),
    'admins_exist', exists (select 1 from public.admins),
    'projects', coalesce((select json_agg(json_build_object(
        'id', e.id, 'project_no', e.project_no, 'code', e.code, 'title', e.title, 'theme', e.theme,
        'projector_key', e.projector_key, 'is_open', e.is_open, 'require_nickname', e.require_nickname,
        'role', coalesce((select m.role from public.project_members m where m.event_id = e.id and m.user_id = auth.uid()), 'admin'))
        order by e.created_at)
      from public.events e where public.can_edit(e.id)), '[]'::json));
$$;

-- 利用の許可（全体管理者のみ）。登録前のメールアドレスを先に許可しておくこともできる
create or replace function public.approve_user(p_email text, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+$' then raise exception 'bad_email'; end if;
  insert into public.approved_users(email, note, approved_by)
  values (v_email, nullif(btrim(coalesce(p_note, '')), ''), (select email from auth.users where id = auth.uid()))
  on conflict (email) do update set note = coalesce(excluded.note, public.approved_users.note);
  return json_build_object('ok', true, 'email', v_email);
end $$;

-- 許可の取り消し（全体管理者のみ）。取り消すと、参加済みのプロジェクトも編集できなくなる
create or replace function public.revoke_user(p_email text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from public.approved_users where email = lower(btrim(p_email));
  return json_build_object('ok', true);
end $$;

-- 許可の一覧と、登録済みで許可待ちの人（全体管理者のみ）
create or replace function public.list_users()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return json_build_object(
    'approved', coalesce((select json_agg(json_build_object('email', a.email, 'note', a.note, 'approved_at', a.approved_at,
        'registered', exists (select 1 from auth.users u where lower(u.email) = a.email)) order by a.approved_at desc)
      from public.approved_users a), '[]'::json),
    'pending', coalesce((select json_agg(json_build_object('email', u.email, 'created_at', u.created_at) order by u.created_at desc)
      from auth.users u
      where not exists (select 1 from public.approved_users a where a.email = lower(u.email))
        and not exists (select 1 from public.admins ad where ad.user_id = u.id)), '[]'::json));
end $$;

-- 背景画像の取得（投影画面用：投影の鍵が必要）
create or replace function public.get_background(p_code text, p_key text, p_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_event public.events := public._event_by_key(p_code, p_key);
begin
  return (select data from public.backgrounds where id = p_id and event_id = v_event.id);
end $$;

-- 実行権限：内部用関数は外部から呼べないようにする
revoke all on function public._participant_event(uuid, text) from public, anon, authenticated;
revoke all on function public._event_by_key(text, text)       from public, anon, authenticated;
grant execute on function public.join_event(text, text)                  to anon, authenticated;
grant execute on function public.get_state(text, uuid, text)             to anon, authenticated;
grant execute on function public.submit_choice(uuid, text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.submit_text(uuid, text, uuid, text)     to anon, authenticated;
grant execute on function public.toggle_reaction(uuid, text, uuid)      to anon, authenticated;
grant execute on function public.add_option(uuid, text, uuid, text)     to anon, authenticated;
grant execute on function public.get_background(text, text, uuid)       to anon, authenticated;
revoke all on function public._new_passphrase() from public, anon, authenticated;
revoke all on function public.claim_first_admin()                  from public, anon;
revoke all on function public.create_project(text, text, text)     from public, anon;
revoke all on function public.join_project(text, text)             from public, anon;
revoke all on function public.rotate_passphrase(uuid, text)        from public, anon;
revoke all on function public.set_member(uuid, uuid, text)         from public, anon;
grant execute on function public.claim_first_admin()               to authenticated;
grant execute on function public.create_project(text, text, text)  to authenticated;
grant execute on function public.join_project(text, text)          to authenticated;
grant execute on function public.rotate_passphrase(uuid, text)     to authenticated;
grant execute on function public.set_member(uuid, uuid, text)      to authenticated;
grant execute on function public.my_projects()                     to authenticated;
revoke all on function public.approve_user(text, text)             from public, anon;
revoke all on function public.revoke_user(text)                    from public, anon;
revoke all on function public.list_users()                         from public, anon;
grant execute on function public.approve_user(text, text)          to authenticated;
grant execute on function public.revoke_user(text)                 to authenticated;
grant execute on function public.list_users()                      to authenticated;
grant execute on function public.is_approved()                     to authenticated;
grant execute on function public.can_edit(uuid)                    to anon, authenticated;
grant execute on function public.get_results(text, text, text)           to anon, authenticated;
grant execute on function public.activate_question(text, text, text)     to anon, authenticated;
grant execute on function public.is_admin()                              to anon, authenticated;
revoke all on function public.reset_question_votes(uuid)        from public, anon;
revoke all on function public.reset_event(uuid, boolean)        from public, anon;
grant execute on function public.reset_question_votes(uuid)     to authenticated;
grant execute on function public.reset_event(uuid, boolean)     to authenticated;

-- =====================================================================
-- 全データを消して作り直すときだけ（通常は実行しない）
-- drop table if exists public.reactions, public.text_answers, public.choice_votes, public.participants,
--   public.options, public.questions, public.events, public.admins cascade;
-- =====================================================================
