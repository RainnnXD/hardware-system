CREATE DATABASE IF NOT EXISTS irongate_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE irongate_db;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS settings, activity_logs, sale_items, sales, inventory_movements,
                     products, suppliers, categories, users, roles;
SET FOREIGN_KEY_CHECKS = 1;

-- ROLES 
CREATE TABLE roles (
  role_id    TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name  VARCHAR(30)      NOT NULL,
  CONSTRAINT pk_roles PRIMARY KEY (role_id),
  CONSTRAINT uq_roles_name UNIQUE (role_name)
) ENGINE=InnoDB;

-- TABLE FOR USERS
CREATE TABLE users (
  user_id        INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  full_name      VARCHAR(100)     NOT NULL,
  username       VARCHAR(40)      NOT NULL,
  email          VARCHAR(120)     NOT NULL,
  password_hash  VARCHAR(255)     NOT NULL,           -- output of PHP password_hash(); never a plain password
  role_id        TINYINT UNSIGNED NOT NULL,
  job_title      VARCHAR(80)      NULL,
  phone          VARCHAR(30)      NULL,
  status         ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
  created_at     TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_users PRIMARY KEY (user_id),
  CONSTRAINT uq_users_username UNIQUE (username),
  CONSTRAINT uq_users_email    UNIQUE (email),
  CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles (role_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  -- Defence in depth: the database itself refuses short/readable values such as 'Password123'.
  CONSTRAINT chk_users_hash CHECK (CHAR_LENGTH(password_hash) >= 60 AND password_hash LIKE '$%'),
  KEY idx_users_role (role_id)
) ENGINE=InnoDB;

-- CATEGORIES 
CREATE TABLE categories (
  category_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_name  VARCHAR(60)       NOT NULL,
  description    VARCHAR(255)      NULL,
  CONSTRAINT pk_categories PRIMARY KEY (category_id),
  CONSTRAINT uq_categories_name UNIQUE (category_name)
) ENGINE=InnoDB;

-- SUPPLIERS 
CREATE TABLE suppliers (
  supplier_id     SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  company_name    VARCHAR(120)      NOT NULL,
  contact_person  VARCHAR(100)      NOT NULL,
  phone           VARCHAR(30)       NOT NULL,
  email           VARCHAR(120)      NULL,
  address         VARCHAR(255)      NOT NULL,
  CONSTRAINT pk_suppliers PRIMARY KEY (supplier_id),
  CONSTRAINT uq_suppliers_company UNIQUE (company_name)
) ENGINE=InnoDB;

-- PRODUCTS
CREATE TABLE products (
  product_id      INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  sku             VARCHAR(30)       NOT NULL,
  product_name    VARCHAR(150)      NOT NULL,
  category_id     SMALLINT UNSIGNED NOT NULL,
  supplier_id     SMALLINT UNSIGNED NOT NULL,
  unit_price      DECIMAL(10,2)     NOT NULL,
  stock_quantity  INT               NOT NULL DEFAULT 0,
  reorder_level   INT               NOT NULL DEFAULT 10,
  unit            VARCHAR(20)       NOT NULL DEFAULT 'pcs',
  CONSTRAINT pk_products PRIMARY KEY (product_id),
  CONSTRAINT uq_products_sku UNIQUE (sku),
  CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories (category_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_products_supplier FOREIGN KEY (supplier_id) REFERENCES suppliers (supplier_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_products_price CHECK (unit_price > 0),
  CONSTRAINT chk_products_stock CHECK (stock_quantity >= 0),
  CONSTRAINT chk_products_reorder CHECK (reorder_level >= 0),
  KEY idx_products_category (category_id),
  KEY idx_products_supplier (supplier_id),
  KEY idx_products_name (product_name)
) ENGINE=InnoDB;

-- INVENTORY MOVEMENTS
CREATE TABLE inventory_movements (
  movement_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  product_id     INT UNSIGNED    NOT NULL,
  user_id        INT UNSIGNED    NOT NULL,
  movement_type  ENUM('IN','OUT','ADJ_IN','ADJ_OUT') NOT NULL,
  quantity       INT             NOT NULL,            -- always positive; direction comes from movement_type
  remarks        VARCHAR(255)    NULL,
  movement_date  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_movements PRIMARY KEY (movement_id),
  -- A product's stock history is removed only together with the product (possible only if never sold).
  CONSTRAINT fk_movements_product FOREIGN KEY (product_id) REFERENCES products (product_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_movements_user FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_movements_qty CHECK (quantity > 0),
  KEY idx_movements_product_date (product_id, movement_date),
  KEY idx_movements_user (user_id),
  KEY idx_movements_date (movement_date)
) ENGINE=InnoDB;

-- SALES
CREATE TABLE sales (
  sale_id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  receipt_number  VARCHAR(20)   NOT NULL,
  user_id         INT UNSIGNED  NOT NULL,              -- the cashier who processed the sale
  customer_name   VARCHAR(120)  NOT NULL DEFAULT 'Walk-in',
  payment_method  ENUM('Cash','GCash','Maya','Bank transfer','Charge account') NOT NULL,
  total_amount    DECIMAL(12,2) NOT NULL DEFAULT 0.00, -- set by the backend as SUM(sale_items.subtotal) inside the sale transaction
  sale_date       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_sales PRIMARY KEY (sale_id),
  CONSTRAINT uq_sales_receipt UNIQUE (receipt_number),
  CONSTRAINT fk_sales_user FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_sales_total CHECK (total_amount >= 0),
  KEY idx_sales_date (sale_date),
  KEY idx_sales_user (user_id),
  KEY idx_sales_payment (payment_method)
) ENGINE=InnoDB;

-- SALE ITEMS 
CREATE TABLE sale_items (
  sale_item_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  sale_id       INT UNSIGNED    NOT NULL,
  product_id    INT UNSIGNED    NOT NULL,
  quantity      INT             NOT NULL,
  unit_price    DECIMAL(10,2)   NOT NULL,              -- price charged at the time of sale (a historical fact about this line)
  subtotal      DECIMAL(12,2)   GENERATED ALWAYS AS (quantity * unit_price) STORED,
  CONSTRAINT pk_sale_items PRIMARY KEY (sale_item_id),
  CONSTRAINT uq_sale_items_line UNIQUE (sale_id, product_id),
  CONSTRAINT fk_sale_items_sale FOREIGN KEY (sale_id) REFERENCES sales (sale_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_sale_items_product FOREIGN KEY (product_id) REFERENCES products (product_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_sale_items_qty CHECK (quantity > 0),
  CONSTRAINT chk_sale_items_price CHECK (unit_price >= 0),
  KEY idx_sale_items_product (product_id)
) ENGINE=InnoDB;

-- ACTIVITY LOGS
CREATE TABLE activity_logs (
  log_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       INT UNSIGNED    NULL,
  action        VARCHAR(40)     NOT NULL,
  description   VARCHAR(500)    NOT NULL,
  date_created  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_activity_logs PRIMARY KEY (log_id),
  CONSTRAINT fk_logs_user FOREIGN KEY (user_id) REFERENCES users (user_id)
    ON UPDATE CASCADE ON DELETE SET NULL,
  KEY idx_logs_user (user_id),
  KEY idx_logs_date (date_created),
  KEY idx_logs_action (action)
) ENGINE=InnoDB;

-- SETTINGS
CREATE TABLE settings (
  setting_id      TINYINT UNSIGNED NOT NULL DEFAULT 1,
  store_name      VARCHAR(100)     NOT NULL,
  tax_rate        DECIMAL(5,2)     NOT NULL DEFAULT 12.00,
  reorder_level   INT              NOT NULL DEFAULT 20,
  receipt_footer  VARCHAR(255)     NULL,
  CONSTRAINT pk_settings PRIMARY KEY (setting_id),
  CONSTRAINT chk_settings_single CHECK (setting_id = 1),
  CONSTRAINT chk_settings_tax CHECK (tax_rate >= 0 AND tax_rate <= 100)
) ENGINE=InnoDB;

-- =============================================================================
-- Irongate Hardware · Seed data (Filipino business records)
-- Every user below has the initial password  Irongate@2026  but is stored ONLY as a bcrypt hash.
-- Each hash differs because password_hash() adds a random salt per call.
-- =============================================================================

INSERT INTO roles (role_id, role_name) VALUES
 (1,'Administrator'),(2,'Manager'),(3,'Inventory Staff'),(4,'Cashier');

INSERT INTO users (user_id, full_name, username, email, password_hash, role_id, job_title, phone, status) VALUES
 (1,'Criselle Enraca','criselle.enraca','criselle.enraca@irongatehardware.example','$2y$10$v/b8sRlFGuMVZIodBUn.p.Hm4rbgnYE94tEvo7NrQz8gkKmjx87dy',1,'Owner & General Manager','0917 301 5521','Active'),
 (2,'Zosaine Manaig','zosaine.manaig','zosaine.manaig@irongatehardware.example','$2y$10$SL6OVE6cnAW9EIv3gr7Iy.dZU1L1sANfKiamY6se8ti2EgOTNtUmG',2,'Operations Manager','0928 440 7316','Active'),
 (3,'Rainzell Espaldon','rainzell.espaldon','rainzell.espaldon@irongatehardware.example','$2y$10$e7C1KgZ0JJ3YvySTc4xVl.gQYfMkH4M.yBmodDGRAOMiVvQ.PeBcm',3,'Warehouse Supervisor','0939 215 8840','Active'),
 (4,'Althea Aquino','althea.aquino','althea.aquino@irongatehardware.example','$2y$10$fuyiJgDkgqbfEjOuKv5ks.UY7W9qmNB.Ct/WEvrZKe3CoKmwzu3fe',4,'Head Cashier','0966 702 1193','Active'),
 (5,'Andrei Reyes','andrei.reyes','andrei.reyes@irongatehardware.example','$2y$10$wuR9JyMWk19JhSOSN7TU4OEb8nkvb7pvLyY7HRNKoX1cen29X4.Wi',3,'Stockroom Assistant','0905 118 6672','Active'),
 (6,'Jhan Vincent Miraples','jhanvincent.miraples','jhanvincent.miraples@irongatehardware.example','$2y$10$6RdWoEJfmxdwjFJO5cDe4u90FUKcbDjeYcO4AVqnOg766NnS6JNvm',4,'Sales Associate','0977 836 2204','Active');

INSERT INTO categories (category_id, category_name, description) VALUES
 (1,'Cement & Masonry','Portland cement, CHB, hollow blocks'),
 (2,'Steel & Wire','Rebars, GI wire, tie wire'),
 (3,'Lumber & Boards','Marine plywood, coco lumber'),
 (4,'Plumbing','PVC pipes, valves, fittings'),
 (5,'Electrical','Wires, breakers, conduit'),
 (6,'Paint & Sealants','Latex paint, roof sealant'),
 (7,'Fasteners','Nails, screws, bolts');

INSERT INTO suppliers (supplier_id, company_name, contact_person, phone, email, address) VALUES
 (1,'Calamba Cement & Masonry Depot','Ernesto Dimaculangan','0917 812 4405','orders@calambacement.example','Brgy. Real, Calamba City, Laguna'),
 (2,'Batangas Steel Trading Corp.','Lorna Macalintal','0928 553 1076','sales@batangassteel.example','Brgy. Pallocan West, Batangas City, Batangas'),
 (3,'Imus Lumber & Plywood Center','Rodel Bautista','0998 217 6630','imuslumber@trade.example','Brgy. Anabu II-A, Imus City, Cavite'),
 (4,'Valenzuela Pipe & Fittings Supply','Cherry Anne Santos','(02) 8365 1420','benta@valpipe.example','MacArthur Highway, Brgy. Karuhatan, Valenzuela City, Metro Manila'),
 (5,'San Pedro Electrical Supply','Noel Cabrera','0919 674 2285','noel@sanpedroelec.example','Brgy. Landayan, San Pedro City, Laguna'),
 (6,'Lipa Paints & Coatings Co.','Marites Landicho','0945 330 7918','accounts@lipapaints.example','Brgy. Sabang, Lipa City, Batangas');

INSERT INTO products (product_id, sku, product_name, category_id, supplier_id, unit_price, stock_quantity, reorder_level, unit) VALUES
 (1,'CM-1001','Portland Cement 40 kg',1,1,265.00,520,80,'bag'),
 (2,'CM-1004','CHB 4" (100 mm)',1,1,14.00,1450,500,'pcs'),
 (3,'CM-1006','CHB 6" (150 mm)',1,1,19.00,380,500,'pcs'),
 (4,'CM-1010','Hollow Blocks 8"',1,1,26.00,0,200,'pcs'),
 (5,'ST-2001','Rebar 10 mm x 6 m',2,2,238.00,64,100,'pcs'),
 (6,'ST-2008','GI Wire #16',2,2,98.00,42,20,'kg'),
 (7,'LB-3002','Marine Plywood 3/4" 4x8',3,3,1650.00,26,15,'sheet'),
 (8,'LB-3010','Coco Lumber 2" x 3" x 10 ft',3,3,215.00,88,40,'pcs'),
 (9,'PL-4003','PVC Pipe 1/2" x 3 m',4,4,95.00,160,60,'pcs'),
 (10,'PL-4020','Gate Valve 3/4"',4,4,285.00,12,15,'pcs'),
 (11,'EL-5001','Electrical Wire THHN 2.0 mm² (150 m)',5,5,2850.00,14,6,'roll'),
 (12,'EL-5012','Circuit Breaker 20 A',5,5,295.00,40,15,'pcs'),
 (13,'PA-6001','Roof Sealant 4 L',6,6,780.00,11,12,'pail'),
 (14,'PA-6010','Latex Paint White 4 L',6,6,890.00,28,12,'can'),
 (15,'FS-7001','Concrete Nails 3"',7,2,85.00,38,50,'kg');

INSERT INTO inventory_movements (movement_id, product_id, user_id, movement_type, quantity, remarks, movement_date) VALUES
 (1, 1,3,'IN', 200,'PO-2210 · Calamba Cement & Masonry Depot','2026-10-10 08:30:00'),
 (2, 7,5,'IN',  20,'PO-2214 · Imus Lumber & Plywood Center','2026-10-11 10:05:00'),
 (3, 3,3,'OUT',120,'Job site: Brgy. Pasong Camachile, General Mariano Alvarez, Cavite','2026-10-12 13:40:00'),
 (4,10,5,'OUT',  3,'Damaged in storage','2026-10-13 09:10:00'),
 (5,12,5,'IN',  24,'PO-2221 · San Pedro Electrical Supply','2026-10-14 15:22:00'),
 (6, 5,3,'OUT', 40,'Job site: Brgy. Halang, Calamba City, Laguna','2026-10-15 11:48:00'),
 (7,15,5,'IN', 100,'PO-2223 · Batangas Steel Trading Corp.','2026-10-15 14:05:00'),
 (8, 9,3,'IN',  80,'PO-2225 · Valenzuela Pipe & Fittings Supply','2026-10-16 08:20:00'),
 (9,13,3,'ADJ_OUT',2,'Count adjustment: damaged pails','2026-10-16 10:30:00'),
 (10,14,5,'ADJ_IN',1,'Count adjustment: found on shelf','2026-10-16 10:45:00');

INSERT INTO sales (sale_id, receipt_number, user_id, customer_name, payment_method, sale_date) VALUES
 (1,'S-1001',4,'JM Dela Cruz Construction','Charge account','2026-10-10 09:12:00'),
 (2,'S-1002',6,'Walk-in','Cash','2026-10-11 13:40:00'),
 (3,'S-1003',4,'Engr. Ramon Villanueva','Bank transfer','2026-10-12 10:25:00'),
 (4,'S-1004',6,'Aling Lourdes Magsaysay','GCash','2026-10-12 16:05:00'),
 (5,'S-1005',4,'Brgy. San Antonio Captain''s Office','Charge account','2026-10-13 11:15:00'),
 (6,'S-1006',6,'Mang Tony Carpentry','Cash','2026-10-14 09:50:00'),
 (7,'S-1007',4,'Walk-in','Maya','2026-10-14 15:30:00'),
 (8,'S-1008',6,'Kuya Joel Electrical Services','GCash','2026-10-15 10:10:00'),
 (9,'S-1009',4,'Dra. Maricel Pangilinan','Bank transfer','2026-10-15 14:45:00'),
 (10,'S-1010',6,'Beth Tolentino Residence','Cash','2026-10-16 09:05:00'),
 (11,'S-1011',4,'RPG Builders & Realty','Charge account','2026-10-16 11:30:00');

INSERT INTO sale_items (sale_id, product_id, quantity, unit_price) VALUES
 (1,2,300,14.00),(1,1,40,265.00),
 (2,15,6,85.00),(2,6,3,98.00),
 (3,7,8,1650.00),(3,8,30,215.00),
 (4,14,2,890.00),(4,13,1,780.00),
 (5,1,60,265.00),(5,2,200,14.00),
 (6,8,40,215.00),(6,15,10,85.00),
 (7,9,12,95.00),(7,10,2,285.00),
 (8,11,2,2850.00),(8,12,10,295.00),
 (9,7,4,1650.00),(9,13,3,780.00),
 (10,14,3,890.00),(10,9,6,95.00),
 (11,1,80,265.00),(11,5,30,238.00);

-- sales.total_amount is derived from the line items (subtotal is a generated column)
UPDATE sales s SET s.total_amount = (SELECT SUM(si.subtotal) FROM sale_items si WHERE si.sale_id = s.sale_id);

-- every sold line also appears in the stock ledger as an OUT movement (INSERT ... SELECT)
INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks, movement_date)
SELECT si.product_id, s.user_id, 'OUT', si.quantity, CONCAT('Sale ', s.receipt_number), s.sale_date
FROM sale_items si JOIN sales s ON s.sale_id = si.sale_id ORDER BY s.sale_date, si.sale_item_id;

INSERT INTO activity_logs (user_id, action, description, date_created) VALUES
 (1,'LOGIN','Signed in','2026-10-14 08:02:00'),
 (5,'STOCK_IN','Stock in: 24 × Circuit Breaker 20 A','2026-10-14 15:22:00'),
 (2,'SUPPLIER_UPDATE','Supplier updated: Batangas Steel Trading Corp.','2026-10-15 08:30:00'),
 (6,'SALE_CREATE','Sale S-1008 saved','2026-10-15 10:10:00'),
 (3,'STOCK_OUT','Stock out: 40 × Rebar 10 mm x 6 m','2026-10-15 11:48:00'),
 (4,'SALE_CREATE','Sale S-1009 saved','2026-10-15 14:45:00'),
 (1,'PRODUCT_UPDATE','Product updated: Portland Cement 40 kg','2026-10-15 16:20:00'),
 (2,'LOGIN','Signed in','2026-10-16 07:55:00'),
 (3,'STOCK_IN','Stock in: 80 × PVC Pipe 1/2" x 3 m','2026-10-16 08:20:00'),
 (6,'SALE_CREATE','Sale S-1010 saved','2026-10-16 09:05:00'),
 (3,'STOCK_ADJUST','Stock adjusted: Roof Sealant 4 L, 13 to 11 (damaged pails)','2026-10-16 10:30:00'),
 (4,'SALE_CREATE','Sale S-1011 saved','2026-10-16 11:30:00');

INSERT INTO settings (setting_id, store_name, tax_rate, reorder_level, receipt_footer) VALUES
 (1,'Irongate Hardware',12.00,20,'Thank you for your purchase.');
