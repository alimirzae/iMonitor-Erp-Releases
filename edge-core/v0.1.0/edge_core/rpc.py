from __future__ import annotations

import json
import os
import sys
import traceback

from .runtime import dispatch


def main() -> int:
    data_dir = os.environ.get("IMONITOR_EDGE_DATA", "data")
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
            request_id = request.get("id")
            result = dispatch(str(request.get("method", "")), request.get("params") or {}, data_dir=data_dir)
            response = {"id": request_id, "result": result}
        except Exception as exc:
            response = {
                "id": None,
                "error": {
                    "message": str(exc),
                    "type": type(exc).__name__,
                    "trace": traceback.format_exc(limit=4),
                },
            }
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
