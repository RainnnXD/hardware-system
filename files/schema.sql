-- =============================================================================
-- Irongate Hardware · Inventory & Sales Management System
-- Database schema (MySQL 8.0+ / MariaDB 10.5+, InnoDB, utf8mb4)  ·  Normal form: 3NF
-- =============================================================================
CREATE DATABASE IF NOT EXISTS irongate_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE irongate_db;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS settings, activity_logs, sale_items, sales, inventory_movements,
                     products, suppliers, categories, users, roles;
SET FOREIGN_KEY_CHECKS = 1;

-- 1. roles: lookup table (1 role : many users) -------------------------------
CREATE TABLE roles (
  role_id    TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name  VARCHAR(30)      NOT NULL,
  CONSTRAINT pk_roles PRIMARY KEY (role_id),
  CONSTRAINT uq_roles_name UNIQUE (role_name)
) ENGINE=InnoDB;

-- 2. users --------------------------------------------------------------------
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

-- 3. categories (1 category : many products) ------------------------------------
CREATE TABLE categories (
  category_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_name  VARCHAR(60)       NOT NULL,
  description    VARCHAR(255)      NULL,
  CONSTRAINT pk_categories PRIMARY KEY (category_id),
  CONSTRAINT uq_categories_name UNIQUE (category_name)
) ENGINE=InnoDB;

-- 4. suppliers (1 supplier : many products) -------------------------------------
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

-- 5. products --------------------------------------------------------------------
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

-- 6. inventory_movements: the stock ledger. ADJ_IN / ADJ_OUT record physical-count corrections.
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

-- 7. sales (1 user : many sales) -------------------------------------------------
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

-- 8. sale_items: resolves the MANY-TO-MANY relationship between sales and products.
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

-- 9. activity_logs: audit trail, kept even if the user row is later removed ----------------------
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

-- 10. settings: exactly one row (setting_id is pinned to 1 by a CHECK constraint) ------------------
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
