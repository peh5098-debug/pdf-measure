-- =============================================================================
-- Clothing Shop - Supabase PostgreSQL schema
-- 사용자 / 상품 / 카테고리 / 장바구니 / 주문 / 결제 상태 관리
--
-- 실행: Supabase Dashboard > SQL Editor 에 붙여넣거나
--       supabase/migrations/ 로 복사 후 `supabase db push`
-- =============================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";     -- 대소문자 무시 slug/email

-- -----------------------------------------------------------------------------
-- ENUM 타입
-- -----------------------------------------------------------------------------
create type public.user_role as enum ('customer', 'admin');

create type public.product_status as enum ('draft', 'active', 'archived');

create type public.order_status as enum (
  'pending',      -- 주문 생성, 결제 대기
  'paid',         -- 결제 완료
  'preparing',    -- 상품 준비중
  'shipped',      -- 배송중
  'delivered',    -- 배송 완료
  'cancelled',    -- 주문 취소
  'returned'      -- 반품 완료
);

create type public.payment_status as enum (
  'ready',               -- 결제 요청 생성
  'in_progress',         -- PG 인증/승인 진행중
  'waiting_for_deposit', -- 가상계좌 입금 대기
  'done',                -- 결제 승인 완료
  'failed',              -- 결제 실패
  'cancelled',           -- 전액 취소
  'partial_cancelled'    -- 부분 취소
);

create type public.payment_method as enum (
  'card', 'virtual_account', 'transfer', 'mobile', 'easy_pay'
);

-- -----------------------------------------------------------------------------
-- 공통: updated_at 자동 갱신 트리거 함수
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- 1. 사용자 (auth.users 1:1 확장)
-- =============================================================================
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       citext unique,
  full_name   text,
  phone       text,
  role        public.user_role not null default 'customer',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- 회원가입 시 profiles 행 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS 정책에서 사용할 관리자 판별 함수 (RLS 재귀 방지를 위해 security definer)
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- 배송지
create table public.addresses (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  label           text,                       -- '집', '회사'
  recipient_name  text not null,
  phone           text not null,
  postal_code     text not null,
  address_line1   text not null,
  address_line2   text,
  is_default      boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_addresses_user on public.addresses (user_id);
-- 사용자당 기본 배송지는 하나만
create unique index uq_addresses_default
  on public.addresses (user_id) where is_default;

create trigger trg_addresses_updated_at
  before update on public.addresses
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 2. 카테고리 (계층형: 상의 > 티셔츠)
-- =============================================================================
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  parent_id   uuid references public.categories (id) on delete set null,
  name        text not null,
  slug        citext not null unique,
  description text,
  image_url   text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint chk_categories_not_self_parent check (parent_id is null or parent_id <> id)
);

create index idx_categories_parent on public.categories (parent_id);

create trigger trg_categories_updated_at
  before update on public.categories
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 3. 상품 / 이미지 / 옵션(사이즈·색상별 재고)
-- =============================================================================
create table public.products (
  id              uuid primary key default gen_random_uuid(),
  category_id     uuid references public.categories (id) on delete set null,
  name            text not null,
  slug            citext not null unique,
  description     text,
  brand           text,
  base_price      int not null check (base_price >= 0),          -- 원 단위 정수
  sale_price      int check (sale_price >= 0),
  status          public.product_status not null default 'draft',
  is_featured     boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint chk_products_sale_price check (sale_price is null or sale_price <= base_price)
);

create index idx_products_category on public.products (category_id);
create index idx_products_status   on public.products (status);
create index idx_products_created  on public.products (created_at desc);

create trigger trg_products_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

create table public.product_images (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products (id) on delete cascade,
  url         text not null,              -- Supabase Storage public URL 또는 path
  alt         text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

create index idx_product_images_product on public.product_images (product_id, sort_order);

-- 실제 구매 단위(SKU). 장바구니·주문은 variant 를 참조한다.
create table public.product_variants (
  id               uuid primary key default gen_random_uuid(),
  product_id       uuid not null references public.products (id) on delete cascade,
  sku              text not null unique,
  size             text not null,          -- 'S', 'M', 'L', '95', '100' ...
  color            text not null,
  color_hex        text,
  additional_price int not null default 0, -- 옵션 추가금
  stock            int not null default 0 check (stock >= 0),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (product_id, size, color)
);

create index idx_variants_product on public.product_variants (product_id);

create trigger trg_variants_updated_at
  before update on public.product_variants
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 4. 장바구니
-- =============================================================================
create table public.carts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null unique references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_carts_updated_at
  before update on public.carts
  for each row execute function public.set_updated_at();

create table public.cart_items (
  id          uuid primary key default gen_random_uuid(),
  cart_id     uuid not null references public.carts (id) on delete cascade,
  variant_id  uuid not null references public.product_variants (id) on delete cascade,
  quantity    int not null check (quantity > 0 and quantity <= 99),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (cart_id, variant_id)            -- 같은 옵션은 수량만 증가
);

create index idx_cart_items_cart on public.cart_items (cart_id);

create trigger trg_cart_items_updated_at
  before update on public.cart_items
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 5. 주문
-- =============================================================================
create sequence public.order_number_seq;

create table public.orders (
  id                uuid primary key default gen_random_uuid(),
  -- 사람이 읽는 주문번호 (예: ORD-20261020-000123), PG orderId 로도 사용
  order_number      text not null unique default (
    'ORD-' || to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD') || '-' ||
    lpad(nextval('public.order_number_seq')::text, 6, '0')
  ),
  user_id           uuid references public.profiles (id) on delete set null,
  status            public.order_status not null default 'pending',

  -- 금액 (원)
  subtotal_amount   int not null check (subtotal_amount >= 0),
  shipping_fee      int not null default 0 check (shipping_fee >= 0),
  discount_amount   int not null default 0 check (discount_amount >= 0),
  total_amount      int not null check (total_amount >= 0),

  -- 배송지 스냅샷 (주소록이 바뀌어도 주문 정보는 유지)
  recipient_name    text not null,
  recipient_phone   text not null,
  postal_code       text not null,
  address_line1     text not null,
  address_line2     text,
  delivery_memo     text,

  tracking_carrier  text,
  tracking_number   text,

  paid_at           timestamptz,
  shipped_at        timestamptz,
  delivered_at      timestamptz,
  cancelled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint chk_orders_total
    check (total_amount = subtotal_amount + shipping_fee - discount_amount)
);

create index idx_orders_user    on public.orders (user_id, created_at desc);
create index idx_orders_status  on public.orders (status);

create trigger trg_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders (id) on delete cascade,
  product_id    uuid references public.products (id) on delete set null,
  variant_id    uuid references public.product_variants (id) on delete set null,
  -- 주문 시점 스냅샷
  product_name  text not null,
  size          text not null,
  color         text not null,
  sku           text not null,
  image_url     text,
  unit_price    int not null check (unit_price >= 0),
  quantity      int not null check (quantity > 0),
  line_total    int generated always as (unit_price * quantity) stored,
  created_at    timestamptz not null default now()
);

create index idx_order_items_order on public.order_items (order_id);

-- 주문 상태 변경 이력
create table public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders (id) on delete cascade,
  from_status public.order_status,
  to_status   public.order_status not null,
  changed_by  uuid references public.profiles (id) on delete set null,
  note        text,
  created_at  timestamptz not null default now()
);

create index idx_order_status_history_order on public.order_status_history (order_id);

create or replace function public.log_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, from_status, to_status, changed_by)
    values (new.id, case when tg_op = 'UPDATE' then old.status end, new.status, auth.uid());

    -- 상태별 타임스탬프 기록
    if new.status = 'paid'      and new.paid_at      is null then new.paid_at      := now(); end if;
    if new.status = 'shipped'   and new.shipped_at   is null then new.shipped_at   := now(); end if;
    if new.status = 'delivered' and new.delivered_at is null then new.delivered_at := now(); end if;
    if new.status = 'cancelled' and new.cancelled_at is null then new.cancelled_at := now(); end if;
  end if;
  return new;
end;
$$;

-- BEFORE 트리거라 *_at 컬럼 설정이 반영됨. INSERT 시 history FK 를 위해 AFTER 가 필요하므로 분리
create trigger trg_orders_status_update
  before update of status on public.orders
  for each row execute function public.log_order_status_change();

create or replace function public.log_order_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.order_status_history (order_id, from_status, to_status, changed_by)
  values (new.id, null, new.status, auth.uid());
  return new;
end;
$$;

create trigger trg_orders_status_insert
  after insert on public.orders
  for each row execute function public.log_order_created();

-- =============================================================================
-- 6. 결제 (PG: Toss Payments / PortOne 등 공통 구조)
-- =============================================================================
create table public.payments (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references public.orders (id) on delete cascade,
  provider          text not null default 'tosspayments',
  method            public.payment_method,
  status            public.payment_status not null default 'ready',
  amount            int not null check (amount >= 0),
  cancelled_amount  int not null default 0 check (cancelled_amount >= 0),
  payment_key       text unique,              -- PG 거래 키
  receipt_url       text,
  failure_code      text,
  failure_message   text,
  raw_response      jsonb,                    -- PG 원본 응답 (감사/디버깅용)
  approved_at       timestamptz,
  cancelled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint chk_payments_cancel_amount check (cancelled_amount <= amount)
);

create index idx_payments_order  on public.payments (order_id);
create index idx_payments_status on public.payments (status);

create trigger trg_payments_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 7. RPC: 장바구니 → 주문 생성 (재고 차감까지 하나의 트랜잭션)
--    클라이언트: supabase.rpc('create_order_from_cart', { ... })
-- =============================================================================
create or replace function public.create_order_from_cart(
  p_recipient_name  text,
  p_recipient_phone text,
  p_postal_code     text,
  p_address_line1   text,
  p_address_line2   text default null,
  p_delivery_memo   text default null
)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_cart_id  uuid;
  v_subtotal int;
  v_shipping int;
  v_order    public.orders;
  v_short    text;
begin
  if v_user_id is null then
    raise exception 'not authenticated';
  end if;

  select id into v_cart_id from carts where user_id = v_user_id;
  if v_cart_id is null or not exists (select 1 from cart_items where cart_id = v_cart_id) then
    raise exception 'cart is empty';
  end if;

  -- 재고 행 잠금 (동시 주문 시 초과 판매 방지)
  perform 1
  from product_variants v
  join cart_items ci on ci.variant_id = v.id
  where ci.cart_id = v_cart_id
  for update of v;

  -- 판매 불가 / 재고 부족 확인
  select string_agg(v.sku, ', ') into v_short
  from cart_items ci
  join product_variants v on v.id = ci.variant_id
  join products p on p.id = v.product_id
  where ci.cart_id = v_cart_id
    and (v.stock < ci.quantity or not v.is_active or p.status <> 'active');

  if v_short is not null then
    raise exception 'unavailable or insufficient stock: %', v_short;
  end if;

  select sum((coalesce(p.sale_price, p.base_price) + v.additional_price) * ci.quantity)
    into v_subtotal
  from cart_items ci
  join product_variants v on v.id = ci.variant_id
  join products p on p.id = v.product_id
  where ci.cart_id = v_cart_id;

  -- 배송비는 서버에서 계산 (5만원 이상 무료배송)
  v_shipping := case when v_subtotal >= 50000 then 0 else 3000 end;

  insert into orders (
    user_id, subtotal_amount, shipping_fee, total_amount,
    recipient_name, recipient_phone, postal_code, address_line1, address_line2, delivery_memo
  ) values (
    v_user_id, v_subtotal, v_shipping, v_subtotal + v_shipping,
    p_recipient_name, p_recipient_phone, p_postal_code, p_address_line1, p_address_line2, p_delivery_memo
  )
  returning * into v_order;

  insert into order_items (
    order_id, product_id, variant_id, product_name, size, color, sku, image_url, unit_price, quantity
  )
  select
    v_order.id, p.id, v.id, p.name, v.size, v.color, v.sku,
    (select pi.url from product_images pi where pi.product_id = p.id order by pi.sort_order limit 1),
    coalesce(p.sale_price, p.base_price) + v.additional_price,
    ci.quantity
  from cart_items ci
  join product_variants v on v.id = ci.variant_id
  join products p on p.id = v.product_id
  where ci.cart_id = v_cart_id;

  update product_variants v
     set stock = v.stock - ci.quantity
    from cart_items ci
   where ci.cart_id = v_cart_id and ci.variant_id = v.id;

  delete from cart_items where cart_id = v_cart_id;

  insert into payments (order_id, amount) values (v_order.id, v_order.total_amount);

  return v_order;
end;
$$;

-- 주문 취소 시 재고 복구 (pending/paid 상태에서만)
create or replace function public.restore_stock_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'cancelled' and old.status in ('pending', 'paid', 'preparing') then
    update product_variants v
       set stock = v.stock + oi.quantity
      from order_items oi
     where oi.order_id = new.id and oi.variant_id = v.id;
  end if;
  return new;
end;
$$;

create trigger trg_orders_restore_stock
  after update of status on public.orders
  for each row execute function public.restore_stock_on_cancel();

-- =============================================================================
-- 8. Row Level Security
--    * 결제 승인/주문 상태 변경은 서버(Route Handler)에서 service_role 키로 수행
--      → service_role 은 RLS 를 우회하므로 아래 정책은 브라우저(anon/authenticated) 기준
-- =============================================================================
alter table public.profiles             enable row level security;
alter table public.addresses            enable row level security;
alter table public.categories           enable row level security;
alter table public.products             enable row level security;
alter table public.product_images       enable row level security;
alter table public.product_variants     enable row level security;
alter table public.carts                enable row level security;
alter table public.cart_items           enable row level security;
alter table public.orders               enable row level security;
alter table public.order_items          enable row level security;
alter table public.order_status_history enable row level security;
alter table public.payments             enable row level security;

-- profiles: 본인 조회/수정, 관리자 전체 조회
create policy "profiles_select_own_or_admin" on public.profiles
  for select using (id = auth.uid() or public.is_admin());
create policy "profiles_update_own" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());
-- role/email 은 본인이 변경 불가: 수정 가능한 컬럼만 허용
revoke update on public.profiles from authenticated, anon;
grant  update (full_name, phone) on public.profiles to authenticated;

-- addresses: 본인 것만
create policy "addresses_owner_all" on public.addresses
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 카탈로그: 누구나 활성 데이터 조회, 관리자는 전체 관리
create policy "categories_public_read" on public.categories
  for select using (is_active or public.is_admin());
create policy "categories_admin_write" on public.categories
  for all using (public.is_admin()) with check (public.is_admin());

create policy "products_public_read" on public.products
  for select using (status = 'active' or public.is_admin());
create policy "products_admin_write" on public.products
  for all using (public.is_admin()) with check (public.is_admin());

create policy "product_images_public_read" on public.product_images
  for select using (
    exists (select 1 from public.products p
            where p.id = product_id and (p.status = 'active' or public.is_admin()))
  );
create policy "product_images_admin_write" on public.product_images
  for all using (public.is_admin()) with check (public.is_admin());

create policy "variants_public_read" on public.product_variants
  for select using (
    exists (select 1 from public.products p
            where p.id = product_id and (p.status = 'active' or public.is_admin()))
  );
create policy "variants_admin_write" on public.product_variants
  for all using (public.is_admin()) with check (public.is_admin());

-- 장바구니: 본인 것만
create policy "carts_owner_all" on public.carts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "cart_items_owner_all" on public.cart_items
  for all
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = auth.uid()))
  with check (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = auth.uid()));

-- 주문/결제: 본인 조회만 (생성은 create_order_from_cart RPC, 변경은 서버/관리자)
create policy "orders_select_own_or_admin" on public.orders
  for select using (user_id = auth.uid() or public.is_admin());
create policy "orders_admin_update" on public.orders
  for update using (public.is_admin()) with check (public.is_admin());

create policy "order_items_select_own_or_admin" on public.order_items
  for select using (
    exists (select 1 from public.orders o
            where o.id = order_id and (o.user_id = auth.uid() or public.is_admin()))
  );

create policy "order_history_select_own_or_admin" on public.order_status_history
  for select using (
    exists (select 1 from public.orders o
            where o.id = order_id and (o.user_id = auth.uid() or public.is_admin()))
  );

create policy "payments_select_own_or_admin" on public.payments
  for select using (
    exists (select 1 from public.orders o
            where o.id = order_id and (o.user_id = auth.uid() or public.is_admin()))
  );

-- RPC 실행 권한
revoke execute on function public.create_order_from_cart(text, text, text, text, text, text) from public, anon;
grant  execute on function public.create_order_from_cart(text, text, text, text, text, text) to authenticated;
