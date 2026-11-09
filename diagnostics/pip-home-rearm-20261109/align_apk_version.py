from pathlib import Path
import argparse
import hashlib
import struct
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('--version-code', type=int, default=7)
    args = parser.parse_args()
    sdk = Path('D:/Android_studio_sdk/build-tools/36.1.0')
    with zipfile.ZipFile(args.source) as source:
        manifest = bytearray(source.read('AndroidManifest.xml'))
        off = 8
        version_name_id = None
        modified = 0
        while off < len(manifest):
            typ, header, size = struct.unpack_from('<HHI', manifest, off)
            if typ == 0x0180:
                ids = list(struct.unpack_from('<' + 'I' * ((size - header) // 4), manifest, off + header))
                version_name_id = ids.index(0x0101021b)
            if typ == 0x0102 and version_name_id is not None:
                ext = off + 16
                attr_start, attr_size, count = struct.unpack_from('<HHH', manifest, ext + 8)
                for i in range(count):
                    attr = ext + attr_start + i * attr_size
                    if struct.unpack_from('<I', manifest, attr + 4)[0] == version_name_id:
                        struct.pack_into('<I', manifest, attr + 16, args.version_code)
                        modified += 1
            off += size
        if modified != 1:
            raise RuntimeError(f'AndroidManifest versionCode attributes changed: {modified}')
        unsigned = args.target.with_name(args.target.stem + '-unsigned.apk')
        with zipfile.ZipFile(unsigned, 'w') as target:
            for info in source.infolist():
                if info.filename == 'AndroidManifest.xml':
                    target.writestr(info, bytes(manifest))
                elif not (info.filename.startswith('META-INF/') and info.filename.endswith(('.SF', '.RSA', '.DSA', '.EC'))):
                    target.writestr(info, source.read(info.filename))
    aligned = args.target.with_name(args.target.stem + '-aligned.apk')
    subprocess.run([str(sdk / 'zipalign.exe'), '-f', '-P', '16', '4', str(unsigned), str(aligned)], check=True)
    subprocess.run([
        'D:/Program Files/Android Studio/jbr/bin/java.exe', '-jar', str(sdk / 'lib/apksigner.jar'),
        'sign', '--ks', 'C:/Users/10540/.android/debug.keystore', '--ks-key-alias', 'androiddebugkey',
        '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', str(args.target), str(aligned),
    ], check=True)
    subprocess.run(['D:/Program Files/Android Studio/jbr/bin/java.exe', '-jar', str(sdk / 'lib/apksigner.jar'), 'verify', str(args.target)], check=True)
    print(hashlib.sha256(args.target.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
