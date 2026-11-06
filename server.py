#!/usr/bin/env python3
"""Loopback-only web controller for the Attack Shark X6."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
BRIDGE_SOURCE = ROOT / "bridge" / "X6Bridge.swift"
BRIDGE_BINARY = ROOT / ".build" / "X6Bridge"
APP_ORIGIN = ""
TOKEN = secrets.token_urlsafe(32)
STATE_LOCK = threading.RLock()
DEVICE_LOCK = threading.Lock()
BRIDGE_ERROR = ""

ACTION_IDS = {
    "off": 0x01, "left": 0x02, "right": 0x03, "middle": 0x04,
    "backward": 0x05, "forward": 0x06, "double_click": 0x07,
    "fire": 0x08, "scroll_up": 0x09, "scroll_down": 0x0A,
    "dpi_cycle": 0x0D, "dpi_plus": 0x0E, "dpi_minus": 0x0F,
    "media_player": 0x15, "previous_track": 0x16, "next_track": 0x17,
    "play_pause": 0x18, "stop": 0x19, "mute": 0x1A,
    "volume_up": 0x1B, "volume_down": 0x1C,
    "browser_calculator": 0x1D, "browser_email": 0x1E,
    "browser_forward": 0x20, "browser_backward": 0x21,
    "browser_stop": 0x22, "browser_computer": 0x23,
    "browser_refresh": 0x24, "browser_home": 0x25,
    "browser_search": 0x26,
}
ACTION_LABELS = {
    "off": "Отключено", "left": "Левый клик", "right": "Правый клик",
    "middle": "Нажатие колеса", "backward": "Назад", "forward": "Вперёд",
    "double_click": "Двойной клик", "fire": "Fire", "scroll_up": "Прокрутка вверх",
    "scroll_down": "Прокрутка вниз", "dpi_cycle": "Следующий DPI",
    "dpi_plus": "DPI +", "dpi_minus": "DPI −", "media_player": "Медиаплеер",
    "previous_track": "Предыдущий трек", "next_track": "Следующий трек",
    "play_pause": "Пуск / пауза", "stop": "Стоп", "mute": "Без звука",
    "volume_up": "Громкость +", "volume_down": "Громкость −",
    "browser_calculator": "Калькулятор", "browser_email": "Почта",
    "browser_forward": "Вперёд в браузере", "browser_backward": "Назад в браузере",
    "browser_stop": "Остановить загрузку", "browser_computer": "Этот компьютер",
    "browser_refresh": "Обновить страницу", "browser_home": "Домашняя страница",
    "browser_search": "Поиск",
}
BUTTON_GROUPS = [1, 2, 3, 7, 8, 5, 6]
BUTTON_ONE_ACTIONS = {
    "off", "left", "right", "middle", "backward", "forward", "double_click",
    "fire", "browser_calculator", "browser_email", "browser_forward",
    "browser_backward", "browser_stop", "browser_computer", "browser_refresh",
    "browser_home", "browser_search",
}
LIGHT_MODES = {
    "off": {"label": "Выключено", "hex": "050f010003a800ff00010401af"},
    "fixed": {"label": "Постоянный", "hex": "050f011003a800ff00010401bf"},
    "breathing": {"label": "Дыхание", "hex": "050f012003a800ff00010401cf"},
    "neon": {"label": "Неон", "hex": "050f013002a80000ff010401de"},
    "color_cycle": {"label": "Смена цветов", "hex": "050f014003a80000ff010401ef"},
    "dpi_static": {"label": "Цвет по DPI", "hex": "050f015002a80000ff010401fe"},
    "dpi_breathing": {"label": "Дыхание по DPI", "hex": "050f016004a80000ff01040210"},
}
MODE_BY_ID = {0x00: "off", 0x10: "fixed", 0x20: "breathing", 0x30: "neon",
              0x40: "color_cycle", 0x50: "dpi_static", 0x60: "dpi_breathing"}
STAGE_COLORS = [
    [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
    [0, 255, 255], [255, 0, 255], [255, 64, 0], [255, 255, 255],
]
BASE_BUTTONS = ["left", "right", "middle", "forward", "backward", "dpi_plus", "dpi_minus"]


def default_config() -> dict:
    return {
        "dpi": {
            "stages": [800, 1200, 1600, 3200, 5600, 26000],
            "activeStage": 2,
            "angleSnap": False,
            "rippleControl": False,
            "lodMm": 2,
        },
        "pollingHz": 1000,
        "lighting": {
            "mode": "breathing",
            "color": "#00FF00",
            "speed": 6,
            "sleepMinutes": 0.5,
            "debounceMs": 8,
        },
        "buttons": copy.deepcopy(BASE_BUTTONS),
    }


def reset_config() -> dict:
    config = default_config()
    config["lighting"]["mode"] = "dpi_static"
    config["lighting"]["debounceMs"] = 4
    return config


def app_support_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "X6 Control"
    return Path.home() / ".local" / "share" / "x6-control"


STORE_PATH = app_support_dir() / "profiles.json"


def load_store() -> dict:
    try:
        with STORE_PATH.open("r", encoding="utf-8") as source:
            value = json.load(source)
        if value.get("version") == 1 and isinstance(value.get("devices"), dict):
            return value
    except (FileNotFoundError, OSError, ValueError, AttributeError):
        pass
    return {"version": 1, "devices": {}}


STORE = load_store()


def save_store() -> None:
    STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = STORE_PATH.with_suffix(".tmp")
    data = json.dumps(STORE, ensure_ascii=False, indent=2).encode("utf-8")
    descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, STORE_PATH)


def device_key(device: dict) -> str:
    serial = (device.get("serial") or "").strip()
    if serial:
        return f"{device['vendorID']}:{device['productID']}:serial:{serial}"
    return f"{device['vendorID']}:{device['productID']}:location:{device['locationID']}"


def ensure_device_record(key: str) -> dict:
    record = STORE["devices"].get(key)
    if record is None:
        profile_id = "standard"
        record = {
            "activeProfile": profile_id,
            "profiles": [{"id": profile_id, "name": "Стандарт X6", "config": default_config()}],
        }
        STORE["devices"][key] = record
        save_store()
    if not record.get("profiles"):
        record["profiles"] = [{"id": "standard", "name": "Стандарт X6", "config": default_config()}]
        record["activeProfile"] = "standard"
        save_store()
    if not any(p["id"] == record.get("activeProfile") for p in record["profiles"]):
        record["activeProfile"] = record["profiles"][0]["id"]
        save_store()
    return record


def selected_profile(record: dict, profile_id: str | None = None) -> dict:
    target = profile_id or record["activeProfile"]
    for profile in record["profiles"]:
        if profile["id"] == target:
            return profile
    raise ValueError("Локальный профиль не найден")


def validate_config(config: object) -> dict:
    if not isinstance(config, dict):
        raise ValueError("Профиль имеет неверный формат")
    try:
        dpi, lighting, buttons = config["dpi"], config["lighting"], config["buttons"]
        stages = dpi["stages"]
        if not isinstance(stages, list) or len(stages) != 6:
            raise ValueError("Нужно задать шесть уровней DPI")
        checked_stages = []
        for value in stages:
            if isinstance(value, bool) or not isinstance(value, int) or value < 50 or value > 26000 or value % 50:
                raise ValueError("DPI задаётся от 50 до 26 000 с шагом 50")
            checked_stages.append(value)
        active = dpi["activeStage"]
        if isinstance(active, bool) or not isinstance(active, int) or not 1 <= active <= 6:
            raise ValueError("Активный уровень DPI должен быть от 1 до 6")
        if not isinstance(dpi["angleSnap"], bool) or not isinstance(dpi["rippleControl"], bool):
            raise ValueError("Параметры сенсора должны быть переключателями")
        if isinstance(dpi["lodMm"], bool) or not isinstance(dpi["lodMm"], int) or dpi["lodMm"] not in (1, 2):
            raise ValueError("Высота отрыва должна быть 1 или 2 мм")
        polling = config["pollingHz"]
        if isinstance(polling, bool) or not isinstance(polling, int) or polling not in (125, 250, 500, 1000):
            raise ValueError("Частота опроса должна быть 125, 250, 500 или 1000 Гц")
        mode = lighting["mode"]
        if mode not in LIGHT_MODES:
            raise ValueError("Неизвестный режим подсветки")
        color = lighting["color"]
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ValueError("Цвет должен быть в формате #RRGGBB")
        speed = lighting["speed"]
        if isinstance(speed, bool) or not isinstance(speed, int) or not 1 <= speed <= 8:
            raise ValueError("Скорость эффекта должна быть от 1 до 8")
        sleep = lighting["sleepMinutes"]
        if isinstance(sleep, bool) or not isinstance(sleep, (int, float)) or not 0.5 <= sleep <= 60 or sleep * 2 != int(sleep * 2):
            raise ValueError("Таймер сна задаётся от 0,5 до 60 минут с шагом 0,5")
        debounce = lighting["debounceMs"]
        if isinstance(debounce, bool) or not isinstance(debounce, int) or not 2 <= debounce <= 25:
            raise ValueError("Задержка кнопок задаётся от 2 до 25 мс")
        if not isinstance(buttons, list) or len(buttons) != 7:
            raise ValueError("Нужно задать действия для семи кнопок")
        for index, action in enumerate(buttons):
            if action not in ACTION_IDS:
                raise ValueError(f"Неизвестное действие для кнопки {index + 1}")
            if index == 0 and action not in BUTTON_ONE_ACTIONS:
                raise ValueError("Для левой кнопки доступны базовые и браузерные действия")
        return copy.deepcopy(config)
    except (KeyError, TypeError) as error:
        raise ValueError("В профиле отсутствуют обязательные настройки") from error


def encode_dpi(config: dict) -> bytes:
    dpi = config["dpi"]
    report = bytearray(52)
    report[0:3] = bytes((0x04, 0x38, 0x01))
    angle = 1 if dpi["angleSnap"] else 0
    report[3] = angle
    report[4] = 1 if dpi["rippleControl"] else 0
    report[5] = 0x3F
    report[6] = angle
    report[7] = 1 if dpi["lodMm"] == 2 else 0
    values = list(dpi["stages"]) + [50, 50]
    for index, value in enumerate(values):
        raw = value // 50 - 1
        report[8 + index] = raw & 0xFF
        report[16 + index] = (raw >> 8) & 0xFF
    report[24] = dpi["activeStage"]
    for index, rgb in enumerate(STAGE_COLORS):
        report[25 + index * 3: 28 + index * 3] = bytes(rgb)
    report[49] = 1
    checksum = sum(report[3:50]) & 0xFFFF
    report[50:52] = checksum.to_bytes(2, "big")
    return bytes(report)


def encode_lighting(config: dict, reset: bool = False) -> bytes:
    lighting = config["lighting"]
    if reset:
        report = bytearray.fromhex("050f015003a800ff00010401ff")
    else:
        report = bytearray.fromhex(LIGHT_MODES[lighting["mode"]]["hex"])
        report[4] = (report[4] & 0xF0) | (9 - lighting["speed"])
        report[9] = int(lighting["sleepMinutes"] * 2)
        report[10] = lighting["debounceMs"]
        if lighting["mode"] in ("fixed", "breathing"):
            report[6:9] = bytes.fromhex(lighting["color"][1:])
        checksum = sum(report[3:11]) & 0xFFFF
        report[11:13] = checksum.to_bytes(2, "big")
    return bytes(report)


def encode_polling(config: dict) -> bytes:
    divisor = 1000 // config["pollingHz"]
    return bytes((0x06, 0x09, 0x01, divisor, (~divisor) & 0xFF, 0, 0, 0, 0))


def encode_buttons(config: dict) -> bytes:
    # The first three actions are followed by reserved groups; bytes are kept
    # from the documented factory capture, including unmapped group 4.
    report = bytearray.fromhex(
        "083b010200000300000400000d00000e00000f00000600000500003c00000100000100000100000100000100000100000100000a00000900000094"
    )
    for index, action in enumerate(config["buttons"]):
        offset = 3 + (BUTTON_GROUPS[index] - 1) * 3
        report[offset] = ACTION_IDS[action]
    checksum = sum(report[3:57]) & 0xFFFF
    report[57:59] = checksum.to_bytes(2, "big")
    return bytes(report)


def ensure_bridge() -> None:
    global BRIDGE_ERROR
    if BRIDGE_BINARY.exists():
        return
    try:
        BRIDGE_BINARY.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["swiftc", str(BRIDGE_SOURCE), "-framework", "IOKit", "-o", str(BRIDGE_BINARY)],
            cwd=str(ROOT), capture_output=True, text=True, timeout=45,
        )
        if result.returncode != 0:
            BRIDGE_ERROR = (result.stderr or result.stdout or "Компилятор Swift завершился с ошибкой").strip()[-1600:]
            return
        BRIDGE_ERROR = ""
    except (OSError, subprocess.TimeoutExpired) as error:
        BRIDGE_ERROR = str(error)


def bridge_call(arguments: list[str], timeout: float = 5.0) -> dict:
    ensure_bridge()
    if BRIDGE_ERROR:
        raise RuntimeError("Не удалось подготовить USB-мост: " + BRIDGE_ERROR)
    try:
        result = subprocess.run([str(BRIDGE_BINARY), *arguments], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"USB-мост X6 не ответил: {error}") from error
    try:
        response = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError) as error:
        detail = (result.stderr or result.stdout or "пустой ответ").strip()[-600:]
        raise RuntimeError(f"Не удалось прочитать ответ USB-моста: {detail}") from error
    if result.returncode != 0 or not response.get("ok"):
        raise RuntimeError(response.get("error", "USB-мост X6 завершился с ошибкой"))
    return response


def online_devices() -> list[dict]:
    with DEVICE_LOCK:
        response = bridge_call(["list"])
    result = []
    for source in response.get("devices", []):
        item = dict(source)
        item["deviceKey"] = device_key(item)
        result.append(item)
    return result


def apply_reports(device: dict, reports: list[bytes]) -> dict:
    acknowledged = []
    with DEVICE_LOCK:
        for report in reports:
            response = bridge_call(["send", str(device["locationID"]), report.hex()], timeout=7.0)
            report_id = response.get("reportID", report[0])
            if not response.get("acknowledged"):
                raise RuntimeError(json.dumps({
                    "message": f"Команда 0x{report_id:02x} отправлена, но подтверждение мыши не пришло. Устройство могло принять настройку.",
                    "partial": acknowledged,
                    "unconfirmed": f"0x{report_id:02x}",
                }, ensure_ascii=False))
            acknowledged.append(f"0x{report_id:02x}")
    return {"acknowledged": acknowledged}


def profile_record_for(key: str) -> dict:
    with STATE_LOCK:
        return ensure_device_record(key)


def public_record(record: dict) -> dict:
    return {
        "activeProfile": record["activeProfile"],
        "profiles": [{"id": p["id"], "name": p["name"]} for p in record["profiles"]],
    }


def get_state(query: dict) -> dict:
    try:
        devices = online_devices()
        bridge_error = ""
    except RuntimeError as error:
        devices = []
        bridge_error = str(error)
    requested_location = query.get("location", [""])[0]
    requested_key = query.get("deviceKey", [""])[0]
    selected = next((d for d in devices if str(d["locationID"]) == requested_location), None) if requested_location else None
    if not selected and requested_key:
        selected = next((d for d in devices if d["deviceKey"] == requested_key), None)
    if not selected and len(devices) == 1:
        selected = devices[0]

    key = selected["deviceKey"] if selected else requested_key
    if not key and len(devices) > 1:
        return {"ok": True, "devices": devices, "selected": None, "profile": None,
                "profileList": [], "bridgeError": bridge_error, "message": "Выберите подключённую мышь или приёмник."}
    if not key:
        return {"ok": True, "devices": devices, "selected": None, "profile": default_config(),
                "profileList": [], "bridgeError": bridge_error, "message": "Подключите Attack Shark X6, чтобы отправлять настройки."}

    with STATE_LOCK:
        record = ensure_device_record(key)
        profile = selected_profile(record)
        return {
            "ok": True,
            "devices": devices,
            "selected": selected,
            "profile": copy.deepcopy(profile["config"]),
            "profileID": profile["id"],
            "profileName": profile["name"],
            "profileList": public_record(record),
            "bridgeError": bridge_error,
            "online": selected is not None,
            "deviceKey": key,
            "message": "Настройки профиля хранятся на Mac. X6 не сообщает сохранённые значения для чтения.",
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "X6Control/1.0"

    def log_message(self, _format: str, *_args) -> None:
        return

    def _headers(self, content_type: str = "application/json; charset=utf-8", length: int = 0) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")

    def _json(self, status: int, value: dict) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._headers(length=len(body))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if self.headers.get("Host", "") != f"127.0.0.1:{self.server.server_port}":
            self._json(403, {"ok": False, "error": "Запрос разрешён только через локальный адрес приложения."})
            return False
        origin = self.headers.get("Origin")
        if origin and origin != f"http://127.0.0.1:{self.server.server_port}":
            self._json(403, {"ok": False, "error": "Источник запроса не совпадает с приложением."})
            return False
        if self.headers.get("X-X6-Token", "") != TOKEN:
            self._json(403, {"ok": False, "error": "Сессия приложения недействительна. Перезапустите его."})
            return False
        return True

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 64 * 1024:
            raise ValueError("Пустой или слишком большой запрос")
        value = json.loads(self.rfile.read(length).decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("Тело запроса должно быть JSON-объектом")
        return value

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            key = parse_qs(parsed.query).get("k", [""])[0]
            if not secrets.compare_digest(key, TOKEN):
                self.send_response(303)
                self.send_header("Location", f"/?k={TOKEN}")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return
            body = (ROOT / "public" / "index.html").read_bytes()
            self.send_response(200)
            self._headers("text/html; charset=utf-8", len(body))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path.startswith("/api/"):
            if not self._authorized():
                return
            if parsed.path == "/api/state":
                self._json(200, get_state(parse_qs(parsed.query)))
            else:
                self._json(404, {"ok": False, "error": "Маршрут не найден"})
            return
        assets = {
            "/app.css": ("app.css", "text/css; charset=utf-8"),
            "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        }
        if parsed.path in assets:
            name, content_type = assets[parsed.path]
            body = (ROOT / "public" / name).read_bytes()
            self.send_response(200)
            self._headers(content_type, len(body))
            self.end_headers()
            self.wfile.write(body)
            return
        self._json(404, {"ok": False, "error": "Страница не найдена"})

    def do_POST(self) -> None:
        if not self._authorized():
            return
        try:
            body = self._body()
            path = urlparse(self.path).path
            if path == "/api/profile/config":
                key, profile_id = str(body.get("deviceKey", "")), str(body.get("profileID", ""))
                config = validate_config(body.get("config"))
                with STATE_LOCK:
                    record = ensure_device_record(key)
                    profile = selected_profile(record, profile_id)
                    profile["config"] = config
                    save_store()
                self._json(200, {"ok": True})
                return
            if path == "/api/profile/manage":
                result = self._manage_profile(body)
                self._json(200, result)
                return
            if path == "/api/apply":
                result = self._apply(body)
                self._json(200, result)
                return
            if path == "/api/reset":
                result = self._reset(body)
                self._json(200, result)
                return
            self._json(404, {"ok": False, "error": "Маршрут не найден"})
        except (ValueError, KeyError, TypeError) as error:
            self._json(400, {"ok": False, "error": str(error)})
        except RuntimeError as error:
            try:
                details = json.loads(str(error))
                self._json(502, {"ok": False, **details})
            except ValueError:
                self._json(502, {"ok": False, "error": str(error)})
        except Exception as error:  # keep implementation failures visible to the UI
            self._json(500, {"ok": False, "error": f"Ошибка приложения: {error}"})

    def _manage_profile(self, body: dict) -> dict:
        key = str(body.get("deviceKey", ""))
        operation = body.get("operation")
        with STATE_LOCK:
            record = ensure_device_record(key)
            profile_id = str(body.get("profileID", record["activeProfile"]))
            profile = selected_profile(record, profile_id)
            if operation == "create":
                name = str(body.get("name", "Новый профиль")).strip()[:40]
                if not name:
                    raise ValueError("Введите название профиля")
                new_profile = {"id": uuid.uuid4().hex[:12], "name": name, "config": copy.deepcopy(profile["config"])}
                record["profiles"].append(new_profile)
                record["activeProfile"] = new_profile["id"]
            elif operation == "duplicate":
                name = str(body.get("name", profile["name"] + " копия")).strip()[:40]
                new_profile = {"id": uuid.uuid4().hex[:12], "name": name or "Копия", "config": copy.deepcopy(profile["config"])}
                record["profiles"].append(new_profile)
            elif operation == "rename":
                name = str(body.get("name", "")).strip()[:40]
                if not name:
                    raise ValueError("Введите название профиля")
                profile["name"] = name
            elif operation == "activate":
                record["activeProfile"] = profile_id
            elif operation == "delete":
                if len(record["profiles"]) <= 1:
                    raise ValueError("Нельзя удалить последний профиль")
                if profile_id == record["activeProfile"]:
                    raise ValueError("Сначала переключитесь на другой профиль")
                record["profiles"] = [p for p in record["profiles"] if p["id"] != profile_id]
            else:
                raise ValueError("Неизвестная операция с профилем")
            save_store()
            current = selected_profile(record)
            return {"ok": True, "profile": copy.deepcopy(current["config"]),
                    "profileID": current["id"], "profileName": current["name"],
                    "profileList": public_record(record)}

    def _get_selected_online_device(self, body: dict) -> dict:
        location = str(body.get("locationID", ""))
        key = str(body.get("deviceKey", ""))
        devices = online_devices()
        match = next((d for d in devices if str(d["locationID"]) == location and d["deviceKey"] == key), None)
        if match is None:
            raise RuntimeError("Выбранная мышь отключена или изменилась. Обновите список устройств.")
        return match

    def _apply(self, body: dict) -> dict:
        device = self._get_selected_online_device(body)
        key = device["deviceKey"]
        section = body.get("section")
        with STATE_LOCK:
            record = ensure_device_record(key)
            profile = selected_profile(record, str(body.get("profileID", "")))
            config = validate_config(profile["config"])
        if section == "performance":
            reports = [encode_dpi(config), encode_polling(config)]
        elif section == "lighting":
            reports = [encode_lighting(config)]
        elif section == "controls":
            reports = [encode_dpi(config), encode_lighting(config)]
        elif section == "buttons":
            reports = [encode_buttons(config)]
        elif section == "profile":
            reports = [encode_dpi(config), encode_lighting(config), encode_polling(config), encode_buttons(config)]
        else:
            raise ValueError("Неизвестная группа настроек")
        result = apply_reports(device, reports)
        return {"ok": True, **result}

    def _reset(self, body: dict) -> dict:
        device = self._get_selected_online_device(body)
        key = device["deviceKey"]
        config = reset_config()
        reports = [encode_dpi(config), encode_lighting(config, reset=True), encode_polling(config), encode_buttons(config)]
        result = apply_reports(device, reports)
        with STATE_LOCK:
            record = ensure_device_record(key)
            profile = selected_profile(record, str(body.get("profileID", "")))
            profile["config"] = copy.deepcopy(config)
            save_store()
            current = selected_profile(record)
        return {"ok": True, **result, "profile": copy.deepcopy(current["config"]),
                "profileID": current["id"], "profileName": current["name"]}


def main() -> None:
    global APP_ORIGIN
    parser = argparse.ArgumentParser(description="Локальная панель управления Attack Shark X6")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true", help="не открывать браузер автоматически")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    APP_ORIGIN = f"http://127.0.0.1:{server.server_port}"
    url = f"{APP_ORIGIN}/?k={TOKEN}"
    print(f"X6 Control запущен: {url}", flush=True)
    print("Настройки мыши читаются не поддерживаются; команды отправляются только по нажатию кнопки.", flush=True)
    if not args.no_open:
        webbrowser.open(url, new=2)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
