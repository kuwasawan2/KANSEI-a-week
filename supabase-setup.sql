-- 週イチ（仮）Supabase 初期設定
-- Supabase の管理画面 → SQL Editor にまるごと貼り付けて「Run」

-- ===== 週の区切り（月曜0:00 JST 始まり） =====
create or replace function public.current_week_start() returns date
language sql stable as $$
  select ((now() at time zone 'Asia/Tokyo')::date
          - (extract(isodow from (now() at time zone 'Asia/Tokyo'))::int - 1))
$$;

-- ===== 参加者の表示名 =====
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 30),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles: 誰でも見られる" on public.profiles for select using (true);
create policy "profiles: 自分の分だけ作れる" on public.profiles for insert to authenticated
  with check (auth.uid() = id);
create policy "profiles: 自分の分だけ直せる" on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- ===== 作品 =====
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  week_start date not null default public.current_week_start(),
  title text not null check (char_length(title) between 1 and 60),
  category text not null check (category in ('product','graphic','ui','video','sound','game','other')),
  image_path text not null,
  hours numeric(5,1),
  tools text check (char_length(tools) <= 200),
  wanted text check (char_length(wanted) <= 400),
  done text check (char_length(done) <= 400),
  next_try text check (char_length(next_try) <= 400),
  feedback_ask text check (char_length(feedback_ask) <= 200),
  created_at timestamptz not null default now(),
  unique (user_id, week_start)            -- 1人1週1作
);

-- 投稿者と週は、送られてきた値に関係なくサーバー側で決める（過去の週への投稿を防ぐ）
create or replace function public.posts_force_fields() returns trigger
language plpgsql as $$
begin
  new.user_id := auth.uid();
  new.week_start := public.current_week_start();
  new.created_at := now();
  return new;
end $$;
create trigger posts_force before insert on public.posts
  for each row execute function public.posts_force_fields();

alter table public.posts enable row level security;
create policy "posts: 誰でも見られる" on public.posts for select using (true);
create policy "posts: ログインした人が自分名義で出せる" on public.posts for insert to authenticated
  with check (auth.uid() = user_id);
create policy "posts: 今週の自分の作品だけ消せる" on public.posts for delete to authenticated
  using (auth.uid() = user_id and week_start = public.current_week_start());

-- ===== コメント =====
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
alter table public.comments enable row level security;
create policy "comments: 誰でも見られる" on public.comments for select using (true);
create policy "comments: ログインした人が自分名義で書ける" on public.comments for insert to authenticated
  with check (auth.uid() = user_id);
create policy "comments: 自分のコメントだけ消せる" on public.comments for delete to authenticated
  using (auth.uid() = user_id);

-- ===== 外から触れる範囲を明示する =====
-- （プロジェクト作成時に「Automatically expose new tables」をオフにした場合に必要。オンでも害はなし）
grant usage on schema public to anon, authenticated;
grant execute on function public.current_week_start() to anon, authenticated;
grant select on public.profiles, public.posts, public.comments to anon, authenticated;
grant insert, update on public.profiles to authenticated;
grant insert, delete on public.posts to authenticated;
grant insert, delete on public.comments to authenticated;

-- ===== 画像の倉庫 =====
-- 公開（誰でも見られる）、1ファイル2MBまで、画像のみ
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('works', 'works', true, 2097152, array['image/jpeg','image/png','image/webp']);

-- 自分のフォルダ（ユーザーID名）にだけ置ける・消せる
create policy "works: 自分のフォルダに置ける" on storage.objects for insert to authenticated
  with check (bucket_id = 'works' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "works: 自分のフォルダから消せる" on storage.objects for delete to authenticated
  using (bucket_id = 'works' and (storage.foldername(name))[1] = auth.uid()::text);
