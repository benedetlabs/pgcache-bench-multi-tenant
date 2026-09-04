-- ============================================================================
-- Multi-tenant campaign (mt1) -- step 1 of 2: the application-shaped schema.
--
-- Run against the ORIGIN, not through PgCache:
--   psql -h $ORIGIN_HOST -U $PGUSER -d $PGDATABASE -q -f 01-schema.sql
--
-- WHY THIS SCHEMA EXISTS
--
-- Every campaign before this one ran against `pgbench_accounts`: one table, one
-- integer primary key, one column read. That is the cheapest query PostgreSQL
-- can serve, and it turned out to be the WORST case for a cache -- the origin
-- served it in ~0.23 ms and there was almost no work for a cache to save.
--
-- Real applications do not look like that. They join, they aggregate, they
-- paginate, and they issue eight to a hundred statements to render one screen.
-- This schema exists to produce that shape of query.
--
-- Sizing target: ~463 MB total, which FITS inside the origin's 1 GB
-- shared_buffers. That is deliberate and it is the hardest case -- the origin
-- serves everything from memory, so the cache cannot win on I/O. It has to win
-- on work saved or not at all.
-- ============================================================================

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
-- 200 tenants is the sweep's upper bound.
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

-- "orders", not "order": ORDER is a reserved word, and quoting it in every
-- pgbench script is a needless source of typos.
CREATE TABLE orders (
  id          int PRIMARY KEY,
  customer_id int NOT NULL REFERENCES customer(id),
  status      text NOT NULL,
  total       numeric(10,2) NOT NULL,
  created_at  timestamptz NOT NULL
);

CREATE TABLE order_item (
  id         int PRIMARY KEY,
  order_id   int NOT NULL REFERENCES orders(id),
  product_id int NOT NULL REFERENCES product(id),
  qty        int NOT NULL,
  price      numeric(10,2) NOT NULL
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
--
-- generate_series rather than an external loader: it runs inside the server, it
-- is deterministic apart from the random() columns, and the whole seed takes
-- well under a minute. Nothing here needs a seeding tool.
--
-- Every foreign key is populated. A schema with NULL FKs would let the planner
-- skip joins the workload is supposed to exercise.

INSERT INTO category SELECT g, 'cat' || g FROM generate_series(1, 50) g;

INSERT INTO seller   SELECT g, 'seller' || g, 3 + random() * 2
                     FROM generate_series(1, 500) g;

-- 100,000 customers spread evenly over 200 tenants = 500 customers per tenant.
INSERT INTO customer SELECT g, 'cust' || g, 'c' || g || '@lab.local', 1 + (g % 200)
                     FROM generate_series(1, 100000) g;

INSERT INTO product  SELECT g, 1 + (g % 50), 1 + (g % 500), 'product ' || g,
                            (10 + random() * 490)::numeric(10,2),
                            (random() * 1000)::int, true
                     FROM generate_series(1, 200000) g;

-- 500,000 orders over 100,000 customers = 5 orders each, and therefore
-- 2,500 orders per tenant. That per-tenant number is what the dashboard
-- aggregates over, so it is the number that sets the origin's cost.
INSERT INTO orders   SELECT g, 1 + (g % 100000),
                            (ARRAY['new','paid','shipped','done'])[1 + (g % 4)],
                            (20 + random() * 2000)::numeric(10,2),
                            now() - (g % 365 || ' days')::interval
                     FROM generate_series(1, 500000) g;

-- 2,000,000 line items over 500,000 orders = 4 per order.
-- The `g * 7 % 200000` scatters products across orders instead of correlating
-- item id with product id, which would have made the join artificially local.
INSERT INTO order_item SELECT g, 1 + (g % 500000), 1 + (g * 7 % 200000),
                              1 + (g % 5), (10 + random() * 490)::numeric(10,2)
                       FROM generate_series(1, 2000000) g;

INSERT INTO review   SELECT g, 1 + (g % 200000), 1 + (g % 100000), 1 + (g % 5),
                            'review body text number ' || g,
                            now() - (g % 365 || ' days')::interval
                     FROM generate_series(1, 300000) g;

-- ── Indexes ─────────────────────────────────────────────────────────────────
-- Exactly what an ORM would create: one on every foreign key, plus the columns
-- the workload filters on. Nothing hand-tuned for this benchmark -- a schema
-- indexed better than a real application would flatter the origin, and a schema
-- indexed worse would flatter the cache.

CREATE INDEX ON product(category_id);
CREATE INDEX ON product(seller_id);
CREATE INDEX ON orders(customer_id);
CREATE INDEX ON orders(status);
CREATE INDEX ON order_item(order_id);
CREATE INDEX ON order_item(product_id);
CREATE INDEX ON review(product_id);
CREATE INDEX ON review(customer_id);
CREATE INDEX ON customer(tenant_id);

ANALYZE;
