from __future__ import annotations

import json
import socket
import time
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from . import CORE_ABI, CORE_VERSION

@dataclass
class EdgeDevice:
    id: str
    name: str
    host: str
    port: int = 9000
    platform: str = "android"
    enabled: bool = True

def self_test() -> dict[str, Any]:
    return {"ok": True, "coreVersion": CORE_VERSION, "coreAbi": CORE_ABI, "checks": ["json", "socket", "urllib", "filesystem"]}

def _registry_path(data_dir: str) -> Path:
    root = Path(data_dir); root.mkdir(parents=True, exist_ok=True); return root / "known-edge-devices.json"

def _load_devices(data_dir: str) -> list[dict[str, Any]]:
    path = _registry_path(data_dir)
    if not path.exists(): return []
    try:
        value = json.loads(path.read_text(encoding="utf-8")); return value if isinstance(value, list) else []
    except Exception: return []

def _save_devices(data_dir: str, items: list[dict[str, Any]]) -> None:
    path = _registry_path(data_dir); tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8"); tmp.replace(path)

def _probe_http(host: str, port: int, path: str = "/api/health", timeout: float = 8.0) -> dict[str, Any]:
    started = time.perf_counter(); url = f"http://{host}:{port}{path}"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            try: payload = json.loads(body)
            except Exception: payload = {"raw": body}
            return {"ok": 200 <= response.status < 300, "statusCode": response.status, "elapsedMs": int((time.perf_counter()-started)*1000), "url": url, "payload": payload}
    except Exception as exc:
        return {"ok": False, "elapsedMs": int((time.perf_counter()-started)*1000), "url": url, "error": str(exc)}

def _probe_tcp(host: str, port: int, timeout: float = 5.0) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout): return {"ok": True, "elapsedMs": int((time.perf_counter()-started)*1000)}
    except Exception as exc: return {"ok": False, "elapsedMs": int((time.perf_counter()-started)*1000), "error": str(exc)}

def dispatch(method: str, payload: dict[str, Any] | None = None, *, data_dir: str = "data") -> dict[str, Any]:
    payload = payload or {}
    if method == "core.health": return self_test()
    if method == "devices.list": return {"ok": True, "items": _load_devices(data_dir)}
    if method == "devices.save":
        missing = [k for k in ["id","name","host"] if not str(payload.get(k, "")).strip()]
        if missing: return {"ok": False, "error": f"missing fields: {', '.join(missing)}"}
        item = asdict(EdgeDevice(id=str(payload["id"]).strip(), name=str(payload["name"]).strip(), host=str(payload["host"]).strip(), port=int(payload.get("port",9000)), platform=str(payload.get("platform","android")).strip().lower() or "android", enabled=bool(payload.get("enabled",True))))
        items = _load_devices(data_dir); index = next((i for i,x in enumerate(items) if str(x.get("id")) == item["id"]), None)
        if index is None: items.append(item)
        else: items[index] = item
        _save_devices(data_dir, items); return {"ok": True, "item": item}
    if method == "devices.delete":
        device_id = str(payload.get("id", "")).strip(); items = _load_devices(data_dir); kept = [x for x in items if str(x.get("id")) != device_id]; _save_devices(data_dir, kept); return {"ok": len(kept) != len(items)}
    if method == "devices.probe": return _probe_http(str(payload["host"]), int(payload.get("port",9000)), str(payload.get("path","/api/health")), float(payload.get("timeout",8)))
    if method == "network.tcp_probe": return _probe_tcp(str(payload["host"]), int(payload["port"]), float(payload.get("timeout",5)))
    return {"ok": False, "error": f"unsupported method: {method}", "coreAbi": CORE_ABI, "coreVersion": CORE_VERSION}

def dispatch_json(method: str, payload_json: str = "{}", data_dir: str = "data") -> str:
    try:
        payload = json.loads(payload_json or "{}")
        if not isinstance(payload, dict): payload = {}
        return json.dumps(dispatch(method, payload, data_dir=data_dir), ensure_ascii=False, separators=(",",":"))
    except Exception as exc:
        return json.dumps({"ok": False, "error": str(exc), "coreAbi": CORE_ABI, "coreVersion": CORE_VERSION}, ensure_ascii=False)
