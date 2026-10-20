-- ============================================================================
-- Multi-tenant campaign (mt1) -- step 1 of 2: the application-shaped schema.
--
-- Run against the ORIGIN, not through PgCache:
--   psql -h $ORIGIN_HOST -U $PGUSER -d $PGDATABASE -q -f 01-schema.sql
--
-- Variables:
--   -v scale=1     (default: 1 -> ~463 MB; 5 -> ~2.3 GB; 10 -> ~4.6 GB)
--   -v tenants=200 (default: 200 tenants)
--
-- Sizing target:
--   Scale 1: ~463 MB total (fits inside origin's 1 GB shared_buffers)
--   Scale 5: ~2.3 GB total (stresses cache capacity and I/O buffer eviction)
--   Scale 10: ~4.6 GB total (fully exceeds 1GB shared_buffers, high-load test)
-- ============================================================================

\if :{?scale}
\else
  \set scale 1
\endif

\if :{?tenants}
\else
  \set tenants 200
\endif

DROP TABLE IF EXISTS review, order_item, orders, product, customer, seller, category CASCADE;

CREATE TABLE category (
  id   int PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE seller (
  id     int PRIMARY KEY,
  name   text NOT NULL,
  rating numeric(3,2)
);

-- tenant_id lives here natively: a customer belongs to exactly one tenant.
CREATE TABLE customer (
  id        int PRIMARY KEY,
  name      text NOT NULL,
  email     text NOT NULL,
  tenant_id int  NOT NULL
);

CREATE TABLE product (
  id          int PRIMARY KEY,
  category_id int NOT NULL REFERENCES category(id),
  seller_id   int NOT NULL REFERENCES seller(id),
  name        text NOT NULL,
  price       numeric(10,2) NOT NULL,
  stock       int NOT NULL,
  active      boolean NOT NULL DEFAULT true
);

-- "orders", not "order": ORDER is a reserved word
CREATE TABLE orders (
  id          int PRIMARY KEY,
  customer_id int NOT NULL REFERENCES customer(id),
  status      text NOT NULL,
  total       numeric(10,2) NOT NULL,
  created_at  timestamptz NOT NULL,
  tenant_id   int NOT NULL
);

CREATE TABLE order_item (
  id         int PRIMARY KEY,
  order_id   int NOT NULL REFERENCES orders(id),
  product_id int NOT NULL REFERENCES product(id),
  qty        int NOT NULL,
  price      numeric(10,2) NOT NULL,
  tenant_id  int NOT NULL
);

CREATE TABLE review (
  id          int PRIMARY KEY,
  product_id  int NOT NULL REFERENCES product(id),
  customer_id int NOT NULL REFERENCES customer(id),
  rating      int NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL
);

-- ── Seed ────────────────────────────────────────────────────────────────────

INSERT INTO category SELECT g, 'cat' || g FROM generate_series(1, 50) g;

INSERT INTO seller   SELECT g, 'seller' || g, 3 + random() * 2
                     FROM generate_series(1, 500) g;

-- 100,000 * :scale customers spread evenly over :tenants
INSERT INTO customer SELECT g, 'cust' || g, 'c' || g || '@lab.local', 1 + (g % :tenants)
                     FROM generate_series(1, 100000 * :scale) g;

INSERT INTO product  SELECT g, 1 + (g % 50), 1 + (g % 500), 'product ' || g,
                            (10 + random() * 490)::numeric(10,2),
                            (random() * 1000)::int, true
                     FROM generate_series(1, LEAST(200000 * :scale, 1000000)) g;

-- 500,000 * :scale orders over (100,000 * :scale) customers
INSERT INTO orders   SELECT g, 1 + (g % (100000 * :scale)),
                            (ARRAY['new','paid','shipped','done'])[1 + (g % 4)],
                            (20 + random() * 2000)::numeric(10,2),
                            now() - (g % 365 || ' days')::interval,
                            1 + ((1 + (g % (100000 * :scale))) % :tenants)
                     FROM generate_series(1, 500000 * :scale) g;

-- 2,000,000 * :scale line items over (500,000 * :scale) orders
INSERT INTO order_item SELECT g, 1 + (g % (500000 * :scale)), 1 + (g * 7 % LEAST(200000 * :scale, 1000000)),
                              1 + (g % 5), (10 + random() * 490)::numeric(10,2),
                              1 + ((1 + ((1 + (g % (500000 * :scale))) % (100000 * :scale))) % :tenants)
                       FROM generate_series(1, 2000000 * :scale) g;

INSERT INTO review   SELECT g, 1 + (g % LEAST(200000 * :scale, 1000000)), 1 + (g % (100000 * :scale)), 1 + (g % 5),
                            'review body text number ' || g,
                            now() - (g % 365 || ' days')::interval
                     FROM generate_series(1, LEAST(300000 * :scale, 1500000)) g;

-- ── Indexes ─────────────────────────────────────────────────────────────────

CREATE INDEX ON product(category_id);
CREATE INDEX ON product(seller_id);
CREATE INDEX ON orders(customer_id);
CREATE INDEX ON orders(status);
CREATE INDEX ON order_item(order_id);
CREATE INDEX ON order_item(product_id);
CREATE INDEX ON review(product_id);
CREATE INDEX ON review(customer_id);
CREATE INDEX ON customer(tenant_id);

-- Sequences for live INSERT benchmark workloads (starting at 100,000,000 to
-- avoid collisions with seeded IDs up to SCALE=20 and allow fast trial cleanup)
CREATE SEQUENCE IF NOT EXISTS orders_id_seq START WITH 100000000;
CREATE SEQUENCE IF NOT EXISTS order_item_id_seq START WITH 100000000;
ALTER TABLE orders ALTER COLUMN id SET DEFAULT nextval('orders_id_seq');
ALTER TABLE order_item ALTER COLUMN id SET DEFAULT nextval('order_item_id_seq');

ANALYZE;
