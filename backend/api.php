<?php
// api.php - the single backend endpoint for Stock Keeper.
// The frontend calls:  api.php?action=<name>   (JSON in, JSON out)

session_set_cookie_params(["httponly" => true, "samesite" => "Lax"]);
session_start();
header("Content-Type: application/json; charset=utf-8");
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT); // DB errors become exceptions

/* ---------- small helpers ---------- */
function out($data, $code = 200) {
    http_response_code($code);
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}
function fail($msg, $code = 400) {
    global $conn;
    if (isset($conn)) { try { $conn->rollback(); } catch (Throwable $t) {} }
    out(["error" => $msg], $code);
}
set_exception_handler(function ($ex) {
    if ($ex instanceof mysqli_sql_exception) {
        if ($ex->getCode() == 1451) fail("Cannot delete: this record is still used by other data", 409);
        if ($ex->getCode() == 1062) fail("That value already exists (duplicate SKU, name or email)", 409);
        if (in_array($ex->getCode(), [3819, 4025])) fail("A value was rejected by the database rules", 422);
    }
    error_log($ex->getMessage());
    fail("Server error. Check that MySQL is running and db.php is correct.", 500);
});

require __DIR__ . "/db.php";

function rows($sql, $types = "", $args = []) {
    global $conn;
    $st = $conn->prepare($sql);
    if ($types !== "") $st->bind_param($types, ...$args);
    $st->execute();
    return $st->get_result()->fetch_all(MYSQLI_ASSOC);
}
function run($sql, $types = "", $args = []) {
    global $conn;
    $st = $conn->prepare($sql);
    if ($types !== "") $st->bind_param($types, ...$args);
    $st->execute();
    return $st;
}

/* ---------- roles and permissions (same matrix as app.js) ---------- */
$ROLE_KEY = [1 => "admin", 2 => "manager", 3 => "inventory", 4 => "cashier"];
$ROLE_ID  = array_flip($ROLE_KEY);
$CAN = [
    "manage" => ["admin", "manager"],
    "users"  => ["admin"],
    "stock"  => ["admin", "inventory"],
    "sell"   => ["admin", "cashier"],
];

function current_user() {
    global $ROLE_KEY;
    static $u = false;
    if ($u !== false) return $u;
    $u = null;
    if (!empty($_SESSION["uid"])) {
        $r = rows("SELECT user_id, full_name, job_title, role_id, status FROM users WHERE user_id = ?", "i", [$_SESSION["uid"]])[0] ?? null;
        if ($r && $r["status"] === "Active") {
            $u = [
                "id"    => (int)$r["user_id"],
                "name"  => $r["full_name"],
                "title" => $r["job_title"] ?? "",
                "role"  => $ROLE_KEY[(int)$r["role_id"]],
            ];
        }
    }
    return $u;
}
function need($perm = null) {
    global $CAN;
    $u = current_user();
    if (!$u) fail("Please sign in", 401);
    if ($perm && !in_array($u["role"], $CAN[$perm])) fail("Permission denied: your role cannot do this", 403);
    return $u;
}

/* ---------- input ---------- */
$action = $_GET["action"] ?? "";
$in = json_decode(file_get_contents("php://input"), true);
if (!is_array($in)) $in = [];
$str = fn($k, $max = 255) => mb_substr(trim((string)($in[$k] ?? "")), 0, $max);

/* creates a user row with a hashed password; returns the new user_id */
function make_user($name, $title, $roleKey, $pw, $phone = null, $status = "Active") {
    global $conn, $ROLE_ID;
    $base = strtolower(trim(preg_replace('/[^a-z0-9]+/i', ".", $name), "."));
    $base = substr($base ?: "user", 0, 30);
    $username = $base;
    $n = 1;
    while (rows("SELECT 1 FROM users WHERE username = ?", "s", [$username])) {
        $username = $base . ++$n;
    }
    $email = $username . "@stockkeeper.example";
    $hash = password_hash($pw, PASSWORD_BCRYPT);
    $rid = $ROLE_ID[$roleKey];
    $title = $title === "" ? null : $title;
    run("INSERT INTO users (full_name, username, email, password_hash, role_id, job_title, phone, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)", "ssssisss",
        [$name, $username, $email, $hash, $rid, $title, $phone, $status]);
    return $conn->insert_id;
}
function other_active_admins($excludeId) {
    return (int)rows("SELECT COUNT(*) c FROM users WHERE role_id = 1 AND status = 'Active' AND user_id <> ?", "i", [$excludeId])[0]["c"];
}

switch ($action) {

/* ====================== AUTH ====================== */
case "login_users": // public: fills the account dropdown on the login screen
    $list = [];
    foreach (rows("SELECT user_id, full_name, role_id FROM users WHERE status = 'Active' ORDER BY user_id") as $r) {
        $list[] = ["id" => (int)$r["user_id"], "name" => $r["full_name"], "role" => $ROLE_KEY[(int)$r["role_id"]],
                   "title" => "", "phone" => "", "status" => "Active"];
    }
    $s = rows("SELECT store_name FROM settings WHERE setting_id = 1")[0] ?? ["store_name" => "Stock Keeper"];
    out(["users" => $list, "store" => $s["store_name"]]);

case "login":
    $id = (int)($in["id"] ?? 0);
    $pw = (string)($in["password"] ?? "");
    $r = rows("SELECT user_id, password_hash, status FROM users WHERE user_id = ?", "i", [$id])[0] ?? null;
    if (!$r || $r["status"] !== "Active" || !password_verify($pw, $r["password_hash"])) {
        fail("Incorrect password", 401);
    }
    session_regenerate_id(true);
    $_SESSION["uid"] = (int)$r["user_id"];
    out(["ok" => true]);

case "logout":
    $_SESSION = [];
    session_destroy();
    out(["ok" => true]);

    case "deactivate_self":
    $u = need();

    // Only administrators can reactivate accounts
    if ($u["role"] !== "admin") {
        fail("Only administrators can reactivate accounts", 403);
    }

    $id = (int)($in["id"] ?? 0);

    if ($id < 1) {
        fail("Invalid employee account");
    }

    // Reactivate the selected employee
    run(
        "UPDATE users SET status = 'Active' WHERE user_id = ?",
        "i",
        [$id]
    );

    out([
        "ok" => true,
        "message" => "Employee account reactivated successfully."
    ]);

    // Prevent the last active administrator from deactivating
    if (
        $u["role"] === "admin" &&
        other_active_admins($u["id"]) < 1
    ) {
        fail("You cannot deactivate the last active administrator");
    }

    // Deactivate the currently signed-in account
    run(
        "UPDATE users SET status = 'Inactive' WHERE user_id = ?",
        "i",
        [$u["id"]]
    );

    // Log the user out
    $_SESSION = [];
    session_destroy();

    out([
        "ok" => true,
        "message" => "Your account has been deactivated."
    ]);

case "register": // public sign-up. Administrators cannot be created this way.
    $name = $str("name", 100);
    $title = $str("title", 80);
    $role = $str("role", 20);
    $pw = (string)($in["password"] ?? "");
    if ($name === "") fail("Full name is required");
    if (strlen($pw) < 6) fail("Use at least 6 characters for the password");
    if (!isset($ROLE_ID[$role]) || $role === "admin") fail("Choose a valid role. Administrators are created by an existing administrator.");
    $newId = make_user($name, $title, $role, $pw);
    out(["id" => $newId]);

/* ====================== LOAD EVERYTHING ====================== */
case "bootstrap":
    $u = need();
    $data = [];

    $data["cats"] = array_map(fn($r) => ["id" => (int)$r["category_id"], "name" => $r["category_name"], "desc" => $r["description"] ?? ""],
        rows("SELECT category_id, category_name, description FROM categories ORDER BY category_id"));

    $data["sup"] = array_map(fn($r) => ["id" => (int)$r["supplier_id"], "name" => $r["company_name"], "contact" => $r["contact_person"],
        "phone" => $r["phone"], "email" => $r["email"] ?? "", "city" => $r["address"]],
        rows("SELECT supplier_id, company_name, contact_person, phone, email, address FROM suppliers ORDER BY supplier_id"));

    $data["prod"] = array_map(fn($r) => ["id" => (int)$r["product_id"], "sku" => $r["sku"], "name" => $r["product_name"],
        "cat" => (int)$r["category_id"], "sup" => (int)$r["supplier_id"], "price" => (float)$r["unit_price"],
        "stock" => (int)$r["stock_quantity"], "min" => (int)$r["reorder_level"], "unit" => $r["unit"]],
        rows("SELECT product_id, sku, product_name, category_id, supplier_id, unit_price, stock_quantity, reorder_level, unit
              FROM products ORDER BY product_id"));

    $data["mov"] = array_map(fn($r) => ["id" => (int)$r["movement_id"], "date" => $r["d"], "pid" => (int)$r["product_id"],
        "type" => substr($r["movement_type"], -2) === "IN" ? "IN" : "OUT", "qty" => (int)$r["quantity"],
        "note" => $r["remarks"] ?: "—", "by" => $r["full_name"]],
        rows("SELECT m.movement_id, DATE_FORMAT(m.movement_date, '%Y-%m-%d %H:%i') d, m.product_id, m.movement_type, m.quantity, m.remarks, u.full_name
              FROM inventory_movements m JOIN users u ON u.user_id = m.user_id
              ORDER BY m.movement_date, m.movement_id"));

    $items = [];
    foreach (rows("SELECT sale_id, product_id, quantity, unit_price FROM sale_items ORDER BY sale_item_id") as $r) {
        $items[(int)$r["sale_id"]][] = ["pid" => (int)$r["product_id"], "qty" => (int)$r["quantity"], "price" => (float)$r["unit_price"]];
    }
    $data["sales"] = array_map(fn($r) => ["id" => $r["receipt_number"], "date" => $r["d"], "cust" => $r["customer_name"],
        "pay" => $r["payment_method"], "by" => $r["full_name"], "items" => $items[(int)$r["sale_id"]] ?? []],
        rows("SELECT s.sale_id, s.receipt_number, DATE_FORMAT(s.sale_date, '%Y-%m-%d %H:%i') d, s.customer_name, s.payment_method, u.full_name
              FROM sales s JOIN users u ON u.user_id = s.user_id
              ORDER BY s.sale_date, s.sale_id"));

    $s = rows("SELECT store_name, tax_rate, reorder_level, receipt_footer FROM settings WHERE setting_id = 1")[0]
         ?? ["store_name" => "Stock Keeper", "tax_rate" => 12, "reorder_level" => 20, "receipt_footer" => ""];
    $data["set"] = ["store" => $s["store_name"], "tax" => (float)$s["tax_rate"], "reorder" => (int)$s["reorder_level"], "footer" => $s["receipt_footer"] ?? ""];

    // employees and logs are only sent to roles that can see them
    $data["emp"] = [];
    if ($u["role"] === "admin") {
        $data["emp"] = array_map(fn($r) => ["id" => (int)$r["user_id"], "name" => $r["full_name"], "title" => $r["job_title"] ?? "",
            "role" => $ROLE_KEY[(int)$r["role_id"]], "phone" => $r["phone"] ?: "—", "status" => $r["status"]],
            rows("SELECT user_id, full_name, job_title, role_id, phone, status FROM users ORDER BY user_id"));
    }
    $data["logs"] = [];
    if (in_array($u["role"], ["admin", "manager"])) {
        $data["logs"] = array_map(fn($r) => ["t" => $r["d"], "u" => $r["full_name"] ?? "Deleted user",
            "r" => $r["role_id"] ? $ROLE_KEY[(int)$r["role_id"]] : "cashier", "a" => $r["description"]],
            rows("SELECT * FROM (
                    SELECT l.log_id, DATE_FORMAT(l.date_created, '%Y-%m-%d %H:%i') d, u.full_name, u.role_id, l.description
                    FROM activity_logs l LEFT JOIN users u ON u.user_id = l.user_id
                    ORDER BY l.log_id DESC LIMIT 300) t ORDER BY log_id"));
    }
    out(["user" => $u, "data" => $data]);

/* ====================== PRODUCTS ====================== */
case "save_product":
    $u = need("manage");
    $id = (int)($in["id"] ?? 0);
    $sku = $str("sku", 30); $name = $str("name", 150); $unit = $str("unit", 20);
    $cat = (int)($in["cat"] ?? 0); $sup = (int)($in["sup"] ?? 0);
    $price = (float)($in["price"] ?? 0); $stock = (int)($in["stock"] ?? 0); $min = (int)($in["min"] ?? 0);
    if ($sku === "" || $name === "" || $unit === "") fail("SKU, name and unit are required");
    if ($price <= 0) fail("Price must be greater than zero");
    if ($stock < 0 || $min < 0) fail("Stock and reorder level cannot be negative");
    $conn->begin_transaction();
    if ($id) {
        $old = rows("SELECT stock_quantity FROM products WHERE product_id = ? FOR UPDATE", "i", [$id])[0] ?? null;
        if (!$old) fail("Product not found", 404);
        run("UPDATE products SET sku=?, product_name=?, category_id=?, supplier_id=?, unit_price=?, stock_quantity=?, reorder_level=?, unit=?
             WHERE product_id=?", "ssiidiisi", [$sku, $name, $cat, $sup, $price, $stock, $min, $unit, $id]);
        $diff = $stock - (int)$old["stock_quantity"];
        if ($diff != 0) { // keep the stock ledger honest when stock is edited here
            run("INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks) VALUES (?, ?, ?, ?, 'Edited in product form')",
                "iisi", [$id, $u["id"], $diff > 0 ? "ADJ_IN" : "ADJ_OUT", abs($diff)]);
        }
    } else {
        run("INSERT INTO products (sku, product_name, category_id, supplier_id, unit_price, stock_quantity, reorder_level, unit)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)", "ssiidiis", [$sku, $name, $cat, $sup, $price, $stock, $min, $unit]);
        $newId = $conn->insert_id;
        if ($stock > 0) {
            run("INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks) VALUES (?, ?, 'IN', ?, 'Opening stock')",
                "iii", [$newId, $u["id"], $stock]);
        }
    }
    $conn->commit();
    out(["ok" => true]);

case "delete_product":
    need("manage");
    run("DELETE FROM products WHERE product_id = ?", "i", [(int)($in["id"] ?? 0)]);
    out(["ok" => true]);

/* ====================== CATEGORIES ====================== */
case "save_category":
    need("manage");
    $id = (int)($in["id"] ?? 0);
    $name = $str("name", 60);
    $desc = $str("desc", 255);
    $desc = $desc === "" ? null : $desc;
    if ($name === "") fail("Category name is required");
    if ($id) run("UPDATE categories SET category_name=?, description=? WHERE category_id=?", "ssi", [$name, $desc, $id]);
    else     run("INSERT INTO categories (category_name, description) VALUES (?, ?)", "ss", [$name, $desc]);
    out(["ok" => true]);

case "delete_category":
    need("manage");
    run("DELETE FROM categories WHERE category_id = ?", "i", [(int)($in["id"] ?? 0)]);
    out(["ok" => true]);

/* ====================== SUPPLIERS ====================== */
case "save_supplier":
    need("manage");
    $id = (int)($in["id"] ?? 0);
    $name = $str("name", 120); $contact = $str("contact", 100); $city = $str("city", 255);
    $phone = $str("phone", 30); $email = $str("email", 120);
    $email = $email === "" ? null : $email;
    if ($name === "" || $contact === "" || $city === "" || $phone === "") fail("Company, contact, city and phone are required");
    if ($id) run("UPDATE suppliers SET company_name=?, contact_person=?, phone=?, email=?, address=? WHERE supplier_id=?",
                 "sssssi", [$name, $contact, $phone, $email, $city, $id]);
    else     run("INSERT INTO suppliers (company_name, contact_person, phone, email, address) VALUES (?, ?, ?, ?, ?)",
                 "sssss", [$name, $contact, $phone, $email, $city]);
    out(["ok" => true]);

case "delete_supplier":
    need("manage");
    run("DELETE FROM suppliers WHERE supplier_id = ?", "i", [(int)($in["id"] ?? 0)]);
    out(["ok" => true]);

/* ====================== EMPLOYEES (administrator only) ====================== */
case "save_employee":
    $u = need("users");
    $id = (int)($in["id"] ?? 0);
    $name = $str("name", 100); $title = $str("title", 80); $role = $str("role", 20);
    $phone = $str("phone", 30); $status = $str("status", 10) ?: "Active";
    if ($phone === "" || $phone === "—") $phone = null;
    if ($name === "") fail("Full name is required");
    if (!isset($ROLE_ID[$role])) fail("Invalid role");
    if (!in_array($status, ["Active", "Inactive"])) fail("Invalid status");
    if ($id) {
        if ($id === $u["id"]) fail("Ask another administrator to edit your own record");
        $cur = rows("SELECT role_id FROM users WHERE user_id = ?", "i", [$id])[0] ?? null;
        if (!$cur) fail("Employee not found", 404);
        if ((int)$cur["role_id"] === 1 && ($role !== "admin" || $status !== "Active") && other_active_admins($id) < 1) {
            fail("You cannot demote or deactivate the last administrator");
        }
        run("UPDATE users SET full_name=?, job_title=?, role_id=?, phone=?, status=? WHERE user_id=?",
            "ssissi", [$name, $title === "" ? null : $title, $ROLE_ID[$role], $phone, $status, $id]);
    } else {
        $pw = (string)($in["pw"] ?? "");
        if (strlen($pw) < 6) fail("Use at least 6 characters for the password");
        make_user($name, $title, $role, $pw, $phone, $status);
    }
    out(["ok" => true]);

case "delete_employee":
    // Only administrators may delete employee accounts.
    $u = need("users");
    $id = (int)($in["id"] ?? 0);
    if ($id <= 0) fail("Choose a valid employee account");
    if ($id === $u["id"]) fail("You cannot delete your own account");

    $cur = rows("SELECT role_id, status FROM users WHERE user_id = ?", "i", [$id])[0] ?? null;
    if (!$cur) fail("Employee account not found", 404);
    if ((int)$cur["role_id"] === 1 && $cur["status"] === "Active" && other_active_admins($id) < 1) {
        fail("You cannot delete the last active administrator");
    }

    // Preserve sales, inventory movements, and activity history. If a foreign key
    // prevents permanent deletion, deactivate this account instead.
    try {
        run("DELETE FROM users WHERE user_id = ?", "i", [$id]);
        out(["ok" => true, "deleted" => true]);
    } catch (mysqli_sql_exception $ex) {
        if ($ex->getCode() !== 1451) throw $ex;
        run("UPDATE users SET status = 'Inactive' WHERE user_id = ?", "i", [$id]);
        out([
            "ok" => true,
            "deleted" => false,
            "deactivated" => true,
            "message" => "This employee has linked history, so the account was deactivated instead of permanently deleted."
        ]);
    }

/* ====================== STOCK MOVEMENTS ====================== */
case "add_movement":
    $u = need("stock");
    $pid = (int)($in["pid"] ?? 0);
    $type = ($in["type"] ?? "") === "OUT" ? "OUT" : "IN";
    $qty = (int)($in["qty"] ?? 0);
    $note = $str("note", 255);
    if ($qty <= 0) fail("Quantity must be at least 1");
    $conn->begin_transaction();
    $p = rows("SELECT stock_quantity FROM products WHERE product_id = ? FOR UPDATE", "i", [$pid])[0] ?? null;
    if (!$p) fail("Product not found", 404);
    if ($type === "OUT" && $qty > (int)$p["stock_quantity"]) fail("Only " . $p["stock_quantity"] . " on hand", 422);
    $delta = $type === "OUT" ? -$qty : $qty;
    run("UPDATE products SET stock_quantity = stock_quantity + ? WHERE product_id = ?", "ii", [$delta, $pid]);
    run("INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks) VALUES (?, ?, ?, ?, ?)",
        "iisis", [$pid, $u["id"], $type, $qty, $note === "" ? null : $note]);
    $conn->commit();
    out(["ok" => true]);

case "adjust_stock":
    $u = need("stock");
    $pid = (int)($in["pid"] ?? 0);
    $new = (int)($in["stock"] ?? -1);
    if ($new < 0) fail("Counted quantity cannot be negative");
    $conn->begin_transaction();
    $p = rows("SELECT stock_quantity FROM products WHERE product_id = ? FOR UPDATE", "i", [$pid])[0] ?? null;
    if (!$p) fail("Product not found", 404);
    $diff = $new - (int)$p["stock_quantity"];
    if ($diff != 0) {
        run("UPDATE products SET stock_quantity = ? WHERE product_id = ?", "ii", [$new, $pid]);
        run("INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks) VALUES (?, ?, ?, ?, 'Count adjustment')",
            "iisi", [$pid, $u["id"], $diff > 0 ? "ADJ_IN" : "ADJ_OUT", abs($diff)]);
    }
    $conn->commit();
    out(["ok" => true]);

/* ====================== SALES ====================== */
case "add_sale":
    $u = need("sell");
    $cust = $str("cust", 120) ?: "Walk-in";
    $pid = (int)($in["pid"] ?? 0);
    $qty = (int)($in["qty"] ?? 0);
    $pay = $str("pay", 20);
    if (!in_array($pay, ["Cash", "GCash", "Maya", "Bank transfer", "Charge account"])) fail("Invalid payment method");
    if ($qty <= 0) fail("Quantity must be at least 1");
    $conn->begin_transaction();
    $p = rows("SELECT unit_price, stock_quantity FROM products WHERE product_id = ? FOR UPDATE", "i", [$pid])[0] ?? null;
    if (!$p) fail("Product not found", 404);
    if ($qty > (int)$p["stock_quantity"]) fail("Only " . $p["stock_quantity"] . " in stock", 422);
    $n = (int)rows("SELECT COALESCE(MAX(CAST(SUBSTRING(receipt_number, 3) AS UNSIGNED)), 1000) + 1 AS n FROM sales")[0]["n"];
    $receipt = "S-" . $n;
    run("INSERT INTO sales (receipt_number, user_id, customer_name, payment_method, total_amount) VALUES (?, ?, ?, ?, 0)",
        "siss", [$receipt, $u["id"], $cust, $pay]);
    $saleId = $conn->insert_id;
    run("INSERT INTO sale_items (sale_id, product_id, quantity, unit_price) VALUES (?, ?, ?, ?)",
        "iiid", [$saleId, $pid, $qty, $p["unit_price"]]);
    run("UPDATE sales SET total_amount = (SELECT SUM(subtotal) FROM sale_items WHERE sale_id = ?) WHERE sale_id = ?", "ii", [$saleId, $saleId]);
    run("UPDATE products SET stock_quantity = stock_quantity - ? WHERE product_id = ?", "ii", [$qty, $pid]);
    run("INSERT INTO inventory_movements (product_id, user_id, movement_type, quantity, remarks) VALUES (?, ?, 'OUT', ?, ?)",
        "iiis", [$pid, $u["id"], $qty, "Sale " . $receipt]);
    $conn->commit();
    out(["receipt" => $receipt]);

/* ====================== SETTINGS & LOGS ====================== */
case "save_settings":
    need("users");
    $store = $str("store", 100);
    $tax = (float)($in["tax"] ?? -1);
    $reorder = (int)($in["reorder"] ?? -1);
    $footer = $str("footer", 255);
    if ($store === "") fail("Store name is required");
    if ($tax < 0 || $tax > 100) fail("Tax rate must be between 0 and 100");
    if ($reorder < 0) fail("Reorder level cannot be negative");
    run("INSERT INTO settings (setting_id, store_name, tax_rate, reorder_level, receipt_footer) VALUES (1, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE store_name = VALUES(store_name), tax_rate = VALUES(tax_rate),
         reorder_level = VALUES(reorder_level), receipt_footer = VALUES(receipt_footer)",
        "sdis", [$store, $tax, $reorder, $footer === "" ? null : $footer]);
    out(["ok" => true]);

case "log":
    $u = need();
    $text = $str("text", 500);
    if ($text === "") out(["ok" => true]);
    if (preg_match('/^Signed in/', $text))            $code = "LOGIN";
    elseif (preg_match('/^Signed out/', $text))       $code = "LOGOUT";
    elseif (preg_match('/^Sale/', $text))             $code = "SALE_CREATE";
    elseif (preg_match('/^(Stock|Quantity)/', $text)) $code = "STOCK";
    elseif (preg_match('/deleted/i', $text))          $code = "DELETE";
    elseif (preg_match('/added/i', $text))            $code = "CREATE";
    else                                              $code = "UPDATE";
    run("INSERT INTO activity_logs (user_id, action, description) VALUES (?, ?, ?)", "iss", [$u["id"], $code, $text]);
    out(["ok" => true]);

default:
    fail("Unknown action", 404);
}