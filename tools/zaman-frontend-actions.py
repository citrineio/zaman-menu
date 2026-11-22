#!/usr/bin/env python3
"""Frontend maintenance for Zaman's existing Sway session; no input daemon APIs."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid

SERVICE = 'com.kawnelectro.Zaman.Session1'
OBJECT = '/com/kawnelectro/Zaman/Session1'
PEGASUS_IDS = {'org.pegasus-frontend.pegasus-fe', 'org.pegasus_frontend.Pegasus', 'pegasus-fe'}
LAUNCHER = Path('/usr/libexec/zaman-shell')
LAUNCHERS = {str(LAUNCHER), '/usr/libexec/zaman/frontend'}
ACTIONS = {'refresh', 'restart'}


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=12, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Command failed: ' + argv[0])
    return result.stdout.strip()


def emit(record):
    print(json.dumps(dict(type='frontend-action', **record)), flush=True)


def graphical_environment():
    # The installer is commonly run over SSH. Reuse Sway's imported user environment.
    names = ('SWAYSOCK', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS')
    if all(os.environ.get(name) for name in names):
        return
    raw = run(['systemctl', '--user', 'show-environment'])
    for line in raw.splitlines():
        if '=' in line:
            name, value = line.split('=', 1)
            if name in names and value and not os.environ.get(name):
                os.environ[name] = value


def runtime_dir():
    base = Path(os.environ['XDG_RUNTIME_DIR'])
    info = base.stat()
    if not base.is_absolute() or info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError('The graphical session runtime directory is unavailable.')
    return base


def state_path():
    return runtime_dir() / 'zaman-frontend-action.json'


def write_state(record):
    target = state_path()
    fd, name = tempfile.mkstemp(prefix='.zaman-frontend-', dir=target.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(record, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def read_state():
    try:
        record = json.loads(state_path().read_text())
    except FileNotFoundError:
        return dict(phase='idle', message='')
    if record.get('phase') in ('queued', 'running') and time.time() - record.get('started', 0) > 40:
        return dict(record, phase='failed', message='The frontend action did not finish. Check the frontend before retrying.')
    return record


def session_call():
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    owner = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
        'org.freedesktop.DBus', 'GetNameOwner', GLib.Variant('(s)', (SERVICE,)),
        GLib.VariantType.new('(s)'), Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]

    def call(method, signature):
        return bus.call_sync(owner, OBJECT, SERVICE, method, None,
            GLib.VariantType.new(signature), Gio.DBusCallFlags.NONE, 2000, None).unpack()
    return call


def require_library(call):
    if call('ForegroundStatus', '(sss)')[0] != 'library':
        raise RuntimeError('Return to the library before using frontend controls.')
    if call('Status', '(ssssss)')[0] not in ('Idle', 'Failed'):
        raise RuntimeError('Close the running game before using frontend controls.')
    if call('InstalledGameStatus', '(sssssb)')[3] in ('Starting', 'Running', 'Stopping', 'CleanupFailed'):
        raise RuntimeError('Close the running game before using frontend controls.')
    if call('StorefrontStatus', '(stssbs)')[0]:
        raise RuntimeError('Close the storefront before using frontend controls.')


def require_idle_menu(menu):
    # Check both the renderer and the input helper's active-session singleton.
    raw = run([shutil.which('qs') or '/usr/bin/qs', '-p', str(menu / 'qml/shell.qml'),
               'ipc', 'call', 'menu', 'timings'])
    state = json.loads(raw)
    if state.get('helperIdle') is not True or state.get('inputOwned') is not False:
        raise RuntimeError('The menu has not finished restoring controller input.')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        try:
            probe.bind('\0zaman-menu-dev:' + str(runtime_dir()))
        except OSError as error:
            raise RuntimeError('The menu input session is still active.') from error


def recv_exact(peer, length):
    chunks = bytearray()
    while len(chunks) < length:
        block = peer.recv(length - len(chunks))
        if not block:
            raise RuntimeError('The graphical session closed its control connection.')
        chunks.extend(block)
    return bytes(chunks)


def sway(kind, payload=''):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(3)
        peer.connect(os.environ['SWAYSOCK'])
        data = payload.encode()
        peer.sendall(b'i3-ipc' + struct.pack('<II', len(data), kind) + data)
        header = recv_exact(peer, 14)
        if header[:6] != b'i3-ipc':
            raise RuntimeError('Invalid compositor reply.')
        length, reply_kind = struct.unpack('<II', header[6:])
        if reply_kind != kind or length > 16 * 1024 * 1024:
            raise RuntimeError('Unexpected compositor reply.')
        return json.loads(recv_exact(peer, length))


def command(text):
    replies = sway(0, text)
    if not isinstance(replies, list) or not replies or any(r.get('success') is not True for r in replies):
        raise RuntimeError('The graphical session rejected the frontend action.')


def walk(node):
    yield node
    for child in node.get('nodes', []) + node.get('floating_nodes', []):
        yield from walk(child)


def pegasus_views(tree):
    return [node for node in walk(tree) if node.get('app_id') in PEGASUS_IDS and node.get('pid')]


def process_info(pid, proc=Path('/proc')):
    folder = proc / str(pid)
    if folder.stat().st_uid != os.getuid():
        raise ValueError('Process belongs to another user.')
    fields = (folder / 'stat').read_text().rsplit(')', 1)[1].split()
    argv = [os.fsdecode(v) for v in (folder / 'cmdline').read_bytes().split(b'\0') if v]
    return dict(pid=int(pid), parent=int(fields[1]), start=fields[19], argv=argv)


def processes(proc=Path('/proc')):
    found = {}
    for folder in proc.iterdir():
        if not folder.name.isdigit():
            continue
        try:
            info = process_info(int(folder.name), proc)
            if info['argv']:
                found[info['pid']] = info
        except (OSError, ValueError, IndexError):
            continue
    return found


def is_pegasus(info):
    return Path(info['argv'][0]).name == 'pegasus-fe'


def is_launcher(info):
    return any(arg in LAUNCHERS for arg in info['argv'][:3])


def restart_targets(found):
    pads = [info for info in found.values() if is_pegasus(info)]
    if len(pads) > 1:
        raise RuntimeError('More than one Pegasus process is running; restart was canceled.')
    if pads:
        root = pads[0]
        current = root
        seen = set()
        while current['parent'] in found and current['parent'] not in seen:
            seen.add(current['parent'])
            current = found[current['parent']]
            if is_launcher(current):
                root = current
    else:
        roots = [info for info in found.values() if is_launcher(info)]
        root_ids = {info['pid'] for info in roots}
        roots = [info for info in roots if info['parent'] not in root_ids]
        if len(roots) > 1:
            raise RuntimeError('More than one shell launcher is running; restart was canceled.')
        if not roots:
            return []
        root = roots[0]
    selected = {root['pid']}
    while True:
        more = {pid for pid, info in found.items() if info['parent'] in selected}
        if more <= selected:
            break
        selected |= more
    result = [root] + [found[pid] for pid in sorted(selected - {root['pid']})]
    for info in result:
        if not (is_pegasus(info) or is_launcher(info) or Path(info['argv'][0]).name == 'sleep'):
            raise RuntimeError('The frontend owns another application; restart was canceled.')
    return result


def stop_targets(targets):
    # Pin every intended process before sending a signal. Never use pkill/name matching.
    with contextlib.ExitStack() as stack:
        handles = []
        for info in targets:
            try:
                fd = os.pidfd_open(info['pid'])
                stack.callback(os.close, fd)
                if process_info(info['pid']) != info:
                    raise RuntimeError('The frontend changed before restart; try again.')
                handles.append(fd)
            except ProcessLookupError:
                continue
        for fd in handles:
            try:
                signal.pidfd_send_signal(fd, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        alive = list(handles)
        while alive and time.monotonic() < deadline:
            alive = [fd for fd in alive if not select.select([fd], [], [], 0)[0]]
            if alive:
                time.sleep(.05)
        for fd in alive:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        deadline = time.monotonic() + 2
        while alive and time.monotonic() < deadline:
            alive = [fd for fd in alive if not select.select([fd], [], [], 0)[0]]
            if alive:
                time.sleep(.05)
        if alive:
            raise RuntimeError('The previous frontend did not stop; no duplicate was started.')


def refresh(menu, call):
    views = pegasus_views(sway(4))
    if len(views) != 1:
        raise RuntimeError('A single Pegasus window is required. Use Restart frontend if it is unavailable.')
    view = views[0]
    original = process_info(view['pid'])
    if not is_pegasus(original):
        raise RuntimeError('The library window is not the expected Pegasus process.')
    command('[con_id=%d] focus' % view['id'])
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        current = next((n for n in walk(sway(4)) if n.get('focused')), {})
        if current.get('id') == view['id'] and current.get('pid') == view['pid']:
            break
        time.sleep(.05)
    else:
        raise RuntimeError('Pegasus did not receive focus; the theme was not refreshed.')
    require_library(call)
    require_idle_menu(menu)
    if process_info(view['pid']) != original:
        raise RuntimeError('Pegasus restarted before the theme refresh; try again.')
    # Last focus check directly before creating the short-lived virtual keyboard.
    current = next((n for n in walk(sway(4)) if n.get('focused')), {})
    if current.get('id') != view['id'] or current.get('pid') != view['pid']:
        raise RuntimeError('Focus changed; the theme was not refreshed.')
    run([shutil.which('wtype') or '/usr/bin/wtype', '-k', 'F5'])
    return 'Pegasus theme refresh requested.'


def restart(menu, call):
    if not LAUNCHER.is_file() or not os.access(LAUNCHER, os.X_OK):
        raise RuntimeError('The installed Zaman shell launcher is unavailable.')
    targets = restart_targets(processes())
    require_library(call)
    require_idle_menu(menu)
    stop_targets(targets)
    # A supervisor may have raced the snapshot. Refuse to create two frontends.
    if restart_targets(processes()):
        raise RuntimeError('A frontend is still running; no duplicate was started.')
    command('exec --no-startup-id ' + shlex.quote(str(LAUNCHER)))
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        views = pegasus_views(sway(4))
        if len(views) == 1 and is_pegasus(process_info(views[0]['pid'])):
            return 'Zaman frontend restarted.'
        time.sleep(.15)
    raise RuntimeError('The Zaman shell was launched, but Pegasus did not appear. Check the frontend log.')


def check_dependencies():
    for name in ('systemd-run', 'wtype', 'qs'):
        if not shutil.which(name):
            raise RuntimeError('Missing required command: ' + name)
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        raise RuntimeError('This Python/kernel combination lacks safe process restart support.')
    if not LAUNCHER.is_file() or not os.access(LAUNCHER, os.X_OK):
        raise RuntimeError('The installed Zaman shell launcher is unavailable.')


def request(action, menu):
    check_dependencies()
    require_library(session_call())
    require_idle_menu(menu)
    with (runtime_dir() / 'zaman-frontend-request.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        previous = read_state()
        if previous.get('phase') in ('queued', 'running'):
            raise RuntimeError('A frontend action is already running.')
        identity = uuid.uuid4().hex
        record = dict(id=identity, action=action, phase='queued', started=time.time(), message='')
        write_state(record)
        argv = ['systemd-run', '--user', '--collect', '--quiet', '--property=Type=exec',
                '--property=RuntimeMaxSec=35', '--unit=zaman-frontend-' + identity]
        for name in ('SWAYSOCK', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS'):
            if name in os.environ:
                argv.append('--setenv=' + name + '=' + os.environ[name])
        argv += ['/usr/bin/python3', str(Path(__file__).resolve()), 'worker', action, identity]
        try:
            run(argv)
        except Exception:
            write_state(dict(record, phase='failed', message='The frontend worker could not start.'))
            raise
        emit(read_state())


def worker(action, identity, menu):
    with (runtime_dir() / 'zaman-frontend-worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        record = read_state()
        if record.get('id') != identity or record.get('action') != action or record.get('phase') != 'queued':
            raise RuntimeError('The frontend action request changed or expired.')
        try:
            write_state(dict(record, phase='running'))
            call = session_call()
            require_library(call)
            require_idle_menu(menu)
            message = refresh(menu, call) if action == 'refresh' else restart(menu, call)
            write_state(dict(record, phase='done', message=message))
        except Exception as error:
            write_state(dict(record, phase='failed', message=str(error)))
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('request', 'worker', 'status', 'check'))
    parser.add_argument('action', nargs='?', choices=sorted(ACTIONS))
    parser.add_argument('identity', nargs='?')
    args = parser.parse_args()
    menu = Path(__file__).resolve().parent.parent
    try:
        if args.operation != 'status':
            graphical_environment()
        if args.operation == 'status':
            emit(read_state())
        elif args.operation == 'check':
            check_dependencies()
            require_library(session_call())
            sway(4)
            emit(dict(phase='done', message='Frontend prerequisites are available.'))
        elif not args.action:
            raise RuntimeError('Missing frontend action.')
        elif args.operation == 'request':
            request(args.action, menu)
        else:
            if not args.identity or len(args.identity) != 32 or any(c not in '0123456789abcdef' for c in args.identity):
                raise RuntimeError('Invalid frontend request identity.')
            worker(args.action, args.identity, menu)
    except Exception as error:
        emit(dict(phase='failed', message=str(error)))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
