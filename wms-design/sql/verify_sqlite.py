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
PG_SQL = ROOT / "sql" / "schema_postgres.sql"
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


if not PG_SQL.is_file():
    print(f"  ✗ 找不到 {PG_SQL}")
    sys.exit(1)
src = PG_SQL.read_text(encoding="utf-8")
sqlite_ddl, deltas = translate(src)
OUT_SQL.write_text(
    "-- 本文件由 sql/verify_sqlite.py 从 schema_postgres.sql 机械生成，请勿手改。\n"
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
EXPECT_TABLES, EXPECT_VIEWS = 46, 1  # docs/12 +3
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
        if msg.endswith(": " + want):
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
    "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WH-SH-01','上海青浦仓','20:00',-1)",
    "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK'),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010')",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10)",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16)",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (11,1,1,1,2,'KG',50000,0),(12,1,2,1,1,'KG',30000,10000),(13,1,3,1,3,'KG',200000,0),(14,1,3,1,1,'KG',80000,0)",
    "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (1,1,1,1,1,100000,-30000,68000)",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')",
]
for s in seed:
    conn.execute(s)
conn.commit()
ok("种子数据写入（含 TIME/DATE/TIMESTAMP/BOOLEAN/NUMERIC 列，未做任何列型改写）")

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
expect_allow_tx('convert_hold 准备：stock 40 被 RETURN_PENDING 冻满（available=0）', ["INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,hold_qty_milli) VALUES (40,1,2,1,3,'KG',5000,5000)", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (30,40,'RETURN_PENDING','RETURN_PENDING','RETURN_RECORD',601,'RRH:601',5000,0,'HELD',0)"])
expect_allow_tx('convert_hold：available=0 时 RETURN_PENDING → SCRAP_PENDING/SCRAP（source_id = 报损单 9001）', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 30 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (31,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0)"])
expect_block_tx('convert_hold 重试：CVT:30 已存在（幂等；SQLite 由 trg_hold_no_replace 先拦，PG 由 uq_hold_op）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (32,40,'SCRAP_PENDING','SCRAP','SCRAP',9001,'CVT:30',5000,0,'HELD',0)"], 'hold_duplicate')
r = one("SELECT s.hold_qty_milli, v.available_qty_milli, (SELECT COALESCE(SUM(hold_qty_milli - released_qty_milli),0) FROM stock_hold WHERE stock_id=40 AND status='HELD' AND hold_type IN ('MANUAL','RETURN_PENDING','SCRAP_PENDING')) FROM stock s JOIN v_stock_available v ON v.stock_id=s.id WHERE s.id=40")
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
expect_allow_tx('A3 convert_hold QUALITY → SCRAP_PENDING（跨列：同事务 quality_hold −q、hold_qty +q）', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 51 AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (52,41,'SCRAP_PENDING','SCRAP','SCRAP',9101,'CVT:51',3000,0,'HELD',0)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 3000, hold_qty_milli = hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 3000"])
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"A3 QUALITY 转后 quality/hold/available = {tuple(r)}（冻结总量 8000 与可用量不变）") if tuple(r) == (5000, 3000, 1000) else bad(f"A3 QUALITY 转后 {r}")
expect_allow_tx('A3 convert_hold RETURN_QC 剩余 5000 → SCRAP_PENDING', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 50 AND status = 'HELD' AND released_qty_milli = 1000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (53,41,'SCRAP_PENDING','SCRAP','SCRAP',9102,'CVT:50',5000,0,'HELD',0)", "UPDATE stock SET quality_hold_qty_milli = quality_hold_qty_milli - 5000, hold_qty_milli = hold_qty_milli + 5000, version = version + 1 WHERE id = 41 AND quality_hold_qty_milli >= 5000"])
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
r = conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)").fetchall()
ok("S6 I3e 对账：RETURN_QC 已释放 = Σ释放记录 + 转报损量（无差异行）") if r == [] else bad(f"I3e 差异 {r}")
conn.execute("BEGIN")
conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (55,41,'RETURN_QC','RETURN_QC','QC',7003,'RQC:7003',2000,0,'HELD',0)"); conn.execute("UPDATE stock_hold SET released_qty_milli = 500, version = version + 1 WHERE id = 55")
r = [x[0] for x in conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)").fetchall()]
conn.execute("ROLLBACK")
ok("S6 I3e 反向：绕过释放记录直接 UPDATE 释放 → 对账查出 hold 55") if r == [55] else bad(f"I3e 未查出：{r}")
expect_allow_tx('Q2 准备：去重记录（未过期/已过期）+ outbox（PENDING / 8 天前 SENT / 刚 SENT）', ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','h','{}',200,datetime('now','+1 day')),('dead','h','{}',200,datetime('now','-1 hour'))", "INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8801,'t','k','{}','PENDING',NULL),(8802,'t','k','{}','SENT',datetime('now','-8 days')),(8803,'t','k','{}','SENT',datetime('now'))"])
expect_block_tx('Q2 删未过期去重记录', ["DELETE FROM idempotency_record WHERE idem_key = 'live'"], 'purge_not_allowed: idempotency_record')
expect_block_tx('Q2 删 PENDING 事件', ["DELETE FROM outbox_event WHERE id = 8801"], 'purge_not_allowed: outbox_event')
expect_block_tx('Q2 删刚投递（未过保留期）事件', ["DELETE FROM outbox_event WHERE id = 8803"], 'purge_not_allowed: outbox_event')
expect_block_tx('Q2 INSERT OR REPLACE 覆盖未过期去重记录', ["INSERT OR REPLACE INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('live','x','{}',200,datetime('now','-1 day'))"], 'idem_duplicate')
expect_block_tx('Q2 REPLACE 覆盖 PENDING 事件', ["REPLACE INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8801,'t','k','{}','SENT',datetime('now','-30 days'))"], 'outbox_duplicate')
expect_allow_tx('Q2 清理（与 purge_expired 同条件）：删已过期去重记录 + 过保留期 SENT 事件', ["DELETE FROM idempotency_record WHERE expires_at < datetime('now')", "DELETE FROM outbox_event WHERE status = 'SENT' AND sent_at < datetime('now','-7 days')"])
r = (one("SELECT group_concat(idem_key) FROM idempotency_record")[0], one("SELECT group_concat(id) FROM (SELECT id FROM outbox_event ORDER BY id)")[0])
ok(f"Q2 清理后剩余 idem={r[0]} outbox={r[1]}（只删了 dead、8802）") if r == ('live', '8801,8803') else bad(f"Q2 清理后 {r}")

print("=== 2c3b. 九轮 P1–P3：UTC 清理、过期列只许往后改、SENT 必带 sent_at ===")
expect_block_tx('P3 status=SENT 但 sent_at 为空', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8804,'t','k','{}','SENT',NULL)"], 'ck_outbox_sent')
expect_allow_tx('P3 正向：PENDING 不带 sent_at、SENT 带 sent_at', ["INSERT INTO outbox_event (id,topic,biz_key,payload,status,sent_at) VALUES (8805,'t','k','{}','PENDING',NULL),(8806,'t','k','{}','SENT',datetime('now'))"])
expect_block_tx('P2 idem expires_at 改早', ["UPDATE idempotency_record SET expires_at = '2000-01-01 00:00:00' WHERE idem_key = 'live'"], 'expiry_backdate: idempotency_record')
expect_block_tx('P2 idem created_at 被改', ["UPDATE idempotency_record SET created_at = '2000-01-01 00:00:00' WHERE idem_key = 'live'"], 'expiry_backdate: idempotency_record')
expect_block_tx('P2 outbox sent_at 改早', ["UPDATE outbox_event SET sent_at = datetime('now','-30 days') WHERE id = 8803"], 'expiry_backdate: outbox_event')
expect_block_tx('P2 outbox sent_at 清空', ["UPDATE outbox_event SET sent_at = NULL, status = 'SENT' WHERE id = 8803"], 'expiry_backdate: outbox_event')
expect_block_tx('P2 PENDING → SENT 时 sent_at 倒填 2000-01-01（早于 created_at）', ["UPDATE outbox_event SET status = 'SENT', sent_at = '2000-01-01 00:00:00' WHERE id = 8801"], 'expiry_backdate: outbox_event')
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
allow_rb('P2 正向：outbox sent_at 往后改、PENDING → SENT 写当前时间', ["UPDATE outbox_event SET sent_at = datetime('now','+1 minute') WHERE id = 8803", "UPDATE outbox_event SET status = 'SENT', sent_at = datetime('now') WHERE id = 8801"])
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
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"误报回转前 quality/hold/available = {tuple(r)}") if tuple(r) == (0, 8000, 1000) else bad(f"误报回转前 {r}")
expect_block_tx('误报回转缺审批单号（→ 应用层 40930，库层 ck_hold_approval 兜底）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (57,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,NULL,NULL)"], 'ck_hold_approval')
expect_block_tx('误报回转审批类型不是 SCRAP_MISREPORT', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (59,41,'RETURN_QC','RETURN_QC','QC',7011,'CVT:53',5000,0,'HELD',0,'OTHER','APR-SH01-20261015-000002')"], 'ck_hold_approval')
expect_block_tx('非误报回转的明细不能挂审批（MANUAL + SCRAP_MISREPORT）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (60,41,'MANUAL','DAMAGE','MANUAL',0,'H60',1000,0,'HELD',7,'SCRAP_MISREPORT','APR-SH01-20261015-000003')"], 'ck_hold_approval')
expect_allow_tx('误报回转：SCRAP_PENDING 52（3000）→ RETURN_QC 56，挂新质检单 7010 + 审批 APR-SH01-20261015-000001；hold −q、quality +q', ["UPDATE stock_hold SET released_qty_milli = hold_qty_milli, status = 'RELEASED', version = version + 1 WHERE id = 52 AND hold_type = 'SCRAP_PENDING' AND status = 'HELD' AND released_qty_milli = 0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (56,41,'RETURN_QC','RETURN_QC','QC',7010,'CVT:52',3000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-000001')", "UPDATE stock SET hold_qty_milli = hold_qty_milli - 3000, quality_hold_qty_milli = quality_hold_qty_milli + 3000, version = version + 1 WHERE id = 41 AND hold_qty_milli >= 3000"])
r = one("SELECT quality_hold_qty_milli, hold_qty_milli, on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli FROM stock WHERE id=41")
ok(f"误报回转后 quality/hold/available = {tuple(r)}（冻结总量 8000、可用量 1000 不变）") if tuple(r) == (3000, 5000, 1000) else bad(f"误报回转后 {r}")
expect_block_tx('误报回转后审批单号不可改', ["UPDATE stock_hold SET approval_no = 'APR-SH01-20261015-000099' WHERE id = 56"], 'hold_immutable')
r = conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.op_key LIKE 'CVT:%' AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE 'CVT:' || o.id = h.op_key AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)").fetchall()
ok("I3e（含误报回转口径）无差异行") if r == [] else bad(f"I3e 差异 {r}")
conn.execute("BEGIN"); conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (58,41,'RETURN_QC','RETURN_QC','QC',7012,'CVT:999',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-000004')")
r = [x[0] for x in conn.execute("SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.op_key LIKE 'CVT:%' AND NOT EXISTS (SELECT 1 FROM stock_hold o WHERE 'CVT:' || o.id = h.op_key AND o.hold_type = 'SCRAP_PENDING' AND o.status = 'RELEASED' AND o.stock_id = h.stock_id) UNION ALL SELECT h.id FROM stock_hold h WHERE h.hold_type = 'RETURN_QC' AND h.released_qty_milli <> COALESCE((SELECT SUM(r.qty_milli) FROM stock_hold_release r WHERE r.hold_id = h.id), 0) + COALESCE((SELECT c.hold_qty_milli FROM stock_hold c WHERE c.op_key = 'CVT:' || h.id), 0)").fetchall()]
conn.execute("ROLLBACK")
ok("I3e 反向：RETURN_QC 声称回转自不存在的 SCRAP_PENDING 999→ 查出 58") if r == [58] else bad(f"I3e 未查出 {r}")

print("=== 2c5. 审批单号格式 ck_hold_approval_no：APR-{仓库编码}-{yyyyMMdd}-{6位数字} ===")
expect_block_tx("审批单号格式反向：仓库编码小写", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (70,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:870',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-sh01-20261015-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：前缀不是 APR", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (71,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:871',1000,0,'HELD',0,'SCRAP_MISREPORT','APV-SH01-20261015-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码含 '-'", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (72,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:872',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH-01-20261015-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码为空", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (73,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:873',1000,0,'HELD',0,'SCRAP_MISREPORT','APR--20261015-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：月份 13", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (74,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:874',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261315-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：日期 32", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (75,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:875',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261032-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：序号 5 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (76,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:876',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-00001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：序号 7 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (77,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:877',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-0000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：日期 7 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (78,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:878',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-2026101-000001')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：末尾多空格", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (79,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:879',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-000001 ')"], "ck_hold_approval_no")
expect_block_tx("审批单号格式反向：仓库编码 33 位", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (80,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:880',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-20261015-000001')"], "ck_hold_approval_no")
def _allow_rb(desc, stmts):
    try:
        conn.execute('SAVEPOINT fmt')
        for x in stmts: conn.execute(x)
        ok(f'{desc} → 通过（已回滚）')
    except sqlite3.Error as e:
        bad(f'{desc} → 被误拦：{e}')
    finally:
        conn.execute('ROLLBACK TO fmt'); conn.execute('RELEASE fmt')
_allow_rb("审批单号格式正向：常规 SH01（APR-SH01-20261015-000123）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (90,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:890',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-SH01-20261015-000123')"])
_allow_rb("审批单号格式正向：单字符编码 + 年末（APR-W-20261231-999999）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (91,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:891',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-W-20261231-999999')"])
_allow_rb("审批单号格式正向：32 位编码（APR-Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id,approval_type,approval_no) VALUES (92,41,'RETURN_QC','RETURN_QC','QC',7100,'CVT:892',1000,0,'HELD',0,'SCRAP_MISREPORT','APR-Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000')"])
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

print("=== 2f. docs/12 权限与审计（小赵评审 B1、I1–I7、S1 + SCRAP_MISREPORT 权限点与审批单号格式 + UTC）===")
conn.execute("INSERT INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x')")
conn.execute('UPDATE sys_user SET perm_version = 3 WHERE id = 101')
conn.execute("INSERT INTO sys_role (id,code,name) VALUES (1,'WH_SUPERVISOR','仓库主管'),(2,'CENTER_OPS','中心运维'),(3,'QC_SUPERVISOR','质检主管')")
conn.execute('INSERT INTO sys_user_role (user_id,role_id) VALUES (202,1),(202,2),(203,2),(205,3),(206,1),(207,3)')
conn.execute('INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (202,1),(203,1),(204,1),(205,1),(206,1)')
conn.execute("INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-A','PDA',101,1)")
conn.execute("INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
conn.execute("INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1,'outbound.cancel_after_pick',7,1,1)")
expect_block_tx('12 B1 INSERT OR REPLACE 覆盖审计（同 id）', ["INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq) VALUES (1,'NOTHING',7,1)"], 'append_only_violation: audit_log')
expect_block_tx('12 B1 INSERT OR REPLACE 借 (node_id,node_seq) 删旧行', ["INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq) VALUES (2,'NOTHING2',7,1)"], 'append_only_violation: audit_log')
expect_block_tx('12 B1 UPSERT 审计', ["INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (1,'x',7,9) ON CONFLICT(id) DO UPDATE SET action='y'"], 'append_only_violation: audit_log')
expect_block_tx('12 audit_log 只追加（UPDATE）', ["UPDATE audit_log SET reason='x' WHERE id=1"], 'append_only_violation: audit_log')
expect_block_tx('12 audit_log 只追加（DELETE）', ['DELETE FROM audit_log WHERE id=1'], 'append_only_violation: audit_log')
expect_allow_tx('12 B1 正向：新 (node_id,node_seq) 追加', ["INSERT INTO audit_log (id,action,node_id,node_seq) VALUES (3,'x',7,2)"])
expect_block_tx('12 同一设备实例两条 PENDING/ACTIVE 绑定', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (2,'DEV-A','PDA',102,1)"], 'binding_duplicate')
expect_block_tx('12 I3 REPLACE 覆盖绑定', ["INSERT OR REPLACE INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-Z','PDA',99,1)"], 'binding_duplicate')
expect_block_tx('12 I3 直接插成 ACTIVE', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,status,activated_at,approval_id) VALUES (3,'DEV-C','PDA',101,1,'ACTIVE','2026-10-15 08:00',1)"], 'binding_insert_not_pending')
expect_block_tx('12 REVOKED 没有吊销时间', ["UPDATE user_device_binding SET status='REVOKED' WHERE id=1"], 'ck_udb_status')
expect_block_tx('12 I3 用不存在的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=999, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (7,'APR-WH01-20261015-000007','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=101, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=7")
expect_block_tx('12 S1 审批人 = 绑定使用人', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=7, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (8,'APR-WH01-20261015-000008','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='REJECTED', decided_at='2026-10-15 09:00', reject_reason='x' WHERE id=8")
expect_block_tx('12 I3 用已驳回的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=8, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (9,'APR-WH01-20261015-000009','CANCEL_AFTER_PICK',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=9")
expect_block_tx('12 I3 用别的类型的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=9, activated_at='2026-10-15 09:00' WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (10,'APR-WH01-20261015-000010','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,'2099-01-01')")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=10")
expect_allow_tx('12 I3 正向：DEVICE_BIND 已通过、审批人≠使用人 → PENDING→ACTIVE', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=10, activated_at='2026-10-15 09:00' WHERE id=1 AND status='PENDING'"])
expect_block_tx('12 I3 绑定换人', ['UPDATE user_device_binding SET user_id=99 WHERE id=1'], 'binding_immutable')
expect_block_tx('12 I3 ACTIVE 退回 PENDING', ["UPDATE user_device_binding SET status='PENDING', activated_at=NULL WHERE id=1"], 'binding_immutable')
expect_allow_tx('12 I3 正向：吊销', ["UPDATE user_device_binding SET status='REVOKED', revoked_at='2026-10-15 10:00', revoke_reason='LOST' WHERE id=1"])
expect_block_tx('12 I3 REVOKED 复活', ["UPDATE user_device_binding SET status='ACTIVE', revoked_at=NULL WHERE id=1"], 'binding_immutable')
expect_block_tx('12 绑定不可删除', ['DELETE FROM user_device_binding WHERE id=1'], 'append_only_violation: user_device_binding')
expect_block_tx('12 离线令牌到期早于签发', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (2,'J2',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 07:00')"], 'ck_offline_ttl')
expect_block_tx('12 I4 离线令牌 30 天', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (3,'J3',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-11-14 08:00')"], 'ck_offline_max_ttl')
expect_allow_tx('12 I4 正向：恰好 12 小时', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (4,'J4',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"])
expect_block_tx('12 离线令牌 jti 重复', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (5,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"], 'offline_token_duplicate')
expect_block_tx('12 I4 REPLACE 覆盖令牌', ["INSERT OR REPLACE INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,'2026-10-15 08:00','2026-10-15 20:00')"], 'offline_token_duplicate')
expect_block_tx('12 I4 延长有效期', ["UPDATE offline_token SET expires_at='2026-10-15 19:00' WHERE id=1"], 'offline_token_immutable')
expect_allow_tx('12 I4 正向：吊销', ["UPDATE offline_token SET revoked_at='2026-10-15 10:00' WHERE id=1"])
expect_block_tx('12 I4 吊销后恢复', ['UPDATE offline_token SET revoked_at=NULL WHERE id=1'], 'offline_token_immutable')
expect_block_tx('12 I2 直接插成 APPROVED', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at,status) VALUES (20,'APR-WH01-20261015-000020','POD_CORRECT',1,'POD','20','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01','APPROVED')"], 'approval_insert_not_pending')
expect_block_tx('12 同一目标两条待审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (21,'APR-WH01-20261015-000021','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,'2099-01-01')"], 'approval_duplicate')
expect_block_tx('12 I1 REPLACE 改写审批（同 id）', ["INSERT OR REPLACE INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'approval_duplicate')
expect_block_tx('12 I1 UPSERT 改写审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','9','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01') ON CONFLICT(id) DO UPDATE SET status='PENDING'"], 'approval_duplicate')
expect_block_tx('12 SoD：申请人自己审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1"], 'ck_apr_sod')
expect_block_tx('12 I2 单人审批进 PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=1"], 'ck_apr_partial')
expect_block_tx('12 I2 审批人三列不成组', ['UPDATE approval_request SET first_approver_id=202 WHERE id=1'], 'ck_apr_pair')
expect_block_tx('12 I2 REJECTED 没有 decided_at', ["UPDATE approval_request SET status='REJECTED' WHERE id=1"], 'ck_apr_decided')
expect_allow_tx('12 正向：主管审批通过', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=1"])
expect_block_tx('12 I1/I2 APPROVED 改回 PENDING', ["UPDATE approval_request SET status='PENDING', decided_at=NULL WHERE id=1"], 'approval_final')
expect_block_tx('12 审批不可删除', ['DELETE FROM approval_request WHERE id=1'], 'append_only_violation: approval_request')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (4,'APR-WH01-20261015-000004','POD_CORRECT',1,'POD','4','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2020-01-01')")
expect_block_tx('12 I2 过期后审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=4"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (41,'APR-WH01-20261015-000041','POD_CORRECT',1,'POD','41','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','-1 minutes'))")
expect_block_tx('12 UTC 反向：expires_at = UTC 当前 −1 分钟，已过期不能再批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=41"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (42,'APR-WH01-20261015-000042','POD_CORRECT',1,'POD','42','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','+2 hours'))")
expect_allow_tx('12 UTC 正向：expires_at = UTC 当前 +2 小时（比本地 UTC+8 早）仍可批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=42"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (3,'APR-WH01-20261015-000003','UNPLANNED_FAILOVER',1,'WAREHOUSE','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')")
expect_block_tx('12 I5 第一确认人不持有任何角色', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 I5 第一确认人只有 CENTER_OPS 却写 WH_SUPERVISOR', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=203, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"], 'approval_role_not_held')
expect_allow_tx('12 I5 正向：真主管确认 → PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00' WHERE id=3"])
expect_block_tx('12 I2 换第一审批人', ['UPDATE approval_request SET first_approver_id=203 WHERE id=3'], 'approval_approver_immutable')
expect_block_tx('12 I2 PARTIAL 倒退 PENDING', ["UPDATE approval_request SET status='PENDING' WHERE id=3"], 'approval_transition_invalid')
expect_block_tx('12 I5 第二确认人不持有 CENTER_OPS', ["UPDATE approval_request SET second_approver_id=204, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 第二确认人 = 第一确认人', ["UPDATE approval_request SET second_approver_id=202, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30' WHERE id=3"], 'ck_apr_dual')
expect_block_tx('12 非计划切换只有一人确认就 APPROVED', ["UPDATE approval_request SET status='APPROVED', decided_at='2026-10-15 09:30' WHERE id=3"], 'ck_apr_done')
expect_allow_tx('12 I5 正向：中心运维第二确认 → APPROVED', ["UPDATE approval_request SET status='APPROVED', second_approver_id=203, second_approver_role='CENTER_OPS', second_approved_at='2026-10-15 09:30', decided_at='2026-10-15 09:30' WHERE id=3"])
expect_block_tx('12 SM 发起人不是本仓仓库主管（只有 CENTER_OPS）', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (23,'APR-WH01-20261015-000023','SCRAP_MISREPORT',1,'SCRAP_ORDER','9009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,'2099-01-01')"], 'approval_role_not_held')
expect_block_tx('12 SM 发起人是质检主管而非仓库主管', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (24,'APR-WH01-20261015-000024','SCRAP_MISREPORT',1,'SCRAP_ORDER','9010','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',205,'2099-01-01')"], 'approval_role_not_held')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (5,'APR-WH01-20261015-000005','SCRAP_MISREPORT',1,'SCRAP_ORDER','9001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,'2099-01-01')")
expect_block_tx('12 SM 发起人自己审批（202 兼 CENTER_OPS 也不行）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'ck_apr_sod')
expect_block_tx('12 SM 审批角色写成仓库主管（另一主管 206 不具审批权）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=206, first_approver_role='WH_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'ck_apr_scrap_roles')
expect_block_tx('12 SM 审批人不持有 QC_SUPERVISOR 却写质检主管', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'approval_role_not_held')
expect_block_tx('12 SM 质检主管不在本仓', ["UPDATE approval_request SET status='APPROVED', first_approver_id=207, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"], 'approval_role_not_held')
expect_allow_tx('12 SM 正向：本仓质检主管审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=5"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (6,'APR-WH01-20261015-000006','SCRAP_MISREPORT',1,'SCRAP_ORDER','9002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',206,'2099-01-01')")
expect_allow_tx('12 SM 正向：中心运维审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at='2026-10-15 09:00', decided_at='2026-10-15 09:00' WHERE id=6"])
expect_block_tx('12 审批单号格式：旧格式 SM-2026-001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (30,'SM-2026-001','CANCEL_AFTER_PICK',1,'OUTBOUND','30','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期 7 位 APR-WH01-2026101-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (31,'APR-WH01-2026101-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','31','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号 5 位 APR-WH01-20261015-00001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (32,'APR-WH01-20261015-00001','CANCEL_AFTER_PICK',1,'OUTBOUND','32','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码为空 APR--20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (33,'APR--20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','33','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期含字母 APR-WH01-2026A015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (34,'APR-WH01-2026A015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','34','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：月份 13 APR-WH01-20261315-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (35,'APR-WH01-20261315-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','35','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号含字母 APR-WH01-20261015-00000X', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (36,'APR-WH01-20261015-00000X','CANCEL_AFTER_PICK',1,'OUTBOUND','36','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：前缀小写 apr-WH01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (37,'apr-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','37','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码含 - APR-WH-01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (38,'APR-WH-01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','38','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_code')
expect_allow_tx('12 审批单号格式正向：APR-SHPD01-20261231-999999', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (40,'APR-SHPD01-20261231-999999','POD_CORRECT',1,'POD','40','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"])
expect_block_tx('12 审批类型不在码表', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (22,'APR-WH01-20261015-000022','BANANA',1,'X','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01')"], 'ck_apr_type')
expect_block_tx('12 perm_version 回退', ['UPDATE sys_user SET perm_version = 1 WHERE id = 101'], 'perm_version_rewind')
expect_block_tx('12 I7 REPLACE 把 perm_version 打回 1', ["INSERT OR REPLACE INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x')"], 'sys_user_duplicate')
expect_allow_tx('12 I7 正向：perm_version 前进', ['UPDATE sys_user SET perm_version = 4 WHERE id = 101'])

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
conn = sqlite3.connect(dbf)
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

print("=== 汇总 ===")
print(f"  通过 {passed} 项 / 失败 {failed} 项")
conn.close()
Path(dbf).unlink(missing_ok=True)
for p in (dbf + "-wal", dbf + "-shm"):
    Path(p).unlink(missing_ok=True)
sys.exit(0 if failed == 0 else 1)
