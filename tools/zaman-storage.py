#!/usr/bin/python3
"""Storage UI backend and per-user automatic mounting. No privileged file writes."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import time
import storage_moves
import xml.etree.ElementTree as ET

from storage_library import (atomic_text, export_index, migrate_indexes, prepare, registry, remove_index, scan)
from storage_notify import notify

CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
STATE = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'zaman/storage'
SETTINGS = CONFIG / 'zaman/storage.json'
SOCKET = '/run/zaman-storage/control'


class StorageBusy(RuntimeError):
    """The broker or library lock is held by another storage request."""


def broker(request):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(600)
        try:
            connection.connect(SOCKET)
        except (FileNotFoundError, ConnectionRefusedError, PermissionError) as error:
            raise RuntimeError('Storage service is unavailable. Run the storage update installer from your desktop account.') from error
        connection.sendall((json.dumps(request) + '\n').encode())
        with connection.makefile('rb') as stream:
            line = stream.readline(4 * 1024**2)
    if not line.endswith(b'\n'):
        raise RuntimeError('Incomplete storage service reply.')
    result = json.loads(line)
    if not result.get('ok'):
        message = result.get('error', 'Storage operation failed.')
        if message == 'Another storage operation is in progress. Try again shortly.':
            raise StorageBusy(message)
        raise RuntimeError(message)
    return result


@contextlib.contextmanager
def locked(name):
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / (name + '.lock')).open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise StorageBusy('Another storage scan or update is in progress. Try again shortly.') from error
        yield


def settings():
    if not SETTINGS.exists():
        return dict(schema=1, volumes={})
    value = json.loads(SETTINGS.read_text())
    if value.get('schema') != 1 or not isinstance(value.get('volumes'), dict):
        raise ValueError('Unsupported storage settings; no changes were made.')
    return value


def update_settings(volume_uuid, **values):
    if not volume_uuid or len(volume_uuid) > 128:
        raise ValueError('A filesystem UUID is required for persistent storage settings.')
    with locked('settings'):
        value = settings()
        entry = value['volumes'].setdefault(volume_uuid, {})
        entry.update(values)
        atomic_text(SETTINGS, json.dumps(value, indent=2) + '\n')
    return entry


def report_path(volume_uuid):
    return STATE / (hashlib.sha256(volume_uuid.encode()).hexdigest() + '.scan.json')


def get_report(volume_uuid):
    path = report_path(volume_uuid)
    return json.loads(path.read_text()) if path.exists() else None


def enrich(snap):
    prefs = settings()['volumes']
    for d in snap['devices']:
        for v in d['volumes']:
            saved = prefs.get(v['uuid'], {})
            v['mode'] = saved.get('mode', 'auto')
            v['prepared'] = saved.get('prepared', False)
            v['indexed'] = saved.get('indexed', False)
            v['count'] = saved.get('count', 0)
            v['unresolved'] = saved.get('unresolved', 0)
            v['suspended'] = saved.get('suspended', False)
    return snap


def publish_storage_map(snapshot):
    theme=CONFIG/'pegasus-frontend/themes/zaman'
    profile=CONFIG/'zaman/storage-details.json'
    if profile.exists():
        try:
            settings=json.loads(profile.read_text())
            if settings.get('schema')!=1:return
            theme=Path(settings['theme'])
        except (OSError,ValueError,KeyError):return
    if theme.is_symlink() or not (theme/'theme.qml').is_file():return
    try:extensions=sorted({e for s in registry().values() for e in s['extensions']})
    except (OSError,ValueError):extensions=[]
    document=ET.Element('storage')
    for root in (storage_moves.INTERNAL,storage_moves.MANAGED_INTERNAL):
        for path in dict.fromkeys((root, root.resolve())):
            ET.SubElement(document, 'volume', root=str(path), label='Internal storage',
                          kind='internal', extensions=' '.join(extensions))
    for d in snapshot['devices']:
        if d['protected']:continue
        bus=d['connection'].lower()
        kind='USB' if bus=='usb' else 'SSD' if bus=='nvme' else 'Storage'
        for v in d['volumes']:
            if v['mountpoint'] and v['uuid'] and not v['duplicateUUID']:
                label=v['name'] if v['name']!=Path(v['device']).name else d['name']
                ET.SubElement(document,'volume',root=v['mountpoint'],label=label,kind=kind,extensions=' '.join(extensions))
    content=ET.tostring(document,encoding='unicode')+'\n'
    target=theme/'storage-info.xml'
    if not target.exists() or target.read_text()!=content:atomic_text(target,content,0o644)


def volume_request(request):
    # Never trust a client-provided mountpoint or device path.
    return dict(id=request.get('id'), identity=request.get('identity'))


def mounted(request, create_workspace=False):
    result = broker(dict(action='workspace' if create_workspace else 'mount', **volume_request(request)))
    v = result['volume']
    if v.get('duplicateUUID') or not v.get('uuid'):
        raise ValueError('A unique filesystem UUID is required to register this volume.')
    mount = Path(v['mountpoint'])
    if not mount.is_mount() or mount.stat().st_dev != os.stat(v['device']).st_rdev:
        raise ValueError('The mount changed. Refresh storage and try again.')
    return v, result.get('workspace')


def do_scan(request, do_prepare=False):
    systems = registry()
    launcher = shutil.which('zamanctl')
    if not launcher:
        raise ValueError('The Zaman launcher is unavailable; the library was preserved.')
    v, workspace = mounted(request, create_workspace=do_prepare)
    with locked('library'):
        prefs = settings()['volumes'].get(v['uuid'], {})
        if do_prepare:
            prepare(workspace, systems, v['uuid'])
        root = Path(v['mountpoint']).resolve()
        result = scan(root, systems, prefs.get('assignments', {}), storage_moves.configured_metadata(CONFIG, root))
        # Mount identity is revalidated after the scan, before publishing paths.
        v2, _ = mounted(request)
        if v2['mountpoint'] != v['mountpoint']:
            raise ValueError('The mount changed while scanning; the previous index was preserved.')
        prepared = storage_moves.prepared_root(dict(v, root=str(root), internal=False))
        portable = prepared if prepared and os.access(prepared, os.W_OK) else None
        export_index(CONFIG, v['uuid'], result, systems, portable, launcher)
        STATE.mkdir(parents=True, exist_ok=True)
        report = dict(uuid=v['uuid'], count=len(result['games']), unresolved=result['unresolved'],
                      warnings=result['warnings'], inspected=result['inspected'],
                      systems=[dict(id=sid, name=s['name']) for sid, s in sorted(systems.items())])
        atomic_text(report_path(v['uuid']), json.dumps(report) + '\n')
        update_settings(v['uuid'], indexed=True, prepared=bool(prepared), count=report['count'],
                        unresolved=sum(g['count'] for g in result['unresolved']), suspended=False)
    message = str(report['count']) + ' games indexed.'
    if report['unresolved']:
        message += ' Choose platforms for the unassigned folders.'
    if report['warnings']:
        message += ' Some disc descriptors need attention.'
    notify('scan:'+v['uuid']+':'+str(time.time_ns()),'Storage prepared for Zaman' if do_prepare else 'Game scan complete',v['name']+' · '+message)
    return dict(message=message, report=report, volume=v)


def dispatch(request):
    action = request.get('action')
    api=sys.modules[__name__]
    if action == 'migrate-indexes':
        with locked('library'):
            return dict(repaired=migrate_indexes(CONFIG))
    if action == 'move-sources':
        return dict(sources=storage_moves.sources(api),recoveries=storage_moves.recoveries(api))
    if action == 'move-for-game':
        deadline = time.monotonic() + 5
        while True:
            try:
                with locked('library'):
                    return storage_moves.intent(api, request.get('paths'))
            except StorageBusy:
                # Drop the lock before waiting so the watcher can finish its work.
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                time.sleep(min(0.15, remaining))
    if action == 'move-library':
        with locked('library'):
            return storage_moves.library(api,request['source'])
    if action == 'move-destination':
        with locked('library'):
            return storage_moves.destination_options(api, request)
    if action in ('move-plan', 'delete-plan'):
        with locked('library'):
            return storage_moves.create_plan(api,request)
    if action == 'move':
        with locked('library'):
            return storage_moves.execute(api,request['job'])
    if action == 'move-cancel':
        path,job=storage_moves.load_job(api,request['job'])
        if job.get('operation') == 'delete' or job.get('committed') or job['phase'] not in ('copying','planned'):
            raise ValueError('The verified move is finishing and cannot be cancelled now.')
        atomic_text(path.parent/'cancel','cancel\n')
        return dict(message='Cancelling the move; original files will be kept.')
    if action == 'inventory':
        snapshot=enrich(broker(dict(action='inventory')))
        publish_storage_map(snapshot)
        return snapshot
    if action in ('prepare', 'scan'):
        return do_scan(request, action == 'prepare')
    if action == 'assign':
        v, _ = mounted(request)
        systems = registry()
        folder = request.get('folder')
        sid = request.get('system')
        report = get_report(v['uuid']) or {}
        groups = {g['folder']: g for g in report.get('unresolved', [])}
        if folder not in groups or sid not in systems or sid not in groups[folder]['candidates']:
            raise ValueError('This folder or platform choice is no longer valid. Scan the drive again.')
        assignments = dict(settings()['volumes'].get(v['uuid'], {}).get('assignments', {}))
        assignments[folder] = sid
        update_settings(v['uuid'], assignments=assignments)
        return do_scan(request)
    if action == 'mode':
        if request.get('mode') not in ('auto', 'manual'):
            raise ValueError('Unknown mount mode.')
        v, _ = mounted(request) if request['mode'] == 'auto' else (None, None)
        if v is None:
            snap = broker(dict(action='inventory'))
            # The broker validates all identities for volume operations, including
            # changing mode when a volume is currently unmounted.
            from storage_disks import selected
            _, v = selected(snap, request)
        update_settings(v['uuid'], mode=request['mode'], suspended=False)
        return dict(message='This storage will connect automatically.' if request['mode'] == 'auto' else 'This storage will be used manually.')
    if action == 'unmount':
        # Suspend automount before unmounting, avoiding an immediate reconnect.
        from storage_disks import selected
        _, v = selected(broker(dict(action='inventory')), request)
        with locked('library'):
            previous = settings()['volumes'].get(v['uuid'], {}).get('suspended', False)
            update_settings(v['uuid'], suspended=True)
            try:
                result = broker(dict(action='unmount', **volume_request(request)))
            except Exception:
                update_settings(v['uuid'], suspended=previous)
                raise
            remove_index(CONFIG, v['uuid'])
        return result
    if action == 'eject':
        from storage_disks import selected
        device, _ = selected(broker(dict(action='inventory')), request)
        with locked('library'):
            for v in device['volumes']:
                if v['uuid']:
                    update_settings(v['uuid'], suspended=True)
            result = broker(dict(action='eject', **volume_request(request)))
            for uid in result['ejected']:
                remove_index(CONFIG, uid)
        notify('eject:' + device['identity'] + ':' + str(time.time_ns()), 'Storage ejected', device['name'] + ' is safe to remove.')
        return result
    if action == 'mount':
        v, _ = mounted(request)
        update_settings(v['uuid'], suspended=False)
        notify('ready:' + v['identity'], 'Storage ready', v['name'])
        return dict(volume=v, message='Storage is ready.')
    if action in ('format-plan', 'format'):
        with locked('library'):
            result=broker(dict(action=action, **volume_request(request), token=request.get('token', '')))
        if action=='format':notify('format:'+str(time.time_ns()),'Storage formatted','Select Prepare for Zaman to create game folders.')
        return result
    if action == 'report':
        from storage_disks import selected
        _, v = selected(broker(dict(action='inventory')), request)
        return dict(report=get_report(v['uuid']))
    raise ValueError('Unknown storage operation.')


def reconcile_once(seen):
    try:
        with locked('library'):
            storage_moves.repair_source_metadata(sys.modules[__name__])
    except RuntimeError:
        return  # A move owns the library until its metadata and cleanup finish.
    snap = broker(dict(action='inventory'))
    publish_storage_map(snap)
    prefs = settings()['volumes']
    present = set()
    for d in snap['devices']:
        if d['protected']:
            continue
        for v in d['volumes']:
            uid = v['uuid']
            if not uid or v['duplicateUUID']:
                if uid:
                    remove_index(CONFIG, uid)
                continue
            present.add(uid)
            saved = prefs.get(uid, {})
            try:
                if saved.get('mode', 'auto') == 'auto' and not saved.get('suspended') and not v['mountpoint']:
                    v, _ = mounted(v)
                current = (v['identity'], v['mountpoint']) if v['mountpoint'] else None
                if current and seen.get('ready:' + uid) != current:
                    notify('ready:' + v['identity'], 'Storage ready', v.get('name','Storage'))
                    seen['ready:' + uid] = current
                if saved.get('indexed') and current and seen.get(uid) != current:
                    do_scan(v)
                    seen[uid] = current
                elif not current:
                    remove_index(CONFIG, uid)
                    seen.pop(uid, None)
            except Exception as error:
                # One damaged drive must not prevent another drive from mounting.
                print('Storage volume ' + uid + ': ' + str(error), file=sys.stderr, flush=True)
                if seen.get('error:' + uid) != v['identity']:
                    notify('error:' + v['identity'], 'Storage needs attention', v.get('name','Storage') + ': ' + str(error), 'failed')
                    seen['error:' + uid] = v['identity']
    for uid, saved in prefs.items():
        if uid not in present:
            remove_index(CONFIG, uid)
            seen.pop(uid, None)
            seen.pop('ready:' + uid, None)
            seen.pop('error:' + uid, None)
            if saved.get('suspended'):
                update_settings(uid, suspended=False)


def watch():
    seen = {}
    migrated = False
    with locked('watcher'):
        while True:
            try:
                if not migrated:
                    dispatch(dict(action='migrate-indexes'))
                    migrated = True
                reconcile_once(seen)
            except Exception as error:
                print('Storage watcher: ' + str(error), file=sys.stderr, flush=True)
            time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('request', 'watch', 'inventory'))
    parser.add_argument('payload', nargs='?')
    args = parser.parse_args()
    try:
        if args.command == 'watch':
            watch()
            return
        request = dict(action='inventory') if args.command == 'inventory' else json.loads(args.payload or '{}')
        if not isinstance(request, dict):
            raise ValueError('Invalid storage request.')
        # One complete JSON line is returned even when the operation fails.
        result = dispatch(request)
        print(json.dumps(dict(result, type='storage' if request['action'] == 'inventory' else 'storage-result', ok=True)), flush=True)
    except Exception as error:
        if 'request' in locals() and isinstance(request,dict) and request.get('action') not in ('inventory','migrate-indexes','move','move-sources','move-library','move-for-game','move-destination','move-plan','delete-plan'):
            notify('action-error:'+str(time.time_ns()),'Storage needs attention',str(error),'failed')
        print(json.dumps(dict(type='storage-result', ok=False, error=str(error))), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
