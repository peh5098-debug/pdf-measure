# Clothing Shop — Next.js (App Router) + Supabase + Tailwind CSS

## 폴더 구조

```
clothing-shop/
├── app/
│   ├── (shop)/                         # 고객용 화면 (공통 Header/Footer 레이아웃)
│   │   ├── layout.tsx
│   │   ├── page.tsx                    # 메인 (추천/신상품)
│   │   ├── categories/[slug]/page.tsx  # 카테고리별 상품 목록
│   │   ├── products/[slug]/page.tsx    # 상품 상세 (사이즈/색상 선택)
│   │   ├── search/page.tsx
│   │   ├── cart/page.tsx
│   │   ├── checkout/
│   │   │   ├── page.tsx                # 배송지 입력 + 결제위젯
│   │   │   ├── success/page.tsx        # PG 결제 성공 리다이렉트 → 승인 요청
│   │   │   └── fail/page.tsx
│   │   └── mypage/
│   │       ├── layout.tsx              # 로그인 필요
│   │       ├── page.tsx
│   │       ├── orders/page.tsx
│   │       ├── orders/[orderNumber]/page.tsx
│   │       └── addresses/page.tsx
│   ├── (auth)/
│   │   ├── login/page.tsx
│   │   ├── signup/page.tsx
│   │   └── auth/callback/route.ts      # OAuth / 이메일 인증 콜백
│   ├── admin/                          # 관리자 (role = 'admin')
│   │   ├── layout.tsx
│   │   ├── page.tsx                    # 대시보드
│   │   ├── products/  (page.tsx, new/page.tsx, [id]/page.tsx)
│   │   ├── categories/page.tsx
│   │   └── orders/   (page.tsx, [id]/page.tsx)
│   ├── api/
│   │   ├── payments/confirm/route.ts   # PG 승인 API 호출 (service_role)
│   │   └── webhooks/payments/route.ts  # PG 웹훅 (가상계좌 입금 등)
│   ├── layout.tsx
│   ├── globals.css
│   ├── not-found.tsx
│   └── error.tsx
│
├── components/
│   ├── ui/                             # Button, Input, Modal, Badge ... (재사용 원자 컴포넌트)
│   ├── layout/                         # Header, Footer, MobileNav
│   ├── product/                        # ProductCard, ProductGrid, ImageGallery, VariantSelector
│   ├── cart/                           # CartItem, CartSummary
│   ├── checkout/                       # AddressForm, PaymentWidget
│   └── admin/                          # ProductForm, OrderStatusSelect, DataTable
│
├── lib/
│   ├── supabase/
│   │   ├── client.ts                   # createBrowserClient (클라이언트 컴포넌트)
│   │   ├── server.ts                   # createServerClient + cookies (서버 컴포넌트/액션)
│   │   ├── admin.ts                    # service_role 클라이언트 (서버 전용!)
│   │   └── middleware.ts               # 세션 갱신 헬퍼
│   ├── queries/                        # 읽기 전용 데이터 조회 (products.ts, categories.ts, orders.ts)
│   ├── actions/                        # Server Actions (cart.ts, order.ts, address.ts, admin/*.ts)
│   ├── payments/                       # PG 연동 (toss.ts)
│   ├── validations/                    # zod 스키마
│   └── utils.ts                        # cn(), formatPrice() 등
│
├── hooks/                              # useCart, useDebounce ...
├── types/
│   ├── database.types.ts               # `supabase gen types typescript` 결과물
│   └── index.ts                        # 앱 도메인 타입
│
├── supabase/
│   ├── schema.sql                      # ← 전체 DB 스키마
│   ├── migrations/                     # supabase CLI 마이그레이션
│   ├── seed.sql
│   └── config.toml
│
├── public/                             # 로고, 파비콘, placeholder 이미지
├── middleware.ts                       # 세션 갱신 + /mypage, /admin 접근 제어
├── tailwind.config.ts
├── next.config.ts                      # images.remotePatterns 에 Supabase Storage 도메인
├── .env.local.example
├── package.json
└── tsconfig.json
```

### 설계 포인트
- **Route Group** `(shop)`, `(auth)` 로 레이아웃을 분리하고, `admin/` 은 별도 레이아웃 + `middleware.ts` 에서 권한 체크.
- **데이터 읽기**는 서버 컴포넌트에서 `lib/queries/*`, **쓰기**는 `lib/actions/*` Server Action 으로.
- **service_role 키는 `lib/supabase/admin.ts` 에서만** 사용하고, 결제 승인·웹훅·관리자 상태 변경 같은 서버 경로에서만 import.

## DB 스키마 (`supabase/schema.sql`)

| 영역 | 테이블 |
|---|---|
| 사용자 | `profiles` (auth.users 확장, role), `addresses` |
| 카테고리 | `categories` (parent_id 계층형) |
| 상품 | `products`, `product_images`, `product_variants` (사이즈·색상별 SKU/재고) |
| 장바구니 | `carts` (사용자당 1개), `cart_items` (variant 단위) |
| 주문 | `orders` (`order_status` enum, 배송지 스냅샷), `order_items` (가격·옵션 스냅샷), `order_status_history` |
| 결제 | `payments` (`payment_status` enum, payment_key, PG 원본 응답 jsonb) |

포함된 로직:
- 회원가입 시 `profiles` 자동 생성 트리거
- `create_order_from_cart()` RPC: 재고 행 잠금 → 재고/판매상태 검증 → 주문·주문상품 생성 → 재고 차감 → 장바구니 비움 → `payments(ready)` 생성까지 단일 트랜잭션. 배송비는 서버에서 계산(5만원 이상 무료).
- 주문 상태 변경 시 이력 기록 + `paid_at`/`shipped_at` 등 자동 기록, 취소 시 재고 복구
- 전 테이블 RLS: 카탈로그는 공개 읽기/관리자 쓰기, 장바구니·배송지는 본인만, 주문·결제는 본인 조회만(변경은 서버/관리자)

### 결제 흐름
1. `/checkout` → `rpc('create_order_from_cart')` → `orders(pending)` + `payments(ready)`
2. PG 결제위젯 호출 (`orderId = order_number`, `amount = total_amount`)
3. `/checkout/success` → `POST /api/payments/confirm` 에서 **DB 금액과 대조 후** PG 승인 API 호출
4. 성공: `payments.status = 'done'`, `orders.status = 'paid'` / 실패: `failed` 기록
