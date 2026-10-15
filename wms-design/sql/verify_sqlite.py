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

import os
import json
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
    "07_replenishment.sql",
    "08_count.sql",
    "10_returns.sql",
    "09_scrap.sql",
    "11_integration.sql",
    "12_auth.sql",
    "12b_auth_audit.sql",
    "16_delivery.sql",
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
    n_utc = s.count("DEFAULT (now() AT TIME ZONE 'UTC')") + s.count("DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC'))")
    if n_now or n_utc:
        s = s.replace("DEFAULT (date_trunc('second', now() AT TIME ZONE 'UTC'))", "DEFAULT (datetime('now'))")   # #2 第九轮：UTC 整秒，SQLite datetime('now') 本来就是整秒 UTC
        s = s.replace("DEFAULT (now() AT TIME ZONE 'UTC')", "DEFAULT (datetime('now'))")
        s = s.replace("DEFAULT now()", "DEFAULT (datetime('now'))")
        deltas.append(f"{n_now} 处 DEFAULT now()、{n_utc} 处 DEFAULT (now() AT TIME ZONE 'UTC') / (date_trunc('second', now() AT TIME ZONE 'UTC')) → DEFAULT (datetime('now'))（表达式默认值需括号；SQLite 恒为 UTC）")

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
if os.environ.get("VERIFY_SQLITE_NO_WRITE") != "1":  # 变异子进程不覆盖生成文件
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
# 变异开关（仅供自检用）：=1 时 connect_main() 重连后不再打开外键，用来证明下面的守卫会让 verify 变红
_MUTANT_NO_FK = os.environ.get("VERIFY_SQLITE_MUTANT_NO_FK") == "1"
_n_connects = 0
_fk_off_allowed = False   # 只有刻意测"连接漏开外键"的用例才会临时置 True


def connect_main(**kw):
    """主连接唯一入口：每次（重）连接都必须打开外键，并确认真的生效。
    SQLite 的 foreign_keys 是连接级设置，重连后默认是 OFF。"""
    global _n_connects
    c = sqlite3.connect(dbf, **kw)
    _n_connects += 1
    c.create_function("edge_sync_active", 0, lambda: 0)   # 第 12 篇：应用连接永远不是同步落库（映射表只读）
    if not (_MUTANT_NO_FK and _n_connects > 1):   # 变异：只去掉"重连"后的外键开启
        c.execute("PRAGMA foreign_keys = ON")
        fk = c.execute("PRAGMA foreign_keys").fetchone()[0]
        if fk != 1:
            print(f"  ✗ PRAGMA foreign_keys=ON 未生效（读回 {fk}），立即退出")
            sys.exit(3)
    return c


def connect_edge_sync():
    """第 12 篇：边缘同步进程的连接（只有同步落库用；应用代码不调用）。和 connect_main 一样开外键，
    另外把 edge_sync_active() 注册为 1，映射表的只读触发器才放行。"""
    c = sqlite3.connect(dbf, isolation_level=None)
    c.execute("PRAGMA foreign_keys = ON")
    if c.execute("PRAGMA foreign_keys").fetchone()[0] != 1:
        print("  ✗ 同步连接 foreign_keys 未生效"); sys.exit(3)
    c.create_function("edge_sync_active", 0, lambda: 1)
    return c


def edge_sync_tx(desc, stmts):
    try:
        edge_sync(stmts); ok(f"{desc} → 经边缘同步连接落库")
    except sqlite3.DatabaseError as e:
        bad(f"{desc} → 同步落库失败 {e}")


def edge_sync(stmts):
    """模拟中心下发：同步连接上一个事务落库"""
    c = connect_edge_sync()
    try:
        c.execute("BEGIN")
        for x in ([stmts] if isinstance(stmts, str) else stmts): c.execute(x)
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK"); raise
    finally:
        c.close()


conn = connect_main(isolation_level=None)   # 自动提交；需要事务时显式 BEGIN/COMMIT
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
EXPECT_TABLES, EXPECT_VIEWS= 98, 3  # 01 增量 +5 表（supplier、customer、vehicle、driver、device）→ 98 表；第 16 篇 +9 表（waybill、delivery_stop、delivery_order、pod_op、pod_line、pod_correction、pod_tolerance_config、delivery_return、delivery_return_line）→ 93；视图仍 3（第 7 篇 +replenish_* 与 v_location_sku_candidate、第 18 篇 v_live_death_in_transit）。第 12 篇 +device_reconnect；docs/03 +5 表； 退供 +supplier_return； docs/12 +3；第 10 篇 +exception_code、exception_case、return_reservation、return_reservation_line、return_blind_receipt；第 9 篇 +scrap_order、scrap_line；第 17 篇 +8 张 process_*；docs/18 加 9 表
ok(f"表数 = {NT}（期望 {EXPECT_TABLES}）") if NT == EXPECT_TABLES else bad(f"表数 = {NT}，期望 {EXPECT_TABLES}")
ok(f"视图数 = {NV}") if NV == EXPECT_VIEWS else bad(f"视图数 = {NV}，期望 {EXPECT_VIEWS}")


_fk_guard_hits = 0


def _fk_guard(desc: str) -> None:
    """自检：用例运行时外键必须是开的（刻意测漏开的用例除外），否则直接记失败。"""
    global _fk_guard_hits
    if _fk_off_allowed:
        return
    if conn.execute("PRAGMA foreign_keys").fetchone()[0] != 1:
        _fk_guard_hits += 1
        bad(f"[FK 守卫] 运行用例时 foreign_keys=OFF：{desc}")


# #2 第十一轮 种子模式（同 2s 退供 SRTN_CLOCK_TRG 口径）：流水 / key 的 occurred_at 时钟触发器对所有写入生效（SQLite 没有表属主），
# 而前面几百条用例用固定日期（'2026-10-15' 等）写流水验证业务规则。先摘掉，文件末尾 "2z2-mv" 节装回来专测时钟。
MV_CLOCK_TRG = ("trg_mv_clock", "trg_mvk_clock")
MV_CLOCK_SQL = [conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (t,)).fetchone()[0] for t in MV_CLOCK_TRG]
for _t in MV_CLOCK_TRG:
    conn.execute(f"DROP TRIGGER {_t}")


def one(sql, *a):
    return conn.execute(sql, a).fetchone()


def expect_block(desc: str, sql: str, want: str) -> None:
    """want = 期望的约束名（CHECK）或列清单（UNIQUE，SQLite 报错只给列不给约束名）。
    只有错误信息精确命中 want 才算通过：被别的约束拦下 = 断言没测到它声称测的东西。"""
    _fk_guard(desc)
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
    _fk_guard(desc)
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
    _fk_guard(desc)
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
    _fk_guard(desc)
    try:
        _run_tx(stmts)
        ok(f"{desc} → 通过")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")


# ---------------------------------------------------------------------------
# 2. 同一套断言
# ---------------------------------------------------------------------------
_MASTER_MIN = ["INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (1,'WHSH01','x','20:00')",
               "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (1,1,'Z-C1','x','CHILLED','PICK',20,80),(2,1,'Z-C2','x','CHILLED','STORAGE',20,80)",
               "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01','BIN',2,'A010'),(2,1,1,'A02','BIN',2,'A020'),(3,1,2,'B01','PALLET',8,'B010')",
               "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,sell_days) VALUES (1,'SKU-APPLE','x','KG','CHILLED',30,14)",   # 第十三轮：01/02 补了外键，内存库变异也要有父行；第 1 篇 sell_days 冷藏必填
               # 跨篇 FK 收口（磐石 2026-10-16）：`fk_inb_supplier` / `fk_obo_customer` 之后，凡是**开了外键的内存变异库**
               # （如 16 段 `_mut16`）都必须先有 supplier 501 / customer 1 父行——否则 `_S16_PARENT` 里的 `outbound_order.customer_id=1` 会先报 FK。
               "INSERT INTO supplier (id,code,name) VALUES (501,'SUP501','变异库父行')",
               "INSERT INTO customer (id,code,name) VALUES (1,'STORE0001','变异库父行')",
               # 16 篇 `fk_wb_driver` / `fk_podc_driver` 的父行（16 段既有用例用 driver_id=1，内存变异库同款）
               "INSERT INTO driver (id,name,phone) VALUES (1,'变异库父行司机','13900000001')"]
print("=== 2. 库层不变量断言（与 verify.sh 同一套）===")
seed = [
    "INSERT INTO warehouse (id,code,name,cutoff_time,work_date_offset) VALUES (1,'WHSH01','上海青浦仓','20:00',-1)",
    # 跨篇 FK 收口（Chief 2026-10-16）：03/10 supplier_id 与 04 customer_id 的既有种子用 501 / 1，**父行必须最先建**
    "INSERT INTO supplier (id,code,name) VALUES (501,'SUP501','跨篇 FK 收口父行')",
    "INSERT INTO customer (id,code,name) VALUES (1,'STORE0001','跨篇 FK 收口父行')",
    # 第 12 篇 FK 底数（权限表加外键后，审批人 / 申请人 / 映射里引用的用户必须存在）：102–199、201–299 号测试用户
    "WITH RECURSIVE n(i) AS (SELECT 102 UNION ALL SELECT i + 1 FROM n WHERE i < 299) INSERT INTO sys_user (id,username,password_hash) SELECT i, 'seed' || i, 'x' FROM n WHERE i <> 200",
    "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (1,1,'Z-C1','冷藏拣货区','CHILLED','PICK',20,80),(2,1,'Z-C2','冷藏存储区','CHILLED','STORAGE',20,80)",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1,1,1,'A01-02-03','BIN',2,'A010'),(2,1,1,'A01-03-01','BIN',2,'A020'),(3,1,2,'B02-01-05','PALLET',8,'B010')",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (1,'SKU-APPLE','山东红富士 80#','KG','CHILLED',30,10,14)",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (2,'SKU-PEAR','砀山酥梨','KG','CHILLED',30,10,14)",   # 第十三轮：stock/lot 用例引用 sku 2，补外键父行
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (1,1,'LOT-1008','2026-10-25','2026-10-08','QUALIFIED',10),(2,1,'LOT-1012','2026-10-29','2026-10-12','QUALIFIED',14),(3,1,'LOT-1014','2026-10-31','2026-10-14','QUALIFIED',16)",
    "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli,allocated_qty_milli) VALUES (11,1,1,1,2,'KG',50000,0),(12,1,2,1,1,'KG',30000,10000),(13,1,3,1,3,'KG',200000,0),(14,1,3,1,1,'KG',80000,0)",
    "INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (1,'CNT-SH01-0001-20261015-000001',1,'FULL','{}','DRAFT','2026-10-15 02:00:00')",   # 长流：count_line.count_id 加外键后的父行
    "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli) VALUES (1,1,1,1,1,100000,-30000,68000)",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (1,'OBT1',1,'SALE','MALL','M-2026-001','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'CREATED','2026-10-16')",
    # 第 7 篇：补货任务 / 任务行 / 需求 / 移库单 / 移库行各一条（供逐键实打与视图断言；父行都在上面）
    "INSERT INTO replenish_task (id,code,warehouse_id,zone_id,work_date,status,line_count) VALUES (701,'RPL-20261015-000001',1,1,'2026-10-15','PENDING',1)",
    "INSERT INTO replenish_task_line (id,task_id,seq,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,planned_qty_milli,uom) VALUES (7101,701,1,3,1,1,3,13,20000,'KG')",
    "INSERT INTO replenish_demand (id,code,warehouse_id,work_date,cause,target_location_id,sku_id,demand_qty_milli,source_outbound_id,source_outbound_line_id,source_alloc_round,source_doc_no) VALUES (7201,'RPD-20261015-000001',1,'2026-10-15','OUTBOUND_SHORTAGE',1,1,20000,1,1,1,'OBT1')",
    "INSERT INTO move_order (id,code,warehouse_id,move_type,status,reason_code,line_count) VALUES (7301,'MV-20261015-000001',1,'LOCATION_TRANSFER','DRAFT','TIDY',1)",
    "INSERT INTO move_order_line (id,move_order_id,line_no,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,qty_milli,uom) VALUES (7311,7301,1,2,3,1,1,12,10000,'KG')",
    # 逐键实打要「无子行」样本：这两条没有任何行引用，供 move_order(code) / replenish_task(code) 的 REPLACE 实打
    "INSERT INTO replenish_task (id,code,warehouse_id,zone_id,work_date,status,line_count) VALUES (702,'RPL-20261015-000002',1,2,'2026-10-15','PENDING',0)",
    "INSERT INTO move_order (id,code,warehouse_id,move_type,status,reason_code,line_count) VALUES (7302,'MV-20261015-000002',1,'CONSOLIDATE','DRAFT','MERGE',0)",
    # 01 增量：台账五表各一条（供逐键实打与断言；父行 warehouse 1 在上面）
    "INSERT INTO supplier (id,code,name) VALUES (8801,'SUP001','山东果蔬供应商')",
    "INSERT INTO customer (id,code,name,store_type) VALUES (8802,'STORE001','门店 A','STORE')",
    "INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8803,'沪A12345','REFRIGERATED')",
    "INSERT INTO driver (id,name,phone) VALUES (8804,'张师傅','13800138000')",
    # 16 篇 `fk_wb_driver` / `fk_podc_driver` 的父行（16 段既有用例用 driver_id=1）
    "INSERT INTO driver (id,name,phone) VALUES (1,'跨篇 FK 父行司机','13900000001')",
    # 16 篇 2z3b 的签收样本（pod_correction 9401–9411）用 driver_id 101–104：只补父行，不改 16 的样本数据
    "INSERT INTO driver (id,name,phone) VALUES (101,'16 样本司机 101','13900000101'),(102,'16 样本司机 102','13900000102'),(103,'16 样本司机 103','13900000103'),(104,'16 样本司机 104','13900000104')",
    "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8805,'D-PDA-8805','PDA',1)",
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
    _fk_guard(desc)
    got = one(sql)[0]
    ok(f"{desc} = {got}") if got == n else bad(f"{desc} = {got}，期望 {n}")


assert_n("主数据种子 warehouse", "SELECT count(*) FROM warehouse", 1)
assert_n("主数据种子 zone", "SELECT count(*) FROM zone", 2)
assert_n("主数据种子 location", "SELECT count(*) FROM location", 3)
assert_n("主数据种子 sku", "SELECT count(*) FROM sku", 2)
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
expect_block_tx('I5 流水平衡（after<>before+qty*dir）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ0',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ0' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (1,'ADJ0',1,1,1,'DOC','ADJUST',-1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,3000,100000,98000,'2026-10-15','ADJ0:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (1,'ADJ0:1:D1:1','ADJ0',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,-1,'2026-10-15')"], 'ck_mv_balance')
expect_allow_tx('期初流水 OPENING（迁移行 seq=1，before=0）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',11,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 11) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (2,'OPEN-MIG1',11,1,1,'DOC','OPENING',1,11,1,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:11:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (2,'OPEN-MIG1:11:D1:1','OPEN-MIG1',11,1,1,'DOC',NULL,NULL,NULL,NULL,11,1,1,'2026-10-15')"])
expect_block_tx('期初流水只能是该行第 1 条', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',111,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 111) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (3,'OPEN-MIG1',111,1,1,'DOC','OPENING',1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,50000,0,50000,'2026-10-15','OPEN-MIG1:111:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (3,'OPEN-MIG1:111:D1:1','OPEN-MIG1',111,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,1,'2026-10-15')"], 'ck_mv_opening')
expect_allow_tx('DOC 过账（调整出 3000）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (4,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,2,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','ADJ1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (4,'ADJ1:1:D1:1','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,2,-1,'2026-10-15')"])
expect_block_tx('重复过账：同 biz_no+line_no+op_no+leg，换 idempotency_key', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (5,'ADJ1',1,1,1,'DOC','ADJUST',-1,11,9,1,1,1,2,NULL,NULL,NULL,NULL,3000,50000,47000,'2026-10-15','X:other')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (5,'X:other','ADJ1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,9,-1,'2026-10-15')"], 'stock_movement_key.biz_no, stock_movement_key.line_no, stock_movement_key.op_no, stock_movement_key.leg')
expect_allow_tx('同一 DOC 行第二次合法操作（op_no=2，不被吞）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (6,'ADJ1',1,2,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,47000,46000,'2026-10-15','ADJ1:1:D2:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (6,'ADJ1:1:D2:1','ADJ1',1,2,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15')"])
expect_block_tx('idempotency_key 重复（唯一格式）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ9',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ9' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (7,'ADJ9',1,1,1,'DOC','ADJUST',-1,11,4,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (7,'ADJ1:1:D1:1','ADJ9',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,4,-1,'2026-10-15')"], 'stock_movement_key.idempotency_key')
expect_block_tx('记账链分叉（同 stock_id+stock_seq）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ8',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ8' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (8,'ADJ8',1,1,1,'DOC','ADJUST',-1,11,3,1,1,1,2,NULL,NULL,NULL,NULL,1000,46000,45000,'2026-10-15','ADJ8:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (8,'ADJ8:1:D1:1','ADJ8',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,-1,'2026-10-15')"], 'stock_movement_key.stock_id, stock_movement_key.stock_seq')
expect_allow_tx('direction=0 纯事件流水不入链（SHIP）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'SHP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'SHP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (9,'SHP1',1,1,1,'DOC','SHIP',0,11,3,1,1,1,2,NULL,NULL,NULL,NULL,3000,46000,46000,'2026-10-15','SHP1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (9,'SHP1:1:D1:1','SHP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,11,3,0,'2026-10-15')"])
expect_allow_tx('期初：stock 12', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'OPEN-MIG1',12,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'OPEN-MIG1' AND l.line_no = 12) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (10,'OPEN-MIG1',12,1,1,'DOC','OPENING',1,12,1,1,2,1,1,NULL,NULL,NULL,NULL,30000,0,30000,'2026-10-15','OPEN-MIG1:12:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (10,'OPEN-MIG1:12:D1:1','OPEN-MIG1',12,1,1,'DOC',NULL,NULL,NULL,NULL,12,1,1,'2026-10-15')"])
expect_allow_tx('PDA 拣货（四元组 77/3/DEV-A/1）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (11,'PK2',3,0,1,'PDA','PICK',-1,12,2,1,2,1,1,77,3,'DEV-A',1,1000,30000,29000,'2026-10-15','PK2:3:PDEV-A.1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (11,'PK2:3:PDEV-A.1:1','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,2,-1,'2026-10-15')"])
expect_block_tx('Idempotency-Key 过期后 PDA 重放同一四元组（换 idempotency_key）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (12,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',1,1000,29000,28000,'2026-10-15','X:replay')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (12,'X:replay','PK2',3,0,1,'PDA',77,3,'DEV-A',1,12,3,-1,'2026-10-15')"], 'stock_movement_key.src_task_id, stock_movement_key.src_line_no, stock_movement_key.device_instance_id, stock_movement_key.src_op_seq, stock_movement_key.leg')
expect_allow_tx('同一 PDA 行第二次合法操作（op_seq=2，不被吞）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-A' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (13,'PK2',3,0,1,'PDA','PICK',-1,12,3,1,2,1,1,77,3,'DEV-A',2,1000,29000,28000,'2026-10-15','PK2:3:PDEV-A.2:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (13,'PK2:3:PDEV-A.2:1','PK2',3,0,1,'PDA',77,3,'DEV-A',2,12,3,-1,'2026-10-15')"])
expect_block_tx('同一单据行 DOC 与 PDA 互斥（PDA 行上来一条 DOC 过账）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (14,'PK2',3,1,1,'DOC','PICK',-1,12,4,1,2,1,1,NULL,NULL,NULL,NULL,1000,28000,27000,'2026-10-15','PK2:3:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (14,'PK2:3:D1:1','PK2',3,1,1,'DOC',NULL,NULL,NULL,NULL,12,4,-1,'2026-10-15')"], 'ledger_line_owner_mismatch')
expect_block_tx('换设备实例不能直接记账（DEV-B 不是当前持有设备）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'PK2',3,'PDA','DEV-B' WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'PK2' AND l.line_no = 3) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (15,'PK2',3,0,1,'PDA','PICK',-1,12,4,1,2,1,1,77,3,'DEV-B',1,1000,28000,27000,'2026-10-15','PK2:3:PDEV-B.1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (15,'PK2:3:PDEV-B.1:1','PK2',3,0,1,'PDA',77,3,'DEV-B',1,12,4,-1,'2026-10-15')"], 'ledger_line_owner_mismatch')
expect_block_tx('PDA 业务键半截（device_instance_id 为 NULL）', ["INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (16,'PK3',1,0,1,'PDA','PICK',-1,12,4,1,2,1,1,78,1,NULL,1,1000,28000,27000,'2026-10-15','PK3:1:PDEV-A.1:1')"], 'ck_mv_kind')
expect_block_tx('只追加：UPDATE 流水', ["UPDATE stock_movement SET remark='x' WHERE id=4"], 'append_only_violation: stock_movement')
expect_block_tx('只追加：DELETE 去重键', ["DELETE FROM stock_movement_key WHERE movement_id=4"], 'append_only_violation: stock_movement_key')
expect_allow_tx('跨分区去重：10-31 记一条', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'XP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'XP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (17,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-10-31','XP1:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (17,'XP1:1:D1:1','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-10-31')"])
expect_block_tx('跨分区去重：同一键 11-01 再记（PG 落在另一个分区）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'XP1',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'XP1' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (18,'XP1',1,1,1,'DOC','SHIP',0,13,0,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,200000,'2026-11-01','X:xp')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (18,'X:xp','XP1',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,0,0,'2026-11-01')"], 'stock_movement_key.biz_no, stock_movement_key.line_no, stock_movement_key.op_no, stock_movement_key.leg')
expect_allow_tx('占用写入（RESERVE 10000）', ["INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (1,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED')"])
expect_block_tx('占用幂等（同 op_key）', ["INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,consumed_qty_milli,released_qty_milli,status) VALUES (2,11,'RESERVE','OUTBOUND_LINE',1,1,'RES:OBT1:1:1:11',10000,0,0,'RESERVED')"], 'reservation_duplicate')   # 第十一轮：trg_res_no_replace 先拦，uq_res_op 兜底
expect_block_tx('超消耗（consumed+released > reserve）', ["UPDATE stock_reservation SET consumed_qty_milli=6000, released_qty_milli=5000, status='CONSUMED' WHERE id=1"], 'ck_res')
expect_block_tx('状态与余量不符：全部释放但仍是 RESERVED（过期任务会漏/重复扫）', ["UPDATE stock_reservation SET released_qty_milli=10000 WHERE id=1"], 'ck_res_status')
expect_block_tx('状态与余量不符：余量>0 却标 RELEASED', ["UPDATE stock_reservation SET released_qty_milli=4000, status='RELEASED' WHERE id=1"], 'ck_res_status')
# #2 第九轮：预占过期时间由库计算（created_at + 最长 24h），调用方不能填永不过期；批次日期严格 YYYY-MM-DD
_R = "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status{c}) VALUES ({i},11,'RESERVE','OUTBOUND_LINE',1,{i},'RES:TTL:{i}',1000,'RESERVED'{v})"
expect_allow_tx('预占不带 expires_at：库补算 created_at + 24h', [_R.format(i=9101, c='', v='')])
r = one("SELECT CAST(strftime('%s', expires_at) AS INTEGER) - CAST(strftime('%s', created_at) AS INTEGER) FROM stock_reservation WHERE id=9101")
ok(f"预占 expires_at 由库算出 = created_at + 86400s（{r[0]}）") if r and r[0] == 86400 else bad(f"预占 expires_at 补算 = {r}")
expect_block_tx('预占 expires_at 填 2999 年（永不过期）', [_R.format(i=9102, c=',expires_at', v=",'2999-01-01 00:00:00'")], 'ck_res_ttl')
expect_block_tx('预占 expires_at 填 created_at + 24h + 1s', [_R.format(i=9103, c=',expires_at', v=",datetime('now','+86401 seconds')")], 'ck_res_ttl')
expect_block_tx('预占 expires_at 非 ISO（strftime 取不到）', [_R.format(i=9104, c=',expires_at', v=",'2999/01/01'")], 'ck_res_ttl')
expect_block_tx('预占 created_at 倒签/预签（与 now 差 > 300s）', [_R.format(i=9105, c=',created_at', v=",'2999-01-01 00:00:00'")], 'reservation_clock_skew')
expect_block_tx('预占 事后把 expires_at 改成 2999 年', ["UPDATE stock_reservation SET expires_at='2999-01-01 00:00:00' WHERE id=9101"], 'ck_res_ttl')
expect_block_tx('预占 事后改 created_at（借此抬高上界）', ["UPDATE stock_reservation SET created_at='2999-01-01 00:00:00' WHERE id=9101"], 'reservation_created_at_immutable')
expect_block_tx('预占 B1：事后把 expires_at 改成 NULL（永不过期）', ["UPDATE stock_reservation SET expires_at=NULL WHERE id=9101"], 'reservation_expires_null')
try:
    conn.execute("BEGIN"); conn.execute("DROP TRIGGER trg_res_expires_lock"); conn.execute("UPDATE stock_reservation SET expires_at=NULL WHERE id=9101")
    ok("变异：去掉 trg_res_expires_lock 后，expires_at 改成 NULL 通过（断言能抓到）") if one("SELECT expires_at FROM stock_reservation WHERE id=9101")[0] is None else bad("变异：去掉 trg_res_expires_lock 后 expires_at 不是 NULL")
except sqlite3.Error as e:
    bad(f"变异：去掉 trg_res_expires_lock 后改 NULL 仍被拒：{e}")
finally:
    conn.execute("ROLLBACK")
expect_allow_tx('预占 N1：缩短 TTL（expires_at = created_at + 1s）允许，更早释放更安全', ["UPDATE stock_reservation SET expires_at=datetime(created_at,'+1 seconds') WHERE id=9101"])
expect_block_tx('预占 N1：再延长到 created_at + 24h + 1s 仍拒', ["UPDATE stock_reservation SET expires_at=datetime(created_at,'+86401 seconds') WHERE id=9101"], 'ck_res_ttl')
expect_block_tx('批次 expiry_date 非 YYYY-MM-DD', ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9101,1,'LOT-D1','2026/10/25','2026-10-08')"], 'ck_lot_date')
expect_block_tx('批次 expiry_date 非真实日历日', ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9102,1,'LOT-D2','2026-02-30','2026-10-08')"], 'ck_lot_date')
expect_block_tx('批次 sell_deadline 带时间', ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,sell_deadline) VALUES (9103,1,'LOT-D3','2026-10-25','2026-10-08','2026-10-20 00:00:00')"], 'ck_lot_date')
expect_block_tx('批次 production_date 乱填', ["INSERT INTO lot (id,sku_id,lot_code,production_date,expiry_date,receive_date) VALUES (9104,1,'LOT-D4','zzzz','2026-10-25','2026-10-08')"], 'ck_lot_date')
for _bad in ('2026/10/15', ' 2026-10-15', '2026-02-30', '20261015', '2026-10-15T00:00:00Z', '2026-10-15 00:00:00.5', '2026-10-15 08:00:00', '2026-10-15 00:00:00', '2026-10-15 24:00:00', '2026-10-15+08:00', '2026-10-15Z', '2026-1-5'):
    expect_block_tx(f'批次 receive_date 非法：{_bad!r}', [f"INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9110,1,'LOT-R','2026-10-25','{_bad}')"], 'ck_lot_recv_ts')
expect_allow_tx('批次 receive_date 纯日期 YYYY-MM-DD（第十一轮：DATE only，带时间一律拒）', ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9111,1,'LOT-R2','2026-10-25','2026-10-15')"])
expect_block_tx('日快照 work_date 非 YYYY-MM-DD', ["INSERT INTO stock_snapshot_daily (work_date,stock_id,warehouse_id,location_id,sku_id,lot_id,on_hand_qty_milli,allocated_qty_milli,reserved_qty_milli,quality_hold_qty_milli,hold_qty_milli,ledger_seq) VALUES ('2026/10/15',11,1,1,1,2,0,0,0,0,0,0)"], 'ck_ssd_date')
def _ttl_mut(desc, drop_name, stmt):
    """变异：去掉约束（只改内存库 DDL）后，原被拒语句应当通过。"""
    ddl = sqlite_ddl.replace(f"CONSTRAINT {drop_name} CHECK (", f"CONSTRAINT {drop_name} CHECK (1 OR ", 1)   # 约束恒真 = 去掉
    if ddl == sqlite_ddl:
        bad(f"变异：没找到 {drop_name}，变异未生效"); return
    mc = sqlite3.connect(":memory:", isolation_level=None)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
    try:
        mc.executescript(ddl)
        [mc.execute(_q) for _q in _MASTER_MIN]
        mc.execute(stmt)
        ok(f"变异：去掉 {drop_name} 后，{desc} 通过（断言能抓到）")
    except sqlite3.Error as e:
        bad(f"变异：去掉 {drop_name} 后 {desc} 仍被拒：{e}")
    finally:
        mc.close()
_ttl_mut("预占 expires_at 填 2999 年", "ck_res_ttl", "INSERT INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status,expires_at) VALUES (9102,11,'RESERVE','OUTBOUND_LINE',1,9102,'RES:TTL:9102',1000,'RESERVED','2999-01-01 00:00:00')")
_ttl_mut("批次 receive_date 带时间 2026-10-15 08:00:00", "ck_lot_recv_ts", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9112,1,'LOT-R3','2026-10-25','2026-10-15 08:00:00')")
_ttl_mut("批次 receive_date 2026/10/15", "ck_lot_recv_ts", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9110,1,'LOT-R','2026-10-25','2026/10/15')")
_ttl_mut("批次 expiry_date 2026/10/25", "ck_lot_date", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (9101,1,'LOT-D1','2026/10/25','2026-10-08')")
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
# 第十三轮（r12 非阻塞 1）：RESOLVED 终态锁；未闭环告警的 UPSERT 不受影响（上面两条）
expect_block_tx('RESOLVED 告警不可再改（resolution 抹空）', ["UPDATE stock_recon_alert SET resolution = NULL, resolved_by = NULL WHERE id = 1"], 'recon_resolved_immutable')
expect_block_tx('RESOLVED 告警不可同 id REPLACE（重置 detected_at / 改 stock_id）', ["REPLACE INTO stock_recon_alert (id,check_code,warehouse_id,stock_id,expected_qty_milli,actual_qty_milli) VALUES (1,'I4',1,14,1,1)"], 'stock_recon_alert.id')
expect_allow_tx('变异：去掉 trg_recon_resolved_lock 后可改 RESOLVED 告警', ["DROP TRIGGER trg_recon_resolved_lock", "UPDATE stock_recon_alert SET resolution = NULL WHERE id = 1"])
expect_allow_tx('未闭环告警仍可 UPDATE（认领 ACKED）', ["UPDATE stock_recon_alert SET status = 'ACKED' WHERE id = 4"])
print("=== 2b2. 小赵复评 C2–C4 + convert_hold ===")
expect_block_tx('C2 只写流水、不写 key 行（库层外键，提交时拦）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ7',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ7' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (30,'ADJ7',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1')"], 'FOREIGN KEY constraint failed')
expect_block_tx('C2 key 行与流水内容不一致（key=ADJ7，流水=ADJ6）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'ADJ7',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'ADJ7' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING", "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES (31,'ADJ6',1,1,1,'DOC','ADJUST',-1,13,1,1,3,1,3,NULL,NULL,NULL,NULL,1000,200000,199000,'2026-10-15','ADJ7:1:D1:1')", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES (31,'ADJ7:1:D1:1','ADJ7',1,1,1,'DOC',NULL,NULL,NULL,NULL,13,1,-1,'2026-10-15')"], 'FOREIGN KEY constraint failed')
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
# 第 11 篇时间加固：*_now 触发器只收 now±300s。下面这些历史时间种子临时 DROP、写完按原文重建（同 outbox 种子路径）
_T11 = ('trg_idem_created_now', 'trg_idem_expires_past', 'trg_idem_expires_ttl', 'trg_upl_received_now', 'trg_paper_submitted_now', 'trg_paper_approved_now')
_T11_SQL = {}
def t11_seed_begin():
    for n in _T11:
        _T11_SQL[n] = conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (n,)).fetchone()[0]
        conn.execute(f"DROP TRIGGER {n}")
    conn.commit()
def t11_seed_end():
    for n in _T11: conn.execute(_T11_SQL[n])
    conn.commit()
def outbox_seed_begin(): conn.execute("DROP TRIGGER trg_outbox_insert_pending"); t11_seed_begin()
def outbox_seed_end(): conn.execute(_OB_TRG); t11_seed_end()
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
t11_seed_begin()
conn.execute("INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('tz_live12h','h','{}',200,datetime('now','+12 hours')),('tz_dead','h','{}',200,datetime('now','-1 hour'))")
t11_seed_end()
old_tz = os.environ.get('TZ')
# Windows 不自带 IANA 时区库，`time.tzset()` 在 Windows 上不存在（会 AttributeError）。
# 该断言要证的是：清理行数不随进程时区变化（SQLite `datetime('now')` 本身就是 UTC）。
# Windows 上无法真正切换进程时区，这里仅跳过切换、仍跑两次断言，POSIX 上行为不变。
tzset = getattr(time, 'tzset', None)
for tz in ('Etc/GMT-8', 'Etc/GMT+10'):   # POSIX 记号相反：Etc/GMT-8 = UTC+8，Etc/GMT+10 = UTC-10
    os.environ['TZ'] = tz
    if tzset: tzset()
    conn.execute("SAVEPOINT tz")
    cnt[tz] = conn.execute("DELETE FROM idempotency_record WHERE expires_at < datetime('now')").rowcount
    conn.execute("ROLLBACK TO tz"); conn.execute("RELEASE tz")
if old_tz is None: os.environ.pop('TZ', None)
else: os.environ['TZ'] = old_tz
if tzset: tzset()
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
 (5001,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'HOLD','5001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5002,'APR-WHSH01-20261015-000002','CANCEL_AFTER_PICK',1,'HOLD','5002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5003,'APR-WHSH01-20261015-000003','CANCEL_AFTER_PICK',1,'HOLD','5003','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5004,'APR-WHSH01-20261015-000004','CANCEL_AFTER_PICK',1,'HOLD','5004','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5009,'APR-WHSH01-20261015-000009','CANCEL_AFTER_PICK',1,'HOLD','5009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5099,'APR-WHSH01-20261015-000099','CANCEL_AFTER_PICK',1,'HOLD','5099','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5123,'APR-WHSH01-20261015-000123','CANCEL_AFTER_PICK',1,'HOLD','5123','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5999,'APR-WHSH01-20261231-999999','CANCEL_AFTER_PICK',1,'HOLD','5999','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5160,'APR-Z9Z9Z9Z9Z9Z9Z9Z9-20260101-000000','CANCEL_AFTER_PICK',91,'HOLD','5160','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5011,'APR-W1-20261015-000001','CANCEL_AFTER_PICK',90,'HOLD','5011','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5000,'APR-WHSH01-20260101-000000','CANCEL_AFTER_PICK',1,'HOLD','5000','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL),
 (5029,'APR-WHSH01-20280229-000001','CANCEL_AFTER_PICK',1,'HOLD','5029','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2f3 底数',201,NULL)
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

print("=== 2d3. G19：COUNT（盘盈/盘亏）放行库位锁，post_in / post_out 同口径；其他来源仍拦 ===")
conn.execute("SAVEPOINT g19")   # 本段完全回滚，不留副作用
conn.execute("UPDATE location SET status = 'LOCKED' WHERE id = 3")
POSTIN_G19 = ("UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli + 1000, ledger_seq = ledger_seq + 1, version = version + 1 "
              "WHERE id = 13 AND (? IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
POSTOUT_G19 = ("UPDATE stock SET on_hand_qty_milli = on_hand_qty_milli - 1000, ledger_seq = ledger_seq + 1, version = version + 1 "
               "WHERE id = 13 AND on_hand_qty_milli - allocated_qty_milli - reserved_qty_milli - quality_hold_qty_milli - hold_qty_milli >= 1000 "
               "AND (? IN ('COUNT','REVERSE_PICK') OR EXISTS (SELECT 1 FROM location l WHERE l.id = stock.location_id AND l.status <> 'LOCKED'))")
c = conn.execute(POSTIN_G19, ("COUNT",)).rowcount
ok("G19 库位 LOCKED：post_in(COUNT) 盘盈入账 rowcount=1") if c == 1 else bad(f"G19 盘盈被锁拦 rowcount={c}")
c = conn.execute(POSTOUT_G19, ("COUNT",)).rowcount
ok("G19 库位 LOCKED：post_out(COUNT) 盘亏过账 rowcount=1") if c == 1 else bad(f"G19 盘亏被锁拦 rowcount={c}")
c = conn.execute(POSTOUT_G19, ("SCRAP",)).rowcount
ok("G19 库位 LOCKED：post_out(SCRAP) rowcount=0（→ 40906）") if c == 0 else bad(f"G19 SCRAP 未被锁拦 rowcount={c}")
c = conn.execute(POSTOUT_G19, ("ADJUST",)).rowcount
ok("G19 库位 LOCKED：post_out(ADJUST) rowcount=0（待 08 篇定，§12 Q13）") if c == 0 else bad(f"G19 ADJUST 未被锁拦 rowcount={c}")
conn.execute("ROLLBACK TO g19"); conn.execute("RELEASE g19")

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
_c = conn.execute("PRAGMA foreign_keys=OFF").fetchall(); _fk_off_allowed = True
expect_block('10 建议 2 SQLite 连接漏开 foreign_keys 仍拦未知异常码', "INSERT INTO exception_case (id,code,warehouse_id,exception_code,source_type,source_key,source_hash,sku_id,lot_id,claimed_qty_milli,counted_qty_milli,diff_qty_milli,due_at,reporter_id) VALUES (198,'EXC-198',1,'NO_SUCH','MANUAL','M:198','00000000000000000000000000000000000000000000000000000000000000c6',1,1,0,0,0,'2026-10-15 12:00:00',7)", 'exc_code_unknown')
_c = conn.execute("PRAGMA foreign_keys=ON").fetchall(); _fk_off_allowed = False
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

# 18 种子路径：18 的遗留用例用固定日期，先摘掉时钟触发器（等同 PG 属主豁免），2h-clock 段重建后再测容差
_TOL18 = ['trg_li_zclock','trg_lw_zclock','trg_ld_zclock','trg_lth_zclock','trg_lth_zclock_ins']
_T18 = {n: one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", n)[0] for n in _TOL18}
for _n in _TOL18: conn.execute('DROP TRIGGER ' + _n)
conn.commit()
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
expect_allow_tx('17 种子：SKU 原料三文鱼/鱼柳/鱼骨/按件鸡腿、库位、批次', ["INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (1701,'SKU-SALMON','三文鱼整鱼','KG','CHILLED',6,1,3),(1702,'SKU-FILLET','三文鱼柳','KG','CHILLED',3,1,2),(1703,'SKU-BONE','三文鱼骨','KG','CHILLED',2,0,1),(1704,'SKU-LEG','鸡腿（定量装）','EA','CHILLED',5,1,3)", "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (1790,1,2,'PC-01','FLOOR',99,'P010'),(1791,1,2,'C-01-01','PALLET',8,'C010'),(1792,1,1,'A09-01-01','BIN',8,'A090')", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1701,1701,'L-RAW1','2026-10-20','2026-10-14'),(1760,1702,'L-FIL1','2026-10-18','2026-10-15'),(1761,1703,'L-BON1','2026-10-17','2026-10-15'),(1762,1702,'L-FIL2','2026-10-18','2026-10-15'),(1763,1702,'L-FIL3','2026-10-18','2026-10-15'),(1764,1704,'L-LEG1','2026-10-19','2026-10-14'),(1765,1703,'L-BON2','2026-10-17','2026-10-15')"])
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
print("=== 2h-ck. docs/17 CHECK 三件套（按名拒绝 + 变异；本轮第一批 12 个，与 verify.sh 2h-ck 同名）===")
def _m17_ck(name, stmts):
    conn.execute("PRAGMA ignore_check_constraints = ON")
    try:
        expect_allow_tx(f"17 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        conn.execute("PRAGMA ignore_check_constraints = OFF")
conn.execute("INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1870,1702,'L-CK1','2026-10-18','2026-10-15')")
conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1830,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:ck0',1000,0)")
conn.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id) VALUES (1831,1782,'PROCESSING','PROCESSING','PROCESS_ORDER',1710,'PRCI:1710:ck9',1000,0)")
expect_block_tx("17 ck_pbom_status 非法状态值", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status,activated_at) VALUES (1801,1,'BOM-CK1',1,'x',4000,5000,8,'BOGUS','2026-10-15 01:00:00')"], "ck_pbom_status")
_m17_ck("ck_pbom_status", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status,activated_at) VALUES (1801,1,'BOM-CK1',1,'x',4000,5000,8,'BOGUS','2026-10-15 01:00:00')"])
expect_block_tx("17 ck_pbom_yield 出成率下限 > 上限", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1802,1,'BOM-CK2',1,'x',6000,5000,8)"], "ck_pbom_yield")
_m17_ck("ck_pbom_yield", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1802,1,'BOM-CK2',1,'x',6000,5000,8)"])
expect_block_tx("17 ck_pbom_tol 称重容差 > 10%", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,balance_tol_bp,created_by) VALUES (1803,1,'BOM-CK3',1,'x',4000,5000,1001,8)"], "ck_pbom_tol")
_m17_ck("ck_pbom_tol", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,balance_tol_bp,created_by) VALUES (1803,1,'BOM-CK3',1,'x',4000,5000,1001,8)"])
expect_block_tx("17 ck_pbom_act ACTIVE 却没 activated_at", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status) VALUES (1804,1,'BOM-CK4',1,'x',4000,5000,8,'ACTIVE')"], "ck_pbom_act")
_m17_ck("ck_pbom_act", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by,status) VALUES (1804,1,'BOM-CK4',1,'x',4000,5000,8,'ACTIVE')"])
expect_block_tx("17 ck_pboml_qty BOM 行标准量为 0", ["INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1801,1702,1,'INPUT',1701,0)"], "ck_pboml_qty")
_m17_ck("ck_pboml_qty", ["INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1801,1702,1,'INPUT',1701,0)"])
expect_block_tx("17 ck_prc_nonneg 计划量为负", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1811,1,'PRC-CK1','2026-10-15',1701,1790,-1,8)"], "ck_prc_nonneg")
_m17_ck("ck_prc_nonneg", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1811,1,'PRC-CK1','2026-10-15',1701,1790,-1,8)"])
expect_block_tx("17 ck_prc_reverse 累计冲回 > 累计领用", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,issued_qty_milli,reversed_qty_milli) VALUES (1812,1,'PRC-CK2','2026-10-15',1701,1790,100,8,100,101)"], "ck_prc_reverse")
_m17_ck("ck_prc_reverse", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,issued_qty_milli,reversed_qty_milli) VALUES (1812,1,'PRC-CK2','2026-10-15',1701,1790,100,8,100,101)"])
expect_block_tx("17 ck_prci_qty 领用量为 0", ["INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1811,1,1710,9,'PRCI:1710:ck1',1791,'PALLET',1781,1782,1830,1701,1701,'2026-10-20',0,21)"], "ck_prci_qty")
_m17_ck("ck_prci_qty", ["INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1811,1,1710,9,'PRCI:1710:ck1',1791,'PALLET',1781,1782,1830,1701,1701,'2026-10-20',0,21)"])
expect_block_tx("17 ck_prci_op op_key 前缀不是 PRCI:", ["INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1812,1,1710,8,'NOPE:1710:ck2',1791,'PALLET',1781,1782,1831,1701,1701,'2026-10-20',1,21)"], "ck_prci_op")
_m17_ck("ck_prci_op", ["INSERT INTO process_issue (id,warehouse_id,process_order_id,line_no,op_key,src_location_id,src_location_type,src_stock_id,pc_stock_id,hold_id,sku_id,lot_id,lot_expiry_date,issue_qty_milli,issued_by) VALUES (1812,1,1710,8,'NOPE:1710:ck2',1791,'PALLET',1781,1782,1831,1701,1701,'2026-10-20',1,21)"])
expect_block_tx("17 ck_prco_int 非整数净重", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1811,1,1710,1740,9,'FINISHED',1702,1870,1792,1.5,0,1.5,'2026-10-15 03:00:00','2026-10-18','2026-10-20')"], "ck_prco_int")
_m17_ck("ck_prco_int", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1811,1,1710,1740,9,'FINISHED',1702,1870,1792,1.5,0,1.5,'2026-10-15 03:00:00','2026-10-18','2026-10-20')"])
expect_block_tx("17 ck_prcr_http 回执状态码不是 200/202", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1811,1,1710,'00000000-0000-4000-8000-000000001811','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',99,201,'{}',21)"], "ck_prcr_http")
_m17_ck("ck_prcr_http", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1811,1,1710,'00000000-0000-4000-8000-000000001811','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',99,201,'{}',21)"])
expect_block_tx("17 ck_plt_self 成品批与原料批同批", ["INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1811,1,1710,1750,1760,1721,1760)"], "ck_plt_self")
_m17_ck("ck_plt_self", ["INSERT INTO process_lot_trace (id,warehouse_id,process_order_id,output_id,output_lot_id,issue_id,raw_lot_id) VALUES (1811,1,1710,1750,1760,1721,1760)"])
print("=== 2h-ck2. docs/17 CHECK 三件套第二批（按名拒绝 + 变异；两库同名）===")
conn.execute("INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (1871,1702,'L-CK2','2026-10-18','2026-10-15'),(1872,1702,'L-CK3','2026-10-18','2026-10-15'),(1873,1702,'L-CK4','2026-10-18','2026-10-15'),(1874,1702,'L-CK5','2026-10-18','2026-10-15'),(1875,1702,'L-CK6','2026-10-18','2026-10-15')")
expect_block_tx("17 ck_pbom_ver 版本号 < 1", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1901,1,'BOM-CK5',0,'x',4000,5000,8);"], "ck_pbom_ver")
_m17_ck("ck_pbom_ver", ["INSERT INTO process_bom (id,warehouse_id,code,bom_version,name,yield_min_bp,yield_max_bp,created_by) VALUES (1901,1,'BOM-CK5',0,'x',4000,5000,8);"])
expect_block_tx("17 ck_pboml_role 非法行角色", ["INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1901,1702,7,'BOGUS',1701,1000);"], "ck_pboml_role")
_m17_ck("ck_pboml_role", ["INSERT INTO process_bom_line (id,bom_id,line_no,line_role,sku_id,std_qty_milli) VALUES (1901,1702,7,'BOGUS',1701,1000);"])
conn.execute("INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1901,1,'PRC-CK3','2026-10-15',1701,1790,1000,8)")
expect_block_tx("17 ck_prc_snapshot 下达却不带快照列", ["UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00' WHERE id=1901;"], "ck_prc_snapshot")
_m17_ck("ck_prc_snapshot", ["UPDATE process_order SET status='RELEASED', released_at='2026-10-15 02:00:00' WHERE id=1901;"])
conn.execute("INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1902,1,'PRC-CK4','2026-10-15',1701,1790,1000,8)")
expect_block_tx("17 ck_prc_done 未完工却写 completed_at", ["UPDATE process_order SET completed_at='2026-10-15 03:00:00' WHERE id=1902;"], "ck_prc_done")
_m17_ck("ck_prc_done", ["UPDATE process_order SET completed_at='2026-10-15 03:00:00' WHERE id=1902;"])
expect_block_tx("17 ck_prc_yrange 出成率下限为 0", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,yield_min_bp) VALUES (1903,1,'PRC-CK5','2026-10-15',1701,1790,1000,8,0);"], "ck_prc_yrange")
_m17_ck("ck_prc_yrange", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by,yield_min_bp) VALUES (1903,1,'PRC-CK5','2026-10-15',1701,1790,1000,8,0);"])
expect_block_tx("17 ck_prco_net 净重 ≠ 毛重 − 皮重", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1911,1,1710,1741,5,'FINISHED',1702,1871,1792,100,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-20');"], "ck_prco_net")
_m17_ck("ck_prco_net", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1911,1,1710,1741,5,'FINISHED',1702,1871,1792,100,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-20');"])
expect_block_tx("17 ck_prco_reverse 产出冲回 > 产出量", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,reversed_qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1912,1,1710,1741,6,'FINISHED',1702,1872,1792,120,20,100,101,'2026-10-15 03:00:00','2026-10-18','2026-10-20');"], "ck_prco_reverse")
_m17_ck("ck_prco_reverse", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,reversed_qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1912,1,1710,1741,6,'FINISHED',1702,1872,1792,120,20,100,101,'2026-10-15 03:00:00','2026-10-18','2026-10-20');"])
expect_block_tx("17 ck_prco_expiry 成品效期晚于原料最早效期", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1913,1,1710,1741,7,'FINISHED',1702,1873,1792,120,20,100,'2026-10-15 03:00:00','2026-10-25','2026-10-20');"], "ck_prco_expiry")
_m17_ck("ck_prco_expiry", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry) VALUES (1913,1,1710,1741,7,'FINISHED',1702,1873,1792,120,20,100,'2026-10-15 03:00:00','2026-10-25','2026-10-20');"])
expect_block_tx("17 ck_prco_sell 可售期晚于效期", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,sell_deadline,earliest_raw_expiry) VALUES (1914,1,1710,1741,8,'FINISHED',1702,1874,1792,120,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-19','2026-10-20');"], "ck_prco_sell")
_m17_ck("ck_prco_sell", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,sell_deadline,earliest_raw_expiry) VALUES (1914,1,1710,1741,8,'FINISHED',1702,1874,1792,120,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-19','2026-10-20');"])
expect_block_tx("17 ck_prco_loss_status 非 LOSS 行却挂损耗定案状态", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,loss_status) VALUES (1915,1,1710,1741,9,'FINISHED',1702,1875,1792,120,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-20','PENDING_APPROVAL');"], "ck_prco_loss_status")
_m17_ck("ck_prco_loss_status", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,lot_id,to_location_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,expiry_date,earliest_raw_expiry,loss_status) VALUES (1915,1,1710,1741,9,'FINISHED',1702,1875,1792,120,20,100,'2026-10-15 03:00:00','2026-10-18','2026-10-20','PENDING_APPROVAL');"])
expect_block_tx("17 ck_prco_loss_settle 待审批行却带获批量", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,scrap_order_id,loss_reason,loss_status,loss_approved_qty_milli) VALUES (1916,1,1710,1741,10,'LOSS',1701,120,20,100,'2026-10-15 03:00:00',9001,'TRIM','PENDING_APPROVAL',5);"], "ck_prco_loss_settle")
_m17_ck("ck_prco_loss_settle", ["INSERT INTO process_output (id,warehouse_id,process_order_id,report_id,line_no,output_role,sku_id,gross_qty_milli,tare_qty_milli,qty_milli,processed_at,scrap_order_id,loss_reason,loss_status,loss_approved_qty_milli) VALUES (1916,1,1710,1741,10,'LOSS',1701,120,20,100,'2026-10-15 03:00:00',9001,'TRIM','PENDING_APPROVAL',5);"])
expect_block_tx("17 ck_prcr_client report_client_id 不是 UUID 形状", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1921,1,1710,'x','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',96,200,'{}',21);"], "ck_prcr_client")
_m17_ck("ck_prcr_client", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1921,1,1710,'x','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',96,200,'{}',21);"])
expect_block_tx("17 ck_prcr_hash request_hash 不是 64 位", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1922,1,1710,'00000000-0000-4000-8000-000000001922','abc',97,200,'{}',21);"], "ck_prcr_hash")
_m17_ck("ck_prcr_hash", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1922,1,1710,'00000000-0000-4000-8000-000000001922','abc',97,200,'{}',21);"])
expect_block_tx("17 ck_prcr_seq 报工序号 < 1", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1923,1,1710,'00000000-0000-4000-8000-000000001923','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,200,'{}',21);"], "ck_prcr_seq")
_m17_ck("ck_prcr_seq", ["INSERT INTO process_report (id,warehouse_id,process_order_id,report_client_id,request_hash,report_seq,response_http,response,reported_by) VALUES (1923,1,1710,'00000000-0000-4000-8000-000000001923','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,200,'{}',21);"])
expect_block_tx("17 ck_prcv_qty 冲回量为 0", ["INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,issue_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1931,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001931','ISSUE',1720,0,'PRCR-1710:1:D1:1',1735,'x',9);"], "ck_prcv_qty")
_m17_ck("ck_prcv_qty", ["INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,issue_id,qty_milli,movement_ref,hold_release_id,reason,operator_id) VALUES (1931,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001931','ISSUE',1720,0,'PRCR-1710:1:D1:1',1735,'x',9);"])
expect_block_tx("17 ck_prcv_apr 返工审批单号长度不足", ["INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,output_id,qty_milli,movement_ref,reason,operator_id) VALUES (1932,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001932','OUTPUT','REWORK','APR-X',1750,1,'PRCR-1710:1:D1:1','x',9);"], "ck_prcv_apr")
_m17_ck("ck_prcv_apr", ["INSERT INTO process_reversal (id,warehouse_id,process_order_id,op_key,reversal_type,disposition,approval_no,output_id,qty_milli,movement_ref,reason,operator_id) VALUES (1932,1,1710,'PRCR:1710:00000000-0000-4000-8000-000000001932','OUTPUT','REWORK','APR-X',1750,1,'PRCR-1710:1:D1:1','x',9);"])
expect_block_tx("17 ck_prc_int 非整数计划量", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1904,1,'PRC-CK6','2026-10-15',1701,1790,1.5,8)"], "ck_prc_int")
_m17_ck("ck_prc_int", ["INSERT INTO process_order (id,warehouse_id,code,work_date,bom_id,process_location_id,planned_input_qty_milli,created_by) VALUES (1904,1,'PRC-CK6','2026-10-15',1701,1790,1.5,8)"])
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
expect_allow_tx('18 种子：活鲜 SKU 3、池 61（LIVE_TANK）、普通位 62、批次 31/32、stock 6101/6102', ["INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (61,1,2,'LT-01','LIVE_TANK',4,'L010'),(62,1,2,'B09-01-01','BIN',2,'L020')", "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (3,'SKU-CRAB','阳澄湖大闸蟹','KG','CHILLED',7,1,3)", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (31,3,'LOT-C1','2026-10-22','2026-10-15','QUALIFIED',7),(32,3,'LOT-C2','2026-10-23','2026-10-16','QUALIFIED',7)", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (6101,1,61,3,31,'KG',50000),(6102,1,61,3,32,'KG',20000)"])
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
expect_block_tx('18 D1 DEDUCTED 改回 PENDING', ["UPDATE live_death SET deduct_status='PENDING', movement_id=NULL, deducted_qty_milli=0 WHERE id=6154"], 'live_death_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC')
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
expect_block('11 同节点 seq 重复（回传顺序被破坏）', "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (101,'wms.shipment.completed','SHP2','{}',1,3,1)", 'outbox_duplicate')   # X2：no-REPLACE 守卫覆盖该唯一键，先于 UNIQUE 报错
expect_allow('11 不同节点同 seq 合法', "INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (102,'wms.shipment.completed','SHP3','{}',1,4,1)")
expect_block('11 outbox 非法状态', "UPDATE outbox_event SET status='LOST' WHERE id=100", 'ck_outbox_status')
expect_allow('11 入站报文落库', "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (100,'ERP','SALES_ORDER','SO-1','{}','h1')")
expect_block('11 同源同单号重复落库', "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha) VALUES (101,'ERP','SALES_ORDER','SO-1','{}','h2')", 'inbound_message_duplicate')   # trg_in_msg_no_replace 覆盖 uq_in_msg，先于 UNIQUE 报错
expect_block('11 入站报文非法状态', "UPDATE inbound_message SET status='OK' WHERE id=100", 'ck_in_msg_status')

t11_seed_begin()
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
expect_block("11 I1 SQLite ISO T 写法不是标准整秒格式（00 §6.8，时间加固起拒）", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (14,'ERP','SALES_ORDER','SO-14','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15T01:00:00','ACCEPTED','2027-01-13T01:00:00')", 'ck_upl_retain')
expect_block("11 I1 SQLite ISO T 写法 89 天", "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES (15,'ERP','SALES_ORDER','SO-15','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}','2026-10-15T01:00:00','ACCEPTED','2027-01-12T01:00:00')", 'ck_upl_retain')
t11_seed_end()
r = one("SELECT count(*) FROM upstream_push_log WHERE id IN (1,2,8,20)")
ok(f"11 B1 绕过尝试后日志仍在（{r[0]} 行）") if r[0] == 4 else bad(f"11 日志被动过：{r}")
print("=== 2i2. docs/11 小吴 C1 死信阻塞同 biz_key / C2 409 判定 / C3 形态 A relay 补 seq ===")
expect_allow_tx('C1 同一单 3 个事件入队（OBT-C1：创建/变更/取消）', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq) VALUES (9101,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9102,'wms.outbound.changed','OBT-C1','{}',1,0,0),(9103,'wms.outbound.changed','OBT-C1','{}',1,0,0)"])
expect_allow_tx('C1 第 1 个事件投递成功（SENDING→SENT 2XX）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9101", "UPDATE outbox_event SET status='SENT', ack_kind='2XX', sent_at=datetime('now') WHERE id=9101"])
expect_allow_tx('C1 第 2 个事件进死信（SENDING→FAILED→DEAD）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9102", "UPDATE outbox_event SET status='FAILED' WHERE id=9102", "UPDATE outbox_event SET status='DEAD' WHERE id=9102"])
expect_block_tx('C1 第 3 个事件在前序 DEAD 时不能投递（验收用例）', ["UPDATE outbox_event SET status='SENDING' WHERE id=9103"], 'outbox_bizkey_blocked')
outbox_seed_begin()  # DEAD 种子走种子路径（应用只能插入 PENDING）
expect_block_tx('C1 同一 biz_key 第二条 DEAD', ["INSERT INTO outbox_event (id,topic,biz_key,payload,warehouse_id,node_id,seq,status) VALUES (9104,'wms.outbound.changed','OBT-C1','{}',1,0,0,'DEAD')"], 'outbox_duplicate')   # X2：no-REPLACE 守卫覆盖该唯一键，先于 UNIQUE 报错
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
t11_seed_begin()
expect_allow_tx("Q1 正向：提交 PENDING（恢复联网后 14h，窗口内）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (11,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')"])
expect_allow_tx("Q1 正向：主管（≠ 申请人）审批通过", ["UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2026-10-15 11:00:00' WHERE id=11"])
expect_allow_tx("Q1 正向：过期补录落 EXPIRED 并挂异常单", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (12,1,'PDA-07','PICK_CONFIRM','PK-L2','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',5001,'PAPER_BACKFILL')"])
expect_block_tx("Q1 反向：自批（审批人 = 申请人）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (13,1,'PDA-07','PICK_CONFIRM','PK-L3','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')", "UPDATE offline_paper_record SET status='APPROVED', approver_id=7, approved_at='2026-10-15 11:00:00' WHERE id=13"], "ck_paper_sod")
expect_block_tx("Q1 反向：backfill_deadline_at ≠ 恢复联网 + 24h（写成 +12h）", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (14,1,'PDA-07','PICK_CONFIRM','PK-L4','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 08:00:00','2026-10-15 07:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "ck_paper_deadline")
expect_block_tx("Q1 反向：过期后仍以 PENDING 提交", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (15,1,'PDA-07','PICK_CONFIRM','PK-L5','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "ck_paper_expired")
expect_block_tx("Q1 反向：过期但不挂异常单", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (16,1,'PDA-07','PICK_CONFIRM','PK-L6','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 21:00:00','EXPIRED',NULL,'PAPER_BACKFILL')"], "ck_paper_expired")
expect_block_tx("Q1 反向：审批类型不是 PAPER_BACKFILL", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (17,1,'PDA-07','PICK_CONFIRM','PK-L7','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'SCRAP_MISREPORT')"], "ck_paper_type")
expect_block_tx("Q1 反向：APPROVED 不带审批人", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (18,1,'PDA-07','PICK_CONFIRM','PK-L8','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')", "UPDATE offline_paper_record SET status='APPROVED' WHERE id=18"], "ck_paper_approve")
expect_block_tx("Q1 反向：同仓同 biz_key 重复补录", ["INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (19,1,'PDA-07','PICK_CONFIRM','PK-L1','2026-10-14 10:00:00',11,'{}',7,'2026-10-14 08:00:00','2026-10-14 20:00:00','2026-10-15 20:00:00','2026-10-15 10:00:00','PENDING',NULL,'PAPER_BACKFILL')"], "paper_duplicate")   # 00 §6.10 第 6 条：no-REPLACE 触发器报自己的错误名
t11_seed_end()
r = one("SELECT group_concat(id || ':' || status) FROM (SELECT id, status FROM offline_paper_record ORDER BY id)")[0]
ok("Q1 反向用例全部回滚，只剩 11:APPROVED、12:EXPIRED") if r == "11:APPROVED,12:EXPIRED" else bad(f"Q1 残留：{r}")
print("=== 2i4. 第 11 篇时间加固（小玛丽 time-scan 11-1…11-6；00 §6.8）===")
_UPL = "INSERT INTO upstream_push_log (id,source_system,biz_type,source_order_no,payload_sha,payload,received_at,result_status,retain_until) VALUES ({id},'ERP','SALES_ORDER','SO-T{id}','" + "c" * 64 + "','{{}}',{rv},'ACCEPTED',{rt})"
_PAP = "INSERT INTO offline_paper_record (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES ({id},1,'PDA-07','PICK_CONFIRM','PK-T{id}',{oc},11,'{{}}',7,{of},{rc},{dl},{sb},'PENDING',NULL,'PAPER_BACKFILL')"
def t11_mut(desc, trg, stmts, check):
    """变异：去掉 trg 后同一攻击必须成功（证明对应拒绝用例会变红），结束后整体回滚"""
    conn.execute("SAVEPOINT m11")
    try:
        conn.execute(f"DROP TRIGGER {trg}")
        for x in stmts: conn.execute(x)
        r = conn.execute(check).fetchone()[0]
        ok(f"{desc} → 变异后攻击成功（{r}），拒绝用例会变红") if r else bad(f"{desc} → 变异后仍拦/未生效")
    except sqlite3.Error as e:
        bad(f"{desc} → 变异后仍被拦：{e}")
    finally:
        conn.execute("ROLLBACK TO m11"); conn.execute("RELEASE m11")
_old = "'2000-01-01 00:00:00'"
_a = _UPL.format(id=40, rv=_old, rt="'2000-04-01 00:00:00'")
expect_block_tx("11-1 推送日志倒填 received_at=2000-01-01", [_a], "upl_received_not_now")
expect_block_tx("11-1 推送日志 received_at 晚 301 秒", [_UPL.format(id=41, rv="datetime('now','+301 seconds')", rt="datetime('now','+91 days')")], "upl_received_not_now")
expect_block_tx("11-1 推送日志 received_at 带 -09:00 偏移（非标准）", [_UPL.format(id=42, rv="datetime('now') || '-09:00'", rt="datetime('now','+91 days')")], "ck_upl_retain")
expect_allow_tx("11-1 正向：received_at = now、retain +90 天", [_UPL.format(id=43, rv="datetime('now')", rt="datetime('now','+90 days')")])
t11_mut("11-1 变异 DROP trg_upl_received_now", "trg_upl_received_now", [_a], "SELECT count(*) FROM upstream_push_log WHERE id=40")
expect_block_tx("§6.10 推送日志 INSERT OR REPLACE 改写已有行（id=43）", [_UPL.replace("INSERT INTO", "INSERT OR REPLACE INTO").format(id=43, rv="datetime('now')", rt="datetime('now','+120 days')")], "append_only_violation: upstream_push_log")
t11_mut("§6.10 变异 DROP trg_upl_no_replace", "trg_upl_no_replace", [_UPL.replace("INSERT INTO", "INSERT OR REPLACE INTO").format(id=43, rv="datetime('now')", rt="datetime('now','+120 days')")], "SELECT count(*) FROM upstream_push_log WHERE id=43 AND CAST(strftime('%s', retain_until) AS INTEGER) - CAST(strftime('%s', received_at) AS INTEGER) > 100 * 86400")
_p = "INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('t11past','h','{}',200,datetime('now','-1 hour'))"
expect_block_tx("11-2 idem expires_at 已过期（-1h）", [_p], "idem_expires_in_past")
expect_block_tx("11-2 idem created_at 倒填 2000 年", ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,created_at,expires_at) VALUES ('t11c','h','{}',200,'2000-01-01 00:00:00',datetime('now','+1 day'))"], "idem_created_not_now")
expect_block_tx("11-2 idem expires_at ≠ created_at + ttl（写成 +2099）", ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('t11t','h','{}',200,'2099-01-01 00:00:00')"], "idem_expires_not_ttl")
expect_allow_tx("11-2 正向：ttl_seconds=600、expires_at = now+600s", ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,ttl_seconds,expires_at) VALUES ('t11ok','h','{}',200,600,datetime('now','+600 seconds'))"])
expect_block_tx("11-2 正向记录不可立即清理（purge 守卫）", ["DELETE FROM idempotency_record WHERE idem_key='t11ok'"], "purge_not_allowed: idempotency_record")
expect_block_tx("11-2 ttl_seconds 超过 90 天", ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,ttl_seconds,expires_at) VALUES ('t11big','h','{}',200,7776001,datetime('now','+7776001 seconds'))"], "ck_idem_ttl")
t11_mut("11-2 变异 DROP trg_idem_expires_past", "trg_idem_expires_past", [_p], "SELECT count(*) FROM idempotency_record WHERE idem_key='t11past'")
_six = _PAP.format(id=40, oc="'2020-10-14 10:00:00'", of="'2020-10-14 08:00:00'", rc="'2020-10-14 20:00:00'", dl="'2020-10-15 20:00:00'", sb="'2020-10-14 20:00:00'")
expect_block_tx("11-5 6 年前补录写 submitted_at=reconnected_at 以 PENDING 提交", [_six], "paper_submitted_not_now")
t11_mut("11-5 变异 DROP trg_paper_submitted_now", "trg_paper_submitted_now", [_six], "SELECT count(*) FROM offline_paper_record WHERE id=40 AND status='PENDING'")
expect_block_tx("11-3 reconnected_at 不可解析（原 NULL 放行，截止可填 2099）", [_PAP.format(id=41, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="'garbage'", dl="'2099-01-01 00:00:00'", sb="datetime('now')")], "ck_paper_deadline")
expect_block_tx("11-4 submitted_at 带 -09:00 偏移（文本比较曾判未过期）", [_PAP.format(id=42, oc="datetime('now','-30 hours')", of="datetime('now','-31 hours')", rc="datetime('now','-30 hours')", dl="datetime('now','-6 hours')", sb="strftime('%Y-%m-%d %H:%M:%S','now','-9 hours') || '-09:00'")], "ck_paper_ts")
expect_block_tx("11-4 截止写成 T 格式（文本比较可提前 11 小时）", [_PAP.format(id=43, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="strftime('%Y-%m-%dT%H:%M:%S','now','+22 hours')", sb="datetime('now')")], "ck_paper_ts")
expect_allow_tx("11-5 正向：恢复联网 2 小时前，submitted_at = now", [_PAP.format(id=44, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')")])
expect_block_tx("11-5 审批 approved_at 倒填 2000 年", ["UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2000-01-01 00:00:00' WHERE id=44"], "paper_approved_not_now")
t11_mut("11-5 变异 DROP trg_paper_approved_now", "trg_paper_approved_now", ["UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at='2000-01-01 00:00:00' WHERE id=44"], "SELECT count(*) FROM offline_paper_record WHERE id=44 AND approved_at='2000-01-01 00:00:00'")
expect_allow_tx("11-5 正向：审批 approved_at = now", ["UPDATE offline_paper_record SET status='APPROVED', approver_id=8, approved_at=datetime('now') WHERE id=44"])
expect_block_tx("§6.10 纸质单 REPLACE 撞 (warehouse_id, biz_key) 换新 id（→ 40910 OFFLINE_PAPER）", [_PAP.replace("INSERT INTO", "REPLACE INTO").format(id=45, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')").replace("'PK-T45'", "'PK-T44'")], "paper_duplicate")
t11_mut("§6.10 变异 DROP trg_paper_no_replace", "trg_paper_no_replace", [_PAP.replace("INSERT INTO", "REPLACE INTO").format(id=45, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')").replace("'PK-T45'", "'PK-T44'")], "SELECT count(*) FROM offline_paper_record WHERE id=45 AND NOT EXISTS (SELECT 1 FROM offline_paper_record WHERE id=44)")
# ── 00 §6.10 / 小玛丽 pr2-r11 X2：第 11 篇 no-REPLACE 逐唯一键行为测试（每个 PK / UNIQUE / 部分唯一索引各打一次冲突 REPLACE）
print("=== 2i5. 第 11 篇 no-REPLACE 逐唯一键覆盖（X2）===")
_OB = "INSERT INTO outbox_event (id,topic,biz_key,payload,status,node_id,seq) VALUES ({id},'t','{bk}','{{}}','{st}',77,{seq})"
_REPCASES = [
  # (表, 唯一键, guard, 错误名, 种子语句, 冲突 REPLACE, 原行存活检查, 去掉该键子句后的 WHEN)
  ("outbox_event", "PK(id)", "trg_outbox_no_replace", "outbox_duplicate",
   [_OB.format(id=779100, bk="X2-A", st="PENDING", seq=99900)],
   _OB.replace("INSERT INTO", "REPLACE INTO").format(id=779100, bk="X2-B", st="PENDING", seq=99901),
   "SELECT count(*) FROM outbox_event WHERE id=779100 AND biz_key='X2-A'",
   "EXISTS (SELECT 1 FROM outbox_event o WHERE (NEW.seq > 0 AND o.seq > 0 AND o.node_id = NEW.node_id AND o.seq = NEW.seq) OR (NEW.status = 'DEAD' AND o.status = 'DEAD' AND o.biz_key = NEW.biz_key))"),
  ("outbox_event", "uq_outbox_seq(node_id,seq) WHERE seq>0", "trg_outbox_no_replace", "outbox_duplicate",
   [_OB.format(id=779100, bk="X2-A", st="PENDING", seq=99900)],
   _OB.replace("INSERT INTO", "REPLACE INTO").format(id=779101, bk="X2-B", st="PENDING", seq=99900),
   "SELECT count(*) FROM outbox_event WHERE id=779100",
   "EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id OR (NEW.status = 'DEAD' AND o.status = 'DEAD' AND o.biz_key = NEW.biz_key))"),
  ("outbox_event", "uq_outbox_dead_bizkey(biz_key) WHERE status='DEAD'", "trg_outbox_no_replace", "outbox_duplicate",
   ["DROP TRIGGER trg_outbox_insert_pending", _OB.format(id=779100, bk="X2-D", st="DEAD", seq=99900)],
   _OB.replace("INSERT INTO", "REPLACE INTO").format(id=779102, bk="X2-D", st="DEAD", seq=99902),
   "SELECT count(*) FROM outbox_event WHERE id=779100",
   "EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id OR (NEW.seq > 0 AND o.seq > 0 AND o.node_id = NEW.node_id AND o.seq = NEW.seq))"),
  ("idempotency_record", "PK(idem_key)", "trg_idem_no_replace", "idem_duplicate",
   ["INSERT INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('x2k','h1','{}',200,datetime('now','+1 day'))"],
   "REPLACE INTO idempotency_record (idem_key,req_hash,response,status_code,expires_at) VALUES ('x2k','h2','{}',200,datetime('now','+1 day'))",
   "SELECT count(*) FROM idempotency_record WHERE idem_key='x2k' AND req_hash='h1'", "0"),
  ("upstream_push_log", "PK(id)", "trg_upl_no_replace", "append_only_violation: upstream_push_log",
   [_UPL.format(id=150, rv="datetime('now')", rt="datetime('now','+90 days')")],
   _UPL.replace("INSERT INTO", "REPLACE INTO").format(id=150, rv="datetime('now')", rt="datetime('now','+120 days')"),
   "SELECT count(*) FROM upstream_push_log WHERE id=150 AND retain_until = datetime(received_at,'+90 days')", "0"),
  ("offline_paper_record", "PK(id)", "trg_paper_no_replace", "paper_duplicate",
   [_PAP.format(id=150, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')")],
   _PAP.replace("INSERT INTO", "REPLACE INTO").format(id=150, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')").replace("'PK-T150'", "'PK-T151'"),
   "SELECT count(*) FROM offline_paper_record WHERE id=150 AND biz_key='PK-T150'",
   "EXISTS (SELECT 1 FROM offline_paper_record o WHERE o.warehouse_id = NEW.warehouse_id AND o.biz_key = NEW.biz_key)"),
  ("offline_paper_record", "uq_paper_bizkey(warehouse_id,biz_key)", "trg_paper_no_replace", "paper_duplicate",
   [_PAP.format(id=150, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')")],
   _PAP.replace("INSERT INTO", "REPLACE INTO").format(id=152, oc="datetime('now','-3 hours')", of="datetime('now','-4 hours')", rc="datetime('now','-2 hours')", dl="datetime('now','+22 hours')", sb="datetime('now')").replace("'PK-T152'", "'PK-T150'"),
   "SELECT count(*) FROM offline_paper_record WHERE id=150",
   "EXISTS (SELECT 1 FROM offline_paper_record o WHERE o.id = NEW.id)"),
  ("numbering_segment", "PK(biz_prefix,date_key)", "trg_numbering_no_replace", "numbering_regress",
   ["INSERT INTO numbering_segment (biz_prefix,date_key,next_value,step) VALUES ('X2N','20261015',5000,100)"],
   "REPLACE INTO numbering_segment (biz_prefix,date_key,next_value,step) VALUES ('X2N','20261015',1,100)",
   "SELECT count(*) FROM numbering_segment WHERE biz_prefix='X2N' AND next_value=5000", "0"),
  ("inbound_message", "PK(id)", "trg_in_msg_no_replace", "inbound_message_duplicate",
   ["INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (779601,'ERP','SALES_ORDER','SO-X2A','{}','h',datetime('now'))"],
   "REPLACE INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (779601,'ERP','SALES_ORDER','SO-X2B','{}','h',datetime('now'))",
   "SELECT count(*) FROM inbound_message WHERE id=779601 AND external_no='SO-X2A'",
   "EXISTS (SELECT 1 FROM inbound_message m WHERE m.source = NEW.source AND m.biz_type = NEW.biz_type AND m.external_no = NEW.external_no)"),
  ("inbound_message", "uq_in_msg(source,biz_type,external_no)", "trg_in_msg_no_replace", "inbound_message_duplicate",
   ["INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (779601,'ERP','SALES_ORDER','SO-X2A','{}','h',datetime('now'))"],
   "REPLACE INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (779602,'ERP','SALES_ORDER','SO-X2A','{}','h2',datetime('now'))",
   "SELECT count(*) FROM inbound_message WHERE id=779601",
   "EXISTS (SELECT 1 FROM inbound_message m WHERE m.id = NEW.id)"),
]
def _guard_body(trg):
    sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (trg,)).fetchone()[0]
    import re as _re
    return " " + sql[_re.search(r"\sBEGIN\s", sql, _re.I).start():].lstrip()
_seen_keys = {}
for tb, key, trg, err, seed, attack, alive, mut_when in _REPCASES:
    _seen_keys.setdefault(tb, set()).add(key)
    conn.execute("SAVEPOINT x2")
    try:
        for x in seed: conn.execute(x)
        try:
            conn.execute(attack); bad(f"X2 {tb} {key} 冲突 REPLACE 未拦截")
        except sqlite3.IntegrityError as e:
            m = str(e)
            (ok if (m == err or m.endswith(": " + err)) else bad)(f"X2 {tb} {key} 冲突 REPLACE → {m}")
        ok(f"X2 {tb} {key} 原行仍在") if conn.execute(alive).fetchone()[0] == 1 else bad(f"X2 {tb} {key} 原行被删")
        fk = conn.execute("PRAGMA foreign_key_check").fetchall()
        ok(f"X2 {tb} {key} foreign_key_check 干净") if not fk else bad(f"X2 {tb} {key} foreign_key_check：{fk[:3]}")
    finally:
        conn.execute("ROLLBACK TO x2"); conn.execute("RELEASE x2")
    # 变异：去掉该键子句（单键表即 WHEN 恒假），同一 REPLACE 必须删掉原行 → 红
    conn.execute("SAVEPOINT x2m")
    try:
        for x in seed: conn.execute(x)
        body = _guard_body(trg)
        conn.execute(f"DROP TRIGGER {trg}")
        conn.execute(f"CREATE TRIGGER {trg} BEFORE INSERT ON {tb} WHEN {mut_when}{body}")
        try:
            conn.execute(attack)
            r = conn.execute(alive).fetchone()[0]
            ok(f"X2 变异 {trg} 去掉 {key} 子句 → 原行被删，测试会变红") if r == 0 else bad(f"X2 变异 {key} 后原行仍在")
        except sqlite3.Error as e:
            bad(f"X2 变异 {trg} 去掉 {key} 子句后仍被拦：{e}")
    finally:
        conn.execute("ROLLBACK TO x2m"); conn.execute("RELEASE x2m")
# 2z3b 实打需要一条满足 uq_outbox_dead_bizkey 谓词（status='DEAD'）的样本行：按合法迁移 PENDING → SENDING → FAILED → DEAD 留一条，提交保留
expect_allow_tx("X2 种子：留一条 DEAD 事件供 2z3b 实打 uq_outbox_dead_bizkey", [
    "INSERT INTO outbox_event (id,topic,biz_key,payload,status,node_id,seq) VALUES (779200,'t','X2-DEAD-SEED','{}','PENDING',78,0)",
    "UPDATE outbox_event SET status='SENDING' WHERE id=779200",
    "UPDATE outbox_event SET status='FAILED', last_error='seed' WHERE id=779200",
    "UPDATE outbox_event SET status='DEAD' WHERE id=779200"])
# 完整性：每张表的唯一索引数 = 已覆盖用例数（新增唯一键而不补用例 → 红）
for tb, keys in _seen_keys.items():
    n = sum(1 for r in conn.execute(f"PRAGMA index_list({tb})") if r[2] == 1)
    ok(f"X2 {tb} 唯一索引 {n} 个全部有 REPLACE 用例") if n == len(keys) else bad(f"X2 {tb} 唯一索引 {n} 个，用例 {len(keys)} 个")
# 小玛丽 blocker：号段只许前进 / 入站判重键不可改（SQLite 侧，与 PG NS1/IM1 同口径）
expect_allow_tx("NS1 准备：建号段 T11N/20261015 next_value=1000", ["INSERT INTO numbering_segment (biz_prefix,date_key,next_value,step) VALUES ('T11N','20261015',1000,100)"])
expect_allow_tx("NS1 正向：取号原语 next_value = next_value + step", ["UPDATE numbering_segment SET next_value = next_value + step WHERE biz_prefix='T11N' AND date_key='20261015'"])
r = one("SELECT next_value FROM numbering_segment WHERE biz_prefix='T11N'")[0]
ok("NS1 取号后 next_value=1100") if r == 1100 else bad(f"NS1 取号结果：{r}")
expect_block_tx("NS1 把 next_value 调回 500（号段回退）", ["UPDATE numbering_segment SET next_value = 500 WHERE biz_prefix='T11N'"], "numbering_regress")
expect_block_tx("NS1 step 改负再取号", ["UPDATE numbering_segment SET step = -100, next_value = next_value - 100 WHERE biz_prefix='T11N'"], "numbering_regress")
expect_block_tx("NS1 改键列 date_key", ["UPDATE numbering_segment SET date_key='20261016' WHERE biz_prefix='T11N'"], "numbering_key_immutable")
expect_block_tx("NS1 改键列 biz_prefix", ["UPDATE numbering_segment SET biz_prefix='T11X' WHERE biz_prefix='T11N'"], "numbering_key_immutable")
expect_block_tx("NS1 DELETE 号段（删了重插 = 回退）", ["DELETE FROM numbering_segment WHERE biz_prefix='T11N'"], "numbering_regress")
expect_block_tx("NS1 REPLACE 号段回到 1", ["REPLACE INTO numbering_segment (biz_prefix,date_key,next_value,step) VALUES ('T11N','20261015',1,100)"], "numbering_regress")
r = one("SELECT next_value FROM numbering_segment WHERE biz_prefix='T11N' AND date_key='20261015'")[0]
ok("NS1 拒绝用例后号段仍为 1100") if r == 1100 else bad(f"NS1 号段被改：{r}")
t11_mut("NS1 变异 DROP trg_numbering_regress", "trg_numbering_regress", ["UPDATE numbering_segment SET next_value = 500 WHERE biz_prefix='T11N'"], "SELECT count(*) FROM numbering_segment WHERE biz_prefix='T11N' AND next_value=500")
t11_mut("NS1 变异 DROP trg_numbering_key_immutable", "trg_numbering_key_immutable", ["UPDATE numbering_segment SET date_key='20261016' WHERE biz_prefix='T11N'"], "SELECT count(*) FROM numbering_segment WHERE biz_prefix='T11N' AND date_key='20261016'")
t11_mut("NS1 变异 DROP trg_numbering_no_delete", "trg_numbering_no_delete", ["DELETE FROM numbering_segment WHERE biz_prefix='T11N'", "INSERT INTO numbering_segment (biz_prefix,date_key,next_value) VALUES ('T11N','20261015',1)"], "SELECT count(*) FROM numbering_segment WHERE biz_prefix='T11N' AND next_value=1")
expect_allow_tx("IM1 准备：入站报文 ERP/SALES_ORDER/SO-I1", ["INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (9601,'ERP','SALES_ORDER','SO-I1','{}','h',datetime('now'))"])
expect_allow_tx("IM1 正向：处理状态可推进", ["UPDATE inbound_message SET status='DONE', processed_at=datetime('now'), biz_ref='OBT-1' WHERE id=9601"])
expect_block_tx("IM1 改 external_no", ["UPDATE inbound_message SET external_no='SO-I1-x' WHERE id=9601"], "inbound_message_key_immutable")
expect_block_tx("IM1 改 source", ["UPDATE inbound_message SET source='WMS' WHERE id=9601"], "inbound_message_key_immutable")
expect_block_tx("IM1 改 biz_type", ["UPDATE inbound_message SET biz_type='PURCHASE' WHERE id=9601"], "inbound_message_key_immutable")
expect_block_tx("IM1 改 id", ["UPDATE inbound_message SET id=9602 WHERE id=9601"], "inbound_message_key_immutable")
expect_block_tx("IM1 同号重推再插（→ 40910 INBOUND_MESSAGE）", ["INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at) VALUES (9603,'ERP','SALES_ORDER','SO-I1','{}','h',datetime('now'))"], "inbound_message_duplicate")
t11_mut("IM1 变异 DROP trg_in_msg_key_immutable", "trg_in_msg_key_immutable", ["UPDATE inbound_message SET external_no='SO-I1-x' WHERE id=9601"], "SELECT count(*) FROM inbound_message WHERE external_no='SO-I1-x'")
_mv = "UPDATE offline_paper_record SET reconnected_at=datetime(reconnected_at,'+1 day'), backfill_deadline_at=datetime(backfill_deadline_at,'+1 day') WHERE id=44"
expect_block_tx("11-5 事后改 reconnected_at（挪截止）", [_mv], "paper_time_immutable")
expect_block_tx("11-5 事后改 approved_at", ["UPDATE offline_paper_record SET approved_at=datetime('now','+1 minute') WHERE id=44"], "paper_time_immutable")
t11_mut("11-5 变异 DROP trg_paper_time_immutable", "trg_paper_time_immutable", ["UPDATE offline_paper_record SET approved_at=datetime('now','+1 minute') WHERE id=44"], "SELECT count(*) FROM offline_paper_record WHERE id=44 AND approved_at = datetime('now','+1 minute')")
# T2（Doro 裁定）：occurred_at / received_at 只收 now±300s 标准整秒；设备原始时间留在 client_occurred_at（只验格式，无容差，不参与清理/比较）
_au = "INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,occurred_at,client_occurred_at) VALUES ({i},'t11.t2',7,{i},1,{oc},'2000-01-01 00:00:00')"
_im = "INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,received_at,client_occurred_at) VALUES ({i},'ERP','SALES_ORDER','SO-T{i}','{{}}','h',{oc},'2000-01-01 00:00:00')"
expect_block_tx("T2 审计 occurred_at 倒填 2000 年", [_au.format(i=9503, oc="'2000-01-01 00:00:00'")], "audit_occurred_not_now")
expect_block_tx("T2 审计 occurred_at 写 T 格式", [_au.format(i=9503, oc="strftime('%Y-%m-%dT%H:%M:%S','now')")], "audit_occurred_not_now")
expect_block_tx("T2 入站报文 received_at 倒填 2000 年", [_im.format(i=9503, oc="'2000-01-01 00:00:00'")], "inbound_received_not_now")
t11_mut("T2 变异 DROP trg_audit_occurred_now", "trg_audit_occurred_now", [_au.format(i=9504, oc="'2000-01-01 00:00:00'")], "SELECT count(*) FROM audit_log WHERE id=9504 AND occurred_at='2000-01-01 00:00:00'")
t11_mut("T2 变异 DROP trg_in_msg_received_now", "trg_in_msg_received_now", [_im.format(i=9504, oc="'2000-01-01 00:00:00'")], "SELECT count(*) FROM inbound_message WHERE id=9504 AND received_at='2000-01-01 00:00:00'")
expect_allow_tx("T2 正向：库时间 + 设备原始时间 2000 年（无容差）", [_au.format(i=9505, oc="datetime('now')"), _im.format(i=9505, oc="datetime('now')")])
r = (one("SELECT client_occurred_at FROM audit_log WHERE id=9505")[0], one("SELECT client_occurred_at FROM inbound_message WHERE id=9505")[0])
ok(f"T2 client_occurred_at 原样保留 {r}") if r == ('2000-01-01 00:00:00',) * 2 else bad(f"T2 client_occurred_at：{r}")
expect_block_tx("T2 client_occurred_at 非标准（带 Z）", ["INSERT INTO inbound_message (id,source,biz_type,external_no,payload,payload_sha,client_occurred_at) VALUES (9506,'ERP','SALES_ORDER','SO-T9506','{}','h','2026-10-15 01:00:00Z')"], "ck_in_msg_cts")
expect_block_tx("T2 client_occurred_at 非标准（审计，小数秒）", ["INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,client_occurred_at) VALUES (9506,'t11.t2',7,9506,1,'2026-10-15 01:00:00.5')"], "ck_audit_cts")
_T2Q = "SELECT count(*) FROM sqlite_master WHERE sql LIKE '%client_occurred_at%' AND NOT (type='table' AND name IN ('audit_log','inbound_message','live_inspection','live_weigh','live_death','pod_op'))"
r = one(_T2Q)[0]
ok("T2 client_occurred_at 不进任何触发器（含清理守卫）、索引、视图") if r == 0 else bad(f"T2 client_occurred_at 被引用 {r} 处")
conn.execute("SAVEPOINT t2m"); conn.execute("CREATE TRIGGER t11_bad_purge BEFORE DELETE ON audit_log WHEN OLD.client_occurred_at < datetime('now') BEGIN SELECT 1; END")
r = one(_T2Q)[0]; conn.execute("ROLLBACK TO t2m"); conn.execute("RELEASE t2m")
ok("T2 变异：加一个按 client_occurred_at 判断的清理触发器，目录断言变红") if r == 1 else bad(f"T2 目录变异未变红：{r}")
# 11-3/11-4 强化变异：用旧 ck_paper_deadline/window/expired 重建一张同构表，攻击能过（红）；同样的行在新表被拒（绿）
_ddl = one("SELECT sql FROM sqlite_master WHERE type='table' AND name='offline_paper_record'")[0]
import re as _re
_old = _ddl.replace("CREATE TABLE offline_paper_record", "CREATE TABLE t11_paper_old", 1)
_old = _re.sub(r"CONSTRAINT ck_paper_ts CHECK \(.*?\),\n", "", _old, count=1, flags=_re.S)
def _swap(src, name, old_expr):
    i = src.index(f"CONSTRAINT {name} "); j = src.index("\n", i)
    return src[:i] + f"CONSTRAINT {name} CHECK ({old_expr})," + src[j:]
_old = _swap(_old, "ck_paper_deadline", "backfill_deadline_at = datetime(reconnected_at, '+24 hours')")
_old = _swap(_old, "ck_paper_window", "reconnected_at > offline_since AND occurred_at >= offline_since AND occurred_at <= reconnected_at AND submitted_at >= reconnected_at")
_old = _swap(_old, "ck_paper_expired", "(status = 'EXPIRED' AND submitted_at > backfill_deadline_at AND exception_case_id IS NOT NULL) OR (status <> 'EXPIRED' AND submitted_at <= backfill_deadline_at AND exception_case_id IS NULL)")
_n = lambda m: one(f"SELECT datetime('now','{m}')")[0]
_d0 = one("SELECT date('now')")[0]
_atk = {
  "11-3 reconnected_at='…Z!' 不可解析，截止填 2099": f"{_n('-3 hours')}|{_n('-4 hours')}|{_n('-2 hours')}Z!|2099-01-01 00:00:00|{_n('+0 seconds')}",
  "11-4 submitted_at 带 -09:00（实际晚截止 9h）仍 PENDING": f"{_d0} 01:00:00|{_d0} 00:00:00|{_d0} 03:00:00|" + one("SELECT datetime(date('now'),'+1 day','+3 hours')")[0] + "|" + one("SELECT strftime('%Y-%m-%d %H:%M:%S', date('now'), '+1 day', '+2 hours', '+59 minutes', '+59 seconds')")[0] + "-09:00",
}
_ins = "INSERT INTO {t} (id,warehouse_id,device_id,action_type,biz_key,occurred_at,operator_id,payload,applicant_id,offline_since,reconnected_at,backfill_deadline_at,submitted_at,status,exception_case_id,approval_type) VALUES (?,1,'PDA-07','PICK_CONFIRM',?,?,11,'{{}}',7,?,?,?,?,'PENDING',NULL,'PAPER_BACKFILL')"
conn.execute("SAVEPOINT p11old")
try:
    conn.execute(_old)
    for k, (desc, vals) in enumerate(_atk.items()):
        oc, of, rc, dl, sb = vals.split("|")
        args = (60 + k, f"PK-OLD{k}", oc, of, rc, dl, sb)
        try:
            conn.execute(_ins.format(t="t11_paper_old"), args)
            ok(f"{desc}：旧表达式重建的表放行（红，原洞可复现）")
        except sqlite3.Error as e:
            bad(f"{desc}：旧表达式也拦了，变异没复现原洞：{e}")
        try:
            conn.execute("SAVEPOINT p11new"); conn.execute(_ins.format(t="offline_paper_record"), args)
            bad(f"{desc}：新约束未拦")
        except sqlite3.IntegrityError as e:
            ok(f"{desc}：新约束拦下（绿，{e}）")
        finally:
            conn.execute("ROLLBACK TO p11new"); conn.execute("RELEASE p11new")
finally:
    conn.execute("ROLLBACK TO p11old"); conn.execute("RELEASE p11old")
r = one("SELECT group_concat(id) FROM offline_paper_record WHERE id >= 40")[0]
ok("11 时间加固反向用例全部回滚（纸质单只剩 44）") if r == "44" else bad(f"11 时间加固残留：{r}")
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

c1 = connect_main(timeout=30)   # N5：种子写连接也开外键
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
    wc = connect_main(timeout=30, isolation_level=None)   # N5：并发写连接也开外键
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
conn = connect_main(isolation_level=None)  # 与开头一致：并发段重连后仍自动提交，后面的 expect_*_tx 才能自己 BEGIN
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
edge_sync('INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,1),(1,2),(1,3),(1,4),(2,3)')
conn.execute("INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (2,'W2','x','20:00'),(3,'ABCDEFGH12345678','x','20:00'),(4,'SHPD01','x','20:00')")
edge_sync('INSERT INTO sys_user_role (user_id,role_id) VALUES (202,1),(202,2),(203,2),(205,3),(206,1),(207,3),(101,1),(208,1),(201,1)')
edge_sync('INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (202,1),(203,1),(204,1),(205,1),(206,1),(101,1),(201,1)')
conn.execute("INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-A','PDA',101,1)")
conn.execute("INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,datetime('now'),datetime('now','+12 hours'))")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000111','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)")
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
expect_block_tx('12 同一设备实例两条 PENDING/ACTIVE 绑定', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (2,'DEV-A','PDA',102,1)"], 'user_device_binding_duplicate')
expect_block_tx('12 I3 REPLACE 覆盖绑定', ["INSERT OR REPLACE INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1,'DEV-Z','PDA',99,1)"], 'user_device_binding_duplicate')
expect_block_tx('12 I3 直接插成 ACTIVE', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,status,activated_at,approval_id) VALUES (3,'DEV-C','PDA',101,1,'ACTIVE','2026-10-15 08:00',1)"], 'binding_insert_not_pending')
expect_block_tx('12 REVOKED 没有吊销时间', ["UPDATE user_device_binding SET status='REVOKED' WHERE id=1"], 'ck_udb_status')
expect_block_tx('12 I3 用不存在的审批激活（触发器 trg_udb_activate 的 NOT EXISTS 拦；approval_id 两库都没有外键，本条不证明外键开着）', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=999, activated_at=datetime('now') WHERE id=1"], 'binding_approval_invalid')
# 外键判别用例（小玛丽 time-scan/fk-case.py）：sku_live_param.sku_id REFERENCES sku(id)，表上其余 CHECK 取默认值都满足、触发器只管 UPDATE/DELETE/重复，
# 插不存在的 sku 只有外键能拦。放在重连之后，外键没重开就会红（小玛丽实测 FK OFF → 未拦截，FK ON → 拦截）。
assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1 or _MUTANT_NO_FK, "foreign_keys 未开"
expect_block_tx('18 FK 判别：sku_live_param 指向不存在的 sku（只有外键能拦，重连后外键必须已重开）', ["INSERT INTO sku_live_param (sku_id) VALUES (987654321)"], 'FOREIGN KEY constraint failed')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (7,'APR-WHSH01-20261015-000007','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL)")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=101, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=7")
expect_block_tx('12 S1 审批人 = 绑定使用人', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=7, activated_at=datetime('now') WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (8,'APR-WHSH01-20261015-000008','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL)")
conn.execute("UPDATE approval_request SET status='REJECTED', decided_at=datetime('now'), reject_reason='x' WHERE id=8")
expect_block_tx('12 I3 用已驳回的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=8, activated_at=datetime('now') WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (9,'APR-WHSH01-20261015-000909','CANCEL_AFTER_PICK',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL)")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=9")
expect_block_tx('12 I3 用别的类型的审批激活', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=9, activated_at=datetime('now') WHERE id=1"], 'binding_approval_invalid')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (10,'APR-WHSH01-20261015-000010','DEVICE_BIND',1,'DEVICE_BINDING','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL)")
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=10")
expect_allow_tx('12 I3 正向：DEVICE_BIND 已通过、审批人≠使用人 → PENDING→ACTIVE', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=10, activated_at=datetime('now') WHERE id=1 AND status='PENDING'"])
expect_block_tx('12 I3 绑定换人', ['UPDATE user_device_binding SET user_id=99 WHERE id=1'], 'binding_immutable')
expect_block_tx('12 I3 ACTIVE 退回 PENDING', ["UPDATE user_device_binding SET status='PENDING', activated_at=NULL WHERE id=1"], 'binding_immutable')
expect_allow_tx('12 I3 正向：吊销', ["UPDATE user_device_binding SET status='REVOKED', revoked_at=datetime('now'), revoke_reason='LOST' WHERE id=1"])
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
expect_block_tx('12 离线令牌到期早于签发', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (2,'J2',1,101,'DEV-A',1,1,datetime('now'),datetime('now','-1 hours'))"], 'ck_offline_ttl')
expect_block_tx('12 I4 离线令牌 30 天', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (3,'J3',1,101,'DEV-A',1,1,datetime('now'),datetime('now','+30 days'))"], 'ck_offline_max_ttl')
expect_allow_tx('12 I4 正向：恰好 12 小时', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (4,'J4',1,101,'DEV-A',1,1,datetime('now'),datetime('now','+12 hours'))"])
expect_block_tx('12 离线令牌 jti 重复', ["INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (5,'J1',1,101,'DEV-A',1,1,datetime('now'),datetime('now','+12 hours'))"], 'offline_token_duplicate')
expect_block_tx('12 I4 REPLACE 覆盖令牌', ["INSERT OR REPLACE INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES (1,'J1',1,101,'DEV-A',1,1,datetime('now'),datetime('now','+12 hours'))"], 'offline_token_duplicate')
expect_block_tx('12 I4 延长有效期', ["UPDATE offline_token SET expires_at='2026-10-15 19:00' WHERE id=1"], 'offline_token_immutable')
expect_allow_tx('12 I4 正向：吊销', ["UPDATE offline_token SET revoked_at=datetime('now') WHERE id=1"])
expect_block_tx('12 I4 吊销后恢复', ['UPDATE offline_token SET revoked_at=NULL WHERE id=1'], 'offline_token_immutable')
expect_block_tx('12 I2 直接插成 APPROVED', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at,status) VALUES (20,'APR-WHSH01-20261015-000020','POD_CORRECT',1,'POD','20','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,'2099-01-01','APPROVED')"], 'approval_insert_not_pending')
expect_block_tx('12 同一目标两条待审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (21,'APR-WHSH01-20261015-000021','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,NULL)"], 'approval_request_duplicate')
expect_block_tx('12 I1 REPLACE 改写审批（同 id）', ["INSERT OR REPLACE INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'approval_request_duplicate')
expect_block_tx('12 I1 UPSERT 改写审批', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1,'APR-WHSH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','9','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL) ON CONFLICT(id) DO UPDATE SET status='PENDING'"], 'approval_request_duplicate')
expect_block_tx('12 SoD：申请人自己审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1"], 'ck_apr_sod')
expect_block_tx('12 I2 单人审批进 PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now') WHERE id=1"], 'ck_apr_partial')
expect_block_tx('12 I2 审批人三列不成组', ['UPDATE approval_request SET first_approver_id=202 WHERE id=1'], 'ck_apr_pair')
expect_block_tx('12 I2 REJECTED 没有 decided_at', ["UPDATE approval_request SET status='REJECTED' WHERE id=1"], 'ck_apr_decided')
expect_allow_tx('12 正向：主管审批通过', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1"])
expect_block_tx('12 I1/I2 APPROVED 改回 PENDING', ["UPDATE approval_request SET status='PENDING', decided_at=NULL WHERE id=1"], 'approval_final')
expect_block_tx('12 审批不可删除', ['DELETE FROM approval_request WHERE id=1'], 'append_only_violation: approval_request')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (4,'APR-WHSH01-20261015-000114','POD_CORRECT',1,'POD','4','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','+1 seconds'))"); import time as _t12; _t12.sleep(2.2)
expect_block_tx('12 I2 过期后审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=4"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (41,'APR-WHSH01-20261015-000041','POD_CORRECT',1,'POD','41','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','+1 seconds'))"); import time as _t12; _t12.sleep(2.2)
expect_block_tx('12 UTC 反向：expires_at = UTC 当前 −1 分钟，已过期不能再批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=41"], 'approval_expired')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (42,'APR-WHSH01-20261015-000042','POD_CORRECT',1,'POD','42','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,datetime('now','+2 hours'))")
expect_allow_tx('12 UTC 正向：expires_at = UTC 当前 +2 小时（比本地 UTC+8 早）仍可批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=42"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (3,'APR-WHSH01-20261015-000903','UNPLANNED_FAILOVER',1,'WAREHOUSE','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)")
expect_block_tx('12 I5 第一确认人不持有任何角色', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now') WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 I5 第一确认人只有 CENTER_OPS 却写 WH_SUPERVISOR', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=203, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now') WHERE id=3"], 'approval_role_not_held')
expect_allow_tx('12 I5 正向：真主管确认 → PARTIAL', ["UPDATE approval_request SET status='PARTIAL', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now') WHERE id=3"])
expect_block_tx('12 I2 换第一审批人', ['UPDATE approval_request SET first_approver_id=203 WHERE id=3'], 'approval_approver_immutable')
expect_block_tx('12 I2 PARTIAL 倒退 PENDING', ["UPDATE approval_request SET status='PENDING' WHERE id=3"], 'approval_transition_invalid')
expect_block_tx('12 I5 第二确认人不持有 CENTER_OPS', ["UPDATE approval_request SET second_approver_id=204, second_approver_role='CENTER_OPS', second_approved_at=datetime('now') WHERE id=3"], 'approval_role_not_held')
expect_block_tx('12 第二确认人 = 第一确认人', ["UPDATE approval_request SET second_approver_id=202, second_approver_role='CENTER_OPS', second_approved_at=datetime('now') WHERE id=3"], 'ck_apr_dual')
expect_block_tx('12 非计划切换只有一人确认就 APPROVED', ["UPDATE approval_request SET status='APPROVED', decided_at=datetime('now') WHERE id=3"], 'ck_apr_done')
expect_allow_tx('12 I5 正向：中心运维第二确认 → APPROVED', ["UPDATE approval_request SET status='APPROVED', second_approver_id=203, second_approver_role='CENTER_OPS', second_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=3"])
# SCRAP_MISREPORT 权限点化（Chief 裁决：以权限点为准）：发起 scrap.misreport.request、审批 scrap.misreport.approve。
# 授权：role 1 = WH_SUPERVISOR 持发起；role 2 = CENTER_OPS、role 3 = QC_SUPERVISOR 持审批。
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (16,'scrap.misreport.request','报损误报回转发起','12'),(17,'scrap.misreport.approve','报损误报回转审批','12')")
edge_sync("INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,16),(2,17),(3,17)")
expect_block_tx('12 SM 发起人不是本仓仓库主管（只有 CENTER_OPS）', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (23,'APR-WHSH01-20261015-000023','SCRAP_MISREPORT',1,'SCRAP_ORDER','9009','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',203,NULL)"], 'approval_perm_not_held')
expect_block_tx('12 SM 发起人是质检主管而非仓库主管', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (24,'APR-WHSH01-20261015-000024','SCRAP_MISREPORT',1,'SCRAP_ORDER','9010','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',205,NULL)"], 'approval_perm_not_held')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (5,'APR-WHSH01-20261015-000005','SCRAP_MISREPORT',1,'SCRAP_ORDER','9001','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL)")
expect_block_tx('12 SM 发起人自己审批（202 兼 CENTER_OPS 也不行）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='CENTER_OPS', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=5"], 'ck_apr_sod')
expect_block_tx('12 SM 审批角色写成仓库主管（另一主管 206 不具审批权）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=206, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=5"], 'approval_perm_not_held')
expect_block_tx('12 SM 审批人不持有 QC_SUPERVISOR 却写质检主管', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='QC_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=5"], 'approval_perm_not_held')
expect_block_tx('12 SM 质检主管不在本仓', ["UPDATE approval_request SET status='APPROVED', first_approver_id=207, first_approver_role='QC_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=5"], 'approval_perm_not_held')
expect_allow_tx('12 SM 正向：本仓质检主管审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=5"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (6,'APR-WHSH01-20261015-000006','SCRAP_MISREPORT',1,'SCRAP_ORDER','9002','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',206,NULL)")
expect_allow_tx('12 SM 正向：中心运维审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=6"])
expect_block_tx('12 审批单号格式：旧格式 SM-2026-001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (30,'SM-2026-001','CANCEL_AFTER_PICK',1,'OUTBOUND','30','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期 7 位 APR-WHSH01-2026101-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (31,'APR-WHSH01-2026101-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','31','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号 5 位 APR-WHSH01-20261015-00001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (32,'APR-WHSH01-20261015-00001','CANCEL_AFTER_PICK',1,'OUTBOUND','32','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码为空 APR--20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (33,'APR--20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','33','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：日期含字母 APR-WHSH01-2026A015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (34,'APR-WHSH01-2026A015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','34','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：月份 13 APR-WHSH01-20261315-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (35,'APR-WHSH01-20261315-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','35','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：序号含字母 APR-WHSH01-20261015-00000X', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (36,'APR-WHSH01-20261015-00000X','CANCEL_AFTER_PICK',1,'OUTBOUND','36','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：前缀小写 apr-WH01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (37,'apr-WH01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','37','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 审批单号格式：仓库编码含 - APR-WH-01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (38,'APR-WH-01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','38','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_allow_tx('12 审批单号格式正向：APR-SHPD01-20261231-999999', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (40,'APR-SHPD01-20261231-999999','POD_CORRECT',4,'POD','40','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"])
expect_block_tx('12 审批类型不在码表', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (22,'APR-WHSH01-20261015-000022','BANANA',1,'X','1','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_type')
expect_block_tx('12 perm_version 回退', ['UPDATE sys_user SET perm_version = 1 WHERE id = 101'], 'perm_version_rewind')
expect_block_tx('12 I7 REPLACE 把 perm_version 打回 1', ["INSERT OR REPLACE INTO sys_user (id,username,password_hash) VALUES (101,'picker01','x')"], 'sys_user_duplicate')
expect_allow_tx('12 I7 正向：perm_version 前进（相对值：本增量起映射增删也会递增 perm_version）', ['UPDATE sys_user SET perm_version = perm_version + 1 WHERE id = 101'])
expect_block_tx('12 T1 审批单号：仓库编码小写 APR-sh01-20261015-000001', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (50,'APR-sh01-20261015-000001','CANCEL_AFTER_PICK',1,'OUTBOUND','50','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码含下划线 APR-S_01-20261015-000002', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (51,'APR-S_01-20261015-000002','CANCEL_AFTER_PICK',1,'OUTBOUND','51','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码含空格 APR-S 01-20261015-000003', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (52,'APR-S 01-20261015-000003','CANCEL_AFTER_PICK',1,'OUTBOUND','52','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码长度 1 APR-A-20261015-000004', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (53,'APR-A-20261015-000004','CANCEL_AFTER_PICK',1,'OUTBOUND','53','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_block_tx('12 T1 审批单号：仓库编码长度 17 APR-ABCDEFGHIJKLMNOPQ-20261015-000005', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (54,'APR-ABCDEFGHIJKLMNOPQ-20261015-000005','CANCEL_AFTER_PICK',1,'OUTBOUND','54','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'ck_apr_code')
expect_allow_tx('12 T1 正向：仓库编码长度 2 / 16', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (56,'APR-W2-20261015-000006','POD_CORRECT',2,'POD','56','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)", "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (57,'APR-ABCDEFGH12345678-20261015-000007','POD_CORRECT',3,'POD','57','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"])
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (60,'APR-WHSH01-20261015-000060','DEVICE_BIND',1,'DEVICE_BINDING','60','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',101,NULL)")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (61,'APR-WHSH01-20261015-000061','POD_CORRECT',1,'POD','61','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (62,'APR-WHSH01-20261015-000062','CANCEL_AFTER_PICK',1,'OUTBOUND','62','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)")
expect_block_tx('12 T2 DEVICE_BIND：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 POD_CORRECT：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=61"], 'approval_perm_not_held')
expect_block_tx('12 T2 CANCEL_AFTER_PICK：无任何角色的用户（204）批准', ["UPDATE approval_request SET status='APPROVED', first_approver_id=204, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=62"], 'approval_perm_not_held')
expect_block_tx('12 T2 DEVICE_BIND：角色存在但无该权限点（203 CENTER_OPS）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=203, first_approver_role='CENTER_OPS', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 DEVICE_BIND：有主管角色但不在本仓（208）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=208, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=60"], 'approval_perm_not_held')
expect_block_tx('12 T2 POD_CORRECT：质检主管无该权限点（205）', ["UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=61"], 'approval_perm_not_held')
expect_allow_tx('12 T2 正向：本仓主管经 sys_role_perm 持有 device.binding.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=60"])
expect_allow_tx('12 T2 正向：本仓主管持有 delivery.pod.correct.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=61"])
expect_allow_tx('12 T2 正向：本仓主管持有 outbound.order.cancel_after_pick.approve', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=62"])
conn.execute("INSERT INTO sys_role (id,code,name) VALUES (4,'CS','客服')")
edge_sync('INSERT INTO sys_role_perm (role_id,perm_id) VALUES (4,4)')
edge_sync('INSERT INTO sys_user_role (user_id,role_id) VALUES (209,4),(210,2)')
edge_sync('INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (209,1)')
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (63,'APR-WHSH01-20261015-000063','CANCEL_AFTER_PICK',1,'OUTBOUND','63','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',209,NULL)")
conn.execute("INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (64,'APR-WHSH01-20261015-000064','CANCEL_AFTER_PICK',1,'OUTBOUND','64','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',202,NULL)")
expect_block_tx('12 拣后取消：只有申请权限 cancel_after_pick（客服 209）不能审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=209, first_approver_role='CS', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=64"], 'approval_perm_not_held')
expect_block_tx('12 拣后取消：申请人 202（持有 .approve）审批自己的单', ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=64"], 'ck_apr_sod')
expect_allow_tx('12 拣后取消正向：不在本仓的 CENTER_OPS（210，数据范围 ALL）审批', ["UPDATE approval_request SET status='APPROVED', first_approver_id=210, first_approver_role='CENTER_OPS', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=63"])
expect_allow_tx('12 拣后取消正向：另一位本仓主管 201 审批 202 的申请', ["UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=64"])
expect_block_tx('12 单号仓库编码 WH01 ≠ 仓 1 的 WHSH01', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (65,'APR-WH01-20261015-000065','POD_CORRECT',1,'POD','65','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'approval_code_warehouse_mismatch')
expect_block_tx('12 单号写 W2 但挂在仓 1', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (66,'APR-W2-20261015-000066','POD_CORRECT',1,'POD','66','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'approval_code_warehouse_mismatch')
expect_block_tx('12 所属仓不存在（warehouse_id=99）', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (67,'APR-WHSH01-20261015-000067','POD_CORRECT',99,'POD','67','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"], 'approval_code_warehouse_mismatch')
expect_allow_tx('12 单号仓库编码正向：APR-WHSH01-… 挂仓 1', ["INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (68,'APR-WHSH01-20261015-000068','POD_CORRECT',1,'POD','68','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','r',201,NULL)"])


print("=== 2g2. 新审批类型（PAPER_BACKFILL/BOX_VOID/PROCESS_YIELD_DEVIATION/LIVE_DEATH_OVER/PROCESS_REWORK）+ audit node 必填 ===")
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (11,'offline.paper.approve','纸质补录审批','00'),(12,'pack.box.void.approve','作废箱审批','06'),(13,'process.yield.approve','得率偏离审批','17'),(14,'live.death.approve','活鲜死亡超阈值审批','18'),(15,'process.rework.approve','加工返工审批','17')")
edge_sync("INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,11),(1,12),(1,13),(1,14),(1,15)")
_H = "a" * 64
for _i, _t in enumerate(["PAPER_BACKFILL", "BOX_VOID", "PROCESS_YIELD_DEVIATION", "LIVE_DEATH_OVER", "PROCESS_REWORK"]):
    for _id, _req in ((81 + _i, 201), (86 + _i, 202)):
        conn.execute(
            "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) "
            f"VALUES ({_id},'APR-WHSH01-20261015-0000{_id}','{_t}',1,'{_t}','{_id}','{{}}','{_H}','r',{_req},NULL)"
        )
conn.commit()
_APP = "UPDATE approval_request SET status='APPROVED', first_approver_id={u}, first_approver_role='{r}', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id={i}"
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
    edge_sync_tx('17×12 审批种子：申请人 1731（也持 PROC_LEAD）、无权审批人 1732（WH_SUPERVISOR 无 process.yield.approve）、加工主管 1733（PROC_LEAD 持有）', ["INSERT INTO sys_user (id,username,password_hash) VALUES (1731,'u1731','x'),(1732,'u1732','x'),(1733,'u1733','x')", "INSERT INTO sys_role (id,code,name) VALUES (1731,'WH_SUPERVISOR_17','仓库主管'),(1732,'PROC_LEAD','加工主管')", "INSERT INTO sys_role_perm (role_id,perm_id) SELECT 1732, id FROM sys_permission WHERE code = 'process.yield.approve'", 'INSERT INTO sys_user_role (user_id,role_id) VALUES (1732,1731),(1733,1732),(1731,1732)', 'INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1731,1),(1732,1),(1733,1)', "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1732,'APR-WHSH01-20261015-000032','PROCESS_YIELD_DEVIATION',1,'PROCESS_ORDER','1711','{}','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc','出成率 43.8% 越界',1731,NULL)"])
    b17('17×12 无 process.yield.approve 的人批 PROCESS_YIELD_DEVIATION', "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1732", 'approval_perm_not_held')
    b17('17×12 报工人自己批（SoD）', "UPDATE approval_request SET status='APPROVED', first_approver_id=1731, first_approver_role='PROC_LEAD', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1732", 'ck_apr_sod')
    expect_allow_tx('17×12 加工主管批 PROCESS_YIELD_DEVIATION', ["UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1732"])
    edge_sync_tx('17×12 返工审批种子：发起人 1734（权限点 process.yield.approve / process.rework.approve 复用 #9 种子，不自建；PROC_REWORKER，持 process.order.reverse 且也持 process.rework.approve，专测 SoD）；1733 PROC_LEAD 加持 process.rework.approve', ["INSERT INTO sys_user (id,username,password_hash) VALUES (1734,'u1734','x')", "INSERT INTO sys_role (id,code,name) VALUES (1734,'PROC_REWORKER','加工返工发起')", "INSERT INTO sys_permission (id,code,name,module) VALUES (1734,'process.order.reverse','加工冲回/返工发起','process')", "INSERT INTO sys_role_perm (role_id,perm_id) SELECT r.rid, p.id FROM (SELECT 1734 AS rid, 'process.order.reverse' AS pc UNION ALL SELECT 1734, 'process.rework.approve' UNION ALL SELECT 1732, 'process.rework.approve') r JOIN sys_permission p ON p.code = r.pc", 'INSERT INTO sys_user_role (user_id,role_id) VALUES (1734,1734)', 'INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1734,1)', "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (1735,'APR-WHSH01-20261015-000035','PROCESS_REWORK',1,'PROCESS_ORDER','1711','{}','dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd','产出 1759 返工',1734,NULL)"])
    b17('17×12 返工：无 process.rework.approve 的人（1732 仓库主管）批 PROCESS_REWORK', "UPDATE approval_request SET status='APPROVED', first_approver_id=1732, first_approver_role='WH_SUPERVISOR_17', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1735", 'approval_perm_not_held')
    b17('17×12 返工 SoD：发起人 1734 自己批（即使持 process.rework.approve）', "UPDATE approval_request SET status='APPROVED', first_approver_id=1734, first_approver_role='PROC_REWORKER', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1735", 'ck_apr_sod')
    expect_allow_tx('17×12 返工：加工主管 1733 批 PROCESS_REWORK', ["UPDATE approval_request SET status='APPROVED', first_approver_id=1733, first_approver_role='PROC_LEAD', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1735"])
print("=== 6. 小吴 C3 形态 A 并发：业务事务只写 seq=0，relay 提交后补号 ===")
conn.commit()  # 前面第 5 节在主连接上留有隐式事务，先提交释放写锁
RELAY8 = 'UPDATE outbox_event SET seq = m.b + r.rn FROM (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM outbox_event WHERE node_id = 8 AND seq = 0) r, (SELECT COALESCE(MAX(seq), 0) AS b FROM outbox_event WHERE node_id = 8) m WHERE outbox_event.id = r.id'
cc_err = []
def cc_ins(i):
    wc = connect_main(timeout=30, isolation_level=None)   # N5：并发写连接也开外键
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
    wc = connect_main(timeout=30, isolation_level=None)   # N5：并发写连接也开外键
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
conn = connect_main()
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

# ---------------------------------------------------------------------------
# 第 10/9 篇 退供应商（Alex 定案）：每条规则 正向 / 拒绝 / 变异（去掉约束后被拒语句通过）
# ---------------------------------------------------------------------------
print("=== 2s. 退供应商：原因白名单、处置必填、食安只退或报废、提货时限、超期转 09 报损 + hold(SCRAP_PENDING) ===")
conn.close()
conn = connect_main(isolation_level=None)
# 种子模式：SQLite 没有「表属主」，时钟窗口 / 只能以 OPEN 建单的触发器对所有写入生效。2s–2s3 用固定日期验证业务规则，
# 先摘掉这三个触发器（同第 11 篇 outbox_seed_begin 口径），2s4 再装回来专测时钟。
SRTN_CLOCK_TRG = ("trg_srtn_ins_open", "trg_srtn_clock_ins", "trg_srtn_clock_upd")
SRTN_CLOCK_SQL = [one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", t)[0] for t in SRTN_CLOCK_TRG]
for _t in SRTN_CLOCK_TRG:
    conn.execute(f"DROP TRIGGER {_t}")
SRTN_SKU = "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days,return_as_fresh) VALUES (97001,'SKU-SR-FRZ','冷冻虾仁','KG','FROZEN',180,30,90,false),(97002,'SKU-SR-AMB','常温大米','KG','AMBIENT',365,30,NULL,false),(97003,'SKU-SR-AMBF','常温香蕉（按生鲜退）','KG','AMBIENT',7,1,NULL,true),(97004,'SKU-SR-LIVE','活鲜（未定义映射）','KG','LIVE',3,1,NULL,false)"
conn.execute(SRTN_SKU)
SRTN_I = "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES "
T0 = "2026-10-15 08:00:00"
def srtn(i, reason, contract, fs, disp, temp, dl):
    c = "NULL" if contract is None else f"'{contract}'"
    d = "NULL" if dl is None else f"'{dl}'"
    return SRTN_I + f"({i},'SRN-{i}',1,501,14,{ {'FRESH': 1, 'FROZEN': 97001, 'STANDARD': 97002}[temp]},1,5000,'{reason}',{c},{'true' if fs else 'false'},'{disp}','{temp}','{T0}',{d},31)"


def _mut_ddl(drop):
    """drop = ('ck', 约束名) 删掉该行 CONSTRAINT；('line', 片段) 删含片段的一行； 删掉该行 CONSTRAINT；('nn', 列) 去掉该列 NOT NULL；('trg', 触发器名) 建库后 DROP。"""
    lines = sqlite_ddl.split("\n")
    if drop[0] == "ck":
        idx = [k for k, l in enumerate(lines) if l.strip().startswith(f"CONSTRAINT {drop[1]} ")]
        assert len(idx) == 1, drop
        k = idx[0]
        if not lines[k].rstrip().endswith(","):   # 最后一条约束：去掉上一行的逗号
            lines[k - 1] = lines[k - 1].rstrip().rstrip(",")
        del lines[k]
    elif drop[0] == "line":   # 删掉含该片段的一行（多行 CHECK 里的一个子句）
        idx = [k for k, l in enumerate(lines) if drop[1] in l]
        assert len(idx) == 1, drop
        del lines[idx[0]]
    elif drop[0] == "sub":   # 删掉一段文本（列级 CHECK）
        txt = "\n".join(lines)
        assert txt.count(drop[1]) == 1, drop
        return txt.replace(drop[1], "")
    elif drop[0] == "rep":   # 文本替换（比较符变异）
        txt = "\n".join(lines)
        assert txt.count(drop[1]) == 1, drop
        return txt.replace(drop[1], drop[2])
    elif drop[0] == "nn":
        idx = [k for k, l in enumerate(lines) if l.strip().startswith(drop[1] + " ") and "NOT NULL" in l]
        k = [k for k in idx if "VARCHAR(16)" in lines[k]][0]
        lines[k] = lines[k].replace("NOT NULL", "", 1)
    return "\n".join(lines)


def srtn_mut(desc, drop, setup, stmt):
    mc = sqlite3.connect(":memory:", isolation_level=None)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
    try:
        mc.executescript(_mut_ddl(drop))
        if drop[0] == "trg":
            mc.execute(f"DROP TRIGGER {drop[1]}")
        for _t in SRTN_CLOCK_TRG:
            mc.execute(f"DROP TRIGGER IF EXISTS {_t}")
        [mc.execute(_q) for _q in _MASTER_MIN]
        mc.execute(SRTN_SKU)
        for st in setup:
            mc.execute(st)
        mc.execute(stmt)
        ok(f"变异：去掉 {desc} 后，原被拒语句通过")
    except sqlite3.Error as e:
        bad(f"变异：去掉 {desc} 后仍被拒（{e}）—— 拒绝不是这条约束给的")
    finally:
        mc.close()


bad_reason = srtn(97109, 'OVERSTOCK', None, False, 'SCRAP', 'FRESH', None)
bad_slow = srtn(97109, 'SLOW_MOVING', None, False, 'DISCOUNT', 'STANDARD', None)
bad_disp = srtn(97109, 'QUALITY', None, False, 'DONATE', 'FRESH', None)
null_disp = SRTN_I + f"(97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,NULL,'FRESH','{T0}',NULL,31)"
bad_fs = srtn(97109, 'QUALITY', None, True, 'DISCOUNT', 'FRESH', None)
bad_recall = srtn(97109, 'RECALL', None, False, 'SCRAP', 'FRESH', None)
bad_dl = srtn(97109, 'QUALITY', None, False, 'RETURN', 'FRESH', '2026-10-17 08:00:00')
bad_dl2 = srtn(97109, 'QUALITY', None, False, 'RETURN', 'FROZEN', None)
expect_allow("退供 R1 正向：质量问题退供（生鲜，T+24h）", srtn(97101, 'QUALITY', None, False, 'RETURN', 'FRESH', '2026-10-16 08:00:00'))
expect_allow("退供 R1 正向：错送 + 换货", srtn(97102, 'WRONG_DELIVERY', None, False, 'EXCHANGE', 'STANDARD', None))
expect_block("退供 R1 拒绝：原因不在白名单（OVERSTOCK）", bad_reason, "ck_srtn_reason")
srtn_mut("ck_srtn_reason", ("ck", "ck_srtn_reason"), [], bad_reason)
expect_allow("退供 R1 正向：滞销 + 合同约定", srtn(97103, 'SLOW_MOVING', 'CT-2026-018 §7.2', False, 'RETURN', 'STANDARD', '2026-10-30 08:00:00'))
expect_block("退供 R1 拒绝：滞销无合同约定", bad_slow, "ck_srtn_slow")
srtn_mut("ck_srtn_slow", ("ck", "ck_srtn_slow"), [], bad_slow)
expect_allow("退供 R2 正向：处置折价（非食安）", srtn(97104, 'QUALITY', None, False, 'DISCOUNT', 'FRESH', None))
expect_block("退供 R2 拒绝：处置方式不在四选一", bad_disp, "ck_srtn_disp")
srtn_mut("ck_srtn_disp", ("ck", "ck_srtn_disp"), [], bad_disp)
expect_block("退供 R2 拒绝：处置方式为空", null_disp, "supplier_return.disposition")
srtn_mut("disposition NOT NULL", ("nn", "disposition"), [], null_disp)
expect_allow("退供 R2 正向：食安 + 报废", srtn(97105, 'QUALITY', None, True, 'SCRAP', 'FRESH', None))
expect_block("退供 R2 拒绝：食安问题折价", bad_fs, "ck_srtn_fsafe")
srtn_mut("ck_srtn_fsafe", ("ck", "ck_srtn_fsafe"), [], bad_fs)
expect_allow("退供 R2 正向：召回（食安）退供，冷冻 T+7d", srtn(97106, 'RECALL', None, True, 'RETURN', 'FROZEN', '2026-10-22 08:00:00'))
expect_block("退供 R2 拒绝：召回未标食安", bad_recall, "ck_srtn_recall_fs")
srtn_mut("ck_srtn_recall_fs", ("ck", "ck_srtn_recall_fs"), [], bad_recall)
expect_allow("退供 R3 正向：常温 T+15d", srtn(97107, 'QUALITY', None, False, 'RETURN', 'STANDARD', '2026-10-30 08:00:00'))
expect_block("退供 R3 拒绝：生鲜截止写成 T+48h", bad_dl, "ck_srtn_deadline")
srtn_mut("ck_srtn_deadline（时限）", ("ck", "ck_srtn_deadline"), [], bad_dl)
expect_block("退供 R3 拒绝：退供缺截止时间", bad_dl2, "ck_srtn_deadline")
expect_allow_tx("退供 R3 正向：截止前提货", ["UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97107", "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-30 07:59:59' WHERE id=97107"])
expect_allow("退供 R3 种子：97106 待提货", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97106")
late = "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-22 08:00:01' WHERE id=97106"
expect_block("退供 R3 拒绝：超过截止再提货（必须走超期报损）", late, "ck_srtn_picked")
srtn_mut("ck_srtn_picked", ("ck", "ck_srtn_picked"), [srtn(97106, 'RECALL', None, True, 'RETURN', 'FROZEN', '2026-10-22 08:00:00'), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97106"], late)
expect_allow("退供 R4 种子：97101 待提货", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97101")
SCR_INS = "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97101,'SCR-97101',1,'SUPPLIER_RETURN',97101,'PICKUP_OVERDUE','2026-10-16',0)"
HOLD_INS = "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97101,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0)"
expect_allow("退供 R4 种子：09 报损单（SUPPLIER_RETURN / PICKUP_OVERDUE）", SCR_INS)
expect_block("09 拒绝：PICKUP_OVERDUE 用在非退供来源", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97109,'SCR-97109',1,'MANUAL',0,'PICKUP_OVERDUE','2026-10-16',7)", "ck_scr_reason_src")
srtn_mut("ck_scr_reason_src 的 PICKUP_OVERDUE 子句", ("line", "AND (reason_code <> 'PICKUP_OVERDUE' OR source_type = 'SUPPLIER_RETURN')"), [], "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97109,'SCR-97109',1,'MANUAL',0,'PICKUP_OVERDUE','2026-10-16',7)")
to_overdue = "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101"
expect_block("退供 R4 拒绝：有报损单但没有 hold(SCRAP_PENDING) 就转超期", to_overdue, "srtn_overdue_no_scrap_hold")
srtn_mut("trg_srtn_overdue", ("trg", "trg_srtn_overdue"), [srtn(97101, 'QUALITY', None, False, 'RETURN', 'FRESH', '2026-10-16 08:00:00'), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97101", SCR_INS], to_overdue)
expect_block("退供 R4 拒绝：建单直接写 OVERDUE_SCRAP", SRTN_I.replace("created_by)", "created_by,status,overdue_at,scrap_order_id)") + f"(97109,'SRN-97109',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','{T0}','2026-10-16 08:00:00',31,'OVERDUE_SCRAP','2026-10-16 09:00:00',97101)", "srtn_overdue_no_scrap_hold")
expect_allow("退供 R4 种子：02 原语 hold(SCRAP_PENDING)，op_key=SRTO:97101", HOLD_INS)
early = "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:00', scrap_order_id=97101 WHERE id=97101"
expect_block("退供 R4 拒绝：未过截止（overdue_at = 截止）就转超期", early, "ck_srtn_overdue")
srtn_mut("ck_srtn_overdue", ("ck", "ck_srtn_overdue"), [srtn(97101, 'QUALITY', None, False, 'RETURN', 'FRESH', '2026-10-16 08:00:00'), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97101", SCR_INS, HOLD_INS], early)
expect_allow("退供 R4 正向：超期 + 报损单 + SCRAP_PENDING 冻结 → OVERDUE_SCRAP", to_overdue)
expect_block_tx("退供 R4 拒绝：报损单号不存在（外键兜底：即使绕过 trg_srtn_overdue）", ["DROP TRIGGER trg_srtn_overdue", "DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=987654 WHERE id=97103"], "fk_srtn_scrap")
_r = one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_srtn_overdue'")[0]
ok("退供 外键兜底测试回滚后 trg_srtn_overdue 仍在") if _r == 1 else bad(f"trg_srtn_overdue 丢失：{_r}")
print("=== 2s2. 退供 食安/滞销、超期绕过、op_key 与重放、唯一与并发 ===")
def _tx_allow(desc, stmts):
    _fk_guard(desc)
    conn.execute("BEGIN")
    try:
        for st in stmts: conn.execute(st)
        ok(f"{desc} → 通过（随后回滚）")
    except sqlite3.Error as e:
        bad(f"{desc} → 仍被拒：{e}")
    finally:
        conn.execute("ROLLBACK")
def _tx_block(desc, stmts, want):
    _fk_guard(desc)
    conn.execute("BEGIN")
    try:
        for st in stmts: conn.execute(st)
        bad(f"{desc} → 未拦截")
    except sqlite3.IntegrityError as e:
        m = str(e)
        ok(f"{desc} → 已拦截（{m}）") if (m == want or m.endswith(": " + want) or want in m) else bad(f"{desc} → 约束不对：期望 {want!r}，实际 {m!r}")
    finally:
        conn.execute("ROLLBACK")
expect_allow_tx("退供 食安 正向：合同滞销 + 折价", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97110,'SRN-97110',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31)"])
expect_allow_tx("退供 食安 正向：合同滞销 + 换货", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97111,'SRN-97111',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31)"])
expect_allow_tx("退供 食安 正向：合同滞销 + 报废", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97112,'SRN-97112',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)"])
expect_block_tx("退供 食安 拒绝：合同滞销标成食安", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)"], "ck_srtn_slow_fs")
srtn_mut("ck_srtn_slow_fs", ["ck", "ck_srtn_slow_fs"], [], "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'SLOW_MOVING','CT-1',true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)")
expect_allow_tx("退供 食安 正向：召回 + 报废", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97113,'SRN-97113',1,501,14,1,1,5000,'RECALL',NULL,true,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)"])
expect_block_tx("退供 食安 拒绝：召回 + 折价", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'DISCOUNT','FRESH','2026-10-15 08:00:00',NULL,31)"], "ck_srtn_fsafe")
expect_block_tx("退供 食安 拒绝：召回 + 换货", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31)"], "ck_srtn_fsafe")
srtn_mut("ck_srtn_fsafe（召回换货）", ["ck", "ck_srtn_fsafe"], [], "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'RECALL',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31)")
expect_block_tx("退供 食安 拒绝：质量食安 + 换货", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97119,'SRN-97119',1,501,14,1,1,5000,'QUALITY',NULL,true,'EXCHANGE','FRESH','2026-10-15 08:00:00',NULL,31)"], "ck_srtn_fsafe")
expect_block_tx("退供 食安 拒绝：建单后把食安单改成折价（UPDATE 绕过）", ["UPDATE supplier_return SET disposition='DISCOUNT' WHERE id=97105"], "ck_srtn_fsafe")
expect_block_tx("退供 食安 拒绝：建单后把召回的食安标记去掉", ["UPDATE supplier_return SET food_safety=false WHERE id=97113"], "ck_srtn_recall_fs")
expect_block_tx("退供 食安 拒绝：召回改成合同滞销（仍是食安）", ["UPDATE supplier_return SET reason_code='SLOW_MOVING', contract_ref='CT-1' WHERE id=97113"], "ck_srtn_slow_fs")
expect_allow_tx("退供 绕过 种子：97130 待提货 + 报损单 97130", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97130,'SRN-97130',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31)", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97130", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97130,'SCR-97130',1,'SUPPLIER_RETURN',97130,'PICKUP_OVERDUE','2026-10-16',0)"])
_tx_block("退供 绕过 拒绝：op_key 小写 srto:", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'srto:97130',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：op_key 前导零 SRTO:097130", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:097130',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：op_key 尾随空格", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130 ',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：op_key 指向别的退供单 SRTO:97101x", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:971300',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：冻结量 ≠ 退供量", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',4999,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：冻结在别的库存行", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,13,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：冻结已释放", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'SRTO:97130',5000,5000,'RELEASED',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_block("退供 绕过 拒绝：冻结挂在别的报损单", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97130',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"], "srtn_overdue_no_scrap_hold")
_tx_allow("变异：去掉 trg_srtn_overdue（op_key 小写） 后，原被拒语句通过", ["DROP TRIGGER trg_srtn_overdue", "DROP TRIGGER trg_srtn_overdue_lock"] + ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97131,14,'SCRAP_PENDING','SCRAP','SCRAP',97130,'srto:97130',5000,0,'HELD',0)", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97130"])
expect_allow_tx("退供 绕过 种子：97132 报损单已取消（有冻结）", ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97132,'SRN-97132',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31)", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97132", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97132,'SCR-97132',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0)", "UPDATE scrap_order SET status='CANCELLED' WHERE id=97132", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97132,14,'SCRAP_PENDING','SCRAP','SCRAP',97132,'SRTO:97132',5000,0,'HELD',0)"])
expect_block_tx("退供 绕过 拒绝：报损单已取消", ["UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97132 WHERE id=97132"], "srtn_overdue_no_scrap_hold")
expect_allow("退供 绕过 种子：97133 OPEN（未进待提货）", "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97133,'SRN-97133',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31)")
expect_block("退供 0 行 拒绝：给未进待提货的退供单开报损单", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97133,'SCR-97133',1,'SUPPLIER_RETURN',97133,'PICKUP_OVERDUE','2026-10-16',0)", "srtn_scrap_not_awaiting")
_tx_allow("变异：去掉 trg_scr_srtn_ins 后，给未进待提货的退供单开报损单通过", ["DROP TRIGGER trg_scr_srtn_ins", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97133,'SCR-97133',1,'SUPPLIER_RETURN',97133,'PICKUP_OVERDUE','2026-10-16',0)"])
expect_block_tx("退供 绕过 拒绝：OPEN 直接跳 OVERDUE_SCRAP（去掉超期守卫后仍由状态机拦；SQLite 触发器顺序与 PG 不同）", ["DROP TRIGGER trg_srtn_overdue", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97133"], "srtn_state_forward_only")
expect_block_tx("退供 绕过 拒绝：OPEN 直接跳 OVERDUE_SCRAP（去掉状态机后仍由超期守卫拦）", ["DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97130 WHERE id=97133"], "srtn_overdue_no_scrap_hold")
expect_block_tx("退供 绕过 拒绝：转超期后换挂报损单", ["UPDATE supplier_return SET scrap_order_id=97130 WHERE id=97101"], "srtn_overdue_immutable")
expect_block_tx("退供 绕过 拒绝：转超期后退回待提货（去掉超期守卫后仍由状态机拦；SQLite 触发器顺序与 PG 不同）", ["DROP TRIGGER trg_srtn_overdue_lock", "UPDATE supplier_return SET status='AWAITING_PICKUP', overdue_at=NULL, scrap_order_id=NULL WHERE id=97101"], "srtn_state_forward_only")
expect_block_tx("退供 绕过 拒绝：转超期后退回待提货（去掉状态机后仍由超期守卫拦）", ["DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='AWAITING_PICKUP', overdue_at=NULL, scrap_order_id=NULL WHERE id=97101"], "srtn_overdue_immutable")
expect_block_tx("退供 绕过 拒绝：转超期后改数量", ["UPDATE supplier_return SET qty_milli=1 WHERE id=97101"], "srtn_overdue_immutable")
_tx_allow("变异：去掉 trg_srtn_overdue（转超期后换挂报损单） 后，原被拒语句通过", ["DROP TRIGGER trg_srtn_overdue", "DROP TRIGGER trg_srtn_overdue_lock"] + ["UPDATE supplier_return SET scrap_order_id=97130 WHERE id=97101"])
expect_block_tx("退供 重放 拒绝：同一退供单再 hold(SCRAP_PENDING)（op_key SRTO:97101 已用；SQLite 先由 trg_hold_no_replace 拦，uq_hold_op 兜底）", ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97139,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0)"], "hold_duplicate")
_mc = sqlite3.connect(":memory:", isolation_level=None)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
try:
    _mc.executescript(_mut_ddl(("ck", "uq_hold_op"))); [_mc.execute(_q) for _q in _MASTER_MIN]; _mc.execute("DROP TRIGGER trg_hold_no_replace")
    _mc.execute(HOLD_INS); _mc.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97139,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0)")
    ok("变异：去掉 uq_hold_op 与 trg_hold_no_replace 后，重放 hold(SCRAP_PENDING) 通过")
except sqlite3.Error as e:
    bad(f"变异：去掉 uq_hold_op 后重放仍被拒：{e}")
finally:
    _mc.close()
_mc = sqlite3.connect(":memory:", isolation_level=None)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
try:
    _mc.executescript(_mut_ddl(("ck", "uq_hold_op"))); [_mc.execute(_q) for _q in _MASTER_MIN]; _mc.execute(HOLD_INS); _mc.execute("INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97139,14,'SCRAP_PENDING','SCRAP','SCRAP',97101,'SRTO:97101',5000,0,'HELD',0)")
    bad("变异：只去掉 uq_hold_op，trg_hold_no_replace 没拦住重放")
except sqlite3.IntegrityError as e:
    ok(f"只去掉 uq_hold_op 时 trg_hold_no_replace 仍拦重放（{e}）") if str(e) == "hold_duplicate" else bad(f"重放拦错：{e}")
finally:
    _mc.close()
_n = conn.execute("UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97101 WHERE id=97101 AND status='AWAITING_PICKUP'").rowcount; ok("退供 重放 转超期：条件更新 WHERE status='AWAITING_PICKUP' 影响 0 行" + f"（{_n}）") if _n == 0 else bad("退供 重放 转超期：条件更新 WHERE status='AWAITING_PICKUP' 影响 0 行" + f"：{_n}")
expect_allow_tx("退供 重放 正向：同值重放转超期（终态不变）是 no-op", ["UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 08:00:01', scrap_order_id=97101 WHERE id=97101"])
expect_block_tx("退供 唯一 拒绝：已取消旧报损单后再给同一退供单开报损单（uq_scr_source 放过，uq_scr_srtn 拦）", ["INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97134,'SCR-97134',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0)"], "scrap_order.source_id")
_tx_allow("变异：去掉 uq_scr_srtn 后，原被拒语句通过", ["DROP INDEX uq_scr_srtn", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97134,'SCR-97134',1,'SUPPLIER_RETURN',97132,'PICKUP_OVERDUE','2026-10-16',0)"])
_tx_block("退供 唯一 拒绝：两张退供单挂同一报损单（绕过触发器后由 uq_srtn_scrap 兜底）", ["DROP TRIGGER trg_srtn_overdue", "DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=97101 WHERE id=97103"], "supplier_return.scrap_order_id")
_tx_allow("变异：去掉 uq_srtn_scrap 后，两张退供单挂同一报损单通过", ["DROP TRIGGER trg_srtn_overdue", "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=97101 WHERE id=97103", "DROP INDEX uq_srtn_scrap"][:1] + ["DROP TRIGGER trg_srtn_forward", "DROP INDEX uq_srtn_scrap"] + ["UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-30 09:00:00', scrap_order_id=97101 WHERE id=97103"])
# 并发：两个连接同时给退供单 97135 开报损单（BEGIN IMMEDIATE 串行，第二个等锁后撞唯一索引）
import time as _time
conn.execute("INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,status,created_by) VALUES (97135,'SRN-97135',1,501,14,1,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00','AWAITING_PICKUP',31)")
_cc_res = []
def _cc_scr(sid, hold_s):
    wc = connect_main(timeout=30, isolation_level=None)   # N5：并发写连接也开外键
    try:
        wc.execute("BEGIN IMMEDIATE")
        wc.execute(f"INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES ({sid},'SCR-{sid}',1,'SUPPLIER_RETURN',97135,'PICKUP_OVERDUE','2026-10-16',0)")
        _time.sleep(hold_s)
        wc.execute("COMMIT"); _cc_res.append("OK")
    except sqlite3.Error as e:
        try: wc.execute("ROLLBACK")
        except sqlite3.Error: pass
        _cc_res.append(str(e))
    finally:
        wc.close()
_ths = [threading.Thread(target=_cc_scr, args=(97140, 0.5)), threading.Thread(target=_cc_scr, args=(97141, 0.0))]
for _t in _ths: _t.start()
for _t in _ths: _t.join()
_n = one("SELECT count(*) FROM scrap_order WHERE source_type='SUPPLIER_RETURN' AND source_id=97135")[0]
ok(f"退供 并发转超期：两连接同时开报损单，只成 1 张（{sorted(_cc_res)}）") if _n == 1 and _cc_res.count("OK") == 1 and any("scrap_order.source_id" in r or "uq_scr" in r or "source_type" in r for r in _cc_res) else bad(f"退供 并发：{_n} 张 {_cc_res}")
print("=== 2s3. 退供 温区映射：FROZEN→FROZEN、CHILLED→FRESH、AMBIENT→STANDARD、AMBIENT+return_as_fresh→FRESH ===")
expect_block("退供 温区 拒绝：冷藏 SKU 标 return_as_fresh", 'UPDATE sku SET return_as_fresh=true WHERE id=1', "ck_sku_rtn_fresh")
srtn_mut("ck_sku_rtn_fresh", ("sub", " CONSTRAINT ck_sku_rtn_fresh CHECK (NOT return_as_fresh OR temperature_required = 'AMBIENT')"), [], 'UPDATE sku SET return_as_fresh=true WHERE id=1')
expect_allow('退供 温区 正向：冷藏 → FRESH', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97150,'SRN-97150',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)")
expect_allow('退供 温区 正向：冷冻 → FROZEN', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97151,'SRN-97151',1,501,14,97001,1,5000,'QUALITY',NULL,false,'SCRAP','FROZEN','2026-10-15 08:00:00',NULL,31)")
expect_allow('退供 温区 正向：常温 → STANDARD', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97152,'SRN-97152',1,501,14,97002,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31)")
expect_allow('退供 温区 正向：常温 + return_as_fresh → FRESH', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97153,'SRN-97153',1,501,14,97003,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)")
expect_allow('退供 温区 正向：常温 + return_as_fresh 退供，截止 T+24h', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97154,'SRN-97154',1,501,14,97003,1,5000,'QUALITY',NULL,false,'RETURN','FRESH','2026-10-15 08:00:00','2026-10-16 08:00:00',31)")
expect_block('退供 温区 拒绝：冷藏标 STANDARD', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：冷冻标 FRESH', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97001,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：常温标 FRESH（无覆盖标记）', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97002,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：常温 + return_as_fresh 标 STANDARD（T+15d）', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97003,1,5000,'QUALITY',NULL,false,'RETURN','STANDARD','2026-10-15 08:00:00','2026-10-30 08:00:00',31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：未定义映射的温区 LIVE', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,97004,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：SKU 不存在', "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,999999,1,5000,'QUALITY',NULL,false,'SCRAP','FRESH','2026-10-15 08:00:00',NULL,31)", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：建单后 UPDATE 改 temp_class', "UPDATE supplier_return SET temp_class='FROZEN' WHERE id=97150", "srtn_temp_class_mismatch")
expect_block('退供 温区 拒绝：建单后 UPDATE 换成冷藏 SKU（类别仍 STANDARD）', 'UPDATE supplier_return SET sku_id=1 WHERE id=97152', "srtn_temp_class_mismatch")
_tx_allow("变异：去掉 trg_srtn_temp_ins 后，冷藏 SKU 标 STANDARD 通过", ["DROP TRIGGER trg_srtn_temp_ins", "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (97159,'SRN-97159',1,501,14,1,1,5000,'QUALITY',NULL,false,'SCRAP','STANDARD','2026-10-15 08:00:00',NULL,31)"])
_tx_allow("变异：去掉 trg_srtn_temp_upd 后，建单后改 temp_class 通过", ["DROP TRIGGER trg_srtn_temp_upd", "UPDATE supplier_return SET temp_class='FROZEN' WHERE id=97150"])
print("=== 2s4. 退供 时间与 0 行（pr03 同类）：格式、时钟窗口、只写一次、边界、孤儿报损单（SQLite 无角色，列级授权 N/A）===")
def NOW(sec=0): return one("SELECT datetime('now', ?)", f"{sec} seconds")[0]
def sr4(i, ready, disp='SCRAP', dl=None, extra_cols="", extra_vals=""):
    d = "NULL" if dl is None else f"'{dl}'"
    return SRTN_I.replace("created_by)", "created_by" + extra_cols + ")") + f"({i},'SRN-{i}',1,501,14,1,1,5000,'QUALITY',NULL,false,'{disp}','FRESH','{ready}',{d},31{extra_vals})"
# 格式（种子模式，时钟触发器未装：只看 ck_srtn_ts）
for _v, _d in [("2026/10/30 10:00:00", "斜杠"), ("zzzz", "非日期"), ("2026-10-15T08:00:00", "T 分隔"), ("2026-10-15 08:00:00+00:00", "+00:00 偏移"), ("2026-10-15 08:00:00+08:00", "+08:00 偏移"), ("2026-10-15 08:00:00.5", "小数秒"), ("2026-02-30 08:00:00", "不存在的日期")]:
    expect_block(f"退供 格式 拒绝：ready_at {_d}（{_v}）", sr4(97160, _v), "ck_srtn_ts")
srtn_mut("ck_srtn_ts（小数秒）", ("ck", "ck_srtn_ts"), [], sr4(97160, "2026-10-15 08:00:00.5"))
srtn_mut("ck_srtn_ts（'zzzz' strftime NULL）", ("ck", "ck_srtn_ts"), [], sr4(97160, "zzzz"))
expect_allow_tx("退供 格式 正向：整秒规范格式（随后回滚）", [sr4(97160, T0), "DELETE FROM supplier_return WHERE id=97160"])
# 装回时钟触发器
for _s in SRTN_CLOCK_SQL: conn.execute(_s)
expect_block("退供 时钟 拒绝：'zzzz'（strftime 为 NULL 不能绕过）", sr4(97161, "zzzz"), "srtn_clock_skew")
_tx_block("变异：时钟触发器去掉 IS NULL 分支后，'zzzz' 仍被 ck_srtn_ts 兜住（纵深）", ["DROP TRIGGER trg_srtn_clock_ins", "CREATE TRIGGER trg_srtn_clock_ins BEFORE INSERT ON supplier_return WHEN abs(CAST(strftime('%s', NEW.ready_at) AS INTEGER) - CAST(strftime('%s','now') AS INTEGER)) > 300 BEGIN SELECT RAISE(ABORT,'srtn_clock_skew'); END", sr4(97161, "zzzz")], "ck_srtn_ts")
expect_block("退供 时钟 拒绝：'T' 分隔的当前时间（时钟内但非规范）", sr4(97161, NOW().replace(" ", "T")), "ck_srtn_ts")
expect_block("退供 时钟 拒绝：倒签 ready_at（now−1d）", sr4(97161, NOW(-86400)), "srtn_clock_skew")
_tx_allow("变异：去掉 trg_srtn_clock_ins 后，倒签 ready_at 通过", ["DROP TRIGGER trg_srtn_clock_ins", sr4(97161, NOW(-86400))])
expect_block("退供 时钟 拒绝：预签 ready_at（now+1d）", sr4(97161, NOW(86400)), "srtn_clock_skew")
expect_block("退供 时钟 拒绝：容差外 301 秒", sr4(97161, NOW(-301)), "srtn_clock_skew")
expect_allow_tx("退供 时钟 正向：容差内 −290 秒（随后回滚）", [sr4(97161, NOW(-290)), "DELETE FROM supplier_return WHERE id=97161"])
expect_block("退供 时钟 拒绝：越过 OPEN 直接 AWAITING_PICKUP 建单", sr4(97161, NOW(), 'RETURN', NOW(86400), ",status", ",'AWAITING_PICKUP'"), "srtn_insert_open_only")
_tx_allow("变异：去掉 trg_srtn_ins_open 后，直接 AWAITING_PICKUP 建单通过", ["DROP TRIGGER trg_srtn_ins_open", sr4(97161, NOW(), 'RETURN', NOW(86400), ",status", ",'AWAITING_PICKUP'")])
_r0 = NOW()
_dl0 = one("SELECT datetime(?, '+24 hours')", _r0)[0]
expect_allow("退供 时钟 正向：97170 以库时钟建单，退供生鲜截止 now+24h", sr4(97170, _r0, 'RETURN', _dl0))
_shift = "UPDATE supplier_return SET ready_at=datetime(ready_at,'-1 hour'), pickup_deadline_at=datetime(pickup_deadline_at,'-1 hour') WHERE id=97170"
expect_block("退供 只写一次 拒绝：建单后整体平移 ready_at / 截止", _shift, "srtn_time_immutable")
_tx_allow("变异：去掉 trg_srtn_time_lock 后，平移通过", ["DROP TRIGGER trg_srtn_time_lock", _shift])
expect_allow("退供 时钟 种子：97170 进待提货", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97170")
_pk_bad = f"UPDATE supplier_return SET status='PICKED_UP', picked_up_at='{NOW(-3600)}' WHERE id=97170"
expect_block("退供 时钟 拒绝：倒签 picked_up_at（now−1h）", _pk_bad, "srtn_clock_skew")
_tx_allow("变异：去掉 trg_srtn_clock_upd 后，倒签提货通过", ["DROP TRIGGER trg_srtn_clock_upd", _pk_bad])
_tx_allow("退供 时钟 正向：picked_up_at = 库时钟", [f"UPDATE supplier_return SET status='PICKED_UP', picked_up_at='{NOW()}' WHERE id=97170"])
_od_seed = ["DROP TRIGGER trg_srtn_ins_open", "DROP TRIGGER trg_srtn_clock_ins",
            sr4(97171, NOW(-90000), 'RETURN', NOW(-3600), ",status", ",'AWAITING_PICKUP'"),
            "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97171,'SCR-97171',1,'SUPPLIER_RETURN',97171,'PICKUP_OVERDUE','2026-10-16',0)",
            "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,released_qty_milli,status,operator_id) VALUES (97171,14,'SCRAP_PENDING','SCRAP','SCRAP',97171,'SRTO:97171',5000,0,'HELD',0)"]
_od = lambda t: f"UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='{t}', scrap_order_id=97171 WHERE id=97171"
_tx_block("退供 时钟 拒绝：预签 overdue_at（now+1d）", _od_seed + [_od(NOW(86400))], "srtn_clock_skew")
_tx_allow("变异：去掉 trg_srtn_clock_upd 后，预签超期通过", _od_seed + ["DROP TRIGGER trg_srtn_clock_upd", _od(NOW(86400))])
_tx_allow("退供 时钟 正向：overdue_at = 库时钟", _od_seed + [_od(NOW())])
print("=== 2s5. 退供 终审（小玛丽 srtn-final）：B2 状态机、N1 created_at（SQLite；B1 pg_temp 为 PG 专属）===")
_w = lambda i, disp='RETURN': sr4(i, NOW(), disp, NOW(86400) if disp == 'RETURN' else None)
_pk = [_w(97410), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97410", f"UPDATE supplier_return SET status='PICKED_UP', picked_up_at='{NOW()}' WHERE id=97410"]
_tx_block("B2 拒绝：PICKED_UP → AWAITING_PICKUP 且清空 picked_up_at", _pk + ["UPDATE supplier_return SET status='AWAITING_PICKUP', picked_up_at=NULL WHERE id=97410"], "srtn_state_forward_only")
_tx_allow("变异：去掉 trg_srtn_forward 后，PICKED_UP 回退通过", _pk + ["DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='AWAITING_PICKUP', picked_up_at=NULL WHERE id=97410"])
_tx_block("B2 拒绝：PICKED_UP 后改 picked_up_at（状态不变，容差内）", _pk + [f"UPDATE supplier_return SET picked_up_at='{NOW(-60)}' WHERE id=97410"], "srtn_time_immutable")
_tx_allow("变异：去掉 trg_srtn_time_lock 后，改 picked_up_at 通过", _pk + ["DROP TRIGGER trg_srtn_time_lock", f"UPDATE supplier_return SET picked_up_at='{NOW(-60)}' WHERE id=97410"])
_cx = [_w(97411, 'SCRAP'), "UPDATE supplier_return SET status='CANCELLED' WHERE id=97411"]
_tx_block("B2 拒绝：CANCELLED → OPEN", _cx + ["UPDATE supplier_return SET status='OPEN' WHERE id=97411"], "srtn_state_forward_only")
_tx_allow("变异：去掉 trg_srtn_forward 后，CANCELLED 复活通过", _cx + ["DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='OPEN' WHERE id=97411"])
_tx_allow("B2 正向：非 RETURN OPEN → DISPOSED", [_w(97412, 'DISCOUNT'), "UPDATE supplier_return SET status='DISPOSED' WHERE id=97412"])
_ds = ["DROP TRIGGER trg_srtn_ins_open", sr4(97413, NOW(), 'RETURN', NOW(86400), ",status", ",'DISPOSED'")]
_tx_block("B2 拒绝：DISPOSED → AWAITING_PICKUP", _ds + ["UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97413"], "srtn_state_forward_only")
_tx_allow("变异：去掉 trg_srtn_forward 后，DISPOSED 复活通过", _ds + ["DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97413"])
_tx_block("B2 拒绝：RETURN 处置 OPEN → DISPOSED", [_w(97414), "UPDATE supplier_return SET status='DISPOSED' WHERE id=97414"], "srtn_state_forward_only")
_tx_allow("变异：去掉 trg_srtn_forward 后，RETURN 直接 DISPOSED 通过", [_w(97414), "DROP TRIGGER trg_srtn_forward", "UPDATE supplier_return SET status='DISPOSED' WHERE id=97414"])
_tx_block("B2 拒绝：OPEN → PICKED_UP（跳过待提货）", [_w(97414), f"UPDATE supplier_return SET status='PICKED_UP', picked_up_at='{NOW()}' WHERE id=97414"], "srtn_state_forward_only")
_tx_allow("变异：去掉 trg_srtn_forward 后，跳过待提货通过", [_w(97414), "DROP TRIGGER trg_srtn_forward", f"UPDATE supplier_return SET status='PICKED_UP', picked_up_at='{NOW()}' WHERE id=97414"])
_ca = lambda v: sr4(97420, NOW(), 'SCRAP', None, ",created_at", f",'{v}'")
expect_block("N1 拒绝：created_at = '1999-01-01 00:00:00'（倒签）", _ca("1999-01-01 00:00:00"), "srtn_clock_skew")
_tx_allow("变异：去掉 trg_srtn_clock_ins 后，倒签 created_at 通过", ["DROP TRIGGER trg_srtn_clock_ins", _ca("1999-01-01 00:00:00")])
expect_block("N1 拒绝：created_at 预签 now+1d", _ca(NOW(86400)), "srtn_clock_skew")
expect_block("N1 拒绝：created_at = 'zzzz'（strftime NULL）", _ca("zzzz"), "srtn_clock_skew")
expect_block("N1 拒绝：created_at 'T' 分隔（时钟内但非规范）", _ca(NOW().replace(" ", "T")), "ck_srtn_ts")
srtn_mut("ck_srtn_ts（created_at 规范格式）", ("ck", "ck_srtn_ts"), [], _ca("2026-10-15T08:00:00"))
_tx_allow("N1 正向：缺省 created_at（datetime('now')）与显式库时钟", [sr4(97421, NOW(), 'SCRAP'), _ca(NOW())])
_tx_block("N1 拒绝：建单后改 created_at", [sr4(97421, NOW(), 'SCRAP'), "UPDATE supplier_return SET created_at=datetime(created_at,'-1 day') WHERE id=97421"], "srtn_time_immutable")
_tx_allow("变异：去掉 trg_srtn_time_lock 后，改 created_at 通过", [sr4(97421, NOW(), 'SCRAP'), "DROP TRIGGER trg_srtn_time_lock", "UPDATE supplier_return SET created_at=datetime(created_at,'-1 day') WHERE id=97421"])
_r = one("SELECT count(*) FROM supplier_return WHERE NOT (length(created_at) = 19 AND datetime(created_at) IS created_at)")[0]
ok("N1 现有退供单 created_at 全部规范整秒") if _r == 0 else bad(f"N1 非规范 created_at {_r} 行")
# 边界：按整秒，提货 = 截止 允许；超期 = 截止 拒绝（2s 已测）
_bd_seed = [sr4(97172, T0, 'RETURN', '2026-10-16 08:00:00'), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97172"]
_bd_pick = "UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-16 08:00:00' WHERE id=97172"
_tx_allow("退供 边界 正向：picked_up_at = 截止（同一秒）", [f"DROP TRIGGER {_t}" for _t in SRTN_CLOCK_TRG] + _bd_seed + [_bd_pick])
_PK_LE = "CAST(strftime('%s', picked_up_at) AS INTEGER) <= CAST(strftime('%s', pickup_deadline_at) AS INTEGER)"
_OD_GT = "CAST(strftime('%s', overdue_at) AS INTEGER) > CAST(strftime('%s', pickup_deadline_at) AS INTEGER)"
def srtn_mut_red(desc, old, new, setup, stmt, want):
    mc = sqlite3.connect(":memory:", isolation_level=None)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
    try:
        txt = sqlite_ddl
        assert txt.count(old) == 1, old
        mc.executescript(txt.replace(old, new))
        for _t in SRTN_CLOCK_TRG: mc.execute(f"DROP TRIGGER IF EXISTS {_t}")
        [mc.execute(_q) for _q in _MASTER_MIN]
        mc.execute(SRTN_SKU)
        for st in setup: mc.execute(st)
        mc.execute(stmt)
        bad(f"变异：{desc} 后仍通过 —— 边界测试没变红")
    except sqlite3.IntegrityError as e:
        ok(f"变异：{desc} 后，边界语句被拒（变红：{e}）") if want in str(e) else bad(f"变异 {desc}：错误不对 {e}")
    finally:
        mc.close()
srtn_mut_red("ck_srtn_picked 的 <= 改成 <", _PK_LE, _PK_LE.replace("<=", "<"), _bd_seed, _bd_pick, "ck_srtn_picked")
srtn_mut("ck_srtn_overdue 的 > 改成 >=", ("rep", _OD_GT, _OD_GT.replace(" > ", " >= ")), [srtn(97101, 'QUALITY', None, False, 'RETURN', 'FRESH', '2026-10-16 08:00:00'), "UPDATE supplier_return SET status='AWAITING_PICKUP' WHERE id=97101", SCR_INS, HOLD_INS], early)
_tx_block("退供 边界 拒绝：非规范 'T' 格式且晚 1 秒（整秒比较 / 格式检查任一拦截）", [f"DROP TRIGGER {_t}" for _t in SRTN_CLOCK_TRG] + _bd_seed + ["UPDATE supplier_return SET status='PICKED_UP', picked_up_at='2026-10-16T08:00:01' WHERE id=97172"], "ck_srtn_")
# 孤儿报损单（0 行静默成功）
_orph = [f"DROP TRIGGER {_t}" for _t in SRTN_CLOCK_TRG] + [sr4(97183, T0, 'RETURN', '2026-10-16 08:00:00', ",status", ",'AWAITING_PICKUP'"),
         "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97183,'SCR-97183',1,'SUPPLIER_RETURN',97183,'PICKUP_OVERDUE','2026-10-16',0)",
         "UPDATE supplier_return SET status='OVERDUE_SCRAP', overdue_at='2026-10-16 09:00:00', scrap_order_id=97183 WHERE id=97183 AND status='PICKED_UP'"]
_r = None
conn.execute("BEGIN")
try:
    for st in _orph[:-1]: conn.execute(st)
    _r = conn.execute(_orph[-1]).rowcount
finally:
    conn.execute("ROLLBACK")
ok("退供 0 行 复现：转超期条件更新影响 0 行（服务端必须查 rowcount → 40930）") if _r == 0 else bad(f"0 行复现 rowcount={_r}")
_tx_block("退供 0 行 拒绝：孤儿报损单不能提交审批", _orph + ["UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97183"], "srtn_scrap_orphan")
_tx_allow("变异：去掉 trg_scr_srtn_upd 后，孤儿报损单提交通过", _orph + ["DROP TRIGGER trg_scr_srtn_upd", "UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97183"])
_tx_allow("退供 0 行 正向：孤儿报损单可以取消", _orph + ["UPDATE scrap_order SET status='CANCELLED' WHERE id=97183"])
_tx_allow("退供 0 行 正向：97101（已转超期且指回本单）报损单提交审批", ["UPDATE scrap_order SET status='PENDING_APPROVAL' WHERE id=97101"])
_tx_block("退供 0 行 拒绝：给未进待提货（OPEN）的退供单开报损单", ["INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97184,'SCR-97184',1,'SUPPLIER_RETURN',97104,'PICKUP_OVERDUE','2026-10-16',0)"], "srtn_scrap_not_awaiting")
_tx_allow("变异：去掉 trg_scr_srtn_ins 后，给 OPEN 退供单开报损单通过", ["DROP TRIGGER trg_scr_srtn_ins", "INSERT INTO scrap_order (id,code,warehouse_id,source_type,source_id,reason_code,work_date,applicant_id) VALUES (97184,'SCR-97184',1,'SUPPLIER_RETURN',97104,'PICKUP_OVERDUE','2026-10-16',0)"])
print("=== 2z3 SQLite 全库 no-REPLACE 扫描（00 §6.10 第 3/4 条；第十二轮：逐唯一键）===")
import re as _re
_GUARD_RE = lambda tb: (_re.compile(r"\bBEFORE\s+INSERT\s+ON\s+" + _re.escape(tb) + r"\b", _re.I), _re.compile(r"RAISE\s*\(\s*ABORT", _re.I),
                        _re.compile(r"EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+" + _re.escape(tb) + r"\b", _re.I))
def _is_guard(tb, s):
    return all(r.search(s) for r in _GUARD_RE(tb))
def _eqref(s, c):
    c = _re.escape(c)
    return bool(_re.search(rf"\b\w+\.{c}\s*=\s*NEW\.{c}\b", s, _re.I) or _re.search(rf"\bNEW\.{c}\s*=\s*\w+\.{c}\b", s, _re.I))
def table_keys(mc, tb):
    """表上全部唯一键：(名, 列元组；表达式列为 None, 部分索引谓词或 None)。主键用 table_info（INTEGER PRIMARY KEY 没有索引行）。"""
    ks = []
    pk = tuple(r[1] for r in sorted(mc.execute(f"PRAGMA table_info({tb})"), key=lambda r: r[5]) if r[5])
    if pk: ks.append(("PK", pk, None))
    for _, iname, uniq, origin, partial in mc.execute(f"PRAGMA index_list({tb})").fetchall():
        if not uniq or origin == 'pk': continue
        cols = tuple(r[2] for r in mc.execute(f"PRAGMA index_xinfo({iname})") if r[5])   # 只取键列；表达式列 name 为 None
        where = None
        if partial:
            sql = mc.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", (iname,)).fetchone()[0]
            where = _re.search(r"\bWHERE\b(.*)$", sql, _re.I | _re.S).group(1).strip()
        ks.append((iname, cols, where))
    return ks
def replace_scan(ddl):
    mc = sqlite3.connect(":memory:"); mc.executescript(ddl)   # 内存库：只装 DDL 做变异 / 扫描，不跑业务用例，不经 connect_main（外键在本行之后按需显式打开），不计入 FK 守卫（r12 非阻塞 3）
    rows = mc.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE sql IS NOT NULL").fetchall()
    tables = {n: s for t, n, tb, s in rows if t == 'table'}
    a = sorted(n for n, s in tables.items() if _re.search(r"ON\s+CONFLICT\s+REPLACE", s, _re.I))
    trg = [(n, tb, s) for t, n, tb, s in rows if t == 'trigger']
    # 非阻塞 1（已知限制）：只认 BEFORE UPDATE/DELETE 的锁；AFTER UPDATE … RAISE 写的锁不计（当前 0 处）
    locked = sorted({tb for n, tb, s in trg if _re.search(r"\bBEFORE\s+(UPDATE|DELETE)\b", s, _re.I) and _re.search(r"RAISE\s*\(", s, _re.I)})
    guards = {t: [s for n, t2, s in trg if t2 == t and _is_guard(t, s)] for t in tables}
    keys = {t: table_keys(mc, t) for t in tables}
    mc.close()
    return a, locked, guards, keys
def key_cover(keys, guards):
    """静态：某个守卫触发器对键的每一列都写了 x.col = NEW.col 才算覆盖；子集键被覆盖时超集键随之覆盖。"""
    direct = [set(c) for _, c, _ in keys if None not in c and any(all(_eqref(s, x) for x in c) for s in guards)]
    return {c: any(d <= set(c) for d in direct) for _, c, _ in keys if None not in c}
# 表级豁免：整张表还没有 no-REPLACE 触发器。只能缩小；修好一张删一行（已有触发器还在名单 = 红）
REPLACE_ALLOW = {
    "supplier_return": "10", "process_bom": "17", "process_bom_line": "17",
}
REPLACE_BASELINE = frozenset({"lot", "stock_ledger_line", "inbound_order", "supplier_return", "process_bom", "process_bom_line"})   # 第 11 篇时间增量补了 trg_upl_no_replace，按"只能缩小"从基线和名单同时删掉 upstream_push_log
# 第十二轮扩面：没有锁定字段的表也要逐唯一键拦 REPLACE。下面两张名单都冻结基线、只能缩小；表已全部覆盖还在名单 = 红
# REPLACE_OK：REPLACE 可以接受（主数据整行改写 ≈ UPDATE，无去重/序号语义；被引用的行由外键兜底，REPLACE 删父行会报 FOREIGN KEY）
REPLACE_OK = {
    "sku_unit": "01 换算系数：没有任何表引用 sku_unit（无子行，不会产生孤儿）；按 (sku_id,uom) 换 id REPLACE 等价于整行改写换算系数，与 UPDATE 能做的一样，不涉及去重 / 序号",
}
REPLACE_OK_BASELINE = frozenset({"sku_unit"})   # 第十三轮冻结（r12 的 warehouse/zone/location/sku/stock_recon_alert 已移出：理由不成立，改为加守卫）
# REPLACE_TODO：别篇的表，由属主判定"加守卫"还是"挪进 REPLACE_OK 并写理由"（第十二轮冻结，只能缩小）
REPLACE_TODO = {t: o for o, ts in {
    "04": ("outbound_order", "outbound_line"), "05 小肥鱼": ("wave", "pick_task", "pick_task_line"),
    "06 小肥鱼": ("pack_box", "pack_box_line", "shipment", "shipment_order"), "08": ("count_order", "count_line", "adjust_order", "adjust_line"),
    "10 米雪儿": ("exception_code",),
    # 12 爱弥斯：六张表已逐唯一键加 no-REPLACE 守卫（第 12 篇增量），按"只能缩小"删掉本行
}.items() for t in ts}
REPLACE_TODO_BASELINE = frozenset(REPLACE_TODO)
# 键级豁免（第十二轮）：表已有守卫，但这几个唯一键还没拦。按条文属主，只能缩小；键已被覆盖还在名单 = 红；基线外 = 红
REPLACE_KEY_ALLOW = {
    ("exception_case", ("code",)): "10 米雪儿",
    ("process_order", ("approval_no",)): "17 米雪儿（uq_prc_apr）",
    ("scrap_line", ("scrap_id", "line_no")): "09 米雪儿",
    ("scrap_order", ("source_id",)): "09 米雪儿（uq_scr_srtn）",
    ("scrap_order", ("source_type", "source_id", "source_date")): "09 米雪儿（uq_scr_source）",
    ("scrap_order", ("code",)): "09 米雪儿",
    ("stock_recon_alert", ("check_code", "warehouse_id", "stock_id")): "02 Doro：未闭环告警靠 ON CONFLICT (uq_recon_open) DO UPDATE 累加 hit_count，守卫会拦掉 UPSERT；索引谓词只含未闭环行，REPLACE 碰不到 RESOLVED（终态锁 trg_recon_resolved_lock），会整行重写未闭环告警，与 UPDATE 能做的一样",
}
REPLACE_KEY_BASELINE = frozenset(REPLACE_KEY_ALLOW)   # 第十三轮：stock_recon_alert 由表级 REPLACE_OK 收窄为这一个键
def replace_check(ddl, allow, key_allow=None):
    key_allow = REPLACE_KEY_ALLOW if key_allow is None else key_allow
    errs = []
    a, locked, guards, keys = replace_scan(ddl)
    errs += [f"{t}: 表 DDL 含 ON CONFLICT REPLACE" for t in a]
    errs += [f"{t}: 有 BEFORE UPDATE/DELETE 拦截却没有 no-REPLACE 触发器（不在豁免名单）" for t in locked if not guards[t] and t not in allow]
    errs += [f"{t}: 豁免名单过期（已有 no-REPLACE 触发器，删掉这行）" for t in allow if guards.get(t)]
    errs += [f"{t}: 豁免名单含冻结基线外的表（新表不能豁免）" for t in allow if t not in REPLACE_BASELINE]
    for t in sorted(keys):
        if not keys[t]: continue
        cov = key_cover(keys[t], guards[t])
        full = all(cov.get(c, False) or (t, c) in key_allow for _, c, _ in keys[t])
        if t in REPLACE_OK or t in REPLACE_TODO:
            tag = "REPLACE_OK" if t in REPLACE_OK else "REPLACE_TODO"
            if t in locked: errs.append(f"{t}: 受锁表不能进 {tag}")
            if full and guards[t]: errs.append(f"{t}: {tag} 过期（唯一键已全部覆盖，删掉这行）")
            continue
        if t in allow: continue
        for n, c, w in keys[t]:
            if None in c:
                if (t, c) not in key_allow: errs.append(f"{t}({n}): 表达式唯一索引，扫描无法判定覆盖 → 红（改成列索引或逐键豁免）")
                continue
            if not cov[c] and (t, c) not in key_allow:
                errs.append(f"{t}({','.join(c)}): 唯一键没有被 no-REPLACE 触发器覆盖（WHEN 里要有每列的 x.col = NEW.col）")
    errs += [f"{t}: REPLACE_OK 含冻结基线外的表" for t in REPLACE_OK if t not in REPLACE_OK_BASELINE]
    errs += [f"{t}: REPLACE_TODO 含冻结基线外的表" for t in REPLACE_TODO if t not in REPLACE_TODO_BASELINE]
    for (t, c), _ in key_allow.items():
        if t in keys and c in key_cover(keys[t], guards[t]) and key_cover(keys[t], guards[t])[c]:
            errs.append(f"{t}({','.join(c)}): 键级豁免过期（已覆盖，删掉这行）")
        if (t, c) not in REPLACE_KEY_BASELINE:
            errs.append(f"{t}({','.join(c)}): 键级豁免含冻结基线外的键")
    return errs, locked, guards, keys
_e, _lk, _gd, _ks = replace_check(sqlite_ddl, REPLACE_ALLOW)
_nkeys = sum(len(_ks[t]) for t in _ks if t not in REPLACE_ALLOW and t not in REPLACE_OK and t not in REPLACE_TODO)
ok(f"no-REPLACE 扫描通过：受锁表 {len(_lk)}，已防护 {len([t for t in _lk if _gd[t]])}，表级豁免 {len(REPLACE_ALLOW)}，REPLACE_OK {len(REPLACE_OK)}，REPLACE_TODO {len(REPLACE_TODO)}，逐键检查 {_nkeys} 个唯一键，键级豁免 {len(REPLACE_KEY_ALLOW)}") if not _e else bad("no-REPLACE 扫描：" + "；".join(_e))
def _scan_mut(desc, ddl, allow, want, key_allow=None):
    e = replace_check(ddl, allow, key_allow)[0]
    ok(f"变异：{desc} → 扫描变红（{[x for x in e if want in x][0]}）") if any(want in x for x in e) else bad(f"变异：{desc} 后扫描仍绿：{e}")
_ddl_nr = sqlite_ddl + "\nDROP TRIGGER trg_res_no_replace;"
assert _ddl_nr != sqlite_ddl
_scan_mut("去掉 trg_res_no_replace", _ddl_nr, REPLACE_ALLOW, "stock_reservation: 有 BEFORE")
_scan_mut("豁免名单加入已防护的 stock_reservation", sqlite_ddl, {**REPLACE_ALLOW, "stock_reservation": "02"}, "stock_reservation: 豁免名单过期")
_scan_mut("去掉 trg_res_no_replace 并把 stock_reservation 塞进豁免名单", _ddl_nr, {**REPLACE_ALLOW, "stock_reservation": "02"}, "stock_reservation: 豁免名单含冻结基线外")
_scan_mut("把已修好的 lot 塞回豁免名单", sqlite_ddl, {**REPLACE_ALLOW, "lot": "01"}, "lot: 豁免名单过期")
_scan_mut("表 DDL 加 ON CONFLICT REPLACE", sqlite_ddl + "\nCREATE TABLE zz_rep (id INTEGER PRIMARY KEY ON CONFLICT REPLACE);", REPLACE_ALLOW, "zz_rep: 表 DDL 含 ON CONFLICT REPLACE")
# X2：假守卫（WHEN 只查 status='never'）必须红
_scan_mut("假守卫：trg_res_no_replace 换成 WHEN r.status = 'never'", _ddl_nr + "\nCREATE TRIGGER trg_res_fake BEFORE INSERT ON stock_reservation WHEN EXISTS (SELECT 1 FROM stock_reservation r WHERE r.status = 'never') BEGIN SELECT RAISE(ABORT, 'reservation_duplicate'); END;", REPLACE_ALLOW, "stock_reservation(id)")
_scan_mut("假守卫：只写 NEW.id IS NULL（引用了列但不比较）", _ddl_nr + "\nCREATE TRIGGER trg_res_fake BEFORE INSERT ON stock_reservation WHEN NEW.id IS NULL AND NEW.op_key IS NULL AND EXISTS (SELECT 1 FROM stock_reservation r) BEGIN SELECT RAISE(ABORT, 'reservation_duplicate'); END;", REPLACE_ALLOW, "stock_reservation(id)")
_scan_mut("WHEN 少一个键：trg_res_no_replace 只查 id，不查 op_key", _ddl_nr + "\nCREATE TRIGGER trg_res_no_replace BEFORE INSERT ON stock_reservation WHEN EXISTS (SELECT 1 FROM stock_reservation r WHERE r.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'reservation_duplicate'); END;", REPLACE_ALLOW, "stock_reservation(op_key)")
_scan_mut("去掉 trg_mvk_no_replace_idem（X1 回退）", sqlite_ddl + "\nDROP TRIGGER trg_mvk_no_replace_idem;", REPLACE_ALLOW, "stock_movement_key(idempotency_key)")
_scan_mut("去掉 trg_mvk_no_replace_seq（X1 回退）", sqlite_ddl + "\nDROP TRIGGER trg_mvk_no_replace_seq;", REPLACE_ALLOW, "stock_movement_key(stock_id,stock_seq)")
_ddl_ob = sqlite_ddl + "\nDROP TRIGGER trg_outbox_no_replace;\nCREATE TRIGGER trg_outbox_no_replace BEFORE INSERT ON outbox_event WHEN EXISTS (SELECT 1 FROM outbox_event o WHERE o.id = NEW.id) BEGIN SELECT RAISE(ABORT, 'outbox_duplicate'); END;"
_scan_mut("第 11 篇 trg_outbox_no_replace 退回只查 id（小玛丽 r11 X2）", _ddl_ob, REPLACE_ALLOW, "outbox_event(node_id,seq)")
_scan_mut("第 11 篇已覆盖的 outbox_event(node_id,seq) 塞回键级豁免", sqlite_ddl, REPLACE_ALLOW, "键级豁免", {**REPLACE_KEY_ALLOW, ("outbox_event", ("node_id", "seq")): "x"})
_scan_mut("第 11 篇去掉 trg_numbering_no_replace（受锁表）", sqlite_ddl + "\nDROP TRIGGER trg_numbering_no_replace;", REPLACE_ALLOW, "numbering_segment: 有 BEFORE")
_scan_mut("第 11 篇去掉 trg_in_msg_no_replace（受锁表）", sqlite_ddl + "\nDROP TRIGGER trg_in_msg_no_replace;", REPLACE_ALLOW, "inbound_message: 有 BEFORE")
_scan_mut("键级豁免加入已覆盖的 stock_movement_key(idempotency_key)", sqlite_ddl, REPLACE_ALLOW, "键级豁免过期", {**REPLACE_KEY_ALLOW, ("stock_movement_key", ("idempotency_key",)): "x"})
_scan_mut("键级豁免加入基线外的键", sqlite_ddl + "\nDROP TRIGGER trg_hold_no_replace_ret;", REPLACE_ALLOW, "键级豁免含冻结基线外", {**REPLACE_KEY_ALLOW, ("stock_hold", ("source_id",)): "x"})
_scan_mut("表达式唯一索引", sqlite_ddl + "\nCREATE UNIQUE INDEX zz_res_expr ON stock_reservation(lower(op_key));", REPLACE_ALLOW, "stock_reservation(zz_res_expr): 表达式唯一索引")

print("=== 2z4 第 1/2 篇触发器 / 索引名冻结基线（#2 第十三轮；少一个 = 红）===")
T0102 = ('warehouse', 'zone', 'location', 'sku', 'sku_barcode', 'sku_unit', 'lot', 'stock', 'stock_reservation', 'stock_hold', 'stock_hold_release', 'stock_ledger_line', 'stock_movement', 'stock_movement_key', 'stock_snapshot_daily', 'stock_recon_alert')
SQ_BASE_0102 = {"trigger": frozenset(['trg_bc_no_replace', 'trg_bc_no_replace_code', 'trg_hold_approval_fk', 'trg_hold_approval_fk_upd', 'trg_hold_immutable', 'trg_hold_no_delete', 'trg_hold_no_replace', 'trg_hold_no_replace_ret', 'trg_hr_no_delete', 'trg_hr_no_replace', 'trg_hr_no_update', 'trg_location_no_replace', 'trg_location_no_replace_code', 'trg_lot_no_replace', 'trg_lot_sell_deadline', 'trg_mv_clock', 'trg_mv_no_delete', 'trg_mv_no_replace', 'trg_mv_no_update', 'trg_mvk_clock', 'trg_mvk_line_kind', 'trg_mvk_no_delete', 'trg_mvk_no_replace', 'trg_mvk_no_replace_biz', 'trg_mvk_no_replace_idem', 'trg_mvk_no_replace_pda', 'trg_mvk_no_replace_seq', 'trg_mvk_no_update', 'trg_recon_no_delete', 'trg_recon_no_replace', 'trg_recon_resolved_lock', 'trg_res_clock', 'trg_res_created_lock', 'trg_res_expires_lock', 'trg_res_no_replace', 'trg_res_ttl_fill', 'trg_sku_no_replace', 'trg_sku_no_replace_code', 'trg_sll_immutable', 'trg_sll_no_replace', 'trg_snap_no_replace', 'trg_stock_no_replace', 'trg_stock_no_replace_dim', 'trg_warehouse_no_replace', 'trg_warehouse_no_replace_code', 'trg_zone_no_replace', 'trg_zone_no_replace_code']),
                "index": frozenset(['ix_hold_from', 'ix_hold_stock', 'ix_hr_hold', 'ix_loc_replen', 'ix_lot_aging', 'ix_lot_expiry', 'ix_mv_biz', 'ix_mv_hold', 'ix_mv_sku_time', 'ix_mv_stock', 'ix_mv_time', 'ix_recon_open', 'ix_res_exp', 'ix_res_source', 'ix_res_stock', 'ix_sku_category', 'ix_snap_sku', 'ix_stock_loc', 'ix_stock_sku_avail', 'ix_stock_wh', 'ix_zone_wh_type', 'sqlite_autoindex_location_1', 'sqlite_autoindex_location_2', 'sqlite_autoindex_lot_1', 'sqlite_autoindex_lot_2', 'sqlite_autoindex_sku_1', 'sqlite_autoindex_sku_2', 'sqlite_autoindex_sku_barcode_1', 'sqlite_autoindex_sku_barcode_2', 'sqlite_autoindex_sku_unit_1', 'sqlite_autoindex_sku_unit_2', 'sqlite_autoindex_stock_1', 'sqlite_autoindex_stock_2', 'sqlite_autoindex_stock_hold_1', 'sqlite_autoindex_stock_hold_2', 'sqlite_autoindex_stock_hold_release_1', 'sqlite_autoindex_stock_hold_release_2', 'sqlite_autoindex_stock_ledger_line_1', 'sqlite_autoindex_stock_movement_1', 'sqlite_autoindex_stock_movement_key_1', 'sqlite_autoindex_stock_movement_key_2', 'sqlite_autoindex_stock_movement_key_3', 'sqlite_autoindex_stock_recon_alert_1', 'sqlite_autoindex_stock_reservation_1', 'sqlite_autoindex_stock_reservation_2', 'sqlite_autoindex_stock_snapshot_daily_1', 'sqlite_autoindex_warehouse_1', 'sqlite_autoindex_warehouse_2', 'sqlite_autoindex_zone_1', 'sqlite_autoindex_zone_2', 'uq_hold_return', 'uq_mvk_biz_line', 'uq_mvk_pda_op', 'uq_mvk_stock_seq', 'uq_recon_open'])}
def _names_0102(ddl):
    mc = sqlite3.connect(":memory:"); mc.executescript(ddl)   # 内存库：只装 DDL 做扫描，不跑业务用例
    out = {ty: {n for (n,) in mc.execute(f"SELECT name FROM sqlite_master WHERE type = ? AND tbl_name IN ({','.join('?' * len(T0102))})", (ty,) + T0102)} for ty in ("trigger", "index")}
    mc.close(); return out
def _base_check(ddl):
    now = _names_0102(ddl)
    return {ty: (sorted(SQ_BASE_0102[ty] - now[ty]), sorted(now[ty] - SQ_BASE_0102[ty])) for ty in now}
for _ty, (_miss, _extra) in _base_check(sqlite_ddl).items():
    ok(f"01/02 {_ty} 名单与冻结基线一致（{len(SQ_BASE_0102[_ty])} 个）") if not _miss else bad(f"01/02 {_ty} 少了：{_miss}")
    if _extra: print(f"  · 01/02 {_ty} 基线外新增（请补进基线）：{_extra}")
_m = _base_check(sqlite_ddl + "\nDROP TRIGGER trg_mvk_no_replace_seq;\nDROP INDEX uq_mvk_stock_seq;")
ok(f"变异：去掉 trg_mvk_no_replace_seq + uq_mvk_stock_seq → 基线变红（{_m['trigger'][0]} / {_m['index'][0]}）") if _m["trigger"][0] and _m["index"][0] else bad("变异：去掉触发器 / 索引后基线仍绿")
print("=== 2z4-11 第 11 篇触发器 / 索引名冻结基线（同 #2 第十三轮机制；少一个 = 红）===")
T11 = ('outbox_event', 'idempotency_record', 'upstream_push_log', 'offline_paper_record', 'inbound_message', 'numbering_segment', 'audit_log')   # audit_log 属第 11 篇（爱弥斯确认），12b 挂在它上面的触发器 / 索引一并冻结
SQ_BASE_11 = {"trigger": frozenset(['trg_audit_no_delete', 'trg_audit_no_replace', 'trg_audit_no_update', 'trg_audit_node_required', 'trg_audit_occurred_now', 'trg_idem_created_now', 'trg_idem_expires_past', 'trg_idem_expires_ttl', 'trg_idem_expiry_fwd', 'trg_idem_no_replace', 'trg_idem_purge_guard', 'trg_in_msg_key_immutable', 'trg_in_msg_no_replace', 'trg_in_msg_received_now', 'trg_numbering_key_immutable', 'trg_numbering_no_delete', 'trg_numbering_no_replace', 'trg_numbering_regress', 'trg_outbox_bizkey_blocked', 'trg_outbox_expiry_fwd', 'trg_outbox_illegal_transition', 'trg_outbox_insert_pending', 'trg_outbox_no_replace', 'trg_outbox_purge_guard', 'trg_outbox_sent_now', 'trg_outbox_seq_immutable', 'trg_paper_approved_now', 'trg_paper_no_replace', 'trg_paper_submitted_now', 'trg_paper_time_immutable', 'trg_upl_no_delete', 'trg_upl_no_replace', 'trg_upl_no_update', 'trg_upl_received_now']),
              "index": frozenset(['ix_audit_actor', 'ix_audit_target', 'ix_audit_wh', 'ix_idem_exp', 'ix_in_msg_retry', 'ix_outbox_bizkey', 'ix_outbox_noseq', 'ix_outbox_pending', 'ix_paper_pending', 'ix_upl_src', 'ix_upl_time', 'sqlite_autoindex_audit_log_1', 'sqlite_autoindex_idempotency_record_1', 'sqlite_autoindex_inbound_message_1', 'sqlite_autoindex_inbound_message_2', 'sqlite_autoindex_numbering_segment_1', 'sqlite_autoindex_offline_paper_record_1', 'sqlite_autoindex_offline_paper_record_2', 'sqlite_autoindex_outbox_event_1', 'sqlite_autoindex_upstream_push_log_1', 'uq_audit_node_seq', 'uq_outbox_dead_bizkey', 'uq_outbox_seq'])}
def _names_11(ddl):
    mc = sqlite3.connect(":memory:"); mc.executescript(ddl)
    out = {ty: {n for (n,) in mc.execute(f"SELECT name FROM sqlite_master WHERE type = ? AND tbl_name IN ({','.join('?' * len(T11))})", (ty,) + T11)} for ty in ("trigger", "index")}
    mc.close(); return out
def _base_check_11(ddl):
    now = _names_11(ddl)
    return {ty: (sorted(SQ_BASE_11[ty] - now[ty]), sorted(now[ty] - SQ_BASE_11[ty])) for ty in now}
for _ty, (_miss, _extra) in _base_check_11(sqlite_ddl).items():
    ok(f"11 {_ty} 名单与冻结基线一致（{len(SQ_BASE_11[_ty])} 个）") if not _miss else bad(f"11 {_ty} 少了：{_miss}")
    if _extra: print(f"  · 11 {_ty} 基线外新增（请补进基线）：{_extra}")
_m = _base_check_11(sqlite_ddl + "\nDROP TRIGGER trg_numbering_no_replace;\nDROP INDEX uq_outbox_seq;")
ok(f"变异：去掉 trg_numbering_no_replace + uq_outbox_seq → 11 基线变红（{_m['trigger'][0]} / {_m['index'][0]}）") if _m["trigger"][0] and _m["index"][0] else bad("变异：11 去掉触发器 / 索引后基线仍绿")
# 第 13 轮配套：11 表声明外键（audit_log.warehouse_id、offline_paper_record.warehouse_id）种子无孤儿
_fk11 = [r for t_ in ("audit_log", "offline_paper_record") for r in conn.execute(f"PRAGMA foreign_key_check({t_})")]
ok("11 外键：audit_log / offline_paper_record foreign_key_check 干净") if not _fk11 else bad(f"11 外键孤儿：{_fk11[:5]}")
expect_block_tx("11 外键：audit_log.warehouse_id 指向不存在的仓", ["INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id,occurred_at) VALUES (779701,'t11.fk',7,779701,999999,datetime('now'))"], "FOREIGN KEY constraint failed")
# Doro 裁定：audit_log.actor_id → sys_user(id) 在 SQLite 写进 11 的 CREATE TABLE（PG 由 12_auth ALTER，爱弥斯）
_fka = [(r[2], r[3], r[4]) for r in conn.execute("PRAGMA foreign_key_list(audit_log)")]
ok("11 外键：audit_log.actor_id → sys_user(id) 已声明") if ("sys_user", "actor_id", "id") in _fka else bad(f"11 外键缺 audit_log.actor_id → sys_user：{_fka}")
expect_block_tx("11 外键：audit_log.actor_id 指向不存在的用户", ["INSERT INTO audit_log (id,actor_id,action,node_id,node_seq,warehouse_id,occurred_at) VALUES (779703,999999,'t11.fk',7,779703,1,datetime('now'))"], "FOREIGN KEY constraint failed")

print("=== 2z2 预占 / 流水 防 REPLACE ===")
_RES = "INTO stock_reservation (id,stock_id,stage,source_type,source_id,source_line_id,op_key,reserve_qty_milli,status) VALUES ({i},11,'RESERVE','OUTBOUND_LINE',1,{i},'{k}',1000,'RESERVED')"
_tx_block("预占 INSERT OR REPLACE 同 id", ["INSERT " + _RES.format(i=99801, k='RES:RP:1'), "INSERT OR REPLACE " + _RES.format(i=99801, k='RES:RP:2')], "reservation_duplicate")
_tx_block("预占 REPLACE INTO 同 op_key 换 id（续命）", ["INSERT " + _RES.format(i=99802, k='RES:RP:3'), "REPLACE " + _RES.format(i=99803, k='RES:RP:3')], "reservation_duplicate")
_tx_allow("变异：去掉 trg_res_no_replace 后，REPLACE 同 op_key 换 id 通过（旧行被删）", ["DROP TRIGGER trg_res_no_replace", "INSERT " + _RES.format(i=99802, k='RES:RP:3'), "REPLACE " + _RES.format(i=99803, k='RES:RP:3')])

print("=== 2z2-mv 流水 occurred_at 服务端时钟（00 §6.8 第 7 条）===")
for _s in MV_CLOCK_SQL: conn.execute(_s)
conn.commit()
def _mv(t, mid=99901, seq=1, stock=99901):
    return ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99901,1,'LOT-MV','2027-01-01','2026-10-15')",
            f"INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES ({stock},1,1,1,99901,'KG',0)",
            "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'MVCLK',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'MVCLK' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING",
            f"INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,src_task_id,src_line_no,device_instance_id,src_op_seq,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key) VALUES ({mid},'MVCLK',1,1,1,'DOC','OPENING',1,{stock},{seq},1,1,1,99901,NULL,NULL,NULL,NULL,50000,0,50000,{t},'MVCLK:1')",
            f"INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) VALUES ({mid},'MVCLK:1','MVCLK',1,1,1,'DOC',NULL,NULL,NULL,NULL,{stock},{seq},1,{t})"]
_NOW = "datetime('now')"
_tx_allow("流水 occurred_at = 服务端当前整秒 UTC", _mv(_NOW))
_tx_block("流水 occurred_at 远离 now（2 个月后）", _mv("datetime('now','+2 months')"), "movement_clock_skew")
_tx_block("流水 occurred_at 只有日期", _mv("date('now')"), "movement_clock_skew")
_tx_block("流水 occurred_at 带 Z 偏移", _mv("strftime('%Y-%m-%dT%H:%M:%SZ','now')"), "movement_clock_skew")
_tx_block("流水 key occurred_at 远离 now（流水本身合法）", ["DROP TRIGGER trg_mv_clock"] + _mv("datetime('now','-1 day')")[:3] + [_mv(_NOW)[3].replace(_NOW, "datetime('now','-1 day')")] + _mv("datetime('now','-1 day')")[4:], "movement_clock_skew")
_tx_allow("变异：去掉 trg_mv_clock / trg_mvk_clock 后，2 个月后的 occurred_at 通过", ["DROP TRIGGER trg_mv_clock", "DROP TRIGGER trg_mvk_clock"] + _mv("datetime('now','+2 months')"))
_tx_block("流水 REPLACE 同主键", _mv(_NOW) + [_mv(_NOW)[3].replace("INSERT INTO", "INSERT OR REPLACE INTO").replace("{_NOW}", _NOW)], "append_only_violation: stock_movement")
_tx_block("流水 key REPLACE 同 movement_id", _mv(_NOW) + [_mv(_NOW)[4].replace("INSERT INTO", "REPLACE INTO")], "append_only_violation: stock_movement_key")
_MVK_GUARDS = ("trg_mvk_no_replace", "trg_mvk_no_replace_idem", "trg_mvk_no_replace_biz", "trg_mvk_no_replace_pda", "trg_mvk_no_replace_seq")
_tx_allow("变异：去掉全部 trg_mvk_no_replace* 后，key REPLACE 同 movement_id 通过", [f"DROP TRIGGER {t}" for t in _MVK_GUARDS] + _mv(_NOW) + [_mv(_NOW)[4].replace("INSERT INTO", "REPLACE INTO")])
# 第十二轮 X1：换 movement_id，只撞其他唯一键（小玛丽 mvk_replace.py 的三种打法）
def _mvk_rep(mid, idem, op_no, seq):
    return (f"REPLACE INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,src_task_id,src_line_no,device_instance_id,src_op_seq,stock_id,stock_seq,direction,occurred_at) "
            f"VALUES ({mid},'{idem}','MVCLK',1,{op_no},1,'DOC',NULL,NULL,NULL,NULL,99901,{seq},1,{_NOW})")
_K = "stock_movement_key"
_X1 = [("同 idempotency_key", _mvk_rep(99902, 'MVCLK:1', 2, 2), f"{_K}.idempotency_key", "trg_mvk_no_replace_idem"),
       ("同 (stock_id,stock_seq)", _mvk_rep(99902, 'MVCLK:2', 2, 1), f"{_K}.stock_id, {_K}.stock_seq", "trg_mvk_no_replace_seq"),
       ("同 (biz_no,line_no,op_no,leg)", _mvk_rep(99902, 'MVCLK:2', 1, 2), f"{_K}.biz_no, {_K}.line_no, {_K}.op_no, {_K}.leg", "trg_mvk_no_replace_biz")]
for _d, _sql, _want, _trg in _X1:
    _tx_block(f"X1 流水 key 换 movement_id，REPLACE {_d}", _mv(_NOW) + [_sql], _want)
    _tx_allow(f"变异：去掉 {_trg} 后，REPLACE {_d} 通过（旧 key 行被删）", [f"DROP TRIGGER {_trg}"] + _mv(_NOW) + [_sql])
_tx_block("流水 occurred_at 小时 = 24（strftime 能解析，GLOB 也过）", ["DROP TRIGGER trg_mvk_clock"] + _mv("strftime('%Y-%m-%d', 'now') || ' 24:00:00'"), "movement_clock_skew")
_tx_block("流水 key occurred_at 小时 = 24", ["DROP TRIGGER trg_mv_clock"] + _mv(_NOW)[:4] + [_mv("strftime('%Y-%m-%d', 'now') || ' 24:00:00'")[4]], "movement_clock_skew")
_tx_block("预占 created_at 小时 = 24", ["INSERT " + _RES.format(i=99804, k='RES:RP:24').replace("op_key,reserve_qty_milli,status)", "op_key,reserve_qty_milli,status,created_at)").replace("'RESERVED')", "'RESERVED', strftime('%Y-%m-%d', 'now') || ' 24:00:00')")], "reservation_clock_skew")
print("=== 2z2-01/02 第十二轮新守卫（lot / stock_ledger_line / stock / sku_barcode / stock_snapshot_daily / stock_hold RETURN_PENDING）===")
_tx_block("lot REPLACE 同 (sku_id,lot_code,expiry_date) 换 id", ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99951,1,'LOT-RP','2027-01-01','2026-10-15')", "REPLACE INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99952,1,'LOT-RP','2027-01-01','2026-10-15')"], "lot_duplicate")
_tx_block("lot INSERT OR REPLACE 同 id（绕 sell_deadline 锁）", ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99951,1,'LOT-RP','2027-01-01','2026-10-15')", "INSERT OR REPLACE INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99951,1,'LOT-RP2','2027-02-01','2026-10-15')"], "lot_duplicate")
_tx_allow("变异：去掉 trg_lot_no_replace 后，lot REPLACE 换 id 通过", ["DROP TRIGGER trg_lot_no_replace", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99951,1,'LOT-RP','2027-01-01','2026-10-15')", "REPLACE INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99952,1,'LOT-RP','2027-01-01','2026-10-15')"])
_SLL = "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) SELECT 'SLLRP',1,'DOC',NULL WHERE NOT EXISTS (SELECT 1 FROM stock_ledger_line l WHERE l.biz_no = 'SLLRP' AND l.line_no = 1) ON CONFLICT (biz_no,line_no) DO NOTHING"
_tx_allow("02 原语先查再插：同一单据行建两次归属行，第二次 0 行（不被守卫误拦）", [_SLL, _SLL])
_tx_block("stock_ledger_line REPLACE 同 (biz_no,line_no) 改 src_kind（抢归属）", [_SLL, "REPLACE INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('SLLRP',1,'PDA','DEV-X')"], "ledger_line_duplicate")
_tx_block("旧写法 ON CONFLICT DO NOTHING 重放被守卫拦（证明原语必须先查再插）", [_SLL, "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('SLLRP',1,'DOC',NULL) ON CONFLICT (biz_no,line_no) DO NOTHING"], "ledger_line_duplicate")
_tx_allow("变异：去掉 trg_sll_no_replace 后，REPLACE 抢归属通过", ["DROP TRIGGER trg_sll_no_replace", _SLL, "REPLACE INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('SLLRP',1,'PDA','DEV-X')"])
_tx_block("stock REPLACE 同维度换 id（余额 / version 重置）", ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99953,1,'LOT-SRP','2027-01-01','2026-10-15')", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (99953,1,1,1,99953,'KG',5000)", "REPLACE INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (99954,1,1,1,99953,'KG',0)"], "stock.warehouse_id, stock.location_id, stock.sku_id, stock.lot_id, stock.container_id")
_tx_allow("变异：去掉 trg_stock_no_replace_dim 后，stock REPLACE 同维度通过", ["DROP TRIGGER trg_stock_no_replace_dim", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (99953,1,'LOT-SRP','2027-01-01','2026-10-15')", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (99953,1,1,1,99953,'KG',5000)", "REPLACE INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (99954,1,1,1,99953,'KG',0)"])
_tx_block("sku_barcode REPLACE 同条码换 id（抢条码）", ["INSERT INTO sku_barcode (id,sku_id,barcode,uom) VALUES (99955,1,'BC-RP','EA')", "REPLACE INTO sku_barcode (id,sku_id,barcode,uom) VALUES (99956,1,'BC-RP','KG')"], "sku_barcode.barcode")
# 种子（提交）：给逐键实打留样本行
for _s in ["INSERT INTO sku_barcode (id,sku_id,barcode,uom) VALUES (99990,1,'BC-PROBE','EA')",
           "INSERT INTO stock_snapshot_daily (work_date,stock_id,warehouse_id,location_id,sku_id,lot_id,container_id,on_hand_qty_milli,allocated_qty_milli,reserved_qty_milli,quality_hold_qty_milli,hold_qty_milli,ledger_seq) "
           "SELECT '2026-10-14',id,warehouse_id,location_id,sku_id,lot_id,container_id,on_hand_qty_milli,allocated_qty_milli,reserved_qty_milli,quality_hold_qty_milli,hold_qty_milli,0 FROM stock ORDER BY id LIMIT 1"]:
    conn.execute(_s)
conn.commit()
_tx_block("stock_snapshot_daily REPLACE 同 (work_date,stock_id)（改写历史快照）", ["REPLACE INTO stock_snapshot_daily (work_date,stock_id,warehouse_id,location_id,sku_id,lot_id,container_id,on_hand_qty_milli,allocated_qty_milli,reserved_qty_milli,quality_hold_qty_milli,hold_qty_milli,ledger_seq) SELECT work_date,stock_id,warehouse_id,location_id,sku_id,lot_id,container_id,0,0,0,0,0,0 FROM stock_snapshot_daily WHERE work_date = '2026-10-14'"], "stock_snapshot_daily.work_date, stock_snapshot_daily.stock_id")
# 第十三轮（小玛丽 r12 B1）：删掉"实打缺口"名单。给 r12 那 12 个键补无子行的合法种子（提交），2z3b 的生成器按 rowid 倒序先取到它们
def _copy_row(t, where, **chg):
    cs = [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
    r = dict(zip(cs, conn.execute(f"SELECT {', '.join(cs)} FROM {t} WHERE {where}").fetchone())); r.update(chg)
    conn.execute(f"INSERT INTO {t} ({', '.join(cs)}) VALUES ({', '.join('?' for _ in cs)})", [r[c] for c in cs])
_free_hold = lambda k: conn.execute("SELECT id FROM stock_hold WHERE id NOT IN (SELECT hold_id FROM process_issue WHERE hold_id IS NOT NULL) ORDER BY id LIMIT 1 OFFSET ?", (k,)).fetchone()[0]
_loc_lt = conn.execute("SELECT location_id FROM live_tank WHERE location_id NOT IN (SELECT location_id FROM live_tank_hold WHERE status = 'ACTIVE') ORDER BY location_id LIMIT 1").fetchone()[0]
_ins_lt = conn.execute("SELECT id FROM live_inspection ORDER BY id LIMIT 1").fetchone()[0]
_mv_free = conn.execute("SELECT movement_id FROM stock_movement_key WHERE movement_id NOT IN (SELECT movement_id FROM live_shrink_settlement WHERE movement_id IS NOT NULL) ORDER BY movement_id LIMIT 1").fetchone()[0]
for _s in ["INSERT INTO return_reservation (id,code,warehouse_id,store_code,outbound_order_id,status,created_by) VALUES (90001,'RSV-20261015-990001',1,'ST001',1,'CREATED',21)",
           "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,status) VALUES (90001,'DEV-RP','PDA',101,1,'PENDING')",
           f"INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id,status) VALUES (90001,1,{_loc_lt},'SEVERE',{_ins_lt},'ACTIVE')",
           f"INSERT INTO live_shrink_settlement (id,warehouse_id,location_id,lot_id,stock_id,work_date,book_qty_milli,measured_qty_milli,shrink_qty_milli,shrink_bp,tolerance_bp,outcome,movement_id,scrap_order_id) VALUES (90001,1,61,31,6101,'2026-09-01',10000,9950,50,50,100,'LOSS',{_mv_free},1)"]:
    conn.execute(_s)
_copy_row("process_issue", "id = 1722", id=1798, line_no=98, op_key="PRCI:1711:00000000-0000-4000-8000-000000009998", hold_id=_free_hold(0))
_copy_row("process_report", "id = 1744", id=1798, report_seq=8, report_client_id="00000000-0000-4000-8000-000000009998")
_li = conn.execute("SELECT id FROM live_inspection ORDER BY id DESC LIMIT 1").fetchone()[0]
_copy_row("live_inspection", f"id = {_li}", id=90001, client_op_id="00000000-0000-4000-8000-000000090001")   # 无子行（不被 live_tank_hold 引用）
conn.execute("INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (90001,1,'Z-RP','无库位','CHILLED','STORAGE',20,80)")   # 无子库位
conn.commit()
# 第 16 篇：配送与签收种子（提交；供 2z3b 逐键实打与部分唯一谓词样本）
_HASH = "a" * 64
for _s in [
    "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9401,'SHP-9401',1,'CREATED')",
    "INSERT INTO waybill (id,code,shipment_id,warehouse_id,driver_id,driver_name,work_date,status) VALUES (9401,'WB-SH01-0001-20261015-000001',9401,1,101,'司机甲','2026-10-15','CREATED')",
    "INSERT INTO delivery_stop (id,waybill_id,stop_no,customer_id,display_status) VALUES (9401,9401,1,1,'PENDING')",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (9402,'OBT-16-9402',1,'SALE','MALL','M-16-9402','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15')",
    "INSERT INTO outbound_line (id,outbound_id,line_no,sku_id,order_qty_milli,picked_qty_milli,uom) VALUES (9402,9402,1,1,10000,10000,'KG')",
    f"INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at,client_occurred_at) VALUES (9401,'WB-SH01-0001-20261015-000001',1,'D9401',1,'POD_SIGN','{_HASH}','200','0',40,'2026-10-15 02:00:00','2026-10-16 02:00:00','2026-10-15 02:00:00')",
    f"INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9402,'WB-SH01-0001-20261015-000001',0,'D9401',2,'LOAD','{_HASH}','200','0')",
    f"INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9403,'WB-SH01-0001-20261015-000001',1,'D9402',1,'POD_SIGN','{_HASH}','200','0',35,'2026-10-15 03:00:00','2026-10-16 03:00:00')",
    "INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9401,9401,1,1,10000,0,NULL,40)",
    "INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9402,9403,9402,1,10000,2000,'QUALITY',35)",
    "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9401,1,9401,1,'SHIPPED')",
    "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status,valid_pod_id,root_pod_id) VALUES (9402,9402,9401,1,'DELIVERED',9403,9403)",
    "INSERT INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at) VALUES (9401,'APR-WHSH01-20261015-009401','POD_CORRECT',1,'POD','9403','{}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','司机申请更正',101,NULL)",
    "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq) VALUES (9401,9403,9401,9403,9402,101,'00000000-0000-4000-8000-000000009401','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','PENDING',202,0,0)",
    "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,tolerance_version,correct_seq,decided_by,decided_at) VALUES (9402,9403,9401,9403,9402,101,'00000000-0000-4000-8000-000000009402','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','APPLIED',200,1,1,1,102,'2026-10-15 05:00:00')",
    "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,approval_id,response_http,auto_tolerance,correct_seq) VALUES (9403,9403,9402,9403,9402,102,'00000000-0000-4000-8000-000000009403','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','PENDING',9401,202,0,0)",
    "INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp,version) VALUES (9401,1,'',500,100,1)",
    "INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp,version) VALUES (9402,1,'VEG',200,50,1)",
    "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9401,9401,1,1,'OPEN')",
    "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status,rtn_inbound_id,counted_by,counted_at) VALUES (9402,9401,1,2,'COUNTED',8001,101,'2026-10-15 04:00:00')",
    "INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli,counted_qty_milli,exception_case_id) VALUES (9401,9402,1,1,5000,4000,100)",
    # 2z3b 逐键实打要「无子行」样本（生成器按 rowid 倒序取）：waybill / delivery_order / pod_correction 各一条
    "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9410,'SHP-9410',1,'CREATED')",
    "INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9410,'WB-SH01-0001-20261015-000010',9410,1,'2026-10-15','CREATED')",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (9410,'OBT-16-9410',1,'SALE','MALL','M-16-9410','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15')",
    "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9410,9410,9401,1,'SHIPPED')",
    "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq) VALUES (9410,9402,9410,9402,9402,103,'00000000-0000-4000-8000-000000009410','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','PENDING',202,0,0)",
    # 生成器要能构造「只撞目标键」的冲突行：每个键至少两行可组合的样本
    "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9411,'SHP-9411',1,'CREATED')",
    "INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9411,'WB-SH01-0001-20261015-000011',9411,1,'2026-10-15','CREATED')",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (9411,'OBT-16-9411',1,'SALE','MALL','M-16-9411','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15')",
    "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9411,9411,9401,1,'SHIPPED')",
    "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq) VALUES (9411,9402,9411,9402,9402,104,'00000000-0000-4000-8000-000000009411','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','PENDING',202,0,0)",
    f"INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9411,'WB-SH01-0001-20261015-000001',0,'D9411',9,'LOAD','{_HASH}','200','0')",
]:
    conn.execute(_s)
conn.commit()
# 生成器的"只撞目标键"造不出时的手写实打（不是豁免：同样两段——带守卫必须被拒且原行在，去掉全部触发器后必须通过且原行被删；任一不满足 = 红）。
# 两条都是"同主键、其余唯一键也落在同一行"：REPLACE 只会删这一行，原值被覆盖（小玛丽 r12 gap_probe2 的打法）
def _hand_rep(t, where, **chg):
    cs = [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
    r = dict(zip(cs, conn.execute(f"SELECT {', '.join(cs)} FROM {t} WHERE {where}").fetchone())); r.update(chg)
    return f"REPLACE INTO {t} ({', '.join(cs)}) VALUES ({', '.join('?' for _ in cs)})", [r[c] for c in cs]
_HAND = {
    ("live_tank_hold", ("id",)): (lambda: _hand_rep("live_tank_hold", "id = 90001", reason="CONSECUTIVE_BREACH"), "SELECT count(*) FROM live_tank_hold WHERE id = 90001 AND reason = 'SEVERE'"),
    ("process_issue", ("id",)): (lambda: _hand_rep("process_issue", "id = 1798", issue_qty_milli=conn.execute("SELECT issue_qty_milli + 1 FROM process_issue WHERE id = 1798").fetchone()[0]), "SELECT count(*) FROM process_issue WHERE id = 1798 AND issue_qty_milli = (SELECT issue_qty_milli FROM process_issue WHERE id = 1722)"),
    # 16 的 pod_correction 有 4 个唯一键（含 3 个部分唯一）挂在同一批列上，组合枚举到 120 次仍取不到合法行（NOT NULL corrected_pod_id）→ 手写：同 id REPLACE 只把 status 改成 VOID（退出两个部分唯一谓词，不撞其它键）
    ("pod_correction", ("id",)): (lambda: _hand_rep("pod_correction", "id = 9410", status="VOID"), "SELECT count(*) FROM pod_correction WHERE id = 9410 AND status = 'PENDING'"),
}
print("=== 2h-clock. 18 服务端时间（time-scan 18-1）：SQLite 只收 now ±300s ===")
for _n in _TOL18: conn.execute(_T18[_n])
conn.commit()
expect_block_tx('18 时钟：死亡上报 reported_at=2099', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, '2099-01-01 00:00:00' FROM live_death ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID reported_at')
expect_block_tx('18 时钟：死亡上报 reported_at 倒签 301s', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, datetime('now','-301 seconds') FROM live_death ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID reported_at')
expect_block_tx("18 时钟：死亡上报 reported_at 'zzzz'", ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, 'zzzz' FROM live_death ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID reported_at')
expect_block_tx('18 时钟：巡检 inspected_at 倒签 1 天', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) SELECT id+900000, warehouse_id, location_id, device_instance_id, client_op_id || 'z', inspector_id, datetime('now','-1 day'), temp_c10, do_x100, ph_x100, result, consecutive_breach, is_recheck FROM live_inspection ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID inspected_at')
expect_block_tx('18 时钟：巡检 inspected_at 预签 301s', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) SELECT id+900000, warehouse_id, location_id, device_instance_id, client_op_id || 'z', inspector_id, datetime('now','+301 seconds'), temp_c10, do_x100, ph_x100, result, consecutive_breach, is_recheck FROM live_inspection ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID inspected_at')
expect_block_tx('18 时钟：称重 weighed_at 倒签 1 天', ["INSERT INTO live_weigh (id,warehouse_id,task_kind,task_id,line_no,weigh_client_id,device_instance_id,scale_id,reading_source,location_id,stock_id,sku_id,lot_id,gross_qty_milli,tare_qty_milli,net_qty_milli,qty_count,planned_qty_milli,deviation_bp,result,result_code,movement_id,weighed_by,weighed_at) SELECT id+900000, warehouse_id, task_kind, task_id, line_no, weigh_client_id || 'z', device_instance_id, scale_id, reading_source, location_id, stock_id, sku_id, lot_id, gross_qty_milli, tare_qty_milli, net_qty_milli, qty_count, planned_qty_milli, deviation_bp, result, result_code, movement_id, weighed_by, datetime('now','-1 day') FROM live_weigh ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID weighed_at')
expect_block_tx('18 时钟：释放 released_at 倒签 1 天', ["INSERT INTO live_tank_hold (id,warehouse_id,location_id,reason,trigger_inspection_id,status,release_inspection_id,released_at) SELECT 990001, warehouse_id, location_id, 'SEVERE', id, 'RELEASED', id, datetime('now','-1 day') FROM live_inspection ORDER BY id LIMIT 1"], 'live_clock_skew: 40003 CLIENT_TIME_INVALID released_at')
expect_block_tx('18 时钟：死亡 work_date 非 ISO', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, '2026/10/15', device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, datetime('now') FROM live_death ORDER BY id LIMIT 1"], 'ck_ld_date')
allow_rb('18 T2 反向：设备原始时间 client_occurred_at 填 2099（仅展示）不影响入库', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at,client_occurred_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, datetime('now'), '2099-01-01 00:00:00' FROM live_death ORDER BY id LIMIT 1"])
expect_block_tx('18 T2：client_occurred_at 非 ISO', ["INSERT INTO live_death (id,warehouse_id,location_id,stock_id,lot_id,work_date,device_instance_id,client_op_id,death_count,death_qty_milli,day_rate_bp,approval_no,movement_id,deduct_status,deducted_qty_milli,exception_key,scrap_order_id,reported_by,reported_at,client_occurred_at) SELECT id+900000, warehouse_id, location_id, stock_id, lot_id, work_date, device_instance_id, client_op_id || 'z', death_count, death_qty_milli, day_rate_bp, approval_no, NULL, 'PENDING', 0, NULL, scrap_order_id, reported_by, datetime('now'), '2099/01/01' FROM live_death ORDER BY id LIMIT 1"], 'ck_ld_cts')
expect_block_tx('18 库写时间改成 NULL：live_death.reported_at', ["UPDATE live_death SET reported_at = NULL WHERE id = (SELECT min(id) FROM live_death)"], 'append_only')
allow_rb('18 时钟：巡检 inspected_at = now − 299s（容差内）', ["INSERT INTO live_inspection (id,warehouse_id,location_id,device_instance_id,client_op_id,inspector_id,inspected_at,temp_c10,do_x100,ph_x100,result,consecutive_breach,is_recheck) SELECT id+900000, warehouse_id, location_id, device_instance_id, client_op_id || 'z', inspector_id, datetime('now','-299 seconds'), temp_c10, do_x100, ph_x100, result, consecutive_breach, is_recheck FROM live_inspection ORDER BY id LIMIT 1"])
print("=== 2j. docs/03 入库：UC1/UC9、测温与离冷链、上架 SoD、质量反馈 SCRAP_PENDING、关单不可改、收货更正单（审批窗口 24h/7d、收货人不能审批） ===")
conn.commit(); ok("03 前置：foreign_keys = ON") if one("PRAGMA foreign_keys")[0] == 1 else bad("03 前置：foreign_keys 未开")
# 03 种子路径：遗留用例用固定日期（10-15 10:00 关单、10-16…10-22 审批），先摘掉 7 个时钟触发器（等同 PG 属主豁免），2j-clock 段前重建再测容差
_TOL03 = ['trg_inb_closed_tol_ins','trg_inb_closed_tol_upd','trg_inb_recon_tol','trg_inb_recon_tol_ins','trg_iqf_closed_tol','trg_iqf_closed_tol_ins','trg_irc_now']
_T03 = {n: one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", n)[0] for n in _TOL03}
def _p03(l): return [(_T03[x[10:]] if x.startswith('@RECREATE ') else ('DROP TRIGGER ' + x[6:] if x.startswith('@DROP ') else x)) for x in l]
for _n in _TOL03: conn.execute('DROP TRIGGER ' + _n)
conn.commit()
expect_allow_tx('03 种子：冷藏收货区/暂存位/存储位、SKU 冷鲜猪里脊、批次、两条库存行、采购入库单 + 行（订 100 KG）', ["INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (31,1,'Z-RCV','冷藏收货区','CHILLED','RECEIVE',20,80)", "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,pick_sequence) VALUES (31,1,31,'RCV-01','FLOOR',99,'R010'),(32,1,2,'B31-01-01','PALLET',8,'B310')", "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (31,'SKU-PORK','冷鲜猪里脊','KG','CHILLED',5,2,3)", "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (303,31,'L-PORK1','2026-10-20','2026-10-15')", "INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) VALUES (3101,1,31,31,303,'KG',0),(3102,1,32,31,303,'KG',0)", "INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date,arrived_at,unload_start_at) VALUES (3100,'INB-SH01-0001-20261015-000001',1,'PURCHASE','ERP','PO-3100','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',501,'RECEIVING','2026-10-15','2026-10-15 01:00:00','2026-10-15 01:05:00')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,temp_zone,ordered_qty_milli,lot_id,expiry_date) VALUES (3110,3100,1,31,'KG','CHILLED',100000,303,'2026-10-20')"])
expect_block_tx('03 单头状态白名单', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1',NULL,'DONE','2026-10-15',NULL)"], 'ck_inb_status')
expect_block_tx('03 source_hash 大写 hex', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA','CREATED','2026-10-15',NULL)"], 'ck_inb_hash')
expect_block_tx('03 退货入库来源白名单（#5 的 ck_inb_rtn_src，10 ALTER，基线已有）', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'RTN-X1',1,'RETURN','WHATEVER','X-1',NULL,'CREATED','2026-10-15',NULL)"], 'ck_inb_rtn_src')
expect_block_tx('03 COMPLETED 不带 closed_at', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-X1',NULL,'COMPLETED','2026-10-15',NULL)"], 'ck_inb_closed')
expect_block_tx('03 同上游单号重推（SQLite 由 trg_inb_no_replace 先拦，PG uq_inb_src）', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,status,work_date,closed_at) VALUES (3195,'INB-X1',1,'PURCHASE','ERP','PO-3100',NULL,'CREATED','2026-10-15',NULL)"], 'inbound_order_duplicate')
expect_allow_tx('03 #5 兼容：退货单只给 #5 用到的列也能建（三列由 10 ALTER 加）（RTN + 行 received_qty_milli）', ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3190,'RTN-3190',1,'RETURN','WMS_DELIVERY','POD-3190','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3191,3190,1,31,'KG',4000)"])
expect_block_tx('03 行实收为负（#5 的 ck_inbl_qc）', ["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3192,3190,2,31,'KG',-1)"], 'ck_inbl_qc')
expect_block_tx('03 行挂在不存在的单上', ["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3193,999999,1,31,'KG')"], 'FOREIGN KEY constraint failed')
expect_allow_tx('03 测温：温区整批 3.0 ℃ + 行 3.5 ℃（冷藏 0–4 ℃ 快照），PASS/ACCEPT', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3120,1,3100,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3100:z1',21,'2026-10-15 01:06:00'),(3121,1,3100,'LINE','CHILLED',3110,35,0,40,'PASS','ACCEPT','TMP:3100:l1',21,'2026-10-15 01:07:00')"])
expect_block_tx('03 测温 8.0 ℃ 却记 PASS（结果与读数不符）', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3110,80,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00')"], 'ck_itc_result')
expect_block_tx('03 测温 FAIL 仍判 ACCEPT（不合格只能拒收或转质检冻结）', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3110,80,0,40,'FAIL','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00')"], 'ck_itc_disp')
expect_block_tx('03 按行测温不带行号', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00')"], 'ck_itc_scope')
expect_block_tx('03 冷藏测温没有上下限快照', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'ZONE','CHILLED',NULL,30,NULL,NULL,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00')"], 'ck_itc_range')
# 03+10 增量·测温严格方案（Chief 三次确认）：非 AMBIENT 只给一端 = 快照不完整，必须拒；AMBIENT 两端全空仍放行
expect_block_tx('03 严格方案：冷藏只给上限（max=-150）也是快照不完整 → 拒', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3124,1,3100,'ZONE','CHILLED',NULL,-600,NULL,-150,'PASS','ACCEPT','TMP:3100:x4',21,'2026-10-15 01:10:00')"], 'ck_itc_range')
expect_block_tx('03 严格方案：冷冻只给下限（min=-250）也是快照不完整 → 拒', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3125,1,3100,'ZONE','FROZEN',NULL,-250,-250,NULL,'PASS','ACCEPT','TMP:3100:x5',21,'2026-10-15 01:10:00')"], 'ck_itc_range')
expect_allow_tx('03 严格方案正向：冷冻两端齐全（-250 ～ -150）照常 PASS', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3126,1,3100,'ZONE','FROZEN',NULL,-200,-250,-150,'PASS','ACCEPT','TMP:3100:x6',21,'2026-10-15 01:10:00')"])
expect_allow_tx('03 严格方案：AMBIENT 两端全空仍可落库（没有上下限快照）', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3127,1,3100,'ZONE','AMBIENT',NULL,250,NULL,NULL,'PASS','ACCEPT','TMP:3100:x7',21,'2026-10-15 01:10:00')"])
conn.execute("SAVEPOINT itcrange"); conn.execute("PRAGMA ignore_check_constraints = ON")
try:
    conn.execute("INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3128,1,3100,'ZONE','CHILLED',NULL,-600,NULL,-150,'PASS','ACCEPT','TMP:3100:x8',21,'2026-10-15 01:10:00')")
    ok("03 严格方案变异：去掉 ck_itc_range 后，只给上限的 -60 ℃ 冻货又能落库（随后回滚）")
except sqlite3.Error as e:
    bad(f"03 严格方案变异：去掉 ck_itc_range 后应能落库 → 被误拦：{e}")
finally:
    conn.execute("PRAGMA ignore_check_constraints = OFF")
    conn.execute("ROLLBACK TO itcrange"); conn.execute("RELEASE itcrange")
expect_block_tx('03 按行测温挂到别的单的行上（组合外键）', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3122,1,3100,'LINE','CHILLED',3191,30,0,40,'PASS','ACCEPT','TMP:3100:x1',21,'2026-10-15 01:08:00')"], 'FOREIGN KEY constraint failed')
expect_allow_tx('03 测温：复测 9.0 ℃ FAIL → REJECT', ["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3123,1,3100,'LINE','CHILLED',3110,90,0,40,'FAIL','REJECT','TMP:3100:l2',21,'2026-10-15 01:09:00')"])
expect_block_tx('03 测温记录只追加（UPDATE 改结果）', ["UPDATE inbound_temp_check SET result='PASS', disposition='ACCEPT', measured_c10=30 WHERE id=3123"], 'append_only_violation: inbound_temp_check')
expect_allow_tx('03 UC1 收货 60 KG：post_in(RECEIVE) 暂存位 + hold(QUALITY, QC_PENDING) + 收货记录（离冷链 12 分钟 ≤ 20 分钟上限快照）+ 行实收', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('INB-SH01-0001-20261015-000001',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=60000, ledger_seq=1, version=version+1 WHERE id=3101 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31001,'INB-SH01-0001-20261015-000001',1,1,1,'DOC','RECEIVE',1,3101,1,1,31,31,303,60000,0,60000,datetime('now'),'INB-SH01-0001-20261015-000001:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31001,'INB-SH01-0001-20261015-000001:1:D1:1','INB-SH01-0001-20261015-000001',1,1,1,'DOC',3101,1,1,datetime('now'))", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3130,3101,'QUALITY','QC_PENDING','INBOUND_QC',3100,'RCVH:3140',60000,21,NULL)", 'UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli+60000, version=version+1 WHERE id=3101 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=60000', "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3140,1,3100,3110,'RCV:3110:1',60000,3101,3130,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", 'UPDATE inbound_line SET received_qty_milli=received_qty_milli+60000, version=version+1 WHERE id=3110'])
expect_block_tx('03 冷藏收货不挂测温', ["INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',NULL,NULL,'2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')"], 'ck_rcp_temp')
expect_block_tx('03 收货挂的是 REJECT 测温', ["INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3123,'REJECT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')"], 'ck_rcp_temp')
expect_block_tx('03 收货挂 REJECT 测温却谎报 ACCEPT（组合外键带处置）', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3139,3101,'QUALITY','QC_PENDING','INBOUND_QC',3100,'RCVH:x',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3139,'INB-SH01-0001-20261015-000001',303,'CHILLED',3123,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')"], 'FOREIGN KEY constraint failed')
expect_block_tx('03 离冷链 25 分钟超 20 分钟上限却不标超时', ["INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',1500,1200,0,21,'2026-10-15 01:20:00')"], 'ck_rcp_chain')
expect_block_tx('03 冷藏收货不记离冷链时长', ["INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:9',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT',NULL,NULL,NULL,NULL,0,21,'2026-10-15 01:20:00')"], 'ck_rcp_chain')
expect_block_tx('03 收货记录只追加（UPDATE 改数量）', ['UPDATE inbound_receipt SET qty_milli=50000 WHERE id=3140'], 'append_only_violation: inbound_receipt')
expect_block_tx('03 收货记录只追加（DELETE）', ['DELETE FROM inbound_receipt WHERE id=3140'], 'append_only_violation: inbound_receipt')
expect_block_tx('03 收货重放同一 op_key', ["INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3141,1,3100,3110,'RCV:3110:1',60000,3101,3999,'INB-SH01-0001-20261015-000001',303,'CHILLED',3121,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')"], 'append_only_violation: inbound_receipt')
expect_allow_tx('03 UC9 质检放行 50 KG：unhold QUALITY（释放去重 + 明细 + quality_hold）+ 行 qc_passed', ["INSERT INTO stock_hold_release (id,hold_id,op_key,qty_milli) VALUES (3150,3130,'QCP:3110:1',50000)", "UPDATE stock_hold SET released_qty_milli=released_qty_milli+50000, status=CASE WHEN released_qty_milli+50000=hold_qty_milli THEN 'RELEASED' ELSE 'HELD' END, version=version+1 WHERE id=3130 AND hold_type='QUALITY' AND status='HELD' AND hold_qty_milli-released_qty_milli>=50000", 'UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-50000, version=version+1 WHERE id=3101 AND quality_hold_qty_milli>=50000', 'UPDATE inbound_line SET qc_passed_qty_milli=qc_passed_qty_milli+50000, version=version+1 WHERE id=3110 AND inbound_id=3100 AND qc_passed_qty_milli+qc_failed_qty_milli+50000<=received_qty_milli'])
expect_block_tx('03 合格 + 不合格超过实收', ['UPDATE inbound_line SET qc_failed_qty_milli=20000 WHERE id=3110'], 'ck_inbl_qc')
expect_allow_tx('03 UC9 质检不合格 4 KG：convert_hold QUALITY → SCRAP_PENDING（跨列）+ 行 qc_failed', ["UPDATE stock_hold SET released_qty_milli=released_qty_milli+4000, version=version+1 WHERE id=3130 AND status='HELD' AND hold_qty_milli-released_qty_milli>=4000", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3132,3101,'SCRAP_PENDING','SCRAP','SCRAP',9301,'CVT:3110:1',4000,0,3130)", 'UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-4000, hold_qty_milli=hold_qty_milli+4000, version=version+1 WHERE id=3101 AND quality_hold_qty_milli>=4000', 'UPDATE inbound_line SET qc_failed_qty_milli=qc_failed_qty_milli+4000, version=version+1 WHERE id=3110 AND qc_passed_qty_milli+qc_failed_qty_milli+4000<=received_qty_milli'])
expect_allow_tx('03 UC2 上架 30 KG（收货人 21、上架人 22）：move(PUTAWAY) 两腿 + 上架记录 + 行 putaway（trg_inbp_apply 累加）', ['UPDATE stock SET on_hand_qty_milli=30000, ledger_seq=2, version=version+1 WHERE id=3101 AND ledger_seq=1 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=30000', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31002,'INB-SH01-0001-20261015-000001',1,2,1,'DOC','PUTAWAY',-1,3101,2,1,31,31,303,30000,60000,30000,datetime('now'),'INB-SH01-0001-20261015-000001:1:D2:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31002,'INB-SH01-0001-20261015-000001:1:D2:1','INB-SH01-0001-20261015-000001',1,2,1,'DOC',3101,2,-1,datetime('now'))", 'UPDATE stock SET on_hand_qty_milli=30000, ledger_seq=1, version=version+1 WHERE id=3102 AND ledger_seq=0', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31003,'INB-SH01-0001-20261015-000001',1,2,2,'DOC','PUTAWAY',1,3102,1,1,32,31,303,30000,0,30000,datetime('now'),'INB-SH01-0001-20261015-000001:1:D2:2',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31003,'INB-SH01-0001-20261015-000001:1:D2:2','INB-SH01-0001-20261015-000001',1,2,2,'DOC',3102,1,1,datetime('now'))", "INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3160,1,3100,3110,3140,21,22,NULL,'PUT:3140:1',3101,32,30000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"])
expect_block_tx('03 SoD：收货人 = 上架人（无放宽审批）', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,NULL,'PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_sod')
expect_block_tx('03 SoD：放宽单号不是审批单号', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,'OK-123','PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 SoD：上架记录伪造收货人（与收货记录不符，组合外键）', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,23,21,NULL,'PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'FOREIGN KEY constraint failed')
allow_rb('03 SoD 放宽：小仓凭审批单号允许同一人（00 §2，放宽记审计）', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3161,1,3100,3110,3140,21,21,'APR-WHSH01-20261015-000301','PUT:3140:9',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"])
expect_block_tx('03 上架记录只追加（UPDATE 改上架人）', ['UPDATE inbound_putaway SET putaway_by=21 WHERE id=3160'], 'append_only_violation: inbound_putaway')
r = str(one("SELECT (SELECT putaway_qty_milli FROM inbound_line WHERE id=3110)||'/'||(SELECT sum(qty_milli) FROM inbound_putaway WHERE inbound_line_id=3110)||'/'||(SELECT on_hand_qty_milli FROM stock WHERE id=3102)")[0]); ok('03 对账：行上架量 = Σ上架记录 = 存储位在库' + ' = ' + r) if r == '30000/30000/30000' else bad('03 对账：行上架量 = Σ上架记录 = 存储位在库' + ' = ' + r + '（期望 30000/30000/30000）')
expect_block_tx('03 B1 超上架：已上 30 KG，再上 20.001 KG（合格 50 KG）', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,20001,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'inbound_putaway_over_qty: 42214 OVER_QTY reason=OVER_PUTAWAY')
allow_rb('03 B1 上架正好补满合格量（30 + 20 = 50 KG）', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,20000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"])
expect_block_tx('03 B1 上架数量 0', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3162,1,3100,3110,3140,21,22,NULL,'PUT:3140:3162',3101,32,0,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_qty')
expect_block_tx('03 B1 直接改行上架量超过合格量', ['UPDATE inbound_line SET putaway_qty_milli=999999 WHERE id=3191'], 'inbound_putaway_over_qc_passed')
expect_block_tx('03 B1 直接改行上架量（≤ 合格量但与上架记录合计不符）', ['UPDATE inbound_line SET putaway_qty_milli=31000 WHERE id=3110'], 'inbound_putaway_counter_mismatch')
expect_block_tx('03 B1 把合格量压到已上架量以下（计数器只增，先被 counter_not_monotonic 拦）', ['UPDATE inbound_line SET qc_passed_qty_milli=29999 WHERE id=3110'], 'inbound_line_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC')
expect_block_tx('03 B1 新建行自带上架量', ["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli,qc_passed_qty_milli,putaway_qty_milli) VALUES (3194,3190,2,31,'KG',10,10,5)"], 'inbound_putaway_counter_mismatch')
expect_block_tx('03 N1 SoD 放宽单号格式：只有前缀 APR-', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 N1 SoD 放宽单号格式：空串', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 N1 SoD 放宽单号格式：APR- 加空格', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-   ','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 N1 SoD 放宽单号格式：小写', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'apr-whsh01-20261015-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 N1 SoD 放宽单号格式：前导空格', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,' APR-WHSH01-20261015-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_block_tx('03 N1 SoD 放宽单号格式：13 月', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3163,1,3100,3110,3140,21,21,'APR-WHSH01-20261315-000301','PUT:3140:3163',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'ck_inbp_waiver')
expect_allow_tx('03 入库后质量反馈：在库发现 1 KG 腐坏 → hold(QUALITY) + 反馈单 OPEN', ["INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3134,3102,'QUALITY','QC_PENDING','INBOUND_FB',3180,'IQFH:3180',1000,22,NULL)", 'UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli+1000, version=version+1 WHERE id=3102 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=1000', "INSERT INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,disposition,reported_by,found_at) VALUES (3180,1,'IQF-SH01-0001-20261015-000001',3100,3110,303,'IN_STOCK','ROT',1000,3102,3134,'PENDING',22,'2026-10-15 05:00:00')"])
expect_block_tx('03 质量反馈：驳回处置不挂冻结', ["INSERT INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,status,disposition,reported_by,found_at,closed_by,closed_at) VALUES (3181,1,'IQF-SH01-0001-20261015-000002',3100,3110,303,'IN_STOCK','ROT',1000,3102,NULL,'CLOSED','REJECTED',22,'2026-10-15 05:00:00',9,'2026-10-15 06:00:00')"], 'ck_iqf_hold')
expect_block_tx('03 质量反馈：OPEN 改受影响数量', ['UPDATE inbound_quality_feedback SET affected_qty_milli=500 WHERE id=3180'], 'iqf_immutable')
expect_block_tx('03 质量反馈：发现人自己关单', ["UPDATE inbound_quality_feedback SET status='CLOSED', disposition='REJECTED', closed_by=22, closed_at='2026-10-15 06:00:00' WHERE id=3180"], 'ck_iqf_close')
expect_block_tx('03 质量反馈：报损关单不挂 SCRAP_PENDING 冻结', ["UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00' WHERE id=3180"], 'ck_iqf_scrap')
expect_block_tx('03 质量反馈：报损关单挂的是 QUALITY 冻结（不是 SCRAP_PENDING）', ["UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00', scrap_hold_id=3134 WHERE id=3180"], 'iqf_scrap_hold_not_scrap_pending')
expect_block_tx('03 质量反馈：退供待处置也必须挂 SCRAP_PENDING', ["UPDATE inbound_quality_feedback SET status='CLOSED', disposition='RETURN_SUPPLIER', closed_by=9, closed_at='2026-10-15 06:00:00' WHERE id=3180"], 'ck_iqf_scrap')
expect_allow_tx('03 质量反馈关单：主管 9 判 SCRAP，挂 hold(SCRAP_PENDING) 3135，convert_hold QUALITY → SCRAP_PENDING', ["UPDATE stock_hold SET released_qty_milli=1000, status='RELEASED', version=version+1 WHERE id=3134 AND status='HELD' AND released_qty_milli=0", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3135,3102,'SCRAP_PENDING','SCRAP','SCRAP',9302,'CVT:3134',1000,0,3134)", 'UPDATE stock SET quality_hold_qty_milli=quality_hold_qty_milli-1000, hold_qty_milli=hold_qty_milli+1000, version=version+1 WHERE id=3102 AND quality_hold_qty_milli>=1000', "UPDATE inbound_quality_feedback SET status='CLOSED', disposition='SCRAP', closed_by=9, closed_at='2026-10-15 06:00:00', scrap_hold_id=3135, version=version+1 WHERE id=3180 AND status='OPEN'"])
expect_block_tx('03 质量反馈：关单后再改', ["UPDATE inbound_quality_feedback SET remark='x' WHERE id=3180"], 'iqf_immutable')
expect_block_tx('03 质量反馈：删除', ['DELETE FROM inbound_quality_feedback WHERE id=3180'], 'iqf_immutable')
expect_allow_tx('03 关单：入库单 3100 COMPLETED（属主写 closed_at 10:00，不被库时钟覆盖）', ["UPDATE inbound_order SET status='COMPLETED', received_at='2026-10-15 01:20:00', closed_at='2026-10-15 10:00:00', version=version+1 WHERE id=3100 AND status='RECEIVING'"])
r = one("SELECT closed_at FROM inbound_order WHERE id=3100")[0]; ok('03 时间：种子路径关单时间 = ' + r) if r == '2026-10-15 10:00:00' else bad('03 种子关单时间 = ' + str(r))
expect_block_tx('03 关单后改原单（单头备注）', ["UPDATE inbound_order SET remark='x' WHERE id=3100"], 'inbound_order_closed_immutable')
expect_block_tx('03 关单后改入库行实收（更正只能开更正单）', ['UPDATE inbound_line SET received_qty_milli=62000 WHERE id=3110'], 'inbound_line_closed_immutable')
expect_block_tx('03 关单后往单上加行', ["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3111,3100,2,31,'KG')"], 'inbound_line_closed_immutable')
expect_block_tx('03 关单后删单', ['DELETE FROM inbound_order WHERE id=3100'], 'inbound_order_closed_immutable')
expect_block_tx('03 B1 关单后再上架', ["INSERT INTO inbound_putaway (id,warehouse_id,inbound_id,inbound_line_id,receipt_id,received_by,putaway_by,sod_waiver_no,op_key,from_stock_id,to_location_id,qty_milli,movement_biz_no,offchain_sec,putaway_at) VALUES (3165,1,3100,3110,3140,21,22,NULL,'PUT:3140:3165',3101,32,1000,'INB-SH01-0001-20261015-000001',300,'2026-10-15 02:00:00')"], 'inbound_putaway_closed_immutable')
expect_block_tx('03 更正单：关单后 24h+1s 只有主管审批（要主管 + 采购双审）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31101,'IRC-B1',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31101,'IRC-B1:1:D1:1','IRC-B1',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31101,'wms.inbound.corrected','IRC-B1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3201,1,'IRC-B1',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3201',1,2000,3102,31101,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03201','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-16 10:00:01')"], 'inbound_correction_dual_approval_required')
expect_block_tx('03 更正单：关单后 7d+1s（超窗，转 08 盘点调整）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B2',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31102,'IRC-B2',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B2:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31102,'IRC-B2:1:D1:1','IRC-B2',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31102,'wms.inbound.corrected','IRC-B2','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3202,1,'IRC-B2',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3202',1,2000,3102,31102,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03202','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-22 10:00:01')"], 'inbound_correction_window_closed: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust')
expect_block_tx('03 更正单：24h 内按双审落档（层级必须与窗口一致）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B3',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31103,'IRC-B3',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B3:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31103,'IRC-B3:1:D1:1','IRC-B3',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31103,'wms.inbound.corrected','IRC-B3','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3203,1,'IRC-B3',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3203',1,2000,3102,31103,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03203','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-15 12:00:00')"], 'inbound_correction_tier_mismatch')
expect_block_tx('03 更正单：收货人 21 当主管审批（申请人另有其人）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B4',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31104,'IRC-B4',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B4:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31104,'IRC-B4:1:D1:1','IRC-B4',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31104,'wms.inbound.corrected','IRC-B4','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3204,1,'IRC-B4',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3204',1,2000,3102,31104,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03204','SUPERVISOR',23,'2026-10-15 10:00:00',21,NULL,'2026-10-15 12:00:00')"], 'ck_irc_receiver_sod')
expect_block_tx('03 更正单：收货人 21 当采购审批（双审）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B5',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31105,'IRC-B5',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B5:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31105,'IRC-B5:1:D1:1','IRC-B5',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31105,'wms.inbound.corrected','IRC-B5','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3205,1,'IRC-B5',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3205',1,2000,3102,31105,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03205','DUAL',23,'2026-10-15 10:00:00',9,21,'2026-10-17 12:00:00')"], 'ck_irc_receiver_sod')
expect_block_tx('03 更正单：申请人自批', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B6',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31106,'IRC-B6',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B6:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31106,'IRC-B6:1:D1:1','IRC-B6',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31106,'wms.inbound.corrected','IRC-B6','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3206,1,'IRC-B6',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3206',1,2000,3102,31106,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03206','SUPERVISOR',23,'2026-10-15 10:00:00',23,NULL,'2026-10-15 12:00:00')"], 'ck_irc_self_apr')
expect_block_tx('03 更正单：原因码必填', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B7',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31107,'IRC-B7',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B7:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31107,'IRC-B7:1:D1:1','IRC-B7',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31107,'wms.inbound.corrected','IRC-B7','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3207,1,'IRC-B7',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3207',1,2000,3102,31107,NULL,NULL,'APR-WHSH01-20261015-03207','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00')"], 'inbound_correction.reason_code')
expect_block_tx('03 更正单：原因码 OTHER 不写说明', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B8',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31108,'IRC-B8',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B8:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31108,'IRC-B8:1:D1:1','IRC-B8',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31108,'wms.inbound.corrected','IRC-B8','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3208,1,'IRC-B8',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3208',1,2000,3102,31108,'OTHER',NULL,'APR-WHSH01-20261015-03208','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00')"], 'ck_irc_reason')
expect_block_tx('03 更正单：原因码不在字典', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B9',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31109,'IRC-B9',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B9:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31109,'IRC-B9:1:D1:1','IRC-B9',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31109,'wms.inbound.corrected','IRC-B9','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3209,1,'IRC-B9',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3209',1,2000,3102,31109,'MISCOUNT',NULL,'APR-WHSH01-20261015-03209','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00')"], 'ck_irc_reason')
expect_block_tx('03 更正单：伪造收货人（与收货记录不符，组合外键）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B10',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31110,'IRC-B10',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B10:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31110,'IRC-B10:1:D1:1','IRC-B10',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31110,'wms.inbound.corrected','IRC-B10','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3210,1,'IRC-B10',3100,3110,3140,22,'2026-10-15 10:00:00','IRC:3140:3210',1,2000,3102,31110,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03210','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00')"], 'FOREIGN KEY constraint failed')
expect_block_tx('03 更正单：伪造关单时间把窗口往后挪（组合外键）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B11',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31111,'IRC-B11',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B11:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31111,'IRC-B11:1:D1:1','IRC-B11',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31111,'wms.inbound.corrected','IRC-B11','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3211,1,'IRC-B11',3100,3110,3140,21,'2026-10-16 12:00:00','IRC:3140:3211',1,2000,3102,31111,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03211','SUPERVISOR',23,'2026-10-16 12:00:00',9,NULL,'2026-10-17 12:00:00')"], 'FOREIGN KEY constraint failed')
expect_block_tx('03 更正单：流水数量和更正数量不符（必须经 02 原语过账同量）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B12',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31112,'IRC-B12',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,1500,30000,31500,CURRENT_TIMESTAMP,'IRC-B12:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31112,'IRC-B12:1:D1:1','IRC-B12',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31112,'wms.inbound.corrected','IRC-B12','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3212,1,'IRC-B12',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3212',1,2000,3102,31112,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03212','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-15 12:00:00')"], 'inbound_correction_movement_mismatch')
expect_block_tx('03 B2 更正单：批准时间早于关单（整秒比较）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B14',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31113,'IRC-B14',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-B14:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31113,'IRC-B14:1:D1:1','IRC-B14',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31113,'wms.inbound.corrected','IRC-B14','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3213,1,'IRC-B14',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3213',1,2000,3102,31113,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03213','SUPERVISOR',23,'2026-10-15 09:59:59',9,NULL,'2026-10-15 09:59:59')"], 'inbound_correction_before_close')
expect_allow_tx('03 更正单 +2 KG：关单后正好 24h，主管 9 审批（收货人 21、申请人 23）→ post_in(ADJUST) + outbox PENDING', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=2, version=version+1 WHERE id=3102 AND ledger_seq=1', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31120,'IRC-A1',1,1,1,'DOC','ADJUST',1,3102,2,1,32,31,303,2000,30000,32000,CURRENT_TIMESTAMP,'IRC-A1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31120,'IRC-A1:1:D1:1','IRC-A1',1,1,1,'DOC',3102,2,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31120,'wms.inbound.corrected','IRC-A1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3220,1,'IRC-A1',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3220',1,2000,3102,31120,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03220','SUPERVISOR',23,'2026-10-15 10:00:00',9,NULL,'2026-10-16 10:00:00')"])
expect_allow_tx('03 更正单 −1 KG：关单后正好 7d，主管 9 + 采购 41 双审 → post_out(ADJUST)', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A2',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=31000, ledger_seq=3, version=version+1 WHERE id=3102 AND ledger_seq=2 AND on_hand_qty_milli-allocated_qty_milli-reserved_qty_milli-quality_hold_qty_milli-hold_qty_milli>=1000', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31122,'IRC-A2',1,1,1,'DOC','ADJUST',-1,3102,3,1,32,31,303,1000,32000,31000,CURRENT_TIMESTAMP,'IRC-A2:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31122,'IRC-A2:1:D1:1','IRC-A2',1,1,1,'DOC',3102,3,-1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31122,'wms.inbound.corrected','IRC-A2','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3222,1,'IRC-A2',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3222',-1,1000,3102,31122,'WEIGHT_ERROR',NULL,'APR-WHSH01-20261015-03222','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-22 10:00:00')"])
expect_allow_tx('03 更正单 +0.5 KG：25h 双审（24h–7d 段内）', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A3',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=31500, ledger_seq=4, version=version+1 WHERE id=3102 AND ledger_seq=3', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31123,'IRC-A3',1,1,1,'DOC','ADJUST',1,3102,4,1,32,31,303,500,31000,31500,CURRENT_TIMESTAMP,'IRC-A3:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31123,'IRC-A3:1:D1:1','IRC-A3',1,1,1,'DOC',3102,4,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31123,'wms.inbound.corrected','IRC-A3','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3223,1,'IRC-A3',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3223',1,500,3102,31123,'WRONG_BATCH',NULL,'APR-WHSH01-20261015-03223','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 11:00:00')"])
expect_block_tx('03 更正单：同一 op_key 重放', ["INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-A3R',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31121,'IRC-A3R',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-A3R:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31121,'IRC-A3R:1:D1:1','IRC-A3R',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31121,'wms.inbound.corrected','IRC-A3R','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3221,1,'IRC-A3R',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3223',1,500,3102,31121,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03221','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 11:00:00')"], 'append_only_violation: inbound_correction')
expect_block_tx('03 更正单只追加（UPDATE 改数量）', ['UPDATE inbound_correction SET qty_milli=1 WHERE id=3220'], 'append_only_violation: inbound_correction')
expect_block_tx('03 更正单只追加（DELETE）', ['DELETE FROM inbound_correction WHERE id=3220'], 'append_only_violation: inbound_correction')
expect_block_tx('03 已对账结算后再开更正单（转 08）', ["UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 12:00:00' WHERE id=3100", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00')"], 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust')
expect_block_tx('03 N4 对账时间 = 批准时间（同一秒，边界算已对账）', ["UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:00' WHERE id=3100", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00')"], 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust')
allow_rb('03 N4 对账时间晚批准 1 秒：仍可开更正单', ["UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:01' WHERE id=3100", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-B13',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31124,'IRC-B13',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-B13:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31124,'IRC-B13:1:D1:1','IRC-B13',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31124,'wms.inbound.corrected','IRC-B13','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3224,1,'IRC-B13',3100,3110,3140,21,'2026-10-15 10:00:00','IRC:3140:3224',1,500,3102,31124,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03224','DUAL',23,'2026-10-15 10:00:00',9,41,'2026-10-16 13:00:00')"])
expect_block_tx('03 对账时间回写后不能再改', ["UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 12:00:00' WHERE id=3100", "UPDATE inbound_order SET supplier_reconciled_at='2026-10-16 13:00:00' WHERE id=3100"], 'inbound_order_closed_immutable')
r = str(one("SELECT (SELECT received_qty_milli FROM inbound_line WHERE id=3110) + (SELECT sum(direction*qty_milli) FROM inbound_correction WHERE inbound_line_id=3110)")[0]); ok('03 对账：净实收 = 行实收 60 + Σ更正（+2 −1 +0.5） = ' + r) if r == '61500' else bad('03 对账：净实收 = 行实收 60 + Σ更正（+2 −1 +0.5） = ' + r + '（期望 61500）')
r = str(one("SELECT on_hand_qty_milli FROM stock WHERE id=3102")[0]); ok('03 对账：存储位在库 30 + 1.5 = ' + r) if r == '31500' else bad('03 对账：存储位在库 30 + 1.5 = ' + r + '（期望 31500）')
r = str(one("SELECT sum(m.direction*m.move_qty_milli) FROM stock_movement m JOIN inbound_correction c ON c.movement_id=m.id WHERE m.biz_type='ADJUST'")[0]); ok('03 对账：更正单挂的 ADJUST 流水净额 = ' + r) if r == '1500' else bad('03 对账：更正单挂的 ADJUST 流水净额 = ' + r + '（期望 1500）')
r = str(one("SELECT count(*) FROM outbox_event WHERE topic='wms.inbound.corrected' AND status='PENDING'")[0]); ok('03 对账：更正单回传 11：outbox 都是 PENDING = ' + r) if r == '3' else bad('03 对账：更正单回传 11：outbox 都是 PENDING = ' + r + '（期望 3）')
r = str(one("SELECT count(*) FROM inbound_receipt WHERE id=3140 AND qty_milli=60000")[0]); ok('03 对账：原收货记录未被改（60 KG） = ' + r) if r == '1' else bad('03 对账：原收货记录未被改（60 KG） = ' + r + '（期望 1）')
r = str(one("SELECT (SELECT putaway_qty_milli FROM inbound_line WHERE id=3110) = (SELECT sum(qty_milli) FROM inbound_putaway WHERE inbound_line_id=3110)")[0]); ok('03 对账：B1 行上架量 = Σ上架记录 = ' + r) if r == '1' else bad('03 对账：B1 行上架量 = Σ上架记录 = ' + r + '（期望 1）')
expect_block_tx('03 R3 入库行 sku_id 不存在（fk_inbl_sku）', ["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3197,3190,9,999999,'KG')"], 'FOREIGN KEY constraint failed')
print("=== 2j-clock. 03 时间约定：SQLite 只收规范整秒、±300s ===")
for _n in _TOL03: conn.execute(_T03[_n])
conn.commit()
ok('03 时钟触发器已重建 7 个') if one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN (%s)" % ','.join(repr(n) for n in _TOL03))[0] == 7 else bad('03 时钟触发器重建不全')
allow_rb('03 时钟：更正单 approved_at = now（关单 1h，主管审批）', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now'))"]))
allow_rb('03 时钟：approved_at = now − 299s（容差内）', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now','-299 seconds'))"]))
allow_rb('03 时钟：approved_at = now + 299s（容差内）', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now','+299 seconds'))"]))
expect_block_tx('03 时钟：approved_at 倒签 301s', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now','-301 seconds'))"]), 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at')
expect_block_tx('03 时钟：approved_at 预签 301s', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now','+301 seconds'))"]), 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at')
expect_block_tx('03 时钟：approved_at 倒签到关单前', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,'2026-10-15 00:00:00')"]), 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at')
expect_block_tx("03 时钟：approved_at 'zzzz'（strftime 为 NULL）", _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,'zzzz')"]), 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at')
expect_block_tx('03 时钟：approved_at 斜杠', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,'2026/10/15 01:00:00')"]), 'inbound_correction_clock_skew: 40003 CLIENT_TIME_INVALID approved_at')
expect_block_tx("03 时钟：approved_at 'T' 分隔（在容差内但非规范）", _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,replace(datetime('now'),' ','T'))"]), 'ck_irc_ts')
expect_block_tx('03 时钟：approved_at 小数秒（在容差内但非规范）', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now')||'.5')"]), 'ck_irc_ts')
expect_block_tx('03 时钟：approved_at 带偏移（在容差内但非规范）', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now')||'+00:00')"]), 'ck_irc_ts')
expect_block_tx('03 N4 时钟：对账 = now，同一时刻开更正单', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "UPDATE inbound_order SET supplier_reconciled_at=datetime('now') WHERE id=3300", "INSERT INTO stock_ledger_line (biz_no,line_no,src_kind,owner_device_instance_id) VALUES ('IRC-T1',1,'DOC',NULL)", 'UPDATE stock SET on_hand_qty_milli=32000, ledger_seq=5, version=version+1 WHERE id=3102 AND ledger_seq=4', "INSERT INTO stock_movement (id,biz_no,line_no,op_no,leg,src_kind,biz_type,direction,stock_id,stock_seq,warehouse_id,location_id,sku_id,lot_id,move_qty_milli,on_hand_before_qty_milli,on_hand_after_qty_milli,occurred_at,idempotency_key,hold_id) VALUES (31220,'IRC-T1',1,1,1,'DOC','ADJUST',1,3102,5,1,32,31,303,500,31500,32000,CURRENT_TIMESTAMP,'IRC-T1:1:D1:1',NULL)", "INSERT INTO stock_movement_key (movement_id,idempotency_key,biz_no,line_no,op_no,leg,src_kind,stock_id,stock_seq,direction,occurred_at) VALUES (31220,'IRC-T1:1:D1:1','IRC-T1',1,1,1,'DOC',3102,5,1,CURRENT_TIMESTAMP)", "INSERT INTO outbox_event (id,topic,biz_key,payload,status) VALUES (31220,'wms.inbound.corrected','IRC-T1','{}','PENDING')", "INSERT INTO inbound_correction (id,warehouse_id,code,inbound_id,inbound_line_id,receipt_id,received_by,order_closed_at,op_key,direction,qty_milli,stock_id,movement_id,reason_code,reason_note,approval_no,approval_tier,requested_by,requested_at,supervisor_id,purchasing_id,approved_at) VALUES (3320,1,'IRC-T1',3300,3301,3304,21,(SELECT closed_at FROM inbound_order WHERE id=3300),'IRC:3304:3320',1,500,3102,31220,'COUNT_ERROR',NULL,'APR-WHSH01-20261015-03320','SUPERVISOR',23,(SELECT closed_at FROM inbound_order WHERE id=3300),9,NULL,datetime('now'))"]), 'inbound_correction_reconciled: 40930 INBOUND_CORRECTION_WINDOW_EXPIRED, use 08 count adjust')
expect_block_tx('03 时钟：对账时间倒签 301s', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "UPDATE inbound_order SET supplier_reconciled_at=datetime('now','-301 seconds') WHERE id=3300"]), 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID supplier_reconciled_at')
allow_rb('03 时钟：对账时间 = now', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3300,'INB-3300',1,'PURCHASE','ERP','PO-3300','RECEIVING','2026-10-15')", "INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,received_qty_milli) VALUES (3301,3300,1,31,'KG',2000)", "INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3303,1,3300,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3300:z1',21,'2026-10-15 01:06:00')", "INSERT INTO stock_hold (id,stock_id,hold_type,reason_code,source_type,source_id,op_key,hold_qty_milli,operator_id,from_hold_id) VALUES (3302,3101,'QUALITY','QC_PENDING','INBOUND_QC',3300,'RCVH:3304',1,21,NULL)", "INSERT INTO inbound_receipt (id,warehouse_id,inbound_id,inbound_line_id,op_key,qty_milli,stock_id,hold_id,movement_biz_no,lot_id,temp_zone,temp_check_id,temp_check_disp,offchain_start_at,offchain_end_at,offchain_sec,offchain_limit_sec,is_offchain_over,received_by,received_at) VALUES (3304,1,3300,3301,'RCV:3301:1',2000,3101,3302,'INB-SH01-0001-20261015-000001',303,'CHILLED',3303,'ACCEPT','2026-10-15 01:05:00','2026-10-15 01:17:00',720,1200,0,21,'2026-10-15 01:20:00')", '@DROP trg_inb_closed_tol_upd', "UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-3600 seconds') WHERE id=3300", '@RECREATE trg_inb_closed_tol_upd', "UPDATE inbound_order SET supplier_reconciled_at=datetime('now') WHERE id=3300"]))
expect_block_tx('03 时钟：关单 closed_at 倒签 301s', _p03(["UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','-301 seconds') WHERE id=3190"]), 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at')
expect_block_tx('03 时钟：关单 closed_at 预签 301s', _p03(["UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now','+301 seconds') WHERE id=3190"]), 'inbound_order_clock_skew: 40003 CLIENT_TIME_INVALID closed_at')
allow_rb('03 时钟：关单 closed_at = now', _p03(["UPDATE inbound_order SET status='COMPLETED', closed_at=datetime('now') WHERE id=3190"]))
expect_block_tx('03 时钟：质量反馈直接以 CLOSED 建单、closed_at 倒签', _p03(["INSERT INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,status,disposition,reported_by,found_at,closed_by,closed_at) VALUES (3185,1,'IQF-SH01-0001-20261015-000009',3100,3110,303,'IN_STOCK','ROT',1000,3102,NULL,'CLOSED','REJECTED',22,'2026-10-15 05:00:00',9,'2020-01-01 00:00:00')"]), 'inbound_quality_feedback_clock_skew: 40003 CLIENT_TIME_INVALID closed_at')
expect_block_tx('03 B2 测温时间非 ISO', _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at) VALUES (3305,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:z9',21,'2026-10-15T01:06:00')"]), 'ck_itc_ts')
expect_block_tx('03 状态迁移：RECEIVING → CREATED（回退）', _p03(["UPDATE inbound_order SET status='CREATED' WHERE id=3190"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：RECEIVING → ARRIVED（回退）', _p03(["UPDATE inbound_order SET status='ARRIVED' WHERE id=3190"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：RECEIVED → RECEIVING（回退）', _p03(["UPDATE inbound_order SET status='RECEIVED' WHERE id=3190", "UPDATE inbound_order SET status='RECEIVING' WHERE id=3190"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：PUTTING_AWAY → RECEIVED（回退）', _p03(["UPDATE inbound_order SET status='PUTTING_AWAY' WHERE id=3190", "UPDATE inbound_order SET status='RECEIVED' WHERE id=3190"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：CANCELLED 终态 → RECEIVING', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date,closed_at) VALUES (3196,'INB-3196',1,'PURCHASE','ERP','PO-3196','CANCELLED','2026-10-15',datetime('now'))", "UPDATE inbound_order SET status='RECEIVING' WHERE id=3196"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：CANCELLED 终态 → COMPLETED', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date,closed_at) VALUES (3196,'INB-3196',1,'PURCHASE','ERP','PO-3196','CANCELLED','2026-10-15',datetime('now'))", "UPDATE inbound_order SET status='COMPLETED' WHERE id=3196"]), 'inbound_order_state_forward_only')
expect_block_tx('03 状态迁移：COMPLETED 终态 → RECEIVING（关单守卫先拦）', _p03(["UPDATE inbound_order SET status='RECEIVING' WHERE id=3100"]), 'inbound_order_state_forward_only')
allow_rb('03 状态迁移：RECEIVING → RECEIVED → PUTTING_AWAY（前进）', _p03(["UPDATE inbound_order SET status='RECEIVED' WHERE id=3190", "UPDATE inbound_order SET status='PUTTING_AWAY' WHERE id=3190"]))
expect_block_tx('03 created_at 建后不可改', _p03(["UPDATE inbound_order SET created_at='2026-10-14 00:00:00' WHERE id=3190"]), 'inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at')
expect_block_tx('03 库写时间改成 NULL：created_at', _p03(['UPDATE inbound_order SET created_at=NULL WHERE id=3190']), 'inbound_order_time_immutable: 40004 TIME_FIELD_IMMUTABLE created_at')
expect_block_tx('03 库写时间改成 NULL：已关单 closed_at（closed_at 属 (id, closed_at) 唯一键，回填后不可改）', _p03(['UPDATE inbound_order SET closed_at=NULL WHERE id=3100']), 'inbound_order_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE')
expect_block_tx('03 库写时间改成 NULL：更正单 approved_at', _p03(['UPDATE inbound_correction SET approved_at=NULL WHERE id=3220']), 'append_only_violation: inbound_correction')
expect_block_tx('03 created_at 预签 2099', _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00','2099-01-01 00:00:00')"]), 'inbound_temp_check_clock_skew: 40003 CLIENT_TIME_INVALID created_at')
expect_block_tx('03 created_at 倒签 301s', _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00',datetime('now','-301 seconds'))"]), 'inbound_temp_check_clock_skew: 40003 CLIENT_TIME_INVALID created_at')
expect_block_tx("03 created_at 'zzzz'", _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00','zzzz')"]), 'inbound_temp_check_clock_skew: 40003 CLIENT_TIME_INVALID created_at')
allow_rb('03 created_at = now − 299s', _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00',datetime('now','-299 seconds'))"]))
expect_block_tx('03 created_at 带小数秒（容差内）', _p03(["INSERT INTO inbound_temp_check (id,warehouse_id,inbound_id,scope,temp_zone,inbound_line_id,measured_c10,min_c10,max_c10,result,disposition,op_key,measured_by,measured_at,created_at) VALUES (3306,1,3190,'ZONE','CHILLED',NULL,30,0,40,'PASS','ACCEPT','TMP:3190:c1',21,'2026-10-15 01:06:00',datetime('now')||'.5')"]), 'ck_itc_cts')
expect_block_tx('03 日期：work_date 2026-02-30', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3198,'INB-3198',1,'PURCHASE','ERP','PO-3198','CREATED','2026-02-30')"]), 'ck_inb_date')
expect_block_tx('03 日期：work_date 斜杠', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3198,'INB-3198',1,'PURCHASE','ERP','PO-3198','CREATED','2026/10/15')"]), 'ck_inb_date')
expect_block_tx('03 日期：work_date 带时分秒', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3198,'INB-3198',1,'PURCHASE','ERP','PO-3198','CREATED','2026-10-15 00:00:00')"]), 'ck_inb_date')
expect_block_tx('03 日期：work_date 不补零', _p03(["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3198,'INB-3198',1,'PURCHASE','ERP','PO-3198','CREATED','2026-10-5')"]), 'ck_inb_date')
expect_block_tx('03 日期：expiry_date 非 ISO', _p03(["INSERT INTO inbound_line (id,inbound_id,line_no,sku_id,uom,expiry_date) VALUES (3199,3190,3,31,'KG','20261020')"]), 'ck_inbl_date')
expect_block_tx('03 REPLACE：INSERT OR REPLACE 已关单 3100（会重置关单时间 / 状态）', ["INSERT OR REPLACE INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,status,work_date) VALUES (3100,'INB-R',1,'PURCHASE','ERP','PO-R','CREATED','2026-10-15')"], 'inbound_order_duplicate')
expect_block_tx('03 REPLACE：REPLACE INTO 入库行 3191（会把计数清零）', ["REPLACE INTO inbound_line (id,inbound_id,line_no,sku_id,uom) VALUES (3191,3190,1,31,'KG')"], 'inbound_line_duplicate')
expect_block_tx('03 REPLACE：质量反馈 3180', ["INSERT OR REPLACE INTO inbound_quality_feedback (id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,status,disposition,reported_by,found_at) SELECT id,warehouse_id,code,inbound_id,inbound_line_id,lot_id,stage,issue_code,affected_qty_milli,stock_id,hold_id,'OPEN','PENDING',reported_by,found_at FROM inbound_quality_feedback WHERE id=3180"], 'iqf_immutable')


print("--- 03/18 no-replace：每个 PK / UNIQUE 键造冲突行 REPLACE，必须被拒且原行仍在；逐键变异（WHEN 去掉该键）必须变红 ---")
_RPL = json.loads('[{"t": "inbound_order", "trg": "trg_inb_no_replace", "msg": "inbound_order_duplicate", "cols": ["id", "code", "warehouse_id", "order_type", "source_system", "source_order_no", "source_hash", "supplier_id", "status", "work_date", "expected_at", "dock_code", "vehicle_no", "arrived_at", "unload_start_at", "received_at", "closed_at", "supplier_reconciled_at", "remark", "version", "created_at", "updated_at", "created_by"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_order_4", "cols": ["id", "closed_at"], "pred": null, "clause": "(k.id = NEW.id AND k.closed_at = NEW.closed_at)"}, {"name": "sqlite_autoindex_inbound_order_3", "cols": ["source_system", "source_order_no"], "pred": null, "clause": "(k.source_system = NEW.source_system AND k.source_order_no = NEW.source_order_no)"}, {"name": "sqlite_autoindex_inbound_order_2", "cols": ["code"], "pred": null, "clause": "(k.code = NEW.code)"}]}, {"t": "inbound_line", "trg": "trg_inbl_no_replace", "msg": "inbound_line_duplicate", "cols": ["id", "inbound_id", "line_no", "sku_id", "uom", "temp_zone", "ordered_qty_milli", "rejected_qty_milli", "putaway_qty_milli", "lot_id", "production_date", "expiry_date", "cost_amount_fen", "version", "received_qty_milli", "qc_passed_qty_milli", "qc_failed_qty_milli"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_line_3", "cols": ["id", "inbound_id"], "pred": null, "clause": "(k.id = NEW.id AND k.inbound_id = NEW.inbound_id)"}, {"name": "sqlite_autoindex_inbound_line_2", "cols": ["inbound_id", "line_no"], "pred": null, "clause": "(k.inbound_id = NEW.inbound_id AND k.line_no = NEW.line_no)"}]}, {"t": "inbound_temp_check", "trg": "trg_itc_no_replace", "msg": "append_only_violation: inbound_temp_check", "cols": ["id", "warehouse_id", "inbound_id", "scope", "temp_zone", "inbound_line_id", "measured_c10", "min_c10", "max_c10", "result", "disposition", "op_key", "measured_by", "measured_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_temp_check_3", "cols": ["id", "inbound_id", "disposition"], "pred": null, "clause": "(k.id = NEW.id AND k.inbound_id = NEW.inbound_id AND k.disposition = NEW.disposition)"}, {"name": "sqlite_autoindex_inbound_temp_check_2", "cols": ["op_key"], "pred": null, "clause": "(k.op_key = NEW.op_key)"}]}, {"t": "inbound_receipt", "trg": "trg_inb_rec_no_replace", "msg": "append_only_violation: inbound_receipt", "cols": ["id", "warehouse_id", "inbound_id", "inbound_line_id", "op_key", "qty_milli", "stock_id", "hold_id", "movement_biz_no", "lot_id", "temp_zone", "temp_check_id", "temp_check_disp", "offchain_start_at", "offchain_end_at", "offchain_sec", "offchain_limit_sec", "is_offchain_over", "received_by", "received_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_receipt_4", "cols": ["id", "inbound_line_id", "received_by"], "pred": null, "clause": "(k.id = NEW.id AND k.inbound_line_id = NEW.inbound_line_id AND k.received_by = NEW.received_by)"}, {"name": "sqlite_autoindex_inbound_receipt_3", "cols": ["hold_id"], "pred": null, "clause": "(k.hold_id = NEW.hold_id)"}, {"name": "sqlite_autoindex_inbound_receipt_2", "cols": ["op_key"], "pred": null, "clause": "(k.op_key = NEW.op_key)"}]}, {"t": "inbound_correction", "trg": "trg_irc_no_replace", "msg": "append_only_violation: inbound_correction", "cols": ["id", "warehouse_id", "code", "inbound_id", "inbound_line_id", "receipt_id", "received_by", "order_closed_at", "op_key", "direction", "qty_milli", "stock_id", "movement_id", "reason_code", "reason_note", "approval_no", "approval_tier", "requested_by", "requested_at", "supervisor_id", "purchasing_id", "approved_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_correction_4", "cols": ["movement_id"], "pred": null, "clause": "(k.movement_id = NEW.movement_id)"}, {"name": "sqlite_autoindex_inbound_correction_3", "cols": ["op_key"], "pred": null, "clause": "(k.op_key = NEW.op_key)"}, {"name": "sqlite_autoindex_inbound_correction_2", "cols": ["code"], "pred": null, "clause": "(k.code = NEW.code)"}]}, {"t": "inbound_putaway", "trg": "trg_inbp_no_replace", "msg": "append_only_violation: inbound_putaway", "cols": ["id", "warehouse_id", "inbound_id", "inbound_line_id", "receipt_id", "received_by", "putaway_by", "sod_waiver_no", "op_key", "from_stock_id", "to_location_id", "qty_milli", "movement_biz_no", "offchain_sec", "putaway_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_putaway_2", "cols": ["op_key"], "pred": null, "clause": "(k.op_key = NEW.op_key)"}]}, {"t": "inbound_quality_feedback", "trg": "trg_iqf_no_replace", "msg": "iqf_immutable", "cols": ["id", "warehouse_id", "code", "inbound_id", "inbound_line_id", "lot_id", "stage", "issue_code", "affected_qty_milli", "stock_id", "hold_id", "scrap_hold_id", "status", "disposition", "reported_by", "found_at", "closed_by", "closed_at", "remark", "version", "created_at", "updated_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_inbound_quality_feedback_2", "cols": ["code"], "pred": null, "clause": "(k.code = NEW.code)"}]}, {"t": "sku_live_param", "trg": "trg_slp_dup", "msg": "slp_duplicate", "cols": ["sku_id", "weigh_tolerance_bp", "death_rate_threshold_bp", "shrink_tolerance_bp", "version", "updated_by", "updated_at"], "keys": [{"name": "PK", "cols": ["sku_id"], "pred": null, "clause": "(k.sku_id = NEW.sku_id)"}]}, {"t": "live_tank", "trg": "trg_lt_dup", "msg": "lt_duplicate", "cols": ["location_id", "warehouse_id", "sku_id", "water_volume_l", "temp_controlled", "temp_min_c10", "temp_max_c10", "temp_severe_min_c10", "temp_severe_max_c10", "do_min_x100", "do_severe_min_x100", "ph_min_x100", "ph_max_x100", "inspect_interval_min", "status", "version", "updated_at"], "keys": [{"name": "PK", "cols": ["location_id"], "pred": null, "clause": "(k.location_id = NEW.location_id)"}]}, {"t": "live_stock_count", "trg": "trg_lsc_dup", "msg": "lsc_duplicate", "cols": ["stock_id", "location_id", "lot_id", "on_hand_count", "version", "updated_at"], "keys": [{"name": "PK", "cols": ["stock_id"], "pred": null, "clause": "(k.stock_id = NEW.stock_id)"}]}, {"t": "live_count_ledger", "trg": "trg_lcl_dup", "msg": "lcl_duplicate", "cols": ["id", "stock_id", "biz_type", "biz_no", "line_no", "delta_count", "count_before", "count_after", "movement_id", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_live_count_ledger_2", "cols": ["biz_type", "biz_no", "line_no", "stock_id"], "pred": null, "clause": "(k.biz_type = NEW.biz_type AND k.biz_no = NEW.biz_no AND k.line_no = NEW.line_no AND k.stock_id = NEW.stock_id)"}]}, {"t": "live_inspection", "trg": "trg_li_dup", "msg": "li_duplicate", "cols": ["id", "warehouse_id", "location_id", "device_instance_id", "client_op_id", "inspector_id", "inspected_at", "client_occurred_at", "temp_c10", "do_x100", "ph_x100", "result", "consecutive_breach", "is_recheck", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_live_inspection_2", "cols": ["device_instance_id", "client_op_id"], "pred": null, "clause": "(k.device_instance_id = NEW.device_instance_id AND k.client_op_id = NEW.client_op_id)"}]}, {"t": "live_tank_hold", "trg": "trg_lth_dup", "msg": "lth_duplicate", "cols": ["id", "warehouse_id", "location_id", "reason", "trigger_inspection_id", "status", "release_inspection_id", "released_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "uq_lth_active", "cols": ["location_id"], "pred": "status = \'ACTIVE\'", "clause": "(k.location_id = NEW.location_id AND (k.status = \'ACTIVE\') AND (NEW.status = \'ACTIVE\'))"}]}, {"t": "live_weigh", "trg": "trg_lw_dup", "msg": "lw_duplicate", "cols": ["id", "warehouse_id", "task_kind", "task_id", "line_no", "weigh_client_id", "device_instance_id", "scale_id", "reading_source", "location_id", "stock_id", "sku_id", "lot_id", "gross_qty_milli", "tare_qty_milli", "net_qty_milli", "qty_count", "planned_qty_milli", "deviation_bp", "result", "result_code", "movement_id", "weighed_by", "weighed_at", "client_occurred_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "uq_lw_key", "cols": ["task_kind", "task_id", "weigh_client_id"], "pred": "result = \'ACCEPTED\'", "clause": "(k.task_kind = NEW.task_kind AND k.task_id = NEW.task_id AND k.weigh_client_id = NEW.weigh_client_id AND (k.result = \'ACCEPTED\') AND (NEW.result = \'ACCEPTED\'))"}]}, {"t": "live_death", "trg": "trg_ld_dup", "msg": "ld_duplicate", "cols": ["id", "warehouse_id", "location_id", "stock_id", "lot_id", "work_date", "device_instance_id", "client_op_id", "death_count", "death_qty_milli", "day_rate_bp", "approval_no", "movement_id", "deduct_status", "deducted_qty_milli", "exception_key", "scrap_order_id", "reported_by", "reported_at", "client_occurred_at", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_live_death_3", "cols": ["movement_id"], "pred": null, "clause": "(k.movement_id = NEW.movement_id)"}, {"name": "sqlite_autoindex_live_death_2", "cols": ["device_instance_id", "client_op_id"], "pred": null, "clause": "(k.device_instance_id = NEW.device_instance_id AND k.client_op_id = NEW.client_op_id)"}]}, {"t": "live_shrink_settlement", "trg": "trg_lss_dup", "msg": "lss_duplicate", "cols": ["id", "warehouse_id", "location_id", "lot_id", "stock_id", "work_date", "book_qty_milli", "measured_qty_milli", "shrink_qty_milli", "shrink_bp", "tolerance_bp", "outcome", "movement_id", "scrap_order_id", "count_order_id", "created_at"], "keys": [{"name": "PK", "cols": ["id"], "pred": null, "clause": "(k.id = NEW.id)"}, {"name": "sqlite_autoindex_live_shrink_settlement_3", "cols": ["movement_id"], "pred": null, "clause": "(k.movement_id = NEW.movement_id)"}, {"name": "sqlite_autoindex_live_shrink_settlement_2", "cols": ["location_id", "lot_id", "work_date"], "pred": null, "clause": "(k.location_id = NEW.location_id AND k.lot_id = NEW.lot_id AND k.work_date = NEW.work_date)"}]}]')
_RPL_SEED = {("live_tank_hold", "uq_lth_active"): "UPDATE live_tank_hold SET status='ACTIVE', released_at=NULL, release_inspection_id=NULL WHERE rowid=(SELECT min(rowid) FROM live_tank_hold)",
             ("live_shrink_settlement", "sqlite_autoindex_live_shrink_settlement_3"): "UPDATE live_shrink_settlement SET movement_id=(SELECT max(id) FROM stock_movement) WHERE rowid=(SELECT min(rowid) FROM live_shrink_settlement)"}
def _rpl_trg(sp, keys):
    wh = f"EXISTS (SELECT 1 FROM {sp['t']} k WHERE {' OR '.join(x['clause'] for x in keys)})" if keys else "0"
    return f"CREATE TRIGGER {sp['trg']} BEFORE INSERT ON {sp['t']} WHEN {wh} BEGIN SELECT RAISE(ABORT, '{sp['msg']}'); END"
def _rpl_case(sp, k, mode):
    # mode: "schema" 原样 schema（任何拒绝都算，原行必须在）；"first" 把本表 no-replace 重建为最新（SQLite 后建先触发）验报错名；"mut" 同上但 WHEN 去掉本键
    t = sp["t"]; kc = k["cols"]
    conn.execute("SAVEPOINT rpl")
    try:
        _w0 = " AND ".join(f"{c} IS NOT NULL" for c in kc) + (f" AND ({k['pred']})" if k["pred"] else "")
        if (t, k["name"]) in _RPL_SEED and conn.execute(f"SELECT 1 FROM {t} WHERE {_w0} LIMIT 1").fetchone() is None:   # 只在没有样本时临时造（round13 起由 Doro 的种子提供）
            trs = [r[0] for r in conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name=?", (t,))]
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name=?", (t,)).fetchall(): conn.execute(f"DROP TRIGGER {r[0]}")
            conn.execute("PRAGMA ignore_check_constraints = ON"); conn.execute(_RPL_SEED[(t, k["name"])]); conn.execute("PRAGMA ignore_check_constraints = OFF")
            for q in trs: conn.execute(q)
        w = " AND ".join(f"{c} IS NOT NULL" for c in kc) + (f" AND ({k['pred']})" if k["pred"] else "")
        r = conn.execute(f"SELECT rowid, * FROM {t} WHERE {w} LIMIT 1").fetchone()
        if r is None: return None, "无可用原行"
        rid, row = r[0], dict(zip(sp["cols"], r[1:]))
        new = dict(row); note = []
        for k2 in sp["keys"]:
            if k2 is k: continue
            free = [c for c in k2["cols"] if c not in kc]
            if not free: note.append(k2["name"] + " ⊆ 本键"); continue
            c = free[0]; v = new[c]
            new[c] = (v + 7000001) if isinstance(v, int) else (None if v is None else str(v) + "~R")
        if mode == "first":
            conn.execute(f"DROP TRIGGER {sp['trg']}")
            conn.execute(_rpl_trg(sp, sp["keys"]))
        elif mode in ("mut", "never"):
            # 变异：只留守卫（其余触发器全去掉，同 2z3b），守卫 WHEN 去掉本键 / 本键子句加 AND NEW.x = 'NEVER' → REPLACE 必须通过且原行被删
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name=?", (t,)).fetchall(): conn.execute(f"DROP TRIGGER {r[0]}")
            if mode == "mut": conn.execute(_rpl_trg(sp, [x for x in sp["keys"] if x is not k]))
            else: conn.execute(_rpl_trg(sp, [dict(x, clause=x["clause"][:-1] + f" AND NEW.{x['cols'][0]} = 'NEVER')") if x is k else x for x in sp["keys"]]))
        err = ""
        try:
            conn.execute(f"{'REPLACE INTO' if len(kc) % 2 else 'INSERT OR REPLACE INTO'} {t} ({','.join(sp['cols'])}) VALUES ({','.join('?' * len(sp['cols']))})", [new[c] for c in sp["cols"]])
        except sqlite3.DatabaseError as e:
            err = str(e)
        alive = conn.execute(f"SELECT count(*) FROM {t} WHERE rowid = ? AND " + " AND ".join(f"{c} IS ?" for c in sp["cols"]), [rid] + [row[c] for c in sp["cols"]]).fetchone()[0] == 1
    finally:
        conn.execute("ROLLBACK TO rpl"); conn.execute("RELEASE rpl")
    if mode in ("mut", "never"): return (sp["msg"] in err), f"err={err[:60]!r} 原行{'在' if alive else '被删'}"   # False = 变红成立：守卫不再拦（原行被删或只剩约束 / 外键兜底；"去守卫后原行被删"的强证明由 00 §6.10 2z3b 实打负责）
    good = (bool(err) and alive) if mode == "schema" else (sp["msg"] in err and alive)
    return good, f"err={err[:60]!r} 原行{'在' if alive else '被删'}" + (f"（{'; '.join(note)}）" if note else "")
def _rpl_cover(sp, sql, strict=False):
    # 静态覆盖：本表每个 PK / UNIQUE 索引都要在 WHEN 里有一条完整子句（部分索引带 k. 与 NEW. 两侧谓词）
    _eq = lambda c: re.search(rf"\b\w+\.{c}\s*=\s*NEW\.{c}\b", sql) or re.search(rf"\bNEW\.{c}\s*=\s*\w+\.{c}\b", sql)
    return [k["name"] for k in sp["keys"] if k["clause"] not in sql and not (not strict and all(_eq(c) for c in k["cols"]))]
for sp in _RPL:
    t = sp["t"]
    n_idx = sum(1 for r in conn.execute(f"PRAGMA index_list({t})") if r[2]) + (0 if any(r[3] == "pk" for r in conn.execute(f"PRAGMA index_list({t})")) else (1 if any(r[5] for r in conn.execute(f"PRAGMA table_info({t})")) else 0))
    ok(f"03/18 {t}：唯一索引数 {n_idx} = REPLACE 用例数 {len(sp['keys'])}") if n_idx == len(sp["keys"]) else bad(f"03/18 {t}：唯一索引数 {n_idx} ≠ REPLACE 用例数 {len(sp['keys'])}")
    cur = conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (sp["trg"],)).fetchone()[0]
    miss = _rpl_cover(sp, cur)
    ok(f"03/18 {sp['trg']} WHEN 覆盖全部 {len(sp['keys'])} 个键，无 IS NULL 放行子句") if not miss and " IS NULL" not in cur.upper().replace("IS NOT NULL", "") else bad(f"03/18 {sp['trg']} 漏键 {miss}")
    for k in sp["keys"]:
        m = _rpl_cover(sp, _rpl_trg(sp, [x for x in sp["keys"] if x is not k]), True)
        ok(f"03/18 变异（静态）：{sp['trg']} 去掉 {k['name']} → 覆盖断言变红") if m == [k["name"]] else bad(f"03/18 静态变异未变红：{t}.{k['name']} {m}")
for sp in _RPL:
    for k in sp["keys"]:
        lab = f"{sp['t']}.{k['name']}({','.join(k['cols'])}{' WHERE ' + k['pred'] if k['pred'] else ''})"
        g, d = _rpl_case(sp, k, "schema")
        ok(f"03/18 REPLACE 撞 {lab} → 被拒、原行仍在") if g else bad(f"03/18 REPLACE 撞 {lab}：{d}")
        g, d = _rpl_case(sp, k, "first")
        ok(f"03/18 REPLACE 撞 {lab} → {sp['trg']} 报 {sp['msg']}") if g else bad(f"03/18 {sp['trg']} 未按 {lab} 拦：{d}")
        sub = [x["name"] for x in sp["keys"] if x is not k and set(x["cols"]) < set(k["cols"]) and not x["pred"]]
        if sub: ok(f"03/18 {lab} 是 {sub[0]} 的超键（由它兜住；WHEN 仍列出本键，不单独做变异）"); continue
        for _m, _w in (("mut", "WHEN 去掉"), ("never", "子句加 AND NEW.x='NEVER'")):
            g, d = _rpl_case(sp, k, _m)
            ok(f"03/18 变异：{sp['trg']} {_w} {k['name']} → 守卫不再拦（{d}）") if g is False else bad(f"03/18 变异未变红：{lab} {_w}：{d}")


print("--- 03/18 去重键不可改、计数器只增：逐列改 → 拦；逐列变异（触发器去掉该列）→ 变红 ---")
_KL = json.loads('[{"t": "inbound_order", "keys": ["id", "closed_at", "source_system", "source_order_no", "code"], "fill": ["closed_at"], "ctr": ["version"], "types": {"id": "BIGINT", "closed_at": "TIMESTAMP", "source_system": "VARCHAR(24)", "source_order_no": "VARCHAR(64)", "code": "VARCHAR(64)", "version": "BIGINT"}}, {"t": "inbound_line", "keys": ["id", "inbound_id", "line_no"], "fill": [], "ctr": ["received_qty_milli", "rejected_qty_milli", "qc_passed_qty_milli", "qc_failed_qty_milli", "putaway_qty_milli", "version"], "types": {"id": "BIGINT", "inbound_id": "BIGINT", "line_no": "SMALLINT", "received_qty_milli": "BIGINT", "rejected_qty_milli": "BIGINT", "qc_passed_qty_milli": "BIGINT", "qc_failed_qty_milli": "BIGINT", "putaway_qty_milli": "BIGINT", "version": "BIGINT"}}, {"t": "inbound_quality_feedback", "keys": ["id", "code"], "fill": [], "ctr": ["version"], "types": {"id": "BIGINT", "code": "VARCHAR(64)", "version": "BIGINT"}}, {"t": "sku_live_param", "keys": ["sku_id"], "fill": [], "ctr": ["version"], "types": {"sku_id": "BIGINT", "version": "INT"}}, {"t": "live_tank", "keys": ["location_id"], "fill": [], "ctr": ["version"], "types": {"location_id": "BIGINT", "version": "INT"}}, {"t": "live_stock_count", "keys": ["stock_id"], "fill": [], "ctr": ["version"], "types": {"stock_id": "BIGINT", "version": "INT"}}, {"t": "live_tank_hold", "keys": ["id", "location_id"], "fill": [], "ctr": [], "types": {"id": "BIGINT", "location_id": "BIGINT"}}, {"t": "live_death", "keys": ["id", "movement_id", "device_instance_id", "client_op_id"], "fill": ["movement_id"], "ctr": ["deducted_qty_milli"], "types": {"id": "BIGINT", "movement_id": "BIGINT", "device_instance_id": "VARCHAR(64)", "client_op_id": "VARCHAR(64)", "deducted_qty_milli": "BIGINT"}}]')
def _kl_trg(sp, keys, ctr):
    out = []
    if keys: out.append(f"CREATE TRIGGER trg_{sp['t']}_keylock BEFORE UPDATE ON {sp['t']} WHEN " + " OR ".join((f"(OLD.{c} IS NOT NULL AND NEW.{c} IS NOT OLD.{c})" if c in sp["fill"] else f"NEW.{c} IS NOT OLD.{c}") for c in keys) + f" BEGIN SELECT RAISE(ABORT, '{sp['t']}_key_immutable: 40930 reason=DEDUPE_KEY_IMMUTABLE'); END")
    if ctr: out.append(f"CREATE TRIGGER trg_{sp['t']}_monotonic BEFORE UPDATE ON {sp['t']} WHEN " + " OR ".join(f"NEW.{c} < OLD.{c}" for c in ctr) + f" BEGIN SELECT RAISE(ABORT, '{sp['t']}_counter_not_monotonic: 40930 reason=COUNTER_NOT_MONOTONIC'); END")
    return out
def _kl_case(sp, col, kind, mut):
    t = sp["t"]; msg = t + ("_key_immutable: 40930" if kind == "key" else "_counter_not_monotonic: 40930")
    conn.execute("SAVEPOINT kl")
    try:
        for x in ("keylock", "monotonic"):
            if conn.execute("SELECT 1 FROM sqlite_master WHERE name=?", (f"trg_{t}_{x}",)).fetchone(): conn.execute(f"DROP TRIGGER trg_{t}_{x}")
        keys = [c for c in sp["keys"] if not (mut and kind == "key" and c == col)]; ctr = [c for c in sp["ctr"] if not (mut and kind == "ctr" and c == col)]
        for q in _kl_trg(sp, keys, ctr): conn.execute(q)   # 重建为最新：SQLite 后建先触发，用例只测本守卫
        r = conn.execute(f"SELECT rowid, {col} FROM {t} WHERE {col} IS NOT NULL LIMIT 1").fetchone()
        if r is None: return None, "无可用行"
        v = r[1]; nv = (v + 7000001 if isinstance(v, int) else str(v) + "~R") if kind == "key" else v - 1
        err = ""
        try: conn.execute(f"UPDATE {t} SET {col} = ? WHERE rowid = ?", (nv, r[0]))
        except sqlite3.DatabaseError as e: err = str(e)
    finally:
        conn.execute("ROLLBACK TO kl"); conn.execute("RELEASE kl")
    return msg in err, f"err={err[:60]!r}"
for sp in _KL:
    for kind, cols in (("key", sp["keys"]), ("ctr", sp["ctr"])):
        for c in cols:
            lab = f"{sp['t']}.{c}" + ("（去重键）" if kind == "key" else "（计数器 −1）")
            g, d = _kl_case(sp, c, kind, False)
            ok(f"03/18 改 {lab} → 拦") if g else bad(f"03/18 改 {lab} 未拦：{d}")
            g, d = _kl_case(sp, c, kind, True)
            ok(f"03/18 变异：守卫去掉 {lab} → 变红") if g is False else bad(f"03/18 变异未变红：{lab} {d}")
    if "movement_id" in sp["fill"]:
        c = "movement_id"; conn.execute("SAVEPOINT kf")
        try:
            r = conn.execute(f"SELECT rowid FROM {sp['t']} WHERE {c} IS NULL LIMIT 1").fetchone()
            for x in ("keylock", "monotonic"):
                if conn.execute("SELECT 1 FROM sqlite_master WHERE name=?", (f"trg_{sp['t']}_{x}",)).fetchone(): conn.execute(f"DROP TRIGGER trg_{sp['t']}_{x}")
            for q in _kl_trg(sp, sp["keys"], sp["ctr"]): conn.execute(q)
            e = ""
            if r:
                try: conn.execute(f"UPDATE {sp['t']} SET {c} = (SELECT max(id) FROM stock_movement) WHERE rowid = ?", (r[0],))
                except sqlite3.DatabaseError as x: e = str(x)
        finally:
            conn.execute("ROLLBACK TO kf"); conn.execute("RELEASE kf")
        ok(f"03/18 可回填键 {sp['t']}.{c}：NULL → 值不被守卫拦") if r and "_key_immutable" not in e else bad(f"03/18 回填 {sp['t']}.{c}：{'无 NULL 行' if not r else e}")


print("--- 18 实打样本种子（2z3b）---")
def _seed18(desc, sql):
    try:
        n = conn.execute(sql).rowcount; conn.commit()
        ok(f"03/18 2z3b 种子：{desc}（{n} 行）") if n == 1 else bad(f"03/18 2z3b 种子 {desc}：{n} 行")
    except sqlite3.Error as e:
        conn.rollback(); bad(f"03/18 2z3b 种子 {desc}：{e}")
def _cols(t): return [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
def _copy(t, over, where):
    cs = _cols(t); return f"INSERT INTO {t} ({','.join(cs)}) SELECT " + ",".join(over.get(c, c) for c in cs) + f" FROM {t} WHERE {where} ORDER BY id DESC LIMIT 1"
# inbound_receipt：现有收货记录都被更正单 / 上架记录的组合外键 (receipt_id, inbound_line_id, received_by) 引用，REPLACE 删不掉原行（外键兜底），补一条无子行的收货记录（未关单 3190）
_seed18("inbound_receipt 无子行的收货记录", _copy("inbound_receipt", {"id": "(SELECT max(id) + 1 FROM inbound_receipt)", "op_key": "op_key || '-S12'", "hold_id": "(SELECT max(h.id) FROM stock_hold h WHERE h.id NOT IN (SELECT hold_id FROM inbound_receipt WHERE hold_id IS NOT NULL))", "received_at": "datetime('now')", "created_at": "datetime('now')"}, "1=1"))


print("--- 03 / 18 冻结基线：本篇触发器与索引一个都不能少 ---")
_BASE0318 = json.loads('{"03": {"pg_trg": ["trg_0keylock_inbound_line", "trg_0keylock_inbound_order", "trg_0keylock_inbound_quality_feedback", "trg_inb_closed_guard", "trg_inb_created_now", "trg_inb_forward", "trg_inb_time_now", "trg_inbl_closed_guard", "trg_inbl_counter_guard", "trg_inbp_append_only", "trg_inbp_apply", "trg_inbp_created_now", "trg_inbp_no_truncate", "trg_iqf_created_now", "trg_iqf_forward", "trg_iqf_guard", "trg_irc_append_only", "trg_irc_created_now", "trg_irc_guard", "trg_irc_no_truncate", "trg_itc_append_only", "trg_itc_created_now", "trg_itc_no_truncate", "trg_rcp_append_only", "trg_rcp_created_now", "trg_rcp_no_truncate"], "sq_trg": ["trg_inb_closed_del", "trg_inb_closed_tol_ins", "trg_inb_closed_tol_upd", "trg_inb_closed_upd", "trg_inb_created_lock", "trg_inb_created_tol", "trg_inb_forward", "trg_inb_no_replace", "trg_inb_rec_no_replace", "trg_inb_recon_tol", "trg_inb_recon_tol_ins", "trg_inbl_closed_del", "trg_inbl_closed_ins", "trg_inbl_closed_upd", "trg_inbl_no_replace", "trg_inbl_put_ins", "trg_inbl_put_qc", "trg_inbl_put_sum", "trg_inbound_line_keylock", "trg_inbound_line_monotonic", "trg_inbound_order_keylock", "trg_inbound_order_monotonic", "trg_inbound_quality_feedback_keylock", "trg_inbound_quality_feedback_monotonic", "trg_inbp_apply", "trg_inbp_closed", "trg_inbp_created_tol", "trg_inbp_no_delete", "trg_inbp_no_replace", "trg_inbp_no_update", "trg_inbp_over", "trg_iqf_closed_tol", "trg_iqf_closed_tol_ins", "trg_iqf_created_lock", "trg_iqf_created_tol", "trg_iqf_forward", "trg_iqf_guard_upd", "trg_iqf_no_delete", "trg_iqf_no_replace", "trg_iqf_scrap_ins", "trg_iqf_scrap_upd", "trg_irc_before_close", "trg_irc_created_tol", "trg_irc_dual", "trg_irc_movement", "trg_irc_no_delete", "trg_irc_no_replace", "trg_irc_no_update", "trg_irc_not_closed", "trg_irc_now", "trg_irc_reconciled", "trg_irc_tier", "trg_irc_window", "trg_itc_created_tol", "trg_itc_no_delete", "trg_itc_no_replace", "trg_itc_no_update", "trg_rcp_created_tol", "trg_rcp_no_delete", "trg_rcp_no_update"], "idx": ["ix_inb_wh_status", "ix_inbl_sku", "ix_inbp_line", "ix_inbp_rcp", "ix_iqf_line", "ix_iqf_open", "ix_irc_line", "ix_itc_order", "ix_rcp_line"]}, "18": {"pg_trg": ["trg_0keylock_live_death", "trg_0keylock_live_stock_count", "trg_0keylock_live_tank", "trg_0keylock_live_tank_hold", "trg_0keylock_sku_live_param", "trg_lcl_append_only", "trg_lcl_no_truncate", "trg_ld_append_only", "trg_ld_no_truncate", "trg_ld_zclock", "trg_li_append_only", "trg_li_no_truncate", "trg_li_zclock", "trg_lsc_guard", "trg_lsc_no_truncate", "trg_lss_append_only", "trg_lss_no_truncate", "trg_lt_guard", "trg_lt_no_truncate", "trg_lt_type", "trg_lth_guard", "trg_lth_no_truncate", "trg_lth_zclock", "trg_lw_append_only", "trg_lw_no_truncate", "trg_lw_zclock", "trg_slp_guard", "trg_slp_no_truncate"], "sq_trg": ["trg_lcl_del", "trg_lcl_dup", "trg_lcl_upd", "trg_ld_del", "trg_ld_dup", "trg_ld_upd", "trg_ld_zclock", "trg_li_del", "trg_li_dup", "trg_li_upd", "trg_li_zclock", "trg_live_death_keylock", "trg_live_death_monotonic", "trg_live_stock_count_keylock", "trg_live_stock_count_monotonic", "trg_live_tank_hold_keylock", "trg_live_tank_keylock", "trg_live_tank_monotonic", "trg_lsc_del", "trg_lsc_dup", "trg_lsc_upd", "trg_lsc_w_ins", "trg_lsc_w_upd", "trg_lss_del", "trg_lss_dup", "trg_lss_upd", "trg_lt_del", "trg_lt_dup", "trg_lt_type", "trg_lt_upd", "trg_lth_closed", "trg_lth_del", "trg_lth_dup", "trg_lth_ins", "trg_lth_rel", "trg_lth_upd", "trg_lth_zclock", "trg_lth_zclock_ins", "trg_lw_del", "trg_lw_dup", "trg_lw_upd", "trg_lw_zclock", "trg_sku_live_param_keylock", "trg_sku_live_param_monotonic", "trg_slp_del", "trg_slp_dup", "trg_slp_upd"], "idx": ["ix_ld_pending", "ix_ld_tank_day", "ix_li_tank", "uq_lth_active", "uq_lw_key"]}}')
def _base_missing(doc):
    have = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('trigger','index')")}
    return [n for n in _BASE0318[doc]["sq_trg"] + _BASE0318[doc]["idx"] if n not in have]
for _d in ("03", "18"):
    _m = _base_missing(_d)
    ok(f"{_d} 冻结基线：SQLite 触发器 {len(_BASE0318[_d]['sq_trg'])} + 索引 {len(_BASE0318[_d]['idx'])} 全在") if not _m else bad(f"{_d} 冻结基线缺：{_m}")
    for _kind in ("sq_trg", "idx"):
        _n = _BASE0318[_d][_kind][0]; conn.execute("SAVEPOINT fb")
        conn.execute(f"DROP {'TRIGGER' if _kind == 'sq_trg' else 'INDEX'} {_n}"); _m = _base_missing(_d)
        conn.execute("ROLLBACK TO fb"); conn.execute("RELEASE fb")
        ok(f"{_d} 变异：DROP {_n} → 冻结基线断言变红") if _m == [_n] else bad(f"{_d} 冻结基线变异未变红：{_n} {_m}")

# 12 爱弥斯：2z3b 实打 device_reconnect 的 PK 与 uq_drc_id_binding 需要样本行：按合法路径（绑定 PENDING 建单 → 库写 occurred_at 的恢复联网记录）留一条，提交保留。
# 不碰 uq_udb_active 的种子（Doro #2 第十三轮已留），这里用独立设备号 DEV-DRC-SEED。
# 12 的外键（approval_request / sys_user_warehouse / device_reconnect 等的 warehouse_id）把已有仓都挂上了子行，2z3b 实打 warehouse(code) 时去守卫的 REPLACE 会撞外键；留一个无子行的仓做样本
expect_allow_tx("12 种子：留一个无子行的仓 779300 供 2z3b 实打 warehouse(code)", ["INSERT INTO warehouse (id,code,name,cutoff_time) VALUES (779300,'WRP779300','x','20:00')"])
# 12 爱弥斯：sys_role / sys_permission / api_credential 已出 REPLACE_TODO，2z3b 要实打其唯一键：各留一条无子行样本（角色 / 权限点不挂映射，去守卫的 REPLACE 不撞外键）
expect_allow_tx("12 种子：无映射的角色 779300、权限点 779300、接口凭证 779300 供 2z3b 实打", [
    "INSERT INTO sys_role (id,code,name) VALUES (779300,'RP_ROLE_779300','x')",
    "INSERT INTO sys_permission (id,code,name,module) VALUES (779300,'rp.seed.779300','x','12')",
    "INSERT INTO api_credential (id,api_key,secret_encrypted,source_system) VALUES (779300,'RPKEY779300','enc','ERP')"])
expect_allow_tx("12 种子：留一条 device_reconnect 供 2z3b 实打（PK / uq_drc_id_binding）", [
    "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (779300,'DEV-DRC-SEED','PDA',101,1)",
    "INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (779300,1,779300,NULL)"])
print("=== 2z3b 逐唯一键实打 REPLACE（第十二轮：每张受锁表、每个唯一键造一条冲突行，必须被拒且原行还在）===")
def _replace_probe(only=None, sink=None):
    ok_, bad_ = (ok, bad) if sink is None else ((lambda m: sink.append(('ok', m))), (lambda m: sink.append(('bad', m))))
    _, locked, guards, keys = replace_scan(sqlite_ddl)
    tried = 0
    for t in sorted(keys):
        if only and t != only: continue
        if not keys[t]: continue
        if t in REPLACE_ALLOW or t in REPLACE_OK or t in REPLACE_TODO:
            print(f"  · {t}: 表级豁免（{REPLACE_ALLOW.get(t) or REPLACE_OK.get(t) or 'TODO ' + REPLACE_TODO[t]}），不实打"); continue
        cols = [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
        ctype = {r[1]: (r[2] or "").upper() for r in conn.execute(f"PRAGMA table_info({t})")}
        fkcols = {r[3] for r in conn.execute(f"PRAGMA foreign_key_list({t})")}
        trgs = conn.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND tbl_name=?", (t,)).fetchall()
        gnames = [n for n, s in trgs if _is_guard(t, s)]
        others = [n for n, s in trgs if n not in gnames]
        for kname, kc, where in keys[t]:
            if (t, kc) in REPLACE_KEY_ALLOW:
                print(f"  · {t}({','.join(kc)}): 键级豁免（{REPLACE_KEY_ALLOW[(t, kc)]}），不实打"); continue
            if None in kc:
                bad_(f"{t}({kname}): 表达式唯一索引，实打无法造冲突行 → 红"); continue
            if (t, kc) in _HAND:
                (_hs, _ha), _chk = _HAND[(t, kc)][0](), _HAND[(t, kc)][1]
                conn.execute("SAVEPOINT rh")
                try:
                    for n, _s in trgs:
                        if n not in gnames: conn.execute(f"DROP TRIGGER {n}")
                    try: conn.execute(_hs, _ha); _e1 = None
                    except sqlite3.Error as e: _e1 = str(e)
                    _a1 = conn.execute(_chk).fetchone()[0]
                    conn.execute("ROLLBACK TO rh")
                    for n, _s in trgs: conn.execute(f"DROP TRIGGER {n}")
                    try: conn.execute(_hs, _ha); _e2 = None
                    except sqlite3.Error as e: _e2 = str(e)
                    _a2 = conn.execute(_chk).fetchone()[0]
                finally:
                    conn.execute("ROLLBACK TO rh"); conn.execute("RELEASE rh")
                tried += 1
                ok_(f"手写实打 REPLACE {t}({','.join(kc)}) → 被拒（{_e1}），原行还在") if _e1 and _a1 == 1 else bad_(f"手写实打 REPLACE {t}({','.join(kc)}) → {_e1 or '通过'}，原行 {_a1}")
                ok_(f"变异：去掉 {t} 的触发器后手写 REPLACE 通过且原值被覆盖") if not _e2 and _a2 == 0 else bad_(f"变异：{t}({','.join(kc)}) 手写 REPLACE 去触发器后 {_e2 or '通过但原行还在'}（样本无效）")
                continue
            cond = " AND ".join(f"{c} IS NOT NULL" for c in kc) + (f" AND ({where})" if where else "")
            samples = conn.execute(f"SELECT rowid, {', '.join(cols)} FROM {t} WHERE {cond} ORDER BY rowid DESC LIMIT 12").fetchall()
            row = samples[0] if samples else None
            if row is None:
                bad_(f"{t}({','.join(kc)}): verify 跑完库里没有满足{'谓词 ' + where if where else '该键'}的样本行，实打不了 → 补一条种子"); continue
            rid, vals = row[0], dict(zip(cols, row[1:]))
            sub = [oc for _, oc, _w in keys[t] if None not in oc and set(oc) < set(kc)]
            if sub:   # 目标键是别的键的超集：撞它必然先撞子集键，子集键单独实打，这里显式记一笔，不静默跳过
                ok_(f"{t}({','.join(kc)}): 是 ({','.join(sub[0])}) 的超集，由子集键的实打覆盖"); continue
            sql = f"REPLACE INTO {t} ({', '.join(cols)}) VALUES ({', '.join('?' for _ in cols)})"
            still = f"SELECT count(*) FROM {t} WHERE rowid = ? AND " + " AND ".join(f"{c} IS ?" for c in cols)   # 原行 = 每一列都等于原值
            desc = f"{t}({','.join(kc)}{' WHERE ' + where if where else ''})"
            args = None; tries = 0; last = None; anomaly = None
            for row in samples:
                rid, vals = row[0], dict(zip(cols, row[1:]))
                def _cands(c, i):
                    v = vals[c]; out = []
                    if isinstance(v, int): out += [v + 7000000 + i, v + 1, v - 1]
                    elif isinstance(v, str):
                        out += [v[:-1] + ('1' if v[-1:] != '1' else '2'), v[:-1] + ('Z' if v[-1:] != 'Z' else 'Y'), f"{v}#R{i}"]
                        if v[-1:].isdigit(): out.append(v + "9")
                        if c not in kc and _re.fullmatch(r"\d{4}-\d\d-\d\d", v or ""): out.append(conn.execute("SELECT date(?, '-1 day')", (v,)).fetchone()[0])
                    for _id, _sq, ptab, fc, pc, *_r in conn.execute(f"PRAGMA foreign_key_list({t})").fetchall():
                        if fc == c and pc:   # 外键列：取父表里本表还没用过的值
                            out += [r[0] for r in conn.execute(f"SELECT {pc} FROM {ptab} WHERE {pc} IS NOT NULL AND {pc} NOT IN (SELECT {c} FROM {t} WHERE {c} IS NOT NULL) LIMIT 3")]
                    out.append(None)
                    return out
                comp = [(i, [c for c in oc if c not in kc]) for i, (_, oc, _w) in enumerate(keys[t]) if None not in oc and not set(oc) >= set(kc)]
                opts = [[(c, v) for c in free for v in _cands(c, i)] for i, free in comp]
                import itertools as _it
                # 先在"去掉守卫"的保存点里试出一条能真删掉原行的冲突行（证明打到了目标键），再用它实打带守卫的库
                conn.execute("SAVEPOINT rpf")
                for n, _s in trgs: conn.execute(f"DROP TRIGGER {n}")
                for _k, combo in enumerate(_it.product(*opts)):
                    tries += 1
                    if _k >= 120: break
                    new = dict(vals)
                    for c, v in combo: new[c] = v
                    a_ = [new[c] for c in cols]
                    conn.execute("SAVEPOINT rpt")
                    try:
                        conn.execute(sql, a_)
                        gone = conn.execute(still, [rid] + [vals[c] for c in cols]).fetchone()[0] == 0
                        hit = conn.execute(f"SELECT count(*) FROM {t} WHERE " + " AND ".join(f"{c} IS ?" for c in kc) + (f" AND ({where})" if where else ""), [vals[c] for c in kc]).fetchone()[0] == 1
                        if gone and hit: args = a_
                        else: anomaly = f"REPLACE 执行了但原行{'还在' if not gone else '被删、目标键却没留下新行'}"   # 去全部触发器后仍不删原行 = 造样本失败，绝不当通过
                    except sqlite3.Error as e:
                        last = str(e)
                    conn.execute("ROLLBACK TO rpt"); conn.execute("RELEASE rpt")
                    if args or anomaly: break
                conn.execute("ROLLBACK TO rpf"); conn.execute("RELEASE rpf")
                if args or anomaly: break
            tried += 1
            if anomaly:
                bad_(f"{desc}: 造样本失败（{anomaly}）→ 红"); continue
            if args is None:
                bad_(f"{desc}: 造不出能撞到这个键的冲突行（试了 {tries} 种，最后错误 {last}）→ 红"); continue
            conn.execute("SAVEPOINT rp")
            try:
                for n in others: conn.execute(f"DROP TRIGGER {n}")   # 只留守卫：拒绝必须来自 no-REPLACE 触发器
                try:
                    conn.execute(sql, args); err = None
                except sqlite3.Error as e:
                    err = str(e)
                alive = conn.execute(still, [rid] + [vals[c] for c in cols]).fetchone()[0]
                ok_(f"实打 REPLACE {desc} → 被拒（{err}），原行还在") if err and alive == 1 else bad_(f"实打 REPLACE {desc} → {'通过' if not err else '被拒'}，原行{'还在' if alive else '被删'}")
                conn.execute("ROLLBACK TO rp")
                for n in others + gnames: conn.execute(f"DROP TRIGGER {n}")
                try:
                    conn.execute(sql, args); merr = None
                except sqlite3.Error as e:
                    merr = str(e)
                malive = conn.execute(still, [rid] + [vals[c] for c in cols]).fetchone()[0]
                ok_(f"变异：去掉 {t} 的守卫后同一 REPLACE 通过且原行被删（证明冲突行打到了这个键）") if not merr and malive == 0 else bad_(f"变异：{desc} 去掉守卫后 REPLACE {'被拒：' + merr if merr else '通过但原行还在'}（样本没打到这个键）")
            finally:
                conn.execute("ROLLBACK TO rp"); conn.execute("RELEASE rp")
    return tried
_np = _replace_probe()
ok(f"逐唯一键实打共 {_np} 个键（无缺口名单）") if _np else bad("逐唯一键实打 0 个键")
# 第十三轮变异（小玛丽 r12 mut_lw）：trg_lw_dup 业务键分支加 AND NEW.result='NEVER'，静态 x.col=NEW.col 仍全在，实打必须变红
_lw_sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='trg_lw_dup'").fetchone()[0]
assert "(NEW.result = 'ACCEPTED' AND" in _lw_sql
conn.execute("SAVEPOINT lwm")
try:
    conn.execute("DROP TRIGGER trg_lw_dup"); conn.execute(_lw_sql.replace("(NEW.result = 'ACCEPTED' AND", "(NEW.result = 'ACCEPTED' AND NEW.result = 'NEVER' AND"))
    _st = replace_check(conn.execute("SELECT group_concat(sql, ';' || char(10)) || ';' FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'").fetchone()[0], REPLACE_ALLOW)[0]
    _sink = []; _replace_probe(only="live_weigh", sink=_sink)
    _red = [m for k, m in _sink if k == 'bad' and 'task_kind' in m]
    ok(f"变异：trg_lw_dup 加 NEW.result='NEVER' → 实打变红（{_red[0][:80]}）；静态扫描{'仍绿（说明只靠静态不够）' if not any('live_weigh' in e for e in _st) else '也红'}") if _red else bad(f"变异：trg_lw_dup 加 NEW.result='NEVER' 后实打仍绿：{_sink}")
finally:
    conn.execute("ROLLBACK TO lwm"); conn.execute("RELEASE lwm")
print("=== 2g-t. 第 12 篇时间加固（自查 B2/B3）+ fk_udb_approval + device_reconnect + 第 3 篇审批类型（SQLite；时钟 ±300 s，整数秒比较）===")
_H12 = 'a' * 64
def _apr12(i, t, tgt, req, exp='NULL', created=None):
    cols = "id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by,expires_at" + (",created_at" if created else "")
    vals = f"{i},'APR-WHSH01-20261015-{i:06d}','{t}',1,'{tgt}','{i}','{{}}','{_H12}','r',{req},{exp}" + (f",{created}" if created else "")
    return f"INSERT INTO approval_request ({cols}) VALUES ({vals})"
def _block_any12(desc, stmts, wants):
    _fk_guard(desc)
    try:
        _run_tx(stmts); bad(f"{desc} → 未拦截")
    except sqlite3.IntegrityError as e:
        m = str(e); (ok if any(m == w or m.endswith(': ' + w) for w in wants) else bad)(f"{desc} → {m}")
def _mut12(desc, setup, attack):
    """变异：同一事务里先去掉修复（DROP TRIGGER / 换回旧触发器），再打攻击语句；攻击成功 = 修复确实是挡住它的那一道（随后回滚）"""
    conn.execute('BEGIN')
    try:
        for x in setup: conn.execute(x)
        try:
            for x in attack: conn.execute(x)
            ok(f"变异：{desc} → 攻击通过（修复去掉后变红，随后回滚）")
        except sqlite3.DatabaseError as e:
            bad(f"变异没变红：{desc} → 仍被拦 {e}")
    finally:
        conn.execute('ROLLBACK')
def _mut12_nocheck(desc, attack):
    """CHECK 不能单独 DROP：用 PRAGMA ignore_check_constraints 模拟"去掉 CHECK"，攻击后回滚"""
    conn.execute('PRAGMA ignore_check_constraints = ON')
    try:
        _mut12(desc, [], attack)
    finally:
        conn.execute('PRAGMA ignore_check_constraints = OFF')
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (1231,'inbound.receipt.adjust.approve','收货更正审批','03'),(1232,'inbound.sod.waive','收货上架职责分离放宽','03')")
edge_sync("INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1,1231),(1,1232)")
# --- B3-1 审批 created_at / expires_at
expect_block_tx('12 B3-1 审批 created_at 倒填 2000 年', [_apr12(1201, 'POD_CORRECT', 'POD', 201, 'NULL', "'2000-01-01 00:00:00'")], 'approval_request_clock_skew')
expect_block_tx('12 B3-1 审批 created_at 填未来 +1 天', [_apr12(1201, 'POD_CORRECT', 'POD', 201, 'NULL', "datetime('now','+1 days')")], 'approval_request_clock_skew')
_mut12('去掉 trg_apr_clock_ins，created_at=2000 的审批写入成功', ['DROP TRIGGER trg_apr_clock_ins'], [_apr12(1201, 'POD_CORRECT', 'POD', 201, "'2000-01-01 12:00:00'", "'2000-01-01 00:00:00'")])
expect_block_tx('12 B3-1 审批 expires_at=2999（永不过期）', [_apr12(1201, 'POD_CORRECT', 'POD', 201, "'2999-01-01 00:00:00'")], 'ck_apr_ttl')
expect_block_tx('12 B3-1 拣后取消 expires_at = 当前 + 2h + 1s（超类型上限 2h）', [_apr12(1201, 'CANCEL_AFTER_PICK', 'OUTBOUND', 201, "datetime('now','+7201 seconds')")], 'ck_apr_ttl')
expect_block_tx('12 B3-1 expires_at 早于 created_at', [_apr12(1201, 'POD_CORRECT', 'POD', 201, "datetime('now','-1 hours')")], 'ck_apr_ttl')
_mut12_nocheck('去掉 ck_apr_ttl，expires_at=2999 的审批写入成功', [_apr12(1201, 'POD_CORRECT', 'POD', 201, "'2999-01-01 00:00:00'")])
expect_allow_tx('12 B3-1 正向：不传 expires_at，由库补算', [_apr12(1201, 'CANCEL_AFTER_PICK', 'OUTBOUND', 201)])
_r = one("SELECT CAST(strftime('%s', expires_at) AS INTEGER) - CAST(strftime('%s', created_at) AS INTEGER) FROM approval_request WHERE id=1201")
(ok if _r and _r[0] == 7200 else bad)(f"12 B3-1 拣后取消不传 expires_at → 库补 created_at + 2h（{_r}）")
expect_allow_tx('12 §6.8-6 正向：调用方缩短有效期（+60 s）', [_apr12(1202, 'POD_CORRECT', 'POD', 201, "datetime('now','+60 seconds')")])
_block_any12('12 审批 expires_at 事后改成 NULL', ["UPDATE approval_request SET expires_at=NULL WHERE id=1201"], ['approval_final', 'approval_request_expires_null'])
conn.execute('BEGIN'); conn.execute('DROP TRIGGER trg_apr_ttl_fill'); conn.execute(_apr12(1203, 'POD_CORRECT', 'POD', 201))
_r = one('SELECT expires_at FROM approval_request WHERE id=1203'); conn.execute('ROLLBACK')
(ok if _r and _r[0] is None else bad)(f'变异：去掉 trg_apr_ttl_fill，不传 expires_at 的审批留下 NULL（{_r}，随后回滚）')
# --- B2 格式
_block_any12("12 B2 审批 expires_at='2020/01/01'（解析不了）", [_apr12(1203, 'POD_CORRECT', 'POD', 201, "'2020/01/01'")], ['ck_apr_ts', 'ck_apr_ttl'])
_block_any12("12 B2 审批 expires_at 带 T/Z", [_apr12(1203, 'POD_CORRECT', 'POD', 201, "strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hours')")], ['ck_apr_ts', 'ck_apr_ttl'])
_block_any12("12 B2 审批 expires_at 小数秒", [_apr12(1203, 'POD_CORRECT', 'POD', 201, "strftime('%Y-%m-%d %H:%M:%f','now','+1 hours')")], ['ck_apr_ts', 'ck_apr_ttl'])
# --- B2-1 trg_apr_expired fail-closed：绕过 CHECK 硬塞解析不了的 expires_at，审批仍按已过期拒
conn.execute('PRAGMA ignore_check_constraints = ON')
conn.execute(_apr12(1204, 'POD_CORRECT', 'POD', 201, "'2020/01/01'"))
conn.execute(_apr12(1205, 'POD_CORRECT', 'POD', 201, "'expired-long-ago'"))
conn.execute('PRAGMA ignore_check_constraints = OFF')
_APP12 = "UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id="
expect_block_tx("12 B2-1 expires_at='2020/01/01' 的审批（库里已有坏值）不能再批", [_APP12 + '1204'], 'approval_expired')
expect_block_tx("12 B2-1 expires_at='expired-long-ago' 的审批不能再批", [_APP12 + '1205'], 'approval_expired')
_mut12("trg_apr_expired 换回旧写法 COALESCE(datetime(..) <= datetime('now'),0)，'2020/01/01' 的审批被批准", [
    'DROP TRIGGER trg_apr_expired',
    "CREATE TRIGGER trg_apr_expired BEFORE UPDATE ON approval_request WHEN NEW.status IN ('PARTIAL','APPROVED') AND NEW.status <> OLD.status AND COALESCE(datetime(OLD.expires_at) <= datetime('now'), 0) BEGIN SELECT RAISE(ABORT, 'approval_expired'); END",
    'PRAGMA ignore_check_constraints = ON'], [_APP12 + '1204'])
conn.execute('PRAGMA ignore_check_constraints = OFF')
# --- B3-2 审批时间
expect_block_tx("12 B3-2 first_approved_at/decided_at 倒填 1999", ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='1999-01-01 00:00:00', decided_at='1999-01-01 00:00:00' WHERE id=1202"], 'approval_request_clock_skew')
expect_block_tx("12 B3-2 decided_at 填未来 2098", ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at='2098-01-01 00:00:00' WHERE id=1202"], 'approval_request_clock_skew')
expect_block_tx("12 B3-2 驳回 decided_at 差 301 s", ["UPDATE approval_request SET status='REJECTED', decided_at=datetime('now','-301 seconds'), reject_reason='x' WHERE id=1202"], 'approval_request_clock_skew')
_mut12('去掉 trg_apr_clock_upd，审批时间 1999 写入成功', ['DROP TRIGGER trg_apr_clock_upd'], ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at='1999-01-01 00:00:00', decided_at='1999-01-01 00:00:00' WHERE id=1202"])
expect_allow_tx("12 B3-2 正向：审批时间 = now（差 299 s 也收）", ["UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now','-299 seconds'), decided_at=datetime('now') WHERE id=1202"])
# --- 第 3 篇审批类型（00 §6.6.1）
conn.execute(_apr12(1211, 'INBOUND_CORRECTION', 'INBOUND_RECEIPT', 201)); conn.execute(_apr12(1212, 'INBOUND_SOD_WAIVER', 'INBOUND_ORDER', 201))
for _i, _t in ((1211, 'INBOUND_CORRECTION'), (1212, 'INBOUND_SOD_WAIVER')):
    expect_block_tx(f'12 {_t}：质检主管 205 无审批权限点', [f"UPDATE approval_request SET status='APPROVED', first_approver_id=205, first_approver_role='QC_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id={_i}"], 'approval_perm_not_held')
    expect_block_tx(f'12 {_t}：申请人 201 自批', [f"UPDATE approval_request SET status='APPROVED', first_approver_id=201, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id={_i}"], 'ck_apr_sod')
    expect_allow_tx(f'12 {_t} 正向：本仓主管 202 审批', [f"UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id={_i}"])
expect_block_tx('12 审批类型 INBOUND_FOO 不在码表', [_apr12(1213, 'INBOUND_FOO', 'X', 201)], 'ck_apr_type')
# --- B3-4 绑定时间 + fk_udb_approval + user_device_binding_time_immutable
expect_block_tx('12 B3-4 绑定 bound_at 倒填 2000', ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,bound_at) VALUES (1201,'DEV-T1','PDA',101,1,'2000-01-01 00:00:00')"], 'user_device_binding_clock_skew')
_mut12('去掉 trg_udb_clock_ins，bound_at=2000 写入成功', ['DROP TRIGGER trg_udb_clock_ins'], ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,bound_at) VALUES (1201,'DEV-T1','PDA',101,1,'2000-01-01 00:00:00')"])
conn.execute("INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1201,'DEV-T1','PDA',101,1),(1202,'DEV-T2','PDA',101,1)")
expect_block_tx('12 FK：吊销时顺手挂不存在的审批 999999（触发器都放行，只有 fk_udb_approval 能拦）', ["UPDATE user_device_binding SET status='REVOKED', revoked_at=datetime('now'), revoke_reason='LOST', approval_id=999999 WHERE id=1201"], 'FOREIGN KEY constraint failed')
_fk_off_allowed = True
conn.execute('PRAGMA foreign_keys = OFF')
_mut12('关掉外键（等价去掉 fk_udb_approval），挂不存在的审批成功', [], ["UPDATE user_device_binding SET status='REVOKED', revoked_at=datetime('now'), revoke_reason='LOST', approval_id=999999 WHERE id=1201"])
conn.execute('PRAGMA foreign_keys = ON'); _fk_off_allowed = False
expect_block_tx('12 B3-4 吊销 revoked_at 倒填 2000', ["UPDATE user_device_binding SET status='REVOKED', revoked_at='2000-01-01 00:00:00', revoke_reason='LOST' WHERE id=1201"], 'user_device_binding_clock_skew')
conn.execute(_apr12(1221, 'DEVICE_BIND', 'DEVICE_BINDING', 201).replace("'1221','{}'", "'1202','{}'"))
conn.execute("UPDATE approval_request SET status='APPROVED', first_approver_id=202, first_approver_role='WH_SUPERVISOR', first_approved_at=datetime('now'), decided_at=datetime('now') WHERE id=1221")
expect_block_tx('12 B3-4 激活 activated_at 倒填 2000', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=1221, activated_at='2000-01-01 00:00:00' WHERE id=1202"], 'user_device_binding_clock_skew')
_mut12('去掉 trg_udb_clock_upd，activated_at=2000 写入成功', ['DROP TRIGGER trg_udb_clock_upd'], ["UPDATE user_device_binding SET status='ACTIVE', approval_id=1221, activated_at='2000-01-01 00:00:00' WHERE id=1202"])
expect_allow_tx('12 B3-4 正向：激活 activated_at = now', ["UPDATE user_device_binding SET status='ACTIVE', approval_id=1221, activated_at=datetime('now') WHERE id=1202"])
expect_block_tx('12 激活后改 activated_at', ["UPDATE user_device_binding SET activated_at=datetime('now','-10 seconds') WHERE id=1202"], 'user_device_binding_time_immutable')
_mut12('去掉 trg_udb_time_lock，激活后改 activated_at 成功', ['DROP TRIGGER trg_udb_time_lock'], ["UPDATE user_device_binding SET activated_at=datetime('now','-10 seconds') WHERE id=1202"])
# --- B3-3 / B2-2 / B2-3 离线令牌
_OT12 = "INSERT INTO offline_token (id,jti,binding_id,user_id,device_instance_id,warehouse_id,perm_version,issued_at,expires_at) VALUES "
expect_block_tx('12 B3-3 离线令牌 issued_at=2030（未来生效）', [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,'2030-01-01 00:00:00','2030-01-01 12:00:00')"], 'offline_token_clock_skew')
_mut12('去掉 trg_offline_clock_ins，issued_at=2030 写入成功', ['DROP TRIGGER trg_offline_clock_ins'], [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,'2030-01-01 00:00:00','2030-01-01 12:00:00')"])
expect_block_tx("12 B2-2 离线令牌 expires_at='9999/12/31'（解析不了）", [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,datetime('now'),'9999/12/31')"], 'ck_offline_ts')
expect_block_tx("12 B2-3 离线令牌 expires_at 带 T/Z 且比签发早 1h", [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,datetime('now'),strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hours'))"], 'ck_offline_ts')
expect_block_tx('12 B2-2 离线令牌 12h + 1s', [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,datetime('now'),datetime('now','+43201 seconds'))"], 'ck_offline_max_ttl')
_mut12_nocheck('去掉 CHECK，9999/12/31 的离线令牌写入成功', [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,datetime('now'),'9999/12/31')"])
expect_allow_tx('12 离线令牌正向：issued_at=now、12h', [_OT12 + "(1201,'J1201',1202,101,'DEV-T2',1,1,datetime('now'),datetime('now','+12 hours'))"])
expect_block_tx('12 B3-3 吊销 revoked_at 倒填 2000', ["UPDATE offline_token SET revoked_at='2000-01-01 00:00:00' WHERE id=1201"], 'offline_token_clock_skew')
_mut12('去掉 trg_offline_clock_upd，revoked_at=2000 写入成功', ['DROP TRIGGER trg_offline_clock_upd'], ["UPDATE offline_token SET revoked_at='2000-01-01 00:00:00' WHERE id=1201"])
# --- device_reconnect
_DR12 = "INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES "
expect_allow_tx('12 device_reconnect 正向：本绑定 + 本绑定的离线令牌', [_DR12 + "(1201,1,1202,'J1201')"])
expect_allow_tx('12 device_reconnect 正向：没有离线令牌（offline_jti 为空）', [_DR12 + "(1202,1,1202,NULL)"])
_r = one("SELECT abs(CAST(strftime('%s', occurred_at) AS INTEGER) - CAST(strftime('%s','now') AS INTEGER)) <= 5 AND occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' FROM device_reconnect WHERE id=1201")
(ok if _r and _r[0] == 1 else bad)(f"12 device_reconnect occurred_at 由库默认写成 UTC 整秒（{_r}）")
expect_block_tx('12 device_reconnect occurred_at 倒填 2000', ["INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti,occurred_at) VALUES (1203,1,1202,NULL,'2000-01-01 00:00:00')"], 'device_reconnect_clock_skew')
_mut12('去掉 trg_drc_clock，occurred_at=2000 写入成功', ['DROP TRIGGER trg_drc_clock'], ["INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti,occurred_at) VALUES (1203,1,1202,NULL,'2000-01-01 00:00:00')"])
expect_block_tx('12 device_reconnect 用别的绑定的离线令牌 J1', [_DR12 + "(1203,1,1202,'J1')"], 'device_reconnect_binding_mismatch')
expect_block_tx('12 device_reconnect 仓不一致', [_DR12 + "(1203,2,1202,NULL)"], 'device_reconnect_binding_mismatch')
expect_block_tx('12 device_reconnect 绑定不存在', [_DR12 + "(1203,1,999999,NULL)"], 'device_reconnect_binding_mismatch')
_mut12('去掉 trg_drc_guard，用别的绑定的令牌写入成功', ['DROP TRIGGER trg_drc_guard'], [_DR12 + "(1203,1,1202,'J1')"])
expect_block_tx('12 device_reconnect 只追加（UPDATE occurred_at）', ["UPDATE device_reconnect SET occurred_at=datetime('now','-1 hours') WHERE id=1201"], 'append_only_violation: device_reconnect')
expect_block_tx('12 device_reconnect 只追加（DELETE）', ['DELETE FROM device_reconnect WHERE id=1201'], 'append_only_violation: device_reconnect')
expect_block_tx('12 device_reconnect INSERT OR REPLACE 同 id', ["INSERT OR REPLACE INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1201,1,1202,NULL)"], 'device_reconnect_duplicate')
_mut12('去掉 trg_drc_no_update，改 occurred_at 成功', ['DROP TRIGGER trg_drc_no_update'], ["UPDATE device_reconnect SET occurred_at=datetime('now','-1 hours') WHERE id=1201"])
_mut12('去掉 trg_drc_no_replace，REPLACE 覆盖成功', ['DROP TRIGGER trg_drc_no_replace'], ["INSERT OR REPLACE INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1201,1,1202,NULL)"])

print("=== 2g-r. 第 12 篇 no-REPLACE（00 §6.10）：每张表逐个唯一键做 REPLACE，断言被拒且原行仍在；逐键从 WHEN 去掉的变异必须变红 ===")
conn.execute(_apr12(1309, 'POD_CORRECT', 'POD', 201, 'NULL').replace("'1309','{}'", "'1399','{}'"))
expect_block_tx('12 时钟：decided_at 小时 24（24:00:00）', ["UPDATE approval_request SET status='REJECTED', decided_at=date('now') || ' 24:00:00', reject_reason='x' WHERE id=1309"], 'approval_request_clock_skew')
expect_block_tx("12 格式：离线令牌 expires_at 小时 24", [_OT12 + "(1209,'J1209',1202,101,'DEV-T2',1,1,datetime('now'),date('now') || ' 24:00:00')"], 'ck_offline_ts')
_mut12_nocheck("去掉 CHECK（含小时 ≤ 23），expires_at='…24:00:00' 写入成功", [_OT12 + "(1209,'J1209',1202,101,'DEV-T2',1,1,datetime('now'),date('now') || ' 24:00:00')"])
# 专用底数行（不被外键引用，变异下 REPLACE 删得掉）
conn.execute(_apr12(1301, 'POD_CORRECT', 'POD', 201))
conn.execute("INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1301,'DEV-R1','PDA',101,1)")
conn.execute(_OT12 + "(1301,'J1301',1202,101,'DEV-T2',1,1,datetime('now'),datetime('now','+1 hours'))")
conn.execute("INSERT INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1301,1,1202,NULL)")
conn.execute("INSERT INTO sys_user (id,username,password_hash) VALUES (1301,'u1301','x'),(1305,'u1305','x')")   # 1305：不被任何外键引用，专供唯一键 REPLACE 用例（不靠外键挡）
conn.execute("INSERT INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1301,'r',13,1301,1)")
_APRC = "INSERT OR REPLACE INTO approval_request (id,code,approval_type,warehouse_id,target_type,target_id,payload_json,payload_hash,reason,requested_by) VALUES "
_KEYS12 = [
  # 表, 触发器, 报错, 唯一键, REPLACE 语句, 原行存活断言 SQL, 触发器 WHEN 子句（按唯一键）
  ('approval_request', 'trg_apr_no_replace', 'approval_request_duplicate', 'PK id',
   _APRC + f"(1301,'APR-WHSH01-20261015-001302','POD_CORRECT',1,'POD','1302','{{}}','{_H12}','r',201)",
   "SELECT count(*) FROM approval_request WHERE id=1301 AND code='APR-WHSH01-20261015-001301' AND target_id='1301'"),
  ('approval_request', 'trg_apr_no_replace', 'approval_request_duplicate', 'uq_apr_code(code)',
   _APRC + f"(1302,'APR-WHSH01-20261015-001301','POD_CORRECT',1,'POD','1302','{{}}','{_H12}','r',201)",
   "SELECT count(*) FROM approval_request WHERE id=1301 AND code='APR-WHSH01-20261015-001301' AND target_id='1301'"),
  ('approval_request', 'trg_apr_no_replace', 'approval_request_duplicate', "uq_apr_open(approval_type,target_type,target_id) WHERE status IN ('PENDING','PARTIAL')",
   _APRC + f"(1302,'APR-WHSH01-20261015-001302','POD_CORRECT',1,'POD','1301','{{}}','{_H12}','r',201)",
   "SELECT count(*) FROM approval_request WHERE id=1301 AND code='APR-WHSH01-20261015-001301' AND target_id='1301'"),
  ('user_device_binding', 'trg_udb_no_replace', 'user_device_binding_duplicate', 'PK id',
   "INSERT OR REPLACE INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1301,'DEV-R9','PDA',101,1)",
   "SELECT count(*) FROM user_device_binding WHERE id=1301 AND device_instance_id='DEV-R1'"),
  ('user_device_binding', 'trg_udb_no_replace', 'user_device_binding_duplicate', "uq_udb_active(device_instance_id) WHERE status IN ('PENDING','ACTIVE')",
   "INSERT OR REPLACE INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (1302,'DEV-R1','PDA',101,1)",
   "SELECT count(*) FROM user_device_binding WHERE id=1301 AND device_instance_id='DEV-R1'"),
  ('offline_token', 'trg_offline_no_replace', 'offline_token_duplicate', 'PK id',
   _OT12.replace('INSERT INTO', 'INSERT OR REPLACE INTO') + "(1301,'J1309',1202,101,'DEV-T2',1,1,datetime('now'),datetime('now','+1 hours'))",
   "SELECT count(*) FROM offline_token WHERE id=1301 AND jti='J1301'"),
  ('offline_token', 'trg_offline_no_replace', 'offline_token_duplicate', 'uq_offline_jti(jti)',
   _OT12.replace('INSERT INTO', 'INSERT OR REPLACE INTO') + "(1302,'J1301',1202,101,'DEV-T2',1,1,datetime('now'),datetime('now','+1 hours'))",
   "SELECT count(*) FROM offline_token WHERE id=1301 AND jti='J1301'"),
  ('device_reconnect', 'trg_drc_no_replace', 'device_reconnect_duplicate', 'PK id',
   "INSERT OR REPLACE INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1301,1,1301,NULL)",
   "SELECT count(*) FROM device_reconnect WHERE id=1301 AND binding_id=1202 AND offline_jti IS NULL"),
  ('device_reconnect', 'trg_drc_no_replace', 'device_reconnect_duplicate', 'uq_drc_id_binding(id,binding_id)',
   "INSERT OR REPLACE INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1301,1,1202,'J1201')",
   "SELECT count(*) FROM device_reconnect WHERE id=1301 AND binding_id=1202 AND offline_jti IS NULL"),
  ('sys_user', 'trg_user_no_replace', 'sys_user_duplicate', 'PK id',
   "INSERT OR REPLACE INTO sys_user (id,username,password_hash) VALUES (1301,'u1309','x')",
   "SELECT count(*) FROM sys_user WHERE id=1301 AND username='u1301'"),
  ('sys_user', 'trg_user_no_replace', 'sys_user_duplicate', 'uq_user_name(username)',
   "INSERT OR REPLACE INTO sys_user (id,username,password_hash) VALUES (1306,'u1305','x')",
   "SELECT count(*) FROM sys_user WHERE id=1305 AND username='u1305'"),
  ('audit_log', 'trg_audit_no_replace', 'append_only_violation: audit_log', 'PK id',
   "INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1301,'x',13,1309,1)",
   "SELECT count(*) FROM audit_log WHERE id=1301 AND node_seq=1301 AND action='r'"),
  ('audit_log', 'trg_audit_no_replace', 'append_only_violation: audit_log', 'uq_audit_node_seq(node_id,node_seq)',
   "INSERT OR REPLACE INTO audit_log (id,action,node_id,node_seq,warehouse_id) VALUES (1302,'x',13,1301,1)",
   "SELECT count(*) FROM audit_log WHERE id=1301 AND node_seq=1301 AND action='r'"),
]
_PRED12 = {   # 唯一键在守卫 WHEN 里的谓词（原文）；变异 1 = 换成 0（去掉），变异 2 = 追加 AND NEW.<键首列> = 'NEVER'（永不触发）
  ('trg_apr_no_replace', 'PK id'): ['a.id = NEW.id'],
  ('trg_apr_no_replace', 'uq_apr_code(code)'): ['a.code = NEW.code'],
  ('trg_apr_no_replace', "uq_apr_open(approval_type,target_type,target_id) WHERE status IN ('PENDING','PARTIAL')"): ["(NEW.status IN ('PENDING','PARTIAL') AND a.status IN ('PENDING','PARTIAL') AND a.approval_type = NEW.approval_type AND a.target_type = NEW.target_type AND a.target_id = NEW.target_id)"],
  ('trg_udb_no_replace', 'PK id'): ['b.id = NEW.id'],
  ('trg_udb_no_replace', "uq_udb_active(device_instance_id) WHERE status IN ('PENDING','ACTIVE')"): ["(NEW.status IN ('PENDING','ACTIVE') AND b.status IN ('PENDING','ACTIVE') AND b.device_instance_id = NEW.device_instance_id)"],
  ('trg_offline_no_replace', 'PK id'): ['t.id = NEW.id'],
  ('trg_offline_no_replace', 'uq_offline_jti(jti)'): ['t.jti = NEW.jti'],
  # uq_drc_id_binding 是 PK 的超集：同 (id,binding_id) 的冲突行必然也撞 PK，所以这一键的变异把两项一起改（另有断言证明单靠复合项也能拒）
  ('trg_drc_no_replace', 'PK id'): ['WHERE d.id = NEW.id OR'],
  ('trg_drc_no_replace', 'uq_drc_id_binding(id,binding_id)'): ['WHERE d.id = NEW.id OR', '(d.id = NEW.id AND d.binding_id = NEW.binding_id)'],
  ('trg_user_no_replace', 'PK id'): ['u.id = NEW.id'],
  ('trg_user_no_replace', 'uq_user_name(username)'): ['u.username = NEW.username'],
  ('trg_audit_no_replace', 'PK id'): ['a.id = NEW.id'],
  ('trg_audit_no_replace', 'uq_audit_node_seq(node_id,node_seq)'): ['(a.node_id = NEW.node_id AND a.node_seq = NEW.node_seq)'],
  ('trg_sys_role_no_replace', 'PK id'): ['(r.id = NEW.id)'], ('trg_sys_role_no_replace', 'uq_role_code(code)'): ['(r.code = NEW.code)'],
  ('trg_sys_permission_no_replace', 'PK id'): ['(p.id = NEW.id)'], ('trg_sys_permission_no_replace', 'uq_perm_code(code)'): ['(p.code = NEW.code)'],
  ('trg_sys_user_role_no_replace', 'PK(user_id,role_id)'): ['(m.user_id = NEW.user_id AND m.role_id = NEW.role_id)'],
  ('trg_sys_role_perm_no_replace', 'PK(role_id,perm_id)'): ['(m.role_id = NEW.role_id AND m.perm_id = NEW.perm_id)'],
  ('trg_sys_user_warehouse_no_replace', 'PK(user_id,warehouse_id)'): ['(m.user_id = NEW.user_id AND m.warehouse_id = NEW.warehouse_id)'],
  ('trg_api_credential_no_replace', 'PK id'): ['(c.id = NEW.id)'], ('trg_api_credential_no_replace', 'uq_api_key(api_key)'): ['(c.api_key = NEW.api_key)'],
}
def _pmut(p, how):
    if p.startswith('WHERE ') and p.endswith(' OR'):
        core = p[6:-3]
        return 'WHERE 0 OR' if how == 'drop' else f"WHERE ({core} AND NEW.id = 'NEVER') OR"
    col = p.split('NEW.')[1].split()[0].rstrip(')')
    return '0' if how == 'drop' else f"({p} AND NEW.{col} = 'NEVER')"
# 每个唯一键在触发器 WHEN 里的子句（变异时逐个删掉）
# 去重 / 映射类表（不只是有锁定字段的表）：每个唯一键都要 no-REPLACE
conn.execute("INSERT INTO sys_role (id,code,name) VALUES (1301,'R1301','r'),(1305,'R1305','r')")
conn.execute("INSERT INTO sys_permission (id,code,name,module) VALUES (1301,'p.1301','p','12'),(1305,'p.1305','p','12')")
edge_sync("INSERT INTO sys_user_role (user_id,role_id) VALUES (1301,1301)")
edge_sync("INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1301,1301)")
edge_sync("INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1301,1)")
conn.execute("INSERT INTO api_credential (id,api_key,secret_encrypted,source_system) VALUES (1301,'K1301','s','ERP')")
_KEYS12 += [
  ('sys_role', 'trg_sys_role_no_replace', 'sys_role_duplicate', 'PK id', "INSERT OR REPLACE INTO sys_role (id,code,name) VALUES (1301,'R1309','x')", "SELECT count(*) FROM sys_role WHERE id=1301 AND code='R1301' AND name='r'"),
  ('sys_role', 'trg_sys_role_no_replace', 'sys_role_duplicate', 'uq_role_code(code)', "INSERT OR REPLACE INTO sys_role (id,code,name) VALUES (1306,'R1305','x')", "SELECT count(*) FROM sys_role WHERE id=1305 AND code='R1305' AND name='r'"),
  ('sys_permission', 'trg_sys_permission_no_replace', 'sys_permission_duplicate', 'PK id', "INSERT OR REPLACE INTO sys_permission (id,code,name,module) VALUES (1301,'p.1309','x','12')", "SELECT count(*) FROM sys_permission WHERE id=1301 AND code='p.1301' AND name='p'"),
  ('sys_permission', 'trg_sys_permission_no_replace', 'sys_permission_duplicate', 'uq_perm_code(code)', "INSERT OR REPLACE INTO sys_permission (id,code,name,module) VALUES (1306,'p.1305','x','12')", "SELECT count(*) FROM sys_permission WHERE id=1305 AND code='p.1305' AND name='p'"),
  ('sys_user_role', 'trg_sys_user_role_no_replace', 'sys_user_role_duplicate', 'PK(user_id,role_id)', "INSERT OR REPLACE INTO sys_user_role (user_id,role_id) VALUES (1301,1301)", "SELECT count(*) FROM sys_user_role WHERE user_id=1301 AND role_id=1301 AND rowid=" + str(one("SELECT rowid FROM sys_user_role WHERE user_id=1301 AND role_id=1301")[0])),
  ('sys_role_perm', 'trg_sys_role_perm_no_replace', 'sys_role_perm_duplicate', 'PK(role_id,perm_id)', "INSERT OR REPLACE INTO sys_role_perm (role_id,perm_id) VALUES (1301,1301)", "SELECT count(*) FROM sys_role_perm WHERE role_id=1301 AND perm_id=1301 AND rowid=" + str(one("SELECT rowid FROM sys_role_perm WHERE role_id=1301 AND perm_id=1301")[0])),
  ('sys_user_warehouse', 'trg_sys_user_warehouse_no_replace', 'sys_user_warehouse_duplicate', 'PK(user_id,warehouse_id)', "INSERT OR REPLACE INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1301,1)", "SELECT count(*) FROM sys_user_warehouse WHERE user_id=1301 AND warehouse_id=1 AND rowid=" + str(one("SELECT rowid FROM sys_user_warehouse WHERE user_id=1301 AND warehouse_id=1")[0])),
  ('api_credential', 'trg_api_credential_no_replace', 'api_credential_duplicate', 'PK id', "INSERT OR REPLACE INTO api_credential (id,api_key,secret_encrypted,source_system) VALUES (1301,'K1309','x','ERP')", "SELECT count(*) FROM api_credential WHERE id=1301 AND api_key='K1301' AND secret_encrypted='s'"),
  ('api_credential', 'trg_api_credential_no_replace', 'api_credential_duplicate', 'uq_api_key(api_key)', "INSERT OR REPLACE INTO api_credential (id,api_key,secret_encrypted,source_system) VALUES (1302,'K1301','x','ERP')", "SELECT count(*) FROM api_credential WHERE id=1301 AND api_key='K1301' AND secret_encrypted='s'"),
]
_MAP12 = ('sys_user_role', 'sys_role_perm', 'sys_user_warehouse')
class _on_sync12:
    """映射表在边缘只读：它们的唯一键 / 键列用例走同步连接（同一个库文件），用完换回应用连接"""
    def __init__(self, on): self.on = on
    def __enter__(self):
        global conn
        self.c0 = conn
        if self.on: conn = connect_edge_sync()
    def __exit__(self, *a):
        global conn
        if self.on: conn.close()
        conn = self.c0
def _k12_one(_tb, _tg, _msg, _key, _rep, _alive):
    global conn
    _n0 = one(f'SELECT count(*) FROM {_tb}')[0]
    expect_block_tx(f'12 §6.10 {_tb} REPLACE 撞 {_key}', [_rep], _msg)
    _ok = one(_alive)[0] == 1 and one(f'SELECT count(*) FROM {_tb}')[0] == _n0
    (ok if _ok and not conn.execute('PRAGMA foreign_key_check').fetchall() else bad)(f'12 §6.10 {_tb} REPLACE 撞 {_key}：原行仍在、行数不变、foreign_key_check 干净（{_n0}）')
    _sql = one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", _tg)[0]
    _ps = _PRED12[(_tg, _key)]
    if any(_sql.count(p) != 1 for p in _ps):
        bad(f'变异前置：{_tg} 里 {_key} 的谓词不是恰好出现一次 {_ps!r}'); return
    for _how, _hd in (('drop', '从 WHEN 去掉'), ('never', "追加 AND NEW.<列>='NEVER'（守卫永不触发）")):
        _msql = _sql
        for p in _ps: _msql = _msql.replace(p, _pmut(p, _how), 1)
        conn.execute('BEGIN')
        try:
            conn.execute(f'DROP TRIGGER {_tg}'); conn.execute(_msql)
            try:
                conn.execute(_rep); _gone = one(_alive)[0] == 0
                (ok if _gone else bad)(f'变异：{_tg} 的 {_key} {_hd} 后 REPLACE 通过且原行被删（变红，随后回滚）')
            except sqlite3.DatabaseError as e:
                bad(f'变异没变红：{_tg} 的 {_key} {_hd} 后 REPLACE 仍被拦 {e}')
        finally:
            conn.execute('ROLLBACK')
for _row in _KEYS12:
    with _on_sync12(_row[0] in _MAP12):
        _k12_one(*_row)
_sql = one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='trg_drc_no_replace'")[0]
_mut12_alive = None
conn.execute('BEGIN')
try:
    conn.execute('DROP TRIGGER trg_drc_no_replace'); conn.execute(_sql.replace('WHERE d.id = NEW.id OR', 'WHERE 0 OR', 1))
    try:
        conn.execute("INSERT OR REPLACE INTO device_reconnect (id,warehouse_id,binding_id,offline_jti) VALUES (1301,1,1202,'J1201')"); bad('12 §6.10 只留 uq_drc_id_binding 子句：同 (id,binding_id) 的 REPLACE 竟通过')
    except sqlite3.IntegrityError as e:
        (ok if str(e) == 'device_reconnect_duplicate' else bad)(f'12 §6.10 去掉 PK 子句、只留 uq_drc_id_binding 子句：同 (id,binding_id) 的 REPLACE 仍被拒（{e}）')
finally:
    conn.execute('ROLLBACK')
# 唯一键清单自检：12 的表上 sqlite_master 里的唯一索引必须都在上面覆盖到
_have = {(r[0], r[1]) for r in conn.execute("SELECT m.tbl_name, il.name FROM sqlite_master m, pragma_index_list(m.tbl_name) il WHERE m.type='table' AND m.tbl_name IN ('approval_request','user_device_binding','offline_token','device_reconnect','sys_user','audit_log','sys_role','sys_permission','sys_user_role','sys_role_perm','sys_user_warehouse','api_credential') AND il.\"unique\" = 1 AND il.origin <> 'pk'")}
_want = {('device_reconnect','uq_drc_id_binding'),('sys_role','uq_role_code'),('sys_permission','uq_perm_code'),('api_credential','uq_api_key'),('approval_request','uq_apr_code'),('approval_request','uq_apr_open'),('user_device_binding','uq_udb_active'),('offline_token','uq_offline_jti'),('sys_user','uq_user_name'),('audit_log','uq_audit_node_seq')}
_have_n = {(t, n if not n.startswith('sqlite_autoindex') else ('uq_apr_code' if t=='approval_request' else 'uq_offline_jti' if t=='offline_token' else 'uq_user_name' if t=='sys_user' else {'sys_role':'uq_role_code','sys_permission':'uq_perm_code','api_credential':'uq_api_key','device_reconnect':'uq_drc_id_binding'}.get(t, n))) for t, n in _have}
_nuq = one("SELECT count(*) FROM sqlite_master m, pragma_index_list(m.tbl_name) il WHERE m.type='table' AND m.tbl_name IN ('approval_request','user_device_binding','offline_token','device_reconnect','sys_user','audit_log','sys_role','sys_permission','sys_user_role','sys_role_perm','sys_user_warehouse','api_credential') AND il.\"unique\" = 1")[0] + one("SELECT count(*) FROM sqlite_master m WHERE m.type='table' AND m.tbl_name IN ('approval_request','user_device_binding','offline_token','device_reconnect','sys_user','audit_log','sys_role','sys_permission','sys_user_role','sys_role_perm','sys_user_warehouse','api_credential') AND NOT EXISTS (SELECT 1 FROM pragma_index_list(m.tbl_name) il WHERE il.origin='pk')")[0]
(ok if _nuq == len(_KEYS12) == 22 else bad)(f'12 §6.10 12 篇表唯一键（含整数 PK）数 {_nuq} = REPLACE 用例数 {len(_KEYS12)}')
(ok if _have_n == _want else bad)(f'12 §6.10 唯一键清单 = 用例覆盖清单（实测 {sorted(_have_n)}）')

# 键列不可改（每表每键列一条拒绝 + 每表一条变异）
_KL12 = [('sys_user','id=1301',[('id','1399'),('username',"'u1399'")]),
  ('approval_request','id=1301',[('id','1399'),('code',"'APR-X'"),('approval_type',"'DEVICE_BIND'"),('target_type',"'X'"),('target_id',"'9'")]),
  ('user_device_binding','id=1301',[('id','1399'),('device_instance_id',"'DEV-R8'")]),
  ('offline_token','id=1301',[('id','1399'),('jti',"'J1399'")]),
  ('sys_role','id=1301',[('id','1399'),('code',"'R1399'")]), ('sys_permission','id=1301',[('id','1399'),('code',"'p.1399'")]),
  ('sys_user_role','user_id=1301',[('user_id','102'),('role_id','1')]), ('sys_role_perm','role_id=1301',[('role_id','1'),('perm_id','1231')]),
  ('sys_user_warehouse','user_id=1301',[('user_id','102'),('warehouse_id','2')]), ('api_credential','id=1301',[('id','1399'),('api_key',"'K1399'")])]
conn.execute("INSERT INTO sys_user (id,username,password_hash) VALUES (1301,'u1301','x')") if not one("SELECT 1 FROM sys_user WHERE id=1301") else None
def _kl12_one(_tb, _w, _cols):
    global conn
    for _c, _v in _cols:
        expect_block_tx(f'12 键列不可改：{_tb}.{_c}', [f'UPDATE {_tb} SET {_c}={_v} WHERE {_w}'], f'{_tb}_key_immutable')
    _c, _v = _cols[-1]
    _also = {'approval_request': 'trg_apr_final', 'user_device_binding': 'trg_udb_immutable', 'offline_token': 'trg_offline_guard'}.get(_tb)
    _mut12(f'去掉 trg_{_tb}_key_lock' + (f' 与原有守卫 {_also}（两道都挡改键）' if _also else '') + f'，改 {_tb}.{_c} 成功', [f'DROP TRIGGER trg_{_tb}_key_lock'] + ([f'DROP TRIGGER {_also}'] if _also else []), [f'UPDATE {_tb} SET {_c}={_v} WHERE {_w}'])
for _row in _KL12:
    with _on_sync12(_row[0] in _MAP12):
        _kl12_one(*_row)
expect_allow_tx('12 计数器正向：approval_request.version +1', ["UPDATE approval_request SET version=version+1 WHERE id=1301"])
expect_block_tx('12 计数器只增：approval_request.version 回退', ["UPDATE approval_request SET version=version-1 WHERE id=1301"], 'approval_request_version_regress')
_mut12('去掉 trg_apr_version，version 回退成功', ['DROP TRIGGER trg_apr_version'], ["UPDATE approval_request SET version=version-1 WHERE id=1301"])
expect_block_tx('12 计数器只增：sys_user.perm_version 回退', ["UPDATE sys_user SET perm_version=perm_version+1 WHERE id=1301", "UPDATE sys_user SET perm_version=perm_version-1 WHERE id=1301"], 'perm_version_rewind')
expect_block_tx('12 计数器行：DELETE sys_user', ['DELETE FROM sys_user WHERE id=1301'], 'append_only_violation: sys_user')
_mut12('去掉 trg_user_no_delete，删用户成功（1305 不被外键引用）', ['DROP TRIGGER trg_user_no_delete'], ['DELETE FROM sys_user WHERE id=1305'])
print("=== 2g-u. 第 12 篇边缘库权限映射只读（只经同步连接落库）+ 用户停用 ===")
edge_sync(["INSERT INTO sys_permission (id,code,name,module) VALUES (1311,'sys.user.role.grant','授角色','12'),(1312,'sys.user.role.revoke','收角色','12'),(1317,'x.rb.test','x','12')",
           "INSERT INTO sys_role (id,code,name) VALUES (1311,'RB_ADMIN','x'),(1312,'RB_TARGET','x')",
           "INSERT INTO sys_user (id,username,password_hash) VALUES (1311,'rb_admin','x'),(1312,'rb_target','x'),(1313,'rb_noperm','x'),(1314,'rb_admin2','x')",
           "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1311,1311),(1312,1317)",
           "INSERT INTO sys_user_role (user_id,role_id) VALUES (1311,1311),(1312,1312)",
           "INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1312,2)"])
ok("12 同步连接（edge_sync_active()=1）把权限映射落库")
_RO12 = [('sys_user_role', "INSERT INTO sys_user_role (user_id,role_id) VALUES (1313,1312)", "UPDATE sys_user_role SET role_id=1312 WHERE user_id=1311 AND role_id=1311", "DELETE FROM sys_user_role WHERE user_id=1312 AND role_id=1312"),
         ('sys_role_perm', "INSERT INTO sys_role_perm (role_id,perm_id) VALUES (1312,1311)", "UPDATE sys_role_perm SET perm_id=1311 WHERE role_id=1312 AND perm_id=1317", "DELETE FROM sys_role_perm WHERE role_id=1312 AND perm_id=1317"),
         ('sys_user_warehouse', "INSERT INTO sys_user_warehouse (user_id,warehouse_id) VALUES (1313,2)", "UPDATE sys_user_warehouse SET warehouse_id=1 WHERE user_id=1312 AND warehouse_id=2", "DELETE FROM sys_user_warehouse WHERE user_id=1312 AND warehouse_id=2")]
_pv = lambda u: one(f"SELECT perm_version FROM sys_user WHERE id={u}")[0]
for _t, _ins, _upd, _del in _RO12:
    for _op, _sfx, _q in (('INSERT', 'ins', _ins), ('UPDATE', 'upd', _upd), ('DELETE', 'del', _del)):
        expect_block_tx(f'12 边缘应用连接直接 {_op} {_t}', [_q], f'{_t}_edge_read_only')
        _mut12(f'去掉 trg_{_t}_edge_ro_{_sfx}' + ('（映射表只有键列，UPDATE 另有 key_lock 一道，一并去掉）' if _sfx == 'upd' else '') + f'，应用连接直接 {_op} {_t} 成功', [f'DROP TRIGGER trg_{_t}_edge_ro_{_sfx}'] + ([f'DROP TRIGGER trg_{_t}_key_lock'] if _sfx == 'upd' else []), [_q])
# 应用连接打不开同步开关：库里没有可写的开关；应用连接里函数恒为 0；没注册函数的连接失败即关
(ok if one("SELECT edge_sync_active()")[0] == 0 else bad)("12 应用连接 edge_sync_active() = 0（开关只在同步进程的连接上）")
(ok if not one("SELECT count(*) FROM sqlite_master WHERE type='table' AND (name LIKE '%sync%gate%' OR name LIKE '%sync_flag%')")[0] else bad)("12 库里没有可被 SQL 改写的同步开关表")
_bare = sqlite3.connect(dbf); _bare.execute("PRAGMA foreign_keys = ON")
try:
    _bare.execute("DELETE FROM sys_user_role WHERE user_id=1312 AND role_id=1312"); bad("12 未注册函数的连接直接删映射竟然成功"); _bare.rollback()
except sqlite3.OperationalError as e:
    (ok if 'edge_sync_active' in str(e) else bad)(f"12 未注册 edge_sync_active 的连接（如 sqlite3 命令行）写映射失败即关（{e}）")
finally:
    _bare.close()
conn.create_function("edge_sync_active", 0, lambda: 1)
_mut12('应用连接把 edge_sync_active 注册成 1（等价拿到同步开关），直接收角色成功', [], ["DELETE FROM sys_user_role WHERE user_id=1312 AND role_id=1312"])
conn.create_function("edge_sync_active", 0, lambda: 0)
_p0 = _pv(1312)
edge_sync(["DELETE FROM sys_user_role WHERE user_id=1312 AND role_id=1312", "UPDATE sys_user SET perm_version = perm_version + 1 WHERE id=1312"])
(ok if _pv(1312) == _p0 + 1 and not one("SELECT count(*) FROM sys_user_role WHERE user_id=1312 AND role_id=1312")[0] else bad)("12 同步下发收角色 + 中心递增后的 perm_version：边缘照单落库，本地不再额外递增")
# 停用
_p0 = _pv(1314)
expect_allow_tx('12 停用用户 1314', ["UPDATE sys_user SET status='DISABLED' WHERE id=1314"])
(ok if _pv(1314) == _p0 + 1 else bad)(f'12 停用：perm_version 由库 +1（{_p0}→{_pv(1314)}）')
conn.execute('BEGIN'); conn.execute('DROP TRIGGER trg_user_status_bump'); _p0 = _pv(1313)
conn.execute("UPDATE sys_user SET status='DISABLED' WHERE id=1313"); _p1 = _pv(1313); conn.execute('ROLLBACK')
(ok if _p1 == _p0 else bad)(f'变异：去掉 trg_user_status_bump 后停用不递增（{_p0}→{_p1}，随后回滚）')
expect_block_tx('12 登录名不可改', ["UPDATE sys_user SET username='rb_x' WHERE id=1314"], 'sys_user_key_immutable')
expect_block_tx('12 登录名不可复用（停用后同名新用户）', ["INSERT INTO sys_user (id,username,password_hash) VALUES (1319,'rb_admin2','x')"], 'sys_user_duplicate')
expect_block_tx('12 停用用户不能物删', ['DELETE FROM sys_user WHERE id=1314'], 'append_only_violation: sys_user')
# 第 12 篇触发器 / 索引名冻结基线（缺任何一个就红）
_T12 = ('sys_user','sys_role','sys_permission','sys_user_role','sys_role_perm','sys_user_warehouse','api_credential','user_device_binding','offline_token','approval_request','device_reconnect')
_TRG12_BASE = set("api_credential.trg_api_credential_key_lock api_credential.trg_api_credential_no_replace approval_request.trg_approval_request_key_lock approval_request.trg_apr_approver_immutable approval_request.trg_apr_clock_ins approval_request.trg_apr_clock_upd approval_request.trg_apr_code_wh approval_request.trg_apr_expired approval_request.trg_apr_expires_null approval_request.trg_apr_final approval_request.trg_apr_insert approval_request.trg_apr_insert_role approval_request.trg_apr_no_delete approval_request.trg_apr_no_replace approval_request.trg_apr_perm approval_request.trg_apr_role approval_request.trg_apr_scrap_role approval_request.trg_apr_transition approval_request.trg_apr_ttl_fill approval_request.trg_apr_version audit_log.trg_audit_no_delete audit_log.trg_audit_no_replace audit_log.trg_audit_node_required device_reconnect.trg_drc_clock device_reconnect.trg_drc_guard device_reconnect.trg_drc_no_delete device_reconnect.trg_drc_no_replace device_reconnect.trg_drc_no_update offline_token.trg_offline_clock_ins offline_token.trg_offline_clock_upd offline_token.trg_offline_guard offline_token.trg_offline_no_replace offline_token.trg_offline_token_key_lock sys_permission.trg_sys_permission_key_lock sys_permission.trg_sys_permission_no_replace sys_role.trg_sys_role_key_lock sys_role.trg_sys_role_no_replace sys_role_perm.trg_sys_role_perm_edge_ro_del sys_role_perm.trg_sys_role_perm_edge_ro_ins sys_role_perm.trg_sys_role_perm_edge_ro_upd sys_role_perm.trg_sys_role_perm_key_lock sys_role_perm.trg_sys_role_perm_no_replace sys_user.trg_sys_user_key_lock sys_user.trg_user_no_delete sys_user.trg_user_no_replace sys_user.trg_user_perm_ver sys_user.trg_user_status_bump sys_user_role.trg_sys_user_role_edge_ro_del sys_user_role.trg_sys_user_role_edge_ro_ins sys_user_role.trg_sys_user_role_edge_ro_upd sys_user_role.trg_sys_user_role_key_lock sys_user_role.trg_sys_user_role_no_replace sys_user_warehouse.trg_sys_user_warehouse_edge_ro_del sys_user_warehouse.trg_sys_user_warehouse_edge_ro_ins sys_user_warehouse.trg_sys_user_warehouse_edge_ro_upd sys_user_warehouse.trg_sys_user_warehouse_key_lock sys_user_warehouse.trg_sys_user_warehouse_no_replace user_device_binding.trg_udb_activate user_device_binding.trg_udb_clock_ins user_device_binding.trg_udb_clock_upd user_device_binding.trg_udb_immutable user_device_binding.trg_udb_insert user_device_binding.trg_udb_no_delete user_device_binding.trg_udb_no_replace user_device_binding.trg_udb_time_lock user_device_binding.trg_user_device_binding_key_lock".split())
_IDX12_BASE = set("api_credential.sqlite_autoindex_api_credential_1 api_credential.sqlite_autoindex_api_credential_2 approval_request.ix_apr_requester approval_request.ix_apr_wh approval_request.sqlite_autoindex_approval_request_1 approval_request.sqlite_autoindex_approval_request_2 approval_request.uq_apr_open audit_log.uq_audit_node_seq device_reconnect.ix_drc_binding device_reconnect.ix_drc_jti device_reconnect.sqlite_autoindex_device_reconnect_1 device_reconnect.sqlite_autoindex_device_reconnect_2 offline_token.ix_offline_binding offline_token.sqlite_autoindex_offline_token_1 offline_token.sqlite_autoindex_offline_token_2 sys_permission.sqlite_autoindex_sys_permission_1 sys_permission.sqlite_autoindex_sys_permission_2 sys_role.sqlite_autoindex_sys_role_1 sys_role.sqlite_autoindex_sys_role_2 sys_role_perm.sqlite_autoindex_sys_role_perm_1 sys_user.ix_user_openid sys_user.sqlite_autoindex_sys_user_1 sys_user.sqlite_autoindex_sys_user_2 sys_user_role.sqlite_autoindex_sys_user_role_1 sys_user_warehouse.sqlite_autoindex_sys_user_warehouse_1 user_device_binding.ix_udb_user user_device_binding.sqlite_autoindex_user_device_binding_1 user_device_binding.uq_udb_active".split())
def _now12(c):
    q = ",".join("'%s'" % t for t in _T12)
    trg = {f"{r[0]}.{r[1]}" for r in c.execute(f"SELECT tbl_name, name FROM sqlite_master WHERE type='trigger' AND (tbl_name IN ({q}) OR name IN ('trg_audit_node_required','trg_audit_no_replace','trg_audit_no_delete'))")}
    idx = {f"{r[0]}.{r[1]}" for r in c.execute(f"SELECT tbl_name, name FROM sqlite_master WHERE type='index' AND (tbl_name IN ({q}) OR name = 'uq_audit_node_seq')")}
    return trg, idx
_t, _i = _now12(conn)
_miss = (_TRG12_BASE - _t) | (_IDX12_BASE - _i)
(ok if not _miss and len(_TRG12_BASE) > 0 else bad)(f"12 触发器 / 索引冻结基线齐全（{len(_TRG12_BASE)} 触发器、{len(_IDX12_BASE)} 索引）" if not _miss and len(_TRG12_BASE) > 0 else f"12 冻结基线缺 {sorted(_miss)} ｜实测触发器 {' '.join(sorted(_t))} ｜实测索引 {' '.join(sorted(_i))}")
conn.execute('BEGIN'); conn.execute('DROP TRIGGER trg_drc_no_replace'); _t2, _ = _now12(conn); conn.execute('ROLLBACK')
(ok if 'device_reconnect.trg_drc_no_replace' in _TRG12_BASE - _t2 else bad)('变异：删 trg_drc_no_replace 后基线断言能发现缺失')
print("=== 2g-fa. audit_log 外键（actor_id 在 11 建表；approval_id 由 12b ADD COLUMN ... REFERENCES）===")
_fka = [(r[2], r[3], r[4]) for r in conn.execute("PRAGMA foreign_key_list(audit_log)")]
for _p in (("sys_user", "actor_id", "id"), ("approval_request", "approval_id", "id")):
    ok(f"audit_log 外键已声明：{_p[1]} → {_p[0]}") if _p in _fka else bad(f"audit_log 外键缺 {_p}：{_fka}")
expect_block_tx("12 外键：audit_log.approval_id 指向不存在的审批单", ["INSERT INTO audit_log (id,approval_id,action,node_id,node_seq,occurred_at) VALUES (779802,999999,'t12.fk',7,779802,datetime('now'))"], "FOREIGN KEY constraint failed")
expect_block_tx("12 外键：audit_log.actor_id 指向不存在的用户（12 侧复核）", ["INSERT INTO audit_log (id,actor_id,action,node_id,node_seq,occurred_at) VALUES (779801,999999,'t12.fk',7,779801,datetime('now'))"], "FOREIGN KEY constraint failed")
print("=== 2i. 第 1 篇主数据不变量（sell_days / 温区 0.1 ℃ / 水位 milli / 换算 milli / 仓编码 / 时间默认值）===")
# 每条库层不变量都是三件套：正向放行 + 反向按名拦截 + 变异（去掉约束后原被拒语句通过）。两库同一套断言。
def _sku_ins(i, code, temp='CHILLED', shelf=30, sell=10, ppm=0, ship=0):
    sell_s = 'NULL' if sell is None else str(sell)
    return ("INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days,natural_loss_tolerance_ppm) "
            f"VALUES ({i},'{code}','x','KG','{temp}',{shelf},{ship},{sell_s},{ppm})")
_sku_ok = _sku_ins(8011, 'SKU-T-SD')
expect_allow_tx("01 sku.sell_days=10 且 ≤ 保质期 30 天（冷藏）", [_sku_ok])
expect_block_tx("01 sku.sell_days 超保质期（31 > 30）", [_sku_ins(8012, 'SKU-T-SD2', sell=31)], "ck_sku_sell_days")
expect_block_tx("01 sku.sell_days=0（可售天数是正数）", [_sku_ins(8013, 'SKU-T-SD3', sell=0)], "ck_sku_sell_days")
expect_block_tx("01 冷藏 SKU 没有 sell_days（sell_deadline 会永远为空）", [_sku_ins(8014, 'SKU-T-SD4', sell=None)], "ck_sku_sell_days_req")
expect_allow_tx("01 常温 SKU 允许不设 sell_days", [_sku_ins(8015, 'SKU-T-SD5', temp='AMBIENT', sell=None)])
expect_allow_tx("01 损耗容差正好 50000 ppm（5%）", [_sku_ins(8016, 'SKU-T-PPM', ppm=50000)])
expect_block_tx("01 损耗容差 50001 ppm（绕过 09 报损审批）", [_sku_ins(8017, 'SKU-T-PPM2', ppm=50001)], "ck_sku_loss_ppm")
# 镜鉴 I-1（食品安全）：取值域 CHECK —— 大小写 / 尾空格 / 未知值一律拒，别再靠精确匹配的 ck_sku_sell_days_req 兜
expect_allow_tx("01 SKU 温区取值域内 5 个值全放行（AMBIENT / CHILLED / FROZEN / FRESH / LIVE）",
                [_sku_ins(8021, 'SKU-T-T1', temp='AMBIENT', sell=None), _sku_ins(8022, 'SKU-T-T2', temp='CHILLED'),
                 _sku_ins(8023, 'SKU-T-T3', temp='FROZEN'), _sku_ins(8024, 'SKU-T-T4', temp='FRESH', sell=None),
                 _sku_ins(8025, 'SKU-T-T5', temp='LIVE', sell=None)])
for _bad in ('chilled', 'FROZEN ', 'CHILL'):
    expect_block_tx(f"01 SKU 温区绕过值 {_bad!r}（小写 / 尾空格 / 未知值，且不填 sell_days）",
                    [_sku_ins(8030, 'SKU-T-TB', temp=_bad, sell=None)], "ck_sku_temp")
for _bad in ('chilled', 'FROZEN ', 'CHILL'):
    _ttl_mut(f"SKU 温区绕过值 {_bad!r} 被放行", "ck_sku_temp", _sku_ins(8095, 'SKU-MT', temp=_bad, sell=None))
expect_block_tx("01 禁发期 6 天 > 保质期 5 天", [_sku_ins(8018, 'SKU-T-SL', shelf=5, sell=1, ship=6)], "ck_sku_shelf_life")
expect_allow_tx("01 禁发期与收货允收期都等于保质期（放行）",
                ["INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,receive_min_shelf_life,ship_min_shelf_life,sell_days) "
                 "VALUES (8019,'SKU-T-SL2','x','KG','CHILLED',5,5,5,1)"])
_ttl_mut("sell_days 超保质期被放行", "ck_sku_sell_days", _sku_ins(8091, 'SKU-M1', sell=31))
_ttl_mut("冷藏 SKU 缺 sell_days 被放行", "ck_sku_sell_days_req", _sku_ins(8092, 'SKU-M2', sell=None))
_ttl_mut("损耗容差 50001 被放行", "ck_sku_loss_ppm", _sku_ins(8093, 'SKU-M3', ppm=50001))
_ttl_mut("禁发期超保质期被放行", "ck_sku_shelf_life", _sku_ins(8094, 'SKU-M4', shelf=5, sell=1, ship=6))

_zone_ins = ("INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) "
             "VALUES ({i},1,'{c}','x','FROZEN','STORAGE',{lo},{hi})")
expect_allow_tx("01 冷冻区 -18.0 ℃ ~ -15.0 ℃（c10 整数）", [_zone_ins.format(i=8101, c='Z-T1', lo=-180, hi=-150)])
expect_block_tx("01 温区上下限相等（等于没有区间）", [_zone_ins.format(i=8102, c='Z-T2', lo=-150, hi=-150)], "ck_zone_temp")
expect_block_tx("01 温区只给下限不给上限", [_zone_ins.format(i=8103, c='Z-T3', lo=-180, hi='NULL')], "ck_zone_temp")
expect_block_tx("01 温区下限大于上限", [_zone_ins.format(i=8104, c='Z-T4', lo=-150, hi=-180)], "ck_zone_temp")
expect_allow_tx("01 温区两列都为空（不控温库区）", ["INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8105,1,'Z-T5','x','AMBIENT','STAGE')"])
# 镜鉴 I-2：空区间只允许 AMBIENT；控温库区（CHILLED/FROZEN）必须给区间
expect_block_tx("01 控温库区 CHILLED 不给温度区间", ["INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8106,1,'Z-T6','x','CHILLED','STORAGE')"], "ck_zone_temp")
expect_block_tx("01 控温库区 FROZEN 不给温度区间", ["INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8107,1,'Z-T7','x','FROZEN','STORAGE')"], "ck_zone_temp")
expect_block_tx("01 空区间只允许 AMBIENT（FRESH 也不例外）", ["INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8108,1,'Z-T8','x','FRESH','STORAGE')"], "ck_zone_temp")
_ttl_mut("CHILLED 库区不给温度区间被放行", "ck_zone_temp", "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type) VALUES (8094,1,'Z-M2','x','CHILLED','STORAGE')")
_ttl_mut("温区上下限相等被放行", "ck_zone_temp", _zone_ins.format(i=8096, c='Z-M1', lo=-150, hi=-150))

_loc_ins = ("INSERT INTO location (id,warehouse_id,zone_id,code,location_type,min_level_milli,max_level_milli) "
            "VALUES ({i},1,1,'{c}','BIN',{lo},{hi})")
expect_allow_tx("01 补货水位 0 ≤ 下限 ≤ 上限（milli）", [_loc_ins.format(i=8111, c='L-T1', lo=0, hi=100000)])
expect_block_tx("01 补货水位下限 > 上限", [_loc_ins.format(i=8112, c='L-T2', lo=100000, hi=50000)], "ck_loc_level")
expect_block_tx("01 补货水位下限为负", [_loc_ins.format(i=8113, c='L-T3', lo=-1, hi=0)], "ck_loc_level")
_ttl_mut("补货水位下限 > 上限被放行", "ck_loc_level", _loc_ins.format(i=8097, c='L-M1', lo=100000, hi=50000))

_wh_ins = "INSERT INTO warehouse (id,code,name,cutoff_time) VALUES ({i},'{c}','x','20:00')"
expect_allow_tx("01 仓编码 WHSH02（[A-Z0-9]、2–16 位）", [_wh_ins.format(i=8121, c='WHSH02')])
expect_block_tx("01 仓编码含小写字母", [_wh_ins.format(i=8122, c='wh02')], "ck_wh_code")
expect_block_tx("01 仓编码含 '-'（会与审批单号分段冲突）", [_wh_ins.format(i=8123, c='AB-C1')], "ck_wh_code")
expect_block_tx("01 仓编码只有 1 位", [_wh_ins.format(i=8124, c='A')], "ck_wh_code")
expect_block_tx("01 仓编码 17 位", [_wh_ins.format(i=8125, c='ABCDEFGH123456789')], "ck_wh_code")
_ttl_mut("仓编码含小写被放行", "ck_wh_code", _wh_ins.format(i=8098, c='wh02'))

_su_ins = "INSERT INTO sku_unit (id,sku_id,uom,base_qty_milli) VALUES ({i},1,'{u}',{q})"
expect_allow_tx("01 换算系数 1 BOX = 12.500 KG（12500 milli）", [_su_ins.format(i=8131, u='BOX12', q=12500)])
expect_block_tx("01 换算系数为 0", [_su_ins.format(i=8132, u='BOX0', q=0)], "ck_unit_ratio")
expect_block_tx("01 换算系数为负", [_su_ins.format(i=8133, u='BOXN', q=-1)], "ck_unit_ratio")
_ttl_mut("换算系数为 0 被放行", "ck_unit_ratio", _su_ins.format(i=8099, u='BOXM', q=0))

# 旧口径列必须消失、新口径列必须在且是整数列（R2；第 18 篇同 *_c10 口径）
_cols01 = lambda t: [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
_typed01 = lambda t: {r[1]: (r[2] or '').upper() for r in conn.execute(f"PRAGMA table_info({t})")}
_gone01 = {"zone": ("temp_min", "temp_max"), "sku": ("natural_loss_pct",), "location": ("min_level", "max_level"), "sku_unit": ("ratio_to_base",)}
_stale01 = [f"{t}.{c}" for t, cs in _gone01.items() for c in cs if c in _cols01(t)]
ok("01 旧口径列已全部改名（无 " + ", ".join(f"{t}.{c}" for t, cs in _gone01.items() for c in cs) + "）") if not _stale01 else bad(f"01 旧口径列还在：{_stale01}")
_new01 = {"zone": ("temp_min_c10", "temp_max_c10"), "sku": ("sell_days", "natural_loss_tolerance_ppm"),
          "location": ("min_level_milli", "max_level_milli"), "sku_unit": ("base_qty_milli",)}
_miss01 = [f"{t}.{c}" for t, cs in _new01.items() for c in cs if c not in _cols01(t)]
ok("01 新口径列齐全（" + ", ".join(f"{t}.{c}" for t, cs in _new01.items() for c in cs) + "）") if not _miss01 else bad(f"01 缺新口径列：{_miss01}")
_nonint01 = [f"{t}.{c}" for t, cs in _new01.items() for c in cs
             if 'INT' not in _typed01(t).get(c, '')]
ok("01 新口径列都是整数列（SQLite 不会退化成 REAL）") if not _nonint01 else bad(f"01 新口径列不是整数：{_nonint01}")
# 变异：把温区上下限改回 NUMERIC，上面那条整数列扫描必须变红
_mddl01 = sqlite_ddl.replace("temp_min_c10    INTEGER", "temp_min_c10    NUMERIC")
if _mddl01 == sqlite_ddl:
    bad("变异没生效：没找到 temp_min_c10 INTEGER 声明")
else:
    _mc01 = sqlite3.connect(":memory:")
    _mc01.executescript(_mddl01)
    _mtype01 = (dict((r[1], (r[2] or '').upper()) for r in _mc01.execute("PRAGMA table_info(zone)")))['temp_min_c10']
    _mc01.close()
    ok(f"变异：temp_min_c10 改回 NUMERIC 后上面那条整数列扫描会变红（实测类型 {_mtype01}）") if 'INT' not in _mtype01 else bad("变异没变红：temp_min_c10 仍是整数列")

# 00 §6.8 第 3 条：服务端时间由库写 UTC 整秒（SQLite datetime('now') 本身就是整秒 UTC）
_t01 = ("warehouse", "zone", "location", "sku", "lot", "supplier", "customer", "vehicle", "driver", "device")
_bad_ts01 = [f"{t}.{c}" for t in _t01 for c in ("created_at", "updated_at")
             if (dict((r[1], r[4]) for r in conn.execute(f"PRAGMA table_info({t})")).get(c) or "") != "datetime('now')"]
ok("01 的 20 个 created_at / updated_at 默认值都是 datetime('now')（UTC 整秒，00 §6.8）") if not _bad_ts01 else bad(f"01 时间默认值不合规：{_bad_ts01}")

print("=== 2a-01L. 01 增量台账五表（供应商 / 客户 / 车辆 / 司机 / 设备）===")
# 种子已在最前面写入（supplier 8801 / customer 8802 / vehicle 8803 / driver 8804 / device 8805）
expect_allow_tx("01 台账正向：批次挂已存在的供应商（lot.supplier_id 外键）",
                ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,supplier_id) VALUES (8806,1,'LOT-SUP-8806','2026-12-01','2026-10-15',8801)"])
expect_block_tx("01 拒绝：ck_supplier_code 小写编码", ["INSERT INTO supplier (id,code,name) VALUES (8811,'sup001','x')"], "ck_supplier_code")
_ttl_mut("供应商编码小写 sup001", "ck_supplier_code", "INSERT INTO supplier (id,code,name) VALUES (8811,'sup001','x')")
expect_block_tx("01 拒绝：ck_supplier_status 未知状态", ["INSERT INTO supplier (id,code,name,status) VALUES (8812,'SUP002','x','PENDING')"], "ck_supplier_status")
expect_block_tx("01 拒绝：ck_customer_type 未知门店类型", ["INSERT INTO customer (id,code,name,store_type) VALUES (8813,'STORE002','x','KIOSK')"], "ck_customer_type")
expect_block_tx("01 拒绝：ck_vehicle_temp 只给上限（两列必须同空或同填）", ["INSERT INTO vehicle (id,plate_no,vehicle_type,temp_max_c10) VALUES (8814,'沪A99999','REFRIGERATED',40)"], "ck_vehicle_temp")
_ttl_mut("车厢温区只给上限", "ck_vehicle_temp", "INSERT INTO vehicle (id,plate_no,vehicle_type,temp_max_c10) VALUES (8814,'沪A99999','REFRIGERATED',40)")
expect_block_tx("01 拒绝：ck_driver_phone 10 位号码", ["INSERT INTO driver (id,name,phone) VALUES (8815,'李师傅','1380013800')"], "ck_driver_phone")
_ttl_mut("司机手机号 10 位", "ck_driver_phone", "INSERT INTO driver (id,name,phone) VALUES (8815,'李师傅','1380013800')")
expect_block_tx("01 拒绝：ck_device_instance 全空白实例号", ["INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8816,'   ',1)"], "ck_device_instance")
_ttl_mut("设备实例号全空白", "ck_device_instance", "INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8816,'   ',1)")
expect_block_tx("01 拒绝：lot.supplier_id 指向不存在的供应商",
                ["INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,supplier_id) VALUES (8817,1,'LOT-SUP-8817','2026-12-02','2026-10-15',999999)"], "FOREIGN KEY constraint failed")
# 防 REPLACE（00 §6.10）：五张表逐唯一键各一把守卫，这里打两条代表 + 各自变异
expect_block_tx("01 台账 REPLACE：supplier 同 code 换 id",
                ["INSERT INTO supplier (id,code,name) VALUES (8911,'SUPREP','x')",
                 "REPLACE INTO supplier (id,code,name) VALUES (8912,'SUPREP','x')"], "master_duplicate: supplier.code")
_tx_allow("01 变异：去掉 trg_supplier_no_replace_code 后，同 code 换 id 的 REPLACE 通过",
          ["DROP TRIGGER trg_supplier_no_replace_code",
           "INSERT INTO supplier (id,code,name) VALUES (8911,'SUPREP','x')",
           "REPLACE INTO supplier (id,code,name) VALUES (8912,'SUPREP','x')"])
expect_block_tx("01 台账 REPLACE：device 同实例号换 id",
                ["INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8921,'D-REP',1)",
                 "REPLACE INTO device (id,device_instance_id,warehouse_id) VALUES (8922,'D-REP',1)"], "master_duplicate: device.device_instance_id")
_tx_allow("01 变异：去掉 trg_device_no_replace_instance 后，同实例号换 id 的 REPLACE 通过",
          ["DROP TRIGGER trg_device_no_replace_instance",
           "INSERT INTO device (id,device_instance_id,warehouse_id) VALUES (8921,'D-REP',1)",
           "REPLACE INTO device (id,device_instance_id,warehouse_id) VALUES (8922,'D-REP',1)"])

# 镜鉴 I2（覆盖补齐）：台账新约束的三件套补全——新增 CHECK（按名拒绝 + 变异）、5 个唯一键重复、device.warehouse_id 外键
expect_block_tx("01 拒绝：ck_customer_code 小写门店编码", ["INSERT INTO customer (id,code,name) VALUES (8821,'store-x','x')"], "ck_customer_code")
_ttl_mut("门店编码小写 store-x", "ck_customer_code", "INSERT INTO customer (id,code,name) VALUES (8821,'store-x','x')")
expect_block_tx("01 拒绝：ck_customer_status 未知状态", ["INSERT INTO customer (id,code,name,status) VALUES (8822,'STORE003','x','PENDING')"], "ck_customer_status")
expect_block_tx("01 拒绝：ck_vehicle_type 未知车型", ["INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8823,'沪A88888','SHIP')"], "ck_vehicle_type")
expect_block_tx("01 拒绝：ck_vehicle_status 未知状态", ["INSERT INTO vehicle (id,plate_no,vehicle_type,status) VALUES (8824,'沪A88889','VAN','PENDING')"], "ck_vehicle_status")
expect_block_tx("01 拒绝：ck_vehicle_cap 载重为 0", ["INSERT INTO vehicle (id,plate_no,vehicle_type,capacity_kg) VALUES (8825,'沪A88890','VAN',0)"], "ck_vehicle_cap")
_ttl_mut("载重为 0", "ck_vehicle_cap", "INSERT INTO vehicle (id,plate_no,vehicle_type,capacity_kg) VALUES (8825,'沪A88890','VAN',0)")
expect_block_tx("01 拒绝：ck_driver_status 未知状态", ["INSERT INTO driver (id,name,phone,status) VALUES (8826,'王师傅','13900139000','PENDING')"], "ck_driver_status")
expect_block_tx("01 拒绝：ck_device_type 未知设备类型", ["INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8827,'D-PDA-8827','ROBOT',1)"], "ck_device_type")
_ttl_mut("设备类型 ROBOT", "ck_device_type", "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8827,'D-PDA-8827','ROBOT',1)")
expect_block_tx("01 拒绝：ck_device_status 未知状态", ["INSERT INTO device (id,device_instance_id,device_type,status,warehouse_id) VALUES (8828,'D-PDA-8828','PDA','PENDING',1)"], "ck_device_status")
expect_block_tx("01 拒绝：ck_device_seen 心跳早于建档", ["INSERT INTO device (id,device_instance_id,device_type,warehouse_id,created_at,last_seen_at) VALUES (8829,'D-PDA-8829','PDA',1,'2026-10-15 10:00:00','2026-10-15 09:00:00')"], "ck_device_seen")
_ttl_mut("心跳早于建档", "ck_device_seen", "INSERT INTO device (id,device_instance_id,device_type,warehouse_id,created_at,last_seen_at) VALUES (8829,'D-PDA-8829','PDA',1,'2026-10-15 10:00:00','2026-10-15 09:00:00')")
expect_block_tx("01 拒绝：device.warehouse_id 挂不存在的仓", ["INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8830,'D-PDA-8830','PDA',999999)"], "FOREIGN KEY constraint failed")
expect_block_tx("01 拒绝：uq_supplier_code 编码重复（守卫先命中）", ["INSERT INTO supplier (id,code,name) VALUES (8831,'SUP001','重复编码')"], "master_duplicate: supplier.code")
expect_block_tx("01 拒绝：uq_customer_code 门店编码重复（守卫先命中）", ["INSERT INTO customer (id,code,name) VALUES (8832,'STORE001','重复门店')"], "master_duplicate: customer.code")
expect_block_tx("01 拒绝：uq_vehicle_plate 车牌重复（守卫先命中）", ["INSERT INTO vehicle (id,plate_no,vehicle_type) VALUES (8833,'沪A12345','VAN')"], "master_duplicate: vehicle.plate_no")
expect_block_tx("01 拒绝：uq_driver_phone 手机号重复（守卫先命中）", ["INSERT INTO driver (id,name,phone) VALUES (8834,'赵师傅','13800138000')"], "master_duplicate: driver.phone")
expect_block_tx("01 拒绝：uq_device_instance 实例号重复（守卫先命中）", ["INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8835,'D-PDA-8805','PDA',1)"], "master_duplicate: device.device_instance_id")
_idx01 = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_lot_supplier'").fetchone()[0]
ok("01 目录断言：ix_lot_supplier（lot.supplier_id 外键列索引）存在（1）") if _idx01 == 1 else bad(f"01 ix_lot_supplier 缺：{_idx01}")

print("=== 2a-FK. 跨篇 FK 收口（03 supplier / 10 supplier / 04 customer+driver / 12b device，共 5 条命名外键）===")
expect_block_tx("跨篇 FK：inbound_order.supplier_id 指向不存在的供应商",
                ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8901,'INB-FK1',1,'PURCHASE','ERP','PO-FK1','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',999999,'RECEIVING','2026-10-15')"], "FOREIGN KEY constraint failed")
expect_allow_tx("跨篇 FK 正向：inbound_order.supplier_id = 501（父行在种子里）",
                ["INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8902,'INB-FK2',1,'PURCHASE','ERP','PO-FK2','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',501,'RECEIVING','2026-10-15')"])
expect_block_tx("跨篇 FK：supplier_return.supplier_id 指向不存在的供应商",
                ["INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8903,'SRN-8903',1,999999,14,1,1,5000,'SLOW_MOVING','CT-FK',0,'DISCOUNT','FRESH',datetime('now'),NULL,31)"], "FOREIGN KEY constraint failed")
expect_block_tx("跨篇 FK：outbound_order.customer_id 指向不存在的客户",
                ["INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8904,'OBT-FK1',1,'SALE','MALL','M-FK1','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',999999,'CREATED','2026-10-16')"], "FOREIGN KEY constraint failed")
expect_block_tx("跨篇 FK：outbound_order.driver_id 指向不存在的司机",
                ["INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8905,'OBT-FK2',1,'SALE','MALL','M-FK2','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,999999,'CREATED','2026-10-16')"], "FOREIGN KEY constraint failed")
expect_block_tx("跨篇 FK：user_device_binding.device_id 指向不存在的设备",
                ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8906,'DEV-FK1','PDA',101,1,999999)"], "FOREIGN KEY constraint failed")
expect_allow_tx("跨篇 FK 正向：user_device_binding.device_id 指向同批新建的设备",
                ["INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (8907,'D-FK-8907','PDA',1)",
                 "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8908,'DEV-FK2','PDA',101,1,8907)"])
expect_allow_tx("跨篇 FK 正向：user_device_binding.device_id = NULL（司机自有手机，设备列可空）",
                ["INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id) VALUES (8916,'D-FK-8916','PDA',101,1)"])
# 镜鉴 r65 重要 I1：本笔 5 条命名外键补齐**第三件（变异）**，并配「删父行被拦 / 去掉外键后删父行通过」。
# 变异 = 临时关掉外键（等价 DROP 掉该 FK，与 05/16 段同口径）后再执行原被拒语句；通过 = 证明拦它的确实是外键。
# 删父行断言的父行一律在本事务内自建（9501–9504），保证事务里只有本事务这一条子行 → 断言不抖。
def _fk_mut(desc: str, stmts: list[str]) -> None:
    global _fk_off_allowed
    _what = "删父行通过" if stmts[-1].startswith("DELETE") else "原被拒语句通过"
    _fk_off_allowed = True; conn.execute("PRAGMA foreign_keys = OFF")
    try:
        expect_allow_tx(f"跨篇 FK 变异：去掉 {desc} 后，{_what}（随后回滚）", stmts)
    finally:
        _fk_off_allowed = False; conn.execute("PRAGMA foreign_keys = ON")
_FKH = "a" * 64
_FK_X_INB = f"INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8901,'INB-FK1',1,'PURCHASE','ERP','PO-FK1','{_FKH}',999999,'RECEIVING','2026-10-15')"
_FK_X_SRTN = "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8903,'SRN-8903',1,999999,14,1,1,5000,'SLOW_MOVING','CT-FK',0,'DISCOUNT','FRESH',datetime('now'),NULL,31)"
_FK_X_OBO_C = f"INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8904,'OBT-FK1',1,'SALE','MALL','M-FK1','{_FKH}',999999,'CREATED','2026-10-16')"
_FK_X_OBO_D = f"INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8905,'OBT-FK2',1,'SALE','MALL','M-FK2','{_FKH}',1,999999,'CREATED','2026-10-16')"
_FK_X_UDB = "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8906,'D-FK-8906','PDA',101,1,999999)"
_FK_P_SUP = "INSERT INTO supplier (id,code,name) VALUES (9501,'SUP9501','变异用父行')"
_FK_P_CUS = "INSERT INTO customer (id,code,name) VALUES (9502,'STORE9502','变异用门店')"
_FK_P_DRV = "INSERT INTO driver (id,name,phone) VALUES (9503,'变异司机','13900139001')"
_FK_P_DEV = "INSERT INTO device (id,device_instance_id,device_type,warehouse_id) VALUES (9504,'D-FK-9504','PDA',1)"
_FK_C_INB = f"INSERT INTO inbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,supplier_id,status,work_date) VALUES (8911,'INB-FK3',1,'PURCHASE','ERP','PO-FK3','{_FKH}',9501,'RECEIVING','2026-10-15')"
_FK_C_SRTN = "INSERT INTO supplier_return (id,code,warehouse_id,supplier_id,stock_id,sku_id,lot_id,qty_milli,reason_code,contract_ref,food_safety,disposition,temp_class,ready_at,pickup_deadline_at,created_by) VALUES (8912,'SRN-8912',1,9501,14,1,1,5000,'SLOW_MOVING','CT-FK',0,'DISCOUNT','FRESH',datetime('now'),NULL,31)"
_FK_C_OBO_C = f"INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (8913,'OBT-FK3',1,'SALE','MALL','M-FK3','{_FKH}',9502,'CREATED','2026-10-16')"
_FK_C_OBO_D = f"INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,driver_id,status,work_date) VALUES (8914,'OBT-FK4',1,'SALE','MALL','M-FK4','{_FKH}',9502,9503,'CREATED','2026-10-16')"
_FK_C_UDB = "INSERT INTO user_device_binding (id,device_instance_id,client_type,user_id,warehouse_id,device_id) VALUES (8915,'D-FK-9504','PDA',101,1,9504)"
_fk_mut("fk_inb_supplier", [_FK_X_INB])
_fk_mut("fk_srtn_supplier", [_FK_X_SRTN])
_fk_mut("fk_obo_customer", [_FK_X_OBO_C])
_fk_mut("fk_obo_driver", [_FK_X_OBO_D])
_fk_mut("fk_udb_device", [_FK_X_UDB])
expect_block_tx("跨篇 FK：删被 inbound_order 引用的供应商被拦", [_FK_P_SUP, _FK_C_INB, "DELETE FROM supplier WHERE id=9501"], "FOREIGN KEY constraint failed")
_fk_mut("fk_inb_supplier", [_FK_P_SUP, _FK_C_INB, "DELETE FROM supplier WHERE id=9501"])
expect_block_tx("跨篇 FK：删被 supplier_return 引用的供应商被拦", [_FK_P_SUP, _FK_C_SRTN, "DELETE FROM supplier WHERE id=9501"], "FOREIGN KEY constraint failed")
_fk_mut("fk_srtn_supplier", [_FK_P_SUP, _FK_C_SRTN, "DELETE FROM supplier WHERE id=9501"])
expect_block_tx("跨篇 FK：删被 outbound_order 引用的门店被拦", [_FK_P_CUS, _FK_C_OBO_C, "DELETE FROM customer WHERE id=9502"], "FOREIGN KEY constraint failed")
_fk_mut("fk_obo_customer", [_FK_P_CUS, _FK_C_OBO_C, "DELETE FROM customer WHERE id=9502"])
expect_block_tx("跨篇 FK：删被 outbound_order 引用的司机被拦", [_FK_P_CUS, _FK_P_DRV, _FK_C_OBO_D, "DELETE FROM driver WHERE id=9503"], "FOREIGN KEY constraint failed")
_fk_mut("fk_obo_driver", [_FK_P_CUS, _FK_P_DRV, _FK_C_OBO_D, "DELETE FROM driver WHERE id=9503"])
expect_block_tx("跨篇 FK：删被 user_device_binding 引用的设备被拦", [_FK_P_DEV, _FK_C_UDB, "DELETE FROM device WHERE id=9504"], "FOREIGN KEY constraint failed")
_fk_mut("fk_udb_device", [_FK_P_DEV, _FK_C_UDB, "DELETE FROM device WHERE id=9504"])

print("=== 2j. 第 7 篇补货与移库（任务 / 任务行 / 需求 / 移库 / 候选视图）===")
# 种子已在最前面写入（replenish_task 701/702、replenish_task_line 7101、replenish_demand 7201、
# move_order 7301/7302、move_order_line 7311）。下面每条都是「正向放行 + 反向按名拦截 + 变异」，
# 一律用 _tx_allow / _tx_block（内部 BEGIN…ROLLBACK），断言之间不互相污染状态。
_TL = ("INSERT INTO replenish_task_line (id,task_id,seq,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,planned_qty_milli,uom) "
       "VALUES ({i},701,{seq},{frm},{to},1,3,13,{q},'KG')")
_tx_allow("07 补货任务行正向：源 3 → 目标 1（拣货位），计划 5 KG", [_TL.format(i=7151, seq=2, frm=3, to=1, q=5000)])
_tx_block("07 补货任务行：源位 = 目标位", [_TL.format(i=7152, seq=3, frm=1, to=1, q=5000)], "ck_rtl_route")
_tx_block("07 补货任务行：计划量为 0", [_TL.format(i=7153, seq=4, frm=3, to=1, q=0)], "ck_rtl_qty")
_tx_block("07 补货任务行：DONE 但没有流水号与时间", ["UPDATE replenish_task_line SET status='DONE' WHERE id=7101"], "ck_rtl_done")
_tx_block("07 补货任务行：ABNORMAL 但没有原因", ["UPDATE replenish_task_line SET status='ABNORMAL' WHERE id=7101"], "ck_rtl_abnormal")
_tx_allow("07 补货任务行正向：ABNORMAL 带原因", ["UPDATE replenish_task_line SET status='ABNORMAL', abnormal_reason='SOURCE_SHORT' WHERE id=7101"])
_tx_block("07 补货任务：只填 assigned_to 不填 claimed_at", ["UPDATE replenish_task SET assigned_to=21 WHERE id=701"], "ck_rt_claim")
_tx_block("07 补货任务：done_count 超过 line_count", ["UPDATE replenish_task SET done_count=2 WHERE id=701"], "ck_rt_count")
_tx_block("07 补货任务只前进：EXECUTING 已领再退回 PENDING", ["UPDATE replenish_task SET status='EXECUTING', assigned_to=21, claimed_at=datetime('now') WHERE id=701",
                                              "UPDATE replenish_task SET status='PENDING' WHERE id=701"], "replenish_task_forward_only")
_tx_allow("07 变异：去掉 trg_rt_forward 后，EXECUTING 退回 PENDING 通过", ["DROP TRIGGER trg_rt_forward",
                                              "UPDATE replenish_task SET status='EXECUTING', assigned_to=21, claimed_at=datetime('now') WHERE id=701",
                                              "UPDATE replenish_task SET status='PENDING' WHERE id=701"])
_tx_block("07 补货行 DONE 后改计划量（历史账被改）", ["UPDATE replenish_task_line SET status='DONE', movement_biz_no='RPL-20261015-000001:1:D1', moved_at=datetime('now') WHERE id=7101",
                                              "UPDATE replenish_task_line SET planned_qty_milli=99999 WHERE id=7101"], "replenish_line_done_locked")
# 变异要连 SQLite 侧的第二个守卫一起拆：DONE 锁是独立触发器 trg_rtl_done_lock（SQLite 一个触发器只能一个 WHEN，
# 因此「状态只前进」与「DONE 锁路由/数量」拆成两个），只拆 trg_rtl_forward 的话仍被 done_lock 拦住。
_tx_allow("07 变异：去掉 trg_rtl_forward + trg_rtl_done_lock 后，DONE 行改计划量通过", ["DROP TRIGGER trg_rtl_forward",
                                              "DROP TRIGGER trg_rtl_done_lock",
                                              "UPDATE replenish_task_line SET status='DONE', movement_biz_no='RPL-20261015-000001:1:D1', moved_at=datetime('now') WHERE id=7101",
                                              "UPDATE replenish_task_line SET planned_qty_milli=99999 WHERE id=7101"])
_RPD = ("INSERT INTO replenish_demand (id,code,warehouse_id,work_date,cause,target_location_id,sku_id,demand_qty_milli,"
        "source_outbound_id,source_outbound_line_id,source_alloc_round,status) VALUES "
        "({i},'{c}',1,'2026-10-15','{cause}',1,1,{q},{oid},{olid},{rnd},'{st}')")
_tx_block("07 需求：OUTBOUND_SHORTAGE 但缺出库行与轮次",
          [_RPD.format(i=7211, c='RPD-T1', cause='OUTBOUND_SHORTAGE', q=1000, oid='NULL', olid='NULL', rnd='NULL', st='OPEN')], "ck_rpd_short")
_tx_block("07 需求：LOW_LEVEL 却带了出库行与轮次",
          [_RPD.format(i=7212, c='RPD-T2', cause='LOW_LEVEL', q=1000, oid=1, olid=9, rnd=1, st='OPEN')], "ck_rpd_short")
_tx_block("07 需求：DONE 但已满足量 < 需求量", ["UPDATE replenish_demand SET status='DONE' WHERE id=7201"], "ck_rpd_done")
_tx_block("07 需求：只挂 task_id 不挂 task_line_id", ["UPDATE replenish_demand SET task_id=701 WHERE id=7201"], "ck_rpd_task")
_tx_block("07 需求：planned 超过 demand", ["UPDATE replenish_demand SET planned_qty_milli=30000 WHERE id=7201"], "ck_rpd_qty")
_tx_block("07 闭环守卫：同一出库行同一轮次第二条未完结需求",
          [_RPD.format(i=7213, c='RPD-T3', cause='OUTBOUND_SHORTAGE', q=1000, oid=1, olid=1, rnd=1, st='OPEN')],
          "replenish_demand_duplicate: replenish_demand.source_outbound_line_id, replenish_demand.source_alloc_round")
_tx_allow("07 闭环守卫正向：同轮次第一条 CANCELLED 后可以再建", ["UPDATE replenish_demand SET status='CANCELLED', cancelled_reason='DOC_CANCELLED' WHERE id=7201",
                _RPD.format(i=7214, c='RPD-T4', cause='OUTBOUND_SHORTAGE', q=1000, oid=1, olid=1, rnd=1, st='OPEN')])
_tx_allow("07 闭环守卫正向：新一轮 alloc_round 可以再建（04 重分配后）",
          [_RPD.format(i=7215, c='RPD-T5', cause='OUTBOUND_SHORTAGE', q=1000, oid=1, olid=1, rnd=2, st='OPEN')])
_tx_block("07 变异：去掉 trg_rpd_no_replace_open 后，同键第二条被部分唯一索引兜住",
          ["DROP TRIGGER trg_rpd_no_replace_open",
           _RPD.format(i=7216, c='RPD-T6', cause='OUTBOUND_SHORTAGE', q=1000, oid=1, olid=1, rnd=1, st='OPEN'),
           _RPD.format(i=7217, c='RPD-T7', cause='OUTBOUND_SHORTAGE', q=1000, oid=1, olid=1, rnd=1, st='OPEN')],
          "UNIQUE constraint failed: replenish_demand.source_outbound_line_id")
_tx_block("07 需求只前进：DONE 再回 OPEN", ["UPDATE replenish_demand SET status='DONE', fulfilled_qty_milli=20000 WHERE id=7201",
                                     "UPDATE replenish_demand SET status='OPEN' WHERE id=7201"], "replenish_demand_forward_only")
_tx_block("07 需求只前进：已满足量回退", ["UPDATE replenish_demand SET fulfilled_qty_milli=5000 WHERE id=7201",
                                 "UPDATE replenish_demand SET fulfilled_qty_milli=1000 WHERE id=7201"], "replenish_demand_forward_only")
_tx_allow("07 需求正向：PLANNED 且 fulfilled 达量置 DONE", ["UPDATE replenish_demand SET status='PLANNED', task_id=701, task_line_id=7101, planned_qty_milli=20000 WHERE id=7201",
                "UPDATE replenish_demand SET status='DONE', fulfilled_qty_milli=20000 WHERE id=7201"])
_MOL = ("INSERT INTO move_order_line (id,move_order_id,line_no,from_location_id,to_location_id,sku_id,lot_id,from_stock_id,qty_milli,uom) "
        "VALUES ({i},7301,{ln},{frm},{to},1,1,12,{q},'KG')")
_tx_block("07 移库行：源位 = 目标位", [_MOL.format(i=7321, ln=2, frm=2, to=2, q=5000)], "ck_mol_route")
_tx_block("07 移库行：数量为 0", [_MOL.format(i=7322, ln=3, frm=2, to=3, q=0)], "ck_mol_qty")
_tx_block("07 移库行：DONE 但没有流水号", ["UPDATE move_order_line SET status='DONE' WHERE id=7311"], "ck_mol_done")
_tx_block("07 移库单：CONFIRMED 但没有确认时间", ["UPDATE move_order SET status='CONFIRMED' WHERE id=7301"], "ck_mo_confirm")
_tx_block("07 移库单：done_count 超过 line_count", ["UPDATE move_order SET done_count=2 WHERE id=7301"], "ck_mo_count")
_tx_block("07 移库单只前进：CONFIRMED 再回 DRAFT", ["UPDATE move_order SET status='CONFIRMED', confirmed_at=datetime('now') WHERE id=7301",
                                          "UPDATE move_order SET status='DRAFT' WHERE id=7301"], "move_order_forward_only")
_tx_allow("07 变异：去掉 trg_mo_forward 后，CONFIRMED 回 DRAFT 通过（回退时同时清 confirmed_at，否则撞 ck_mo_confirm）", ["DROP TRIGGER trg_mo_forward",
                                          "UPDATE move_order SET status='CONFIRMED', confirmed_at=datetime('now') WHERE id=7301",
                                          "UPDATE move_order SET status='DRAFT', confirmed_at=NULL WHERE id=7301"])
_tx_block("07 移库行 DONE 后改数量", ["UPDATE move_order_line SET status='DONE', movement_biz_no='MV-20261015-000001:1:D1', moved_at=datetime('now') WHERE id=7311",
                              "UPDATE move_order_line SET qty_milli=99999 WHERE id=7311"], "move_line_done_locked")
print("--- 2j-view. 上架 / 补货共用候选视图 v_location_sku_candidate ---")
def _view_case(desc, setup, check_sql, want, why=""):
    conn.execute("SAVEPOINT vc")
    try:
        for s in setup: conn.execute(s)
        got = [r[0] for r in conn.execute(check_sql)]
        ok(f"{desc} → {got}{why}") if got == want else bad(f"{desc} → {got}，期望 {want}{why}")
    except sqlite3.Error as e:
        bad(f"{desc} → 查询失败：{e}")
    finally:
        conn.execute("ROLLBACK TO vc"); conn.execute("RELEASE vc")
# 视图用例一律在 SAVEPOINT 里**现造数据**，不依赖基础种子（种子的 mix_sku/max_lots/批次分布与本视图口径无关）。
# 固定夹具：两个温区 + 五个库位（空位 mix_sku 一真一假、一个 LOCKED、一个常温位）+ 三个 SKU + 四个批次。
# 号段避开前面各篇用例（退供占了 97001–97004、7701–7704 也可能被别处用），本轮统一取 7711+ / 971xx。
_Z7V = [
    "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (7711,1,'Z7V-C','7篇视图冷藏','CHILLED','STORAGE',0,40)",
    "INSERT INTO zone (id,warehouse_id,code,name,temp_zone,zone_type,temp_min_c10,temp_max_c10) VALUES (7712,1,'Z7V-A','7篇视图常温','AMBIENT','STORAGE',100,300)",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7711,1,7711,'7V-A01','BIN',2,1,1,'7VA01','AVAILABLE')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7712,1,7711,'7V-A02','BIN',2,0,1,'7VA02','AVAILABLE')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7713,1,7711,'7V-A03','BIN',2,1,1,'7VA03','LOCKED')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7714,1,7711,'7V-A04','BIN',2,0,1,'7VA04','AVAILABLE')",
    "INSERT INTO location (id,warehouse_id,zone_id,code,location_type,max_lots,mix_sku,pickable,pick_sequence,status) VALUES (7715,1,7712,'7V-B01','BIN',2,1,1,'7VB01','AVAILABLE')",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (97101,'SKU7-CH','7篇视图冷藏货','KG','CHILLED',30,10,14)",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (97102,'SKU7-AM','7篇视图常温货','KG','AMBIENT',365,30,30)",
    "INSERT INTO sku (id,code,name,base_uom,temperature_required,shelf_life_days,ship_min_shelf_life,sell_days) VALUES (97103,'SKU7-CH2','7篇视图冷藏货2','KG','CHILLED',30,10,14)",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (97111,97101,'LOT7-C1','2026-11-01','2026-10-15')",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (97114,97103,'LOT7-C3','2026-11-03','2026-10-15')",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (97115,97103,'LOT7-C4','2026-11-04','2026-10-15')",
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date) VALUES (97113,97102,'LOT7-A1','2026-12-01','2026-10-15')",
]
def _s7(i, loc, sku, lot, q):
    return (f"INSERT INTO stock (id,warehouse_id,location_id,sku_id,lot_id,uom,on_hand_qty_milli) "
            f"VALUES ({i},1,{loc},{sku},{lot},'KG',{q})")
_c7 = "SELECT location_id FROM v_location_sku_candidate WHERE sku_id = 97101 AND zone_id = 7711 ORDER BY location_id"
_a7 = "SELECT location_id FROM v_location_sku_candidate WHERE sku_id = 97102 AND zone_id = 7712 ORDER BY location_id"
_view_case("07 视图：冷藏 SKU 候选 = 冷藏可用位（7711/7712/7714）；LOCKED 7713 与常温位 7715 都不进",
           _Z7V, _c7, [7711, 7712, 7714], "（同温区 + 未锁定）")
_view_case("07 视图：常温 SKU 候选只有常温位 7715（四个冷藏位全不进）",
           _Z7V, _a7, [7715], "（温区必须一致）")
_view_case("07 视图：mix_sku=false 的 7714 已有别的冷藏 SKU 的货 → 本 SKU 不进候选",
           _Z7V + [_s7(97141, 7714, 97103, 97114, 5000)], _c7, [7711, 7712], "（7714 被排除）")
_view_case("07 视图：mix_sku=false 的 7714 已有同 SKU 的货 → 仍在候选且 has_same_sku=1",
           _Z7V + [_s7(97142, 7714, 97101, 97111, 5000)],
           "SELECT has_same_sku FROM v_location_sku_candidate WHERE sku_id = 97101 AND location_id = 7714",
           [1], "（同 SKU 复用位）")
_view_case("07 视图：mix_sku=true 的 7711 有别的冷藏 SKU 的货也照样进候选",
           _Z7V + [_s7(97143, 7711, 97103, 97114, 5000)],
           "SELECT location_id FROM v_location_sku_candidate WHERE sku_id = 97101 AND location_id = 7711",
           [7711], "（mix_sku=true 允许混放）")
_view_case("07 视图：max_lots=2 的 7714 已放 2 个批次 → lot_cnt=2 且 has_lot_slot=0",
           _Z7V + [_s7(97144, 7714, 97103, 97114, 1000), _s7(97145, 7714, 97103, 97115, 1000)],
           "SELECT lot_cnt || '/' || max_lots || '/' || has_lot_slot FROM v_location_sku_candidate WHERE sku_id = 97103 AND location_id = 7714",
           ['2/2/0'], "（批次位占满）")
_view_case("07 视图：7714 只有 1 个批次 → lot_cnt=1 且 has_lot_slot=1",
           _Z7V + [_s7(97146, 7714, 97103, 97114, 1000)],
           "SELECT lot_cnt || '/' || has_lot_slot FROM v_location_sku_candidate WHERE sku_id = 97103 AND location_id = 7714",
           ['1/1'], "（还有批次位）")

print("=== FK 自检 ===")
_fk_guard("收尾")
ok(f"全程无用例在 foreign_keys=OFF 下运行（守卫命中 {_fk_guard_hits} 次）") if _fk_guard_hits == 0 else bad(f"FK 守卫命中 {_fk_guard_hits} 次")
if not _MUTANT_NO_FK and os.environ.get("VERIFY_SQLITE_SKIP_MUTANT") != "1":
    import subprocess
    # 子进程输出含 ✓/✗ 等非 ASCII：Windows 默认用 GBK 解码管道会在 _readerthread 里抛
    # UnicodeDecodeError，把 stdout 变成 None（POSIX 上是 UTF-8，不受影响）。显式指定编码。
    _mr = subprocess.run([sys.executable, __file__], env={**os.environ, "VERIFY_SQLITE_MUTANT_NO_FK": "1", "VERIFY_SQLITE_NO_WRITE": "1", "PYTHONIOENCODING": "utf-8"},
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    _mout = (_mr.stdout or "") + (_mr.stderr or "")
    if _mr.returncode != 0 and "[FK 守卫]" in _mout:
        ok(f"变异：去掉重连后的外键开启 → verify 变红（exit {_mr.returncode}，守卫命中 {_mout.count('[FK 守卫]')} 次）")
    else:
        bad(f"变异：去掉重连后的外键开启后 verify 仍绿或未被守卫发现（exit {_mr.returncode}）")
print("=== 2t. docs/05 波次与拣货：本轮新增 12 个 CHECK / 8 个外键 / ix_pt_handover 的三件套（正向 / 按名拒绝 / 变异）===")
# 变异 = 模拟"去掉该约束"后再执行原被拒语句，必须变成通过，然后回滚（证明拒绝确实来自该约束）。
# SQLite 不能 DROP CONSTRAINT：CHECK 用 @PRAGMA ignore_check_constraints@，外键用 PRAGMA foreign_keys=OFF。
def _m05_ck(name, stmts):
    conn.execute("PRAGMA ignore_check_constraints = ON")
    try:
        expect_allow_tx(f"05 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        conn.execute("PRAGMA ignore_check_constraints = OFF")
def _m05_fk(name, stmts):
    global _fk_off_allowed
    _fk_off_allowed = True; conn.execute("PRAGMA foreign_keys = OFF")
    try:
        expect_allow_tx(f"05 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        _fk_off_allowed = False; conn.execute("PRAGMA foreign_keys = ON")
def _m05_ck_trg(desc, drops, stmts):
    """变异：自指用例现在有两道防线（CHECK + 环守卫触发器），要同时去掉才谈得上"去掉守卫后通过"；随后回滚恢复。"""
    conn.execute("SAVEPOINT m05cktrg"); conn.execute("PRAGMA ignore_check_constraints = ON")
    for d in drops:
        conn.execute(d)
    try:
        for st in stmts:
            conn.execute(st)
        ok(f"{desc} → 通过（随后回滚）")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")
    finally:
        conn.execute("PRAGMA ignore_check_constraints = OFF")
        conn.execute("ROLLBACK TO m05cktrg"); conn.execute("RELEASE m05cktrg")
conn.execute("INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9101,'W-9101',1,'2026-10-15','CHILLED','R1','PLANNED')")
expect_allow_tx("05 正向：波次 + 任务 + 任务行（12 个 CHECK / 8 个外键全满足）", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type,zone_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9101,'PT-9101',9101,1,'PICK',1,'EXECUTING',41,'D9101',1,0)", "INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9101,9101,1,1,1,1,11,1,1000,1000,'KG','DONE')"])
expect_block_tx("05 拒绝：ck_wave_status 非法状态值", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9102,'W-9102',1,'2026-10-15','CHILLED','R1','BOGUS')"], "ck_wave_status")
_m05_ck("ck_wave_status", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status) VALUES (9102,'W-9102',1,'2026-10-15','CHILLED','R1','BOGUS')"])
expect_block_tx("05 拒绝：ck_wave_strategy 非法拣货策略", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,pick_strategy) VALUES (9103,'W-9103',1,'2026-10-15','CHILLED','R1','BOGUS')"], "ck_wave_strategy")
_m05_ck("ck_wave_strategy", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,pick_strategy) VALUES (9103,'W-9103',1,'2026-10-15','CHILLED','R1','BOGUS')"])
expect_block_tx("05 拒绝：ck_wave_parent 自指父波次", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,parent_wave_id) VALUES (9104,'W-9104',1,'2026-10-15','CHILLED','R1',9104)"], "ck_wave_parent")
_m05_ck_trg("05 变异：去掉 ck_wave_parent 与环守卫后，自指波次通过（随后回滚）", ["DROP TRIGGER trg_wave_parent_cycle", "DROP TRIGGER trg_wave_parent_cycle_u"], ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,parent_wave_id) VALUES (9104,'W-9104',1,'2026-10-15','CHILLED','R1',9104)"])
expect_block_tx("05 拒绝：ck_wave_count 汇总量为负", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,order_count) VALUES (9105,'W-9105',1,'2026-10-15','CHILLED','R1',-1)"], "ck_wave_count")
_m05_ck("ck_wave_count", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,order_count) VALUES (9105,'W-9105',1,'2026-10-15','CHILLED','R1',-1)"])
expect_block_tx("05 拒绝：ck_pt_type 非法任务类型", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type) VALUES (9104,'PT-9104',9101,1,'BOGUS')"], "ck_pt_type")
_m05_ck("ck_pt_type", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,task_type) VALUES (9104,'PT-9104',9101,1,'BOGUS')"])
expect_block_tx("05 拒绝：ck_pt_status 非法任务状态", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9105,'PT-9105',9101,1,'BOGUS')"], "ck_pt_status")
_m05_ck("ck_pt_status", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9105,'PT-9105',9101,1,'BOGUS')"])
expect_block_tx("05 拒绝：ck_pt_exec EXECUTING 没有持有人与设备", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9106,'PT-9106',9101,1,'EXECUTING')"], "ck_pt_exec")
_m05_ck("ck_pt_exec", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,status) VALUES (9106,'PT-9106',9101,1,'EXECUTING')"])
expect_block_tx("05 拒绝：ck_pt_count done_count 大于 line_count", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,line_count,done_count) VALUES (9107,'PT-9107',9101,1,1,2)"], "ck_pt_count")
_m05_ck("ck_pt_count", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,line_count,done_count) VALUES (9107,'PT-9107',9101,1,1,2)"])
expect_block_tx("05 拒绝：ck_pt_handover 交接来源指向自身", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,handover_from_task_id) VALUES (9108,'PT-9108',9101,1,9108)"], "ck_pt_handover")
_m05_ck_trg("05 变异：去掉 ck_pt_handover 与环守卫后，自指交接通过（随后回滚）", ["DROP TRIGGER trg_pt_handover_cycle", "DROP TRIGGER trg_pt_handover_cycle_u"], ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,handover_from_task_id) VALUES (9108,'PT-9108',9101,1,9108)"])
expect_block_tx("05 拒绝：ck_ptl_status 非法任务行状态", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9102,9101,2,1,1,1,11,1000,'KG','BOGUS')"], "ck_ptl_status")
_m05_ck("ck_ptl_status", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9102,9101,2,1,1,1,11,1000,'KG','BOGUS')"])
expect_block_tx("05 拒绝：ck_ptl_short SHORT 行缺原因码", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9103,9101,3,1,1,1,11,1000,'KG','SHORT')"], "ck_ptl_short")
_m05_ck("ck_ptl_short", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,status) VALUES (9103,9101,3,1,1,1,11,1000,'KG','SHORT')"])
expect_block_tx("05 拒绝：ck_ptl_short 原因码不在白名单", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,short_reason_code) VALUES (9105,9101,5,1,1,1,11,1000,'KG','BOGUS')"], "ck_ptl_short")
_m05_ck("ck_ptl_short", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,short_reason_code) VALUES (9105,9101,5,1,1,1,11,1000,'KG','BOGUS')"])
expect_block_tx("05 拒绝：ck_ptl_override 越权原因缺越权人", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,override_reason) VALUES (9104,9101,4,1,1,1,11,1000,'KG','FEFO_SKIP')"], "ck_ptl_override")
_m05_ck("ck_ptl_override", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom,override_reason) VALUES (9104,9101,4,1,1,1,11,1000,'KG','FEFO_SKIP')"])
expect_block_tx("05 拒绝：fk_pt_wave 任务挂不存在的波次", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id) VALUES (9109,'PT-9109',999999,1)"], "FOREIGN KEY constraint failed")
_m05_fk("fk_pt_wave", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id) VALUES (9109,'PT-9109',999999,1)"])
expect_block_tx("05 拒绝：fk_pt_zone 任务挂不存在的库区", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,zone_id) VALUES (9110,'PT-9110',9101,1,999999)"], "FOREIGN KEY constraint failed")
_m05_fk("fk_pt_zone", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,zone_id) VALUES (9110,'PT-9110',9101,1,999999)"])
expect_block_tx("05 拒绝：fk_ptl_task 任务行挂不存在的任务", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9106,999999,1,1,1,1,11,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_task", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9106,999999,1,1,1,1,11,1000,'KG')"])
expect_block_tx("05 拒绝：fk_ptl_stock 任务行挂不存在的库存行", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9107,9101,6,1,1,1,999999,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_stock", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9107,9101,6,1,1,1,999999,1000,'KG')"])
expect_block_tx("05 拒绝：fk_ptl_location 任务行挂不存在的库位", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9108,9101,7,999999,1,1,11,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_location", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9108,9101,7,999999,1,1,11,1000,'KG')"])
expect_block_tx("05 拒绝：fk_ptl_sku 任务行挂不存在的 SKU", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9109,9101,8,1,999999,1,11,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_sku", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9109,9101,8,1,999999,1,11,1000,'KG')"])
expect_block_tx("05 拒绝：fk_ptl_lot 任务行挂不存在的批次", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9110,9101,9,1,1,999999,11,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_lot", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,uom) VALUES (9110,9101,9,1,1,999999,11,1000,'KG')"])
expect_block_tx("05 拒绝：fk_ptl_obl 任务行挂不存在的出库行", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,uom) VALUES (9111,9101,10,1,1,1,11,999999,1000,'KG')"], "FOREIGN KEY constraint failed")
_m05_fk("fk_ptl_obl", ["INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,uom) VALUES (9111,9101,10,1,1,1,11,999999,1000,'KG')"])
_ix05 = one("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_pt_handover' AND sql LIKE '%handover_from_task_id IS NOT NULL%'")[0]
(ok if _ix05 == 1 else bad)("05 目录：ix_pt_handover 存在且是 handover_from_task_id 的部分索引")
conn.execute("SAVEPOINT ix05"); conn.execute("DROP INDEX ix_pt_handover")
_ix05n = one("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_pt_handover'")[0]
conn.execute("ROLLBACK TO ix05"); conn.execute("RELEASE ix05")
(ok if _ix05n == 0 else bad)("05 变异：去掉 ix_pt_handover 后，目录断言会变红（随后回滚）")
# P25-2（可证伪）：SKIP / ABNORMAL 行不算完成——任务不得凭它们进 DONE
conn.execute("INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9301,'PT-9301',9101,1,'EXECUTING',41,'D9101',1,0)")
conn.execute("INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9301,9301,1,1,1,1,11,1000,0,'KG','SKIP')")
_p25n = conn.execute("UPDATE pick_task SET status='DONE' WHERE id=9301 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9301 AND l.status IN ('PENDING','SKIP','ABNORMAL'))").rowcount
(ok if _p25n == 0 else bad)("05 P25-2：任务里有 SKIP 行（confirmed < planned）时 T-done 守卫命中 0 行（不得进 DONE）")
_p25m = conn.execute("UPDATE pick_task SET status='DONE' WHERE id=9301 AND status='EXECUTING'").rowcount
(ok if _p25m == 1 else bad)("05 P25-2 变异：去掉 NOT EXISTS 守卫后同一 UPDATE 命中 1 行（守卫是拦它的那条）")
print("=== 2u. docs/06 复核装箱发货：本轮新增 4 个 CHECK / 9 个外键的三件套（正向 / 按名拒绝 / 变异）===")
# 变异 = 模拟"去掉该约束"后再执行原被拒语句，必须变成通过，然后回滚（证明拒绝确实来自该约束）。
def _m06_ck(name, stmts):
    conn.execute("PRAGMA ignore_check_constraints = ON")
    try:
        expect_allow_tx(f"06 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        conn.execute("PRAGMA ignore_check_constraints = OFF")
def _m06_fk(name, stmts):
    global _fk_off_allowed
    _fk_off_allowed = True; conn.execute("PRAGMA foreign_keys = OFF")
    try:
        expect_allow_tx(f"06 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        _fk_off_allowed = False; conn.execute("PRAGMA foreign_keys = ON")
expect_allow_tx("06 正向：交接车次 HANDED_OVER + 箱 SEALED + 箱明细（4 个 CHECK / 9 个外键全满足）", ["INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9201,'SHP-9201',1,'HANDED_OVER')", "INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,1)", "INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id,stage_location_id,box_type,weight_g,sealed,checker_id,packed_at) VALUES (9201,'BOX-9201',1,1,9201,1,'CARTON',1500.00,1,41,'2026-10-15 09:00:00')", "INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9201,9201,1,0,1000,'KG')"])
expect_allow_tx("06 正向：车次 CANCELLED", ["INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9202,'SHP-9202',1,'CANCELLED')"])
expect_block_tx("06 拒绝：ck_box_type 非法箱型", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,box_type) VALUES (9203,'BOX-9203',1,1,'BOGUS')"], "ck_box_type")
_m06_ck("ck_box_type", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,box_type) VALUES (9203,'BOX-9203',1,1,'BOGUS')"])
expect_block_tx("06 拒绝：ck_box_weight 重量为负", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,weight_g) VALUES (9204,'BOX-9204',1,1,-1)"], "ck_box_weight")
_m06_ck("ck_box_weight", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,weight_g) VALUES (9204,'BOX-9204',1,1,-1)"])
expect_block_tx("06 拒绝：ck_box_sealed 未封箱却标封箱", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,sealed) VALUES (9205,'BOX-9205',1,1,1)"], "ck_box_sealed")
_m06_ck("ck_box_sealed", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,sealed) VALUES (9205,'BOX-9205',1,1,1)"])
expect_block_tx("06 拒绝：ck_shp_status 非法车次状态", ["INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9203,'SHP-9203',1,'BOGUS')"], "ck_shp_status")
_m06_ck("ck_shp_status", ["INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9203,'SHP-9203',1,'BOGUS')"])
expect_block_tx("06 拒绝：fk_shp_wh 车次挂不存在的仓", ["INSERT INTO shipment (id,code,warehouse_id) VALUES (9204,'SHP-9204',999999)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_shp_wh", ["INSERT INTO shipment (id,code,warehouse_id) VALUES (9204,'SHP-9204',999999)"])
expect_block_tx("06 拒绝：fk_sho_shipment 挂单指向不存在的车次", ["INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (999999,1)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_sho_shipment", ["INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (999999,1)"])
expect_block_tx("06 拒绝：fk_sho_outbound 挂单指向不存在的出库单", ["INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,999999)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_sho_outbound", ["INSERT INTO shipment_order (shipment_id,outbound_id) VALUES (9201,999999)"])
expect_block_tx("06 拒绝：fk_box_wh 箱挂不存在的仓", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9206,'BOX-9206',999999,1)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_box_wh", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9206,'BOX-9206',999999,1)"])
expect_block_tx("06 拒绝：fk_box_outbound 箱挂不存在的出库单", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9207,'BOX-9207',1,999999)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_box_outbound", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id) VALUES (9207,'BOX-9207',1,999999)"])
expect_block_tx("06 拒绝：fk_box_shipment 箱挂不存在的车次", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id) VALUES (9208,'BOX-9208',1,1,999999)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_box_shipment", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,shipment_id) VALUES (9208,'BOX-9208',1,1,999999)"])
expect_block_tx("06 拒绝：fk_box_stage 箱挂不存在的集货位", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,stage_location_id) VALUES (9209,'BOX-9209',1,1,999999)"], "FOREIGN KEY constraint failed")
_m06_fk("fk_box_stage", ["INSERT INTO pack_box (id,code,warehouse_id,outbound_id,stage_location_id) VALUES (9209,'BOX-9209',1,1,999999)"])
expect_block_tx("06 拒绝：fk_bxl_box 箱明细挂不存在的箱", ["INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9202,999999,1,0,1000,'KG')"], "FOREIGN KEY constraint failed")
_m06_fk("fk_bxl_box", ["INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9202,999999,1,0,1000,'KG')"])
expect_block_tx("06 拒绝：fk_bxl_sku 箱明细挂不存在的 SKU", ["INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9203,9201,999999,0,1000,'KG')"], "FOREIGN KEY constraint failed")
_m06_fk("fk_bxl_sku", ["INSERT INTO pack_box_line (id,box_id,sku_id,lot_id,qty_milli,uom) VALUES (9203,9201,999999,0,1000,'KG')"])
print("=== 2g-12t. 第 12 篇时间加固第二轮：正向放行 + 反向按名拦截 + 变异（两库对称）===")
# 三件套：① 正向（窗口内时间落库）② 反向（按错误名精确命中）③ 变异（去掉守卫后原被拒语句必须通过）
expect_allow_tx("12t 正向：建号 created_at = datetime('now') → 通过",
                ["INSERT INTO sys_user (id,username,password_hash,created_at) VALUES (779901,'t12t1','x',datetime('now'))"])
expect_allow_tx("12t 正向：写登录时间 = datetime('now') → 通过",
                ["INSERT INTO sys_user (id,username,password_hash) VALUES (779902,'t12t2','x')",
                 "UPDATE sys_user SET last_login_at = datetime('now') WHERE id = 779902"])
expect_allow_tx("12t 正向：写停用时间 = datetime('now') → 通过",
                ["INSERT INTO sys_user (id,username,password_hash) VALUES (779903,'t12t3','x')",
                 "UPDATE sys_user SET deleted_at = datetime('now') WHERE id = 779903"])
expect_block_tx("12t 反向：INSERT sys_user 带 last_login_at（新用户没登录过）",
                ["INSERT INTO sys_user (id,username,password_hash,last_login_at) VALUES (779904,'t12t4','x','2000-01-01 00:00:00')"],
                "sys_user_insert_time_set")
expect_block_tx("12t 反向：INSERT sys_user 带 deleted_at（新用户不是停用态）",
                ["INSERT INTO sys_user (id,username,password_hash,deleted_at) VALUES (779905,'t12t5','x','2000-01-01 00:00:00')"],
                "sys_user_insert_time_set")
expect_block_tx("12t 反向：UPDATE sys_user 改建号时间（created_at 不可改）",
                ["INSERT INTO sys_user (id,username,password_hash) VALUES (779906,'t12t6','x')",
                 "UPDATE sys_user SET created_at = '2000-01-01 00:00:00' WHERE id = 779906"],
                "sys_user_created_at_immutable")
expect_block_tx("12t 反向：UPDATE sys_user 清空停用时间（停用是事实，不可回退）",
                ["INSERT INTO sys_user (id,username,password_hash) VALUES (779907,'t12t7','x')",
                 "UPDATE sys_user SET deleted_at = datetime('now') WHERE id = 779907",
                 "UPDATE sys_user SET deleted_at = NULL WHERE id = 779907"],
                "sys_user_deleted_at_immutable")
expect_block_tx("12t 反向：INSERT sys_user created_at 与 now 相差 > 300 s（时钟偏移）",
                ["INSERT INTO sys_user (id,username,password_hash,created_at) VALUES (779908,'t12t8','x','2000-01-01 00:00:00')"],
                "sys_user_clock_skew")
expect_block_tx("12t 反向：INSERT api_credential 带 last_used_at（新凭证没用过）",
                ["INSERT INTO api_credential (id,api_key,secret_encrypted,source_system,last_used_at) VALUES (779909,'K779909','s','ERP','2000-01-01 00:00:00')"],
                "api_credential_insert_time_set")
for _tg12t, _sql12t in [
    ("trg_user_ins_time_set", "INSERT INTO sys_user (id,username,password_hash,last_login_at) VALUES (779911,'t12tm1','x','2000-01-01 00:00:00')"),
    ("trg_api_ins_time_set", "INSERT INTO api_credential (id,api_key,secret_encrypted,source_system,last_used_at) VALUES (779912,'K779912','s','ERP','2000-01-01 00:00:00')"),
]:
    conn.execute("SAVEPOINT mut12t")
    conn.execute(f"DROP TRIGGER {_tg12t}")
    _passed12t = False
    try:
        conn.execute(_sql12t)
        _passed12t = True
    except sqlite3.Error:
        _passed12t = False
    conn.execute("ROLLBACK TO mut12t"); conn.execute("RELEASE mut12t")
    ok(f"变异：去掉 {_tg12t} 后原被拒语句通过（断言能抓到）") if _passed12t else bad(f"变异没变红：{_tg12t}")
print("=== 2v. docs/08 盘点与调整：本轮新增 10 个 CHECK / 8 个外键 / 5 条索引 + uq_adjl 的三件套（正向 / 按名拒绝 / 变异）===")
# 变异 = 模拟"去掉该约束"后再执行原被拒语句，必须变成通过，然后回滚（证明拒绝确实来自该约束）。
# SQLite 不能 DROP CONSTRAINT：CHECK 用 @PRAGMA ignore_check_constraints@，外键用 PRAGMA foreign_keys=OFF。
# ck_cnt_int / ck_adj_int（量必须整 milli）在 SQLite 侧是可证伪的（见上面的 "2e. count_line 整数约束"：写 1.5 被
# ck_cnt_int 拦下）；在 PG 侧由列类型 BIGINT 直接保证（CHECK 恒真），故这两条在本段只做目录断言，两库标题一致。
def _m08_ck(name, stmts):
    conn.execute("PRAGMA ignore_check_constraints = ON")
    try:
        expect_allow_tx(f"08 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        conn.execute("PRAGMA ignore_check_constraints = OFF")
def _m08_fk(name, stmts):
    global _fk_off_allowed
    _fk_off_allowed = True; conn.execute("PRAGMA foreign_keys = OFF")
    try:
        expect_allow_tx(f"08 变异：去掉 {name} 后，原被拒语句通过（随后回滚）", stmts)
    finally:
        _fk_off_allowed = False; conn.execute("PRAGMA foreign_keys = ON")
expect_allow_tx("08 正向：盘点单 + 盘点行（COUNTING/RECOUNTED，ck_cnt_*、ck_cntl_*、fk_cnt_wh/fk_cntl_* 全满足）", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at,created_by) VALUES (9401,'CNT-SH01-9401-20261015-000001',1,'CYCLE','{}','COUNTING','2026-10-15 02:00:00',41)", "INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,recount_qty_milli,status,counted_by,counted_at) VALUES (9411,9401,1,1,1,100000,-30000,68000,69000,'RECOUNTED',41,'2026-10-15 03:00:00')"])
expect_allow_tx("08 正向：调整单 + 调整行（ck_adj_*、fk_adj_wh/fk_adjl_order 全满足）", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9421,'ADJ-SH01-9401-20261015-000001',1,'COUNT_LOSS','COUNT_DIFF','PENDING',41)", "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9431,9421,1,11,-2000)"])
expect_allow_tx("08 正向：盘点行回指调整单 + 同一调整单第 2 行（fk_cntl_adjust / uq_adjl 多行不撞）", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at,adjust_id) VALUES (9412,9401,2,1,1,1000,0,900,'COUNTED',41,'2026-10-15 03:05:00',9421)", "INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9432,9421,2,12,3000)"])
expect_block_tx("08 拒绝：ck_cnt_type 非法盘点类型", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9402,'CNT-SH01-9402-20261015-000002',1,'BOGUS','{}','2026-10-15 02:00:00')"], "ck_cnt_type")
_m08_ck("ck_cnt_type", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9402,'CNT-SH01-9402-20261015-000002',1,'BOGUS','{}','2026-10-15 02:00:00')"])
expect_block_tx("08 拒绝：ck_cnt_status 非法盘点单状态", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (9403,'CNT-SH01-9403-20261015-000003',1,'FULL','{}','BOGUS','2026-10-15 02:00:00')"], "ck_cnt_status")
_m08_ck("ck_cnt_status", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,status,book_at) VALUES (9403,'CNT-SH01-9403-20261015-000003',1,'FULL','{}','BOGUS','2026-10-15 02:00:00')"])
expect_block_tx("08 拒绝：ck_cnt_approved 盘点审批人与创建人同一人", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at,created_by,approved_by) VALUES (9404,'CNT-SH01-9404-20261015-000004',1,'FULL','{}','2026-10-15 02:00:00',41,41)"], "ck_cnt_approved")
_m08_ck("ck_cnt_approved", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at,created_by,approved_by) VALUES (9404,'CNT-SH01-9404-20261015-000004',1,'FULL','{}','2026-10-15 02:00:00',41,41)"])
expect_block_tx("08 拒绝：ck_adj_type 非法调整类型", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9422,'ADJ-SH01-9402-20261015-000002',1,'BOGUS','COUNT_DIFF',41)"], "ck_adj_type")
_m08_ck("ck_adj_type", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9422,'ADJ-SH01-9402-20261015-000002',1,'BOGUS','COUNT_DIFF',41)"])
expect_block_tx("08 拒绝：ck_adj_status 非法调整单状态", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9423,'ADJ-SH01-9403-20261015-000003',1,'MANUAL','COUNT_DIFF','BOGUS',41)"], "ck_adj_status")
_m08_ck("ck_adj_status", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,status,applicant_id) VALUES (9423,'ADJ-SH01-9403-20261015-000003',1,'MANUAL','COUNT_DIFF','BOGUS',41)"])
expect_block_tx("08 拒绝：ck_adj_sod 调整单审批人与申请人同一人", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id,approver_id) VALUES (9424,'ADJ-SH01-9404-20261015-000004',1,'MANUAL','COUNT_DIFF',41,41)"], "ck_adj_sod")
_m08_ck("ck_adj_sod", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id,approver_id) VALUES (9424,'ADJ-SH01-9404-20261015-000004',1,'MANUAL','COUNT_DIFF',41,41)"])
expect_block_tx("08 拒绝：ck_adj_delta 调整量为 0（既不盘盈也不盘亏）", ["INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9433,9421,3,11,0)"], "ck_adj_delta")
_m08_ck("ck_adj_delta", ["INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9433,9421,3,11,0)"])
expect_block_tx("08 拒绝：ck_cntl_status 非法盘点行状态", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at) VALUES (9413,9401,3,1,2,1000,0,1000,'BOGUS',41,'2026-10-15 03:10:00')"], "ck_cntl_status")
_m08_ck("ck_cntl_status", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,actual_qty_milli,status,counted_by,counted_at) VALUES (9413,9401,3,1,2,1000,0,1000,'BOGUS',41,'2026-10-15 03:10:00')"])
expect_block_tx("08 拒绝：ck_cntl_counted 已盘点却没写实盘量", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,status,counted_at) VALUES (9414,9401,3,2,1,1000,0,'COUNTED','2026-10-15 03:15:00')"], "ck_cntl_counted")
_m08_ck("ck_cntl_counted", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,status,counted_at) VALUES (9414,9401,3,2,1,1000,0,'COUNTED','2026-10-15 03:15:00')"])
expect_block_tx("08 拒绝：ck_cntl_recount 未实盘就写复盘量", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,recount_qty_milli) VALUES (9415,9401,2,1,2,1000,0,1000)"], "ck_cntl_recount")
_m08_ck("ck_cntl_recount", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,movement_qty_milli,recount_qty_milli) VALUES (9415,9401,2,1,2,1000,0,1000)"])
_ck08a = one("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='count_line' AND sql LIKE '%ck_cnt_int%'")[0]
(ok if _ck08a == 1 else bad)("08 目录：ck_cnt_int 存在（基准/期间/实盘/复盘量必须是整 milli；SQLite 侧另有 1.5 反证）")
_ck08b = one("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='adjust_line' AND sql LIKE '%ck_adj_int%'")[0]
(ok if _ck08b == 1 else bad)("08 目录：ck_adj_int 存在（调整量必须是整 milli；SQLite 侧另有 1.5 反证）")
expect_block_tx("08 拒绝：fk_cnt_wh 盘点单挂不存在的仓", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9405,'CNT-SH01-9405-20261015-000005',999999,'FULL','{}','2026-10-15 02:00:00')"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cnt_wh", ["INSERT INTO count_order (id,code,warehouse_id,count_type,scope_json,book_at) VALUES (9405,'CNT-SH01-9405-20261015-000005',999999,'FULL','{}','2026-10-15 02:00:00')"])
expect_block_tx("08 拒绝：fk_adj_wh 调整单挂不存在的仓", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9425,'ADJ-SH01-9405-20261015-000005',999999,'MANUAL','COUNT_DIFF',41)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_adj_wh", ["INSERT INTO adjust_order (id,code,warehouse_id,adjust_type,reason_code,applicant_id) VALUES (9425,'ADJ-SH01-9405-20261015-000005',999999,'MANUAL','COUNT_DIFF',41)"])
expect_block_tx("08 拒绝：fk_adjl_order 调整行挂不存在的调整单", ["INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9434,999999,9,11,100)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_adjl_order", ["INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9434,999999,9,11,100)"])
expect_block_tx("08 拒绝：fk_cntl_count 盘点行挂不存在的盘点单", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9416,999999,1,1,1,1000)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cntl_count", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9416,999999,1,1,1,1000)"])
expect_block_tx("08 拒绝：fk_cntl_adjust 盘点行挂不存在的调整单", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,adjust_id) VALUES (9417,9401,3,1,3,1000,999999)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cntl_adjust", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli,adjust_id) VALUES (9417,9401,3,1,3,1000,999999)"])
expect_block_tx("08 拒绝：fk_cntl_loc 盘点行挂不存在的库位", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9418,9401,999999,1,1,1000)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cntl_loc", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9418,9401,999999,1,1,1000)"])
expect_block_tx("08 拒绝：fk_cntl_sku 盘点行挂不存在的 SKU", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9419,9401,1,999999,1,1000)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cntl_sku", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9419,9401,1,999999,1,1000)"])
expect_block_tx("08 拒绝：fk_cntl_lot 盘点行挂不存在的批次", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9420,9401,1,1,999999,1000)"], "FOREIGN KEY constraint failed")
_m08_fk("fk_cntl_lot", ["INSERT INTO count_line (id,count_id,location_id,sku_id,lot_id,book_qty_milli) VALUES (9420,9401,1,1,999999,1000)"])
expect_block_tx("08 拒绝：uq_adjl 同一调整单同一 line_no 重复（02 记账幂等键 {biz_no}:{line_no}）", ["INSERT INTO adjust_line (id,adjust_id,line_no,stock_id,delta_qty_milli) VALUES (9435,9421,1,13,500)"], "adjust_line.adjust_id, adjust_line.line_no")
_uq08 = one("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='adjust_line' AND sql LIKE '%uq_adjl%'")[0]
(ok if _uq08 == 1 else bad)("08 目录：uq_adjl 存在（02 记账幂等键 {biz_no}:{line_no}:D{op_no}:{leg} 的行号唯一）")
for _ixname, _ixtbl, _ixdesc in (("ix_cnt_wh", "count_order", "count_order(warehouse_id, status, created_at)"), ("ix_adj_wh", "adjust_order", "adjust_order(warehouse_id, status, created_at)"), ("ix_adj_src", "adjust_order", "adjust_order(source_type, source_id)"), ("ix_cnt_line_count", "count_line", "count_line(count_id, status)"), ("ix_cnt_line_loc", "count_line", "count_line(location_id)")):
    _ixdef = "(" + _ixdesc.split("(", 1)[1]   # 目录断言同时核对列清单，避免"名字在、列不对"混过去
    _ixn = one("SELECT count(*) FROM sqlite_master WHERE type='index' AND name=? AND tbl_name=? AND sql LIKE ?", _ixname, _ixtbl, "%" + _ixdef + "%")[0]
    (ok if _ixn == 1 else bad)(f"08 目录：{_ixname} 存在且挂在 {_ixdesc}")
    conn.execute("SAVEPOINT ix08"); conn.execute(f"DROP INDEX {_ixname}")
    _ixm = one("SELECT count(*) FROM sqlite_master WHERE type='index' AND name=?", _ixname)[0]
    conn.execute("ROLLBACK TO ix08"); conn.execute("RELEASE ix08")
    (ok if _ixm == 0 else bad)(f"08 变异：去掉 {_ixname} 后目录断言命中 0（随后回滚）")
print("=== 2t2. docs/05 增量：空串设备号 / 父子链·改派链环守卫 / 撤销回退行状态（正向 / 按名拒绝 / 变异）===")
# 环守卫变异：SQLite DDL 可回滚 → 在保存点里 DROP TRIGGER，原被拒语句必须通过，再回滚恢复。
def _m05_trg(desc, drops, stmt):
    conn.execute("SAVEPOINT m05trg")
    for d in drops:
        conn.execute(d)
    try:
        conn.execute(stmt)
        ok(f"{desc} → 通过（随后回滚）")
    except sqlite3.Error as e:
        bad(f"{desc} → 被误拦：{e}")
    finally:
        conn.execute("ROLLBACK TO m05trg"); conn.execute("RELEASE m05trg")
# 深链（>64 节）没法在守卫开着时建出来 → 在保存点里去掉 4 个触发器造链、用 sqlite_master 里的原文装回去，再闭合必须报 depth。
def _m05_deep(desc, inserts, close_sql, want):
    names = ("trg_wave_parent_cycle", "trg_wave_parent_cycle_u", "trg_pt_handover_cycle", "trg_pt_handover_cycle_u")
    saved = [one("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", n)[0] for n in names]
    conn.execute("SAVEPOINT m05deep")
    try:
        for n in names:
            conn.execute(f"DROP TRIGGER {n}")
        for st in inserts:
            conn.execute(st)
        for s in saved:
            conn.execute(s)
        try:
            conn.execute(close_sql)
            bad(f"{desc} → 未拦截（SQLite 侧有洞）")
        except sqlite3.IntegrityError as e:
            msg = str(e)
            if msg == want or msg.endswith(": " + want):
                ok(f"{desc} → 已拦截（{msg}）")
            else:
                bad(f"{desc} → 被拦了但守卫不对：期望 {want!r}，实际 {msg!r}")
    finally:
        conn.execute("ROLLBACK TO m05deep"); conn.execute("RELEASE m05deep")
# ① 空串设备号：ck_pt_device 与 ck_pt_exec 各管一件事，EXECUTING + 空串也必须撞 ck_pt_device
expect_block_tx("05 增量①：ck_pt_device 拒非空的空串设备号", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9401,'PT-9401',9101,1,'')"], "ck_pt_device")
_m05_ck("ck_pt_device", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9401,'PT-9401',9101,1,'')"])
expect_block_tx("05 增量①：EXECUTING + 空串设备也一样撞 ck_pt_device（旧 ck_pt_exec 放行的那条）", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id) VALUES (9402,'PT-9402',9101,1,'EXECUTING',41,'')"], "ck_pt_device")
# r6 加固（镜鉴）：'' 之外，全空格与制表符也必须拒（否则 P{设备}.{op_seq} 仍会退化）
expect_block_tx("05 增量①r6：ck_pt_device 拒全空格设备号", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9406,'PT-9406',9101,1,'   ')"], "ck_pt_device")
expect_block_tx("05 增量①r6：ck_pt_device 拒制表符/换行组成的设备号", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9407,'PT-9407',9101,1,char(9)||char(10))"], "ck_pt_device")
expect_allow_tx("05 增量①r6 正向：设备号两侧带空格的合法值仍可落库", ["INSERT INTO pick_task (id,code,wave_id,warehouse_id,device_instance_id) VALUES (9408,'PT-9408',9101,1,' D9408 ')"])
# ② 环守卫：合法链通过，两点成环在 UPDATE / INSERT 两条路径上都被拒
conn.execute("INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9201,'W-9201',1,'2026-10-15','CHILLED','R1','PLANNED',NULL)")
conn.execute("INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9202,'W-9202',1,'2026-10-15','CHILLED','R1','PLANNED',9201)")
expect_allow_tx("05 增量②正向：合法父子链（9203 → 9202 → 9201）", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9203,'W-9203',1,'2026-10-15','CHILLED','R1','PLANNED',9202)"])
expect_block_tx("05 增量②：环守卫拒两点成环（UPDATE 闭合 9201 → 9202）", ["UPDATE wave SET parent_wave_id=9202 WHERE id=9201"], "wave_parent_cycle")
_m05_trg("05 增量②变异：去掉两个环守卫触发器后，成环 UPDATE 通过", ["DROP TRIGGER trg_wave_parent_cycle", "DROP TRIGGER trg_wave_parent_cycle_u"], "UPDATE wave SET parent_wave_id=9202 WHERE id=9201")
expect_allow_tx("05 增量②：悬空父指针仍可落库（无自引用外键，见 §12 Q14）", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9206,'W-9206',1,'2026-10-15','CHILLED','R1','PLANNED',9205)"])
expect_block_tx("05 增量②：INSERT 补上第二条边成环也被拒（9205 → 9206 → 9205）", ["INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (9205,'W-9205',1,'2026-10-15','CHILLED','R1','PLANNED',9206)"], "wave_parent_cycle")
# r6 加固（镜鉴）：旧 SQLite 递归只走 64 行，65 节链闭合会漏检——现在必须报 cycle；>64 节深链必须报 depth（与 PG 同口径）
for _g in range(9601, 9666):
    conn.execute("INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES (?,?,1,'2026-10-15','CHILLED','R1','PLANNED',?)", (_g, f"W-C{_g}", None if _g == 9601 else _g - 1))
expect_block_tx("05 增量②r6：65 节链闭合报 wave_parent_cycle（旧递归上限漏检的那条）", ["UPDATE wave SET parent_wave_id=9665 WHERE id=9601"], "wave_parent_cycle")
_m05_deep("05 增量②r6：已存在的 66 节深链再闭合报 wave_parent_cycle_depth（两库同口径）",
          [f"INSERT INTO wave (id,code,warehouse_id,work_date,temperature_zone,route_code,status,parent_wave_id) VALUES ({_g},'W-E{_g}',1,'2026-10-15','CHILLED','R1','PLANNED',{'NULL' if _g == 9701 else _g - 1})" for _g in range(9701, 9767)],
          "UPDATE wave SET parent_wave_id=9766 WHERE id=9701", "wave_parent_cycle_depth")
conn.execute("INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id) VALUES (9403,'PT-9403',9201,1,'EXECUTING',41,'D9403')")
conn.execute("INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,handover_from_task_id) VALUES (9404,'PT-9404',9201,1,'EXECUTING',42,'D9404',9403)")
expect_block_tx("05 增量②：环守卫拒改派链成环（9403 → 9404 → 9403）", ["UPDATE pick_task SET handover_from_task_id=9404 WHERE id=9403"], "pick_task_handover_cycle")
_m05_trg("05 增量②变异：去掉两个改派链守卫触发器后，成环 UPDATE 通过", ["DROP TRIGGER trg_pt_handover_cycle", "DROP TRIGGER trg_pt_handover_cycle_u"], "UPDATE pick_task SET handover_from_task_id=9404 WHERE id=9403")
_cyc = one("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN ('trg_wave_parent_cycle','trg_wave_parent_cycle_u','trg_pt_handover_cycle','trg_pt_handover_cycle_u')")[0]
(ok if _cyc == 4 else bad)(f"05 增量②目录：4 个环守卫触发器都在 sqlite_master（实际 {_cyc}）")
# ③ 撤销回退行状态：§6.5 的撤销必须与数量同一条 UPDATE 回退 status，否则 T-done 仍判拣满
conn.execute("INSERT INTO pick_task (id,code,wave_id,warehouse_id,status,assigned_to,device_instance_id,line_count,done_count) VALUES (9405,'PT-9405',9201,1,'EXECUTING',41,'D9405',1,1)")
conn.execute("INSERT INTO pick_task_line (id,pick_task_id,seq,location_id,sku_id,lot_id,stock_id,outbound_line_id,planned_qty_milli,confirmed_qty_milli,uom,status) VALUES (9405,9405,1,1,1,1,11,1,1000,1000,'KG','DONE')")
_u5n = conn.execute("UPDATE pick_task_line SET confirmed_qty_milli=confirmed_qty_milli-300, status=CASE WHEN status='DONE' AND confirmed_qty_milli-300 < planned_qty_milli THEN 'PENDING' ELSE status END WHERE id=9405 AND confirmed_qty_milli>=300").rowcount
_u5s = one("SELECT status FROM pick_task_line WHERE id=9405")[0]
(ok if (_u5n, _u5s) == (1, 'PENDING') else bad)(f"05 增量③：撤销同一条 UPDATE 把 DONE 行回退成 PENDING（{_u5n}/{_u5s}）")
_t5d = conn.execute("UPDATE pick_task SET status='DONE' WHERE id=9405 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9405 AND l.status IN ('PENDING','SKIP','ABNORMAL'))").rowcount
(ok if _t5d == 0 else bad)(f"05 增量③：回退后 T-done 守卫命中 0 行（任务不得进 DONE），实际 {_t5d}")
conn.execute("UPDATE pick_task_line SET confirmed_qty_milli=1000, status='DONE' WHERE id=9405")
_v5n = conn.execute("UPDATE pick_task_line SET confirmed_qty_milli=confirmed_qty_milli-300 WHERE id=9405 AND confirmed_qty_milli>=300").rowcount
_v5s = one("SELECT status FROM pick_task_line WHERE id=9405")[0]
(ok if (_v5n, _v5s) == (1, 'DONE') else bad)(f"05 增量③变异：只减量不回退状态的旧写法，行仍是 DONE（{_v5n}/{_v5s}）")
_t5m = conn.execute("UPDATE pick_task SET status='DONE' WHERE id=9405 AND status='EXECUTING' AND NOT EXISTS (SELECT 1 FROM pick_task_line l WHERE l.pick_task_id=9405 AND l.status IN ('PENDING','SKIP','ABNORMAL'))").rowcount
(ok if _t5m == 1 else bad)(f"05 增量③变异：不回退状态时同一任务被判 DONE（证明回退是拦它的那条），实际 {_t5m}")
print("=== 2w. docs/16 配送与签收：38 CHECK / 22 外键 / 3 部分唯一索引的三件套（正向 / 按名拒绝 / 变异）===")
# 父行（96xx；warehouse 1 / sku 1 见最前面的 seed）。同一份列表也用于变异内存库。
_S16_PARENT = [
    "INSERT INTO lot (id,sku_id,lot_code,expiry_date,receive_date,quality_status,remaining_life_days) VALUES (9610,1,'LOT-16-9610','2026-12-01','2026-10-15','QUALIFIED',30)",
    "INSERT INTO shipment (id,code,warehouse_id,status) VALUES (9610,'SHP-9610',1,'CREATED'),(9611,'SHP-9611',1,'CREATED'),(9612,'SHP-9612',1,'CREATED'),(9613,'SHP-9613',1,'CREATED'),(9614,'SHP-9614',1,'CREATED'),(9615,'SHP-9615',1,'CREATED'),(9616,'SHP-9616',1,'CREATED'),(9617,'SHP-9617',1,'CREATED')",
    "INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9610,'WB-16-9610',9610,1,'2026-10-15','IN_TRANSIT')",
    "INSERT INTO outbound_order (id,code,warehouse_id,order_type,source_system,source_order_no,source_hash,customer_id,status,work_date) VALUES (9610,'OBT-16-9610',1,'SALE','MALL','M-16-9610','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9611,'OBT-16-9611',1,'SALE','MALL','M-16-9611','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9612,'OBT-16-9612',1,'SALE','MALL','M-16-9612','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9613,'OBT-16-9613',1,'SALE','MALL','M-16-9613','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9614,'OBT-16-9614',1,'SALE','MALL','M-16-9614','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9615,'OBT-16-9615',1,'SALE','MALL','M-16-9615','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15'),(9616,'OBT-16-9616',1,'SALE','MALL','M-16-9616','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'SHIPPED','2026-10-15')",
    "INSERT INTO outbound_line (id,outbound_id,line_no,sku_id,order_qty_milli,picked_qty_milli,uom) VALUES (9610,9610,1,1,10000,10000,'KG')",
    "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9610,'WB-16-9610',1,'D9610',1,'POD_SIGN','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0',40,'2026-10-15 02:00:00','2026-10-16 02:00:00')",
    "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9611,'WB-16-9610',0,'D9611',2,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0'),(9612,'WB-16-9610',0,'D9612',3,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0'),(9613,'WB-16-9610',0,'D9613',4,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0'),(9614,'WB-16-9610',0,'D9614',5,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0'),(9615,'WB-16-9610',0,'D9615',6,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0'),(9671,'WB-16-9610',0,'D9671',7,'LOAD','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','200','0')",
    "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9670,9610,1,90,'OPEN'),(9671,9610,1,91,'OPEN'),(9672,9610,1,92,'OPEN'),(9673,9610,1,93,'OPEN'),(9674,9610,1,94,'OPEN'),(9675,9610,1,95,'OPEN'),(9676,9610,1,96,'OPEN')",
]
for _q in _S16_PARENT:
    try:
        conn.execute(_q)
    except sqlite3.Error as _e:
        bad(f"16 准备父行失败：{_e}")
conn.commit()
_H = "a" * 64
# 正向：9 张表各一条
expect_allow("16 正向：waybill（CREATED + 快照列）", "INSERT INTO waybill (id,code,shipment_id,warehouse_id,driver_name,vehicle_no,work_date,status) VALUES (9671,'WB-16-9671',9611,1,'司机甲','沪A16','2026-10-15','CREATED')")
expect_allow("16 正向：delivery_stop", "INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9671,9610,1,'PENDING')")
expect_allow("16 正向：delivery_order（SHIPPED，无生效签收）", "INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9671,9611,9610,1,'SHIPPED')")
expect_allow("16 正向：pod_op（LOAD）", "INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9672,'WB-16-9610',0,'D9672',8,'LOAD','%s','200','0')" % _H)
expect_allow("16 正向：pod_line", "INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9671,9610,9610,9610,10000,0,40)")
expect_allow("16 正向：pod_correction（PENDING + 202）", "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9671,9610,9610,9610,9612,1,'00000000-0000-4000-8000-000000009671','%s','202',0)" % _H)
expect_allow("16 正向：pod_tolerance_config", "INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9671,1,'CHILLED',500,100)")
expect_allow("16 正向：delivery_return（OPEN）", "INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9677,9610,1,1,'OPEN')")
expect_allow("16 正向：delivery_return_line", "INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9671,9670,1,9610,5000)")
# I2 跨篇 FK（Chief 2026-10-16）：16 的三列指向 01 台账，各一条正向（父行 driver 1 在 seed / _MASTER_MIN 里）。
# 注意：SQLite 的 no-REPLACE 守卫按 `id OR code OR shipment_id` 等业务键判重，正向行必须避开 16 段坏样本用的键
#（故用 shipment 9617 / 站点号 9 / outbound 9611），否则会把 `_S16` 的按名拒绝抢成 `*_duplicate`。
expect_allow("16 正向：waybill.driver_id = 1（01 司机台账、快照列照旧）", "INSERT INTO waybill (id,code,shipment_id,warehouse_id,driver_id,driver_name,driver_phone,work_date,status) VALUES (9672,'WB-16-9672',9617,1,1,'司机乙','13900000002','2026-10-15','CREATED')")
expect_allow("16 正向：delivery_stop.customer_id = 1（01 门店台账）", "INSERT INTO delivery_stop (id,waybill_id,stop_no,customer_id,display_status) VALUES (9672,9610,9,1,'PENDING')")
expect_allow("16 正向：pod_correction.driver_id = 1（01 司机台账）", "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9672,9610,9610,9610,9611,1,'00000000-0000-4000-8000-000000009672','%s','202',0)" % _H)

def _mut16(desc, drop, stmts):
    """变异：内存库里让该约束恒真（CHECK 用 `CHECK (1 OR …`，可覆盖多行约束）/ 删 FOREIGN KEY 行 / DROP INDEX 后，原被拒语句应当通过。"""
    try:
        mc = sqlite3.connect(":memory:", isolation_level=None)
        mc.execute("PRAGMA foreign_keys=ON")
        if drop[0] == "ck":
            import re as _re
            _txt, _n = _re.subn(rf"(CONSTRAINT\s+{_re.escape(drop[1])}\s+CHECK\s*\()", r"\g<1>1 OR ", sqlite_ddl, count=1)
            assert _n == 1, drop
            mc.executescript(_txt)
        elif drop[0] == "ckmulti":   # 一次让多个 CHECK 恒真（语义重叠对）
            import re as _re
            _txt = sqlite_ddl
            for _n in drop[1:]:
                _txt, _k = _re.subn(rf"(CONSTRAINT\s+{_re.escape(_n)}\s+CHECK\s*\()", r"\g<1>1 OR ", _txt, count=1)
                assert _k == 1, _n
            mc.executescript(_txt)
        elif drop[0] == "idx":
            mc.executescript(sqlite_ddl); mc.execute(f"DROP INDEX {drop[1]}")
        elif drop[0] == "fk":
            _ls = sqlite_ddl.split("\n")
            _ix = [i for i, l in enumerate(_ls) if f"CONSTRAINT {drop[1]} " in l]
            assert len(_ix) == 1, (_ix, drop)
            del _ls[_ix[0]]
            mc.executescript("\n".join(_ls))
        else:
            mc.executescript(_mut_ddl(drop))
        for _q in _MASTER_MIN: mc.execute(_q)
        for _q in _S16_PARENT: mc.execute(_q)
        for _q in stmts: mc.execute(_q)
        ok(f"16 变异：去掉 {desc} 后，原被拒语句通过")
    except (sqlite3.Error, AssertionError) as _e:
        bad(f"16 变异：去掉 {desc} 后仍被拒：{_e}")

_S16 = [
    ("ck", "ck_wb_status", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9681,'WB-16-9681',9612,1,'2026-10-15','PENDING')"]),
    ("ck", "ck_wb_version", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status,waybill_version) VALUES (9682,'WB-16-9682',9613,1,'2026-10-15','CREATED',-1)"]),
    ("ck", "ck_wb_signed", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9683,'WB-16-9683',9614,1,'2026-10-15','CLOSED')"]),
    ("fk", "fk_wb_shipment", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9684,'WB-16-9684',999999,1,'2026-10-15','CREATED')"]),
    ("fk", "fk_wb_wh", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,work_date,status) VALUES (9685,'WB-16-9685',9615,999999,'2026-10-15','CREATED')"]),
    ("fk", "fk_wb_driver", ["INSERT INTO waybill (id,code,shipment_id,warehouse_id,driver_id,work_date,status) VALUES (9699,'WB-16-9699',9616,1,999999,'2026-10-15','CREATED')"]),
    ("ck", "ck_dstop_no", ["INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9681,9610,0,'PENDING')"]),
    ("ck", "ck_dstop_st", ["INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9682,9610,2,'X')"]),
    ("fk", "fk_dstop_wb", ["INSERT INTO delivery_stop (id,waybill_id,stop_no,display_status) VALUES (9683,999999,1,'PENDING')"]),
    ("fk", "fk_dstop_customer", ["INSERT INTO delivery_stop (id,waybill_id,stop_no,customer_id,display_status) VALUES (9699,9610,3,999999,'PENDING')"]),
    ("ck", "ck_dord_cseq", ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status,correct_seq) VALUES (9682,9613,9610,1,'SHIPPED',-1)"]),
    ("ck", "ck_dord_pod", ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status,valid_pod_id) VALUES (9683,9614,9610,1,'SHIPPED',9610)"]),
    ("fk", "fk_dord_out", ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9684,999999,9610,1,'SHIPPED')"]),
    ("fk", "fk_dord_wb", ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9685,9615,999999,1,'SHIPPED')"]),
    ("ck", "ck_pod_op_type", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9681,'WB-16-9610',1,'D96A',1,'X','%s','200','0')" % _H]),
    ("ck", "ck_pod_op_hash", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9682,'WB-16-9610',1,'D96B',1,'LOAD','abc','200','0')"]),
    ("ck", "ck_pod_op_seq", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9683,'WB-16-9610',1,'D96C',-1,'LOAD','%s','200','0')" % _H]),
    ("ck", "ck_pod_op_cache", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code) VALUES (9684,'WB-16-9610',1,'D96D',1,'LOAD','%s','200','X')" % _H]),
    ("ck", "ck_pod_op_temp", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9685,'WB-16-9610',1,'D96E',1,'POD_SIGN','%s','200','0',NULL,'2026-10-15 02:00:00','2026-10-16 02:00:00')" % _H]),
    ("ck", "ck_pod_op_cdl", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10) VALUES (9686,'WB-16-9610',1,'D96F',1,'POD_SIGN','%s','200','0',40)" % _H]),
    ("ck", "ck_pod_op_cdl24", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,temperature_x10,delivered_at,correct_deadline_at) VALUES (9687,'WB-16-9610',1,'D96G',1,'POD_SIGN','%s','200','0',40,'2026-10-15 02:00:00','2026-10-15 03:00:00')" % _H]),
    ("ck", "ck_pod_op_cct", ["INSERT INTO pod_op (id,waybill_no,stop_no,device_instance_id,op_seq,op_type,req_hash,http_status,biz_code,client_occurred_at) VALUES (9688,'WB-16-9610',0,'D96H',9,'LOAD','%s','200','0','2026-10-15 02:00:00.5')" % _H]),
    ("ck", "ck_podl_qty", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9681,9671,9610,9610,10000,20000,'QUALITY',40)"]),
    ("ck", "ck_podl_rsn", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9682,9611,9610,9610,10000,5000,40)"]),
    ("ck", "ck_podl_rsn_v", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,reason_code,receive_temp_c10) VALUES (9683,9612,9610,9610,10000,5000,'X',40)"]),
    ("ck", "ck_podl_temp", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9684,9613,9610,9610,10000,0,700)"]),
    ("fk", "fk_podl_pod", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9685,999999,9610,9610,10000,0,40)"]),
    ("fk", "fk_podl_obl", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9686,9614,999999,9610,10000,0,40)"]),
    ("fk", "fk_podl_lot", ["INSERT INTO pod_line (id,pod_id,outbound_line_id,lot_id,shipped_qty_milli,rejected_qty_milli,receive_temp_c10) VALUES (9687,9615,9610,999999,10000,0,40)"]),
    ("ck", "ck_podc_client", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9681,9610,9610,9610,9613,1,'00000000-0000-4000-8000-00000000967','%s','202',0)" % _H]),
    ("ck", "ck_podc_hash", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9682,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009682','%s','202',0)" % ("a" * 63)]),
    ("ck", "ck_podc_status", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance) VALUES (9683,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009683','%s','X','202',0)" % _H]),
    ("ck", "ck_podc_http", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9684,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009684','%s','200',0)" % _H]),
    ("ck", "ck_podc_auto", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance,tolerance_version) VALUES (9685,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009685','%s','200',1,NULL)" % _H]),
    ("ck", "ck_podc_seq", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9686,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009686','%s','APPLIED','202',0,0,2,'2026-10-15 09:00:00')" % _H]),
    ("ck", "ck_podc_sod", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9687,9610,9610,9610,9613,1,'00000000-0000-4000-8000-000000009687','%s','APPLIED','202',0,1,1,'2026-10-15 09:00:00')" % _H]),
    ("ck", "ck_podc_decide", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq) VALUES (9688,9610,9610,9610,9614,1,'00000000-0000-4000-8000-000000009688','%s','APPLIED','202',0,1)" % _H]),
    ("fk", "fk_podc_op", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9689,999999,9610,9610,9615,1,'00000000-0000-4000-8000-000000009689','%s','202',0)" % _H]),
    ("fk", "fk_podc_root", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9690,9610,9610,999999,9615,1,'00000000-0000-4000-8000-000000009690','%s','202',0)" % _H]),
    ("fk", "fk_podc_out", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9691,9610,9610,9610,999999,1,'00000000-0000-4000-8000-000000009691','%s','202',0)" % _H]),
    ("fk", "fk_podc_apr", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9692,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009692','%s',999999,'202',0)" % _H]),
    ("fk", "fk_podc_driver", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9699,9610,9610,9610,9614,999999,'00000000-0000-4000-8000-000000009699','%s','202',0)" % _H]),
    ("ck", "ck_podt_cat", ["INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9681,1,' X',500,100)"]),
    ("ck", "ck_podt_abs", ["INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9682,1,'A',-1,100)"]),
    ("ck", "ck_podt_pct", ["INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9683,1,'B',500,10001)"]),
    ("ck", "ck_podt_notblank", ["INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9684,1,'C',0,0)"]),
    ("fk", "fk_podt_wh", ["INSERT INTO pod_tolerance_config (id,warehouse_id,sku_category,max_abs_qty_milli,max_pct_bp) VALUES (9685,999999,'D',500,100)"]),
    ("ck", "ck_dret_seq", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9681,9610,2,0,'OPEN')"]),
    ("ck", "ck_dret_status", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9682,9610,2,2,'X')"]),
    ("ck", "ck_dret_cnt", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9683,9610,2,3,'COUNTED')"]),
    ("ck", "ck_dret_cancel", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9684,9610,2,4,'CANCELLED')"]),
    ("fk", "fk_dret_wb", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status) VALUES (9685,999999,1,5,'OPEN')"]),
    ("fk", "fk_dret_rtn", ["INSERT INTO delivery_return (id,waybill_id,stop_no,handover_seq,status,rtn_inbound_id) VALUES (9686,9610,2,6,'OPEN',999999)"]),
    ("ck", "ck_dretl_qty", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9681,9671,1,9610,-1)"]),
    ("ck", "ck_dretl_exc", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli,counted_qty_milli) VALUES (9682,9672,1,9610,5000,4000)"]),
    ("fk", "fk_dretl_ret", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9683,999999,1,9610,5000)"]),
    ("fk", "fk_dretl_sku", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9684,9673,999999,9610,5000)"]),
    ("fk", "fk_dretl_lot", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli) VALUES (9685,9674,1,999999,5000)"]),
    ("fk", "fk_dretl_exc", ["INSERT INTO delivery_return_line (id,delivery_return_id,sku_id,lot_id,reported_qty_milli,counted_qty_milli,exception_case_id) VALUES (9686,9675,1,9610,5000,5000,999999)"]),
    ("idx", "uq_podc_approval", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9693,9610,9701,9610,9616,1,'00000000-0000-4000-8000-000000009693','%s',(SELECT max(id) FROM approval_request),'202',0)" % _H,
                                 "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,approval_id,response_http,auto_tolerance) VALUES (9694,9610,9702,9610,9616,1,'00000000-0000-4000-8000-000000009694','%s',(SELECT max(id) FROM approval_request),'202',0)" % _H]),
    ("idx", "uq_podc_pending", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9695,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009695','%s','202',0)" % _H,
                                "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,response_http,auto_tolerance) VALUES (9696,9610,9610,9610,9615,1,'00000000-0000-4000-8000-000000009696','%s','202',0)" % _H]),
    ("idx", "uq_podc_seq", ["INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9697,9610,9610,9610,9616,1,'00000000-0000-4000-8000-000000009697','%s','APPLIED','202',0,1,2,'2026-10-15 09:00:00')" % _H,
                            "INSERT INTO pod_correction (id,correct_op_id,corrected_pod_id,root_pod_op_id,outbound_id,driver_id,correction_client_id,request_hash,status,response_http,auto_tolerance,correct_seq,decided_by,decided_at) VALUES (9698,9610,9610,9610,9616,1,'00000000-0000-4000-8000-000000009698','%s','APPLIED','202',0,1,2,'2026-10-15 09:00:00')" % _H]),
]
for _k, _n, _stmts in _S16:
    if _k == "ck":
        expect_block_tx(f"16 拒绝：{_n}", _stmts, _n)
        _mut16(_n, ("ck", _n), _stmts)
    elif _k == "fk":
        expect_block_tx(f"16 拒绝：{_n}", _stmts, "FOREIGN KEY constraint failed")
        _mut16(_n, ("fk", _n), _stmts)
    else:
        # 部分唯一索引：SQLite 侧守卫（`trg_podc_no_replace`）先于唯一索引命中，所以按名拒绝到的是 `pod_correction_duplicate`；
        # 索引本身的逐键实打由 2z3b 覆盖（三个部分唯一索引的谓词样本行已在前面提交），PG 段另有 `uq_podc_*` 的按名拒绝 + DROP INDEX 变异。
        expect_block_tx(f"16 拒绝：{_n}（SQLite 由 no-REPLACE 守卫先拦）", _stmts, "pod_correction_duplicate")
# ck_dord_status 与 ck_dord_pod 语义重叠：SQLite 先报 ck_dord_status（PG 先报 ck_dord_pod，见 verify.sh），各自按实际拦它的那条断言
expect_block_tx("16 拒绝：ck_dord_status（与 ck_dord_pod 重叠，SQLite 先报它）",
                ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9681,9612,9610,1,'X')"], "ck_dord_status")
_mut16("ck_dord_status + ck_dord_pod", ("ckmulti", "ck_dord_status", "ck_dord_pod"),
       ["INSERT INTO delivery_order (id,outbound_id,waybill_id,stop_no,status) VALUES (9681,9612,9610,1,'X')"])

print("=== 汇总 ===")
print(f"  通过 {passed} 项 / 失败 {failed} 项")
conn.close()
# Windows 上刚关闭的连接偶尔仍持有临时库文件句柄（WinError 32），重试几次再放弃；
# 清理失败不影响校验结论（结论由上面的 failed 计数决定）。
for _p in (dbf, dbf + "-wal", dbf + "-shm"):
    for _try in range(5):
        try:
            Path(_p).unlink(missing_ok=True)
            break
        except PermissionError:
            time.sleep(0.2)
sys.exit(0 if failed == 0 else 1)
