#!/usr/bin/python3
"""Open the Zaman Storage confirmation for a selected Pegasus game."""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit


def decode(url):
    if len(url.encode()) > 65536:
        raise ValueError('Game selection is too large.')
    value = urlsplit(url)
    if (value.scheme != 'zaman-storage' or value.netloc not in ('move', 'delete')
            or value.path not in ('', '/') or value.fragment):
        raise ValueError('Unsupported storage link.')
    query = parse_qs(value.query, strict_parsing=True, max_num_fields=1)
    if set(query) != {'paths'} or len(query['paths']) != 1:
        raise ValueError('Invalid storage link.')
    paths = json.loads(query['paths'][0])
    if (not isinstance(paths, list) or not 1 <= len(paths) <= 64
            or any(not isinstance(p, str) or not Path(p).is_absolute()
                   or any(ord(ch) < 32 for ch in p) for p in paths)):
        raise ValueError('Invalid game paths.')
    return dict(paths=paths, action=value.netloc)


def open_menu(menu_dir, payload):
    executable = shutil.which('qs') or shutil.which('quickshell')
    if not executable:
        raise RuntimeError('Quickshell is unavailable.')
    subprocess.run(['systemctl', '--user', 'start', 'zaman-quickshell.service'], check=True, timeout=20)
    argv = [executable, '-p', str(menu_dir / 'qml/shell.qml'), 'ipc', 'call', 'menu']
    token = secrets.token_hex(12)
    data = json.dumps(dict(payload, token=token), ensure_ascii=True, separators=(',', ':'))
    last_error = ''
    for attempt in range(15):
        result = subprocess.run([*argv, 'storageMove', data], text=True, capture_output=True, timeout=4)
        if result.returncode == 0:
            status = result.stdout.strip().strip('"')
            if status == 'opening':
                break
            if status == 'busy':
                raise RuntimeError('Close the system menu, then open the game’s Options again.')
            raise RuntimeError('The storage request was rejected.')
        last_error = result.stderr.strip() or result.stdout.strip()
        if attempt < 14:
            time.sleep(0.2)
    else:
        raise RuntimeError('The Zaman menu did not accept the storage request. ' + last_error)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        result = subprocess.run([*argv, 'storageMoveStatus', token], text=True, capture_output=True, timeout=4)
        if result.returncode:
            raise RuntimeError('Could not confirm that the storage menu opened. ' + result.stderr.strip())
        status = result.stdout.strip().strip('"')
        if status == 'shown':
            return
        if status == 'unavailable':
            raise RuntimeError('Return to the Pegasus library and close any running game before using game storage.')
        if status != 'opening':
            break
        time.sleep(0.15)
    raise RuntimeError('The storage menu did not open. Try again from game details.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--menu-dir', default=Path(__file__).resolve().parents[1], type=Path)
    parser.add_argument('url')
    args = parser.parse_args()
    try:
        open_menu(args.menu_dir, decode(args.url))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Zaman Storage: ' + str(error), file=sys.stderr)
        if shutil.which('notify-send'):
            subprocess.run(['notify-send', 'Zaman Storage', str(error)], check=False, timeout=5)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
