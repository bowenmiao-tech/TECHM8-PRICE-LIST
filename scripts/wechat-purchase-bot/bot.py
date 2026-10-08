"""TECHM8 WeChat purchasing helper.

Runs on a Windows PC where the helper WeChat account is signed in to Weixin 4.x.
It watches the supplier groups the admin turned on in 采购跟单 → 设置 → 微信自动登记,
reads new messages through Windows UI Automation (nothing is injected into WeChat
and it never sends a message), and posts them to the admin-purchasing Edge
Function, which records the domestic parcels.

    python bot.py --init       create local/config.json with a new helper token
    python bot.py --probe      show what can be read right now (no clicks, no network)
    python bot.py --dry-run    run the loop but print what would be sent
    python bot.py              run
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import logging
import re
import secrets
import sys
import tempfile
import time
import urllib.error
import urllib.request
from logging.handlers import RotatingFileHandler
from pathlib import Path

import uiautomation as auto

VERSION = "1.0.0"
HERE = Path(__file__).resolve().parent
LOCAL = HERE / "local"
CONFIG_PATH = LOCAL / "config.json"
STATE_PATH = LOCAL / "state.json"
LOG_PATH = LOCAL / "bot.log"

DEFAULTS = {
    "endpoint": "https://fwlronvmgqzkleofriis.supabase.co/functions/v1/admin-purchasing",
    "token": "",
    "poll_seconds": 60,
    "idle_seconds": 120,
    "heartbeat_seconds": 300,
    "context_messages": 30,
}

UNREAD = re.compile(r"^\[(\d+)条\]")
TRACKING_HINT = re.compile(r"[A-Za-z]{0,4}\d{9,}")
MAX_TAIL = 60
MAX_IMAGES = 4
MAX_PENDING = 20

log = logging.getLogger("wechat-bot")


class UiChanged(RuntimeError):
    """Weixin no longer exposes a part of its window this helper relies on."""


class ApiError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(f"{status}: {message}")
        self.status = status


# ---------- Windows helpers ----------

class _LastInput(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]


def idle_seconds() -> float:
    info = _LastInput()
    info.cbSize = ctypes.sizeof(info)
    ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info))
    return ((ctypes.windll.kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF) / 1000


def single_instance() -> bool:
    ctypes.windll.kernel32.CreateMutexW(None, False, "TECHM8-WeChat-Purchase-Helper")
    return ctypes.windll.kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS


# ---------- reading Weixin ----------

class WeChat:
    """Everything this helper knows about the Weixin 4.x window lives here, so a
    WeChat update that renames something only needs fixing in one place."""

    def window(self):
        window = auto.WindowControl(searchDepth=1, ClassName="mmui::MainWindow")
        return window if window.Exists(1) else None

    def sessions(self, window) -> list[dict]:
        listing = window.ListControl(AutomationId="session_list")
        if not listing.Exists(2):
            raise UiChanged("找不到会话列表 (session_list)")
        found = []
        for item in listing.GetChildren():
            automation_id = item.AutomationId or ""
            if not automation_id.startswith("session_item_"):
                continue
            lines = [line.strip() for line in (item.Name or "").split("\n")]
            unread = 0
            for line in lines[1:3]:
                match = UNREAD.match(line)
                if match:
                    unread = int(match.group(1))
                    break
            found.append({"name": automation_id[len("session_item_"):], "unread": unread, "control": item})
        return found

    def current_chat(self, window) -> str | None:
        field = window.EditControl(AutomationId="chat_input_field")
        return field.Name if field.Exists(0.5) else None

    def open_chat(self, window, session: dict) -> bool:
        user32 = ctypes.windll.user32
        previous = user32.GetForegroundWindow()
        cursor = auto.GetCursorPos()
        try:
            if window.IsMinimize():
                window.Restore()
                time.sleep(0.5)
            window.SetActive()
            time.sleep(0.2)
            session["control"].Click(simulateMove=False)
        finally:
            auto.SetCursorPos(*cursor)
        opened = False
        deadline = time.time() + 4
        while time.time() < deadline:
            if self.current_chat(window) == session["name"]:
                opened = True
                break
            time.sleep(0.3)
        if previous:
            user32.SetForegroundWindow(previous)
        return opened

    def messages(self, window) -> list[dict]:
        listing = window.ListControl(AutomationId="chat_message_list")
        if not listing.Exists(2):
            raise UiChanged("找不到消息列表 (chat_message_list)")
        frame = listing.BoundingRectangle
        found = []
        for item in listing.GetChildren():
            kind_class = item.ClassName or ""
            text = (item.Name or "").strip()
            if kind_class == "mmui::ChatItemView":  # time separators and notices
                continue
            if text in ("图片", "[图片]"):
                kind = "image"
            elif "Text" in kind_class:
                kind = "text"
            else:
                kind = "other"
            rect = item.BoundingRectangle
            found.append({
                "type": kind,
                "text": text,
                "visible": rect.top >= frame.top and rect.bottom <= frame.bottom and rect.height() > 0,
                "control": item,
            })
        return found

    def capture(self, message: dict) -> dict | None:
        path = Path(tempfile.gettempdir()) / f"techm8-wechat-{secrets.token_hex(4)}.png"
        try:
            if not message["control"].CaptureToImage(str(path)):
                return None
            data = path.read_bytes()
            if len(data) > 2_800_000:
                return None
            return {"media_type": "image/png", "data": base64.b64encode(data).decode()}
        except Exception:  # noqa: BLE001 — a missed screenshot only loses that image
            log.exception("截图失败")
            return None
        finally:
            path.unlink(missing_ok=True)


def signature(message: dict) -> list[str]:
    return [message["type"], message["text"]]


def new_messages(tail: list, current: list[dict], unread: int) -> list[dict]:
    """Messages in `current` that were not seen before. `tail` is what was on
    screen last time; `unread` is WeChat's own count when the chat was closed."""
    if unread:
        return current[-unread:]
    if not tail:
        return []  # first look at this chat: remember it, send nothing
    sigs = [signature(message) for message in current]
    for overlap in range(min(len(sigs), len(tail)), 0, -1):
        if sigs[:overlap] == tail[-overlap:]:
            return current[overlap:]
    if sigs and sigs[-1] in tail:
        return []  # scrolled back into history
    return current[-10:]


# ---------- talking to the purchasing backend ----------

class Api:
    def __init__(self, config: dict):
        self.endpoint = config["endpoint"]
        self.token = config["token"]

    def post(self, action: str, payload: dict, timeout: int = 60) -> dict:
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps({"action": action, "payload": payload}).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json", "x-bot-token": self.token},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            try:
                message = json.loads(error.read().decode("utf-8")).get("message", "")
            except Exception:  # noqa: BLE001
                message = error.reason
            raise ApiError(error.code, message) from None
        if not body.get("ok"):
            raise ApiError(500, body.get("message", "request failed"))
        return body.get("result") or {}


# ---------- the loop ----------

class Helper:
    def __init__(self, config: dict, dry_run: bool):
        self.config = config
        self.dry_run = dry_run
        self.api = None if dry_run else Api(config)
        self.ui = WeChat()
        self.state = load_json(STATE_PATH, {"groups": {}, "pending": [], "watch": []})
        self.watch = set(self.state.get("watch", []))
        self.last_heartbeat = 0.0
        self.last_names: list[str] = []
        self.last_error = ""
        self.retry_after = 0.0

    def heartbeat(self, state: str, names: list[str] | None = None, force: bool = False):
        names = sorted(names) if names is not None else self.last_names
        due = time.time() - self.last_heartbeat >= self.config["heartbeat_seconds"]
        if not (force or due or names != self.last_names):
            return
        self.last_names = names
        self.last_heartbeat = time.time()
        detail = {
            "sessions": len(names),
            "watch_missing": sorted(self.watch - set(names)),
            "pending": len(self.state["pending"]),
            "last_error": self.last_error[:300],
        }
        if self.dry_run:
            log.info("[dry-run] 心跳 state=%s 会话=%d 监听=%s", state, len(names), sorted(self.watch))
            return
        try:
            result = self.api.post("bot_heartbeat", {"state": state, "version": VERSION, "groups": names, "detail": detail})
            self.watch = set(result.get("watch") or [])
            self.state["watch"] = sorted(self.watch)
        except Exception as error:  # noqa: BLE001
            log.warning("心跳失败：%s", error)

    def send(self, payload: dict) -> bool:
        group, count = payload["group"], len(payload["new_messages"])
        if self.dry_run:
            hints = sorted({hint for message in payload["new_messages"] for hint in TRACKING_HINT.findall(message["text"])})
            log.info("[dry-run] 会发送「%s」%d 条新消息，%d 张截图，疑似单号 %s", group, count, len(payload["images"]), hints or "无")
            return True
        try:
            result = self.api.post("bot_ingest", payload, timeout=170)
        except ApiError as error:
            self.last_error = f"{group}: {error}"
            if error.status in (400, 413):
                log.error("「%s」的消息被拒收，丢弃：%s", group, error)
                return True
            log.warning("「%s」发送失败，稍后重试：%s", group, error)
            return False
        except Exception as error:  # noqa: BLE001 — network trouble: keep for later
            self.last_error = f"{group}: {error}"
            log.warning("「%s」发送失败，稍后重试：%s", group, error)
            return False
        status = result.get("status")
        if status == "saved":
            log.info("「%s」登记了 %d 个包裹（%s），跳过 %d 个已有单号",
                     group, len(result.get("parcel_ids") or []), result.get("po_number") or "未关联采购单",
                     len(result.get("skipped") or []))
        else:
            log.info("「%s」%d 条新消息：%s", group, count, status)
        return True

    def flush_pending(self):
        if not self.state["pending"] or time.time() < self.retry_after:
            return
        still = []
        for payload in self.state["pending"]:
            if still or not self.send(payload):
                still.append(payload)
        self.state["pending"] = still[-MAX_PENDING:]
        if still:
            self.retry_after = time.time() + 600

    def read_group(self, window, session: dict, current: str | None) -> str | None:
        name = session["name"]
        if name != current:
            if idle_seconds() < self.config["idle_seconds"]:
                log.info("「%s」有 %d 条新消息，等电脑空闲再去看", name, session["unread"])
                return current
            if not self.ui.open_chat(window, session):
                log.warning("打不开「%s」", name)
                return self.ui.current_chat(window)
            current = name
        on_screen = self.ui.messages(window)
        group_state = self.state["groups"].setdefault(name, {})
        fresh = new_messages(group_state.get("tail", []), on_screen, session["unread"])
        group_state["tail"] = [signature(message) for message in on_screen][-MAX_TAIL:]
        if fresh:
            earlier = on_screen[:len(on_screen) - len(fresh)][-self.config["context_messages"]:]
            images = []
            for message in fresh:
                if message["type"] == "image" and message["visible"] and len(images) < MAX_IMAGES:
                    shot = self.ui.capture(message)
                    if shot:
                        images.append(shot)
            payload = {
                "group": name,
                "new_messages": [{"type": m["type"], "text": m["text"]} for m in fresh],
                "context": [{"type": m["type"], "text": m["text"]} for m in earlier],
                "images": images,
            }
            if session["unread"] > len(on_screen):
                log.info("「%s」有 %d 条未读，屏幕上只看得到 %d 条（把微信窗口拉高能看到更多）", name, session["unread"], len(on_screen))
            if not self.send(payload):
                self.state["pending"].append(payload)
                self.state["pending"] = self.state["pending"][-MAX_PENDING:]
        return current

    def cycle(self):
        window = self.ui.window()
        if not window:
            self.heartbeat("wechat_closed", [], force=True)
            log.warning("没找到微信窗口：请打开微信并登录小号")
            return
        sessions = self.ui.sessions(window)
        self.heartbeat("ok", [session["name"] for session in sessions])
        self.flush_pending()
        current = self.ui.current_chat(window)
        for session in sessions:
            if session["name"] in self.watch and (session["unread"] or session["name"] == current):
                current = self.read_group(window, session, current)
        save_json(STATE_PATH, self.state)

    def run(self, once: bool):
        log.info("微信采购助手 %s 启动%s，监听 %d 个群", VERSION, "（试运行，不发送）" if self.dry_run else "", len(self.watch))
        self.heartbeat("ok", [], force=True)
        while True:
            try:
                self.cycle()
                self.last_error = ""
            except UiChanged as error:
                self.last_error = str(error)
                log.error("微信界面和程序对不上了：%s。可能是微信升级了，需要更新程序。", error)
                self.heartbeat("ui_changed", force=True)
            except Exception as error:  # noqa: BLE001 — keep the helper alive
                self.last_error = str(error)
                log.exception("这一轮出错了")
                self.heartbeat("error", force=True)
            if once:
                break
            time.sleep(self.config["poll_seconds"])


# ---------- setup ----------

def load_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return fallback
    except json.JSONDecodeError:
        log.warning("%s 坏了，重新开始", path.name)
        return fallback


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    temp.replace(path)


def load_config() -> dict:
    config = dict(DEFAULTS)
    config.update(load_json(CONFIG_PATH, {}))
    return config


def init_config():
    config = load_config()
    if config["token"]:
        print("local/config.json 已经有令牌了。")
    else:
        config["token"] = secrets.token_urlsafe(32)
        save_json(CONFIG_PATH, config)
        print("已生成 local/config.json。")
    print("令牌指纹（复制到 采购跟单 → 设置 → 微信自动登记 → 助手电脑 登记）：")
    print(hashlib.sha256(config["token"].encode("utf-8")).hexdigest())


def probe():
    ui = WeChat()
    window = ui.window()
    if not window:
        print("没找到微信窗口。")
        return
    for session in ui.sessions(window):
        print(f"会话：{session['name']}" + (f"  [{session['unread']} 条未读]" if session["unread"] else ""))
    current = ui.current_chat(window)
    print(f"当前打开：{current or '（没有）'}")
    if current:
        shown = ui.messages(window)
        kinds = {}
        for message in shown:
            kinds[message["type"]] = kinds.get(message["type"], 0) + 1
        hints = sorted({hint for message in shown for hint in TRACKING_HINT.findall(message["text"])})
        print(f"屏幕上的消息：{len(shown)} 条 {kinds}，疑似单号：{hints or '无'}")


def setup_logging():
    LOCAL.mkdir(parents=True, exist_ok=True)
    sys.stdout.reconfigure(encoding="utf-8")
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%m-%d %H:%M:%S")
    file_handler = RotatingFileHandler(LOG_PATH, maxBytes=1_000_000, backupCount=3, encoding="utf-8")
    file_handler.setFormatter(formatter)
    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(formatter)
    log.addHandler(file_handler)
    log.addHandler(console)
    log.setLevel(logging.INFO)


def main():
    parser = argparse.ArgumentParser(description="TECHM8 微信采购助手")
    parser.add_argument("--init", action="store_true", help="生成本机配置和令牌")
    parser.add_argument("--probe", action="store_true", help="只看现在能读到什么")
    parser.add_argument("--dry-run", action="store_true", help="试运行：打印要发送的内容，不联网")
    parser.add_argument("--once", action="store_true", help="只跑一轮")
    parser.add_argument("--watch", action="append", default=[], help="试运行时要看的群名（可以写多次）")
    args = parser.parse_args()
    setup_logging()
    auto.SetGlobalSearchTimeout(2)

    if args.init:
        init_config()
        return
    if args.probe:
        probe()
        return
    config = load_config()
    if not args.dry_run and not config["token"]:
        print("还没有令牌：先运行 python bot.py --init")
        sys.exit(1)
    if not single_instance():
        print("助手已经在运行了。")
        sys.exit(0)
    helper = Helper(config, args.dry_run)
    if args.dry_run and args.watch:
        helper.watch = set(args.watch)
    helper.run(args.once)


if __name__ == "__main__":
    main()
