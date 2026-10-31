"""Align playback logs and real compositor metadata, without inventing video PTS.

python tool/ordinary_playback_analyze.py diagnostics/playback/run-01

Outputs preserve original records. A layer snapshot is a compositor state sample,
not necessarily a new buffer; FrameTimeline IDs are not media frame numbers. Dart
elapsedUs is calibrated to Android BOOTTIME with the measured method-channel RTT.
Raster phase and scheduler timestamps remain in their own domains unless their
clock mapping is explicitly provided. The analysis never concludes visual success.
"""

import argparse
from collections import Counter
import csv
import io
import json
from pathlib import Path
import subprocess
import tempfile


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def write_jsonl(path, values):
    with path.open("w", encoding="utf-8") as writer:
        for value in values:
            writer.write(json.dumps(value, ensure_ascii=False) + "\n")


def number(value):
    if value is None or value in ("", "[NULL]"):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return float(value)
        except (TypeError, ValueError):
            return None


def read_jsonl(path):
    records, invalid = [], []
    for line, raw in enumerate(path.read_text(encoding="utf-8-sig", errors="replace").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
            if not isinstance(record, dict):
                raise ValueError("record is not an object")
            records.append((line, record))
        except (ValueError, TypeError) as error:
            invalid.append({"file": path.name, "line": line, "error": str(error)})
    return records, invalid


def clock_anchors(records):
    result = []
    for _, record in records:
        if record.get("event") not in ("clock.sync", "clock.anchor"):
            continue
        native = record.get("native", {})
        sent, received = number(record.get("dartSendUs")), number(record.get("dartReceiveUs"))
        boot = number(native.get("bootNs"))
        if sent is None or received is None or boot is None or received < sent:
            continue
        result.append({"seq": record.get("seq"), "elapsedUs": (sent + received) / 2,
                       "bootNs": boot, "offsetNs": boot - (sent + received) * 500,
                       "roundTripNs": (received - sent) * 1000,
                       "uncertaintyNs": (received - sent) * 500})
    return result


def align_record(record, anchors):
    """Only map clocks with a same-process anchor; never fall back to wall time."""
    if number(record.get("bootNs")) is not None:
        return {"bootNs": number(record["bootNs"]), "clock": "native BOOTTIME",
                "uncertaintyNs": 0}
    elapsed = number(record.get("elapsedUs"))
    if elapsed is None or not anchors:
        return {"bootNs": None, "clock": "unmapped", "uncertaintyNs": None}
    # Initial configure includes file/listener setup and often has a much wider
    # round trip. Prefer the tightest observed interval; proximity only breaks
    # ties. Keep anchor distance/offset spread visible rather than assuming drift.
    anchor = min(anchors, key=lambda item: (item["uncertaintyNs"],
                                           abs(item["elapsedUs"] - elapsed)))
    return {"bootNs": round(elapsed * 1000 + anchor["offsetNs"]),
            "clock": "Dart elapsedUs via minimum-RTT same-file clock.sync",
            "uncertaintyNs": anchor["uncertaintyNs"], "anchorSeq": anchor["seq"],
            "anchorDistanceUs": abs(anchor["elapsedUs"] - elapsed)}


def changed_fields(previous, current, fields):
    return {key: {"before": previous.get(key), "after": current.get(key)}
            for key in fields if previous.get(key) != current.get(key)}


def analyze_app(directory, destination):
    counts, events, invalid, gaps, clocks, changes = Counter(), [], [], [], [], []
    loss_records = []
    previous_geometry = {}
    for path in sorted(directory.glob("*.jsonl")):
        records, file_invalid = read_jsonl(path)
        invalid.extend(file_invalid)
        anchors = clock_anchors(records)
        clocks.append({"file": path.name, "anchors": anchors,
                       "offsetRangeNs": max((a["offsetNs"] for a in anchors), default=0) -
                                        min((a["offsetNs"] for a in anchors), default=0)})
        previous_seq = None
        for line, record in records:
            seq = number(record.get("seq"))
            if seq is not None and previous_seq is not None and seq != previous_seq + 1:
                gaps.append({"file": path.name, "after": previous_seq, "before": seq})
            if seq is not None:
                previous_seq = seq
            clock = align_record(record, anchors)
            event = {"file": path.name, "line": line, **clock, "record": record}
            events.append(event)
            counts[record.get("event", "unknown")] += 1
            name = record.get("event", "")
            data = record.get("data", {})
            if not isinstance(data, dict):
                data = {}
            if (number(record.get("droppedBefore")) or number(record.get("dropped"))
                    or number(record.get("droppedRecords")) or number(data.get("dropped"))
                    or number(data.get("droppedRecords"))
                    or name in ("trace.fileLimit", "trace.collectionError", "probe.error")
                    or record.get("truncated")):
                loss_records.append({"file": path.name, "line": line, "record": record})
            if name in ("geometry", "region.paint"):
                key = (path.name, record.get("probe"), record.get("name"), record.get("owner"))
                fields = ("size", "globalLogicalRect", "flutterPhysicalRect", "matrix", "dpr",
                          "nodes", "cid", "revision", "textureId", "frameReady", "showPoster", "source")
                previous = previous_geometry.get(key)
                if previous is not None:
                    delta = changed_fields(previous, record, fields)
                    if delta:
                        changes.append({"stream": "flutter-layout-or-paint", "bootNs": clock["bootNs"],
                                        "uncertaintyNs": clock["uncertaintyNs"], "file": path.name,
                                        "seq": seq, "probe": record.get("probe"),
                                        "name": record.get("name"), "changes": delta})
                previous_geometry[key] = record
            if name.startswith(("media.", "source.", "cover.", "surface.", "texture.")):
                changes.append({"stream": "source-event", "bootNs": clock["bootNs"],
                                "uncertaintyNs": clock["uncertaintyNs"], "file": path.name,
                                "seq": seq, "record": record})
            if name == "window.geometry":
                data = record.get("data", {})
                for view in data.get("views", []):
                    key = (path.name, "android", view.get("id"))
                    fields = ("width", "height", "windowX", "windowY", "screenX", "screenY",
                              "visibleRect", "visibility", "windowVisibility", "shown", "attached",
                              "alpha", "scaleX", "scaleY", "translationX", "translationY", "translationZ",
                              "pivotX", "pivotY", "rotation", "matrix", "clip", "scrollX", "scrollY",
                              "clipChildren", "clipToPadding", "surfaceId",
                              "surfaceValid", "surfaceFrame", "textureMatrix")
                    previous = previous_geometry.get(key)
                    if previous is not None:
                        delta = changed_fields(previous, view, fields)
                        if delta:
                            changes.append({"stream": "android-view-sample", "bootNs": clock["bootNs"],
                                            "file": path.name, "seq": seq, "viewId": view.get("id"),
                                            "class": view.get("class"), "changes": delta})
                    previous_geometry[key] = view
    events.sort(key=lambda value: (value["bootNs"] is None, value["bootNs"] or 0))
    write_jsonl(destination / "app-events.jsonl", events)
    write_jsonl(destination / "flutter-raster-frames.jsonl", (
        event for event in events if event["record"].get("event") == "frame.raster"))
    write_jsonl(destination / "video-texture-consumed.jsonl", (
        event for event in events if event["record"].get("event") == "texture.consumed"))
    write_jsonl(destination / "app-changes.jsonl", changes)
    write_json(destination / "clock-anchors.json", clocks)
    return {"records": len(events), "eventCounts": dict(counts), "invalidRecords": invalid,
            "sequenceGaps": gaps, "unmappedClockRecords": sum(e["bootNs"] is None for e in events),
            "explicitLossOrCollectionErrors": loss_records,
            "changes": len(changes), "clockFiles": clocks}, events


def query(binary, trace, sql):
    # Query files avoid the Windows command-line length limit and let one query
    # fetch all selected rows without reparsing the entire trace per 500 layers.
    with tempfile.TemporaryDirectory(prefix="piliplus-playback-sql-") as temporary:
        path = Path(temporary) / "query.sql"
        path.write_text(sql, encoding="utf-8")
        result = subprocess.run([str(binary.resolve()), str(trace.resolve()), "-q", str(path)],
                                check=True, capture_output=True, encoding="utf-8", timeout=180)
    return list(csv.DictReader(io.StringIO(result.stdout)))


def scope_layers(layers, package):
    """Include app descendants and transform ancestors, keeping their roles distinct."""
    seeds = {lid for lid, layer in layers.items() if package in layer["name"]}
    children = set(seeds)
    while True:
        found = {lid for lid, layer in layers.items() if layer["parent"] in children}
        new = found - children
        if not new:
            break
        children.update(new)
    selected = set(children)
    for lid in tuple(children):
        visited = set()
        while lid in layers and lid not in visited:
            selected.add(lid)
            visited.add(lid)
            lid = layers[lid]["parent"]
    return {lid: {**layers[lid], "role": "app" if lid in seeds else
                 "app-descendant" if lid in children else "ancestor"} for lid in selected}


GEOMETRY_PREFIXES = ("transform.", "requested_transform.", "buffer_transform.", "position.",
                     "crop.", "source_bounds.", "bounds.", "screen_bounds.", "destination_frame.",
                     "active_buffer.", "color.a", "requested_color.a", "visible_region.")
LAYER_FIELDS = {"parent", "flags", "visibility_reason", "is_opaque", "z", "z_order_relative_of",
                "hwc_composition_type", "curr_frame", "is_hidden"}


def layer_measurements(layer):
    return {key: value for key, value in layer["fields"].items()
            if key in LAYER_FIELDS or key.startswith(GEOMETRY_PREFIXES)}


def analyze_system(processor, trace, destination, package):
    errors = []

    def safe_query(sql, source):
        try:
            return query(processor, trace, sql)
        except (subprocess.SubprocessError, OSError) as error:
            errors.append({"source": source, "error": str(error),
                           "stderr": getattr(error, "stderr", None)})
            return []

    clocks = safe_query("SELECT * FROM clock_snapshot;", "clocks")
    trace_clock = safe_query("SELECT * FROM metadata WHERE name='trace_time_clock_id';", "trace-clock")
    write_json(destination / "system-clocks.json", {"traceClock": trace_clock, "snapshots": clocks})
    clock_id = number(trace_clock[0].get("int_value")) if trace_clock else None
    boot_offsets = [number(c.get("ts")) - number(c.get("clock_value")) for c in clocks
                    if number(c.get("clock_id")) == 6 and number(c.get("ts")) is not None
                    and number(c.get("clock_value")) is not None]
    offset = 0 if clock_id == 6 else boot_offsets[0] if boot_offsets and len(set(boot_offsets)) == 1 else None
    base = safe_query("""SELECT l.id AS row_id,l.snapshot_id,ss.ts,
        EXTRACT_ARG(l.arg_set_id,'id') AS layer_id,
        EXTRACT_ARG(l.arg_set_id,'parent') AS parent_id,
        EXTRACT_ARG(l.arg_set_id,'name') AS name
        FROM surfaceflinger_layer l
        JOIN surfaceflinger_layers_snapshot ss ON ss.id=l.snapshot_id;""", "layers")
    snapshots = {}
    for row in base:
        lid, sid = number(row["layer_id"]), number(row["snapshot_id"])
        if lid is None or sid is None:
            continue
        snapshot = snapshots.setdefault(sid, {"tsNs": number(row["ts"]), "layers": {}})
        snapshot["layers"][lid] = {"id": lid, "rowId": number(row["row_id"]),
            "parent": number(row["parent_id"]), "name": row["name"], "fields": {}}
    by_row = {}
    for snapshot in snapshots.values():
        snapshot["layers"] = scope_layers(snapshot["layers"], package)
        by_row.update({layer["rowId"]: layer for layer in snapshot["layers"].values()})
    ids = list(by_row)
    if ids:
        group = ",".join(map(str, ids))
        rows = safe_query(f"""SELECT l.id AS row_id,a.flat_key,a.display_value,a.value_type
          FROM surfaceflinger_layer l JOIN args a ON a.arg_set_id=l.arg_set_id
          WHERE l.id IN ({group});""", "layer-fields")
        for row in rows:
            value = row["display_value"]
            if row["value_type"] in ("int", "real", "uint"):
                value = number(value)
            elif value in ("true", "false"):
                value = value == "true"
            by_row[number(row["row_id"])]["fields"][row["flat_key"]] = value
    layers, buffers, changes, previous = [], [], [], {}
    unique_buffers = set()
    for sid, snapshot in sorted(snapshots.items(), key=lambda item: item[1]["tsNs"]):
        boot = snapshot["tsNs"] - offset if offset is not None else None
        current = snapshot["layers"]
        for lid in previous.keys() - current.keys():
            changes.append({"snapshot": sid, "tsNs": snapshot["tsNs"], "bootNs": boot,
                            "layer": lid, "event": "layer.disappeared", "name": previous[lid]["name"]})
        for lid, layer in current.items():
            layers.append({"snapshot": sid, "tsNs": snapshot["tsNs"], "bootNs": boot, **layer})
            measured = layer_measurements(layer)
            if lid in previous:
                before = layer_measurements(previous[lid])
                delta = changed_fields(before, measured, set(before) | set(measured))
                if delta:
                    changes.append({"snapshot": sid, "tsNs": snapshot["tsNs"], "bootNs": boot,
                                    "layer": lid, "role": layer["role"], "event": "layer.changed",
                                    "name": layer["name"], "changes": delta})
            else:
                changes.append({"snapshot": sid, "tsNs": snapshot["tsNs"], "bootNs": boot,
                                "layer": lid, "role": layer["role"], "event": "layer.appeared",
                                "name": layer["name"], "measurements": measured})
            fields = layer["fields"]
            if layer["role"] != "ancestor" and "active_buffer.width" in fields:
                chain, visited, parent = [], {lid}, layer["parent"]
                while parent in current and parent not in visited:
                    chain.append(parent)
                    visited.add(parent)
                    parent = current[parent]["parent"]
                frame = {"snapshot": sid, "tsNs": snapshot["tsNs"], "bootNs": boot,
                         "layer": lid, "name": layer["name"], "frameNumber": fields.get("curr_frame"),
                         "bufferWidth": number(fields["active_buffer.width"]),
                         "bufferHeight": number(fields.get("active_buffer.height")),
                         "parentChain": chain, "measurements": measured,
                         "kind": "compositor buffer state, not decoded video frame"}
                buffers.append(frame)
                if frame["frameNumber"] is not None:
                    unique_buffers.add((lid, frame["frameNumber"]))
        previous = current
    write_jsonl(destination / "system-layers.jsonl", layers)
    write_jsonl(destination / "system-buffer-samples.jsonl", buffers)
    write_jsonl(destination / "system-layer-changes.jsonl", changes)
    # Include display frames referenced by the app, not unrelated apps' frames.
    escaped = package.replace("'", "''")
    timing = safe_query(f"""SELECT f.*,p.name AS process_name FROM actual_frame_timeline_slice f
        LEFT JOIN process p ON p.upid=f.upid
        WHERE instr(f.layer_name,'{escaped}')>0 OR p.name='{escaped}'
           OR p.name GLOB '{escaped}:*' ORDER BY f.ts;""", "frame-timeline")
    for frame in timing:
        frame["bootNs"] = number(frame.get("ts")) - offset if offset is not None else None
    tokens = sorted({number(row.get("display_frame_token")) for row in timing
                     if number(row.get("display_frame_token")) is not None})
    display = []
    for start in range(0, len(tokens), 500):
        group = ",".join(map(str, tokens[start:start + 500]))
        display.extend(safe_query(f"""SELECT * FROM actual_frame_timeline_slice
            WHERE display_frame_token IN ({group}) AND surface_frame_token IS NULL ORDER BY ts;""",
                                  "display-frame-timeline"))
    write_jsonl(destination / "system-app-frames.jsonl", timing)
    write_jsonl(destination / "system-display-frames.jsonl", display)
    # Some SurfaceView producers do not emit app FrameTimeline tokens. Preserve
    # system display timing separately, without pretending it belongs to the app.
    global_display = safe_query("""SELECT * FROM actual_frame_timeline_slice
        WHERE surface_frame_token IS NULL ORDER BY ts;""", "global-display-frame-timeline")
    write_jsonl(destination / "system-global-display-frames.jsonl", global_display)
    stats = safe_query("SELECT name,value,severity FROM stats WHERE value>0 AND "
                       "(name LIKE '%lost%' OR name LIKE '%drop%' OR name LIKE '%overrun%');", "trace-loss")
    write_json(destination / "system-loss-stats.json", stats)
    if not base:
        errors.append({"source": "layers", "error": "No SurfaceFlinger layer snapshots available"})
    if not timing:
        errors.append({"source": "frame-timeline", "error": "No app FrameTimeline records available"})
    return {"snapshots": len(snapshots), "scopedLayerSamples": len(layers), "bufferSamples": len(buffers),
            "uniqueLayerFrameNumbers": len(unique_buffers), "appFrameTimelineRecords": len(timing),
            "relatedDisplayFrameRecords": len(display), "layerChanges": len(changes),
            "unassociatedGlobalDisplayFrameRecords": len(global_display),
            "traceClockId": clock_id, "traceMinusBootNs": offset, "traceLossStats": stats,
            "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--package")
    parser.add_argument("--processor", type=Path,
                        default=Path("diagnostics/pip-20261006/trace_processor_shell.exe"))
    args = parser.parse_args()
    destination = args.output or args.capture / "analysis"
    if destination.exists() and any(destination.iterdir()):
        parser.error("analysis output must be new or empty; use --output for another analysis")
    destination.mkdir(parents=True, exist_ok=True)
    metadata_path = args.capture / "capture.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8-sig")) if metadata_path.exists() else {}
    package = args.package or metadata.get("package", "com.personal.piliplus.debug")
    app, _ = analyze_app(args.capture / "app", destination)
    trace = args.capture / "system.pftrace"
    system = analyze_system(args.processor, trace, destination, package) if trace.exists() else {
        "errors": [{"source": "perfetto", "error": "No system.pftrace supplied"}]}
    summary = {"package": package, "app": app, "system": system, "limitations": [
        "No pixels captured; metadata does not establish whether a visible flash occurred.",
        "A SurfaceFlinger snapshot can repeat a buffer; layer frame numbers are not video PTS.",
        "Flutter paint/layout, raster, native view samples and actual presentation are separate events.",
        "App event alignment uses callback timestamps; raster phase timestamps retain their original clock.",
        "Clock uncertainty is half method-channel RTT; clock drift outside anchors is not bounded.",
        "External video texture contents are inside the Flutter layer, not separate SurfaceFlinger layers.",
        "texture.consumed means Flutter consumed an external image, not that the display presented it.",
        "Texture timestamps use the producer's clock; sourceHint/requestContext do not prove buffer CID.",
        "Recording overhead can change timing; observed ordering and source identities remain inspectable.",
    ]}
    write_json(destination / "summary.json", summary)
    print(json.dumps({"appRecords": app["records"], "appChanges": app["changes"],
                      "appSequenceGaps": len(app["sequenceGaps"]), "system": system}))


if __name__ == "__main__":
    main()
