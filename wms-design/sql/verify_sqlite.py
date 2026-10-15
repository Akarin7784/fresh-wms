#!/usr/bin/env python3
"""
sql/verify_sqlite.py —— 双库对等验证（设计文档 §3.1 / D5 的可证伪检查）

做三件事：
  1. 把 schema_postgres.sql 机械翻译成 SQLite DDL，并打印每一处不得不改的地方。
     改动清单越短，说明"限制在两个引擎交集内建模"这条原则守得越好。
  2. 在 SQLite 上跑与 sql/verify.sh 完全相同的断言（约束、幂等、SoD、差异列、FEFO 视图）。
  3. 用多线程真实复现 §4.3 的条件更新防超卖，并实测 §3.1 R2 声称的 NUMERIC 精度退化。

用法：python sql/verify_sqlite.py
退出码非 0 表示设计文档中的某条主张不成立。
"""
from __future__ import annotations

import re
import sqlite3
import sys
import tempfile
import threading
from decimal import Decimal
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / "sql" / "schema"
SCHEMA_PARTS = (
    "00_preamble.sql",
    "01_master.sql",
    "02_inventory.sql",
    "03_inbound.sql",
    "04_outbound.sql",
    "05_picking.sql",
    "06_pack_ship.sql",
    "08_count.sql",
    "10_returns.sql",
    "09_scrap.sql",
    "11_integration.sql",
    "12_auth.sql",
    "12b_auth_audit.sql",
    "17_processing.sql",
    "18_live.sql",
    "90_available_view.sql",
    "99_grants.sql",
)
OUT_SQL = ROOT / "sql" / "schema_sqlite.sql"

passed = failed = 0


def ok(msg: str) -> None:
    global passed
    passed += 1
    print(f"  \u2713 {msg}")


def bad(msg: str) -> None:
    global failed
    failed += 1
    print(f"  \u2717 {msg}")


# ---------------------------------------------------------------------------
# 1. 机械翻译
# ---------------------------------------------------------------------------

def translate(pg: str) -> tuple[str, list[str]]:
    deltas: list[str] = []
    s = pg

    # delta 1: COMMENT ON —— SQLite 无此语法，只能降级为行内注释
    n_comment = len(re.findall(r"^COMMENT ON .*;$", s, flags=re.M))
    if n_comment:
        s = re.sub(r"^COMMENT ON .*;$", "", s, flags=re.M)
        deltas.append(f"删除 {n_comment} 条 COMMENT ON（SQLite 无该语法，注释降级到行内）")

    # delta 2: now() —— SQLite 无 now() 函数，且表达式默认值必须加括号
    #   九轮 P1：UTC 默认值 DEFAULT (now() AT TIME ZONE 'UTC') 同属这一类，SQLite 的 datetime('now') 恒为 UTC
    n_now = len(re.findall(r"DEFAULT now\(\)", s))
    n_utc = s.count("DEFAULT (now() AT TIME ZONE 'UTC')")
    if n_now or n_utc:
        s = s.replace("DEFAULT (now() AT TIME ZONE 'UTC')", "DEFAULT (datetime('now'))")
        s = s.replace("DEFAULT now()", "DEFAULT (datetime('now'))")
        deltas.append(f"{n_now} 处 DEFAULT now()、{n_utc} 处 DEFAULT (now() AT TIME ZONE 'UTC') → DEFAULT (datetime('now'))（表达式默认值需括号；SQLite 恒为 UTC）")

    # delta 4: 方言专属行 —— 行尾 "-- @pg-only" 的行删除；"-- @sqlite-only " 开头的行取消注释。
    #   只用于交集之外、两库语义相同但语法不同的东西：分区子句、触发器、角色权限（docs/02 §4.4、§4.8）
    n_pg = len(re.findall(r"^.*--\s*@pg-only\s*$", s, flags=re.M))
    n_sl = len(re.findall(r"^-- @sqlite-only ", s, flags=re.M))
    if n_pg or n_sl:
        s = re.sub(r"^.*--\s*@pg-only\s*$\n?", "", s, flags=re.M)
        s = re.sub(r"^-- @sqlite-only ", "", s, flags=re.M)
        deltas.append(f"方言专属行：删除 {n_pg} 行 @pg-only（分区、plpgsql 触发器、角色权限），启用 {n_sl} 行 @sqlite-only（等价触发器）")

    # delta 3: BEGIN/COMMIT —— executescript 自行管理事务
    if "BEGIN;" in s:
        s = s.replace("BEGIN;", "").replace("COMMIT;", "")
        deltas.append("去掉显式 BEGIN/COMMIT（由 executescript 管理）")

    return s, deltas


missing = [name for name in SCHEMA_PARTS if not (SCHEMA_DIR / name).is_file()]
if missing:
    print(f"  ✗ 找不到 {', '.join(str(SCHEMA_DIR / name) for name in missing)}")
    sys.exit(1)
src = "".join((SCHEMA_DIR / name).read_text(encoding="utf-8") for name in SCHEMA_PARTS)
if not src.endswith("\n"):
    src += "\n"
sqlite_ddl, deltas = translate(src)
OUT_SQL.write_text(
    "-- 本文件由 sql/verify_sqlite.py 从 sql/schema/*.sql 按加载顺序机械生成，请勿手改。\n"
    f"-- 翻译产生的改动共 {len(deltas)} 类：\n"
    + "".join(f"--   {i}. {d}\n" for i, d in enumerate(deltas, 1))
    + "\n"
    + sqlite_ddl,
    encoding="utf-8",
)

print("=== 1. PG → SQLite 机械翻译 ===")
print(f"  不得不改的地方共 {len(deltas)} 类：")
for i, d in enumerate(deltas, 1):
    print(f"    {i}. {d}")
if len(deltas) <= 4:  # 第 4 类"方言专属行"仅限分区/触发器/权限，见 docs/02 §4.8
    ok(f"改动仅 {len(deltas)} 类，且全部是语法糖级别（无一处需要改列型/改语义/删功能）")
else:
    bad(f"改动 {len(deltas)} 类，交集原则守得不够，见上方清单")

dbf = tempfile.mktemp(suffix=".db")
conn = sqlite3.connect(dbf, isolation_level=None)   # 自动提交；需要事务时显式 BEGIN/COMMIT
conn.execute("PRAGMA foreign_keys = ON")
try:
    conn.executescript(sqlite_ddl)
    conn.commit()
    ok("翻译后的 DDL 在 SQLite 全量执行通过")
except Exception as e:  # noqa: BLE001
    bad(f"SQLite 建表失败：{e}")
    print("方言交集被突破，§3.1 的规则需要重新审视")
    sys.exit(1)

NT = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
NI = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='index' AND sql IS NOT NULL").fetchone()[0]
NV = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='view'").fetchone()[0]
print(f"  → 表 {NT} 张 / 手工建索引 {NI} 个 / 视图 {NV} 个")
# 期望值：main 8ed5f0c 为 38 表；docs/02 新增 stock_hold、stock_recon_alert、stock_movement_key、stock_ledger_line → 42 表（PG 分区子表不计）。改表数必须同步改这里和 verify.sh
EXPECT_TABLES, EXPECT_VIEWS= 72, 2  # docs/12 +3；第 10 篇 +exception_code、exception_case、return_reservation、return_reservation_line、return_blind_receipt；第 9 篇 +scrap_order、scrap_line；第 17 篇 +8 张 process_*；docs/18 加 9 表 + v_live_death_in_transit
ok(f"表数 = {NT}（期望 {EXPECT_TABLES}）") if NT == EXPECT_TABLES else bad(f"表数 = {NT}，期望 {EXPECT_TABLES}")
ok(f"视图数 = {NV}") if NV == EXPECT_VIEWS else bad(f"视图数 = {NV}，期望 {EXPECT_VIEWS}")


def one(sql, *a):
    return conn.execute(sql, a).fetchone()


def expect_block(desc: str, sql: str, want: str) -> None:
    """want = 期望的约束名（CHECK）或列清单（UNIQUE，SQLite 报错只给列不给约束名）。
    只有错误信息精确命中 want 才算通过：被别的约束拦下 = 断言没测到它声称测的东西。"""
    try:
        conn.execute(sql)
        conn.commit()
        bad(f"{desc} → 未拦截（SQLite 侧有洞）")
    except sqlite3.IntegrityError as e:
        conn.rollback()
        msg = str(e)
        if msg.endswith(": " + want) or msg == want:   # 触发器 RAISE 没有前缀，整句精确匹配
            ok(f"{desc} → 已拦截（{msg}）")
        else:
            bad(f"{desc} → 被拦了但约束不对：期望 {want!r}，实际 {msg!r}")


def expect_allow(desc: str, sql: str) -> None:
    try:
        conn.execute(sql)
        conn.commit()
        ok(f"{desc} → 通过")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")
        conn.rollback()


def _run_tx(stmts):
    conn.execute("BEGIN")
    try:
        for st in stmts:
            conn.execute(st)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def expect_block_tx(desc: str, stmts: list[str], want: str) -> None:
    """一个事务里执行一组语句（如：归属行 + 流水 + 去重键），期望被 want 指定的约束/触发器拦下并整体回滚。"""
    try:
        _run_tx(stmts)
        bad(f"{desc} → 未拦截（SQLite 侧有洞）")
    except sqlite3.IntegrityError as e:
        msg = str(e)
        if msg == want or msg.endswith(": " + want):
            ok(f"{desc} → 已拦截并回滚（{msg}）")
        else:
            bad(f"{desc} → 被拦了但约束不对：期望 {want!r}，实际 {msg!r}")


def expect_allow_tx(desc: str, stmts: list[str]) -> None:
    try:
        _run_tx(stmts)
        ok(f"{desc} → 通过")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")


# ---------------------------------------------------------------------------
# 2. 同一套断言
# ---------------------------------------------------------------------------
print("=== 2. 库层不变量断言（与 verify.sh 同一套）===")
seed = [
    "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WHSH01','上海青浦仓','20:00',-1)",
    "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK'),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010')",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10)",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16)",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (11,1,1,1,2,'KG',50000,0),(12,1,2,1,1,'KG',30000,10000),(13,1,3,1,3,'KG',200000,0),(14,1,3,1,1,'KG',80000,0)",
    "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (1,1,1,1,1,100000,-30000,68000)",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')",
]
for s in seed:
    try:
        conn.execute(s)
    except sqlite3.Error as e:   # 种子任何一步失败都立即非零退出
        print(f"  ✗ seed 失败，立即退出：{e}\n    {s}")
        sys.exit(2)
conn.commit()
ok("种子数据写入（含 TIME/DATE/TIMESTAMP/BOOLEAN/NUMERIC 列，未做任何列型改写）")


def assert_n(desc: str, sql: str, n: int) -> None:
    got = one(sql)[0]
    ok(f"{desc} = {got}") if got == n else bad(f"{desc} = {got}，期望 {n}")


assert_n("主数据种子 warehouse", "SELECT count(*) FROM warehouse", 1)
assert_n("主数据种子 zone", "SELECT count(*) FROM zone", 2)
assert_n("主数据种子 location", "SELECT count(*) FROM location", 3)
assert_n("主数据种子 sku", "SELECT count(*) FROM sku", 1)
assert_n("主数据种子 lot", "SELECT count(*) FROM lot", 3)
assert_n("主数据种子 stock", "SELECT count(*) FROM stock", 4)
assert_n("种子 outbound_order", "SELECT count(*) FROM outbound_order", 1)
assert_n("种子 count_line", "SELECT count(*) FROM count_line", 1)

expect_block(
    "I2 超占（allocated>on_hand）",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (900,1,1,1,1,'KG',10000,99000)",
    'ck_stock_nonneg',
)
expect_block(
    "§4.6② 业务层幂等（source_system+source_order_no 重复）",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (2,'OBT2',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')",
    'outbound_order.source_system, outbound_order.source_order_no',
)
expect_block(
    "§2.2 职责分离（拣货人=复核人）",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date,picker_id,checker_id) VALUES (3,'OBT3',1,'SALE','MALL','M-2026-003','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16',77,77)",
    'ck_obo_sod',
)
expect_block(
    "I6 同维度重复库存行（container_id 用 0 哨兵后应被拦）",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (21,1,3,1,1,0,'KG',5000)",
    'stock.warehouse_id, stock.location_id, stock.sku_id, stock.lot_id, stock.container_id',
)

print("=== 2a'. docs/04 出库数量 milli、source_hash、回冲上限 ===")
expect_block(
    "04 D6 source_hash 不是 64 位（空串）",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (4,'OBT4',1,'SALE','MALL','M-2026-004','',1,'CREATED','2026-10-16')",
    'ck_obo_hash',
)
expect_block("N4 source_hash 大写 hex", "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (6,'OBT6',1,'SALE','MALL','M-2026-006','Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')", 'ck_obo_hash')
expect_block("N4 source_hash 非 hex（z）", "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (7,'OBT7',1,'SALE','MALL','M-2026-007','zaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')", 'ck_obo_hash')
expect_block("N4 source_hash 长度 63", "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8,'OBT8',1,'SALE','MALL','M-2026-008','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')", 'ck_obo_hash')
expect_block(
    "04 I4 非法出库单状态",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (5,'OBT5',1,'SALE','MALL','M-2026-005','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'ALLOCATING','2026-10-16')",
    'ck_obo_status',
)
conn.execute("INSERT INTO outbound_line (id,outbound_id,line_no,sku_id,order_qty_milli,picked_qty_milli,uom) VALUES (1,1,1,1,10000,5000,'KG')")
conn.commit()
assert_n("种子 outbound_line", "SELECT count(*) FROM outbound_line", 1)
expect_block("04 D4 回冲超过拣出（reversed > picked）", "UPDATE outbound_line SET reversed_qty_milli = 6000 WHERE id = 1", 'ck_obl_reversed')
expect_block("04 出库行数量为负", "UPDATE outbound_line SET short_qty_milli = -1 WHERE id = 1", 'ck_obl_nonneg')
expect_block("04 出库行数量非整数（SQLite 防 REAL）", "UPDATE outbound_line SET picked_qty_milli = 5000.5 WHERE id = 1", 'ck_obl_int')
_u = "UPDATE outbound_line SET reversed_qty_milli = reversed_qty_milli + 3000 WHERE id = 1 AND reversed_qty_milli + 3000 <= picked_qty_milli"
_r1 = conn.execute(_u).rowcount; conn.commit()
_r2 = conn.execute(_u).rowcount; conn.commit()
ok("04 回冲条件更新：第 1 次 3000 → 1 行；再冲 3000 超过 picked 5000 → 0 行（走 42214，不靠 CHECK）") if (_r1, _r2) == (1, 0) else bad(f"04 回冲条件更新 rowcount = {_r1}/{_r2}（期望 1/0）")


print("=== 2a. docs/02 库存核心：BIGINT *_qty_milli 整数约束与条件 UPDATE ===")
expect_block(
    "02 SQLite 非整数写入 BIGINT（3.5 会被存成 REAL）→ ck_stock_int",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (31,1,3,1,1,7,'KG',3.5)",
    'ck_stock_int',
)
expect_block(
    "02 SQLite 文本小数写入 BIGINT（'12.500'）→ ck_stock_int",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (32,1,3,1,1,8,'KG','12.500')",
    'ck_stock_int',
)
expect_allow(
    "02 文本整数 '12500' 被 INTEGER 亲和性转成整数（合法）",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (33,1,3,1,1,9,'KG','12500')",
)
T33 = one("SELECT typeof(on_hand_qty_milli) FROM stock WHERE id=33")[0]
ok(f"stock 33 存储类型 = {T33}") if T33 == "integer" else bad(f"stock 33 存储类型 = {T33}")
c = conn.execute("UPDATE stock SET reserved_qty_milli = reserved_qty_milli + 50000 WHERE id = 11 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 50000").rowcount
conn.commit()
ok("02 条件预占：available(50000) 恰好够 50000 → rowcount=1") if c == 1 else bad(f"条件预占 rowcount={c}")
c = conn.execute("UPDATE stock SET reserved_qty_milli = reserved_qty_milli + 1 WHERE id = 11 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1").rowcount
conn.commit()
ok("02 条件预占：available=0 再占 1 milli → rowcount=0（走 40904，不靠 CHECK 报错）") if c == 0 else bad(f"超占 rowcount={c}")
# 复原，避免干扰后面的 FEFO 排序断言
conn.execute("UPDATE stock SET reserved_qty_milli = 0 WHERE id = 11")
conn.execute("DELETE FROM stock WHERE id = 33")
conn.commit()

# ---- 以下由用例表生成（verify_sqlite.py 与 verify.sh 同一份用例）----
print("=== 2b. docs/02 库存核心：记账去重、只追加、期初、互斥、占用/冻结状态、对账去重 ===")
expect_block_tx('I5 流水平衡（after<>before+qty*dir）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ0',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'ADJ0',1,1,1,'DOC','ADJUST',-1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,3000,100000,98000,'2026-10-15','ADJ0:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (1,'ADJ0:1:D1:1','ADJ0',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,-1,'2026-10-15')"], 'ck_mv_balance')
expect_allow_tx('期初流水 OPENING（迁移行 seq=1，before=0）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',11,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'OPEN-MIG1',11,1,1,'DOC','OPENING',1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:11:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (2,'OPEN-MIG1:11:D1:1','OPEN-MIG1',11,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,1,'2026-10-15')"])
expect_block_tx('期初流水只能是该行第 1 条', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',111,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'OPEN-MIG1',111,1,1,'DOC','OPENING',1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:111:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (3,'OPEN-MIG1:111:D1:1','OPEN-MIG1',111,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,1,'2026-10-15')"], 'ck_mv_opening')
expect_allow_tx('DOC 过账（调整出 3000）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','ADJ1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (4,'ADJ1:1:D1:1','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,-1,'2026-10-15')"])
expect_block_tx('重复过账：同 biz_no+line_no+op_no+leg，换 idempotency_key', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,9,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','X:other')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (5,'X:other','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,9,-1,'2026-10-15')"], 'stock_movement_key.biz_no, stock_movement_key.line_no, stock_movement_key.op_no, stock_movement_key.leg')
expect_allow_tx('同一 DOC 行第二次合法操作（op_no=2，不被吞）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'ADJ1',1,2,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,47000,46000,'2026-10-15','ADJ1:1:D2:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6,'ADJ1:1:D2:1','ADJ1',1,2,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15')"])
expect_block_tx('idempotency_key 重复（唯一格式）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ9',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'ADJ9',1,1,1,'DOC','ADJUST',-1,11,4,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (7,'ADJ1:1:D1:1','ADJ9',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,4,-1,'2026-10-15')"], 'stock_movement_key.idempotency_key')
expect_block_tx('记账链分叉（同 stock_id+stock_seq）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ8',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'ADJ8',1,1,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ8:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (8,'ADJ8:1:D1:1','ADJ8',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15')"], 'stock_movement_key.stock_id, stock_movement_key.stock_seq')
expect_allow_tx('direction=0 纯事件流水不入链（SHIP）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('SHP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'SHP1',1,1,1,'DOC','SHIP',0,11,3,1,1,1,2,NULL,NULL,NULL,NULL,3000,46000,46000,'2026-10-15','SHP1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (9,'SHP1:1:D1:1','SHP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,0,'2026-10-15')"])
expect_allow_tx('期初：stock 12', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-MIG1',12,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (10,'OPEN-MIG1',12,1,1,'DOC','OPENING',1,12,1,1,2,1,1,NULL,NULL,NULL,NULL,30000,0,30000,'2026-10-15','OPEN-MIG1:12:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (10,'OPEN-MIG1:12:D1:1','OPEN-MIG1',12,1,1,'DOC',NULL,NULL,NULL,NULL,12,1,1,'2026-10-15')"])
expect_allow_tx('PDA 拣货（四元组 77/3/DEV-A/1）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (11,'PK2',3,0,1,'PDA','PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PK2:3:PDEV-A.1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (11,'PK2:3:PDEV-A.1:1','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,2,-1,'2026-10-15')"])
expect_block_tx('Idempotency-Key 过期后 PDA 重放同一四元组（换 idempotency_key）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (12,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','X:replay')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (12,'X:replay','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,3,-1,'2026-10-15')"], 'stock_movement_key.src_task_id, stock_movement_key.src_line_no, stock_movement_key.device_instance_id, stock_movement_key.src_op_seq, stock_movement_key.leg')
expect_allow_tx('同一 PDA 行第二次合法操作（op_seq=2，不被吞）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-A') ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (13,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',2,1000,29000,28000,'2026-10-15','PK2:3:PDEV-A.2:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (13,'PK2:3:PDEV-A.2:1','PK2',3,0,1,'PDA',77,3,'DEV-A',2,12,3,-1,'2026-10-15')"])
expect_block_tx('同一单据行 DOC 与 PDA 互斥（PDA 行上来一条 DOC 过账）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (14,'PK2',3,1,1,'DOC','PICK',-1,12,4,1,2,1,1,NULL,NULL,NULL,NULL,1000,28000,27000,'2026-10-15','PK2:3:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (14,'PK2:3:D1:1','PK2',3,1,1,'DOC',NULL,NULL,NULL,NULL,12,4,-1,'2026-10-15')"], 'ledger_line_owner_mismatch')
expect_block_tx('换设备实例不能直接记账（DEV-B 不是当前持有设备）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PK2',3,'PDA','DEV-B') ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (15,'PK2',3,0,1,'PDA','PICK',-1,12,4,1,2,1,1,77,3,'DEV-B',1,1000,28000,27000,'2026-10-15','PK2:3:PDEV-B.1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (15,'PK2:3:PDEV-B.1:1','PK2',3,0,1,'PDA',77,3,'DEV-B',1,12,4,-1,'2026-10-15')"], 'ledger_line_owner_mismatch')
expect_block_tx('PDA 业务键半截（device_instance_id 为 NULL）', ["INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (16,'PK3',1,0,1,'PDA','PICK',-1,12,4,1,2,1,1,78,1,NULL,1,1000,28000,27000,'2026-10-15','PK3:1:PDEV-A.1:1')"], 'ck_mv_kind')
expect_block_tx('只追加：UPDATE 流水', ["UPDATE stock_movement SET remark='x' WHERE id=4"], 'append_only_violation: stock_movement')
expect_block_tx('只追加：DELETE 去重键', ["DELETE FROM stock_movement_key WHERE movement_id=4"], 'append_only_violation: stock_movement_key')
expect_allow_tx('跨分区去重：10-31 记一条', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('XP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (17,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-10-31','XP1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (17,'XP1:1:D1:1','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-10-31')"])
expect_block_tx('跨分区去重：同一键 11-01 再记（PG 落在另一个分区）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('XP1',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (18,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-11-01','X:xp')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (18,'X:xp','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-11-01')"], 'stock_movement_key.biz_no, stock_movement_key.line_no, stock_movement_key.op_no, stock_movement_key.leg')
expect_allow_tx('占用写入（RESERVE 10000）', ["INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (1,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED')"])
expect_block_tx('占用幂等（同 op_key）', ["INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (2,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED')"], 'stock_reservation.op_key')
expect_block_tx('超消耗（consumed+released > reserve）', ["UPDATE stock_reservation SET consumed_qty_milli=6000, released_qty_milli=5000, status='CONSUMED' WHERE id=1"], 'ck_res')
expect_block_tx('状态与余量不符：全部释放但仍是 RESERVED（过期任务会漏/重复扫）', ["UPDATE stock_reservation SET released_qty_milli=10000 WHERE id=1"], 'ck_res_status')
expect_block_tx('状态与余量不符：余量>0 却标 RELEASED', ["UPDATE stock_reservation SET released_qty_milli=4000, status='RELEASED' WHERE id=1"], 'ck_res_status')
expect_block_tx('冻结超释放', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (1,11,'MANUAL','DAMAGE','MANUAL',0,'HOLD:1',1000,2000,'RELEASED',7)"], 'ck_hold')
expect_block_tx('冻结状态与余量不符（已全释放仍 HELD）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (2,11,'MANUAL','DAMAGE','MANUAL',0,'HOLD:2',1000,1000,'HELD',7)"], 'ck_hold_status')
expect_block_tx('冻结类型不在码表', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (3,11,'FROZEN','DAMAGE','MANUAL',0,'HOLD:3',1000,0,'HELD',7)"], 'ck_hold_type')
expect_block_tx('原因与类型不配（MANUAL 冒用 RETURN_PENDING）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (4,11,'MANUAL','RETURN_PENDING','RETURN_RECORD',501,'HOLD:4',1000,0,'HELD',0)"], 'ck_hold_reason')
expect_block_tx('RETURN_PENDING 必须挂待回库记录且为系统冻结', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (5,11,'RETURN_PENDING','RETURN_PENDING','MANUAL',0,'HOLD:5',1000,0,'HELD',7)"], 'ck_hold_return')
expect_allow_tx('待回库 RETURN_PENDING 冻结（RRH:501）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (10,14,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',501,'RRH:501',5000,0,'HELD',0)"])
expect_block_tx('同一待回库记录重复冻结', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (11,14,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',501,'RRH:501:dup',5000,0,'HELD',0)"], 'stock_hold.source_id')
expect_allow_tx('对账告警（I4, stock 13）', ["INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (1,'I4',1,13,200000,199000)"])
expect_block_tx('同一未闭环差异不重复建告警', ["INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (2,'I4',1,13,200000,198000)"], 'stock_recon_alert.check_code, stock_recon_alert.warehouse_id, stock_recon_alert.stock_id')
expect_allow_tx('重复检出走 upsert 累加 hit_count', ["INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (3,'I4',1,13,200000,198000) ON CONFLICT (check_code,warehouse_id,stock_id) WHERE status <> 'RESOLVED' DO UPDATE SET hit_count = stock_recon_alert.hit_count + 1, actual_qty_milli = excluded.actual_qty_milli"])
expect_allow_tx('闭环后同一差异可再开', ["UPDATE stock_recon_alert SET status='RESOLVED', resolved_by=7, resolution='调整单 ADJ-x' WHERE id=1", "INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (4,'I4',1,13,200000,199000)"])
print("=== 2b2. 小赵复评 C2–C4 + convert_hold ===")
expect_block_tx('C2 只写流水、不写 key 行（库层外键，提交时拦）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ7',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (30,'ADJ7',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1')"], 'FOREIGN KEY constraint failed')
expect_block_tx('C2 key 行与流水内容不一致（key=ADJ7，流水=ADJ6）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('ADJ7',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (31,'ADJ6',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (31,'ADJ7:1:D1:1','ADJ7',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,1,-1,'2026-10-15')"], 'FOREIGN KEY constraint failed')
expect_block_tx('C3 归属行 src_kind 从 PDA 改成 DOC', ["UPDATE stock_ledger_line SET src_kind='DOC', owner_device_instance_id=NULL WHERE biz_no='PK2' AND line_no=3"], 'ledger_line_immutable')
expect_block_tx('C3 归属行 biz_no 不可改', ["UPDATE stock_ledger_line SET biz_no='PK9' WHERE biz_no='PK2' AND line_no=3"], 'ledger_line_immutable')
expect_allow_tx('C3 换主（只改 owner_device_instance_id）仍允许', ["UPDATE stock_ledger_line SET owner_device_instance_id='DEV-B', post_count=post_count+1 WHERE biz_no='PK2' AND line_no=3"])
expect_block_tx("C4 check_code='ZZZ'", ["INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9,'ZZZ',1,13,1,2)"], 'ck_recon_code')
try:
    conn.execute("SAVEPOINT rrc")
    conn.execute("INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9021,'RR_HOLD_FAILED',1,12,1000,0),(9020,'RR_HOLD_MISMATCH',1,14,5000,0)")
    ok("C4 正向：check_code='RR_HOLD_FAILED'、'RR_HOLD_MISMATCH'（04 §9 / 05 巡检，#7 Q15）可写入 → 通过（已回滚）")
except sqlite3.Error as e:
    bad(f"C4 RR_HOLD_* 被误拦：{e}")
finally:
    conn.execute("ROLLBACK TO rrc"); conn.execute("RELEASE rrc")
try:
    conn.execute("SAVEPOINT cbx")
    conn.execute("INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9022,'CHECK_BOX_MISMATCH',1,12,1000,0),(9023,'SHIP_EVENT_MISSING',1,14,5000,0)")
    ok("C4 正向：check_code='CHECK_BOX_MISMATCH'、'SHIP_EVENT_MISSING'（06 巡检，#11 Q10）可写入 → 通过（已回滚）")
except sqlite3.Error as e:
    bad(f"C4 06 巡检码被误拦：{e}")
finally:
    conn.execute("ROLLBACK TO cbx"); conn.execute("RELEASE cbx")
expect_allow_tx('convert_hold 准备：stock 40 被 RETURN_PENDING 冻满（available=0）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (40,1,2,1,3,'KG',5000,5000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (30,40,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',601,'RRH:601',5000,0,'HELD',0)"])
expect_allow_tx('convert_hold：available=0 时 RETURN_PENDING → SCRAP_PENDING/SCRAP（source_id = 报损单 9001）', ["SELECT id FROM stock WHERE id = 40 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 30 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (31,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0,30)"])
expect_block_tx('convert_hold 重试：CVT:30 已存在（幂等；SQLite 由 trg_hold_no_replace 先拦，PG 由 uq_hold_op）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (32,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0)"], 'hold_duplicate')
r = one("SELECT s.hold_qty_milli, v.available_qty_milli, (SELECT COALESCE(SUM(hold_qty_milli - released_qty_milli),0) FROM stock_hold WHERE stock_id=40 AND status='HELD' AND hold_type IN ('MANUAL','RETURN_PENDING','SCRAP_PENDING','PROCESSING','LIVE_HOLD')) FROM stock s JOIN v_stock_available v ON v.stock_id=s.id WHERE s.id=40")
ok(f"convert_hold 后 stock.hold_qty={r[0]}、available={r[1]}、明细余量={r[2]}（期望 5000/0/5000，冻结总量不变、I3d 对得上）") if tuple(r) == (5000, 0, 5000) else bad(f"convert_hold 后 {r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0").rowcount
ok("convert_hold 并发第二个：关闭原冻结 rowcount=0（输家再按 CVT:30 查回结果）") if c == 0 else bad(f"重复关闭 rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 31 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount
ok("SCRAP_PENDING 人工解冻：人工路径只放行 QUALITY/MANUAL，rowcount=0（→ 40933）") if c == 0 else bad(f"人工解冻了 SCRAP_PENDING rowcount={c}")
expect_block_tx('N1 SCRAP_PENDING 改成 MANUAL（洗白后人工解冻）', ["UPDATE stock_hold SET hold_type='MANUAL', reason_code='DAMAGE', operator_id=7 WHERE id=31"], 'hold_immutable')
expect_block_tx('N1 改冻结明细数量 hold_qty_milli', ["UPDATE stock_hold SET hold_qty_milli=9000 WHERE id=31"], 'hold_immutable')
expect_block_tx('N1 改冻结来源 source_type/source_id', ["UPDATE stock_hold SET source_type='MANUAL', source_id=0 WHERE id=31"], 'hold_immutable')
conn.execute("BEGIN")
c1 = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000").rowcount
c2 = conn.execute("UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 1000").rowcount
r = one("SELECT s.hold_qty_milli, h.released_qty_milli, h.status FROM stock s JOIN stock_hold h ON h.stock_id=s.id WHERE h.id=31")
conn.execute("ROLLBACK")
ok(f"N1 正常释放仍可：SCRAP_PENDING 释放 1000 + stock.hold_qty −1000 → {tuple(r)}（事务内验证后回滚）") if (c1, c2, tuple(r)) == (1, 1, (4000, 1000, 'HELD')) else bad(f"N1 正常释放 {c1},{c2},{r}")
for mode, sql2, want in (("REVOKED：释放回可用", "UPDATE stock SET hold_qty_milli = hold_qty_milli - 5000, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 5000", (5000, 0, 5000, 'RELEASED')), ("POSTED：释放与扣减同事务", "UPDATE stock SET hold_qty_milli = hold_qty_milli - 5000, on_hand_qty_milli = on_hand_qty_milli - 5000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 40 AND hold_qty_milli >= 5000 AND on_hand_qty_milli >= 5000", (0, 0, 0, 'RELEASED'))):
    conn.execute("BEGIN")
    c1 = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 9001 AND status = 'HELD'").rowcount
    c2 = conn.execute(sql2).rowcount
    r = tuple(one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli, h.status FROM stock s JOIN stock_hold h ON h.stock_id=s.id WHERE h.id=31"))
    conn.execute("ROLLBACK")
    ok(f"release_scrap_hold {mode} → {r}（回滚）") if (c1, c2, r) == (1, 1, want) else bad(f"release_scrap_hold {mode}: {c1},{c2},{r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 31 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 9002 AND status = 'HELD'").rowcount
ok("release_scrap_hold 报损单不匹配（9002）rowcount=0（→ 40930）") if c == 0 else bad(f"错单释放 rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 30 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 601 AND status = 'HELD'").rowcount
ok("release_scrap_hold 非 SCRAP_PENDING 冻结 rowcount=0（→ 40930）") if c == 0 else bad(f"非报损冻结被释放 rowcount={c}")
expect_block_tx('R1 已释放冻结改回 HELD（released 清零）', ["UPDATE stock_hold SET released_qty_milli = 0, status = 'HELD' WHERE id = 30"], 'hold_immutable')
expect_block_tx('R1 释放量减少（5000→1000）', ["UPDATE stock_hold SET released_qty_milli = 1000, status = 'HELD' WHERE id = 30"], 'hold_immutable')
expect_block_tx('R2 DELETE 冻结明细', ["DELETE FROM stock_hold WHERE id = 31"], 'hold_immutable')
expect_block_tx('R2 INSERT OR REPLACE 同 id 洗成 MANUAL', ["INSERT OR REPLACE INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (31,40,'MANUAL','DAMAGE','MANUAL',0,'CVT:30',5000,0,'HELD',7)"], 'hold_duplicate')
expect_block_tx('R2 REPLACE 新 id 撞 op_key（冲突删旧行）', ["REPLACE INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (99,40,'MANUAL','DAMAGE','MANUAL',0,'CVT:30',5000,0,'HELD',7)"], 'hold_duplicate')
r = one("SELECT hold_type, status, released_qty_milli FROM stock_hold WHERE id = 31")
ok(f"R2 绕过尝试后 id=31 仍为 {tuple(r)}") if tuple(r) == ('SCRAP_PENDING', 'HELD', 0) else bad(f"id=31 被改成 {r}")
expect_block_tx('报损冻结不能再用 MANUAL/SCRAP（只能 SCRAP_PENDING）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (33,40,'MANUAL','SCRAP','SCRAP',601,'H33',1000,0,'HELD',7)"], 'ck_hold_reason')
expect_block_tx('SCRAP_PENDING 必须挂报损单且为系统冻结', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (34,40,'SCRAP_PENDING','SCRAP','RETURN_RECORD',601,'H34',1000,0,'HELD',7)"], 'ck_hold_scrap')
mvn = one("SELECT count(*) FROM stock_movement WHERE biz_no='XP1'")[0]
ok("跨分区去重：被拦那笔的流水也随事务回滚（XP1 只有 1 条）") if mvn == 1 else bad(f"XP1 流水 {mvn} 条")

print("=== 2c. docs/02 待回库 RETURN_PENDING：冻结 → 确认解冻（不写流水）===")
# 冻结 10 已在上面写入明细；stock 14 的 frozen 列同事务 +5000（这里补上列，验证可用量）
conn.execute("UPDATE stock SET hold_qty_milli = hold_qty_milli + 5000 WHERE id = 14 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 5000")
AV14 = one("SELECT available_qty_milli FROM v_stock_available WHERE stock_id=14")[0]
ok(f"RETURN_PENDING 冻结后 available = {AV14}（期望 75000，FEFO 分不到）") if AV14 == 75000 else bad(f"冻结后 available={AV14}")
mv0 = one("SELECT count(*) FROM stock_movement")[0]
_run_tx([
    "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 10 AND status = 'HELD'",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 5000 WHERE id = 14 AND hold_qty_milli >= 5000",
])
AV14 = one("SELECT available_qty_milli FROM v_stock_available WHERE stock_id=14")[0]
mv1 = one("SELECT count(*) FROM stock_movement")[0]
ok("确认回库：同事务释放冻结，available 回到 80000，无新增流水") if AV14 == 80000 and mv1 == mv0 else bad(f"确认后 available={AV14} 流水 {mv0}→{mv1}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 10 AND status = 'HELD'").rowcount
ok("冻结只释放一次：再次释放 rowcount=0") if c == 0 else bad(f"重复释放 rowcount={c}")


print("=== 2c2. A3 RETURN_QC 系统冻结、release_qc_hold、QUALITY/RETURN_QC → SCRAP_PENDING ===")
expect_allow_tx('A3 准备：stock 41 质检冻结 9000（RETURN_QC 6000 + QUALITY 3000）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (41,1,2,2,3,'KG',9000,9000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (50,41,'RETURN_QC','RETURN_QC','QC',7001,'RQC:7001',6000,0,'HELD',0)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (51,41,'QUALITY','QC_PENDING','INBOUND_QC',1,'H51',3000,0,'HELD',0)"])
expect_block_tx('A3 RETURN_QC 必须挂质检单且为系统冻结', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (54,41,'RETURN_QC','RETURN_QC','INBOUND_QC',7002,'H54',1000,0,'HELD',5)"], 'ck_hold_retqc')
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount
ok("A3 手工解冻 RETURN_QC rowcount=0（→ 40933）") if c == 0 else bad(f"手工解冻了 RETURN_QC rowcount={c}")
expect_allow_tx('A3 release_qc_hold 释放 1000（去重行 + 明细 + stock 同事务）', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (1,50,'QCR:7001:1',1000)", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 50 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 7001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 1000"])
expect_block_tx('A3 release_qc_hold 重放同一 op_key（不重复解冻；SQLite 由 trg_hr_no_replace 先拦，PG 由 uq_hr_op）', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (2,50,'QCR:7001:1',1000)", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 50 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 7001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 1000"], 'hold_duplicate')
r = one("SELECT h.released_qty_milli, s.quality_hold_qty_milli FROM stock_hold h JOIN stock s ON s.id=h.stock_id WHERE h.id=50")
ok(f"A3 重放后 已释放/quality_hold = {tuple(r)}（只释放一次）") if tuple(r) == (1000, 8000) else bad(f"A3 重放后 {r}")
expect_allow_tx('A3 convert_hold QUALITY → SCRAP_PENDING（跨列：同事务 quality_hold −q、hold_qty +q）', ["SELECT id FROM stock WHERE id = 41 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 51 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 51 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (52,41,'SCRAP_PENDING','SCRAP','SCRAP',9101,'CVT:51',3000,0,'HELD',0,51)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 3000"])
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"A3 QUALITY 转后 quality/hold/available = {tuple(r)}（冻结总量 8000 与可用量不变）") if tuple(r) == (5000, 3000, 1000) else bad(f"A3 QUALITY 转后 {r}")
expect_allow_tx('A3 convert_hold RETURN_QC 剩余 5000 → SCRAP_PENDING', ["SELECT id FROM stock WHERE id = 41 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 50 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND released_qty_milli = 1000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (53,41,'SCRAP_PENDING','SCRAP','SCRAP',9102,'CVT:50',5000,0,'HELD',0,50)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 5000, hold_qty_milli = hold_qty_milli + 5000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 5000"])
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"A3 RETURN_QC 转后 quality/hold/available = {tuple(r)}（冻结总量 8000 与可用量不变）") if tuple(r) == (0, 8000, 1000) else bad(f"A3 RETURN_QC 转后 {r}")
expect_block_tx('A3 stock_hold_release 只追加（UPDATE）', ["UPDATE stock_hold_release SET qty_milli = 2000 WHERE op_key = 'QCR:7001:1'"], 'hold_immutable')


print("=== 2c3. 小赵五轮 Q1/S6 stock_hold_release；Q2 去重记录与 outbox 清理 ===")
expect_block_tx('Q1 INSERT OR REPLACE 同 id 冲掉去重记录', ["INSERT OR REPLACE INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (1,50,'QCR:junk',1)"], 'hold_duplicate')
expect_block_tx('Q1 REPLACE 新 id 撞 op_key', ["REPLACE INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (3,50,'QCR:7001:1',1)"], 'hold_duplicate')
expect_block_tx('Q1 UPSERT ON CONFLICT(op_key) DO UPDATE', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (3,50,'QCR:7001:1',1) ON CONFLICT(op_key) DO UPDATE SET qty_milli = 1"], 'hold_duplicate')
r = one("SELECT count(*), SUM(qty_milli) FROM stock_hold_release WHERE op_key = 'QCR:7001:1'")
ok(f"Q1 绕过尝试后去重记录仍在：{tuple(r)}") if tuple(r) == (1, 1000) else bad(f"去重记录被改：{r}")
expect_block_tx('S6 释放记录挂不存在的冻结（外键）', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (4,999999,'QCR:x:1',1)"], 'FOREIGN KEY constraint failed')
r = conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)").fetchall()
ok("S6 I3e 对账：RETURN_QC 已释放 = Σ释放记录 + 转报损量（无差异行）") if r == [] else bad(f"I3e 差异 {r}")
conn.execute("BEGIN")
conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (55,41,'RETURN_QC','RETURN_QC','QC',7003,'RQC:7003',2000,0,'HELD',0)"); conn.execute("UPDATE stock_hold SET released_qty_milli = 500, version = version + 1 WHERE id = 55")
r = [x[0] for x in conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)").fetchall()]
conn.execute("ROLLBACK")
ok("S6 I3e 反向：绕过释放记录直接 UPDATE 释放 → 对账查出 hold 55") if r == [55] else bad(f"I3e 未查出：{r}")
# 十六轮：SQLite 应用只能插入 PENDING（trg_outbox_insert_pending）。SENT 种子走单独的种子路径：临时 DROP 触发器，写完原样重建
_OB_TRG = one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='trg_outbox_insert_pending'")[0]
def outbox_seed_begin(): conn.execute("DROP TRIGGER trg_outbox_insert_pending"); conn.commit()
def outbox_seed_end(): conn.execute(_OB_TRG); conn.commit()
outbox_seed_begin()
expect_allow_tx('Q2 准备：去重记录（未过期/已过期）+ outbox（PENDING / 8 天前 SENT / 刚 SENT）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','h','{}',200,datetime('now','+1 day')),('dead','h','{}',200,datetime('now','-1 hour'))", "INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8801,'t','k','{}','PENDING',NULL,NULL),(8802,'t','k','{}','SENT',datetime('now','-8 days'),'2XX'),(8803,'t','k','{}','SENT',datetime('now'),'2XX')"])
expect_block_tx('Q2 删未过期去重记录', ["DELETE FROM idempotency_record WHERE idem_key = 'live'"], 'purge_not_allowed: idempotency_record')
expect_block_tx('Q2 删 PENDING 事件', ["DELETE FROM outbox_event WHERE id = 8801"], 'purge_not_allowed: outbox_event')
expect_block_tx('Q2 删刚投递（未过保留期）事件', ["DELETE FROM outbox_event WHERE id = 8803"], 'purge_not_allowed: outbox_event')
expect_block_tx('Q2 INSERT OR REPLACE 覆盖未过期去重记录', ["INSERT OR REPLACE INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','x','{}',200,datetime('now','-1 day'))"], 'idem_duplicate')
expect_block_tx('Q2 REPLACE 覆盖 PENDING 事件', ["REPLACE INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8801,'t','k','{}','SENT',datetime('now','-30 days'))"], 'outbox_duplicate')
expect_allow_tx('Q2 清理（与 purge_expired 同条件）：删已过期去重记录 + 过保留期 SENT 事件', ["DELETE FROM idempotency_record WHERE expires_at < datetime('now')", "DELETE FROM outbox_event WHERE status = 'SENT' AND sent_at < datetime('now','-7 days')"])
r = (one("SELECT group_concat(idem_key) FROM idempotency_record")[0], one("SELECT group_concat(id) FROM (SELECT id FROM outbox_event ORDER BY id)")[0])
ok(f"Q2 清理后剩余 idem={r[0]} outbox={r[1]}（只删了 dead、8802）") if r == ('live', '8801,8803') else bad(f"Q2 清理后 {r}")

print("=== 2c3b. 九轮 P1–P3：UTC 清理、过期列只许往后改、SENT 必带 sent_at ===")
expect_block_tx('P3 status=SENT 但 sent_at 为空', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8804,'t','k','{}','SENT',NULL,'2XX')"], 'ck_outbox_sent')
expect_allow_tx('P3 正向：PENDING 不带 sent_at、SENT 带 sent_at', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at,ack_kind) VALUES (8805,'t','k','{}','PENDING',NULL,NULL),(8806,'t','k','{}','SENT',datetime('now'),'2XX')"])
outbox_seed_end()
r = one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_outbox_insert_pending'")[0]
ok("种子路径结束后 trg_outbox_insert_pending 已重建") if r == 1 else bad("trg_outbox_insert_pending 未重建")
expect_block_tx('R1 补洞：应用以 SENT 状态插入 outbox（sent_at 倒写 1 天前）', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8811,'t','k','{}','SENT',datetime('now','-1 day'))"], 'outbox_insert_not_pending')
expect_block_tx('R1 补洞：应用以 PENDING 插入但带过去的 sent_at', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8812,'t','k','{}','PENDING',datetime('now','-8 days'))"], 'outbox_insert_not_pending')
expect_block_tx('R1 补洞：应用以 FAILED 状态插入 outbox（SQLite 没有角色，非 PENDING 一律拒绝）', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (8814,'t','k','{}','FAILED')"], 'outbox_insert_not_pending')
expect_block_tx('P2 idem expires_at 改早', ["UPDATE idempotency_record SET expires_at = '2000-01-01 00:00:00' WHERE idem_key = 'live'"], 'expiry_backdate: idempotency_record')
expect_block_tx('P2 idem created_at 被改', ["UPDATE idempotency_record SET created_at = '2000-01-01 00:00:00' WHERE idem_key = 'live'"], 'expiry_backdate: idempotency_record')
expect_block_tx('P2 outbox sent_at 改早', ["UPDATE outbox_event SET sent_at = datetime('now','-30 days') WHERE id = 8803"], 'expiry_backdate: outbox_event')
expect_block_tx('P2 outbox sent_at 清空', ["UPDATE outbox_event SET sent_at = NULL, status = 'SENT' WHERE id = 8803"], 'expiry_backdate: outbox_event')
expect_block_tx('P2 PENDING → SENT 时 sent_at 倒填 2000-01-01（R1 起先由 sent_at_not_now 拦）（早于 created_at）', ["UPDATE outbox_event SET status = 'SENT', sent_at = '2000-01-01 00:00:00' WHERE id = 8801"], 'sent_at_not_now')
expect_block_tx('P2 SENT 退回 PENDING', ["UPDATE outbox_event SET status = 'PENDING' WHERE id = 8803"], 'expiry_backdate: outbox_event')
def allow_rb(desc, stmts):
    try:
        conn.execute("SAVEPOINT p2")
        for x in stmts: conn.execute(x)
        ok(f"{desc} → 通过（已回滚）")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")
    finally:
        conn.execute("ROLLBACK TO p2"); conn.execute("RELEASE p2")
allow_rb('P2 正向：idem expires_at 往后延', ["UPDATE idempotency_record SET expires_at = datetime('now','+2 days') WHERE idem_key = 'live'"])
allow_rb('P2 正向：outbox sent_at 往后改、PENDING → SENT 写当前时间', ["UPDATE outbox_event SET sent_at = datetime('now','+1 minute') WHERE id = 8803", "UPDATE outbox_event SET status = 'SENT', ack_kind = '2XX', sent_at = datetime('now') WHERE id = 8801"])
expect_block_tx('R1 PENDING → SENT 时 sent_at 写成 1 小时前', ["UPDATE outbox_event SET status = 'SENT', sent_at = datetime('now','-1 hour') WHERE id = 8801"], 'sent_at_not_now')
expect_block_tx('R1 PENDING → SENT 时 sent_at 写成 1 小时后', ["UPDATE outbox_event SET status = 'SENT', sent_at = datetime('now','+1 hour') WHERE id = 8801"], 'sent_at_not_now')
allow_rb('R1 正向：PENDING → SENT 写当前 UTC（容差内 +3 秒）', ["UPDATE outbox_event SET status = 'SENT', ack_kind = '2XX', sent_at = datetime('now','+3 seconds') WHERE id = 8801"])
expect_block_tx("S1 outbox sent_at 写 'garbage'（julianday 为 NULL，sent_at_not_now 不触发）", ["UPDATE outbox_event SET status = 'SENT', ack_kind = '2XX', sent_at = 'garbage' WHERE id = 8801"], 'ck_outbox_ts')
expect_block_tx('S1 outbox sent_at 写 T 格式（文本比较永远大于 now-7d）', ["UPDATE outbox_event SET status = 'SENT', ack_kind = '2XX', sent_at = strftime('%Y-%m-%dT%H:%M:%S','now') WHERE id = 8801"], 'ck_outbox_ts')
expect_block_tx('S1 outbox next_retry_at 写整数', ['UPDATE outbox_event SET next_retry_at = 1800000000 WHERE id = 8801'], 'ck_outbox_ts')
expect_block_tx('S1 idem expires_at 写整数 1800000000（原可直接 DELETE）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s1int','h','{}',200,1800000000)"], 'ck_idem_ts')
expect_block_tx('S1 idem expires_at 非真实日期 2026-02-30', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s1feb','h','{}',200,'2026-02-30 00:00:00')"], 'ck_idem_ts')
expect_block_tx('S1 idem expires_at 带小数秒（非 19 位标准格式）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s1frac','h','{}',200,'2099-01-01 00:00:00.5')"], 'ck_idem_ts')
expect_block_tx('S1 idem expires_at 25:00:00（time() 为 NULL，CHECK 必须为 FALSE 而不是 UNKNOWN）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s125','h','{}',200,'2026-01-01 25:00:00')"], 'ck_idem_ts')
expect_block_tx('S1 idem expires_at 24:00:00（time() 回写 24:00:00，小时必须 ≤ 23）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s124','h','{}',200,'2026-01-01 24:00:00')"], 'ck_idem_ts')
expect_block_tx('S1 outbox next_retry_at 25:00:00', ["UPDATE outbox_event SET next_retry_at = '2026-01-01 25:00:00' WHERE id = 8801"], 'ck_outbox_ts')
allow_rb('S1 正向：标准 UTC 文本 datetime(\'now\', \'+1 day\')', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('s1ok','h','{}',200,datetime('now','+1 day'))"])
import os, time
cnt = {}
conn.execute("INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('tz_live12h','h','{}',200,datetime('now','+12 hours')),('tz_dead','h','{}',200,datetime('now','-1 hour'))")
old_tz = os.environ.get('TZ')
for tz in ('Etc/GMT-8', 'Etc/GMT+10'):   # POSIX 记号相反：Etc/GMT-8 = UTC+8，Etc/GMT+10 = UTC-10
    os.environ['TZ'] = tz; time.tzset()
    conn.execute("SAVEPOINT tz")
    cnt[tz] = conn.execute("DELETE FROM idempotency_record WHERE expires_at < datetime('now')").rowcount
    conn.execute("ROLLBACK TO tz"); conn.execute("RELEASE tz")
if old_tz is None: os.environ.pop('TZ', None)
else: os.environ['TZ'] = old_tz
time.tzset()
conn.execute("DELETE FROM idempotency_record WHERE idem_key = 'tz_dead'")
ok(f"P1 进程时区 +8 / -10 下清理行数相同 {cnt}（只删 tz_dead）") if list(cnt.values()) == [1, 1] else bad(f"P1 时区清理行数 {cnt}")
r = one("SELECT count(*) FROM idempotency_record WHERE idem_key = 'tz_live12h'")[0]
ok("P1 还剩 12 小时的 tz_live12h 未被删") if r == 1 else bad("tz_live12h 被删")

print("=== 2c4. 误报回转 SCRAP_PENDING → RETURN_QC（SCRAP_MISREPORT 审批）===")
conn.executescript("""
CREATE TABLE IF NOT EXISTS approval_request (
    id BIGINT PRIMARY KEY,
    code VARCHAR(64) NOT NULL,
    CONSTRAINT uq_apr_code UNIQUE (code)
);
INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (90,'W1','x','20:00'),(91,'Z9Z9Z9Z9Z9Z9Z9Z9','x','20:00') ON CONFLICT (id) DO NOTHING;
INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES
 (5001,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'HOLD','5001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5002,'APR-WHSH01-20261015-000002','CANCEL_AFTER_PICK',1,'HOLD','5002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5003,'APR-WHSH01-20261015-000003','CANCEL_AFTER_PICK',1,'HOLD','5003','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5004,'APR-WHSH01-20261015-000004','CANCEL_AFTER_PICK',1,'HOLD','5004','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5009,'APR-WHSH01-20261015-000009','CANCEL_AFTER_PICK',1,'HOLD','5009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5099,'APR-WHSH01-20261015-000099','CANCEL_AFTER_PICK',1,'HOLD','5099','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5123,'APR-WHSH01-20261015-000123','CANCEL_AFTER_PICK',1,'HOLD','5123','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5999,'APR-WHSH01-20261231-999999','CANCEL_AFTER_PICK',1,'HOLD','5999','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5160,'APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000','CANCEL_AFTER_PICK',91,'HOLD','5160','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5011,'APR-W1-20261015-000001','CANCEL_AFTER_PICK',90,'HOLD','5011','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5000,'APR-WHSH01-20260101-000000','CANCEL_AFTER_PICK',1,'HOLD','5000','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01'),
 (5029,'APR-WHSH01-20280229-000001','CANCEL_AFTER_PICK',1,'HOLD','5029','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,'2099-01-01')
ON CONFLICT (code) DO NOTHING;
""")
assert_n("审批号底数：合法 APR 写入 approval_request", "SELECT count(*) FROM approval_request", 12)
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"误报回转前 quality/hold/available = {tuple(r)}") if tuple(r) == (0, 8000, 1000) else bad(f"误报回转前 {r}")
expect_block_tx('误报回转缺审批单号（→ 应用层 40930，库层 ck_hold_approval 兜底）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (57,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,NULL,NULL,1)"], 'ck_hold_approval')
expect_block_tx('误报回转审批类型不是 SCRAP_MISREPORT', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (59,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,'OTHER','APR-WHSH01-20261015-000002',1)"], 'ck_hold_approval')
expect_block_tx('非误报回转的明细不能挂审批（MANUAL + SCRAP_MISREPORT）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (60,41,'MANUAL','DAMAGE','MANUAL',0,'H60',1000,0,'HELD',7,'SCRAP_MISREPORT','APR-WHSH01-20261015-000003')"], 'ck_hold_approval')
expect_allow_tx('误报回转：SCRAP_PENDING 52（3000）→ RETURN_QC 56，挂新质检单 7010 + 审批 APR-WHSH01-20261015-000001；hold −q、quality +q', ["SELECT id FROM stock WHERE id = 41 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 52 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 52 AND hold_type = 'SCRAP_PENDING' AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal,from_hold_id) VALUES (56,41,'RETURN_QC','RETURN_QC','QC',7010,'CVT:52',3000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',1,52)", "UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, quality_hold_qty_milli = quality_hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND hold_qty_milli >= 3000"])
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"误报回转后 quality/hold/available = {tuple(r)}（冻结总量 8000、可用量 1000 不变）") if tuple(r) == (3000, 5000, 1000) else bad(f"误报回转后 {r}")
expect_block_tx('误报回转后审批单号不可改', ["UPDATE stock_hold SET approval_no = 'APR-WHSH01-20261015-000099' WHERE id = 56"], 'hold_immutable')
r = conn.execute("SELECT h.id FROM stock_hold h WHERE h.is_reversal AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE o.id = h.from_hold_id AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)").fetchall()
ok("I3e（含误报回转口径）无差异行") if r == [] else bad(f"I3e 差异 {r}")
conn.execute("BEGIN"); conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (58,41,'RETURN_QC','RETURN_QC','QC',7012,'CVT:999',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000004',1)")
r = [x[0] for x in conn.execute("SELECT h.id FROM stock_hold h WHERE h.is_reversal AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE o.id = h.from_hold_id AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)").fetchall()]
conn.execute("ROLLBACK")
ok("I3e 反向：RETURN_QC 声称回转自不存在的 SCRAP_PENDING 999→ 查出 58") if r == [58] else bad(f"I3e 未查出 {r}")

print("=== 2c5. 审批单号格式 ck_hold_approval_no：APR-{仓库编码}-{yyyyMMdd}-{6位数字} ===")
expect_block_tx("审批单号格式反向：仓库编码小写", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (70,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:870',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-whsh01-20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：前缀不是 APR", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (71,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:871',1000,0,'HELD',0,'SCRAP_MISREPORT','APV-WHSH01-20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码含 '-'", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (72,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:872',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WH-SH-01-20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码为空", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (73,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:873',1000,0,'HELD',0,'SCRAP_MISREPORT','APR--20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：月份 13", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (74,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:874',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261315-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：日期 32", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (75,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:875',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261032-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：序号 5 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (76,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:876',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-00001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：序号 7 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (77,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:877',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-0000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：日期 7 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (78,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:878',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-2026101-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：末尾多空格", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (79,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:879',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001 ',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码 17 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (80,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:880',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-AAAAAAAAAAAAAAAAA-20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码 1 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (81,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:881',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-W-20261015-000001',1)"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码含下划线", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (82,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:882',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH_01-20261015-000001',1)"], "ck_hold_approval_no")
def _allow_rb(desc, stmts):
    try:
        conn.execute('SAVEPOINT fmt')
        for x in stmts: conn.execute(x)
        ok(f'{desc} → 通过（已回滚）')
    except sqlite3.Error as e:
        bad(f'{desc} → 被误拦：{e}')
    finally:
        conn.execute('ROLLBACK TO fmt'); conn.execute('RELEASE fmt')
_allow_rb("审批单号格式正向：常规 WHSH01（APR-WHSH01-20261015-000123）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (90,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:890',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000123',1)"])
_allow_rb("审批单号格式正向：年末日期（APR-WHSH01-20261231-999999）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (91,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:891',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261231-999999',1)"])
_allow_rb("审批单号格式正向：16 位编码（APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (92,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:892',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000',1)"])
_allow_rb("审批单号格式正向：2 位编码（APR-W1-20261015-000001）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (95,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:895',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-W1-20261015-000001',1)"])
_allow_rb("审批单号格式正向：年初 + 序号全 0（APR-WHSH01-20260101-000000）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (96,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:896',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260101-000000',1)"])
expect_block_tx("N1 审批单号非真实日期：2 月 30 日", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (83,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:883',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260230-000001',1)"], "ck_hold_approval_no")
expect_block_tx("N1 审批单号非真实日期：平年 2 月 29 日", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (84,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:884',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20250229-000001',1)"], "ck_hold_approval_no")
expect_block_tx("N1 审批单号非真实日期：4 月 31 日", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (85,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:885',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20260431-000001',1)"], "ck_hold_approval_no")
expect_block_tx("N1 审批单号非真实日期：年份 0000", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (86,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:886',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-00001015-000001',1)"], "ck_hold_approval_no")
_allow_rb("N1 审批单号真实日期正向：闰年 2 月 29 日（APR-WHSH01-20280229-000001）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (93,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:893',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20280229-000001',1)"])
expect_block_tx("N1 回转标记打在非 RETURN_QC 上", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (87,41,'MANUAL','DAMAGE','MANUAL',0,'H87',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',1)"], "ck_hold_reversal_key")
expect_block_tx("N1 RETURN_QC 的 CVT 明细未标回转（不带审批伪造回转）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (88,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:888',1000,0,'HELD',0,NULL,NULL,0)"], "ck_hold_reversal_key")
r = one("SELECT count(*) FROM stock_hold WHERE id >= 70 AND id < 100")[0]
ok("审批单号格式用例全部回滚，无残留明细") if r == 0 else bad(f"审批单号格式用例残留 {r} 行")
print("=== 2d. docs/02 40906：库位锁定写进扣减原语的 WHERE ===")
conn.execute("UPDATE location SET status = 'LOCKED' WHERE id = 3")
DEDUCT = ("UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 "
          "WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 "
          "AND EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED')")
c = conn.execute(DEDUCT).rowcount
ok("库位 LOCKED：扣减 rowcount=0（再按只读分类返回 40906）") if c == 0 else bad(f"锁定库位仍扣减 rowcount={c}")
conn.execute("UPDATE location SET status = 'AVAILABLE' WHERE id = 3")
c = conn.execute(DEDUCT).rowcount
ok("库位解锁后同一语句 rowcount=1") if c == 1 else bad(f"解锁后 rowcount={c}")
conn.execute("UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq - 1 WHERE id = 13")   # 复原（非业务路径）

print("=== 2d2. post_in：REVERSE_PICK 放行库位锁（盘点期间流水），其他来源仍拦 ===")
conn.execute("UPDATE location SET status = 'LOCKED' WHERE id = 3")
POSTIN = "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 13 AND (? = 'REVERSE_PICK' OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))"
c = conn.execute(POSTIN, ("REVERSE_PICK",)).rowcount
ok("库位 LOCKED：REVERSE_PICK 入账 rowcount=1") if c == 1 else bad(f"REVERSE_PICK 被锁拦 rowcount={c}")
c = conn.execute(POSTIN, ("RECEIVE",)).rowcount
ok("库位 LOCKED：RECEIVE 入账 rowcount=0（→ 40906）") if c == 0 else bad(f"RECEIVE 未被锁拦 rowcount={c}")
c = conn.execute(POSTIN, ("MOVE",)).rowcount
ok("库位 LOCKED：MOVE 目标腿 rowcount=0") if c == 0 else bad(f"MOVE 未被锁拦 rowcount={c}")
conn.execute("UPDATE location SET status = 'AVAILABLE' WHERE id = 3")
conn.execute("UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq - 1 WHERE id = 13")   # 复原

print("=== 2e. count_line 整数约束（SQLite 侧）===")
expect_block(
    "count_line 实盘写入 1.5（REAL）",
    "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (2,1,2,1,1,1000,0,1.5)",
    'ck_cnt_int',
)

D = one("SELECT diff_qty_milli FROM count_line WHERE id=1")[0]
ok(f"§5.6 差异生成列 diff_qty_milli = {D}（预期 -2000）") if D == -2000 else bad(f"差异列 = {D}")

print("=== 2f. 部分 convert_hold、PROCESSING/LIVE_HOLD、consume_process_hold、sell_deadline ===")
expect_block_tx("回转 op_key 小写 cvt: 两库都拒（ck_hold_reversal_key）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (130,41,'RETURN_QC','RETURN_QC','QC',7200,'cvt:52',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000009',1)"], "ck_hold_reversal_key")
expect_allow_tx("部分转换准备：stock 45 RETURN_QC 4000", ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (45,1,1,1,3,'KG',4000,4000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (110,45,'RETURN_QC','RETURN_QC','QC',7201,'RQC:7201',4000,0,'HELD',0)"])
expect_allow_tx("convert_hold 部分 2000，调用方键 CVT:110:1", ["SELECT id FROM stock WHERE id = 45 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 110 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 2000, status = CASE WHEN released_qty_milli + 2000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 2000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (111,45,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:110:1',2000,0,'HELD',0,110)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 2000, hold_qty_milli = hold_qty_milli + 2000, version = version + 1 WHERE id = 45 AND quality_hold_qty_milli >= 2000"])
expect_allow_tx("convert_hold 再转 500，另一键 CVT:110:2", ["SELECT id FROM stock WHERE id = 45 ORDER BY id", "SELECT id FROM stock_hold WHERE id = 110 ORDER BY id", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, status = CASE WHEN released_qty_milli + 500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (112,45,'SCRAP_PENDING','SCRAP','SCRAP',9202,'CVT:110:2',500,0,'HELD',0,110)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 500, hold_qty_milli = hold_qty_milli + 500, version = version + 1 WHERE id = 45 AND quality_hold_qty_milli >= 500"])
expect_block_tx("同一调用方键 CVT:110:1 重放", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (113,45,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:110:1',2000,0,'HELD',0,110)"], "hold_duplicate")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 110 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000").rowcount
ok("超量部分转换 rowcount=0（→ 40905）") if c == 0 else bad(f"超量转换 rowcount={c}")
r = one("SELECT h.released_qty_milli, h.status, (SELECT COALESCE(SUM(c.hold_qty_milli),0) FROM stock_hold c WHERE c.from_hold_id = h.id), s.quality_hold_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli - s.allocated_qty_milli - s.reserved_qty_milli - s.quality_hold_qty_milli - s.hold_qty_milli FROM stock_hold h JOIN stock s ON s.id = h.stock_id WHERE h.id = 110")
ok(f"部分转换后 父释放/状态/子合计/quality/hold/available = {tuple(r)}") if tuple(r) == (2500, "HELD", 2500, 1500, 2500, 0) else bad(f"部分转换后 {r}")
expect_block_tx("from_hold_id 不可改", ["UPDATE stock_hold SET from_hold_id = 50 WHERE id = 111"], "hold_immutable")
r = [x[0] for x in conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT SUM(c.hold_qty_milli) FROM stock_hold c WHERE c.from_hold_id = h.id), 0)").fetchall()]
ok("I3e 部分转换后仍无差异（按 from_hold_id 汇总）") if r == [] else bad(f"I3e 差异 {r}")
expect_block_tx("PROCESSING op_key 小写 prci:", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (129,11,'PROCESSING','PROCESSING','PROCESS_ORDER',1,'prci:1',1000,0,'HELD',0)"], "ck_hold_process")
expect_block_tx("PROCESSING operator 非 0（人工 hold 插不进去）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (128,11,'PROCESSING','PROCESSING','PROCESS_ORDER',1,'PRCI:badop',1000,0,'HELD',7)"], "ck_hold_process")
expect_block_tx("LIVE_HOLD 来源不是 LIVE_TANK_HOLD", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (127,11,'LIVE_HOLD','LIVE_HOLD','MANUAL',1,'LH:bad',1000,0,'HELD',0)"], "ck_hold_live")
expect_allow_tx("place_hold PROCESSING：stock 46 冻满 5000", ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (46,1,2,1,2,'KG',5000,5000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (120,46,'PROCESSING','PROCESSING','PROCESS_ORDER',8801,'PRCI:8801',5000,0,'HELD',0)"])
expect_allow_tx("place_hold LIVE_HOLD：stock 47 冻满 3000", ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (47,1,3,1,2,'KG',3000,3000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (121,47,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6601,'LH:6601',3000,0,'HELD',0)"])
r = one("SELECT (SELECT available_qty_milli FROM v_stock_available WHERE stock_id=46), (SELECT available_qty_milli FROM v_stock_available WHERE stock_id=47)")
ok(f"PROCESSING/LIVE_HOLD 可用量 = {tuple(r)}（都从 available 扣除）") if tuple(r) == (0, 0) else bad(f"系统锁可用量 {r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 120 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount
ok("PROCESSING 人工解冻 rowcount=0（→ 40933）") if c == 0 else bad(f"人工解冻了 PROCESSING rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED' WHERE id = 121 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount
ok("LIVE_HOLD 人工解冻 rowcount=0（→ 40933）") if c == 0 else bad(f"人工解冻了 LIVE_HOLD rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, version = version + 1 WHERE id = 121 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500").rowcount
ok("release_hold 不释放 LIVE_HOLD（WHERE 限 PROCESSING，rowcount=0）") if c == 0 else bad(f"release_hold 误放了 LIVE_HOLD rowcount={c}")
expect_allow_tx("consume_process_hold 扣 2000（hold 与 on_hand 同一条 UPDATE，记 PROCESS_CONSUME）", [
    "SELECT id FROM stock WHERE id=46 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=120 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, on_hand_qty_milli = on_hand_qty_milli - 2000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 2000 AND on_hand_qty_milli >= 2000",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 2000, status = CASE WHEN released_qty_milli + 2000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 2000",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC1',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (200,'PRC1',1,1,1,'DOC','PROCESS_CONSUME',-1,46,120,1,1,2,1,2,NULL,NULL,NULL,NULL,2000,5000,3000,'2026-10-16','PRC1:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (200,'PRC1:1:D1:1','PRC1',1,1,1,'DOC',NULL,NULL,NULL,NULL,46,1,-1,'2026-10-16')",
])
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli, h.released_qty_milli, h.status, (SELECT count(*) FROM stock_movement WHERE stock_id=46 AND biz_type='PROCESS_CONSUME') FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
ok(f"consume 2000 后 on_hand/hold/available/released/status/流水 = {tuple(r)}") if tuple(r) == (3000, 3000, 0, 2000, "HELD", 1) else bad(f"consume 2000 {r}")
expect_allow_tx("consume_process_hold 再扣 1000，另一幂等键", [
    "SELECT id FROM stock WHERE id=46 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=120 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, status = CASE WHEN released_qty_milli + 1000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (201,'PRC1',1,2,1,'DOC','PROCESS_CONSUME',-1,46,120,2,1,2,1,2,NULL,NULL,NULL,NULL,1000,3000,2000,'2026-10-16','PRC1:1:D2:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (201,'PRC1:1:D2:1','PRC1',1,2,1,'DOC',NULL,NULL,NULL,NULL,46,2,-1,'2026-10-16')",
])
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli, h.released_qty_milli, (SELECT count(*) FROM stock_movement WHERE stock_id=46 AND biz_type='PROCESS_CONSUME') FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
ok(f"consume 再扣 1000 后 = {tuple(r)}") if tuple(r) == (2000, 2000, 0, 3000, 2) else bad(f"第二次 consume {r}")
expect_block_tx("consume 重放同一幂等键，整笔回滚（不二次扣减）", [
    "SELECT id FROM stock WHERE id=46 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=120 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 1000, on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 46 AND hold_qty_milli >= 1000 AND on_hand_qty_milli >= 1000",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC9',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (202,'PRC9',1,1,1,'DOC','PROCESS_CONSUME',-1,46,120,9,1,2,1,2,NULL,NULL,NULL,NULL,1000,2000,1000,'2026-10-16','PRC1:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (202,'PRC1:1:D1:1','PRC9',1,1,1,'DOC',NULL,NULL,NULL,NULL,46,9,-1,'2026-10-16')",
], "stock_movement_key.idempotency_key")
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, h.released_qty_milli, (SELECT count(*) FROM stock_movement WHERE stock_id=46) FROM stock s JOIN stock_hold h ON s.id = h.stock_id AND h.id=120")
ok(f"重放回滚后 on_hand/hold/released/流水 = {tuple(r)}") if tuple(r) == (2000, 2000, 3000, 2) else bad(f"重放后 {r}")
r = one("SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN 1 ELSE 0 END FROM stock_hold h WHERE h.id=120")
ok("I3f PROCESSING 已释放 = 释放记录 + PROCESS_CONSUME 流水") if r[0] == 1 else bad(f"I3f = {r}")
expect_allow_tx("同一 stock 两条 PROCESSING，只扣其中一条（stock 52 / hold 130、131）", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (52,1,3,2,1,'KG',2000,2000)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (130,52,'PROCESSING','PROCESSING','PROCESS_ORDER',8810,'PRCI:8810',1000,0,'HELD',0),(131,52,'PROCESSING','PROCESSING','PROCESS_ORDER',8811,'PRCI:8811',1000,0,'HELD',0)",
    "SELECT id FROM stock WHERE id=52 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id IN (130,131) ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 400, on_hand_qty_milli = on_hand_qty_milli - 400, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 52 AND hold_qty_milli >= 400 AND on_hand_qty_milli >= 400",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 400, status = CASE WHEN released_qty_milli + 400 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 130 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 400",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC2',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (220,'PRC2',1,1,1,'DOC','PROCESS_CONSUME',-1,52,130,1,1,3,2,1,NULL,NULL,NULL,NULL,400,2000,1600,'2026-10-16','PRC2:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (220,'PRC2:1:D1:1','PRC2',1,1,1,'DOC',NULL,NULL,NULL,NULL,52,1,-1,'2026-10-16')",
])
rows = conn.execute("SELECT h.id, CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN 1 ELSE 0 END FROM stock_hold h WHERE h.id IN (130,131) ORDER BY h.id").fetchall()
ok(f"I3f 按单条冻结对账，未扣的 131 不被 130 的流水算进去 = {rows}") if rows == [(130, 1), (131, 1)] else bad(f"I3f 双冻结 = {rows}")
r = one("SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.stock_id=h.stock_id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0) THEN 1 ELSE 0 END FROM stock_hold h WHERE h.id=131")
ok("按 stock 汇总 PROCESS_CONSUME 会对不上未扣的那条 PROCESSING") if r[0] == 0 else bad(f"按 stock 汇总居然对上了 131：{r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 120 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000").rowcount
ok("consume 超过 PROCESSING 余量 rowcount=0（→ 40905）") if c == 0 else bad(f"超量 consume rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 121 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100").rowcount
ok("consume_process_hold 不接受 LIVE_HOLD（rowcount=0）") if c == 0 else bad(f"LIVE_HOLD 被 consume rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 31 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100").rowcount
ok("consume_process_hold 不接受 SCRAP_PENDING（rowcount=0）") if c == 0 else bad(f"非 PROCESSING 被 consume rowcount={c}")
expect_allow_tx("同池两条 LIVE_HOLD（stock 48/51，source 7701，sku 2，不进 FEFO）", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (48,1,1,2,1,'KG',2000,2000),(51,1,3,2,2,'KG',3500,3500)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (123,48,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7701,'LH:7701:48',2000,0,'HELD',0),(126,51,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7701,'LH:7701:51',3500,0,'HELD',0)",
])
_REL_INS = "INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT v.rid, h.id, 'LTH:7701:8801:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h JOIN (SELECT 81 AS rid, 123 AS hid UNION ALL SELECT 82, 126) v ON h.id = v.hid WHERE h.hold_type='LIVE_HOLD' AND h.source_type='LIVE_TANK_HOLD' AND h.source_id=7701 AND h.status='HELD'"
_REL_HOLD = "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id IN (123,126) AND hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD'"
_REL_STOCK = "UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82)), version=version+1 WHERE id IN (48,51) AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND h.id IN (123,126) AND r.id IN (81,82))"
_REL_COUNT = "SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126')) || '/' || (SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='RELEASED') || '/' || (SELECT count(*) FROM stock WHERE id IN (48,51) AND hold_qty_milli=0)"
conn.execute("BEGIN")
conn.execute("SELECT id FROM stock WHERE id IN (SELECT stock_id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD') ORDER BY id")
conn.execute("SELECT id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD' ORDER BY id")
conn.execute(_REL_INS)
conn.execute(_REL_HOLD)
conn.execute(_REL_STOCK + " AND 1=0")
r = one(_REL_COUNT)[0]
conn.execute("ROLLBACK")
ok(f"release_live_hold 行数不一致 释放/明细/汇总 = {r}，已回滚（→ 50010）") if r == "2/2/0" else bad(f"行数不一致 = {r}")
r = one("SELECT (SELECT status FROM stock_hold WHERE id=123)||'/'||(SELECT status FROM stock_hold WHERE id=126)")[0]
ok("行数不一致回滚后两条仍 HELD") if r == "HELD/HELD" else bad(f"回滚后状态 = {r}")
expect_allow_tx("release_live_hold 整池释放 source 7701", ["SELECT id FROM stock WHERE id IN (SELECT stock_id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD') ORDER BY id", "SELECT id FROM stock_hold WHERE hold_type='LIVE_HOLD' AND source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='HELD' ORDER BY id", _REL_INS, _REL_HOLD, _REL_STOCK])
r = one("SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126'))||'/'||(SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=7701 AND status='RELEASED')||'/'||(SELECT count(*) FROM stock WHERE id IN (48,51) AND hold_qty_milli=0)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=48)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=48)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=51)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=51)")[0]
ok(f"整池释放 释放行/明细/汇总/两行 on_hand/hold = {r}") if r == "2/2/2/2000/0/3500/0" else bad(f"整池释放 = {r}")
r = one("SELECT count(*)||'/'||COALESCE(SUM(qty_milli),0) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126')")[0]
ok("release_live_hold 幂等：等值命中已有 op_key（合计 5500），直接返回不再写") if r == "2/5500" else bad(f"幂等预查 = {r}")
expect_block_tx("release_live_hold 重放同一 op_key", ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (83,123,'LTH:7701:8801:123',2000)"], "hold_duplicate")
r = one("SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:7701:8801:123','LTH:7701:8801:126'))||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=48)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=48)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=51)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=51)")[0]
ok(f"重放回滚后整池释放行数与在库不变 = {r}") if r == "2/2000/0/3500/0" else bad(f"重放后整池 = {r}")
expect_allow_tx("consume_live_hold 准备：stock 50 LIVE_HOLD 4000（source 7702）", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (50,1,2,2,1,'KG',4000,4000)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (125,50,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7702,'LH:7702',4000,0,'HELD',0)",
])
expect_allow_tx("consume_live_hold 部分扣 1500（LIVE_DEATH，一条 SCRAP -1）", [
    "SELECT id FROM stock WHERE id=50 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=125 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 1500, on_hand_qty_milli = on_hand_qty_milli - 1500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 1500 AND on_hand_qty_milli >= 1500",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1500, status = CASE WHEN released_qty_milli + 1500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1500",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD1',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (210,'LD1',1,1,1,'DOC','SCRAP',-1,50,125,1,1,2,2,1,NULL,NULL,NULL,NULL,1500,4000,2500,'2026-10-16','LD1:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (210,'LD1:1:D1:1','LD1',1,1,1,'DOC',NULL,NULL,NULL,NULL,50,1,-1,'2026-10-16')",
])
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli, h.released_qty_milli, h.status, (SELECT count(*) FROM stock_movement WHERE stock_id=50 AND biz_type='SCRAP' AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
ok(f"死亡一次只有一条 -1 流水，部分扣后 = {tuple(r)}") if tuple(r) == (2500, 2500, 0, 1500, "HELD", 1) else bad(f"consume_live_hold {r}")
expect_block_tx("consume_live_hold 重放同一幂等键", [
    "SELECT id FROM stock WHERE id=50 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=125 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 1500, on_hand_qty_milli = on_hand_qty_milli - 1500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 1500 AND on_hand_qty_milli >= 1500",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1500, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1500",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD9',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (212,'LD9',1,1,1,'DOC','SCRAP',-1,50,125,9,1,2,2,1,NULL,NULL,NULL,NULL,1500,2500,1000,'2026-10-16','LD1:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (212,'LD1:1:D1:1','LD9',1,1,1,'DOC',NULL,NULL,NULL,NULL,50,9,-1,'2026-10-16')",
], "stock_movement_key.idempotency_key")
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, h.released_qty_milli, (SELECT count(*) FROM stock_movement WHERE stock_id=50 AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
ok(f"死亡重放不二次扣减，仍一条 -1 流水 = {tuple(r)}") if tuple(r) == (2500, 2500, 1500, 1) else bad(f"死亡重放后 {r}")
expect_allow_tx("consume_live_hold 再扣 500，另一幂等键", [
    "SELECT id FROM stock WHERE id=50 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=125 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 500, on_hand_qty_milli = on_hand_qty_milli - 500, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 50 AND hold_qty_milli >= 500 AND on_hand_qty_milli >= 500",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, status = CASE WHEN released_qty_milli + 500 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (211,'LD1',1,2,1,'DOC','SCRAP',-1,50,125,2,1,2,2,1,NULL,NULL,NULL,NULL,500,2500,2000,'2026-10-16','LD1:1:D2:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (211,'LD1:1:D2:1','LD1',1,2,1,'DOC',NULL,NULL,NULL,NULL,50,2,-1,'2026-10-16')",
])
r = one("SELECT s.on_hand_qty_milli, s.hold_qty_milli, s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli, h.released_qty_milli, (SELECT count(*) FROM stock_movement WHERE stock_id=50 AND direction=-1) FROM stock s JOIN stock_hold h ON s.id=h.stock_id AND h.id=125")
ok(f"consume_live_hold 再扣 500 后 = {tuple(r)}") if tuple(r) == (2000, 2000, 0, 2000, 2) else bad(f"第二次 consume_live {r}")
r = one("SELECT CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='SCRAP' AND m.direction=-1),0) THEN 1 ELSE 0 END FROM stock_hold h WHERE h.id=125")
ok("I3g LIVE_HOLD 已释放 = 释放记录 + 本行 SCRAP 流水") if r[0] == 1 else bad(f"I3g = {r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 125 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000").rowcount
ok("consume_live_hold 超量 rowcount=0（→ 40905）") if c == 0 else bad(f"超量 consume_live rowcount={c}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 100, version = version + 1 WHERE id = 120 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 100").rowcount
ok("consume_live_hold 不接受 PROCESSING（rowcount=0）") if c == 0 else bad(f"PROCESSING 被 consume_live rowcount={c}")
expect_allow_tx("N-1 consume_process_hold：stock 53 冻结 3000，一次扣完并提交", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (53,1,1,2,3,'KG',3000,3000)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (140,53,'PROCESSING','PROCESSING','PROCESS_ORDER',5301,'PRCI:5301',3000,0,'HELD',0)",
    "SELECT id FROM stock WHERE id=53 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=140 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 53 AND hold_qty_milli >= 3000 AND on_hand_qty_milli >= 3000",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, status = CASE WHEN released_qty_milli + 3000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 140 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC3',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (230,'PRC3',1,1,1,'DOC','PROCESS_CONSUME',-1,53,140,1,1,1,2,3,NULL,NULL,NULL,NULL,3000,3000,0,'2026-10-16','PRC3:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (230,'PRC3:1:D1:1','PRC3',1,1,1,'DOC',NULL,NULL,NULL,NULL,53,1,-1,'2026-10-16')",
])
conn.execute("BEGIN")
r = one("SELECT id||'/'||move_qty_milli||'/'||on_hand_before_qty_milli||'/'||on_hand_after_qty_milli FROM stock_movement WHERE idempotency_key = 'PRC3:1:D1:1'")[0]
conn.execute("COMMIT")
ok(f"N-1 加工消耗重放：等值命中原流水，扣减之前就返回 = {r}") if r == "230/3000/3000/0" else bad(f"N-1 加工预查 = {r}")
r = one("SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE idempotency_key='PRC3:1:D1:1') FROM stock s JOIN stock_hold h ON h.id=140 WHERE s.id=53")[0]
ok(f"N-1 加工重放未再扣、未再记账 = {r}") if r == "1/0/0/3000/RELEASED/1" else bad(f"N-1 加工重放后 = {r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 140 AND hold_type = 'PROCESSING' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000").rowcount
ok("N-1 加工：跳过预查时余量扣减 rowcount=0（→ 40905），原语不得走到这一步") if c == 0 else bad(f"N-1 加工 40905 对照 rowcount={c}")
expect_allow_tx("N-1 consume_live_hold：stock 54 冻结 3000，一次扣完并提交", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (54,1,1,2,2,'KG',3000,3000)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (141,54,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6602,'LH:6602',3000,0,'HELD',0)",
    "SELECT id FROM stock WHERE id=54 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=141 ORDER BY id",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 54 AND hold_qty_milli >= 3000 AND on_hand_qty_milli >= 3000",
    "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, status = CASE WHEN released_qty_milli + 3000 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 141 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000",
    "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD3',1,'DOC',NULL)",
    "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,hold_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (231,'LD3',1,1,1,'DOC','SCRAP',-1,54,141,1,1,1,2,2,NULL,NULL,NULL,NULL,3000,3000,0,'2026-10-16','LD3:1:D1:1')",
    "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (231,'LD3:1:D1:1','LD3',1,1,1,'DOC',NULL,NULL,NULL,NULL,54,1,-1,'2026-10-16')",
])
conn.execute("BEGIN")
r = one("SELECT id||'/'||move_qty_milli||'/'||on_hand_before_qty_milli||'/'||on_hand_after_qty_milli FROM stock_movement WHERE idempotency_key = 'LD3:1:D1:1'")[0]
conn.execute("COMMIT")
ok(f"N-1 活鲜消耗重放：等值命中原流水，扣减之前就返回 = {r}") if r == "231/3000/3000/0" else bad(f"N-1 活鲜预查 = {r}")
r = one("SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||h.released_qty_milli||'/'||h.status||'/'||(SELECT count(*) FROM stock_movement WHERE idempotency_key='LD3:1:D1:1') FROM stock s JOIN stock_hold h ON h.id=141 WHERE s.id=54")[0]
ok(f"N-1 活鲜重放未再扣、未再记账 = {r}") if r == "1/0/0/3000/RELEASED/1" else bad(f"N-1 活鲜重放后 = {r}")
c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 3000, version = version + 1 WHERE id = 141 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 3000").rowcount
ok("N-1 活鲜：跳过预查时余量扣减 rowcount=0（→ 40905），原语不得走到这一步") if c == 0 else bad(f"N-1 活鲜 40905 对照 rowcount={c}")
expect_allow_tx("N-2 顺序：stock 61 整池释放一次后提交", [
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (61,1,3,2,3,'KG',3000,3000)",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (172,61,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',7903,'LH:7903',3000,0,'HELD',0)",
    "SELECT id FROM stock WHERE id=61 ORDER BY id",
    "SELECT id FROM stock_hold WHERE id=172 AND status='HELD' ORDER BY id",
    "INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT 193, h.id, 'LTH:7903:9003:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h WHERE h.id=172 AND h.status='HELD'",
    "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id=172 AND status='HELD'",
    "UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r WHERE r.id=193), version=version+1 WHERE id=61 AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r WHERE r.id=193)",
])
conn.execute("BEGIN")
r = one("SELECT (SELECT count(*) FROM stock_hold WHERE id=172 AND status='HELD') || '/' || (SELECT id||':'||qty_milli FROM stock_hold_release WHERE op_key='LTH:7903:9003:172')")[0]
conn.execute("COMMIT")
ok(f"N-2 顺序：第 1 步锁到 0 条 HELD 后重跑幂等查询，返回原释放 = {r}") if r == "0/193:3000" else bad(f"N-2 顺序重查 = {r}")
r = one("SELECT s.version||'/'||s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(SELECT count(*) FROM stock_hold_release WHERE hold_id=172)||'/'||h.version FROM stock s JOIN stock_hold h ON h.id=172 WHERE s.id=61")[0]
ok(f"N-2 顺序重放不插空释放、不抬 version = {r}") if r == "1/3000/0/1/1" else bad(f"N-2 顺序重放后 = {r}")
expect_allow_tx("ck_recon_code 活鲜四码可写入", ["INSERT INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (9101,'LIVE_COUNT_WEIGHT',1,46,1,0),(9102,'LIVE_COUNT_LEDGER',1,46,1,0),(9103,'LIVE_HOLD_MISMATCH',1,47,1,0),(9104,'LIVE_INSPECT_OVERDUE',1,47,1,0)"])
expect_block_tx("已有批次 sell_deadline 从 NULL 补写", ["UPDATE lot SET sell_deadline = '2026-11-01' WHERE id = 1"], "sell_deadline_immutable")
expect_allow_tx("新建批次写入 sell_deadline", ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,sell_deadline) VALUES (90,1,'LOT-SD','2026-12-01','2026-10-01','2026-11-01')"])
expect_block_tx("sell_deadline 改早", ["UPDATE lot SET sell_deadline = '2026-10-01' WHERE id = 90"], "sell_deadline_immutable")
expect_block_tx("sell_deadline 改晚", ["UPDATE lot SET sell_deadline = '2026-12-15' WHERE id = 90"], "sell_deadline_immutable")
expect_block_tx("sell_deadline 清空", ["UPDATE lot SET sell_deadline = NULL WHERE id = 90"], "sell_deadline_immutable")
expect_allow("sell_deadline 不动时其余列可改", "UPDATE lot SET remaining_life_days = 12 WHERE id = 90")

print("=== 2g. docs/10 退货与异常：异常单 I1/I2、A2 键、FAILOVER_GAP、RTN milli、A1/A3/A4 ===")
conn.execute("INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1953,2,'LOT-RTN-1953','2026-10-31','2026-10-14')"); conn.commit()   # #5 自有批次：避开 #2 新增库存行维度
expect_allow('10 准备：异常码字典 RETURN_COUNT_DIFF / FAILOVER_GAP', "INSERT INTO exception_code (code,name,action,liability) VALUES ('RETURN_COUNT_DIFF','拒收回仓清点差异','ADJUST','CARRIER'),('FAILOVER_GAP','故障切换丢单','NONE','WAREHOUSE')")
expect_allow('10 拒收回仓差异异常单（key=POD:1610:0，司机报 5000，仓点 4000）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (100,'EXC-100',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000001',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)")
expect_block('10 同一来源业务键重复建异常单', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (101,'EXC-101',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000002',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7)", 'exc_duplicate')
expect_block('10 差异列必须 = 实点 − 声称', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (102,'EXC-102',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1612:0','0000000000000000000000000000000000000000000000000000000000000003',1,1,5000,4000,1000,'2026-10-15 12:00:00',7)", 'ck_exc_diff')
expect_block('10 I1 异常码不在字典（外键）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (103,'EXC-103',1,'NO_SUCH_CODE','DELIVERY_RETURN','POD:1613:0','0000000000000000000000000000000000000000000000000000000000000004',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)", 'exc_code_unknown')
expect_block('10 I1 来源类型非法', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (104,'EXC-104',1,'RETURN_COUNT_DIFF','BOGUS','X:1','0000000000000000000000000000000000000000000000000000000000000005',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)", 'ck_exc_src_type')
expect_block('10 source_hash 不是 64 位小写 hex', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (105,'EXC-105',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1614:0','h1',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)", 'ck_exc_hash')
expect_block('10 source_hash 大写', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (106,'EXC-106',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1615:0','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)", 'ck_exc_hash')
expect_block('10 关闭异常必须有处置结论和处理人', "UPDATE exception_case SET status='RESOLVED' WHERE id=100", 'ck_exc_close')
expect_block('10 异常单非法状态', "UPDATE exception_case SET status='DONE' WHERE id=100", 'ck_exc_status')
expect_allow('10 OPEN → RESOLVED（ACCEPT_COUNT）', "UPDATE exception_case SET status='RESOLVED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=100")
expect_block('10 I2 RESOLVED 后改实点（同时改差异，ck_exc_diff 仍成立）', 'UPDATE exception_case SET counted_qty_milli=5000, diff_qty_milli=0 WHERE id=100', 'exc_immutable')
expect_block('10 I2 RESOLVED → OPEN', "UPDATE exception_case SET status='OPEN' WHERE id=100", 'exc_state_forward_only')
expect_allow('10 RESOLVED → CLOSED', "UPDATE exception_case SET status='CLOSED', closed_at='2026-10-15 12:00:00' WHERE id=100")
expect_block('10 I2 CLOSED → OPEN', "UPDATE exception_case SET status='OPEN' WHERE id=100", 'exc_state_forward_only')
expect_block('10 I2 CLOSED 后改声称数', 'UPDATE exception_case SET claimed_qty_milli=4000, diff_qty_milli=0 WHERE id=100', 'exc_immutable')
expect_allow('10 A2 首签差异单 POD:1611:0', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (110,'EXC-110',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:0','000000000000000000000000000000000000000000000000000000000000000a',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)")
expect_allow('10 A2 更正后先取消旧单（X5）', "UPDATE exception_case SET status='CANCELLED' WHERE id=110")
expect_block('10 A2 已取消的旧键仍占位（uq_exc_src 不变，不能复用旧键）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (111,'EXC-111',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:0','000000000000000000000000000000000000000000000000000000000000000b',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7)", 'exc_duplicate')
expect_allow('10 A2 更正后新键 POD:1611:1 建单成功', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (112,'EXC-112',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1611:1','000000000000000000000000000000000000000000000000000000000000000c',1,1,5000,3000,-2000,'2026-10-15 12:00:00',7)")
expect_block('10 I2 CANCELLED → OPEN', "UPDATE exception_case SET status='OPEN' WHERE id=110", 'exc_state_forward_only')
expect_allow('10 FAILOVER_GAP 第一次故障 FG:1:ERP:SO-1', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (120,'EXC-120',1,'FAILOVER_GAP','FAILOVER_GAP','FG:1:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000014',1,1,0,0,0,'2026-10-15 12:00:00',7)")
expect_allow('10 FAILOVER_GAP 同一单第二次故障 FG:2:ERP:SO-1 不撞键', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (121,'EXC-121',1,'FAILOVER_GAP','FAILOVER_GAP','FG:2:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000015',1,1,0,0,0,'2026-10-15 12:00:00',7)")
expect_block('10 FAILOVER_GAP 同一次故障同一单重复', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (122,'EXC-122',1,'FAILOVER_GAP','FAILOVER_GAP','FG:1:ERP:SO-1','0000000000000000000000000000000000000000000000000000000000000016',1,1,0,0,0,'2026-10-15 12:00:00',7)", 'exc_duplicate')
expect_block('10 异常码字典责任方取值', "INSERT INTO exception_code (code,name,action,liability) VALUES ('X','x','NONE','NOBODY')", 'ck_exc_liab')
expect_allow('10 准备：RTN 单头 8001（第 3 篇 inbound_order，order_type=RETURN，source=WMS_DELIVERY）', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8001,'RTN-8001',1,'RETURN','WMS_DELIVERY','POD-1610','RECEIVING','2026-10-15')")
expect_block('10 ALTER ck_inb_rtn_src：RETURN 单来源不在白名单', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8002,'RTN-8002',1,'RETURN','WMS','X-1','RECEIVING','2026-10-15')", 'ck_inb_rtn_src')
expect_allow('10 I3 RTN 行 milli 列（实点 4000；声称数在异常单 / 预约行，不在 inbound_line）', "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (8101,8001,1,2,'KG',4000)")
expect_block('10 I3 质检合格+不合格 > 实点', 'UPDATE inbound_line SET qc_passed_qty_milli=3000, qc_failed_qty_milli=1001 WHERE id=8101', 'ck_inbl_qc')
expect_block('10 I3 负的实点', "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (8102,8001,2,2,'KG',-1)", 'ck_inbl_qc')
expect_block('10 I3 非整数 milli（SQLite REAL）', "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (8103,8001,3,2,'KG',1.5)", 'ck_inbl_int')
expect_allow_tx('10 A3 准备：RTN 收货后 RETURN_QC 系统冻结 4000（source=QC/RTN 8001，operator=0）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (60,1,3,2,1953,'KG',4000,4000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (60,60,'RETURN_QC','RETURN_QC','QC',8001,'RQC:8101',4000,0,'HELD',0)"])
expect_block('10 A3 退货待检挂成 QUALITY 人工冻结（RETURN_QC 必须系统冻结）', "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (61,60,'RETURN_QC','RETURN_QC','QC',8001,'RQC:8101b',1000,0,'HELD',7)", 'ck_hold_retqc')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount; conn.commit()
ok('10 A3 人工解冻路径（只放行 QUALITY/MANUAL）对 RETURN_QC → 40933' + ' rowcount=' + str(_c)) if _c == 0 else bad('10 A3 人工解冻路径（只放行 QUALITY/MANUAL）对 RETURN_QC → 40933' + ' rowcount=' + str(_c) + '，期望 0')
expect_allow_tx('10 A4 质检合格：qc_passed +1000 与 release_qc_hold 1000 同事务、同 op_key QCR:8101:1', ['UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli + 1000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 1000 <= received_qty_milli', "INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (60,60,'QCR:8101:1',1000)", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000", 'UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 60 AND quality_hold_qty_milli >= 1000'])
expect_block_tx('10 A4 重放同一 op_key（Key 过期后再提交）整事务回滚', ['UPDATE inbound_line SET qc_passed_qty_milli = qc_passed_qty_milli + 1000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 1000 <= received_qty_milli', "INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (61,60,'QCR:8101:1',1000)", "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1000, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8001 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1000", 'UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 1000, version = version + 1 WHERE id = 60 AND quality_hold_qty_milli >= 1000'], 'hold_duplicate')  # base a93f6f3 Q1：SQLite 先由 BEFORE INSERT 拒 REPLACE/重复
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = released_qty_milli + 500, version = version + 1 WHERE id = 60 AND hold_type = 'RETURN_QC' AND source_type = 'QC' AND source_id = 8002 AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 500").rowcount; conn.commit()
ok('10 A4 release_qc_hold 新签名：inbound_order_id 与冻结 source_id 不符（8002≠8001）→ 40930 rowcount=' + str(_c)) if _c == 0 else bad('10 A4 release_qc_hold 新签名：inbound_order_id 与冻结 source_id 不符（8002≠8001）→ 40930 rowcount=' + str(_c) + '，期望 0')
_v = str(one("SELECT l.qc_passed_qty_milli||'/'||h.released_qty_milli||'/'||s.quality_hold_qty_milli FROM inbound_line l, stock_hold h, stock s WHERE l.id=8101 AND h.id=60 AND s.id=60")[0])
ok('10 A4 重放后 qc_passed/已释放/quality_hold（只记一次、只解一次）' + ' = ' + _v) if _v == '1000/1000/3000' else bad('10 A4 重放后 qc_passed/已释放/quality_hold（只记一次、只解一次）' + ' = ' + _v + '，期望 1000/1000/3000')
expect_block_tx('10 A1 不合格转 SCRAP_PENDING 不能挂质检来源（必须挂报损单）', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND released_qty_milli = 1000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (62,60,'SCRAP_PENDING','SCRAP','QC',8001,'CVT:60:1',3000,0,'HELD',0)"], 'ck_hold_scrap')
expect_allow_tx('10 A1 先建 DRAFT 报损单 9201，再 convert_hold(qty=3000) RETURN_QC → SCRAP_PENDING（子明细 from_hold_id=60）（source=SCRAP/9201）', ['UPDATE inbound_line SET qc_failed_qty_milli = qc_failed_qty_milli + 3000 WHERE id = 8101 AND qc_passed_qty_milli + qc_failed_qty_milli + 3000 <= received_qty_milli', "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 60 AND status = 'HELD' AND released_qty_milli = 1000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,from_hold_id) VALUES (63,60,'SCRAP_PENDING','SCRAP','SCRAP',9201,'CVT:60:1',3000,0,'HELD',0,60)", 'UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 60 AND quality_hold_qty_milli >= 3000'])
_v = str(one("SELECT quality_hold_qty_milli||'/'||hold_qty_milli||'/'||(on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli) FROM stock WHERE id=60")[0])
ok('10 A1 转后 quality/hold/available' + ' = ' + _v) if _v == '0/3000/1000' else bad('10 A1 转后 quality/hold/available' + ' = ' + _v + '，期望 0/3000/1000')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 63 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount; conn.commit()
ok('10 A1 人工解冻路径对转入的 SCRAP_PENDING → 40933' + ' rowcount=' + str(_c)) if _c == 0 else bad('10 A1 人工解冻路径对转入的 SCRAP_PENDING → 40933' + ' rowcount=' + str(_c) + '，期望 0')

expect_allow_tx('10 L1 准备：异常单 140 / 141（OPEN）', ["INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (140,'EXC-140',1,'RETURN_COUNT_DIFF','MANUAL','M:140','0000000000000000000000000000000000000000000000000000000000000082',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)", "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (141,'EXC-141',1,'RETURN_COUNT_DIFF','MANUAL','M:141','0000000000000000000000000000000000000000000000000000000000000083',1,1,5000,4000,-1000,'2026-10-15 12:00:00',7)"])
expect_block('10 L1 OPEN → CLOSED（跳过 RESOLVED）', "UPDATE exception_case SET status='CLOSED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=141", 'exc_state_forward_only')
expect_allow('10 L1 OPEN → PROCESSING', "UPDATE exception_case SET status='PROCESSING', assignee_id=8 WHERE id=140")
expect_block('10 L1 PROCESSING → CLOSED（跳过 RESOLVED）', "UPDATE exception_case SET status='CLOSED', resolution='ACCEPT_COUNT', closed_by=8 WHERE id=140", 'exc_state_forward_only')
expect_block('10 建议 1 处置结论取值非法', "UPDATE exception_case SET resolution='WHATEVER' WHERE id=141", 'ck_exc_resol')
expect_block('10 建议 1 报损处置缺报损单号', "UPDATE exception_case SET status='RESOLVED', resolution='SCRAP', closed_by=8 WHERE id=140", 'ck_exc_resdoc')
expect_allow('10 L1 PROCESSING → RESOLVED（SCRAP，带单号）', "UPDATE exception_case SET status='RESOLVED', resolution='SCRAP', resolution_doc='SCR-1', closed_by=8 WHERE id=140")
expect_block('10 L1 RESOLVED → PROCESSING（已解决不能退回）', "UPDATE exception_case SET status='PROCESSING' WHERE id=140", 'exc_state_forward_only')
expect_block('10 L1 RESOLVED 后改实点（借道重开改数被堵）', 'UPDATE exception_case SET counted_qty_milli=5000, diff_qty_milli=0 WHERE id=140', 'exc_immutable')
expect_block('10 L2 RESOLVED 后改处置结论', "UPDATE exception_case SET resolution='NO_ACTION', resolution_doc=NULL WHERE id=140", 'exc_immutable')
expect_block('10 L2 RESOLVED 后改责任方', "UPDATE exception_case SET liable_party='CARRIER' WHERE id=140", 'exc_immutable')
expect_allow('10 L2 RESOLVED 下首次写 closed_at', "UPDATE exception_case SET closed_at='2026-10-15 13:00:00' WHERE id=140")
expect_block('10 L2 closed_at 只能写一次', "UPDATE exception_case SET closed_at='2026-10-16 13:00:00' WHERE id=140", 'exc_immutable')
expect_block('10 L2 CLOSED 后改处置结论 / 清单号', "UPDATE exception_case SET resolution='NO_ACTION', resolution_doc=NULL WHERE id=100", 'exc_immutable')
expect_block('10 L2 CLOSED 后改责任方', "UPDATE exception_case SET liable_party='CARRIER' WHERE id=100", 'exc_immutable')
expect_block('10 L2 CLOSED 后改关闭人', 'UPDATE exception_case SET closed_by=99 WHERE id=100', 'exc_immutable')
expect_block('10 L2 CLOSED 后改仓库', 'UPDATE exception_case SET warehouse_id=2 WHERE id=100', 'exc_immutable')
expect_block('10 L2 CLOSED 后只改 version 也不行', 'UPDATE exception_case SET version=version+1 WHERE id=100', 'exc_immutable')
expect_block('10 L2 建单后改仓库（OPEN）', 'UPDATE exception_case SET warehouse_id=2 WHERE id=141', 'exc_immutable')
expect_block('10 L2 建单后改异常码', "UPDATE exception_case SET exception_code='FAILOVER_GAP' WHERE id=141", 'exc_immutable')
expect_block('10 L2 建单后改上报人', 'UPDATE exception_case SET reporter_id=99 WHERE id=141', 'exc_immutable')
expect_block('10 L2 建单后改单号', "UPDATE exception_case SET code='EXC-X' WHERE id=141", 'exc_immutable')
expect_block('10 L3 DELETE 已关闭异常单（去重键不能被释放）', 'DELETE FROM exception_case WHERE id=100', 'exc_no_delete')
expect_block('10 L3 DELETE 已取消异常单', 'DELETE FROM exception_case WHERE id=110', 'exc_no_delete')
expect_allow('10 质检单来源 SCRAP_MISREPORT（第 9 篇交接 / 质检误报回转）', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8010,'RTN-10',1,'RETURN','SCRAP_MISREPORT','APR-WHSH01-20261015-000001','CREATED','2026-10-15')")
expect_block('10 质检单来源拼错（SCRAP_MISREPORTX）', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8011,'RTN-11',1,'RETURN','SCRAP_MISREPORTX','APR-WHSH01-20261015-000002','CREATED','2026-10-15')", 'ck_inb_rtn_src')
expect_allow('10 异常单来源 SCRAP_MISREPORT', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (142,'EXC-142',1,'RETURN_COUNT_DIFF','SCRAP_MISREPORT','APR-WHSH01-20261015-000001','0000000000000000000000000000000000000000000000000000000000000084',1,1,0,0,0,'2026-10-15 12:00:00',7)")
expect_block('10 L3 SQLite INSERT OR REPLACE 把已关闭异常单重置为 OPEN', "INSERT OR REPLACE INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (100,'EXC-100',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000001',1,1,5000,5000,0,'2026-10-15 12:00:00',7)", 'exc_duplicate')
expect_block('10 L3 SQLite REPLACE 换 id 复用旧键 POD:1610:0', "REPLACE INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (199,'EXC-199',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000001',1,1,5000,5000,0,'2026-10-15 12:00:00',7)", 'exc_duplicate')
expect_block('10 L3 SQLite INSERT OR IGNORE 也不能静默吞掉（触发器 ABORT）', "INSERT OR IGNORE INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (100,'EXC-100',1,'RETURN_COUNT_DIFF','DELIVERY_RETURN','POD:1610:0','0000000000000000000000000000000000000000000000000000000000000001',1,1,5000,5000,0,'2026-10-15 12:00:00',7)", 'exc_duplicate')
_c = conn.execute("PRAGMA foreign_keys=OFF").fetchall()
expect_block('10 建议 2 SQLite 连接漏开 foreign_keys 仍拦未知异常码', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (198,'EXC-198',1,'NO_SUCH','MANUAL','M:198','00000000000000000000000000000000000000000000000000000000000000c6',1,1,0,0,0,'2026-10-15 12:00:00',7)", 'exc_code_unknown')
_c = conn.execute("PRAGMA foreign_keys=ON").fetchall()
expect_allow('10 STORE_RETURN 门店退货回仓 RTN', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8002,'RTN-2',1,'RETURN','STORE_RETURN','ST01:R-001','CREATED','2026-10-15')")
expect_block('10 STORE_RETURN 之外的未登记退货来源', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8003,'RTN-3',1,'RETURN','WHATEVER','X-1','CREATED','2026-10-15')", 'ck_inb_rtn_src')
expect_allow('10 非退货入库单不受退货来源 CHECK 约束', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8004,'PO-1',1,'PURCHASE','ERP_X','PO-001','CREATED','2026-10-15')")
expect_allow_tx('10 STORE_RETURN 入库后 RETURN_QC 系统冻结（source=QC/RTN 8002）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES (70,1,1,2,1953,'KG',2000,2000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (70,70,'RETURN_QC','RETURN_QC','QC',8002,'RQC:8201',2000,0,'HELD',0)"])
expect_block('10 STORE_RETURN 不走 RETURN_PENDING（挂质检来源被拦）', "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (71,70,'RETURN_PENDING','RETURN_PENDING','QC',8002,'X71',1000,0,'HELD',0)", 'ck_hold_return')
expect_block('10 STORE_RETURN 冻结不能是人工冻结（operator≠0）', "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (72,70,'RETURN_QC','RETURN_QC','QC',8002,'X72',1000,0,'HELD',7)", 'ck_hold_retqc')
expect_allow('10 STORE_RETURN 清点差异异常单（source_type=STORE_RETURN）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (130,'EXC-130',1,'RETURN_COUNT_DIFF','STORE_RETURN','RTN-2:1','000000000000000000000000000000000000000000000000000000000000001e',2,3,3000,2000,-1000,'2026-10-15 12:00:00',7)")

expect_allow('10 盲收 RTN 来源 STORE_BLIND', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8020,'RTN-20',1,'RETURN','STORE_BLIND','BRC-20261015-000001','CREATED','2026-10-15')")
expect_block('10 RTN 来源拼错 STORE_BLINDX', "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (8021,'RTN-21',1,'RETURN','STORE_BLINDX','BRC-20261015-000009','CREATED','2026-10-15')", 'ck_inb_rtn_src')
expect_allow('10 盲收异常单（BLIND_RETURN，截止 = 建单 + 48h）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (150,'EXC-150',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:1','0000000000000000000000000000000000000000000000000000000000000000',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-17 10:00:00','UNKNOWN')")
expect_block('10 盲收异常单缺截止时间', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00',NULL,'UNKNOWN')", 'ck_exc_blind')
expect_block('10 盲收异常单截止 ≠ +48h', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-16 10:00:00','UNKNOWN')", 'exc_blind_deadline')
expect_block('10 liable_party 取值非法（SUPPLIER 不在四值内）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id,created_at,link_deadline_at,liable_party) VALUES (151,'EXC-151',1,'RETURN_COUNT_DIFF','BLIND_RETURN','BRC:2','0000000000000000000000000000000000000000000000000000000000000001',1,0,0,3000,3000,'2026-10-17 10:00:00',7,'2026-10-15 10:00:00','2026-10-17 10:00:00','SUPPLIER')", 'ck_exc_liable')
_v = str(one('SELECT liable_party FROM exception_case WHERE id=100')[0])
ok('10 liable_party 默认 UNKNOWN' + ' = ' + _v) if _v == 'UNKNOWN' else bad('10 liable_party 默认 UNKNOWN' + ' = ' + _v)
expect_allow('10 liable_party 改为 STORE（处理中）', "UPDATE exception_case SET liable_party='STORE' WHERE id=150")
expect_allow('10 截止往后延（+24h，主管）', "UPDATE exception_case SET link_deadline_at='2026-10-18 10:00:00' WHERE id=150")
expect_block('10 截止往前改', "UPDATE exception_case SET link_deadline_at='2026-10-17 09:00:00' WHERE id=150", 'exc_deadline_backward')
expect_block('10 截止清空', 'UPDATE exception_case SET link_deadline_at=NULL WHERE id=150', 'exc_deadline_backward')
expect_allow('10 盲收记录（容器码 + 原因码 + 照片）', 'INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (1,\'BRC-20261015-000001\',1,1,3000,\'ST001\',\'CTN-001\',\'DAMAGED\',\'["F1","F2"]\',8020,150,\'IDEM-BLIND-1\',7)')
expect_block('10 盲收缺容器码', "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,'ST001','DAMAGED','[]',8020,150,'IDEM-BLIND-2',7)", 'NOT NULL constraint failed: return_blind_receipt.container_code')
expect_block('10 盲收缺原因码', "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,'ST001','CTN-002','[]',8020,150,'IDEM-BLIND-2',7)", 'NOT NULL constraint failed: return_blind_receipt.reason_code')
expect_block('10 盲收容器码空串', "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'','DAMAGED','[]',8020,150,'IDEM-BLIND-2',7)", 'ck_rbr_ctn')
expect_block('10 盲收原因码不在枚举', "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'CTN-002','BROKEN','[]',8020,150,'IDEM-BLIND-2',7)", 'ck_rbr_reason')
expect_block('10 盲收同 op_key 重放', "INSERT INTO return_blind_receipt (id,code,warehouse_id,sku_id,qty_milli,store_code,container_code,reason_code,photo_ids,rtn_inbound_id,exception_case_id,op_key,received_by) VALUES (2,'BRC-20261015-000002',1,1,3000,NULL,'CTN-002','DAMAGED','[]',8020,150,'IDEM-BLIND-1',7)", 'rbr_immutable')
expect_block('10 盲收记录不可改', 'UPDATE return_blind_receipt SET qty_milli=1000 WHERE id=1', 'rbr_immutable')
expect_block('10 盲收记录不可删', 'DELETE FROM return_blind_receipt WHERE id=1', 'rbr_immutable')
expect_allow('10 退货预约建单（门店 ST001）', "INSERT INTO return_reservation (id,code,warehouse_id,store_code,outbound_order_id,created_by) VALUES (1,'RSV-20261015-000001',1,'ST001',1,21)")
expect_allow('10 预约行（原因码 + 容器码）', "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (1,1,1,1,2000,'QUALITY','CTN-101')")
expect_block('10 预约行缺原因码', "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,container_code) VALUES (2,1,2,1,2000,'CTN-102')", 'NOT NULL constraint failed: return_reservation_line.reason_code')
expect_block('10 预约行缺容器码', "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code) VALUES (2,1,2,1,2000,'QUALITY')", 'NOT NULL constraint failed: return_reservation_line.container_code')
expect_block('10 预约行原因码非法', "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (2,1,2,1,2000,'NOPE','CTN-102')", 'ck_rrsl_reason')
expect_block('10 预约 RECEIVED 缺 RTN / 收货人', "UPDATE return_reservation SET status='RECEIVED' WHERE id=1", 'ck_rrsv_recv')
expect_allow('10 收货写实点', 'UPDATE return_reservation_line SET received_qty_milli=2000 WHERE id=1')
expect_block('10 实点只写一次', 'UPDATE return_reservation_line SET received_qty_milli=1000 WHERE id=1', 'rrsl_locked')
expect_block('10 预约门店不可改', "UPDATE return_reservation SET store_code='ST002' WHERE id=1", 'rrsv_immutable')
expect_allow('10 预约收货 CREATED → RECEIVED（RTN 8010，随后挂 RETURN_QC）', "UPDATE return_reservation SET status='RECEIVED', rtn_inbound_id=8010, received_by=7, received_at='2026-10-15 11:00:00', version=version+1 WHERE id=1 AND status='CREATED'")
expect_block('10 预约 RECEIVED → CANCELLED', "UPDATE return_reservation SET status='CANCELLED' WHERE id=1", 'rrsv_state_forward_only')
expect_block('10 预约终态整行只读', 'UPDATE return_reservation SET version=9 WHERE id=1', 'rrsv_immutable')
expect_block('10 收货后再加预约行', "INSERT INTO return_reservation_line (id,reservation_id,line_no,sku_id,qty_milli,reason_code,container_code) VALUES (3,1,3,1,1000,'QUALITY','CTN-103')", 'rrsl_locked')
expect_block('10 收货后改预约行', "UPDATE return_reservation_line SET container_code='X' WHERE id=1", 'rrsl_locked')
expect_block('10 预约不可删', 'DELETE FROM return_reservation_line WHERE id=1', 'return_no_delete')
expect_block('10 预约同号重复（SQLite 拦 REPLACE）', "INSERT INTO return_reservation (id,code,warehouse_id,store_code,outbound_order_id,created_by) VALUES (2,'RSV-20261015-000001',1,'ST001',1,21)", 'rrsv_duplicate')
_c = conn.execute("UPDATE return_reservation SET status='CANCELLED' WHERE id=1 AND status='CREATED'").rowcount; conn.commit()
ok('10 预约 version 条件更新（旧状态 CREATED）0 行' + ' rowcount=' + str(_c)) if _c == 0 else bad('10 预约 version 条件更新（旧状态 CREATED）0 行' + ' rowcount=' + str(_c))


print("=== 2e-exc1. docs/10 × 17：加工损耗未获批部分转异常（source_type=PROCESS_LOSS）===")
expect_allow('10 PROCESS_LOSS 准备：异常码 PROCESS_LOSS_UNSETTLED', "INSERT INTO exception_code (code,name,action,liability) VALUES ('PROCESS_LOSS_UNSETTLED','加工损耗未获批部分','ADJUST','WAREHOUSE')")
expect_allow('10 PROCESS_LOSS：17 损耗行 1757 审批驳回/过期，未批 0.400 转异常（key=PRCL:1757）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1900,'EXC-1900',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1757','0000000000000000000000000000000000000000000000000000000000000130',1,1,400,0,-400,'2026-10-15 12:00:00',0)")
def _pl_convert(i, key, h, ob, res):
    """SQLite 侧幂等转异常：BEGIN IMMEDIATE 串行；NOT EXISTS 条件插入，changes()=1 才写 loss_settled；返回 exception_no。"""
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(f"INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) SELECT {i},'EXC-{i}',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','{key}','0000000000000000000000000000000000000000000000000000000000000{h}',1,1,400,0,-400,'2026-10-15 12:00:00',0 WHERE NOT EXISTS (SELECT 1 FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='{key}')")
    if conn.execute("SELECT changes()").fetchone()[0] == 1:
        conn.execute(f"INSERT INTO outbox_event (id,topic,biz_key,payload) VALUES ({ob},'wms.process.loss_settled','PRC-SH01-20261015-000017','{{\"result\":\"{res}\"}}')")
    code = conn.execute(f"SELECT code FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='{key}'").fetchone()[0]
    conn.execute("COMMIT"); return code
_c = _pl_convert(1911, 'PRCL:1757', '911', 9911, 'REJECTED')
ok('10 PROCESS_LOSS 同一损耗行再次转异常（回调重放）→ 不报错，返回已有 exception_no ' + _c) if _c == 'EXC-1900' else bad('10 PROCESS_LOSS 重放幂等返回：' + str(_c))
_a = _pl_convert(1921, 'PRCL:1758', '921', 9921, 'REJECTED')               # 审批驳回回调
_b = _pl_convert(1922, 'PRCL:1758', '922', 9922, 'EXPIRED_TO_EXCEPTION')   # 12h 过期任务（SQLite 单写者，顺序模拟）
_r = one("SELECT (SELECT count(*) FROM exception_case WHERE source_type='PROCESS_LOSS' AND source_key='PRCL:1758') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9911,9921,9922))")[0]
ok(f'10×17 审批回调与过期任务处理同一损耗行（顺序模拟，索引兜底）：异常单 1 张、两方都返回 {_a}、loss_settled 1 条') if (_a == _b == 'EXC-1921' and _r == '1/1') else bad(f'10×17 转异常：A={_a} B={_b} 异常单/事件={_r}（期望 EXC-1921 ×2、1/1）')
expect_block('10 PROCESS_LOSS source_key 不是 PRCL:{损耗行 id}', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1902,'EXC-1902',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','POD:1757:0','0000000000000000000000000000000000000000000000000000000000000132',1,1,400,0,-400,'2026-10-15 12:00:00',0)", 'ck_exc_pl_key')
expect_block('10 PROCESS_LOSS 缺 SKU', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1903,'EXC-1903',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:1759','0000000000000000000000000000000000000000000000000000000000000133',0,1,400,0,-400,'2026-10-15 12:00:00',0)", 'ck_exc_pl_key')
expect_block('10 PROCESS_LOSS 键带前导零 PRCL:01757', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1905,'EXC-1905',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:01757','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0)", 'ck_exc_pl_key')
expect_block('10 PROCESS_LOSS 键为 0（PRCL:0）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1906,'EXC-1906',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:0','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0)", 'ck_exc_pl_key')
expect_block('10 PROCESS_LOSS 键非纯数字 PRCL:17a', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1907,'EXC-1907',1,'PROCESS_LOSS_UNSETTLED','PROCESS_LOSS','PRCL:17a','0000000000000000000000000000000000000000000000000000000000000133',1,1,400,0,-400,'2026-10-15 12:00:00',0)", 'ck_exc_pl_key')

print("=== 2e-exc2. docs/10 × 18：活鲜死亡延迟扣减转异常（source_type=LIVE_DEATH，LDTH:{live_death.id}）===")
expect_allow("10 LIVE_DEATH 准备：异常码 LIVE_DEATH_UNDEDUCTED", "INSERT INTO exception_code (code,name,action,liability) VALUES ('LIVE_DEATH_UNDEDUCTED','活鲜死亡延迟扣减失败','ADJUST','WAREHOUSE')")
def _lvd(i, key, h):
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(f"INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) SELECT {i},'EXC-{i}',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','{key}','0000000000000000000000000000000000000000000000000000000000000{h}',1,1,1000,0,-1000,'2026-10-15 12:00:00',0 WHERE NOT EXISTS (SELECT 1 FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='{key}')")
    code = conn.execute(f"SELECT code FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='{key}'").fetchone()[0]
    conn.execute("COMMIT"); return code
_c = _lvd(1931, 'LDTH:1801', '931')
ok('10 LIVE_DEATH：18 延迟扣减任务 deduct_status=EXCEPTION 转异常（LDTH:1801）→ ' + _c) if _c == 'EXC-1931' else bad('10 LIVE_DEATH 建单：' + str(_c))
_c = _lvd(1932, 'LDTH:1801', '932')
ok('10 LIVE_DEATH 重放同一死亡登记 → 不报错，返回已有 ' + _c) if _c == 'EXC-1931' else bad('10 LIVE_DEATH 重放：' + str(_c))
_r = one("SELECT count(*) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:1801'")[0]
ok('10 LIVE_DEATH 重放后异常单仍 1 张') if _r == 1 else bad(f'10 LIVE_DEATH 异常单数 {_r}')
_ix = {n: (s or '').replace(' ', '').lower() for n, s in conn.execute("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='exception_case' AND name IN ('uq_exc_ldth_key','uq_exc_pl_key')")}
_okix = all(n in _ix and 'createuniqueindex' in _ix[n] and '(source_key)where' in _ix[n] and v in _ix[n] for n, v in (('uq_exc_ldth_key', "source_type='live_death'"), ('uq_exc_pl_key', "source_type='process_loss'")))
ok('10 ON CONFLICT 仲裁索引按名存在：uq_exc_ldth_key / uq_exc_pl_key 为 source_key 单列部分唯一') if _okix else bad(f'10 uq_exc_ldth_key/uq_exc_pl_key 定义不符：{_ix}')
expect_block('10 LIVE_DEATH source_key 不是 LDTH:{live_death.id}', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1933,'EXC-1933',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','PRCL:1801','0000000000000000000000000000000000000000000000000000000000000933',1,1,1000,0,-1000,'2026-10-15 12:00:00',0)", 'ck_exc_ldth_key')
expect_block('10 LIVE_DEATH 缺 SKU', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1934,'EXC-1934',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:1802','0000000000000000000000000000000000000000000000000000000000000934',0,1,1000,0,-1000,'2026-10-15 12:00:00',0)", 'ck_exc_ldth_key')
expect_block('10 LIVE_DEATH 键为 0（LDTH:0）', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1935,'EXC-1935',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:0','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0)", 'ck_exc_ldth_key')
expect_block('10 LIVE_DEATH 键带前导零 LDTH:007', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1936,'EXC-1936',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:007','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0)", 'ck_exc_ldth_key')
expect_block('10 LIVE_DEATH 旧前缀 LVD:1801', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (1937,'EXC-1937',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LVD:1801','0000000000000000000000000000000000000000000000000000000000000934',1,1,1000,0,-1000,'2026-10-15 12:00:00',0)", 'ck_exc_ldth_key')

print("=== 2f. docs/09 效期与损耗：报损单状态前进、交接单不可撤回、来源/原因 CHECK、外键 ===")
expect_allow('09 报损单建单（DRAFT，来源=效期扫描 501）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (100,'SCR-1',1,'EXPIRY_SCAN',501,'EXPIRED','2026-10-15',7)")
expect_block('09 同一来源重复建有效报损单', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (101,'SCR-2',1,'EXPIRY_SCAN',501,'EXPIRED','2026-10-15',7)", 'scrap_order.source_type, scrap_order.source_id, scrap_order.source_date')
expect_block('09 I3 来源类型非法', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (109,'SCR-9',1,'WHATEVER',9,'EXPIRED','2026-10-15',7)", 'ck_scr_src_type')
expect_block('09 I3 原因码非法', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (109,'SCR-9',1,'MANUAL',9,'ANY','2026-10-15',7)", 'ck_scr_reason')
expect_block('09 报损单非法状态值（建单）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (109,'SCR-9',1,'MANUAL',9,'OTHER','2026-10-15',7,'DONE')", 'ck_scr_status')
expect_allow('09 DRAFT 单下加报损行', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (100,100,1,14,1,1,5000,0,'POST_OUT')")
expect_block('09 报损行数量 0', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (101,100,2,14,1,1,0,0,'POST_OUT')", 'ck_scrl_qty')
expect_block('09 报损行数量非整数 milli（SQLite REAL）', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (102,100,3,14,1,1,1.5,0,'POST_OUT')", 'ck_scrl_int')
expect_block('09 I3 报损行挂到不存在的报损单（外键）', 'UPDATE scrap_line SET scrap_id=999 WHERE id=100', 'FOREIGN KEY constraint failed')
expect_block('09 I3 新增报损行挂到不存在的报损单', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (103,999,1,14,1,1,1000,0,'POST_OUT')", 'scrap_line_locked')
expect_allow('09 S1 DRAFT → PENDING_APPROVAL', "UPDATE scrap_order SET status='PENDING_APPROVAL', version=version+1 WHERE id=100 AND status='DRAFT'")
expect_block('09 I3 提交后不能再加行', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (104,100,2,14,1,1,1000,0,'POST_OUT')", 'scrap_line_locked')
expect_block('09 I3 提交后不能改量', 'UPDATE scrap_line SET scrap_qty_milli=4000 WHERE id=100', 'scrap_line_locked')
expect_block('09 报损审批 SoD（审批人=申请人）', "UPDATE scrap_order SET approver_id=7, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=100", 'ck_scr_sod')
expect_allow('09 S2 审批（审批人 8）', "UPDATE scrap_order SET approver_id=8, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=100 AND status='PENDING_APPROVAL'")
expect_block('09 I3 APPROVED → DRAFT（跳回）', "UPDATE scrap_order SET status='DRAFT' WHERE id=100", 'scrap_state_forward_only')
expect_allow('09 S3 APPROVED → POSTED', "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:01:00' WHERE id=100 AND status='APPROVED'")
expect_block('09 I3 POSTED → DRAFT', "UPDATE scrap_order SET status='DRAFT' WHERE id=100", 'scrap_state_forward_only')
expect_block('09 I3 POSTED → CANCELLED', "UPDATE scrap_order SET status='CANCELLED' WHERE id=100", 'scrap_state_forward_only')
expect_block('09 I3 POSTED 单下插 POST_OUT 且 hold_id=0 的行', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (105,100,9,14,1,1,1000,0,'POST_OUT')", 'scrap_line_locked')
expect_block('09 报损单非法状态值（更新）', "UPDATE scrap_order SET status='DONE' WHERE id=100", 'scrap_state_forward_only')
expect_allow('09 交接报损单 DRAFT（RETURN_HANDOVER，source_id=待回库 701）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (102,'SCR-3',1,'RETURN_HANDOVER',701,'DAMAGED','2026-10-15',8)")
expect_block('09 同一待回库记录重复交接报损', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (103,'SCR-4',1,'RETURN_HANDOVER',701,'DAMAGED','2026-10-15',8)", 'scrap_order.source_type, scrap_order.source_id, scrap_order.source_date')
expect_block('09 交接单不许取消（DRAFT → CANCELLED）', "UPDATE scrap_order SET status='CANCELLED' WHERE id=102", 'scrap_handover_no_revoke')
expect_allow('09 交接单提交', "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=102 AND status='DRAFT'")
expect_block('09 交接单不许撤回（PENDING_APPROVAL → DRAFT，→ 40930）', "UPDATE scrap_order SET status='DRAFT' WHERE id=102", 'scrap_handover_no_revoke')
expect_block('09 交接单不许驳回到 REJECTED', "UPDATE scrap_order SET status='REJECTED' WHERE id=102", 'scrap_handover_no_revoke')
expect_block('09 来源不可改（交接单改成 MANUAL 绕过）', "UPDATE scrap_order SET source_type='MANUAL' WHERE id=102", 'scrap_state_forward_only')
expect_allow_tx('09 准备：交接单 102 / 手工单 104 各挂一条 SCRAP_PENDING', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (80,1,1,2,4,'KG',4000,4000)", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (104,'SCR-5',1,'MANUAL',0,'DAMAGED','2026-10-15',7)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (80,80,'SCRAP_PENDING','SCRAP','SCRAP',102,'CVT:79',2000,0,'HELD',0)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (81,80,'SCRAP_PENDING','SCRAP','SCRAP',104,'SCRH:81',2000,0,'HELD',0)"])
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 102 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 102 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))").rowcount; conn.commit()
ok('09 release_scrap_hold(REVOKED) 对交接单拒绝（→ 40930）' + ' rowcount=' + str(_c)) if _c == 0 else bad('09 release_scrap_hold(REVOKED) 对交接单拒绝（→ 40930）' + ' rowcount=' + str(_c) + '，期望 0')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 81 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 104 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 104 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))").rowcount; conn.commit()
ok('09 release_scrap_hold(REVOKED) 对手工单放行' + ' rowcount=' + str(_c)) if _c == 1 else bad('09 release_scrap_hold(REVOKED) 对手工单放行' + ' rowcount=' + str(_c) + '，期望 1')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount; conn.commit()
ok('09 人工解冻路径对 SCRAP_PENDING（→ 40933）' + ' rowcount=' + str(_c)) if _c == 0 else bad('09 人工解冻路径对 SCRAP_PENDING（→ 40933）' + ' rowcount=' + str(_c) + '，期望 0')
expect_allow('09 A1 质检不合格报损单 DRAFT（RETURN_QC，source_id=退货行 8101）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (105,'SCR-6',1,'RETURN_QC',8101,'QC_REJECT','2026-10-15',9)")

expect_block('09 Q8 交接单作废必须带 SCRAP_MISREPORT 审批单号', "UPDATE scrap_order SET status='VOIDED' WHERE id=102", 'ck_scr_void')
expect_block('09 Q8 非交接单不能作废（手工单 104）', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000009' WHERE id=104", 'scrap_state_forward_only')
expect_block_tx('09 Q8 误报回转缺审批（ck_hold_approval）', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,is_reversal) VALUES (82,80,'RETURN_QC','RETURN_QC','QC',8301,'CVT:80',2000,0,'HELD',0,true)", 'UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, quality_hold_qty_milli = quality_hold_qty_milli + 2000, version = version + 1 WHERE id = 80 AND hold_qty_milli >= 2000', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000001', version=version+1 WHERE id=102 AND status='PENDING_APPROVAL'"], 'ck_hold_approval')
expect_block('09 Q17 审批单号格式不对（APR-1）', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-1' WHERE id=102", 'ck_scr_apr_fmt')
expect_block('09 Q17 审批单号序号不足 6 位', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-12345' WHERE id=102", 'ck_scr_apr_fmt')
expect_block('09 Q17 审批单号仓库编码含小写', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-whsh01-20261015-000001' WHERE id=102", 'ck_scr_apr_fmt')
expect_block('09 Q17 审批单号日期不足 8 位', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-2026101-000001' WHERE id=102", 'ck_scr_apr_fmt')
expect_block('09 Q17 审批单号仓库编码只有 1 位', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-S-20261015-000001' WHERE id=102", 'ck_scr_apr_fmt')
expect_block('09 Q17 审批单号仓库编码超过 16 位', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-ABCDEFGHIJKLMNOPQ-20261015-000001' WHERE id=102", 'ck_scr_apr_fmt')
expect_allow_tx('09 Q8 误报同一事务：convert_hold SCRAP_PENDING→RETURN_QC（CVT:80，审批 APR-1，新质检单 8301）+ 报损单 VOIDED', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 80 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (82,80,'RETURN_QC','RETURN_QC','QC',8301,'CVT:80',2000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000001',true)", 'UPDATE stock SET hold_qty_milli = hold_qty_milli - 2000, quality_hold_qty_milli = quality_hold_qty_milli + 2000, version = version + 1 WHERE id = 80 AND hold_qty_milli >= 2000', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000001', version=version+1 WHERE id=102 AND status='PENDING_APPROVAL'"])
_v = str(one("SELECT hold_qty_milli||'/'||quality_hold_qty_milli FROM stock WHERE id=80")[0])
ok('09 Q8 回转后 stock 80 hold/quality（跨列挪量，可用量不变）' + ' = ' + _v) if _v == '2000/2000' else bad('09 Q8 回转后 stock 80 hold/quality（跨列挪量，可用量不变）' + ' = ' + _v)
expect_block('09 K1 质检不合格单不许取消（DRAFT → CANCELLED，→ 40930）', "UPDATE scrap_order SET status='CANCELLED' WHERE id=105", 'scrap_handover_no_revoke')
expect_allow_tx('09 K1/K4 准备：质检单 105 挂 SCRAP_PENDING 3000，行数量 = 冻结量', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (81,1,1,2,5,'KG',3000,3000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (83,81,'SCRAP_PENDING','SCRAP','SCRAP',105,'CVT:84',3000,0,'HELD',0)", "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (110,105,1,81,2,5,3000,83,'POST_OUT')"])
expect_block('09 K4 带冻结的行数量 ≠ 冻结余量（建行）', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (111,105,2,81,2,5,1000,83,'POST_OUT')", 'scrap_line_hold_mismatch')
expect_block('09 K4 交接 / 质检 DRAFT 改数量（5000→1 式）', 'UPDATE scrap_line SET scrap_qty_milli=1 WHERE id=110', 'scrap_line_hold_locked')
expect_block('09 K4 交接 / 质检 DRAFT 摘掉冻结（hold_id → 0）', 'UPDATE scrap_line SET hold_id=0 WHERE id=110', 'scrap_line_hold_locked')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 83 AND hold_type = 'SCRAP_PENDING' AND source_type = 'SCRAP' AND source_id = 105 AND status = 'HELD' AND EXISTS (SELECT 1 FROM scrap_order o WHERE o.id = 105 AND o.source_type NOT IN ('RETURN_HANDOVER','RETURN_QC'))").rowcount; conn.commit()
ok('09 K1 release_scrap_hold(REVOKED) 对质检单拒绝（→ 40930）' + ' rowcount=' + str(_c)) if _c == 0 else bad('09 K1 release_scrap_hold(REVOKED) 对质检单拒绝（→ 40930）' + ' rowcount=' + str(_c))
expect_allow('09 K1 质检单提交', "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=105 AND status='DRAFT'")
expect_block('09 K1 质检单不许撤回（→ DRAFT）', "UPDATE scrap_order SET status='DRAFT' WHERE id=105", 'scrap_handover_no_revoke')
expect_block('09 K1 质检单不许驳回（→ REJECTED）', "UPDATE scrap_order SET status='REJECTED' WHERE id=105", 'scrap_handover_no_revoke')
expect_allow('09 K1 质检判错只走 SCRAP_MISREPORT 作废（VOIDED，合法审批号）', "UPDATE scrap_order SET status='VOIDED', void_approval_no='APR-WHSH01-20261015-000002' WHERE id=105 AND status='PENDING_APPROVAL'")
expect_block('09 K3 POSTED 单的行改 hold_id / ledger_mode', "UPDATE scrap_line SET hold_id=0, ledger_mode='NONE' WHERE id=100", 'scrap_line_locked')
expect_block('09 K3 POSTED 单的行改成本', 'UPDATE scrap_line SET cost_amount=1 WHERE id=100', 'scrap_line_locked')
expect_block('09 K3 事后换申请人', 'UPDATE scrap_order SET applicant_id=12 WHERE id=100', 'scrap_immutable')
expect_block('09 K3 事后换审批人', 'UPDATE scrap_order SET approver_id=13 WHERE id=100', 'scrap_immutable')
expect_block('09 K3 过账时间改写', "UPDATE scrap_order SET posted_at='2026-10-16 00:00:00' WHERE id=100", 'scrap_immutable')
expect_block('09 K3 终态改原因码', "UPDATE scrap_order SET reason_code='OTHER' WHERE id=100", 'scrap_immutable')
expect_block('09 K3 改仓库', 'UPDATE scrap_order SET warehouse_id=2 WHERE id=104', 'scrap_immutable')
expect_block('09 S1 建单直接写 CANCELLED', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (120,'SCR-20',1,'RETURN_HANDOVER',720,'DAMAGED','2026-10-15',8,'CANCELLED')", 'scrap_insert_draft_only')
expect_block('09 S1 建单直接写 POSTED', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (121,'SCR-21',1,'MANUAL',0,'DAMAGED','2026-10-15',8,'POSTED')", 'scrap_insert_draft_only')
expect_allow('09 S1 手工单 104 提交', "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=104 AND status='DRAFT'")
expect_block('09 S1 审批缺 approved_at', "UPDATE scrap_order SET approver_id=8, status='APPROVED' WHERE id=104", 'ck_scr_appr')
expect_block('09 K2 DELETE 报损单', 'DELETE FROM scrap_order WHERE id=102', 'scrap_no_delete')
expect_block('09 K2 DELETE POSTED 单的行', 'DELETE FROM scrap_line WHERE id=100', 'scrap_no_delete')
expect_block('09 K2 SQLite INSERT OR REPLACE 换掉交接单（改 MANUAL + CANCELLED）', "INSERT OR REPLACE INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id,status) VALUES (102,'SCR-3',1,'MANUAL',0,'DAMAGED','2026-10-15',8,'DRAFT')", 'scrap_duplicate')
expect_block('09 K2 SQLite INSERT OR REPLACE 报损行', "INSERT OR REPLACE INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (100,100,1,14,1,1,1,0,'NONE')", 'scrap_line_locked')
expect_block('09 K2 SQLite REPLACE INTO 报损单', "REPLACE INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (100,'SCR-1',1,'MANUAL',0,'OTHER','2026-10-15',7)", 'scrap_duplicate')
expect_allow('09 sell_days 到期自动报损单（SELL_EXPIRED，批次 lot_id=601，系统建草稿）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (130,'SCR-30',1,'SELL_EXPIRED',601,'2026-10-15','SELL_EXPIRED','2026-10-15',0)")
expect_block('09 sell_days 同一批次同一天重复建单', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_EXPIRED',601,'2026-10-15','SELL_EXPIRED','2026-10-15',0)", 'scrap_order.source_type, scrap_order.source_id, scrap_order.source_date')
expect_allow('09 sell_days 同一批次次日余量（退货回仓后）再建一张', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (132,'SCR-32',1,'SELL_EXPIRED',601,'2026-10-16','SELL_EXPIRED','2026-10-16',0)")
expect_allow('09 sell_days 来源与 EXPIRY_SCAN 同 source_id 互不干扰', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (133,'SCR-33',1,'EXPIRY_SCAN',601,'EXPIRED','2026-10-15',0)")
expect_block('09 sell_days 来源拼错', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_DAY_EXPIRED',602,'SELL_EXPIRED','2026-10-15',0)", 'ck_scr_src_type')
expect_block('09 sell_days 原因码拼错', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (131,'SCR-31',1,'SELL_EXPIRED',602,'2026-10-15','SELL_DAYS','2026-10-15',0)", 'ck_scr_reason')
expect_block('09 D3 SELL_EXPIRED 缺 source_date（默认 1970-01-01）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'SELL_EXPIRED',603,'SELL_EXPIRED','2026-10-15',0)", 'ck_scr_src_date')
expect_block('09 D3 SELL_EXPIRED source_date ≠ work_date', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'SELL_EXPIRED',603,'2026-10-14','SELL_EXPIRED','2026-10-15',0)", 'ck_scr_src_date')
expect_block('09 D3 非按日来源写了日期（EXPIRY_SCAN）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (134,'SCR-34',1,'EXPIRY_SCAN',603,'2026-10-15','EXPIRED','2026-10-15',7)", 'ck_scr_src_date')
expect_block('09 D3 建单后改 source_date', "UPDATE scrap_order SET source_date='2026-10-17', work_date='2026-10-17' WHERE id=132", 'scrap_state_forward_only')
expect_allow('09 D3 LIVE_SHRINK 批次 605 第一天', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (140,'SCR-40',1,'LIVE_SHRINK',605,'2026-10-15','NATURAL_LOSS','2026-10-15',0)")
expect_allow('09 D3 LIVE_SHRINK 同批次次日再建', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (141,'SCR-41',1,'LIVE_SHRINK',605,'2026-10-16','NATURAL_LOSS','2026-10-16',0)")
expect_block('09 D3 LIVE_SHRINK 同批次同日重复', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (142,'SCR-42',1,'LIVE_SHRINK',605,'2026-10-15','NATURAL_LOSS','2026-10-15',0)", 'scrap_order.source_type, scrap_order.source_id, scrap_order.source_date')
expect_block('09 D3 LIVE_SHRINK 缺 source_date', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (143,'SCR-43',1,'LIVE_SHRINK',606,'1970-01-01','NATURAL_LOSS','2026-10-15',0)", 'ck_scr_src_date')
expect_block('09 D3 LIVE_DEATH 写了日期（不按日）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (144,'SCR-44',1,'LIVE_DEATH',607,'2026-10-15','OTHER','2026-10-15',0)", 'ck_scr_src_date')
expect_allow('09 sell_days 系统提交（DRAFT → PENDING_APPROVAL，S1 同事务冻结 SCRAP_PENDING 即下架）', "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=130 AND status='DRAFT'")
expect_block('09 sell_days 系统单也要人审（审批人 = 申请人 0）', "UPDATE scrap_order SET approver_id=0, approved_at='2026-10-15 10:00:00', status='APPROVED' WHERE id=130", 'ck_scr_sod')
expect_block('09 Q8 VOIDED 是终态（→ POSTED）', "UPDATE scrap_order SET status='POSTED' WHERE id=102", 'scrap_state_forward_only')
_c = conn.execute("UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 82 AND status = 'HELD' AND hold_type IN ('QUALITY','MANUAL')").rowcount; conn.commit()
ok('09 Q8 回转后的 RETURN_QC 不能人工解冻（→ 40933，只能 release_qc_hold）' + ' rowcount=' + str(_c)) if _c == 0 else bad('09 Q8 回转后的 RETURN_QC 不能人工解冻（→ 40933，只能 release_qc_hold）' + ' rowcount=' + str(_c))

print("=== 2f2. docs/09 记账型来源 PROCESS_LOSS / LIVE_*（Doro P1）、加工原因码、PROCESS_LOSS 作废 ===")
_r = one("SELECT CASE WHEN sql LIKE '%ck_scr_src_type%PROCESS_LOSS%' THEN 'Y' ELSE 'N' END FROM sqlite_master WHERE type='table' AND name='scrap_order'")[0]
ok("09 ck_scr_src_type 含 PROCESS_LOSS（SQLite，对齐 00 §6.4 1d907031 登记）") if _r == 'Y' else bad(f"09 ck_scr_src_type 缺 PROCESS_LOSS：{_r}")
expect_allow('09 PROCESS_LOSS 报损单（17 损耗行 1752，TRIM，记账型）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (150,'SCR-50',1,'PROCESS_LOSS',1752,'TRIM','2026-10-15',21)")
r = one("SELECT CASE WHEN record_only THEN 'Y' ELSE 'N' END FROM scrap_order WHERE id=150")[0]
ok(f"09 PROCESS_LOSS 自动推出 record_only = {r}") if str(r) == 'Y' else bad(f"09 PROCESS_LOSS 自动推出 record_only = {r}")
try:
    conn.execute('UPDATE scrap_order SET record_only=false WHERE id=150'); conn.commit(); bad('09 record_only 不能由应用写入（生成列）' + " → 未拦截")
except sqlite3.Error as e:
    conn.rollback(); ok('09 record_only 不能由应用写入（生成列）' + f" → 已拦截（{e}）") if "generated column" in str(e) else bad('09 record_only 不能由应用写入（生成列）' + f" → {e}")
expect_block('09 PROCESS_LOSS 用通用原因码 NATURAL_LOSS', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'PROCESS_LOSS',1753,'NATURAL_LOSS','2026-10-15',21)", 'ck_scr_reason_src')
expect_block('09 手工报损用加工原因 TRIM', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'MANUAL',0,'TRIM','2026-10-15',21)", 'ck_scr_reason_src')
expect_block('09 PROCESS_LOSS 写了 source_date', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,source_date,reason_code,work_date,applicant_id) VALUES (151,'SCR-51',1,'PROCESS_LOSS',1753,'2026-10-15','TRIM','2026-10-15',21)", 'ck_scr_src_date')
expect_block('09 记账型单的行挂冻结（会扣第二次）', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (150,150,1,11,1,1,2700,0,'POST_OUT')", 'scrap_line_record_only')
expect_allow('09 记账型行：hold_id=0、ledger_mode=NONE', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (150,150,1,11,1,1,2700,0,'NONE')")
expect_block('09 记账型行改成出账', "UPDATE scrap_line SET ledger_mode='POST_OUT' WHERE id=150", 'scrap_line_record_only')
expect_block('09 普通单（手工）不能 DRAFT 直接 POSTED', "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=104", 'scrap_state_forward_only')
expect_allow('09 PROCESS_LOSS 容差内 DRAFT → POSTED（无人审、不出账）', "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=150 AND status='DRAFT'")
expect_block('09 PROCESS_LOSS 作废缺 void_ref', "UPDATE scrap_order SET status='VOIDED' WHERE id=150", 'ck_scr_void')
expect_block('09 void_ref 不是 17 冲回键', "UPDATE scrap_order SET status='VOIDED', void_ref='X:1' WHERE id=150", 'ck_scr_void_ref')
expect_allow('09 17 损耗改原因：POSTED → VOIDED（void_ref = PRCR 冲回键）', "UPDATE scrap_order SET status='VOIDED', void_ref='PRCR:1711:00000000-0000-4000-8000-000000001794' WHERE id=150 AND status='POSTED'")
expect_block('09 VOIDED 后不能再 POSTED', "UPDATE scrap_order SET status='POSTED' WHERE id=150", 'scrap_state_forward_only')
expect_allow('09 PROCESS_LOSS 超容差：DRAFT → PENDING_APPROVAL（随 17 PROCESS_YIELD_DEVIATION 合并审批）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (152,'SCR-52',1,'PROCESS_LOSS',1758,'DEFECT','2026-10-15',21)")
expect_allow('09 超容差单提交', "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=152 AND status='DRAFT'")
expect_block('09 待审批的记账型单不能跳过审批直接 POSTED', "UPDATE scrap_order SET status='POSTED', posted_at='2026-10-15 10:00:00' WHERE id=152", 'scrap_state_forward_only')
expect_allow('09 LIVE_DEATH 报损单（18 consume_live_hold 已扣，记账型）', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (153,'SCR-53',1,'LIVE_DEATH',1801,'LIVE_DEATH','2026-10-15',21)")
expect_block('09 LIVE_DEATH 行挂冻结（双扣）', "INSERT INTO scrap_line (id,scrap_id,line_no,stock_id,sku_id,lot_id,scrap_qty_milli,hold_id,ledger_mode) VALUES (153,153,1,11,1,1,800,0,'POST_OUT')", 'scrap_line_record_only')
expect_block('09 LIVE_DEATH 原因码用在效期扫描单', "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (154,'SCR-54',1,'EXPIRY_SCAN',1999,'LIVE_DEATH','2026-10-15',21)", 'ck_scr_reason_src')

print("=== 2h. docs/17 加工中心（#13 改稿，基于 #2 1d907031）：02 原语、守恒 C1–C5、外键、状态白名单、REPLACE 防护 ===")
def b17(desc, sql, want):
    """第 17 篇专用：SQLite 的外键/触发器报错不带 "xxx: " 前缀，按全等或后缀匹配。"""
    try:
        conn.execute(sql); conn.commit(); bad(f"{desc} → 未拦截（SQLite 侧有洞）")
    except sqlite3.IntegrityError as e:
        conn.rollback(); msg = str(e)
        ok(f"{desc} → 已拦截（{msg}）") if (msg == want or msg.endswith(": " + want)) else bad(f"{desc} → 被拦了但约束不对：期望 {want!r}，实际 {msg!r}")
expect_allow_tx('17 种子：SKU 原料三文鱼/鱼柳/鱼骨/按件鸡腿、库位、批次', ["INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (1701,'SKU-SALMON','三文鱼整鱼','KG','CHILLED',6,1),(1702,'SKU-FILLET','三文鱼柳','KG','CHILLED',3,1),(1703,'SKU-BONE','三文鱼骨','KG','CHILLED',2,0),(1704,'SKU-LEG','鸡腿（定量装）','EA','CHILLED',5,1)", "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1790,1,2,'PC-01','FLOOR',99,'P010'),(1791,1,2,'C-01-01','PALLET',8,'C010'),(1792,1,1,'A09-01-01','BIN',8,'A090')", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1701,1701,'L-RAW1','2026-10-20','2026-10-14'),(1760,1702,'L-FIL1','2026-10-18','2026-10-15'),(1761,1703,'L-BON1','2026-10-17','2026-10-15'),(1762,1702,'L-FIL2','2026-10-18','2026-10-15'),(1763,1702,'L-FIL3','2026-10-18','2026-10-15'),(1764,1704,'L-LEG1','2026-10-19','2026-10-14'),(1765,1703,'L-BON2','2026-10-17','2026-10-15')"])
expect_allow_tx('17 种子：库存行 + 期初（原料 20 KG、鸡腿 10 件）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1781,1,1791,1701,1701,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1782,1,1790,1701,1701,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1783,1,1792,1702,1760,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1784,1,1792,1703,1761,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1785,1,1792,1702,1762,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1786,1,1792,1702,1763,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1787,1,1790,1704,1764,'KG',0)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1788,1,1792,1703,1765,'KG',0)", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-1781',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=20000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1781 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17001,'OPEN-1781',1,1,1,'DOC','OPENING',1,1781,1,1,1791,1701,1701,20000,0,20000,'2026-10-15','OPEN-1781:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17001,'OPEN-1781:1:D1:1','OPEN-1781',1,1,1,'DOC',1781,1,1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('OPEN-1787',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1787 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17002,'OPEN-1787',1,1,1,'DOC','OPENING',1,1787,1,1,1790,1704,1764,10000,0,10000,'2026-10-15','OPEN-1787:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17002,'OPEN-1787:1:D1:1','OPEN-1787',1,1,1,'DOC',1787,1,1,'2026-10-15')"])
expect_allow_tx('17 BOM 草稿（出成率 45%–55%，损耗上限 30%，称重容差 0.5%）', ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,loss_max_bp,balance_tol_bp,created_by) VALUES (1701,1,'BOM-SALMON',1,'三文鱼分切',4500,5500,3000,50,8)"])
b17('17 BOM 损耗上限 > 100%', "INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,loss_max_bp,created_by) VALUES (1709,1,'BOM-X',1,'x',4000,5000,10001,8)", 'ck_pbom_loss')
b17('17 BOM 行 SKU 不存在（外键）', "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17019,1701,9,'INPUT',999999,1000)", 'FOREIGN KEY constraint failed')
b17('17 BOM 行挂不存在的 BOM（外键）', "INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17019,999,1,'INPUT',1701,1000)", 'FOREIGN KEY constraint failed')
expect_allow_tx('17 BOM 行：原料 / 成品 / 副产品', ["INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (17011,1701,1,'INPUT',1701,10000),(17012,1701,2,'FINISHED',1702,5000),(17013,1701,3,'BYPRODUCT',1703,2000)"])
expect_allow_tx('17 BOM 生效', ["UPDATE process_bom SET status='ACTIVE', activated_at='2026-10-15 01:00:00' WHERE id=1701"])
b17('17 BOM ACTIVE → DRAFT 回退（绕 bom_frozen）', "UPDATE process_bom SET status='DRAFT' WHERE id=1701", 'bom_forward_only')
b17('17 BOM ACTIVE 时改出成率', 'UPDATE process_bom SET yield_min_bp=1000 WHERE id=1701', 'bom_forward_only')
b17('17 BOM 生效后不能改行', 'UPDATE process_bom_line SET std_qty_milli=1 WHERE id=17012', 'bom_frozen')
expect_allow_tx('17 BOM v2 草稿 → 生效 → 退役', ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1702,1,'BOM-SALMON',2,'v2',4500,5500,8)"])
b17('17 BOM RETIRED/DRAFT 不能直接跳 RETIRED（DRAFT → RETIRED）', "UPDATE process_bom SET status='RETIRED', activated_at='2026-10-15 02:00:00' WHERE id=1702", 'bom_forward_only')
b17('17 加工单直接以 IN_PROGRESS 插入', "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,status) VALUES (1719,1,'PRC-X','2026-10-15',1701,1790,1,8,'IN_PROGRESS')", 'process_order_bad_transition')
b17('17 加工单 BOM 不存在（外键）', "INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1719,1,'PRC-X','2026-10-15',999,1790,1,8)", 'FOREIGN KEY constraint failed')
expect_allow_tx('17 加工单 1710 CREATED', ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1710,1,'PRC-SH01-0001-20261015-000001','2026-10-15',1701,1790,10000,8)"])
b17('17 CREATED → COMPLETED 跳状态', "UPDATE process_order SET status='COMPLETED', completed_at='2026-10-15 03:00:00' WHERE id=1710", 'process_order_bad_transition')
expect_allow_tx('17 下达（带快照）', ["UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00', bom_code='BOM-SALMON', bom_version=1, bom_snapshot='[INPUT:1701,FINISHED:1702,BYPRODUCT:1703]', yield_min_bp=4500, yield_max_bp=5500, loss_max_bp=3000, balance_tol_bp=50 WHERE id=1710"])
expect_allow_tx('17 开工 IN_PROGRESS', ["UPDATE process_order SET status='IN_PROGRESS' WHERE id=1710"])
b17('17 IN_PROGRESS → CREATED 回退', "UPDATE process_order SET status='CREATED' WHERE id=1710", 'process_order_bad_transition')
expect_allow_tx('17 领用 10 KG：move(存储位→加工中心) + place_hold(PROCESSING) + 领用行 + 单头累计', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1781 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17003,'PRC-SH01-0001-20261015-000001',1,1,1,'DOC','PROCESS_ISSUE',-1,1781,2,1,1791,1701,1701,10000,20000,10000,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17003,'PRC-SH01-0001-20261015-000001:1:D1:1','PRC-SH01-0001-20261015-000001',1,1,1,'DOC',1781,2,-1,'2026-10-15')", 'UPDATE stock SET on_hand_qty_milli=10000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1782 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17004,'PRC-SH01-0001-20261015-000001',1,1,2,'DOC','PROCESS_ISSUE',1,1782,1,1,1790,1701,1701,10000,0,10000,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D1:2',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17004,'PRC-SH01-0001-20261015-000001:1:D1:2','PRC-SH01-0001-20261015-000001',1,1,2,'DOC',1782,1,1,'2026-10-15')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1730,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:00000000-0000-4000-8000-000000001720',10000,0)", 'UPDATE stock SET hold_qty_milli=10000, version=version+1 WHERE id=1782', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1720,1,1710,1,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',10000,21)", 'UPDATE process_order SET issued_qty_milli=10000 WHERE id=1710'])
r = one('SELECT available_qty_milli FROM v_stock_available WHERE stock_id=1782')[0]
ok(f"17 加工中心原料全部 PROCESSING 冻结，可用 = 0 = {r}") if str(r) == '0' else bad(f"17 加工中心原料全部 PROCESSING 冻结，可用 = 0 = {r}（期望 0）")
b17('17 领用行挂不存在的冻结（外键）', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1781,1782,999999,1701,1701,'2026-10-20',1,21)", 'FOREIGN KEY constraint failed')
b17('17 LIVE_TANK 领用缺 18 出池称重 live_weigh_id', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_count) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'LIVE_TANK',1781,1782,999998,1701,1701,'2026-10-20',1,21,3)", 'ck_prci_live')
b17('17 按件领用：件数 × 单件净重 ≠ 净重', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_pcs,unit_net_weight_g) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1787,1787,999998,1704,1764,'2026-10-20',2000,21,5,350)", 'ck_prci_pcs')
b17('17 按件领用：缺单件净重（std_net_weight_g 为空 → 40001）', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by,issue_pcs) VALUES (1729,1,1710,9,'PRCI:1710:x9',1791,'PALLET',1787,1787,999998,1704,1764,'2026-10-20',2000,21,5)", 'ck_prci_pcs')
b17('17 领用行 op_key 重放', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1729,1,1710,9,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',1,21)", 'process_issue_duplicate')
b17('17 领用量不可改', 'UPDATE process_issue SET issue_qty_milli=9000 WHERE id=1720', 'process_issue_immutable')
b17('17 领用行不可删', 'DELETE FROM process_issue WHERE id=1720', 'process_issue_immutable')
expect_allow_tx('17 报工 #1：成品 4.8 + 副产 2.0 + 损耗 TRIM 2.7（报损单只记账）；consume_process_hold 9.5（含损耗）+ post_in 两条', ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1740,1,1710,'00000000-0000-4000-8000-000000001740','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,false,200,'{}',21)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1750,1,1710,1740,1,'FINISHED',1702,1760,1792,4820,20,4800,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1751,1,1710,1740,2,'BYPRODUCT',1703,1761,1792,2020,20,2000,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1752,1,1710,1740,3,'LOSS',1701,NULL,NULL,2720,20,2700,'2026-10-15 03:00:00',NULL,NULL,9001,'TRIM',NULL)", "UPDATE stock_hold SET released_qty_milli=9500, status='HELD', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=9500", 'UPDATE stock SET on_hand_qty_milli=500, hold_qty_milli=500, ledger_seq=2, version=version+1 WHERE id=1782 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17005,'PRC-SH01-0001-20261015-000001',1,2,1,'DOC','PROCESS_CONSUME',-1,1782,2,1,1790,1701,1701,9500,10000,500,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D2:1',1730)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17005,'PRC-SH01-0001-20261015-000001:1:D2:1','PRC-SH01-0001-20261015-000001',1,2,1,'DOC',1782,2,-1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1001,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=4800, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1783 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17006,'PRC-SH01-0001-20261015-000001',1001,1,1,'DOC','PROCESS_OUTPUT',1,1783,1,1,1792,1702,1760,4800,0,4800,'2026-10-15','PRC-SH01-0001-20261015-000001:1001:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17006,'PRC-SH01-0001-20261015-000001:1001:D1:1','PRC-SH01-0001-20261015-000001',1001,1,1,'DOC',1783,1,1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000001',1002,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1784 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17007,'PRC-SH01-0001-20261015-000001',1002,1,1,'DOC','PROCESS_OUTPUT',1,1784,1,1,1792,1703,1761,2000,0,2000,'2026-10-15','PRC-SH01-0001-20261015-000001:1002:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17007,'PRC-SH01-0001-20261015-000001:1002:D1:1','PRC-SH01-0001-20261015-000001',1002,1,1,'DOC',1784,1,1,'2026-10-15')", 'UPDATE process_issue SET consumed_qty_milli=9500 WHERE id=1720', 'UPDATE process_order SET consumed_qty_milli=9500, output_qty_milli=4800, byproduct_qty_milli=2000, loss_qty_milli=2700 WHERE id=1710'])
r = one("SELECT on_hand_qty_milli || '/' || hold_qty_milli FROM stock WHERE id=1782")[0]
ok(f"17 C1 报工后：加工中心余料 = 0.5 KG，仍全部冻结 = {r}") if str(r) == '500/500' else bad(f"17 C1 报工后：加工中心余料 = 0.5 KG，仍全部冻结 = {r}（期望 500/500）")
b17('17 C2 单头已消耗 ≠ 各去向之和', 'UPDATE process_order SET consumed_qty_milli=9600 WHERE id=1710', 'ck_prc_consume')
b17('17 C2 消耗超过净领用（余料 < 0）', 'UPDATE process_order SET consumed_qty_milli=10100, loss_qty_milli=3300 WHERE id=1710', 'ck_prc_cap')
b17('17 领用行 冲回 + 消耗 > 领用（42214 OVER_REVERSE）', 'UPDATE process_issue SET reversed_qty_milli=501 WHERE id=1720', 'ck_prci_reverse')
b17('17 领用行消耗量回退', 'UPDATE process_issue SET consumed_qty_milli=9000 WHERE id=1720', 'process_issue_immutable')
b17('17 余料 0.5 KG > 容差 50g 时直接完工（必须先领用冲回）', "UPDATE process_order SET status='COMPLETED', yield_bp=4800, completed_at='2026-10-15 04:00:00' WHERE id=1710", 'ck_prc_balance')
expect_allow_tx('17 领用冲回 0.45 KG：release_hold（stock_hold_release）+ move 回来源库位 + 冲回记录（movement_ref/hold_release_id）', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (1735,1730,'PRCR:1710:00000000-0000-4000-8000-000000001790',450)", "UPDATE stock_hold SET released_qty_milli=9950, status='HELD', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=450", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1710',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=50, hold_qty_milli=50, ledger_seq=3, version=version+1 WHERE id=1782 AND ledger_seq=2', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17008,'PRCR-1710',1,1,1,'DOC','PROCESS_REVERSE',-1,1782,3,1,1790,1701,1701,450,500,50,'2026-10-15','PRCR-1710:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17008,'PRCR-1710:1:D1:1','PRCR-1710',1,1,1,'DOC',1782,3,-1,'2026-10-15')", 'UPDATE stock SET on_hand_qty_milli=10450, hold_qty_milli=0, ledger_seq=3, version=version+1 WHERE id=1781 AND ledger_seq=2', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17009,'PRCR-1710',1,1,2,'DOC','PROCESS_REVERSE',1,1781,3,1,1791,1701,1701,450,10000,10450,'2026-10-15','PRCR-1710:1:D1:2',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17009,'PRCR-1710:1:D1:2','PRCR-1710',1,1,2,'DOC',1781,3,1,'2026-10-15')", 'UPDATE process_issue SET reversed_qty_milli=450 WHERE id=1720', 'UPDATE process_order SET reversed_qty_milli=450 WHERE id=1710', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1790,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001790','ISSUE',NULL,NULL,1720,NULL,450,'PRCR-1710:1:D1:1',1735,'测试',9)"])
b17('17 领用冲回缺 hold_release_id', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001791','ISSUE',NULL,NULL,1720,NULL,1,'PRCR-1710:1:D1:1',NULL,'测试',9)", 'ck_prcv_type')
b17('17 冲回 movement_ref 指向不存在的流水（外键）', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001791','ISSUE',NULL,NULL,1720,NULL,1,'NOPE:1:D1:1',1735,'测试',9)", 'FOREIGN KEY constraint failed')
b17('17 冲回 op_key 不带加工单 id / 非 UUID', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,issue_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:abc','ISSUE',1720,1,'PRCR-1710:1:D1:1',1735,'x',9)", 'ck_prcv_op')
b17('17 冲回 op_key 重放', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1791,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001790','ISSUE',NULL,NULL,1720,NULL,1,'PRCR-1710:1:D1:1',1735,'测试',9)", 'process_reversal_duplicate')
expect_allow_tx('17 完工报工：余料 50g ≤ 容差 → WEIGH_DIFF 损耗 + consume 50g', ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1741,1,1710,'00000000-0000-4000-8000-000000001741','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',2,true,200,'{}',21)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1753,1,1710,1741,1,'LOSS',1701,NULL,NULL,70,20,50,'2026-10-15 03:00:00',NULL,NULL,9002,'WEIGH_DIFF',NULL)", "UPDATE stock_hold SET released_qty_milli=10000, status='RELEASED', version=version+1 WHERE id=1730 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=50", 'UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=4, version=version+1 WHERE id=1782 AND ledger_seq=3', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17010,'PRC-SH01-0001-20261015-000001',1,3,1,'DOC','PROCESS_CONSUME',-1,1782,4,1,1790,1701,1701,50,50,0,'2026-10-15','PRC-SH01-0001-20261015-000001:1:D3:1',1730)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17010,'PRC-SH01-0001-20261015-000001:1:D3:1','PRC-SH01-0001-20261015-000001',1,3,1,'DOC',1782,4,-1,'2026-10-15')", 'UPDATE process_issue SET consumed_qty_milli=9550 WHERE id=1720', 'UPDATE process_order SET consumed_qty_milli=9550, loss_qty_milli=2750 WHERE id=1710'])
b17('17 完工出成率与净额不符（应用传 5100）', "UPDATE process_order SET status='COMPLETED', yield_bp=5100, completed_at='2026-10-15 04:00:00' WHERE id=1710", 'ck_prc_yield')
expect_allow_tx('17 完工：余料 0、出成率 4.8/9.55 = 50.26%、损耗 28.8% 均在界内', ["UPDATE process_order SET status='COMPLETED', yield_bp=5026, completed_at='2026-10-15 04:00:00' WHERE id=1710"])
b17('17 完工后单据只读', 'UPDATE process_order SET loss_qty_milli=2751 WHERE id=1710', 'process_order_frozen')
r = one("SELECT status || '/' || released_qty_milli FROM stock_hold WHERE id=1730")[0]
ok(f"17 1710 冻结已全部释放（RELEASED，释放 = 消耗 + 冲回） = {r}") if str(r) == 'RELEASED/10000' else bad(f"17 1710 冻结已全部释放（RELEASED，释放 = 消耗 + 冲回） = {r}（期望 RELEASED/10000）")
expect_allow_tx('17 单 1711 建单 → 下达 → 开工', ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1711,1,'PRC-SH01-0001-20261015-000002','2026-10-15',1701,1790,10000,8)"])
expect_allow_tx('17 单 1711 下达', ["UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00', bom_code='BOM-SALMON', bom_version=1, bom_snapshot='[INPUT:1701,FINISHED:1702,BYPRODUCT:1703]', yield_min_bp=4500, yield_max_bp=5500, loss_max_bp=3000, balance_tol_bp=50 WHERE id=1711"])
expect_allow_tx('17 单 1711 开工', ["UPDATE process_order SET status='IN_PROGRESS' WHERE id=1711"])
expect_allow_tx('17 单 1711 领用 5 KG', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=5450, hold_qty_milli=0, ledger_seq=4, version=version+1 WHERE id=1781 AND ledger_seq=3', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17011,'PRC-SH01-0001-20261015-000002',1,1,1,'DOC','PROCESS_ISSUE',-1,1781,4,1,1791,1701,1701,5000,10450,5450,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17011,'PRC-SH01-0001-20261015-000002:1:D1:1','PRC-SH01-0001-20261015-000002',1,1,1,'DOC',1781,4,-1,'2026-10-15')", 'UPDATE stock SET on_hand_qty_milli=5000, hold_qty_milli=0, ledger_seq=5, version=version+1 WHERE id=1782 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17012,'PRC-SH01-0001-20261015-000002',1,1,2,'DOC','PROCESS_ISSUE',1,1782,5,1,1790,1701,1701,5000,0,5000,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D1:2',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17012,'PRC-SH01-0001-20261015-000002:1:D1:2','PRC-SH01-0001-20261015-000002',1,1,2,'DOC',1782,5,1,'2026-10-15')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1731,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1711,'PRCI:1711:00000000-0000-4000-8000-000000001721',5000,0)", 'UPDATE stock SET hold_qty_milli=5000, version=version+1 WHERE id=1782', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1721,1,1711,1,'PRCI:1711:00000000-0000-4000-8000-000000001721',1791,'PALLET',1781,1782,1731,1701,1701,'2026-10-20',5000,21)", 'UPDATE process_order SET issued_qty_milli=5000 WHERE id=1711'])
expect_allow_tx('17 单 1711 报工：成品 2.5 + 副产 2.0 + 损耗 TRIM 0.5，consume 5.0', ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1742,1,1711,'00000000-0000-4000-8000-000000001742','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,false,200,'{}',21)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1754,1,1711,1742,1,'FINISHED',1702,1762,1792,2520,20,2500,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1755,1,1711,1742,2,'BYPRODUCT',1703,1765,1792,2020,20,2000,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1756,1,1711,1742,3,'LOSS',1701,NULL,NULL,520,20,500,'2026-10-15 03:00:00',NULL,NULL,9003,'TRIM',NULL)", "UPDATE stock_hold SET released_qty_milli=5000, status='RELEASED', version=version+1 WHERE id=1731 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=5000", 'UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=6, version=version+1 WHERE id=1782 AND ledger_seq=5', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17013,'PRC-SH01-0001-20261015-000002',1,2,1,'DOC','PROCESS_CONSUME',-1,1782,6,1,1790,1701,1701,5000,5000,0,'2026-10-15','PRC-SH01-0001-20261015-000002:1:D2:1',1731)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17013,'PRC-SH01-0001-20261015-000002:1:D2:1','PRC-SH01-0001-20261015-000002',1,2,1,'DOC',1782,6,-1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1001,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=2500, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1785 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17014,'PRC-SH01-0001-20261015-000002',1001,1,1,'DOC','PROCESS_OUTPUT',1,1785,1,1,1792,1702,1762,2500,0,2500,'2026-10-15','PRC-SH01-0001-20261015-000002:1001:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17014,'PRC-SH01-0001-20261015-000002:1001:D1:1','PRC-SH01-0001-20261015-000002',1001,1,1,'DOC',1785,1,1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',1002,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1788 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17015,'PRC-SH01-0001-20261015-000002',1002,1,1,'DOC','PROCESS_OUTPUT',1,1788,1,1,1792,1703,1765,2000,0,2000,'2026-10-15','PRC-SH01-0001-20261015-000002:1002:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17015,'PRC-SH01-0001-20261015-000002:1002:D1:1','PRC-SH01-0001-20261015-000002',1002,1,1,'DOC',1788,1,1,'2026-10-15')", 'UPDATE process_issue SET consumed_qty_milli=5000 WHERE id=1721', 'UPDATE process_order SET consumed_qty_milli=5000, output_qty_milli=2500, byproduct_qty_milli=2000, loss_qty_milli=500 WHERE id=1711'])
expect_allow_tx('17 C3 产出冲回报废 0.3 KG：post_out(PROCESS_REVERSE)，output −0.3、scrapped +0.3、consumed 不变', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1711',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=2200, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1785 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17016,'PRCR-1711',1,1,1,'DOC','PROCESS_REVERSE',-1,1785,2,1,1792,1702,1762,300,2500,2200,'2026-10-15','PRCR-1711:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17016,'PRCR-1711:1:D1:1','PRCR-1711',1,1,1,'DOC',1785,2,-1,'2026-10-15')", 'UPDATE process_output SET reversed_qty_milli=300 WHERE id=1754', 'UPDATE process_order SET output_qty_milli=2200, scrapped_qty_milli=300 WHERE id=1711', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1792,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001792','OUTPUT','SCRAP',NULL,NULL,1754,300,'PRCR-1711:1:D1:1',NULL,'测试',9)"])
b17('17 产出冲回直接改库存、不记报废（旧写法：output 减了、scrapped 没加）', 'UPDATE process_order SET output_qty_milli=2100 WHERE id=1711', 'ck_prc_consume')
b17('17 scrapped 回退', 'UPDATE process_order SET output_qty_milli=2300, scrapped_qty_milli=200 WHERE id=1711', 'process_order_frozen')
b17('17 返工回台缺主管审批单号', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1793,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001793','OUTPUT','REWORK',NULL,NULL,1754,200,'PRCR-1711:1:D1:1',NULL,'测试',9)", 'ck_prcv_type')
expect_allow_tx('17 返工回台 0.2 KG（主管 approval_no）：move 成品 → 加工中心 + place_hold + REWORK 领用行；issued +0.2、reworked +0.2', ['UPDATE stock SET location_id=1790, lot_id=1762 WHERE id=1786', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRCR-1711',2,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=2000, hold_qty_milli=0, ledger_seq=3, version=version+1 WHERE id=1785 AND ledger_seq=2', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17017,'PRCR-1711',2,1,1,'DOC','PROCESS_REVERSE',-1,1785,3,1,1792,1702,1762,200,2200,2000,'2026-10-15','PRCR-1711:2:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17017,'PRCR-1711:2:D1:1','PRCR-1711',2,1,1,'DOC',1785,3,-1,'2026-10-15')", 'UPDATE stock SET on_hand_qty_milli=200, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1786 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17018,'PRCR-1711',2,1,2,'DOC','PROCESS_REVERSE',1,1786,1,1,1790,1702,1762,200,0,200,'2026-10-15','PRCR-1711:2:D1:2',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17018,'PRCR-1711:2:D1:2','PRCR-1711',2,1,2,'DOC',1786,1,1,'2026-10-15')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1732,1786,'PROCESSING','PROCESSING','PROCESS_ORDER',1711,'PRCI:1711:00000000-0000-4000-8000-000000001722',200,0)", 'UPDATE stock SET hold_qty_milli=200, version=version+1 WHERE id=1786', "INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1722,1,1711,2,'PRCI:1711:00000000-0000-4000-8000-000000001722',1792,'REWORK',1785,1786,1732,1702,1762,'2026-10-18',200,21)", 'UPDATE process_output SET reversed_qty_milli=500 WHERE id=1754', 'UPDATE process_order SET issued_qty_milli=5200, output_qty_milli=2000, reworked_qty_milli=200 WHERE id=1711', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1793,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001793','OUTPUT','REWORK','APR-WHSH01-20261015-000031',NULL,1754,200,'PRCR-1711:2:D1:1',NULL,'测试',9)"])
expect_allow_tx('17 返工报工：成品 0.19 + 损耗 TRIM 0.01，consume 0.2', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (1789,1,1792,1702,1763,'KG',0)", "INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1743,1,1711,'00000000-0000-4000-8000-000000001743','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',2,false,200,'{}',21)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1757,1,1711,1743,1,'FINISHED',1702,1763,1792,210,20,190,'2026-10-15 03:00:00','2026-10-18','2026-10-20',NULL,NULL,NULL)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1758,1,1711,1743,2,'LOSS',1702,NULL,NULL,30,20,10,'2026-10-15 03:00:00',NULL,NULL,9004,'TRIM',NULL)", "UPDATE stock_hold SET released_qty_milli=200, status='RELEASED', version=version+1 WHERE id=1732 AND hold_type='PROCESSING' AND hold_qty_milli-released_qty_milli>=200", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',2,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=0, hold_qty_milli=0, ledger_seq=2, version=version+1 WHERE id=1786 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17019,'PRC-SH01-0001-20261015-000002',2,2,1,'DOC','PROCESS_CONSUME',-1,1786,2,1,1790,1702,1762,200,200,0,'2026-10-15','PRC-SH01-0001-20261015-000002:2:D2:1',1732)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17019,'PRC-SH01-0001-20261015-000002:2:D2:1','PRC-SH01-0001-20261015-000002',2,2,1,'DOC',1786,2,-1,'2026-10-15')", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('PRC-SH01-0001-20261015-000002',2001,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=190, hold_qty_milli=0, ledger_seq=1, version=version+1 WHERE id=1789 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (17020,'PRC-SH01-0001-20261015-000002',2001,1,1,'DOC','PROCESS_OUTPUT',1,1789,1,1,1792,1702,1763,190,0,190,'2026-10-15','PRC-SH01-0001-20261015-000002:2001:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (17020,'PRC-SH01-0001-20261015-000002:2001:D1:1','PRC-SH01-0001-20261015-000002',2001,1,1,'DOC',1789,1,1,'2026-10-15')", 'UPDATE process_issue SET consumed_qty_milli=200 WHERE id=1722', 'UPDATE process_order SET consumed_qty_milli=5200, output_qty_milli=2190, loss_qty_milli=510 WHERE id=1711'])
b17('17 C4 损耗部分冲回（只能整行转出，对应 09 整张作废）', 'UPDATE process_output SET reversed_qty_milli=100 WHERE id=1756', 'ck_prco_loss_whole')
expect_allow_tx('17 C4 损耗冲回只改原因/拆数量：TRIM 0.5 整行转出 → TRIM 0.4 + DEFECT 0.1（新行 from_output_id、新报损单），不回在制、单头损耗不变', ['UPDATE process_output SET reversed_qty_milli=500 WHERE id=1756', "INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1744,1,1711,'00000000-0000-4000-8000-000000001744','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',3,false,200,'{}',21)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1768,1,1711,1744,1,'LOSS',1701,NULL,NULL,420,20,400,'2026-10-15 03:00:00',NULL,NULL,9005,'TRIM',1756)", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1759,1,1711,1744,2,'LOSS',1701,NULL,NULL,120,20,100,'2026-10-15 03:00:00',NULL,NULL,9006,'DEFECT',1756)", "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1794,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001794','LOSS',NULL,NULL,NULL,1756,500,NULL,NULL,'测试',9)"])
b17('17 损耗冲回带库存流水（回在制）', "INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,issue_id,output_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1795,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001795','LOSS',NULL,NULL,NULL,1756,1,'PRCR-1711:1:D1:1',NULL,'测试',9)", 'ck_prcv_type')
b17('17 损耗冲回直接把单头损耗减掉（重量凭空消失）', 'UPDATE process_order SET loss_qty_milli=410 WHERE id=1711', 'ck_prc_consume')
b17('17 LOSS 行原因不可直接改', "UPDATE process_output SET loss_reason='DRIP' WHERE id=1756", 'process_output_immutable')
b17('17 LOSS 原因 REVERSE_SCRAP 不收（报废单独记 scrapped）', "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id) VALUES (1769,1,1711,1744,9,'LOSS',1701,NULL,NULL,21,20,1,'2026-10-15 03:00:00',NULL,NULL,9006,'REVERSE_SCRAP',NULL)", 'ck_prco_kind')
b17('17 越界直接完工（无审批单）', "UPDATE process_order SET status='COMPLETED', yield_bp=4380, completed_at='2026-10-15 05:00:00' WHERE id=1711", 'ck_prc_dev')
b17('17 待审批缺过期时刻（Q-f 12h）', "UPDATE process_order SET status='PENDING_APPROVAL', yield_bp=4380, approval_no='APR-WHSH01-20261015-000032' WHERE id=1711", 'ck_prc_apr_exp')
expect_allow_tx('17 越界转 PROCESS_YIELD_DEVIATION（出成率+损耗合并一张，12h 过期）', ["UPDATE process_order SET status='PENDING_APPROVAL', yield_bp=4380, approval_no='APR-WHSH01-20261015-000032', approval_expires_at='2026-10-15 17:00:00' WHERE id=1711"])
b17('17 PENDING_APPROVAL → CANCELLED 不允许', "UPDATE process_order SET status='CANCELLED', cancel_reason='x' WHERE id=1711", 'process_order_bad_transition')
expect_allow_tx('17 审批通过 → COMPLETED', ["UPDATE process_order SET status='COMPLETED', completed_at='2026-10-15 06:00:00' WHERE id=1711"])
expect_allow_tx('17 撤销单 1713 建单', ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1713,1,'PRC-SH01-0001-20261015-000003','2026-10-15',1701,1790,10000,8)"])
b17('17 撤销缺原因', "UPDATE process_order SET status='CANCELLED' WHERE id=1713", 'ck_prc_cancel')
expect_allow_tx('17 撤销', ["UPDATE process_order SET status='CANCELLED', cancel_reason='设备故障' WHERE id=1713"])
expect_allow_tx('17 追溯：成品 1760 ← 原料行 1720；返工成品 1763 ← REWORK 行 1722', ['INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1770,1,1710,1750,1760,1720,1701),(1771,1,1710,1751,1761,1720,1701),(1772,1,1711,1757,1763,1722,1762),(1773,1,1711,1754,1762,1721,1701)'])
b17('17 追溯挂不存在的产出（外键）', 'INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1779,1,1710,999999,1760,1720,1701)', 'FOREIGN KEY constraint failed')
r = one('SELECT count(*) FROM stock s WHERE s.id BETWEEN 1781 AND 1789 AND (s.on_hand_qty_milli <> COALESCE((SELECT SUM(m.direction*m.move_qty_milli) FROM stock_movement m WHERE m.stock_id=s.id),0) OR s.ledger_seq <> COALESCE((SELECT MAX(m.stock_seq) FROM stock_movement m WHERE m.stock_id=s.id AND m.direction<>0),0))')[0]
ok(f"17 C5 流水回放：8 行库存 on_hand = Σ流水 且 ledger_seq = 末条 stock_seq（差异行数） = {r}") if str(r) == '0' else bad(f"17 C5 流水回放：8 行库存 on_hand = Σ流水 且 ledger_seq = 末条 stock_seq（差异行数） = {r}（期望 0）")
r = one('SELECT count(*) FROM process_order WHERE id IN (1710,1711) AND NOT (issued_qty_milli - reversed_qty_milli = consumed_qty_milli AND consumed_qty_milli = output_qty_milli+byproduct_qty_milli+loss_qty_milli+scrapped_qty_milli+reworked_qty_milli)')[0]
ok(f"17 C5 单头公式：issued − reversed = consumed = 成品+副产+损耗+报废+返工（不平的单数） = {r}") if str(r) == '0' else bad(f"17 C5 单头公式：issued − reversed = consumed = 成品+副产+损耗+报废+返工（不平的单数） = {r}（期望 0）")
r = one('SELECT count(*) FROM process_order o WHERE o.id IN (1710,1711) AND (o.issued_qty_milli,o.reversed_qty_milli,o.consumed_qty_milli) <> (SELECT SUM(i.issue_qty_milli),SUM(i.reversed_qty_milli),SUM(i.consumed_qty_milli) FROM process_issue i WHERE i.process_order_id=o.id)')[0]
ok(f"17 C5 明细 ↔ 单头：Σ领用行 issued/reversed/consumed = 单头（不平的单数） = {r}") if str(r) == '0' else bad(f"17 C5 明细 ↔ 单头：Σ领用行 issued/reversed/consumed = 单头（不平的单数） = {r}（期望 0）")
r = one("SELECT count(*) FROM process_issue i JOIN stock_hold h ON h.id=i.hold_id WHERE i.reversed_qty_milli + i.consumed_qty_milli <> h.released_qty_milli OR h.status <> 'RELEASED'")[0]
ok(f"17 C5 明细 ↔ 冻结：每行 冲回+消耗 = PROCESSING 已释放量，余量 = 0（不平的行数） = {r}") if str(r) == '0' else bad(f"17 C5 明细 ↔ 冻结：每行 冲回+消耗 = PROCESSING 已释放量，余量 = 0（不平的行数） = {r}（期望 0）")
r = one("SELECT -SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_type='PROCESS_CONSUME' AND biz_no LIKE 'PRC-SH01-0001-20261015-%'")[0]
ok(f"17 C5 流水 ↔ 单头：Σ PROCESS_CONSUME = consumed（1710/1711 合计 9550+5200） = {r}") if str(r) == '14750' else bad(f"17 C5 流水 ↔ 单头：Σ PROCESS_CONSUME = consumed（1710/1711 合计 9550+5200） = {r}（期望 14750）")
r = one("SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_type='PROCESS_OUTPUT'")[0]
ok(f"17 C5 流水 ↔ 产出：Σ PROCESS_OUTPUT = 成品+副产 产出原值（4800+2000+2500+2000+190） = {r}") if str(r) == '11490' else bad(f"17 C5 流水 ↔ 产出：Σ PROCESS_OUTPUT = 成品+副产 产出原值（4800+2000+2500+2000+190） = {r}（期望 11490）")
r = one("SELECT (SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_no='PRCR-1710') || '/' || (SELECT SUM(direction*move_qty_milli) FROM stock_movement WHERE biz_no='PRCR-1711')")[0]
ok(f"17 C5 冲回流水平衡：领用冲回两腿净额 0、报废 −0.3、返工两腿净额 0（PRCR-1710 / PRCR-1711 合计） = {r}") if str(r) == '0/-300' else bad(f"17 C5 冲回流水平衡：领用冲回两腿净额 0、报废 −0.3、返工两腿净额 0（PRCR-1710 / PRCR-1711 合计） = {r}（期望 0/-300）")
r = one("SELECT (SELECT SUM(qty_milli) FROM process_reversal WHERE reversal_type='ISSUE') - (SELECT SUM(reversed_qty_milli) FROM process_issue) + (SELECT count(*) FROM process_reversal v WHERE v.movement_ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.idempotency_key=v.movement_ref))")[0]
ok(f"17 C5 冲回记录 ↔ 明细：Σ ISSUE 冲回 = Σ 领用行 reversed；每条冲回 movement_ref 都有流水 = {r}") if str(r) == '0' else bad(f"17 C5 冲回记录 ↔ 明细：Σ ISSUE 冲回 = Σ 领用行 reversed；每条冲回 movement_ref 都有流水 = {r}（期望 0）")
r = one('SELECT (SELECT SUM(on_hand_qty_milli) FROM stock WHERE id IN (1781,1782,1783,1784,1785,1786,1788,1789)) + (SELECT SUM(loss_qty_milli+scrapped_qty_milli) FROM process_order WHERE id IN (1710,1711))')[0]
ok(f"17 C5 全仓重量守恒：原料期初 20 = 在库(原料+在制+成品+副产) + 损耗 + 报废（克） = {r}") if str(r) == '20000' else bad(f"17 C5 全仓重量守恒：原料期初 20 = 在库(原料+在制+成品+副产) + 损耗 + 报废（克） = {r}（期望 20000）")
r = one("SELECT count(*) FROM stock_hold h WHERE h.id IN (1730,1731,1732) AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.biz_type='PROCESS_CONSUME' AND m.direction=-1),0)")[0]
ok(f"17 I3f（#2 1d907031）按 hold_id 对账：每条 PROCESSING 冻结 已释放 = stock_hold_release + 本冻结 PROCESS_CONSUME 流水（不平的冻结数） = {r}") if str(r) == '0' else bad(f"17 I3f（#2 1d907031）按 hold_id 对账：每条 PROCESSING 冻结 已释放 = stock_hold_release + 本冻结 PROCESS_CONSUME 流水（不平的冻结数） = {r}（期望 0）")
r = one("SELECT count(*) FROM stock_movement m WHERE m.biz_type='PROCESS_CONSUME' AND m.biz_no LIKE 'PRC-SH01-0001-20261015-%' AND (m.hold_id IS NULL OR NOT EXISTS (SELECT 1 FROM process_issue i JOIN process_order o ON o.id=i.process_order_id WHERE i.hold_id=m.hold_id AND o.code=m.biz_no AND i.line_no=m.line_no))")[0]
ok(f"17 consume 流水全部写 hold_id，且与领用行 hold_id 一致（缺失/不一致条数） = {r}") if str(r) == '0' else bad(f"17 consume 流水全部写 hold_id，且与领用行 hold_id 一致（缺失/不一致条数） = {r}（期望 0）")
b17("17 B6 INSERT OR REPLACE 覆写 process_report", "INSERT OR REPLACE INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,is_final,response_http,response,reported_by) VALUES (1740,1,1710,'00000000-0000-4000-8000-000000001740','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',1,false,202,'{}',21)", 'process_report_duplicate')
b17("17 B6 INSERT OR REPLACE 覆写 process_issue", "INSERT OR REPLACE INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1720,1,1710,1,'PRCI:1710:00000000-0000-4000-8000-000000001720',1791,'PALLET',1781,1782,1730,1701,1701,'2026-10-20',1,21)", 'process_issue_duplicate')
b17("17 B6 INSERT OR REPLACE 覆写 process_output", "INSERT OR REPLACE INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1750,1,1710,1740,1,'FINISHED',1702,1760,1792,9020,20,9000,'2026-10-15 03:00:00','2026-10-18','2026-10-20')", 'process_output_duplicate')
b17("17 B6 INSERT OR REPLACE 覆写 process_lot_trace", 'INSERT OR REPLACE INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1770,1,1710,1750,1760,1720,1765)', 'process_lot_trace_duplicate')
b17("17 B6 INSERT OR REPLACE 覆写 process_reversal", "INSERT OR REPLACE INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,output_id,qty_milli,reason,operator_id) VALUES (1794,1,1711,'PRCR:1711:00000000-0000-4000-8000-000000001794','LOSS',1756,1,'x',9)", 'process_reversal_duplicate')
r = one("WITH RECURSIVE f(lot) AS (SELECT output_lot_id FROM process_lot_trace WHERE raw_lot_id=1701 UNION SELECT t.output_lot_id FROM process_lot_trace t JOIN f ON t.raw_lot_id=f.lot) SELECT group_concat(lot, ',') FROM (SELECT lot FROM f ORDER BY lot)")[0]
ok(f"17 召回正查（递归，含返工二级）：原料批次 1701 → {r}") if r == "1760,1761,1762,1763" else bad(f"17 召回正查 = {r}（期望 1760,1761,1762,1763）")
print("=== 2h-loss. docs/17 损耗定案主守卫：损耗行条件更新（审批回调 / 12h 过期任务重放）===")
def _settle(stmts):
    conn.execute("BEGIN IMMEDIATE")
    for x in stmts: conn.execute(x)
    conn.execute("COMMIT")
expect_allow_tx("17 损耗定案准备：1711 两条越界损耗行 1797/1798（PENDING_APPROVAL）", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1797,1,1711,1744,7,'LOSS',1701,NULL,NULL,320,20,300,'2026-10-15 03:00:00',NULL,NULL,9007,'WEIGH_DIFF',NULL,'PENDING_APPROVAL')", "INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1798,1,1711,1744,8,'LOSS',1701,NULL,NULL,420,20,400,'2026-10-15 03:00:00',NULL,NULL,9008,'WEIGH_DIFF',NULL,'PENDING_APPROVAL')"])
_settle(["UPDATE process_output SET loss_status='APPROVED', loss_approved_qty_milli=300, loss_exception_no=NULL WHERE id=1797 AND loss_status='PENDING_APPROVAL'", "INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9971,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' WHERE changes() = 1"]); _settle(["UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0, loss_exception_no='EXC-1797' WHERE id=1797 AND loss_status='PENDING_APPROVAL'", "INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9972,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' WHERE changes() = 1"])
_r = one("SELECT loss_status || '/' || COALESCE(loss_exception_no,'-') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9971,9972)) FROM process_output WHERE id=1797")[0]
ok(f"17 先审批通过，过期任务重放 → 状态/异常单/loss_settled = {_r}") if _r == "APPROVED/-/1" else bad(f"17 审批→过期重放后 = {_r}（期望 APPROVED/-/1）")
_settle(["UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0, loss_exception_no='EXC-1798' WHERE id=1798 AND loss_status='PENDING_APPROVAL'", "INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9981,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' WHERE changes() = 1"]); _settle(["UPDATE process_output SET loss_status='APPROVED', loss_approved_qty_milli=400, loss_exception_no=NULL WHERE id=1798 AND loss_status='PENDING_APPROVAL'", "INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9982,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' WHERE changes() = 1"]); _settle(["UPDATE process_output SET loss_status='REJECTED', loss_approved_qty_milli=0, loss_exception_no='EXC-1798B' WHERE id=1798 AND loss_status='PENDING_APPROVAL'", "INSERT INTO outbox_event (id,topic,biz_key,payload) SELECT 9983,'wms.process.loss_settled','PRC-SH01-20261015-001711','{}' WHERE changes() = 1"])
_r = one("SELECT loss_status || '/' || COALESCE(loss_exception_no,'-') || '/' || (SELECT count(*) FROM outbox_event WHERE topic='wms.process.loss_settled' AND id IN (9981,9982,9983)) FROM process_output WHERE id=1798")[0]
ok(f"17 先过期转异常，审批通过/驳回回调重放 → 仍 {_r}（异常单 1 张、loss_settled 1 条）") if _r == "EXPIRED_TO_EXCEPTION/EXC-1798/1" else bad(f"17 过期→审批重放后 = {_r}")
b17('17 绕过条件更新：已 APPROVED 直接改 REJECTED', "UPDATE process_output SET loss_status='REJECTED', loss_approved_qty_milli=0, loss_exception_no='EXC-X' WHERE id=1797", 'process_loss_settle_once')
b17('17 定案后改异常单号', "UPDATE process_output SET loss_exception_no='EXC-Y' WHERE id=1798", 'process_loss_settle_once')
conn.execute("INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,scrap_order_id,loss_reason,from_output_id,loss_status) VALUES (1799,1,1711,1744,9,'LOSS',1701,NULL,NULL,120,20,100,'2026-10-15 03:00:00',NULL,NULL,9009,'WEIGH_DIFF',NULL,'PENDING_APPROVAL')"); conn.commit()
b17('17 过期转异常不带异常单号', "UPDATE process_output SET loss_status='EXPIRED_TO_EXCEPTION', loss_approved_qty_milli=0 WHERE id=1799", 'ck_prco_loss_settle')
b17('17 非 LOSS 行（SETTLED）不能改成待审', "UPDATE process_output SET loss_status='PENDING_APPROVAL' WHERE output_role='FINISHED' AND process_order_id=1711", 'process_loss_settle_once')

print("=== 2h. docs/18 活鲜暂存：B2 死亡/失重单次扣减、P2 整池释放、B3 task_kind、B5 42217 不占键、B6 外键 ===")
expect_allow_tx('18 种子：活鲜 SKU 3、池 61（LIVE_TANK）、普通位 62、批次 31/32、stock 6101/6102', ["INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (61,1,2,'LT-01','LIVE_TANK',4,'L010'),(62,1,2,'B09-01-01','BIN',2,'L020')", "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (3,'SKU-CRAB','阳澄湖大闸蟹','KG','CHILLED',7,1)", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (31,3,'LOT-C1','2026-10-22','2026-10-15','QUALIFIED',7),(32,3,'LOT-C2','2026-10-23','2026-10-16','QUALIFIED',7)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (6101,1,61,3,31,'KG',50000),(6102,1,61,3,32,'KG',20000)"])
expect_block_tx('18 B6 普通库位挂池扩展', ['INSERT INTO live_tank (location_id,warehouse_id,sku_id,water_volume_l,temp_min_c10,temp_max_c10,temp_severe_min_c10,temp_severe_max_c10,do_min_x100,do_severe_min_x100,ph_min_x100,ph_max_x100) VALUES (62,1,3,2000,140,200,100,240,500,300,700,850)'], 'lt_not_live_tank')
expect_allow_tx('18 SKU 参数与池扩展（池 61）', ['INSERT INTO sku_live_param (sku_id) VALUES (3)', 'INSERT INTO live_tank (location_id,warehouse_id,sku_id,water_volume_l,temp_min_c10,temp_max_c10,temp_severe_min_c10,temp_severe_max_c10,do_min_x100,do_severe_min_x100,ph_min_x100,ph_max_x100) VALUES (61,1,3,2000,140,200,100,240,500,300,700,850)'])
expect_block_tx('18 B6 SKU 参数指向不存在的 SKU', ['INSERT INTO sku_live_param (sku_id) VALUES (9999)'], 'FOREIGN KEY constraint failed')
expect_block_tx('18 一池一 SKU：改池 SKU', ['UPDATE live_tank SET sku_id=1 WHERE location_id=61'], 'lt_immutable')
expect_allow_tx('18 尾数余额（6101 120 只，6102 40 只）', ['INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES (6101,61,31,120),(6102,61,32,40)'])
expect_block_tx('18 B6 尾数余额引用不存在的 stock', ['INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES (987654,61,31,0)'], 'FOREIGN KEY constraint failed')
expect_block_tx('18 B6 尾数流水引用不存在的重量流水', ["INSERT INTO live_count_ledger (id,stock_id,biz_type,biz_no,delta_count,count_before,count_after,movement_id) VALUES (6190,6101,'DEATH','LD-X',-1,120,119,987654)"], 'FOREIGN KEY constraint failed')
expect_block_tx('18 B6 巡检挂在非池库位', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6190,1,62,'DEV-L','op-x',7,'2026-10-15 10:00:00',180,600,780,'NORMAL',0,false)"], 'FOREIGN KEY constraint failed')
expect_allow_tx('18 连续 2 次超标 → 锁池单 6121 + 两条 place_hold(LIVE_HOLD)（先锁 stock 行再写冻结明细）', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6111,1,61,'DEV-L','op-1',7,'2026-10-15 10:00:00',215,600,780,'ALARM',1,false)", "INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6112,1,61,'DEV-L','op-2',7,'2026-10-15 10:00:00',216,600,780,'ALARM',2,false)", "INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id) VALUES (6121,1,61,'CONSECUTIVE_BREACH',6112)", 'UPDATE stock SET hold_qty_milli = hold_qty_milli + on_hand_qty_milli, version = version + 1 WHERE id IN (6101,6102) AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli = on_hand_qty_milli', "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (6131,6101,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6121,'LH:6121:6101',50000,0,'HELD',0),(6132,6102,'LIVE_HOLD','LIVE_HOLD','LIVE_TANK_HOLD',6121,'LH:6121:6102',20000,0,'HELD',0)"])
expect_block_tx('18 同池第二条 ACTIVE 锁', ["INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id) VALUES (6129,1,61,'SEVERE',987654)"], 'lth_duplicate')
expect_allow_tx('18 B2 锁池中死亡：consume_live_hold(6131, 1200, LIVE_DEATH) + 只数 −2 + 流水挂 hold_id、live_death 挂 movement_id', ['UPDATE stock SET hold_qty_milli = hold_qty_milli - 1200, on_hand_qty_milli = on_hand_qty_milli - 1200, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6101 AND hold_qty_milli >= 1200 AND on_hand_qty_milli >= 1200', "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1200, status = CASE WHEN released_qty_milli + 1200 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 6131 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1200", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6151',1,'DOC',NULL)", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (6141,'LD-6151',1,1,1,'DOC','SCRAP',-1,6101,1,1,61,3,31,NULL,NULL,NULL,NULL,1200,50000,48800,'2026-10-16','LD-6151:1:D1:1',6131)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6141,'LD-6151:1:D1:1','LD-6151',1,1,1,'DOC',NULL,NULL,NULL,NULL,6101,1,-1,'2026-10-16')", 'UPDATE live_stock_count SET on_hand_count = on_hand_count - 2, version = version + 1 WHERE stock_id = 6101 AND on_hand_count >= 2', "INSERT INTO live_count_ledger (id,stock_id,biz_type,biz_no,delta_count,count_before,count_after,movement_id) VALUES (6161,6101,'DEATH','LD-6151',-2,120,118,6141)", "INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6151,1,61,6101,31,'2026-10-16','DEV-L','d-1',2,1200,125,6141,1200,7,'2026-10-15 10:00:00')"])
r = one("SELECT s.on_hand_qty_milli||'/'||s.hold_qty_milli||'/'||(s.on_hand_qty_milli-s.allocated_qty_milli-s.reserved_qty_milli-s.quality_hold_qty_milli-s.hold_qty_milli)||'/'||h.released_qty_milli||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=6101 AND direction=-1)||'/'||(SELECT on_hand_count FROM live_stock_count WHERE stock_id=6101) FROM stock s JOIN stock_hold h ON h.stock_id=s.id AND h.id=6131")[0]
ok(f"18 B2 死亡一次：在库/冻结/可用/明细已扣/−1 流水条数/只数 = {r}") if str(r) == '48800/48800/0/1200/1/118' else bad(f"18 B2 死亡一次：在库/冻结/可用/明细已扣/−1 流水条数/只数 = {r}（期望 48800/48800/0/1200/1/118）")
expect_block_tx('18 B2 死亡离线重放（同设备同 op）', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6152,1,61,6101,31,'2026-10-16','DEV-L','d-1',2,1200,125,6141,1200,7,'2026-10-15 10:00:00')"], 'ld_duplicate')
expect_block_tx('18 B2 两条死亡挂同一条流水（重复扣减依据）', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deducted_qty_milli,reported_by,reported_at) VALUES (6153,1,61,6101,31,'2026-10-16','DEV-L','d-2',2,1200,125,6141,1200,7,'2026-10-15 10:00:00')"], 'ld_duplicate')
expect_block_tx('18 B2 consume_live_hold 同一 op_key 重放', ['UPDATE stock SET hold_qty_milli = hold_qty_milli - 1200, on_hand_qty_milli = on_hand_qty_milli - 1200, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6101 AND hold_qty_milli >= 1200 AND on_hand_qty_milli >= 1200', "UPDATE stock_hold SET released_qty_milli = released_qty_milli + 1200, status = CASE WHEN released_qty_milli + 1200 = hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version = version + 1 WHERE id = 6131 AND hold_type = 'LIVE_HOLD' AND status = 'HELD' AND hold_qty_milli - released_qty_milli >= 1200", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6151R',1,'DOC',NULL)", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (6142,'LD-6151R',1,1,1,'DOC','SCRAP',-1,6101,2,1,61,3,31,NULL,NULL,NULL,NULL,1200,48800,47600,'2026-10-16','LD-6151:1:D1:1',6131)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6142,'LD-6151:1:D1:1','LD-6151R',1,1,1,'DOC',NULL,NULL,NULL,NULL,6101,2,-1,'2026-10-16')"], 'stock_movement_key.idempotency_key')
r = one("SELECT (SELECT on_hand_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT released_qty_milli FROM stock_hold WHERE id=6131)||'/'||(SELECT count(*) FROM stock_movement WHERE stock_id=6101 AND direction=-1)")[0]
ok(f"18 B2 重放回滚后不二次扣减 = {r}") if str(r) == '48800/1200/1' else bad(f"18 B2 重放回滚后不二次扣减 = {r}（期望 48800/1200/1）")
expect_block_tx('18 用非复检记录释放锁池', ["UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6112, released_at='2026-10-15 10:00:00' WHERE id=6121"], 'lth_recheck_required')
expect_allow_tx('18 P2 复检合格 → release_live_hold(6121, 6113, LTH:6121:6113, release_ids=[616131,616132]) 按本次释放行 id 汇总 + 锁池单 RELEASED', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) VALUES (6113,1,61,'DEV-L','op-3',7,'2026-10-15 10:00:00',180,600,780,'NORMAL',0,true)", "INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) SELECT v.rid, h.id, 'LTH:6121:6113:' || h.id, h.hold_qty_milli - h.released_qty_milli FROM stock_hold h JOIN (SELECT 616131 AS rid, 6131 AS hold_id UNION ALL SELECT 616132, 6132) v ON v.hold_id = h.id WHERE h.status='HELD'", "UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status='RELEASED', version=version+1 WHERE id IN (6131, 6132) AND status='HELD'", 'UPDATE stock SET hold_qty_milli = hold_qty_milli - (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND r.id IN (616131, 616132)), version=version+1 WHERE id IN (SELECT stock_id FROM stock_hold WHERE id IN (6131, 6132)) AND hold_qty_milli >= (SELECT COALESCE(SUM(r.qty_milli),0) FROM stock_hold_release r JOIN stock_hold h ON h.id=r.hold_id WHERE h.stock_id=stock.id AND r.id IN (616131, 616132))', "UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6113, released_at='2026-10-15 10:00:00' WHERE id=6121 AND status='ACTIVE'"])
r = one("SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:6121:6113:6131', 'LTH:6121:6113:6132'))||'/'||(SELECT count(*) FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=6121 AND status='RELEASED')||'/'||(SELECT count(*) FROM stock WHERE id IN (6101,6102) AND hold_qty_milli=0)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=6102)")[0]
ok(f"18 P2 整池释放：释放行/明细 RELEASED/两行 hold=0/两行在库不变 = {r}") if str(r) == '2/2/2/48800/20000' else bad(f"18 P2 整池释放：释放行/明细 RELEASED/两行 hold=0/两行在库不变 = {r}（期望 2/2/2/48800/20000）")
expect_block_tx('18 P2 release_live_hold 同一 op_key 重放', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (606131,6131,'LTH:6121:6113:6131',48800)"], 'hold_duplicate')
expect_block_tx('18 P2 释放后再释放（锁池单已关）', ["UPDATE live_tank_hold SET status='RELEASED', release_inspection_id=6113, released_at='2026-10-15 10:00:00' WHERE id=6121"], 'lth_closed')
r = one("SELECT (SELECT count(*) FROM stock_hold_release WHERE op_key IN ('LTH:6121:6113:6131', 'LTH:6121:6113:6132'))||'/'||(SELECT hold_qty_milli FROM stock WHERE id=6101)||'/'||(SELECT hold_qty_milli FROM stock WHERE id=6102)")[0]
ok(f"18 P2 重放后释放行数与汇总不变 = {r}") if str(r) == '2/0/0' else bad(f"18 P2 重放后释放行数与汇总不变 = {r}（期望 2/0/0）")
r = one("SELECT group_concat(h.id||':'||CASE WHEN h.released_qty_milli = COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id=h.id),0) + COALESCE((SELECT SUM(m.move_qty_milli) FROM stock_movement m WHERE m.hold_id=h.id AND m.direction=-1),0) THEN 'OK' ELSE 'BAD' END||':'||(SELECT count(*) FROM stock_movement m WHERE m.hold_id=h.id), '/') FROM (SELECT * FROM stock_hold WHERE source_type='LIVE_TANK_HOLD' AND source_id=6121 ORDER BY id) h")[0]
ok(f"18 LIVE_HOLD_MISMATCH 逐条明细对账：hold_id 经 stock_movement 取（6131 挂死亡流水 1 条，另一条 0 条） = {r}") if str(r) == "6131:OK:1/6132:OK:0" else bad(f"18 LIVE_HOLD_MISMATCH 逐条明细对账：hold_id 经 stock_movement 取（6131 挂死亡流水 1 条，另一条 0 条） = {r}")
expect_allow_tx('18 B5 超容差 REJECTED（42217）留痕', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6171,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00')"])
expect_allow_tx('18 B5 同一键再次 REJECTED：42217 不占幂等键，重新执行', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6172,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9600,500,9100,8,10200,1079,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00')"])
expect_allow_tx('18 B5 同一键重称通过 ACCEPTED（扣 10.0kg 8 只）', ['UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 10000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 10000', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LW-6173',1,'DOC',NULL)", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6143,'LW-6173',1,1,1,'DOC','PICK',-1,6102,1,1,61,3,32,NULL,NULL,NULL,NULL,10000,20000,10000,'2026-10-16','LW-6173:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6143,'LW-6173:1:D1:1','LW-6173',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,1,-1,'2026-10-16')", "INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6173,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10000,8,10200,197,'ACCEPTED',NULL,6143,7,'2026-10-15 10:00:00')"])
expect_block_tx('18 B5 ACCEPTED 同键重放 → 40910 LIVE_WEIGH 依据', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6174,1,'PICK',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10000,8,10200,197,'ACCEPTED',NULL,6143,7,'2026-10-15 10:00:00')"], 'lw_duplicate')
expect_allow_tx('18 B3 加工领用同 task_id/weigh_client_id 不撞拣货键（task_kind 区分）', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6175,1,'PROCESS_ISSUE',7001,1,'w-1','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00')"])
expect_block_tx('18 B3 task_kind 非法', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6176,1,'RETURN',7001,1,'w-2','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00')"], 'CHECK constraint failed: ck_lw_kind')
expect_block_tx('18 S1 REJECTED 的 result_code 不是 42217', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6177,1,'PICK',7001,1,'w-3','DEV-P','SC-01','SCALE',61,6102,3,32,9500,500,9000,8,10200,1177,'REJECTED','99999',NULL,7,'2026-10-15 10:00:00')"], 'CHECK constraint failed: ck_lw_result')
expect_block_tx('18 净重 ≠ 毛 − 皮', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) VALUES (6178,1,'PICK',7001,1,'w-4','DEV-P','SC-01','SCALE',61,6102,3,32,10500,500,10500,8,10200,294,'REJECTED','42217',NULL,7,'2026-10-15 10:00:00')"], 'CHECK constraint failed: ck_lw_qty')
expect_block_tx('18 B2 失重 LOSS 不带扣减流水', ["INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome,scrap_order_id) VALUES (6181,1,61,31,6101,'2026-10-16',48800,48500,300,62,100,'LOSS',901)"], 'CHECK constraint failed: ck_lss_outcome')
expect_allow_tx('18 超容差 → VARIANCE（不扣，挂盘点单）', ["INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome,count_order_id) VALUES (6182,1,61,31,6101,'2026-10-16',48800,46800,2000,410,100,'VARIANCE',801)"])
expect_block_tx('18 同池同批同日重复结算（→ 40910 LIVE_SHRINK）', ["INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome) VALUES (6183,1,61,31,6101,'2026-10-16',48800,48800,0,0,100,'NONE')"], 'lss_duplicate')
expect_block_tx('18 删死亡登记', ['DELETE FROM live_death WHERE id=6151'], 'append_only')
expect_block_tx('18 改称重记录', ['UPDATE live_weigh SET net_qty_milli=9000 WHERE id=6173'], 'append_only')
# 18 D1/D2（Doro 定）：死亡先落、扣减延后补扣；补扣在库不足转 EXCEPTION
expect_allow_tx('18 D1 写节点暂停：死亡先落 PENDING（6154，4.0kg，未扣）', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6154,1,61,6102,32,'2026-10-16','DEV-L','d-p1',1,4000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00')"])
expect_block_tx('18 D1 PENDING 带已扣量', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x1',1,1000,100,NULL,'PENDING',500,NULL,7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D1 DEDUCTED 不带 movement_id', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x2',1,1000,100,NULL,'DEDUCTED',1000,NULL,7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D1 DEDUCTED 已扣量 ≠ 死亡量', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x3',1,1000,100,6143,'DEDUCTED',500,NULL,7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
r = one("SELECT deduct_status||'/'||diff_qty_milli FROM v_live_death_in_transit WHERE live_death_id=6154")[0]
ok(f"18 D1 PENDING 列为在途差异（不算对平） = {r}") if str(r) == 'PENDING/4000' else bad(f"18 D1 PENDING 列为在途差异（不算对平） = {r}（期望 PENDING/4000）")
expect_allow_tx('18 D1 恢复后补扣：post_out(SCRAP) 4.0kg + PENDING→DEDUCTED 回填 movement_id', ['UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 4000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 4000', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6154',1,'DOC',NULL)", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6144,'LD-6154',1,1,1,'DOC','SCRAP',-1,6102,2,1,61,3,32,NULL,NULL,NULL,NULL,4000,10000,6000,'2026-10-16','LD-6154:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6144,'LD-6154:1:D1:1','LD-6154',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,2,-1,'2026-10-16')", "UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6144, deducted_qty_milli=4000, exception_key=NULL WHERE id=6154 AND deduct_status='PENDING'"])
expect_block_tx('18 D1 补扣重放（同 op_key）', ['UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 4000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 4000', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6146,'LD-6154',1,1,1,'DOC','SCRAP',-1,6102,2,1,61,3,32,NULL,NULL,NULL,NULL,4000,10000,6000,'2026-10-16','LD-6154:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6146,'LD-6154:1:D1:1','LD-6154',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,2,-1,'2026-10-16')", "UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6146, deducted_qty_milli=4000, exception_key=NULL WHERE id=6154 AND deduct_status='PENDING'"], 'stock_movement_key.stock_id, stock_movement_key.stock_seq')
r = one("SELECT (SELECT on_hand_qty_milli FROM stock WHERE id=6102)||'/'||(SELECT count(*) FROM stock_movement WHERE biz_no='LD-6154')||'/'||(SELECT count(*) FROM v_live_death_in_transit WHERE live_death_id=6154)")[0]
ok(f"18 D1 补扣重放只扣一次：在库/−1 流水数/在途行 = {r}") if str(r) == '6000/1/0' else bad(f"18 D1 补扣重放只扣一次：在库/−1 流水数/在途行 = {r}（期望 6000/1/0）")
expect_block_tx('18 D1 DEDUCTED 改回 PENDING', ["UPDATE live_death SET deduct_status='PENDING', movement_id=NULL, deducted_qty_milli=0 WHERE id=6154"], 'append_only')
expect_allow_tx('18 D2 死亡先落 PENDING（6155 9.0kg、6156 0.5kg）', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6155,1,61,6102,32,'2026-10-16','DEV-L','d-p2',1,9000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00')", "INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6156,1,61,6102,32,'2026-10-16','DEV-L','d-p3',1,500,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00')"])
expect_block_tx('18 D2 补扣时顺手改死亡量', ["UPDATE live_death SET deduct_status='DEDUCTED', movement_id=6144, deducted_qty_milli=4000, death_qty_milli=4000 WHERE id=6155"], 'append_only')
expect_allow_tx('18 D2 补扣在库不足（部分）：扣 6.0kg + EXCEPTION 回填 movement_id，差额 3.0kg 转 10 异常单 LDTH:6155', ['UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 6000, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = 6102 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 6000', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-6155',1,'DOC',NULL)", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6145,'LD-6155',1,1,1,'DOC','SCRAP',-1,6102,3,1,61,3,32,NULL,NULL,NULL,NULL,6000,6000,0,'2026-10-16','LD-6155:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6145,'LD-6155:1:D1:1','LD-6155',1,1,1,'DOC',NULL,NULL,NULL,NULL,6102,3,-1,'2026-10-16')", "UPDATE live_death SET deduct_status='EXCEPTION', movement_id=6145, deducted_qty_milli=6000, exception_key='LDTH:6155' WHERE id=6155 AND deduct_status='PENDING'"])
expect_allow_tx('18 D2 补扣在库为 0（零扣）：EXCEPTION、movement_id 为空，0.5kg 转异常单 LDTH:6156', ["UPDATE live_death SET deduct_status='EXCEPTION', movement_id=NULL, deducted_qty_milli=0, exception_key='LDTH:6156' WHERE id=6156 AND deduct_status='PENDING'"])
r = one("SELECT group_concat(live_death_id||':'||deduct_status||':'||diff_qty_milli||':'||CASE WHEN death_qty_milli = deducted_qty_milli + diff_qty_milli AND movement_qty_milli = deducted_qty_milli THEN 'OK' ELSE 'BAD' END, ',') FROM (SELECT * FROM v_live_death_in_transit ORDER BY live_death_id) t")[0]
ok(f"18 D2 EXCEPTION 列为差异 + 守恒（死亡量 = 已扣 + 异常量，流水量 = 已扣） = {r}") if str(r) == '6155:EXCEPTION:3000:OK,6156:EXCEPTION:500:OK' else bad(f"18 D2 EXCEPTION 列为差异 + 守恒（死亡量 = 已扣 + 异常量，流水量 = 已扣） = {r}（期望 6155:EXCEPTION:3000:OK,6156:EXCEPTION:500:OK）")
expect_block_tx('18 D2 EXCEPTION 已扣 > 0 但无 movement_id', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x4',1,1000,100,NULL,'EXCEPTION',300,'LDTH:6157',7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D2 EXCEPTION 零扣却挂流水', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x5',1,1000,100,6143,'EXCEPTION',0,'LDTH:6157',7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D2 EXCEPTION 已扣 = 死亡量（应为 DEDUCTED）', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x6',1,1000,100,6143,'EXCEPTION',1000,'LDTH:6157',7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D2 EXCEPTION 来源键前导零 LDTH:06157', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x7',1,1000,100,NULL,'EXCEPTION',0,'LDTH:06157',7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D2 EXCEPTION 来源键不是本行 id', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x8',1,1000,100,NULL,'EXCEPTION',0,'LDTH:6156',7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')
expect_block_tx('18 D2 EXCEPTION 不带来源键', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES (6157,1,61,6102,32,'2026-10-16','DEV-L','d-x9',1,1000,100,NULL,'EXCEPTION',0,NULL,7,'2026-10-15 11:00:00')"], 'ck_ld_deduct')

# 18 × 10 LDTH 全链（SQLite 单写者：应用层与 PG live_death_makeup() 同序，BEGIN IMMEDIATE 内扣库存 → 回填 live_death → WHERE NOT EXISTS 开 #5 真异常单）
def _ldth_chain(sid, ld, onhand, qhold, mid):
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(f"INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli,quality_hold_qty_milli) VALUES ({sid},1,61,3,32,{sid},'KG',{onhand},{qhold})")
    conn.execute(f"INSERT INTO live_stock_count (stock_id,location_id,lot_id,on_hand_count) VALUES ({sid},61,32,0)")
    conn.execute(f"INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,movement_id,deduct_status,deducted_qty_milli,exception_key,reported_by,reported_at) VALUES ({ld},1,61,{sid},32,'2026-10-16','DEV-L','d-c{ld}',1,1000,100,NULL,'PENDING',0,NULL,7,'2026-10-15 11:00:00')")
    conn.execute("COMMIT")
    conn.execute("BEGIN IMMEDIATE")
    st = conn.execute(f"SELECT deduct_status FROM live_death WHERE id={ld}").fetchone()[0]
    if st != 'PENDING':
        conn.execute("COMMIT"); return 'EXISTING:' + st
    death = conn.execute(f"SELECT death_qty_milli FROM live_death WHERE id={ld}").fetchone()[0]
    av = conn.execute(f"SELECT on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli FROM stock WHERE id={sid}").fetchone()[0]
    q = min(death, max(av, 0))
    if q > 0:
        n = conn.execute(f"UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - {q}, ledger_seq = ledger_seq + 1, version = version + 1 WHERE id = {sid} AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= {q}").rowcount
        seq, after = conn.execute(f"SELECT ledger_seq, on_hand_qty_milli FROM stock WHERE id={sid}").fetchone()
        conn.execute(f"INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('LD-{ld}',1,'DOC',NULL)")
        conn.execute(f"INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,container_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES ({mid},'LD-{ld}',1,1,1,'DOC','SCRAP',-1,{sid},{seq},1,61,3,32,{sid},NULL,NULL,NULL,NULL,{q},{after + q},{after},'2026-10-16','LD-{ld}:1:D1:1')")
        conn.execute(f"INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES ({mid},'LD-{ld}:1:D1:1','LD-{ld}',1,1,1,'DOC',NULL,NULL,NULL,NULL,{sid},{seq},-1,'2026-10-16')")
    stat = 'DEDUCTED' if q == death else 'EXCEPTION'
    conn.execute(f"UPDATE live_death SET deduct_status='{stat}', movement_id={mid if q > 0 else 'NULL'}, deducted_qty_milli={q}, exception_key={'NULL' if q == death else repr('LDTH:%d' % ld)} WHERE id={ld} AND deduct_status='PENDING'")
    if q < death:
        g = death - q
        conn.execute(f"INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) SELECT {mid},'EXC-{mid}',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:{ld}','{str(mid).zfill(64)}',3,32,{g},0,{-g},'2026-10-17 12:00:00',0 WHERE NOT EXISTS (SELECT 1 FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:{ld}')")
    conn.execute("COMMIT")
    return f"WON:{q}:{death - q}:3"
def _ldth_state(sid, ld):
    return one(f"SELECT (SELECT count(*) FROM stock_movement WHERE idempotency_key='LD-{ld}:1:D1:1')||'/'||(SELECT deduct_status||':'||deducted_qty_milli||':'||COALESCE(movement_id,'NULL')||':'||COALESCE(exception_key,'-') FROM live_death WHERE id={ld})||'/'||(SELECT count(*)||':'||COALESCE(max(claimed_qty_milli),0)||':'||COALESCE(max(sku_id),0) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:{ld}' AND exception_code='LIVE_DEATH_UNDEDUCTED')||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id={sid})")[0]
r1 = _ldth_chain(6941, 6961, 400, 0, 696101); s1 = _ldth_state(6941, 6961)
ok(f"18×10 LDTH 全链 在库 400/死亡 1000：{r1}，终态 {s1}") if r1 == 'WON:400:600:3' and s1 == '1/EXCEPTION:400:696101:LDTH:6961/1:600:3/0' else bad(f"18×10 LDTH 全链 400/1000：{r1} 终态 {s1}（期望 WON:400:600:3、1/EXCEPTION:400:696101:LDTH:6961/1:600:3/0）")
r2 = _ldth_chain(6942, 6962, 1000, 1000, 696201); s2 = _ldth_state(6942, 6962)
ok(f"18×10 LDTH 全链 全被质检冻结：{r2}，movement_id 为空，异常量 1000，终态 {s2}") if r2 == 'WON:0:1000:3' and s2 == '0/EXCEPTION:0:NULL:LDTH:6962/1:1000:3/1000' else bad(f"18×10 LDTH 全链 冻满：{r2} 终态 {s2}（期望 WON:0:1000:3、0/EXCEPTION:0:NULL:LDTH:6962/1:1000:3/1000）")
conn.execute("BEGIN IMMEDIATE"); _st = conn.execute("SELECT deduct_status FROM live_death WHERE id=6961").fetchone()[0]; conn.execute("COMMIT")
_n = one("SELECT count(*) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:6961'")[0]
ok(f"18×10 LDTH 补扣重放：EXISTING:{_st}，异常单仍 {_n} 张") if _st == 'EXCEPTION' and _n == 1 else bad(f"18×10 LDTH 重放：{_st}/{_n}")
# 重复 LDTH 键：断言 0 行（事务内临时去掉 trg_exc_no_replace，让 uq_exc_ldth_key 作为 ON CONFLICT 仲裁索引直接生效；删掉该索引时这里报 ON CONFLICT 无匹配约束而变红）
_trg = one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='trg_exc_no_replace'")[0]
conn.execute("BEGIN IMMEDIATE")
try:
    conn.execute("DROP TRIGGER trg_exc_no_replace")
    _ch = conn.execute("INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (696199,'EXC-696199',1,'LIVE_DEATH_UNDEDUCTED','LIVE_DEATH','LDTH:6961','" + '696199'.zfill(64) + "',3,32,600,0,-600,'2026-10-17 12:00:00',0) ON CONFLICT (source_key) WHERE source_type = 'LIVE_DEATH' DO NOTHING").rowcount
    _ch = str(_ch)
except sqlite3.Error as e:
    _ch = 'ERR:' + str(e)
conn.execute("ROLLBACK")
_n = one("SELECT count(*) FROM exception_case WHERE source_type='LIVE_DEATH' AND source_key='LDTH:6961'")[0]
_back = one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_exc_no_replace'")[0]
ok("18×10 重复 LDTH:6961 走 ON CONFLICT (source_key) WHERE LIVE_DEATH：插入 0 行，仍 1 张，触发器已回滚恢复") if _ch == '0' and _n == 1 and _back == 1 else bad(f"18×10 重复 LDTH 键：插入=[{_ch}] 张数={_n} 触发器={_back}（期望 0/1/1）")
_ix = one("SELECT sql FROM sqlite_master WHERE type='index' AND name='uq_exc_ldth_key'")
_ix = _ix[0] if _ix else None
ok("18 依赖的 uq_exc_ldth_key：UNIQUE (source_key) WHERE source_type = 'LIVE_DEATH'") if _ix and ' '.join(_ix.split()) == "CREATE UNIQUE INDEX uq_exc_ldth_key ON exception_case(source_key) WHERE source_type = 'LIVE_DEATH'" else bad(f"uq_exc_ldth_key 目录：{_ix}")

print("=== 2i. docs/11 集成：outbox 节点序号、入站报文 ===")
expect_allow('11 outbox 事件（node 3, seq 1）', "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (100,'wms.shipment.completed','SHP1','{}',1,3,1)")
expect_block('11 同节点 seq 重复（回传顺序被破坏）', "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (101,'wms.shipment.completed','SHP2','{}',1,3,1)", 'outbox_event.node_id, outbox_event.seq')
expect_allow('11 不同节点同 seq 合法', "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (102,'wms.shipment.completed','SHP3','{}',1,4,1)")
expect_block('11 outbox 非法状态', "UPDATE outbox_event SET status='LOST' WHERE id=100", 'ck_outbox_status')
expect_allow('11 入站报文落库', "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (100,'ERP','SALES_ORDER','SO-1','{}','h1')")
expect_block('11 同源同单号重复落库', "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (101,'ERP','SALES_ORDER','SO-1','{}','h2')", 'inbound_message.source, inbound_message.biz_type, inbound_message.external_no')
expect_block('11 入站报文非法状态', "UPDATE inbound_message SET status='OK' WHERE id=100", 'ck_in_msg_status')

expect_allow("11 推送日志：同单号重推各记一行（只追加，不唯一；保留 90 天）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,warehouse_id,payload_sha,payload,received_at,result_status,retain_until) VALUES (1,'ERP','SALES_ORDER','SO-1',1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00'),(2,'ERP','SALES_ORDER','SO-1',1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:05:00','DUPLICATE','2027-01-13 01:05:00')")
expect_block("11 推送日志结果取值", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (3,'ERP','SALES_ORDER','SO-3','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','OK','2027-01-13 01:00:00')", 'ck_upl_result')
expect_block("11 I1 保留期等于接收时间", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (4,'ERP','SALES_ORDER','SO-4','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-15 01:00:00')", 'ck_upl_retain')
expect_block("11 I1 保留期只有 1 秒", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (5,'ERP','SALES_ORDER','SO-5','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-15 01:00:01')", 'ck_upl_retain')
expect_block("11 I1 保留期 7 天（旧口径，现低于 90 天下限）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (6,'ERP','SALES_ORDER','SO-6','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2026-10-22 01:00:00')", 'ck_upl_retain')
expect_block("11 I1 保留期 90 天差 1 秒", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (7,'ERP','SALES_ORDER','SO-7','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 00:59:59')", 'ck_upl_retain')
expect_allow("11 I1 保留期恰好 90 天（边界放行）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (8,'ERP','SALES_ORDER','SO-8','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00')")
expect_block("11 payload_sha 大写 hex", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (9,'ERP','SALES_ORDER','SO-9','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00')", 'ck_upl_sha')
expect_block("11 payload_sha 长度 63", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (10,'ERP','SALES_ORDER','SO-10','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00')", 'ck_upl_sha')
expect_block("11 payload_sha 非 hex（z）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (11,'ERP','SALES_ORDER','SO-11','zaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','2027-01-13 01:00:00')", 'ck_upl_sha')
expect_block_tx("11 B1 只追加：UPDATE 推送日志（改结果+原文）", ["UPDATE upstream_push_log SET result_status='REJECTED', payload='x' WHERE id=1"], 'append_only_violation: upstream_push_log')
expect_block_tx("11 B1 只追加：DELETE 推送日志", ["DELETE FROM upstream_push_log WHERE id=1"], 'append_only_violation: upstream_push_log')
expect_allow("11 写一条已过保留期的旧日志（归档用例）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (20,'ERP','SALES_ORDER','SO-OLD','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','{}','2020-01-01 00:00:00','ACCEPTED','2020-04-01 00:00:00')")
expect_block_tx("11 B1 SQLite 删已过期行也拦（边缘无角色，清理走维护脚本）", ["DELETE FROM upstream_push_log WHERE id=20"], 'append_only_violation: upstream_push_log')
expect_block("11 I1 SQLite 保留期写成不可解析的字符串", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (12,'ERP','SALES_ORDER','SO-12','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15 01:00:00','ACCEPTED','never')", 'ck_upl_retain')
expect_block("11 I1 SQLite 接收时间写成不可解析的字符串", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (13,'ERP','SALES_ORDER','SO-13','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','garbage','ACCEPTED','2027-01-13 01:00:00')", 'ck_upl_retain')
expect_allow("11 I1 SQLite ISO T 写法 90 天同样放行", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (14,'ERP','SALES_ORDER','SO-14','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15T01:00:00','ACCEPTED','2027-01-13T01:00:00')")
expect_block("11 I1 SQLite ISO T 写法 89 天", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (15,'ERP','SALES_ORDER','SO-15','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15T01:00:00','ACCEPTED','2027-01-12T01:00:00')", 'ck_upl_retain')
r = one("SELECT count(*) FROM upstream_push_log WHERE id IN (1,2,8,20)")
ok(f"11 B1 绕过尝试后日志仍在（{r[0]} 行）") if r[0] == 4 else bad(f"11 日志被动过：{r}")
print("=== 2i2. docs/11 小吴 C1 死信阻塞同 biz_key / C2 409 判定 / C3 形态 A relay 补 seq ===")
expect_allow_tx('C1 同一单 3 个事件入队（OBT-C1：创建/变更/取消）', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9101,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9102,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9103,'wms.outbound.changed','OBT-C1','{}',1,0,0)"])
expect_allow_tx('C1 第 1 个事件投递成功（SENDING→SENT 2XX）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9101", "UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=datetime('now') WHERE id=9101"])
expect_allow_tx('C1 第 2 个事件进死信（SENDING→FAILED→DEAD）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9102", "UPDATE outbox_event SET status='FAILED' WHERE id=9102", "UPDATE outbox_event SET status='DEAD' WHERE id=9102"])
expect_block_tx('C1 第 3 个事件在前序 DEAD 时不能投递（验收用例）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9103"], 'outbox_bizkey_blocked')
outbox_seed_begin()  # DEAD 种子走种子路径（应用只能插入 PENDING）
expect_block_tx('C1 同一 biz_key 第二条 DEAD', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq,status) VALUES (9104,'wms.outbound.changed','OBT-C1','{}',1,0,0,'DEAD')"], 'outbox_event.biz_key')
outbox_seed_end()
expect_block_tx('C1 跳过不带审计（无人、无时间、无原因）', ["UPDATE outbox_event SET status='SKIPPED' WHERE id=9102"], 'ck_outbox_skip')
expect_block_tx('C1 跳过原因过短', ["UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='x' WHERE id=9102"], 'ck_outbox_skip')
expect_block_tx('C1 非 DEAD 事件不能直接跳过（PENDING→SKIPPED）', ["UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='下游已手工补录' WHERE id=9103"], 'outbox_illegal_transition')
expect_block_tx('C1 非 SKIPPED 行不能带跳过审计字段', ["UPDATE outbox_event SET skip_reason='下游已手工补录' WHERE id=9103"], 'ck_outbox_skip')
expect_allow_tx('C1 人工跳过死信（谁/何时/原因齐全）', ["UPDATE outbox_event SET status='SKIPPED', skipped_by=7, skipped_at='2026-10-15 03:00:00', skip_reason='下游已手工补录' WHERE id=9102"])
expect_allow_tx('C1 跳过后第 3 个事件放行', ["UPDATE outbox_event SET status='SENDING' WHERE id=9103"])
expect_block_tx('C1 SKIPPED 是终态（不能改回 PENDING）', ["UPDATE outbox_event SET status='PENDING', skipped_by=NULL, skipped_at=NULL, skip_reason=NULL WHERE id=9102"], 'outbox_illegal_transition')
outbox_seed_begin()  # DEAD 种子走种子路径（应用只能插入 PENDING）
expect_allow_tx('C1 另一单：头事件 DEAD、后续 PENDING', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq,status) VALUES (9201,'wms.outbound.changed','OBT-C1B','{}',1,0,0,'DEAD')", "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9202,'wms.outbound.changed','OBT-C1B','{}',1,0,0)"])
outbox_seed_end()
expect_block_tx('C1 重放前后续事件被阻塞', ["UPDATE outbox_event SET status='SENDING' WHERE id=9202"], 'outbox_bizkey_blocked')
expect_allow_tx('C1 重放死信成功（DEAD→PENDING→SENDING→SENT，replay_count+1）', ["UPDATE outbox_event SET status='PENDING', replay_count=replay_count+1 WHERE id=9201", "UPDATE outbox_event SET status='SENDING' WHERE id=9201", "UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=datetime('now') WHERE id=9201"])
expect_allow_tx('C1 重放成功后后续事件放行', ["UPDATE outbox_event SET status='SENDING' WHERE id=9202"])
expect_block_tx('C2 SENT 不注明依据', ["UPDATE outbox_event SET status='SENT', sent_at=datetime('now') WHERE id=9202"], 'ck_outbox_ack')
expect_block_tx('C2 SENT 依据为任意 409', ["UPDATE outbox_event SET status='SENT', ack_kind='409', sent_at=datetime('now') WHERE id=9202"], 'ck_outbox_ack')
expect_block_tx('C2 非 SENT 行带 ack_kind', ["UPDATE outbox_event SET status='FAILED', ack_kind='DUP_409' WHERE id=9202"], 'ck_outbox_ack')
expect_allow_tx('C2 下游 409 且识别为同一请求重复 → SENT(DUP_409)', ["UPDATE outbox_event SET status='SENT', ack_kind='DUP_409', sent_at=datetime('now') WHERE id=9202"])
expect_block_tx('C2 SENT 是终态（不能改回 PENDING 重发；合并 02 后先由 02 的 SENT 终态守卫拦）', ["UPDATE outbox_event SET status='PENDING', ack_kind=NULL WHERE id=9202"], 'expiry_backdate: outbox_event')
expect_allow_tx('C3 形态 A 业务事务只写 seq=0（不碰 numbering_segment）', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9301,'wms.outbound.changed','OBT-C3-9301','{}',1,9,0),(9302,'wms.outbound.changed','OBT-C3-9302','{}',1,9,0),(9303,'wms.outbound.changed','OBT-C3-9303','{}',1,9,0)"])
expect_allow_tx('C3 relay 提交后补号', ['UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 9 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 9) m WHERE outbox_event.id = r.id'])
expect_block_tx('C3 已补的 seq 不可改', ['UPDATE outbox_event SET seq=100 WHERE id=9301'], 'outbox_seq_immutable')
expect_block_tx('C3 已补的 seq 不可清零重补', ['UPDATE outbox_event SET seq=0 WHERE id=9301'], 'outbox_seq_immutable')
r = one("SELECT group_concat(id || ':' || seq, ',') FROM outbox_event WHERE node_id = 9 ")[0]
ok(f"C3 relay 按 id 顺序补 1..3（{r}）") if r == "9301:1,9302:2,9303:3" else bad(f"C3 relay 补号：{r}")
expect_allow_tx("C3 relay 重跑幂等（无 seq=0 行则不动）", ['UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 9 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 9) m WHERE outbox_event.id = r.id'])
r = one("SELECT count(*) FROM numbering_segment WHERE biz_prefix LIKE 'OUTBOX%'")[0]
ok("C3 形态 A 不再写 numbering_segment(OUTBOX:node)") if r == 0 else bad(f"numbering_segment 出现 OUTBOX 行：{r}")

print("=== 2i3. 第 11 篇 Q1：离线纸质单补录 offline_paper_record（PAPER_BACKFILL）===")
expect_allow_tx("Q1 正向：提交 PENDING（恢复联网后 14h，窗口内）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (11,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')"])
expect_allow_tx("Q1 正向：主管（≠ 申请人）审批通过", ["UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2026-10-15 11:00:00' WHERE id=11"])
expect_allow_tx("Q1 正向：过期补录落 EXPIRED 并挂异常单", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (12,1,'PDA-07','PICK_CONFIRM','PK-L2','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',5001,'PAPER_BACKFILL')"])
expect_block_tx("Q1 反向：自批（审批人 = 申请人）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (13,1,'PDA-07','PICK_CONFIRM','PK-L3','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')", "UPDATE offline_paper_record SET status='APPROVED', approver_id=7, approved_at='2026-10-15 11:00:00' WHERE id=13"], "ck_paper_sod")
expect_block_tx("Q1 反向：backfill_deadline_at ≠ 恢复联网 + 24h（写成 +12h）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (14,1,'PDA-07','PICK_CONFIRM','PK-L4','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 08:00:00','2026-10-15 07:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "ck_paper_deadline")
expect_block_tx("Q1 反向：过期后仍以 PENDING 提交", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (15,1,'PDA-07','PICK_CONFIRM','PK-L5','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "ck_paper_expired")
expect_block_tx("Q1 反向：过期但不挂异常单", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (16,1,'PDA-07','PICK_CONFIRM','PK-L6','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',NULL,'PAPER_BACKFILL')"], "ck_paper_expired")
expect_block_tx("Q1 反向：审批类型不是 PAPER_BACKFILL", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (17,1,'PDA-07','PICK_CONFIRM','PK-L7','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'SCRAP_MISREPORT')"], "ck_paper_type")
expect_block_tx("Q1 反向：APPROVED 不带审批人", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (18,1,'PDA-07','PICK_CONFIRM','PK-L8','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')", "UPDATE offline_paper_record SET status='APPROVED' WHERE id=18"], "ck_paper_approve")
expect_block_tx("Q1 反向：同仓同 biz_key 重复补录", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (19,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "offline_paper_record.warehouse_id, offline_paper_record.biz_key")
r = one("SELECT group_concat(id || ':' || status) FROM (SELECT id, status FROM offline_paper_record ORDER BY id)")[0]
ok("Q1 反向用例全部回滚，只剩 11:APPROVED、12:EXPIRED") if r == "11:APPROVED,12:EXPIRED" else bad(f"Q1 残留：{r}")
print("=== 3. §4.4 FEFO 候选池排序（视图 + 排序键）===")
rows = conn.execute(
    """
    SELECT lot_code FROM v_stock_available
    WHERE sku_id=1 AND warehouse_id=1 AND available_qty_milli > 0
      AND date(expiry_date) >= date('2026-10-15','+10 day')
    ORDER BY expiry_date ASC, remaining_life_days ASC, pick_sequence ASC, stock_id ASC
    """
).fetchall()
seq = [r[0] for r in rows]
print(f"  → 出库顺序：{' '.join(seq)}")
ok("FEFO 序列与 PG 侧完全一致") if seq == ["LOT-1008", "LOT-1008", "LOT-1012", "LOT-1014"] \
    else bad(f"FEFO 序列偏离：{seq}")
FEFO_SQL = ("SELECT stock_id FROM v_stock_available WHERE sku_id=1 AND warehouse_id=1 AND available_qty_milli > 0 "
            "AND date(expiry_date) >= date('2026-10-15','+10 day') ORDER BY expiry_date, remaining_life_days, pick_sequence, stock_id")
conn.execute("BEGIN")
conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (20,12,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',20,'RRH:20',20000,0,'HELD',0)")
c = conn.execute("UPDATE stock SET hold_qty_milli = hold_qty_milli + 20000 WHERE id = 12 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 20000").rowcount
av = one("SELECT available_qty_milli FROM v_stock_available WHERE stock_id=12")[0]
ids = [r[0] for r in conn.execute(FEFO_SQL)]
conn.execute("ROLLBACK")
ok(f"RETURN_PENDING 冻满 stock 12：hold_qty 计入、available 20000→{av}、FEFO 候选不含 12（{len(ids)} 行）") \
    if c == 1 and av == 0 and 12 not in ids and len(ids) == 3 else bad(f"RETURN_PENDING/FEFO：rc={c} av={av} ids={ids}")
AV = one("SELECT available_qty_milli FROM v_stock_available WHERE stock_id=12")[0]
ok(f"available_qty_milli = 30000 − 10000 = {AV}") if AV == 20000 else bad(f"可用量 = {AV}")

# ---------------------------------------------------------------------------
# 3. 并发防超卖（多线程 + WAL）
# ---------------------------------------------------------------------------
print("=== 4. §4.3 并发防超卖：50 线程同时扣 3 KG，起始 100 KG ===")
conn.close()

c1 = sqlite3.connect(dbf, timeout=30)
c1.execute("PRAGMA journal_mode = WAL")
c1.execute("PRAGMA busy_timeout = 30000")
c1.execute("INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (999,1,1,1,1,'KG',100000)")
c1.commit()
mode = c1.execute("PRAGMA journal_mode").fetchone()[0]
print(f"  → journal_mode = {mode}（§3.1 / RK1 要求）")
c1.close()

results: list[int] = []
lock = threading.Lock()


def worker() -> None:
    wc = sqlite3.connect(dbf, timeout=30, isolation_level=None)
    wc.execute("PRAGMA busy_timeout = 30000")
    try:
        cur = wc.execute(
            "UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 3000, ledger_seq = ledger_seq + 1, version = version + 1 "
            "WHERE id = 999 AND on_hand_qty_milli >= 3000"
        )
        with lock:
            results.append(cur.rowcount)
    except sqlite3.OperationalError as e:
        with lock:
            results.append(-1)
            print(f"    ! {e}")
    finally:
        wc.close()


threads = [threading.Thread(target=worker) for _ in range(50)]
for t in threads:
    t.start()
for t in threads:
    t.join()

succ = sum(1 for r in results if r == 1)
rej = sum(1 for r in results if r == 0)
err = sum(1 for r in results if r == -1)
conn = sqlite3.connect(dbf, isolation_level=None)  # 与开头一致：并发段重连后仍自动提交，后面的 expect_*_tx 才能自己 BEGIN
final = one("SELECT on_hand_qty_milli FROM stock WHERE id=999")[0]
ver = one("SELECT version FROM stock WHERE id=999")[0]
print(f"  → 成功 {succ} / 拒绝 {rej} / 异常 {err} / 剩余 {final} / version {ver}")
if succ == 33 and rej == 17 and err == 0 and final == 1000 and ver == 33:
    ok("SQLite 无 SELECT FOR UPDATE，条件更新同样做到不超卖、不丢更新（33×3000 + 1000 = 100000 milli）")
else:
    bad(f"并发结果偏离：succ={succ} rej={rej} err={err} final={final} version={ver}")

# ---------------------------------------------------------------------------
# 4. R2 精度规则实测
# ---------------------------------------------------------------------------
print("=== 5. §3.1 R2：NUMERIC(14,3) 在 SQLite 的亲和性实测 ===")
conn.execute("CREATE TABLE probe (v NUMERIC(14,3))")
conn.execute("INSERT INTO probe VALUES (1.2345678)")
val, typ = conn.execute("SELECT v, typeof(v) FROM probe").fetchone()
print(f"  → 存入 1.2345678，取回 {val!r}（typeof={typ}）—— 精度未被截断，退化为 REAL")
acc = conn.execute("SELECT 0.1+0.2+0.3").fetchone()[0]
print(f"  → SQLite 侧 0.1+0.2+0.3 = {acc!r}")
if typ == "real":
    ok("R2 的判断成立：SQLite 的 NUMERIC(14,3) 不保证精度，必须应用层用整数最小单位")
else:
    bad(f"R2 的判断需要修正：typeof={typ}")

conn.execute("CREATE TABLE probe2 (v_li INTEGER)")  # 以"厘"为单位的整数存法
for q in ("0.1", "0.2", "0.3"):
    conn.execute("INSERT INTO probe2 VALUES (?)", (int(Decimal(q) * 1000),))
tot = conn.execute("SELECT sum(v_li) FROM probe2").fetchone()[0]
if tot == 600:
    ok(f"整数最小单位（厘）累加 0.1+0.2+0.3 = {tot}/1000 = {tot / 1000}，精确")
else:
    bad(f"整数存法结果异常：{tot}")

print("=== 2g. docs/12 权限与审计（小赵评审 B1、I1–I7、S1 + SCRAP_MISREPORT）===")
conn.execute("INSERT INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x')")
conn.execute('UPDATE sys_user SET perm_version = 3 WHERE id = 101')
conn.execute("INSERT INTO sys_role (id,code,name) VALUES (1,'WH_SUPERVISOR','仓库主管'),(2,'CENTER_OPS','中心运维'),(3,'QC_SUPERVISOR','质检主管')")
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (1,'device.binding.approve','设备绑定审批','12'),(2,'delivery.pod.correct.approve','POD 更正审批','15'),(3,'outbound.order.cancel_after_pick.approve','拣后取消审批','04'),(4,'outbound.order.cancel_after_pick','拣后取消申请','04')")
conn.execute('INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,1),(1,2),(1,3),(1,4),(2,3)')
conn.execute("INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (2,'W2','x','20:00'),(3,'ABCDEFGH12345678','x','20:00'),(4,'SHPD01','x','20:00')")
conn.execute('INSERT INTO sys_user_role (user_id,role_id) VALUES (202,1),(202,2),(203,2),(205,3),(206,1),(207,3),(101,1),(208,1),(201,1)')
conn.execute('INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (202,1),(203,1),(204,1),(205,1),(206,1),(101,1),(201,1)')
conn.execute("INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-A','PDA',101,1)")
conn.execute("INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000111','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
conn.execute("INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1,'outbound.cancel_after_pick',7,1,1)")
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx('12 B1 INSERT OR REPLACE 覆盖审计（同 id）', ["INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq) VALUES (1,'NOTHING',7,1)"], 'append_only_violation: audit_log')
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 B1 INSERT OR REPLACE 覆盖审计（同 id）：audit_log 行数不变（{_ac} -> {_ac2}）')
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx('12 B1 INSERT OR REPLACE 借 (node_id,node_seq) 删旧行', ["INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq) VALUES (2,'NOTHING2',7,1)"], 'append_only_violation: audit_log')
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 B1 INSERT OR REPLACE 借 (node_id,node_seq) 删旧行：audit_log 行数不变（{_ac} -> {_ac2}）')
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx('12 B1 UPSERT 审计', ["INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (1,'x',7,9) ON CONFLICT(id) DO UPDATE SET action='y'"], 'append_only_violation: audit_log')
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 B1 UPSERT 审计：audit_log 行数不变（{_ac} -> {_ac2}）')
_sig_sql = 'SELECT ' + " || '|' || ".join(f'quote({c[1]})' for c in conn.execute('PRAGMA table_info(audit_log)')) + ' FROM audit_log WHERE id=1'; _ah = (conn.execute(_sig_sql).fetchone() or (None,))[0]   # 全列 quote() 拼接，NULL 安全
expect_block_tx('12 audit_log 只追加（UPDATE）', ["UPDATE audit_log SET reason='x' WHERE id=1"], 'append_only_violation: audit_log')
_ah2 = (conn.execute(_sig_sql).fetchone() or (None,))[0]; ok('12 audit_log 只追加（UPDATE）：id=1 行内容不变（全列 quote 签名，非 NULL）') if (_ah is not None and _ah2 == _ah) else bad(f'12 audit_log 只追加（UPDATE）：id=1 行内容变了或签名为 NULL：{_ah!r} -> {_ah2!r}')
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx('12 audit_log 只追加（DELETE）', ['DELETE FROM audit_log WHERE id=1'], 'append_only_violation: audit_log')
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 audit_log 只追加（DELETE）：audit_log 行数不变（{_ac} -> {_ac2}）')
expect_allow_tx('12 B1 正向：新 (node_id,node_seq) 追加', ["INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (3,'x',7,2)"])
expect_block_tx('12 同一设备实例两条 PENDING/ACTIVE 绑定', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (2,'DEV-A','PDA',102,1)"], 'binding_duplicate')
expect_block_tx('12 I3 REPLACE 覆盖绑定', ["INSERT OR REPLACE INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-Z','PDA',99,1)"], 'binding_duplicate')
expect_block_tx('12 I3 直接插成 ACTIVE', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,status,activated_at,approval_id) VALUES (3,'DEV-C','PDA',101,1,'ACTIVE','2026-10-15 08:00',1)"], 'binding_insert_not_pending')
expect_block_tx('12 REVOKED 没有吊销时间', ["UPDATE user_device_binding SET status='REVOKED' WHERE id=1"], 'ck_udb_status')
expect_block_tx('12 I3 用不存在的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=999, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (7,'APR-WHSH01-20261015-000007','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=101, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=7")
expect_block_tx('12 S1 审批人 = 绑定使用人', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=7, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (8,'APR-WHSH01-20261015-000008','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='REJECTED', decided_at='2026-10-15 09:00', reject_reason='x' WHERE id=8")
expect_block_tx('12 I3 用已驳回的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=8, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (9,'APR-WHSH01-20261015-000909','CANCEL_AFTER_PICK',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=9")
expect_block_tx('12 I3 用别的类型的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=9, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (10,'APR-WHSH01-20261015-000010','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=10")
expect_allow_tx('12 I3 正向：DEVICE_BIND 已通过、审批人≠使用人 → PENDING→ACTIVE', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=10, activated_at='2026-10-15 09:00' WHERE id=1 AND status='PENDING'"])
expect_block_tx('12 I3 绑定换人', ['UPDATE user_device_binding SET user_id=99 WHERE id=1'], 'binding_immutable')
expect_block_tx('12 I3 ACTIVE 退回 PENDING', ["UPDATE user_device_binding SET status='PENDING', activated_at=NULL WHERE id=1"], 'binding_immutable')
expect_allow_tx('12 I3 正向：吊销', ["UPDATE user_device_binding SET status='REVOKED', revoked_at='2026-10-15 10:00', revoke_reason='LOST' WHERE id=1"])
expect_block_tx('12 I3 REVOKED 复活', ["UPDATE user_device_binding SET status='ACTIVE', revoked_at=NULL WHERE id=1"], 'binding_immutable')
expect_block_tx('12 绑定不可删除', ['DELETE FROM user_device_binding WHERE id=1'], 'append_only_violation: user_device_binding')
# 逐表整表 DELETE（SQLite 没有 TRUNCATE，对应 PG 的单表 TRUNCATE 用例）：必须被只追加触发器挡下，且行数不变
_k0 = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_apr_code_referenced_del'").fetchone()[0]
for _t in ('approval_request', 'user_device_binding', 'audit_log'):
    conn.commit(); _n0 = conn.execute(f'SELECT count(*) FROM {_t}').fetchone()[0]
    # approval_request 另有模拟外键的 trg_apr_code_referenced_del 会先拦；同 PG，在同一事务内先拆掉它（DDL 随 ROLLBACK 恢复），确保命中只追加触发器
    _pre = ['DROP TRIGGER IF EXISTS trg_apr_code_referenced_del'] if _t == 'approval_request' else []
    expect_block_tx(f'12 整表 DELETE {_t} 被只追加触发器拦下', _pre + [f'DELETE FROM {_t}'], f'append_only_violation: {_t}')
    conn.commit(); _n1 = conn.execute(f'SELECT count(*) FROM {_t}').fetchone()[0]
    (ok if _n0 == _n1 else bad)(f'12 整表 DELETE {_t} 后行数不变（{_n0} -> {_n1}）')
_k = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_apr_code_referenced_del'").fetchone()[0]
(ok if _k == _k0 else bad)(f'12 整表 DELETE 用例回滚后 trg_apr_code_referenced_del 状态不变（{_k0} -> {_k}）')
expect_block_tx('12 离线令牌到期早于签发', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (2,'J2',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 07:00')"], 'ck_offline_ttl')
expect_block_tx('12 I4 离线令牌 30 天', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (3,'J3',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-11-14 08:00')"], 'ck_offline_max_ttl')
expect_allow_tx('12 I4 正向：恰好 12 小时', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (4,'J4',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"])
expect_block_tx('12 离线令牌 jti 重复', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (5,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"], 'offline_token_duplicate')
expect_block_tx('12 I4 REPLACE 覆盖令牌', ["INSERT OR REPLACE INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"], 'offline_token_duplicate')
expect_block_tx('12 I4 延长有效期', ["UPDATE offline_token SET expires_at='2026-10-15 19:00' WHERE id=1"], 'offline_token_immutable')
expect_allow_tx('12 I4 正向：吊销', ["UPDATE offline_token SET revoked_at='2026-10-15 10:00' WHERE id=1"])
expect_block_tx('12 I4 吊销后恢复', ['UPDATE offline_token SET revoked_at=NULL WHERE id=1'], 'offline_token_immutable')
expect_block_tx('12 I2 直接插成 APPROVED', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at,status) VALUES (20,'APR-WHSH01-20261015-000020','POD_CORRECT',1,'POD','20','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01','APPROVED')"], 'approval_insert_not_pending')
expect_block_tx('12 同一目标两条待审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (21,'APR-WHSH01-20261015-000021','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,'2099-01-01')"], 'approval_duplicate')
expect_block_tx('12 I1 REPLACE 改写审批（同 id）', ["INSERT OR REPLACE INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'approval_duplicate')
expect_block_tx('12 I1 UPSERT 改写审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','9','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01') ON CONFLICT(id) DO UPDATE SET status='PENDING'"], 'approval_duplicate')
expect_block_tx('12 SoD：申请人自己审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1"], 'ck_apr_sod')
expect_block_tx('12 I2 单人审批进 PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=1"], 'ck_apr_partial')
expect_block_tx('12 I2 审批人三列不成组', ['UPDATE approval_request SET first_approver_id=202 WHERE id=1'], 'ck_apr_pair')
expect_block_tx('12 I2 REJECTED 没有 decided_at', ["UPDATE approval_request SET status='REJECTED' WHERE id=1"], 'ck_apr_decided')
expect_allow_tx('12 正向：主管审批通过', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1"])
expect_block_tx('12 I1/I2 APPROVED 改回 PENDING', ["UPDATE approval_request SET status='PENDING', decided_at=NULL WHERE id=1"], 'approval_final')
expect_block_tx('12 审批不可删除', ['DELETE FROM approval_request WHERE id=1'], 'append_only_violation: approval_request')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (4,'APR-WHSH01-20261015-000114','POD_CORRECT',1,'POD','4','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2020-01-01')")
expect_block_tx('12 I2 过期后审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=4"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (41,'APR-WHSH01-20261015-000041','POD_CORRECT',1,'POD','41','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','-1 minutes'))")
expect_block_tx('12 UTC 反向：expires_at = UTC 当前 −1 分钟，已过期不能再批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=41"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (42,'APR-WHSH01-20261015-000042','POD_CORRECT',1,'POD','42','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','+2 hours'))")
expect_allow_tx('12 UTC 正向：expires_at = UTC 当前 +2 小时（比本地 UTC+8 早）仍可批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=42"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (3,'APR-WHSH01-20261015-000903','UNPLANNED_FAILOVER',1,'WAREHOUSE','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
expect_block_tx('12 I5 第一确认人不持有任何角色', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 I5 第一确认人只有 CENTER_OPS 却写 WH_SUPERVISOR', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=203, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"], 'approval_role_not_held')
expect_allow_tx('12 I5 正向：真主管确认 → PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"])
expect_block_tx('12 I2 换第一审批人', ['UPDATE approval_request SET first_approver_id=203 WHERE id=3'], 'approval_approver_immutable')
expect_block_tx('12 I2 PARTIAL 倒退 PENDING', ["UPDATE approval_request SET status='PENDING' WHERE id=3"], 'approval_transition_invalid')
expect_block_tx('12 I5 第二确认人不持有 CENTER_OPS', ["UPDATE approval_request SET second_approver_id=204, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 第二确认人 = 第一确认人', ["UPDATE approval_request SET second_approver_id=202, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3"], 'ck_apr_dual')
expect_block_tx('12 非计划切换只有一人确认就 APPROVED', ["UPDATE approval_request SET status='APPROVED', decided_at='2026-10-15 09:30' WHERE id=3"], 'ck_apr_done')
expect_allow_tx('12 I5 正向：中心运维第二确认 → APPROVED', ["UPDATE approval_request SET status='APPROVED', second_approver_id=203, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30', decided_at='2026-10-15 09:30' WHERE id=3"])
expect_block_tx('12 SM 发起人不是本仓仓库主管（只有 CENTER_OPS）', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (23,'APR-WHSH01-20261015-000023','SCRAP_MISREPORT',1,'SCRAP_ORDER','9009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,'2099-01-01')"], 'approval_role_not_held')
expect_block_tx('12 SM 发起人是质检主管而非仓库主管', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (24,'APR-WHSH01-20261015-000024','SCRAP_MISREPORT',1,'SCRAP_ORDER','9010','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',205,'2099-01-01')"], 'approval_role_not_held')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (5,'APR-WHSH01-20261015-000005','SCRAP_MISREPORT',1,'SCRAP_ORDER','9001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,'2099-01-01')")
expect_block_tx('12 SM 发起人自己审批（202 兼 CENTER_OPS 也不行）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'ck_apr_sod')
expect_block_tx('12 SM 审批角色写成仓库主管（另一主管 206 不具审批权）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=206, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'ck_apr_scrap_roles')
expect_block_tx('12 SM 审批人不持有 QC_SUPERVISOR 却写质检主管', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'approval_role_not_held')
expect_block_tx('12 SM 质检主管不在本仓', ["UPDATE approval_request SET status='APPROVED', first_approver_id=207, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'approval_role_not_held')
expect_allow_tx('12 SM 正向：本仓质检主管审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (6,'APR-WHSH01-20261015-000006','SCRAP_MISREPORT',1,'SCRAP_ORDER','9002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',206,'2099-01-01')")
expect_allow_tx('12 SM 正向：中心运维审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=6"])
expect_block_tx('12 审批单号格式：旧格式 SM-2026-001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (30,'SM-2026-001','CANCEL_AFTER_PICK',1,'OUTBOUND','30','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期 7 位 APR-WHSH01-2026101-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (31,'APR-WHSH01-2026101-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','31','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号 5 位 APR-WHSH01-20261015-00001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (32,'APR-WHSH01-20261015-00001','CANCEL_AFTER_PICK',1,'OUTBOUND','32','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码为空 APR--20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (33,'APR--20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','33','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期含字母 APR-WHSH01-2026A015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (34,'APR-WHSH01-2026A015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','34','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：月份 13 APR-WHSH01-20261315-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (35,'APR-WHSH01-20261315-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','35','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号含字母 APR-WHSH01-20261015-00000X', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (36,'APR-WHSH01-20261015-00000X','CANCEL_AFTER_PICK',1,'OUTBOUND','36','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：前缀小写 apr-WH01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (37,'apr-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','37','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码含 - APR-WH-01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (38,'APR-WH-01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','38','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_allow_tx('12 审批单号格式正向：APR-SHPD01-20261231-999999', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (40,'APR-SHPD01-20261231-999999','POD_CORRECT',4,'POD','40','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"])
expect_block_tx('12 审批类型不在码表', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (22,'APR-WHSH01-20261015-000022','BANANA',1,'X','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_type')
expect_block_tx('12 perm_version 回退', ['UPDATE sys_user SET perm_version = 1 WHERE id = 101'], 'perm_version_rewind')
expect_block_tx('12 I7 REPLACE 把 perm_version 打回 1', ["INSERT OR REPLACE INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x')"], 'sys_user_duplicate')
expect_allow_tx('12 I7 正向：perm_version 前进', ['UPDATE sys_user SET perm_version = 4 WHERE id = 101'])
expect_block_tx('12 T1 审批单号：仓库编码小写 APR-sh01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (50,'APR-sh01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','50','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码含下划线 APR-S_01-20261015-000002', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (51,'APR-S_01-20261015-000002','CANCEL_AFTER_PICK',1,'OUTBOUND','51','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码含空格 APR-S 01-20261015-000003', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (52,'APR-S 01-20261015-000003','CANCEL_AFTER_PICK',1,'OUTBOUND','52','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码长度 1 APR-A-20261015-000004', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (53,'APR-A-20261015-000004','CANCEL_AFTER_PICK',1,'OUTBOUND','53','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码长度 17 APR-ABCDEFGHIJKLMNOPQ-20261015-000005', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (54,'APR-ABCDEFGHIJKLMNOPQ-20261015-000005','CANCEL_AFTER_PICK',1,'OUTBOUND','54','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_allow_tx('12 T1 正向：仓库编码长度 2 / 16', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (56,'APR-W2-20261015-000006','POD_CORRECT',2,'POD','56','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')", "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (57,'APR-ABCDEFGH12345678-20261015-000007','POD_CORRECT',3,'POD','57','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (60,'APR-WHSH01-20261015-000060','DEVICE_BIND',1,'DEVICE_BINDING','60','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (61,'APR-WHSH01-20261015-000061','POD_CORRECT',1,'POD','61','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (62,'APR-WHSH01-20261015-000062','CANCEL_AFTER_PICK',1,'OUTBOUND','62','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
expect_block_tx('12 T2 DEVICE_BIND：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 POD_CORRECT：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61"], 'approval_perm_not_held')
expect_block_tx('12 T2 CANCEL_AFTER_PICK：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=62"], 'approval_perm_not_held')
expect_block_tx('12 T2 DEVICE_BIND：角色存在但无该权限点（203 CENTER_OPS）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 DEVICE_BIND：有主管角色但不在本仓（208）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=208, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 POD_CORRECT：质检主管无该权限点（205）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61"], 'approval_perm_not_held')
expect_allow_tx('12 T2 正向：本仓主管经 sys_role_perm 持有 device.binding.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=60"])
expect_allow_tx('12 T2 正向：本仓主管持有 delivery.pod.correct.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=61"])
expect_allow_tx('12 T2 正向：本仓主管持有 outbound.order.cancel_after_pick.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=62"])
conn.execute("INSERT INTO sys_role (id,code,name) VALUES (4,'CS','客服')")
conn.execute('INSERT INTO sys_role_perm (role_id,perm_id) VALUES (4,4)')
conn.execute('INSERT INTO sys_user_role (user_id,role_id) VALUES (209,4),(210,2)')
conn.execute('INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (209,1)')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (63,'APR-WHSH01-20261015-000063','CANCEL_AFTER_PICK',1,'OUTBOUND','63','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',209,'2099-01-01')")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (64,'APR-WHSH01-20261015-000064','CANCEL_AFTER_PICK',1,'OUTBOUND','64','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,'2099-01-01')")
expect_block_tx('12 拣后取消：只有申请权限 cancel_after_pick（客服 209）不能审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=209, first_approver_role='CS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64"], 'approval_perm_not_held')
expect_block_tx('12 拣后取消：申请人 202（持有 .approve）审批自己的单', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64"], 'ck_apr_sod')
expect_allow_tx('12 拣后取消正向：不在本仓的 CENTER_OPS（210，数据范围 ALL）审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=210, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=63"])
expect_allow_tx('12 拣后取消正向：另一位本仓主管 201 审批 202 的申请', ["UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=64"])
expect_block_tx('12 单号仓库编码 WH01 ≠ 仓 1 的 WHSH01', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (65,'APR-WH01-20261015-000065','POD_CORRECT',1,'POD','65','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'approval_code_warehouse_mismatch')
expect_block_tx('12 单号写 W2 但挂在仓 1', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (66,'APR-W2-20261015-000066','POD_CORRECT',1,'POD','66','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'approval_code_warehouse_mismatch')
expect_block_tx('12 所属仓不存在（warehouse_id=99）', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (67,'APR-WHSH01-20261015-000067','POD_CORRECT',99,'POD','67','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'approval_code_warehouse_mismatch')
expect_allow_tx('12 单号仓库编码正向：APR-WHSH01-… 挂仓 1', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (68,'APR-WHSH01-20261015-000068','POD_CORRECT',1,'POD','68','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"])


print("=== 2g2. 新审批类型（PAPER_BACKFILL/BOX_VOID/PROCESS_YIELD_DEVIATION/LIVE_DEATH_OVER/PROCESS_REWORK）+ audit node 必填 ===")
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (11,'offline.paper.approve','纸质补录审批','00'),(12,'pack.box.void.approve','作废箱审批','06'),(13,'process.yield.approve','得率偏离审批','17'),(14,'live.death.approve','活鲜死亡超阈值审批','18'),(15,'process.rework.approve','加工返工审批','17')")
conn.execute("INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,11),(1,12),(1,13),(1,14),(1,15)")
_H = "a" * 64
for _i, _t in enumerate(["PAPER_BACKFILL", "BOX_VOID", "PROCESS_YIELD_DEVIATION", "LIVE_DEATH_OVER", "PROCESS_REWORK"]):
    for _id, _req in ((81 + _i, 201), (86 + _i, 202)):
        conn.execute(
            "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) "
            f"VALUES ({_id},'APR-WHSH01-20261015-0000{_id}','{_t}',1,'{_t}','{_id}','{{}}','{_H}','r',{_req},'2099-01-01')"
        )
conn.commit()
_APP = "UPDATE approval_request SET status='APPROVED', first_approver_id={u}, first_approver_role='{r}', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id={i}"
for _i, _t in enumerate(["PAPER_BACKFILL", "BOX_VOID", "PROCESS_YIELD_DEVIATION", "LIVE_DEATH_OVER", "PROCESS_REWORK"]):
    expect_block_tx(f"12 {_t}：无该审批权限点（质检主管 205）", [_APP.format(u=205, r="QC_SUPERVISOR", i=81 + _i)], "approval_perm_not_held")
    expect_block_tx(f"12 {_t}：申请人 202 自批", [_APP.format(u=202, r="WH_SUPERVISOR", i=86 + _i)], "ck_apr_sod")
    expect_allow_tx(f"12 {_t} 正向：本仓主管 202 审批 201 的申请", [_APP.format(u=202, r="WH_SUPERVISOR", i=81 + _i)])
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx("12 audit_log 新写入省略 node_id/node_seq（默认 0）→ 40001", ["INSERT INTO audit_log (id,action,warehouse_id) VALUES (900,'x',1)"], "audit_node_required: 40001")
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 audit_log 新写入省略 node_id/node_seq（默认 0）→ 40001：audit_log 行数不变（{_ac} -> {_ac2}）')
_ac = one('SELECT count(*) FROM audit_log')[0]
expect_block_tx("12 audit_log node_seq=0 → 40001", ["INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (901,'x',7,0,1)"], "audit_node_required: 40001")
_ac2 = one('SELECT count(*) FROM audit_log')[0]; (ok if _ac2 == _ac else bad)(f'12 audit_log node_seq=0 → 40001：audit_log 行数不变（{_ac} -> {_ac2}）')
expect_allow_tx("12 audit_log node_id/node_seq > 0 正向", ["INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (902,'x',7,902,1)"])
expect_block_tx("12 stock_hold.approval_no 没有对应审批单", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (990,41,'RETURN_QC','RETURN_QC','QC',7990,'CVT:990',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000990',1)"], "fk_hold_approval_no")
expect_allow_tx("12 stock_hold.approval_no 指向已有审批单", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no,is_reversal) VALUES (991,41,'RETURN_QC','RETURN_QC','QC',7991,'CVT:991',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-WHSH01-20261015-000123',1)"])

print("=== 2h-apr. 第 17 篇 × 第 12 篇：PROCESS_YIELD_DEVIATION / PROCESS_REWORK 审批权限与 SoD（放在 #9「2g3. stock_hold.approval_no」段之后；树里没有 #9 时整段跳过；权限点 process.yield.approve / process.rework.approve 用 #9 verify 种子，本段不插） ===")
def b17(desc, sql, want):
    try:
        conn.execute(sql); conn.commit(); bad(f'{desc} → 未拦截（SQLite 侧有洞）')
    except sqlite3.IntegrityError as e:
        conn.rollback(); msg = str(e)
        ok(f'{desc} → 已拦截（{msg}）') if (msg == want or msg.endswith(': ' + want)) else bad(f'{desc} → 被拦了但约束不对：期望 {want!r}，实际 {msg!r}')
try:
    _n = one("SELECT count(*) FROM sys_permission WHERE code IN ('process.yield.approve','process.rework.approve')")[0]
except sqlite3.OperationalError:
    _n = 0
_has12b = any(r[1] == 'approval_type' for r in conn.execute("PRAGMA table_info(approval_request)").fetchall())
if _n == 0 and not _has12b:
    ok("17×12 跳过：树里没有 #9（无 12b approval_request、无权限点种子），本段不自建")
elif _n == 0:
    bad("17×12 前置：已加载 #9 的 12b，但本段跑在 #9 种子之前（权限点 0/2）——本段须放在 #9「2g2. 新审批类型」/「2g3. stock_hold.approval_no」之后")
elif _n != 2:
    bad(f"17×12 前置：#9 权限点种子不全（{_n}/2）")
else:
    ok("17×12 前置：#9 种子已有 process.yield.approve / process.rework.approve（本段不自建）")
    expect_allow_tx('17×12 审批种子：申请人 1731（也持 PROC_LEAD）、无权审批人 1732（WH_SUPERVISOR 无 process.yield.approve）、加工主管 1733（PROC_LEAD 持有）', ["INSERT INTO sys_user (id,username,password_hash) VALUES (1731,'u1731','x'),(1732,'u1732','x'),(1733,'u1733','x')", "INSERT INTO sys_role (id,code,name) VALUES (1731,'WH_SUPERVISOR_17','仓库主管'),(1732,'PROC_LEAD','加工主管')", "INSERT INTO sys_role_perm (role_id,perm_id) SELECT 1732, id FROM sys_permission WHERE code = 'process.yield.approve'", 'INSERT INTO sys_user_role (user_id,role_id) VALUES (1732,1731),(1733,1732),(1731,1732)', 'INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1731,1),(1732,1),(1733,1)', "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1732,'APR-WHSH01-20261015-000032','PROCESS_YIELD_DEVIATION',1,'PROCESS_ORDER','1711','{}','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc','出成率 43.8% 越界',1731,'2099-01-01 00:00:00')"])
    b17('17×12 无 process.yield.approve 的人批 PROCESS_YIELD_DEVIATION', "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732", 'approval_perm_not_held')
    b17('17×12 报工人自己批（SoD）', "UPDATE approval_request SET status='APPROVED', first_approver_id=1731, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732", 'ck_apr_sod')
    expect_allow_tx('17×12 加工主管批 PROCESS_YIELD_DEVIATION', ["UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:30:00', decided_at='2026-10-15 05:30:00' WHERE id=1732"])
    expect_allow_tx('17×12 返工审批种子：发起人 1734（权限点 process.yield.approve / process.rework.approve 复用 #9 种子，不自建；PROC_REWORKER，持 process.order.reverse 且也持 process.rework.approve，专测 SoD）；1733 PROC_LEAD 加持 process.rework.approve', ["INSERT INTO sys_user (id,username,password_hash) VALUES (1734,'u1734','x')", "INSERT INTO sys_role (id,code,name) VALUES (1734,'PROC_REWORKER','加工返工发起')", "INSERT INTO sys_permission (id,code,name,module) VALUES (1734,'process.order.reverse','加工冲回/返工发起','process')", "INSERT INTO sys_role_perm (role_id,perm_id) SELECT r.rid, p.id FROM (SELECT 1734 AS rid, 'process.order.reverse' AS pc UNION ALL SELECT 1734, 'process.rework.approve' UNION ALL SELECT 1732, 'process.rework.approve') r JOIN sys_permission p ON p.code = r.pc", 'INSERT INTO sys_user_role (user_id,role_id) VALUES (1734,1734)', 'INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1734,1)', "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1735,'APR-WHSH01-20261015-000035','PROCESS_REWORK',1,'PROCESS_ORDER','1711','{}','dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd','产出 1759 返工',1734,'2099-01-01 00:00:00')"])
    b17('17×12 返工：无 process.rework.approve 的人（1732 仓库主管）批 PROCESS_REWORK', "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735", 'approval_perm_not_held')
    b17('17×12 返工 SoD：发起人 1734 自己批（即使持 process.rework.approve）', "UPDATE approval_request SET status='APPROVED', first_approver_id=1734, first_approver_role='PROC_REWORKER', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735", 'ck_apr_sod')
    expect_allow_tx('17×12 返工：加工主管 1733 批 PROCESS_REWORK', ["UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at='2026-10-15 05:40:00', decided_at='2026-10-15 05:40:00' WHERE id=1735"])
print("=== 6. 小吴 C3 形态 A 并发：业务事务只写 seq=0，relay 提交后补号 ===")
conn.commit()  # 前面第 5 节在主连接上留有隐式事务，先提交释放写锁
RELAY8 = 'UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id'
cc_err = []
def cc_ins(i):
    wc = sqlite3.connect(dbf, timeout=30, isolation_level=None)
    wc.execute("PRAGMA busy_timeout = 30000")
    try:
        wc.execute("BEGIN IMMEDIATE")
        wc.execute(f"INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES ({9500+i},'t','OBT-CC-{i}','{{}}',1,8,0)")
        wc.execute("COMMIT")
    except sqlite3.Error as e:
        cc_err.append(str(e))
    finally:
        wc.close()
def cc_relay():
    wc = sqlite3.connect(dbf, timeout=30, isolation_level=None)
    wc.execute("PRAGMA busy_timeout = 30000")
    try:
        wc.execute("BEGIN IMMEDIATE"); wc.execute(RELAY8); wc.execute("COMMIT")
    except sqlite3.Error as e:
        cc_err.append(str(e))
    finally:
        wc.close()
ths = [threading.Thread(target=cc_ins, args=(i,)) for i in range(1, 41)] + [threading.Thread(target=cc_relay) for _ in range(5)]
for t in ths: t.start()
for t in ths: t.join()
cc_relay()
conn = sqlite3.connect(dbf)
r = one("SELECT count(*) || '/' || count(DISTINCT seq) || '/' || min(seq) || '/' || max(seq) || '/' || sum(CASE WHEN seq = 0 THEN 1 ELSE 0 END) FROM outbox_event WHERE node_id = 8")[0]
ok(f"C3 40 并发事务 + 5 个并发 relay：seq 连续 1..40、无重复、无漏补、无报错（{r}）") if r == "40/40/1/40/0" and not cc_err else bad(f"C3 并发补号：{r} {cc_err[:3]}")
r = one("SELECT count(*) FROM numbering_segment WHERE biz_prefix LIKE 'OUTBOX%'")[0]
ok("C3 并发期间业务事务未触碰 numbering_segment（无单行热点）") if r == 0 else bad(f"numbering_segment 出现 OUTBOX 行：{r}")
try:
    conn.execute("UPDATE outbox_event SET seq = 1 WHERE id = (SELECT id FROM outbox_event WHERE node_id = 8 AND seq = 2)"); conn.commit()
    bad("C3 并发补号后改 seq 未拦截")
except sqlite3.IntegrityError as e:
    conn.rollback()
    ok(f"C3 并发补号后重复 seq（同节点） → 已拦截（{e}）") if "outbox_seq_immutable" in str(e) else bad(f"C3 改 seq 拦错：{e}")
# 边缘 SQLite 单写者：BEGIN IMMEDIATE 串行，业务事务内取号不会出现"小 seq 后提交"；文档 §4.3 说明
print("=== 汇总 ===")
print(f"  通过 {passed} 项 / 失败 {failed} 项")
conn.close()
Path(dbf).unlink(missing_ok=True)
for p in (dbf + "-wal", dbf + "-shm"):
    Path(p).unlink(missing_ok=True)
sys.exit(0 if failed == 0 else 1)
