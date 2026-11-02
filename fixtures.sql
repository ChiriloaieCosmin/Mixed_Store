-- =====================================================================
-- Fixtures pentru schema cu 6 tabele (ruleaza DUPA schema.sql)
-- 3 utilizatori, 6 categorii, 15 produse, 4 clienti, 300 de vanzari
-- pe ultimele 45 de zile. Produsele 14 si 15 nu se vand deloc.
-- Parolele sunt placeholdere; hash-urile reale apar la etapa de autentificare.
-- TVA-ul este orientativ, verifica cotele reale cu magazinul.
-- =====================================================================

BEGIN;

INSERT INTO users (username, password_hash, full_name, role) VALUES
    ('admin',     'PLACEHOLDER_HASH', 'Proprietar Magazin', 'admin'),      -- 1
    ('vanzator',  'PLACEHOLDER_HASH', 'Maria Vanzator',     'vanzator'),   -- 2
    ('gestionar', 'PLACEHOLDER_HASH', 'Ion Gestionar',      'gestionar');  -- 3

INSERT INTO categories (name) VALUES
    ('Alimente de baza'),        -- 1
    ('Bauturi'),                 -- 2
    ('Lactate si mezeluri'),     -- 3
    ('Dulciuri'),                -- 4
    ('Produse de curatenie'),    -- 5
    ('Maruntisuri');             -- 6

INSERT INTO products (barcode, name, category_id, unit, sale_price, vat_rate, min_stock) VALUES
    ('5940000000011', 'Faina alba 1kg',           1, 'buc',  4.50, 11, 20),  -- 1
    ('5940000000028', 'Zahar 1kg',                1, 'buc',  5.50, 11, 20),  -- 2
    ('5940000000035', 'Ulei floarea-soarelui 1L', 1, 'buc',  9.99, 11, 15),  -- 3
    ('5940000000042', 'Orez 1kg',                 1, 'buc',  7.00, 11, 15),  -- 4
    ('5940000000059', 'Paine alba',               1, 'buc',  4.00, 11, 10),  -- 5
    ('5940000000066', 'Apa plata 2L',             2, 'buc',  4.50, 11, 30),  -- 6
    ('5940000000073', 'Bere 0.5L',                2, 'buc',  5.50, 21, 30),  -- 7
    ('5940000000080', 'Suc 2L',                   2, 'buc',  8.00, 21, 20),  -- 8
    ('5940000000097', 'Lapte 1L',                 3, 'buc',  7.50, 11, 20),  -- 9
    (NULL,            'Telemea la kg',            3, 'kg',  38.00, 11, 5),   -- 10
    (NULL,            'Salam la kg',              3, 'kg',  45.00, 11, 5),   -- 11
    ('5940000000103', 'Ciocolata cu lapte',       4, 'buc',  6.00, 11, 15),  -- 12
    ('5940000000110', 'Detergent rufe 2kg',       5, 'buc', 25.00, 21, 5),   -- 13
    ('5940000000127', 'Sapun solid',              5, 'buc',  3.50, 21, 10),  -- 14 (nu se vinde)
    ('5940000000134', 'Baterii AA (set 4)',       6, 'buc', 12.00, 21, 5);   -- 15 (nu se vinde)

-- Pret de achizitie ~70% din pret de vanzare; stoc initial inainte de vanzari
UPDATE products
SET purchase_price = ROUND(sale_price * 0.70, 2),
    stock = CASE WHEN id <= 9 THEN 300 ELSE 100 END;

INSERT INTO customers (name, phone, address, credit_limit) VALUES
    ('Gheorghe Popa', '0740111111', 'Sat, nr. 12', 500),
    ('Elena Ionescu', '0740222222', 'Sat, nr. 40', 300),
    ('Vasile Marin',  '0740333333', 'Sat, nr. 7',  400),
    ('Ana Dumitru',   '0740444444', 'Sat, nr. 91', 200);

-- 300 de vanzari in ultimele 45 de zile (12% pe credit, 28% card, restul cash)
WITH gen AS (
    SELECT g, random() AS r, random() * 45 AS d FROM generate_series(1, 300) g
)
INSERT INTO sales (customer_id, user_id, sold_at, payment_method, status, total)
SELECT CASE WHEN r < 0.12 THEN 1 + (g % 4) END,
       2,
       now() - d * interval '1 day',
       CASE WHEN r < 0.12 THEN 'credit' WHEN r < 0.40 THEN 'card' ELSE 'cash' END,
       'completed',
       0
FROM gen;

-- Cate 2 produse pe vanzare; produsele 1-9 sunt mai populare, 14 si 15 nu apar deloc
INSERT INTO sale_items (sale_id, product_id, quantity, unit_price, vat_rate)
SELECT s.id, p.id,
       CASE WHEN p.unit = 'kg' THEN 0.5 + ((s.id + p.id) % 4) * 0.25
            ELSE 1 + ((s.id + p.id) % 3) END,
       p.sale_price, p.vat_rate
FROM sales s
CROSS JOIN LATERAL (
    SELECT id, unit, sale_price, vat_rate
    FROM products
    WHERE id <= 13
    ORDER BY (('x' || substr(md5(s.id::text || '-' || id::text), 1, 8))::bit(32)::bigint / 4294967296.0)
             / CASE WHEN id <= 9 THEN 3 ELSE 1 END
    LIMIT 2
) p;

UPDATE sales
SET total = (SELECT COALESCE(SUM(quantity * unit_price), 0) FROM sale_items WHERE sale_id = sales.id);

-- Stocul scade cu cantitatile vandute
UPDATE products p
SET stock = p.stock - COALESCE((SELECT SUM(quantity) FROM sale_items WHERE product_id = p.id), 0);

COMMIT;

ANALYZE;

-- Verificare rapida:
--   SELECT * FROM top_selling_products(30, 5);
--   SELECT * FROM slowest_selling_products(30, 5);
--   SELECT * FROM v_customer_credit;
