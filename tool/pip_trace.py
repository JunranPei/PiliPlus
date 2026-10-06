"""Reassemble text-only PiP traces. Report missing chunks instead of hiding them."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def extract(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    counts = Counter()
    pending = {}
    invalid = []
    records = 0
    geometry = []
    with source.open(encoding="utf-8-sig", errors="replace") as reader, (
        destination / "events.jsonl"
    ).open("w", encoding="utf-8") as writer:
        for number, line in enumerate(reader, 1):
            file_record = line.lstrip().startswith('{')
            stream = "dart" if file_record or "[PIP_TRACE] " in line else (
                "android" if "PiliPlusPiPTrace:" in line else None
            )
            if stream is None:
                continue
            marker = "[PIP_TRACE] " if stream == "dart" else "PiliPlusPiPTrace: "
            raw = line.strip() if file_record else line.split(marker, 1)[1].strip()
            header = re.match(r"\S+\s+\S+\s+(\d+)\s+(\d+)", line)
            pid = header.group(1) if header else "file"
            try:
                item = json.loads(raw)
                if item.get("event") == "trace.chunk":
                    key = (pid, item["seq"])
                    group = pending.setdefault(key, {"parts": {}, "total": item["parts"], "line": number})
                    group["parts"][item["part"]] = item["payload"]
                    if len(group["parts"]) != group["total"]:
                        continue
                    item = json.loads("".join(group["parts"][i] for i in range(group["total"])))
                    del pending[key]
            except (ValueError, KeyError, TypeError) as error:
                invalid.append({"line": number, "error": str(error)})
                continue
            counts[f"{stream}:{item.get('event')}"] += 1
            records += 1
            writer.write(json.dumps({"stream": stream, "pid": pid, "sourceLine": number, "record": item}, ensure_ascii=False) + "\n")
            if item.get("event") == "geometry":
                geometry.append(item)
    summary = {
        "source": str(source.resolve()), "records": records,
        "events": dict(counts), "invalidRecords": invalid,
        "incompleteChunks": [
            {"pid": key[0], "seq": key[1], "firstLine": group["line"],
             "missingParts": sorted(set(range(group["total"])) - set(group["parts"]))}
            for key, group in pending.items()
        ],
        "geometryRecords": len(geometry),
        "visualResult": "not inferred from logs",
    }
    (destination / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    with (destination / "geometry.jsonl").open("w", encoding="utf-8") as writer:
        for item in geometry:
            writer.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(json.dumps({"records": records, "geometry": len(geometry), "invalid": len(invalid), "incompleteChunks": len(pending)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    extract(args.source, args.destination)
