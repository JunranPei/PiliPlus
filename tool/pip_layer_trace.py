"""Export actual SF buffer geometry and ancestors; never capture pixel data."""
import argparse
import csv
import io
import json
from pathlib import Path
import subprocess


def query(binary, trace, sql):
    result = subprocess.run([str(binary.resolve()), str(trace.resolve()), '-Q', sql],
                            check=True, capture_output=True, encoding='utf-8')
    return list(csv.DictReader(io.StringIO(result.stdout)))


def export(binary, trace, destination, package):
    base = query(binary, trace, """
      SELECT l.id AS row_id,l.snapshot_id,ss.ts,
        EXTRACT_ARG(l.arg_set_id,'id') AS layer_id,
        EXTRACT_ARG(l.arg_set_id,'parent') AS parent_id,
        EXTRACT_ARG(l.arg_set_id,'name') AS name
      FROM surfaceflinger_layer l
      JOIN surfaceflinger_layers_snapshot ss ON ss.id=l.snapshot_id;
    """)
    all_snapshots = {}
    for row in base:
        sid, lid = int(row['snapshot_id']), int(row['layer_id'])
        snapshot = all_snapshots.setdefault(sid, {'tsNs':int(row['ts']), 'layers':{}})
        snapshot['layers'][lid] = {
            'id':lid, 'rowId':int(row['row_id']),
            'parent':int(row['parent_id']) if row['parent_id'] not in ('', '[NULL]') else None,
            'name':row['name'], 'fields':{},
        }
    snapshots, by_row = {}, {}
    for sid,snapshot in all_snapshots.items():
        selected = set()
        for lid,layer in snapshot['layers'].items():
            if package not in layer['name']:continue
            while lid in snapshot['layers'] and lid not in selected:
                selected.add(lid)
                lid = snapshot['layers'][lid]['parent']
        if not selected:continue
        scoped = {lid:snapshot['layers'][lid] for lid in selected}
        snapshots[sid] = {'tsNs':snapshot['tsNs'], 'layers':scoped}
        by_row.update({layer['rowId']:layer for layer in scoped.values()})
    ids = list(by_row)
    for start in range(0,len(ids),500):
        group = ','.join(map(str,ids[start:start+500]))
        rows = query(binary,trace,f"""
          SELECT l.id AS row_id,a.flat_key,a.display_value,a.value_type
          FROM surfaceflinger_layer l JOIN args a ON a.arg_set_id=l.arg_set_id
          WHERE l.id IN ({group});
        """)
        for row in rows:
            value = row['display_value']
            if row['value_type']=='int':value=int(value)
            elif row['value_type']=='real':value=float(value)
            by_row[int(row['row_id'])]['fields'][row['flat_key']]=value
    destination.mkdir(parents=True, exist_ok=True)
    buffers, layer_count, seen_frames = 0, 0, set()
    with (destination/'layers.jsonl').open('w', encoding='utf-8') as layers_out, (
        destination/'buffer-frames.jsonl'
    ).open('w', encoding='utf-8') as frames_out:
        for sid, snapshot in snapshots.items():
            for lid, layer in snapshot['layers'].items():
                layers_out.write(json.dumps({'snapshot': sid, 'tsNs': snapshot['tsNs'], **layer}, ensure_ascii=False)+'\n')
                layer_count += 1
                fields = layer['fields']
                if package not in layer['name'] or 'active_buffer.width' not in fields:
                    continue
                chain, visited, parent = [], {lid}, layer['parent']
                while parent in snapshot['layers'] and parent not in visited:
                    node = snapshot['layers'][parent]
                    chain.append(parent)
                    visited.add(parent)
                    parent = node['parent']
                frame = {
                    'snapshot': sid, 'tsNs': snapshot['tsNs'], 'layer': lid,
                    'name': layer['name'], 'frameNumber': fields.get('curr_frame'),
                    'bufferWidth': fields['active_buffer.width'],
                    'bufferHeight': fields.get('active_buffer.height'),
                    'parentChain': chain,
                    # No inferred identity matrices or invented missing values.
                    'geometry': {k:v for k,v in fields.items() if any(k.startswith(p) for p in
                        ('transform.', 'requested_transform.', 'buffer_transform.', 'position.',
                         'crop.', 'source_bounds.', 'bounds.', 'screen_bounds.', 'destination_frame.'))},
                }
                frames_out.write(json.dumps(frame, ensure_ascii=False)+'\n')
                buffers += 1
                seen_frames.add((lid, frame['frameNumber']))
    timing = query(binary, trace, 'SELECT * FROM actual_frame_timeline_slice ORDER BY ts;')
    transitions = query(binary, trace, 'SELECT * FROM window_manager_shell_transitions;')
    stats = query(binary, trace, "SELECT name,value,severity FROM stats WHERE value>0 AND (name LIKE '%lost%' OR name LIKE '%drop%' OR name LIKE '%overrun%');")
    for name, items in [('presented-frames',timing), ('transitions',transitions), ('trace-loss-stats',stats)]:
        (destination/f'{name}.json').write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding='utf-8')
    summary = {'snapshotsWithApp':len(snapshots), 'scopedLayers':layer_count,
               'bufferSamples':buffers, 'uniqueLayerFrames':len(seen_frames),
               'presentationRecords':len(timing), 'transitions':len(transitions),
               'lossStats':stats, 'visualResult':'not inferred from metadata'}
    (destination/'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--processor', type=Path,
                        default=Path('diagnostics/pip-20261006/trace_processor_shell.exe'))
    parser.add_argument('--package', default='com.personal.piliplus.debug')
    args = parser.parse_args()
    export(args.processor,args.trace,args.destination,args.package)
