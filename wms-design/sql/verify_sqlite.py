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
    n_now = len(re.findall(r"DEFAULT now\(\)", s))
    if n_now:
        s = s.replace("DEFAULT now()", "DEFAULT (datetime('now'))")
        deltas.append(f"{n_now} 处 DEFAULT now() → DEFAULT (datetime('now'))（表达式默认值需括号）")

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
if len(deltas) <= 4:
    ok(f"改动仅 {len(deltas)} 类，且全部是语法糖级别（无一处需要改列型/改语义/删功能）")
else:
    bad(f"改动 {len(deltas)} 类，交集原则守得不够，见上方清单")

dbf = tempfile.mktemp(suffix=".db")
conn = sqlite3.connect(dbf)
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
# 期望值：main 8ed5f0c 为 38 表；docs/02 新增 stock_hold、stock_recon_alert → 40 表。改表数必须同步改这里和 verify.sh
EXPECT_TABLES, EXPECT_VIEWS = 40, 1
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
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16')",
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
    "I5 流水平衡（after<>before+qty*dir）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'PK1',1,1,'PICK',-1,11,1,1,1,1,1,3000,100000,98000,'2026-10-15','k1')",
    'ck_mv_balance',
)
expect_allow(
    "写入一条平衡的合法流水",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'PK1',1,1,'PICK',-1,11,1,1,1,1,1,3000,100000,97000,'2026-10-15','k2')",
)
expect_block(
    "§4.6③ 记账层幂等（idempotency_key 重复）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'PK1',2,1,'PICK',-1,11,2,1,1,1,1,3000,97000,94000,'2026-10-15','k2')",
    'stock_movement.idempotency_key',
)
expect_block(
    "§4.6② 业务层幂等（source_system+source_order_no 重复）",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date) VALUES (2,'OBT2',1,'SALE','MALL','M-2026-001',1,'CREATED','2026-10-16')",
    'outbound_order.source_system, outbound_order.source_order_no',
)
expect_block(
    "§2.2 职责分离（拣货人=复核人）",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,customer_id,status,work_date,picker_id,checker_id) VALUES (3,'OBT3',1,'SALE','MALL','M-2026-003',1,'CREATED','2026-10-16',77,77)",
    'ck_obo_sod',
)
expect_block(
    "I6 同维度重复库存行（container_id 用 0 哨兵后应被拦）",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,container_id,uom,on_hand_qty_milli) VALUES (21,1,3,1,1,0,'KG',5000)",
    'stock.warehouse_id, stock.location_id, stock.sku_id, stock.lot_id, stock.container_id',
)


print("=== 2b. docs/02 库存核心：BIGINT *_qty_milli 与记账链断言 ===")
expect_block(
    "02 重复过账（同 biz_no+line_no+leg，换一个 idempotency_key）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'PK1',1,1,'PICK',-1,11,9,1,1,1,1,3000,100000,97000,'2026-10-15','k-other')",
    'stock_movement.biz_no, stock_movement.line_no, stock_movement.leg',
)
expect_block(
    "02 记账链分叉（同 stock_id+stock_seq 两条改 on_hand 的流水）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'PK9',1,1,'PICK',-1,11,1,1,1,1,1,1000,100000,99000,'2026-10-15','k5')",
    'stock_movement.stock_id, stock_movement.stock_seq',
)
expect_allow(
    "02 direction=0 纯事件流水不入链（SHIP，before=after）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'SHP1',1,1,'SHIP',0,11,1,1,1,1,1,3000,97000,97000,'2026-10-15','k6')",
)
expect_allow(
    "02 PDA 拣货流水带第 5 篇业务键",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'PK2',3,1,'PICK',-1,12,1,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PICK:PK2:3:1')",
)
expect_block(
    "02 Idempotency-Key 过期后 PDA 重放同一操作（换 idempotency_key、同业务键）→ 业务键兜底",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'PK2',3,1,'PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','PICK:PK2:3:2')",
    'stock_movement.src_task_id, stock_movement.src_line_no, stock_movement.device_instance_id, stock_movement.src_op_seq, stock_movement.leg',
)
expect_block(
    "02 PDA 业务键半截（device_instance_id 为 NULL）",
    "INSERT INTO stock_movement (id,biz_no,line_no,leg,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'PK2',4,1,'PICK',-1,12,3,1,2,1,1,77,4,NULL,1,1000,28000,27000,'2026-10-15','PICK:PK2:4:1')",
    'ck_mv_pda_src',
)
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
expect_allow(
    "02 占用写入（RESERVE 10000）",
    "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli) VALUES (1,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1',10000)",
)
expect_block(
    "02 占用幂等（同 op_key 重复占用）",
    "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli) VALUES (2,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1',10000)",
    'stock_reservation.op_key',
)
expect_block(
    "02 占用超消耗（consumed+released > reserve）",
    "UPDATE stock_reservation SET consumed_qty_milli = 6000, released_qty_milli = 5000 WHERE id = 1",
    'ck_res',
)
expect_block(
    "02 冻结明细超释放（released > hold）",
    "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,op_key,hold_qty_milli,released_qty_milli,operator_id) VALUES (1,11,'MANUAL','DAMAGE','MANUAL','HOLD:1',1000,2000,7)",
    'ck_hold',
)
c = conn.execute("UPDATE stock SET reserved_qty_milli = reserved_qty_milli + 50000 WHERE id = 11 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - frozen_qty_milli >= 50000").rowcount
conn.commit()
ok("02 条件预占：available(50000) 恰好够 50000 → rowcount=1") if c == 1 else bad(f"条件预占 rowcount={c}")
c = conn.execute("UPDATE stock SET reserved_qty_milli = reserved_qty_milli + 1 WHERE id = 11 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - frozen_qty_milli >= 1").rowcount
conn.commit()
ok("02 条件预占：available=0 再占 1 milli → rowcount=0（走 40904，不靠 CHECK 报错）") if c == 0 else bad(f"超占 rowcount={c}")
# 复原，避免干扰后面的 FEFO 排序断言
conn.execute("UPDATE stock SET reserved_qty_milli = 0 WHERE id = 11")
conn.execute("DELETE FROM stock WHERE id = 33")
conn.commit()

D = one("SELECT diff_qty_milli FROM count_line WHERE id=1")[0]
ok(f"§5.6 差异生成列 diff_qty_milli = {D}（预期 -2000）") if D == -2000 else bad(f"差异列 = {D}")

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
