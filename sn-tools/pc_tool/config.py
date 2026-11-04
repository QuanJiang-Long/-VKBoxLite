r"""
配置读写。配置存 config.json，改规则不用改代码。

⚠️ 路径基准：所有相对路径都必须基于【程序所在目录】，不能用 os.getcwd()。
   开发时 `python main.py` 两者相同，看不出问题；
   但 PyInstaller --onefile 打包后，运行时会把资源解压到
   %TEMP%\_MEIxxxx\ 并把它当工作目录 —— 若用相对路径，
   config.json 和 data\ 台账会写进那个临时目录，每次运行都是新目录，
   配置和台账全部丢失，且现场根本找不到文件。
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, asdict, field
from typing import Any, Optional

from sn_rule import SnRule


def app_dir() -> str:
    """程序基准目录：打包后是 exe 所在目录，开发时是源码目录。

    sys.frozen 由 PyInstaller 设置；此时 sys.executable 就是 exe 本身。
    未打包时用 __file__，避免受启动时 cwd 影响。
    """
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def app_path(*parts: str) -> str:
    """基于基准目录拼绝对路径。"""
    return os.path.join(app_dir(), *parts)


CONFIG_FILE = app_path("config.json")

DEFAULT_DATA_DIR = app_path("data")


@dataclass
class Config:
    # --- SN 规则 ---
    sn_rule: dict = field(default_factory=dict)

    # --- 串口 ---
    baud: int = 115200
    timeout_ms: int = 1500          # 单条指令等待应答的超时
    port: str = ""                  # 留空 = 每次自动识别

    # --- 烧录行为 ---
    auto_lock: bool = True          # 烧录成功后自动 LOCK:SN（Q3 确认：开）
    confirm_before_write: bool = True   # 写入前二次确认，防误点
    auto_loop: bool = False         # 生产模式：探测到新设备自动开烧
    rework_password: str = "8888"   # 返修密码（返修会解锁并强制改写 SN）
    require_operator: bool = True   # 工号不能为空（Q1）
    # SN 流水号是否每天归零。开 = 每天从 0001 开始，9999 是每天上限；
    # 关 = 旧的全局单调递增，9999 是一辈子总量。
    # 唯一性由 (日期, 流水号) 共同保证，日期嵌在 SN 里，不会撞号。
    # 留着这个开关是为了产线出问题时能只改 config.json 回退，不用重新打包。
    serial_daily_reset: bool = True

    # --- 台账 ---
    operator: str = ""              # 操作员工号
    data_dir: str = DEFAULT_DATA_DIR

    # --- MQTT 接入信息（可选，留空不影响 SN 烧录）---
    # 参照 VKBoxLite_sniff 前端"首页"的 MQTT 服务器面板。
    # ⚠️ 这三项目前只记录、不写设备：我们的设备端固件 soft_sn_demo 只有
    #    6 条 SN 指令，没有 W:MQTT / R:MQTT（那两个是 VKBoxLite_sniff 才有）。
    #    等信息收齐、MQTT 联调时再决定走设备指令还是只做记录。
    mqtt_host: str = ""                  # 服务器地址，如 dz.voltkun.com
    mqtt_port: int = 1883                # 端口
    mqtt_pass: str = ""                  # MQTT 凭证密码（平台签发）

    # --- 界面 ---
    beep_on_finish: bool = True

    # ---------------- 派生路径 ----------------
    @property
    def rule(self) -> SnRule:
        return SnRule.from_dict(self.sn_rule)

    @property
    def counter_file(self) -> str:
        return os.path.join(self.data_dir, "counter.json")

    @property
    def ledger_file(self) -> str:
        return os.path.join(self.data_dir, "ledger.csv")

    @property
    def log_file(self) -> str:
        return os.path.join(self.data_dir, "session.log")

    def to_dict(self) -> dict:
        d = asdict(self)
        # rule 是 property，不进 asdict；确保 sn_rule 有值
        if not d.get("sn_rule"):
            d["sn_rule"] = self.rule.to_dict()
        # ⚠️ data_dir 必须回写空串，不能回写解析后的绝对路径。
        #    from_dict 会把空 data_dir 解析成基准目录存进对象，
        #    若 to_dict 原样吐回去，任何一次 save_config（含自检脚本）
        #    都会把绝对路径固化进 config.json。
        #    后果：项目换个目录、或打包后 exe 移到别处，配置仍指向
        #    旧绝对路径，台账静默写到老地方去。
        #    存空串 = "按当前程序位置动态解析"，才是可移植的写法。
        try:
            if os.path.abspath(str(self.data_dir)) == DEFAULT_DATA_DIR:
                d["data_dir"] = ""
        except (TypeError, ValueError):
            pass
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Config":
        d = dict(d or {})
        known = {f for f in cls.__dataclass_fields__}  # noqa: C401
        # data_dir 留空 = 用默认基准目录（打包/开发都正确）。
        # 显式填了相对路径也按基准目录重算，见 from_dict 的迁移逻辑。
        raw_dir = d.get("data_dir")
        if raw_dir and not os.path.isabs(str(raw_dir)):
            d["data_dir"] = app_path(str(raw_dir))
        elif not raw_dir:
            d["data_dir"] = DEFAULT_DATA_DIR
        return cls(**{k: v for k, v in d.items() if k in known})


def load_config(path: Optional[str] = None) -> Config:
    # ⚠️ 不能用 `path: str = CONFIG_FILE` 做默认参数：Python 的默认值在
    #    【函数定义时】求值并冻结。以后修改 CONFIG_FILE（测试隔离、
    #    切换配置目录）对它毫无作用，load/save 仍走导入时那个路径 ——
    #    实测因此让冒烟测试写脏了真实 config.json。
    #    改成 None + 函数体内取值，每次调用才重新读当前 CONFIG_FILE。
    if path is None:
        path = CONFIG_FILE
    if not os.path.exists(path):
        c = Config()
        save_config(c, path)
        return c
    try:
        with open(path, "r", encoding="utf-8") as f:
            return Config.from_dict(json.load(f))
    except (json.JSONDecodeError, OSError) as e:
        # 配置损坏不阻塞开工：备份坏的，用默认值，并在日志里留痕
        backup = path + ".broken"
        try:
            os.replace(path, backup)
        except OSError:
            pass
        print(f"[config] 配置文件损坏，已备份为 {backup}，使用默认配置: {e}")
        c = Config()
        save_config(c, path)
        return c


def save_config(c: Config, path: Optional[str] = None) -> None:
    # 同上：默认参数必须在调用时求值，不能用 CONFIG_FILE 直接做默认值
    if path is None:
        path = CONFIG_FILE
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(c.to_dict(), f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)   # 原子替换，避免写一半断电留下坏文件


if __name__ == "__main__":
    # 自检目录用当前目录下的临时子目录：有些环境（沙箱/受限账户）
    # 不允许在系统 Temp 下建目录，用本地目录最稳
    import shutil

    td = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_selftest_tmp")
    shutil.rmtree(td, ignore_errors=True)
    os.makedirs(td, exist_ok=True)
    try:
        p = os.path.join(td, "config.json")
        c1 = Config()
        c1.operator = "OP007"
        c1.sn_rule = c1.rule.to_dict()
        save_config(c1, p)

        c2 = load_config(p)
        assert c2.operator == "OP007", c2.operator
        assert c2.rule.prefix == "VL", c2.rule.prefix
        assert c2.rule.serial_digits == 3, c2.rule.serial_digits
        assert c2.auto_lock is True

        # 损坏文件应被备份并回退默认值，不抛异常
        with open(p, "w", encoding="utf-8") as f:
            f.write("{ this is not json")
        c3 = load_config(p)
        assert c3.operator == "", c3.operator
        assert os.path.exists(p + ".broken")

        # 未知字段被忽略，不会因旧配置多一个键就崩
        with open(p, "w", encoding="utf-8") as f:
            json.dump({"operator": "X", "no_such_field": 1}, f)
        c4 = load_config(p)
        assert c4.operator == "X"
        assert not hasattr(c4, "no_such_field")

        # 默认配置落盘后能原样读回
        c5 = Config()
        p5 = os.path.join(td, "default.json")
        save_config(c5, p5)
        assert load_config(p5).rule.serial_digits == 3
        assert load_config(p5).rule.prefix == "VL"

        print("config 自检: 全部通过")
    finally:
        shutil.rmtree(td, ignore_errors=True)
