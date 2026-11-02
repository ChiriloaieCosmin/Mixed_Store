-- =====================================================================
-- Sistem de gestiune - magazin mixt (PostgreSQL / Supabase)
-- Proiect: Baze de date avansate  |  Versiunea 1: 6 tabele
-- Rulare: lipeste tot in Supabase SQL Editor si apasa Run
-- =====================================================================

BEGIN;

-- Curatare: sterge obiectele acestui proiect (inclusiv varianta veche cu 14 tabele)
-- Nu atinge schema public si nici alte tabele din proiect.
DROP VIEW IF EXISTS v_customer_balance, v_expiring_soon, v_product_stock,
                    v_low_stock, v_customer_credit CASCADE;
DROP FUNCTION IF EXISTS top_revenue_products(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS slowest_selling_products(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS top_selling_products(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS product_sales_stats(TIMESTAMPTZ, TIMESTAMPTZ);
DROP TABLE IF EXISTS sale_item_batches, credit_payments, sale_items, sales,
                     customers, stock_adjustments, receipt_items, goods_receipts,
                     product_price_history, products, suppliers, categories,
                     users, roles CASCADE;

-- ---------------------------------------------------------------------
-- 1. UTILIZATORI (3 roluri, ca valori permise in coloana role)
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id            SERIAL PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(100) NOT NULL,
    role          VARCHAR(20)  NOT NULL
                  CHECK (role IN ('admin', 'vanzator', 'gestionar')),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. CATEGORII
-- ---------------------------------------------------------------------
CREATE TABLE categories (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(80) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- 3. PRODUSE (stocul curent este o coloana)
-- ---------------------------------------------------------------------
CREATE TABLE products (
    id             SERIAL PRIMARY KEY,
    barcode        VARCHAR(30) UNIQUE,
    name           VARCHAR(150) NOT NULL,
    category_id    INTEGER NOT NULL REFERENCES categories(id),
    unit           VARCHAR(10) NOT NULL DEFAULT 'buc'
                   CHECK (unit IN ('buc', 'kg', 'l', 'm')),
    sale_price     NUMERIC(10,2) NOT NULL CHECK (sale_price >= 0),
    purchase_price NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (purchase_price >= 0),
    vat_rate       NUMERIC(4,2)  NOT NULL DEFAULT 11,
    stock          NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (stock >= 0),
    min_stock      NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (min_stock >= 0),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 4. CLIENTI (pentru vanzari pe credit, "pe caiet")
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    id           SERIAL PRIMARY KEY,
    name         VARCHAR(120) NOT NULL,
    phone        VARCHAR(30),
    address      TEXT,
    credit_limit NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 5. VANZARI
-- ---------------------------------------------------------------------
CREATE TABLE sales (
    id             BIGSERIAL PRIMARY KEY,
    customer_id    INTEGER REFERENCES customers(id),        -- NULL = client anonim
    user_id        INTEGER NOT NULL REFERENCES users(id),   -- vanzatorul
    sold_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    payment_method VARCHAR(10) NOT NULL
                   CHECK (payment_method IN ('cash', 'card', 'credit')),
    status         VARCHAR(10) NOT NULL DEFAULT 'completed'
                   CHECK (status IN ('completed', 'cancelled')),
    total          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    -- vanzarea pe credit are nevoie de un client cunoscut
    CHECK (payment_method <> 'credit' OR customer_id IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 6. LINII DE VANZARE
-- ---------------------------------------------------------------------
CREATE TABLE sale_items (
    id         BIGSERIAL PRIMARY KEY,
    sale_id    BIGINT  NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id),
    quantity   NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),  -- pretul din momentul vanzarii
    vat_rate   NUMERIC(4,2)  NOT NULL
);

-- ---------------------------------------------------------------------
-- NOTA DESPRE INDECSI
-- Intentionat nu adaug indecsi in plus (doar cei din PRIMARY KEY / UNIQUE),
-- ca sa poti arata EXPLAIN ANALYZE "inainte" si "dupa" la etapa 4.
-- Candidati: sales(sold_at), sale_items(product_id), sale_items(sale_id),
--            sales(customer_id)
-- ---------------------------------------------------------------------

-- =====================================================================
-- VIEW-URI SI FUNCTII PENTRU STATISTICI
-- =====================================================================

-- Produse sub stocul minim
CREATE VIEW v_low_stock AS
SELECT id AS product_id, name, unit, stock, min_stock
FROM products
WHERE is_active AND stock < min_stock;

-- Cat datoreaza fiecare client (suma vanzarilor pe credit)
CREATE VIEW v_customer_credit AS
SELECT c.id AS customer_id,
       c.name,
       c.credit_limit,
       COALESCE(SUM(s.total), 0) AS credit_total
FROM customers c
LEFT JOIN sales s ON s.customer_id = c.id
                 AND s.payment_method = 'credit'
                 AND s.status = 'completed'
GROUP BY c.id;

-- Statistici pe produs pentru ORICE perioada (include si produsele nevandute).
-- Profitul = (pret vanzare - pret achizitie) * cantitate.
CREATE FUNCTION product_sales_stats(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
    product_id INTEGER,
    product_name TEXT,
    qty_sold NUMERIC,
    revenue NUMERIC,
    profit NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT p.id,
           p.name::text,
           COALESCE(SUM(si.quantity), 0),
           COALESCE(SUM(si.quantity * si.unit_price), 0),
           COALESCE(SUM(si.quantity * (si.unit_price - p.purchase_price)), 0)
    FROM products p
    LEFT JOIN (sale_items si
               JOIN sales sa ON sa.id = si.sale_id
                            AND sa.status = 'completed'
                            AND sa.sold_at >= p_from
                            AND sa.sold_at <  p_to)
           ON si.product_id = p.id
    WHERE p.is_active
    GROUP BY p.id, p.name;
$$;

-- Cele mai vandute produse (dupa cantitate) in ultimele N zile
CREATE FUNCTION top_selling_products(p_days INTEGER DEFAULT 30, p_limit INTEGER DEFAULT 10)
RETURNS TABLE (product_name TEXT, qty_sold NUMERIC, revenue NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT product_name, qty_sold, revenue
    FROM product_sales_stats(now() - make_interval(days => p_days), now())
    WHERE qty_sold > 0
    ORDER BY qty_sold DESC
    LIMIT p_limit;
$$;

-- Cele mai greu vandute (inclusiv 0 vanzari) care au totusi stoc
CREATE FUNCTION slowest_selling_products(p_days INTEGER DEFAULT 30, p_limit INTEGER DEFAULT 10)
RETURNS TABLE (product_name TEXT, qty_sold NUMERIC, stock NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT st.product_name, st.qty_sold, p.stock
    FROM product_sales_stats(now() - make_interval(days => p_days), now()) st
    JOIN products p ON p.id = st.product_id
    WHERE p.stock > 0
    ORDER BY st.qty_sold ASC, p.stock DESC
    LIMIT p_limit;
$$;

-- Produsele care au adus cei mai multi bani in ultimele N zile
CREATE FUNCTION top_revenue_products(p_days INTEGER DEFAULT 30, p_limit INTEGER DEFAULT 10)
RETURNS TABLE (product_name TEXT, revenue NUMERIC, profit NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT product_name, revenue, profit
    FROM product_sales_stats(now() - make_interval(days => p_days), now())
    WHERE revenue > 0
    ORDER BY revenue DESC
    LIMIT p_limit;
$$;

COMMIT;

-- Exemple:
--   SELECT * FROM top_selling_products(30, 10);
--   SELECT * FROM slowest_selling_products(30, 10);
--   SELECT * FROM top_revenue_products(30, 10);
--   SELECT * FROM product_sales_stats('2026-10-01', '2026-11-01');
--   SELECT * FROM v_low_stock;
--   SELECT * FROM v_customer_credit ORDER BY credit_total DESC;
