"""Prepare the pinned Microsoft native ConPTY dependency (build-time only).

python scripts/fetch-conpty.py [--archive downloaded.nupkg]
No Pi files, runtime environment, system console, or system libraries are changed.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use an offline copy; the same SHA-256 is required')
    parser.add_argument('--verify', action='store_true', help='Verify the prepared binaries without downloading or modifying files')
    args = parser.parse_args()
    base = ROOT / 'vendor/conpty'
    package = json.loads((base / 'package.json').read_text(encoding='utf-8'))
    if args.verify:
        for name, expected in package['files'].items():
            path = base / 'runtime' / name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise RuntimeError(f'Missing or changed ConPTY binary: {name}. Run zig build fetch-conpty.')
        print(f'Verified native ConPTY {package["version"]}')
        return
    with tempfile.TemporaryDirectory(prefix='ghostty-conpty-') as temporary:
        archive = args.archive
        if archive is None:
            archive = Path(temporary) / 'conpty.nupkg'
            # curl verifies HTTPS certificates and honors process-local proxies.
            subprocess.run(['curl', '--fail', '--location', '--proto', '=https',
                            '--retry', '2', '--max-time', '120', '--output', str(archive),
                            package['url']], check=True)
        data = archive.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != package['sha256']:
            raise RuntimeError(f'ConPTY package SHA-256 mismatch: {digest}; no files installed')
        staging = Path(temporary) / 'runtime'
        with zipfile.ZipFile(io.BytesIO(data)) as source:
            manifest = ET.fromstring(source.read(package['id'] + '.nuspec').decode('utf-8-sig'))
            metadata = manifest.find('{*}metadata')
            if metadata.find('{*}version').text != package['version'] or metadata.find('{*}license').text != 'MIT':
                raise RuntimeError('Unexpected ConPTY version or license; no files installed')
            for arch in ['x86', 'x64', 'arm64']:
                dll = staging / arch / 'conpty.dll'
                host = staging / 'hosts' / arch / 'OpenConsole.exe'
                dll.parent.mkdir(parents=True, exist_ok=True)
                host.parent.mkdir(parents=True, exist_ok=True)
                dll.write_bytes(source.read(f'runtimes/win-{arch}/native/conpty.dll'))
                host.write_bytes(source.read(f'build/native/runtimes/{arch}/OpenConsole.exe'))
        for name, expected in package['files'].items():
            if hashlib.sha256((staging / name).read_bytes()).hexdigest() != expected:
                raise RuntimeError(f'Unexpected binary hash: {name}; no files installed')
        # Only the verified, allowlisted files enter the local dependency cache.
        # No archive paths are passed to extractall. Verification failures
        # occur before writing the old cache.
        destination = base / 'runtime'
        destination.mkdir(parents=True, exist_ok=True)
        for path in staging.rglob('*'):
            if path.is_file():
                target = destination / path.relative_to(staging)
                target.parent.mkdir(parents=True, exist_ok=True)
                staged = target.with_suffix(target.suffix + '.tmp')
                shutil.copyfile(path, staged)
                staged.replace(target)
        (destination / 'package.sha256').write_text(digest + '\n', encoding='ascii')
    print(f'Prepared native ConPTY {package["version"]}: {destination}')


if __name__ == '__main__':
    main()
