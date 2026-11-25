"""Optional live analysis events; keep stdout for the JSON result."""
import json
import os
from datetime import datetime


def report(fraction, text):
    if not (path := os.environ.get("MAEKI_PROGRESS_FILE")):
        return
    record = {"progress": fraction, "time": datetime.now().strftime("%H:%M:%S"), "text": text}
    try:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass
