-- =====================================================================
-- USEI — backend no Supabase (Postgres + Auth + Storage + Realtime)
--
-- Como usar: Supabase → SQL Editor → New query → colar este arquivo
-- inteiro → Run. Pode rodar de novo sem estragar nada (idempotente).
--
-- O que este arquivo monta:
--   • perfis (criados sozinhos no cadastro, com ID USEI-00001...)
--   • anúncios, pedidos, transações, reembolsos
--   • verificação de vendedor (dados privados) + perfil público (selo)
--   • cupons com limite de uso
--   • chat comprador ↔ vendedor (em tempo real)
--   • armazenamento PRIVADO para documento e selfie
--   • regras de segurança (RLS) em todas as tabelas
--   • funções no servidor para o que não pode ficar na mão do navegador:
--     valor do pedido, taxa, cupom, mudança de status, aprovação.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- PERFIS
-- ---------------------------------------------------------------------
create sequence if not exists public.account_seq start 1;

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  account_id    text unique not null default ('USEI-' || lpad(nextval('public.account_seq')::text, 5, '0')),
  name          text not null default '' check (char_length(name) <= 120),
  email         text,
  phone         text check (phone is null or char_length(phone) <= 30),
  photo_url     text check (photo_url is null or photo_url ~* '^https://'),
  role          text not null default 'user' check (role in ('user','admin')),
  banned        boolean not null default false,
  fee_rate      numeric(5,2) check (fee_rate is null or (fee_rate >= 0 and fee_rate <= 100)),
  admin_notes   text,
  verified      boolean not null default false,
  support_phone text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Quem é admin (usado nas regras). SECURITY DEFINER evita recursão de RLS.
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and not banned);
$$;

-- Conta ativa = logada e não suspensa.
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and not banned);
$$;

-- Perfil criado automaticamente quando alguém se cadastra.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email, phone)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)), 120),
    new.email,
    left(nullif(trim(new.raw_user_meta_data->>'phone'), ''), 30)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- E-mail do perfil acompanha a troca de e-mail no login.
create or replace function public.handle_user_email_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email, updated_at = now() where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- O que qualquer visitante pode ver de um vendedor (sem e-mail, sem notas).
create or replace view public.public_profiles as
  select id, name, photo_url, verified,
         case when verified then support_phone end as support_phone,
         created_at
  from public.profiles
  where not banned;

-- ---------------------------------------------------------------------
-- ANÚNCIOS
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id          bigint generated always as identity primary key,
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name        text not null check (char_length(name) between 2 and 120),
  description text check (description is null or char_length(description) <= 4000),
  category    text not null default 'outros'
              check (category in ('eletronicos','ferramentas','esportes','moda','casa','veiculos','games','outros')),
  type        text not null check (type in ('rent','sale','both')),
  rent_price  numeric(12,2) check (rent_price is null or rent_price >= 0),
  sale_price  numeric(12,2) check (sale_price is null or sale_price >= 0),
  location    text check (location is null or char_length(location) <= 120),
  images      text[] not null default '{}' check (coalesce(array_length(images, 1), 0) <= 12),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint products_price_ok check (
    (type = 'rent' and rent_price > 0) or
    (type = 'sale' and sale_price > 0) or
    (type = 'both' and (coalesce(rent_price, 0) > 0 or coalesce(sale_price, 0) > 0))
  )
);
create index if not exists products_active_created_idx on public.products (active, created_at desc);
create index if not exists products_owner_idx on public.products (owner_id);

-- Vitrine pública: anúncios ativos + nome e selo de quem anuncia.
create or replace view public.catalog as
  select p.*, pp.name as owner_name, pp.verified as owner_verified, pp.support_phone as owner_support_phone
  from public.products p
  join public.public_profiles pp on pp.id = p.owner_id
  where p.active;

-- ---------------------------------------------------------------------
-- PEDIDOS, TRANSAÇÕES E REEMBOLSOS (só mudam por funções do servidor)
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id            bigint generated always as identity primary key,
  product_id    bigint references public.products(id) on delete set null,
  product_name  text not null,
  product_image text,
  owner_id      uuid not null references public.profiles(id),
  buyer_id      uuid not null references public.profiles(id),
  type          text not null check (type in ('rent','sale')),
  days          int check (days is null or days between 1 and 365),
  unit_price    numeric(12,2) not null,
  subtotal      numeric(12,2) not null,
  discount      numeric(12,2) not null default 0,
  fee_rate      numeric(5,2) not null,
  fee           numeric(12,2) not null,
  total         numeric(12,2) not null,
  coupon_code   text,
  status        text not null default 'pendente' check (status in ('pendente','confirmado','entregue','cancelado')),
  start_date    date,
  end_date      date,
  cancelled_by  text check (cancelled_by in ('admin','cliente','vendedor')),
  cancelled_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists orders_buyer_idx on public.orders (buyer_id, created_at desc);
create index if not exists orders_owner_idx on public.orders (owner_id, created_at desc);

create table if not exists public.transactions (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references public.orders(id) on delete cascade,
  buyer_id   uuid not null references public.profiles(id),
  owner_id   uuid not null references public.profiles(id),
  amount     numeric(12,2) not null,
  method     text not null default 'plataforma',
  status     text not null default 'em análise'
             check (status in ('em análise','aprovado','finalizado','cancelado','reembolsado')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists transactions_order_idx on public.transactions (order_id);

create table if not exists public.refunds (
  id             bigint generated always as identity primary key,
  order_id       bigint not null references public.orders(id) on delete cascade,
  transaction_id bigint references public.transactions(id) on delete set null,
  buyer_id       uuid not null references public.profiles(id),
  owner_id       uuid not null references public.profiles(id),
  product_name   text,
  amount         numeric(12,2) not null,
  requested_by   text,
  requested_at   timestamptz not null default now(),
  status         text not null default 'aprovado',
  approved_at    timestamptz,
  cancelled_by   text,
  cancelled_at   timestamptz
);

-- ---------------------------------------------------------------------
-- VERIFICAÇÃO DE VENDEDOR (privada: documento, selfie, banco)
-- As fotos ficam no bucket PRIVADO "verificacoes"; aqui só o caminho.
-- ---------------------------------------------------------------------
create table if not exists public.verifications (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  doc_front_path text not null,
  doc_back_path  text not null,
  selfie_path    text not null,
  bank_name      text,
  bank_agency    text,
  bank_account   text,
  pix_key        text,
  support_phone  text,
  status         text not null default 'pendente' check (status in ('pendente','aprovado','rejeitado')),
  submitted_at   timestamptz not null default now(),
  reviewed_at    timestamptz,
  reviewed_by    uuid references public.profiles(id),
  review_note    text
);

-- ---------------------------------------------------------------------
-- CUPONS
-- ---------------------------------------------------------------------
create table if not exists public.coupons (
  code           text primary key check (code ~ '^[A-Z0-9_-]{3,20}$'),
  created_by     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  discount_type  text not null check (discount_type in ('percent','fixed')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  max_uses       int not null default 0 check (max_uses >= 0),
  uses           int not null default 0,
  active         boolean not null default true,
  expires_at     timestamptz,
  created_at     timestamptz not null default now(),
  constraint coupons_percent_ok check (discount_type <> 'percent' or discount_value <= 100)
);

create table if not exists public.coupon_redemptions (
  id         bigint generated always as identity primary key,
  code       text not null references public.coupons(code) on delete cascade,
  order_id   bigint references public.orders(id) on delete set null,
  buyer_id   uuid not null references public.profiles(id),
  discount   numeric(12,2) not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- CHAT
-- ---------------------------------------------------------------------
create table if not exists public.conversations (
  id              bigint generated always as identity primary key,
  product_id      bigint references public.products(id) on delete set null,
  product_name    text,
  buyer_id        uuid not null references public.profiles(id) on delete cascade,
  seller_id       uuid not null references public.profiles(id) on delete cascade,
  last_message_at timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  constraint conversations_unique unique (product_id, buyer_id, seller_id),
  constraint conversations_two_people check (buyer_id <> seller_id)
);

create table if not exists public.messages (
  id              bigint generated always as identity primary key,
  conversation_id bigint not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body            text not null check (char_length(body) between 1 and 2000),
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
create index if not exists messages_conversation_idx on public.messages (conversation_id, created_at);

create or replace function public.touch_conversation() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists on_message_created on public.messages;
create trigger on_message_created after insert on public.messages
  for each row execute function public.touch_conversation();

-- Mensagens chegam na hora (sem ficar perguntando ao servidor).
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
exception when undefined_object then null; end $$;

-- ---------------------------------------------------------------------
-- updated_at automático
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['profiles','products','orders','transactions'] loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format('create trigger touch_%1$s before update on public.%1$s for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- REGRAS DE SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.products           enable row level security;
alter table public.orders             enable row level security;
alter table public.transactions       enable row level security;
alter table public.refunds            enable row level security;
alter table public.verifications      enable row level security;
alter table public.coupons            enable row level security;
alter table public.coupon_redemptions enable row level security;
alter table public.conversations      enable row level security;
alter table public.messages           enable row level security;

-- Perfis: cada um vê e edita o próprio; admin vê todos.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- Pela tabela, a pessoa só muda nome, telefone e foto. Cargo, banimento,
-- taxa, notas e selo só mudam pelas funções de admin.
revoke update on public.profiles from anon, authenticated;
grant update (name, phone, photo_url) on public.profiles to authenticated;
revoke insert, delete on public.profiles from anon, authenticated;

-- Anúncios: ativos são públicos; dono e admin gerenciam.
drop policy if exists products_select on public.products;
create policy products_select on public.products for select using (active or owner_id = auth.uid() or public.is_admin());
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert with check (owner_id = auth.uid() and public.is_active_user());
drop policy if exists products_update on public.products;
create policy products_update on public.products for update
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete using (owner_id = auth.uid() or public.is_admin());

-- Pedidos, transações e reembolsos: só quem participou (ou admin) vê.
-- Ninguém grava direto: só pelas funções create_order / set_order_status.
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select using (buyer_id = auth.uid() or owner_id = auth.uid() or public.is_admin());
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select using (buyer_id = auth.uid() or owner_id = auth.uid() or public.is_admin());
drop policy if exists refunds_select on public.refunds;
create policy refunds_select on public.refunds for select using (buyer_id = auth.uid() or owner_id = auth.uid() or public.is_admin());

-- Verificação: só a própria pessoa e admin leem. Gravação pelas funções.
drop policy if exists verifications_select on public.verifications;
create policy verifications_select on public.verifications for select using (user_id = auth.uid() or public.is_admin());

-- Cupons: quem criou (e admin) vê e gerencia. Validar no checkout é pela
-- função check_coupon, que não expõe a lista de cupons de ninguém.
drop policy if exists coupons_select on public.coupons;
create policy coupons_select on public.coupons for select using (created_by = auth.uid() or public.is_admin());
drop policy if exists coupons_insert on public.coupons;
create policy coupons_insert on public.coupons for insert with check (created_by = auth.uid() and public.is_active_user());
drop policy if exists coupons_update on public.coupons;
create policy coupons_update on public.coupons for update using (created_by = auth.uid() or public.is_admin());
drop policy if exists coupons_delete on public.coupons;
create policy coupons_delete on public.coupons for delete using (created_by = auth.uid() or public.is_admin());
revoke update on public.coupons from anon, authenticated;
grant update (active, max_uses, expires_at) on public.coupons to authenticated;

drop policy if exists redemptions_select on public.coupon_redemptions;
create policy redemptions_select on public.coupon_redemptions for select using (
  buyer_id = auth.uid() or public.is_admin()
  or exists (select 1 from public.coupons c where c.code = coupon_redemptions.code and c.created_by = auth.uid())
);

-- Chat: só as duas pessoas da conversa (e admin).
drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select using (auth.uid() in (buyer_id, seller_id) or public.is_admin());
drop policy if exists conversations_insert on public.conversations;
create policy conversations_insert on public.conversations for insert with check (buyer_id = auth.uid() and seller_id <> auth.uid() and public.is_active_user());
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select using (
  exists (select 1 from public.conversations c where c.id = conversation_id and (auth.uid() in (c.buyer_id, c.seller_id) or public.is_admin()))
);
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert with check (
  sender_id = auth.uid() and public.is_active_user()
  and exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.buyer_id, c.seller_id))
);

-- Vitrine e perfil público podem ser lidos por qualquer visitante.
grant select on public.public_profiles to anon, authenticated;
grant select on public.catalog to anon, authenticated;

-- ---------------------------------------------------------------------
-- FUNÇÕES DO SERVIDOR (o navegador pede; o banco confere e calcula)
-- ---------------------------------------------------------------------

-- Valida um cupom no checkout sem revelar nada além do desconto.
create or replace function public.check_coupon(p_code text)
returns table (code text, discount_type text, discount_value numeric)
language sql stable security definer set search_path = public as $$
  select c.code, c.discount_type, c.discount_value
  from public.coupons c
  where c.code = upper(trim(p_code))
    and c.active
    and (c.expires_at is null or c.expires_at > now())
    and (c.max_uses = 0 or c.uses < c.max_uses)
    and c.created_by <> auth.uid();
$$;

-- Cria o pedido com preço, cupom e taxa calculados AQUI (não no navegador).
create or replace function public.create_order(p_product_id bigint, p_type text, p_days int default 1, p_coupon text default null)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  prof  public.profiles;
  prod  public.products;
  cp    public.coupons;
  o     public.orders;
  unit  numeric(12,2);
  sub   numeric(12,2);
  disc  numeric(12,2) := 0;
  rate  numeric(5,2);
  fee   numeric(12,2);
  d     int := null;
begin
  if me is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select * into prof from public.profiles where id = me;
  if not found or prof.banned then raise exception 'Conta suspensa ou inexistente.' using errcode = '42501'; end if;

  select * into prod from public.products where id = p_product_id and active;
  if not found then raise exception 'Este anúncio não está disponível.'; end if;
  if prod.owner_id = me then raise exception 'Você não pode alugar ou comprar o próprio anúncio.'; end if;

  if p_type = 'rent' then
    if prod.type not in ('rent','both') or coalesce(prod.rent_price, 0) <= 0 then raise exception 'Este anúncio não é para aluguel.'; end if;
    if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Escolha de 1 a 365 dias.'; end if;
    d := p_days; unit := prod.rent_price; sub := unit * d;
  elsif p_type = 'sale' then
    if prod.type not in ('sale','both') or coalesce(prod.sale_price, 0) <= 0 then raise exception 'Este anúncio não está à venda.'; end if;
    unit := prod.sale_price; sub := unit;
  else
    raise exception 'Tipo de pedido inválido.';
  end if;

  if p_coupon is not null and length(trim(p_coupon)) > 0 then
    select * into cp from public.coupons where code = upper(trim(p_coupon)) for update;
    if not found or not cp.active or (cp.expires_at is not null and cp.expires_at <= now()) then raise exception 'Cupom inválido ou expirado.'; end if;
    if cp.created_by = me then raise exception 'Você não pode usar o próprio cupom.'; end if;
    if cp.max_uses > 0 and cp.uses >= cp.max_uses then raise exception 'Este cupom já foi usado o máximo de vezes.'; end if;
    disc := case when cp.discount_type = 'percent' then round(sub * cp.discount_value / 100, 2) else least(sub, cp.discount_value) end;
    update public.coupons set uses = uses + 1 where code = cp.code;
  end if;

  rate := coalesce(prof.fee_rate, 8);
  fee  := round((sub - disc) * rate / 100, 2);

  insert into public.orders (product_id, product_name, product_image, owner_id, buyer_id, type, days,
                             unit_price, subtotal, discount, fee_rate, fee, total, coupon_code, start_date, end_date)
  values (prod.id, prod.name, prod.images[1], prod.owner_id, me, p_type, d,
          unit, sub, disc, rate, fee, (sub - disc) + fee, cp.code, current_date,
          case when p_type = 'rent' then current_date + d end)
  returning * into o;

  insert into public.transactions (order_id, buyer_id, owner_id, amount) values (o.id, me, prod.owner_id, o.total);
  if cp.code is not null then
    insert into public.coupon_redemptions (code, order_id, buyer_id, discount) values (cp.code, o.id, me, disc);
  end if;
  return o;
end $$;

-- Muda o status do pedido e mantém transação/reembolso em dia.
-- Cliente: cancela enquanto pendente. Vendedor: confirma, entrega ou
-- cancela pendente. Admin: qualquer mudança.
create or replace function public.set_order_status(p_order_id bigint, p_status text)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  o        public.orders;
  tx       public.transactions;
  actor    text;
  was_paid boolean;
begin
  if p_status not in ('pendente','confirmado','entregue','cancelado') then raise exception 'Status inválido.'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;

  if public.is_admin() then actor := 'admin';
  elsif me = o.buyer_id then actor := 'cliente';
  elsif me = o.owner_id then actor := 'vendedor';
  else raise exception 'Sem permissão para este pedido.' using errcode = '42501';
  end if;

  if actor = 'cliente' and not (p_status = 'cancelado' and o.status = 'pendente') then
    raise exception 'Você só pode cancelar pedidos que ainda estão pendentes.';
  end if;
  if actor = 'vendedor' and not (
       (o.status = 'pendente'   and p_status in ('confirmado','cancelado')) or
       (o.status = 'confirmado' and p_status = 'entregue')) then
    raise exception 'Essa mudança de status não é permitida.';
  end if;

  was_paid := o.status in ('confirmado','entregue');
  update public.orders set
    status       = p_status,
    cancelled_by = case when p_status = 'cancelado' then actor else cancelled_by end,
    cancelled_at = case when p_status = 'cancelado' then now() else cancelled_at end
  where id = o.id
  returning * into o;

  select * into tx from public.transactions where order_id = o.id order by id limit 1;
  if found then
    if p_status = 'cancelado' and was_paid then
      update public.transactions set status = 'reembolsado' where id = tx.id;
      insert into public.refunds (order_id, transaction_id, buyer_id, owner_id, product_name, amount,
                                  requested_by, status, approved_at, cancelled_by, cancelled_at)
      values (o.id, tx.id, o.buyer_id, o.owner_id, o.product_name, tx.amount,
              actor, 'aprovado', now(), actor, now());
    else
      update public.transactions set status = case p_status
        when 'pendente' then 'em análise' when 'confirmado' then 'aprovado'
        when 'entregue' then 'finalizado' else 'cancelado' end
      where id = tx.id;
    end if;
  end if;
  return o;
end $$;

-- Envia (ou reenvia, se foi rejeitada) a verificação de vendedor.
create or replace function public.submit_verification(
  p_doc_front text, p_doc_back text, p_selfie text,
  p_bank_name text, p_bank_agency text, p_bank_account text, p_pix_key text, p_support_phone text)
returns public.verifications
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  cur public.verifications;
  v   public.verifications;
  dir text;
begin
  if me is null or not public.is_active_user() then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  dir := me::text || '/';
  if left(coalesce(p_doc_front, ''), length(dir)) <> dir
     or left(coalesce(p_doc_back, ''), length(dir)) <> dir
     or left(coalesce(p_selfie, ''), length(dir)) <> dir then
    raise exception 'Envie as três fotos: documento (frente e verso) e selfie.';
  end if;
  select * into cur from public.verifications where user_id = me;
  if found and cur.status = 'aprovado' then raise exception 'Sua conta já está verificada.'; end if;

  insert into public.verifications as t (user_id, doc_front_path, doc_back_path, selfie_path,
      bank_name, bank_agency, bank_account, pix_key, support_phone, status, submitted_at)
  values (me, p_doc_front, p_doc_back, p_selfie,
      nullif(trim(p_bank_name), ''), nullif(trim(p_bank_agency), ''), nullif(trim(p_bank_account), ''),
      nullif(trim(p_pix_key), ''), nullif(trim(p_support_phone), ''), 'pendente', now())
  on conflict (user_id) do update set
      doc_front_path = excluded.doc_front_path, doc_back_path = excluded.doc_back_path,
      selfie_path = excluded.selfie_path, bank_name = excluded.bank_name,
      bank_agency = excluded.bank_agency, bank_account = excluded.bank_account,
      pix_key = excluded.pix_key, support_phone = excluded.support_phone,
      status = 'pendente', submitted_at = now(),
      reviewed_at = null, reviewed_by = null, review_note = null
  returning * into v;
  return v;
end $$;

-- Admin aprova ou rejeita; aprovado = selo + telefone de suporte públicos.
create or replace function public.review_verification(p_user uuid, p_approve boolean, p_note text default null)
returns public.verifications
language plpgsql security definer set search_path = public as $$
declare v public.verifications;
begin
  if not public.is_admin() then raise exception 'Apenas administradores.' using errcode = '42501'; end if;
  update public.verifications set
    status = case when p_approve then 'aprovado' else 'rejeitado' end,
    reviewed_at = now(), reviewed_by = auth.uid(), review_note = p_note
  where user_id = p_user
  returning * into v;
  if not found then raise exception 'Esta pessoa ainda não enviou verificação.'; end if;
  update public.profiles set
    verified = p_approve,
    support_phone = case when p_approve then v.support_phone else null end
  where id = p_user;
  return v;
end $$;

-- Admin: banir/desbanir, taxa por cliente, anotações e cargo.
create or replace function public.admin_update_profile(
  p_user uuid, p_banned boolean default null, p_fee_rate numeric default null,
  p_clear_fee boolean default false, p_notes text default null, p_role text default null)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare r public.profiles;
begin
  if not public.is_admin() then raise exception 'Apenas administradores.' using errcode = '42501'; end if;
  if p_user = auth.uid() and (p_banned is true or (p_role is not null and p_role <> 'admin')) then
    raise exception 'Você não pode banir nem tirar o próprio acesso de admin.';
  end if;
  if p_role is not null and p_role not in ('user','admin') then raise exception 'Cargo inválido.'; end if;
  if p_fee_rate is not null and (p_fee_rate < 0 or p_fee_rate > 100) then raise exception 'A taxa vai de 0 a 100%%.'; end if;
  update public.profiles set
    banned      = coalesce(p_banned, banned),
    fee_rate    = case when p_clear_fee then null else coalesce(p_fee_rate, fee_rate) end,
    admin_notes = coalesce(p_notes, admin_notes),
    role        = coalesce(p_role, role)
  where id = p_user
  returning * into r;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  return r;
end $$;

-- Quem pode chamar cada função.
revoke execute on function public.create_order(bigint, text, int, text) from public, anon;
revoke execute on function public.set_order_status(bigint, text) from public, anon;
revoke execute on function public.submit_verification(text, text, text, text, text, text, text, text) from public, anon;
revoke execute on function public.review_verification(uuid, boolean, text) from public, anon;
revoke execute on function public.admin_update_profile(uuid, boolean, numeric, boolean, text, text) from public, anon;
revoke execute on function public.check_coupon(text) from public, anon;
grant execute on function public.create_order(bigint, text, int, text) to authenticated;
grant execute on function public.set_order_status(bigint, text) to authenticated;
grant execute on function public.submit_verification(text, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.review_verification(uuid, boolean, text) to authenticated;
grant execute on function public.admin_update_profile(uuid, boolean, numeric, boolean, text, text) to authenticated;
grant execute on function public.check_coupon(text) to authenticated;

-- ---------------------------------------------------------------------
-- ARMAZENAMENTO PRIVADO — documento e selfie
-- Cada pessoa só envia para a própria pasta ("<id>/arquivo.jpg").
-- Só ela e o admin conseguem abrir (por link temporário assinado).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verificacoes', 'verificacoes', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "verificacoes: dono envia" on storage.objects;
create policy "verificacoes: dono envia" on storage.objects for insert to authenticated
  with check (bucket_id = 'verificacoes' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "verificacoes: dono substitui" on storage.objects;
create policy "verificacoes: dono substitui" on storage.objects for update to authenticated
  using (bucket_id = 'verificacoes' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "verificacoes: dono e admin abrem" on storage.objects;
create policy "verificacoes: dono e admin abrem" on storage.objects for select to authenticated
  using (bucket_id = 'verificacoes' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop policy if exists "verificacoes: admin apaga" on storage.objects;
create policy "verificacoes: admin apaga" on storage.objects for delete to authenticated
  using (bucket_id = 'verificacoes' and public.is_admin());

-- =====================================================================
-- PRIMEIRO ADMIN — depois de criar sua conta no app novo, rode SÓ esta
-- linha (trocando o e-mail se for outro):
--
--   update public.profiles set role = 'admin' where email = 'usei.contato@gmail.com';
-- =====================================================================
