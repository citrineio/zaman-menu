"""UDisks adapter and storage safety policy. No shell commands or user code."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

PREFIX = 'org.freedesktop.UDisks2.'
BLOCK, DRIVE, FS, PART, TABLE = [PREFIX + s for s in ('Block', 'Drive', 'Filesystem', 'Partition', 'PartitionTable')]
MANAGED_ROOTS = ('/mnt/', '/media/', '/run/media/')
BOOT_TYPES = {'c12a7328-f81f-11d2-ba4b-00a0c93ec93b', '21686148-6449-6e6f-744e-656564454649', '0xef', '0xee'}


def decode(value):
    return bytes(value).rstrip(b'\0').decode('utf-8', 'replace')


class UDisks:
    def __init__(self):
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, path, interface, method, signature=None, values=(), timeout=180000):
        args = self.GLib.Variant(signature, values) if signature else None
        return self.bus.call_sync(PREFIX[:-1], path, interface, method, args, None,
                                  self.Gio.DBusCallFlags.NONE, timeout, None).unpack()

    def objects(self):
        return self.call('/org/freedesktop/UDisks2', 'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects')[0]

    def options(self, **values):
        return {k: self.GLib.Variant('b' if isinstance(v, bool) else 's', v) for k, v in values.items()}

    def mount(self, path, username, readonly=False):
        opts = self.options(**{'as-user': username, 'options': 'ro,nosuid,nodev,noexec' if readonly else 'rw,nosuid,nodev'})
        return self.call(path, FS, 'Mount', '(a{sv})', (opts,))[0]

    def unmount(self, path):
        self.call(path, FS, 'Unmount', '(a{sv})', ({},))


def kernel_inventory():
    result = subprocess.run(['/usr/bin/lsblk', '--json', '--bytes', '--paths', '--output',
                             'NAME,TYPE,SIZE,RO,MAJ:MIN,MOUNTPOINTS'], capture_output=True, text=True,
                            check=True, timeout=15)
    return json.loads(result.stdout)['blockdevices']


def flatten(node):
    yield node
    for child in node.get('children', []):
        yield from flatten(child)


def kernel_disks(nodes):
    result = {}
    for node in nodes:
        for item in flatten(node):
            if item['type'] == 'disk':
                result[item['name']] = item
    return result


def protected_reason(node, blocks):
    if node is None:
        return 'Cannot verify the physical disk in the kernel.'
    if node['size'] < 512 * 1024**2:
        return 'Small firmware or boot device.'
    for item in flatten(node):
        if item.get('ro'):
            return 'Read-only device.'
        if item['type'] not in ('disk', 'part'):
            return 'Layered or encrypted storage is not managed here.'
        for mount in item.get('mountpoints') or []:
            if mount and not any(mount.startswith(root) for root in MANAGED_ROOTS):
                return 'System or application storage (' + mount + ').'
        for interfaces in blocks.values():
            b = interfaces.get(BLOCK, {})
            if decode(b.get('Device', [])) != item['name']:
                continue
            if b.get('ReadOnly') or b.get('HintIgnore'):
                return 'Read-only or reserved device.'
            if b.get('CryptoBackingDevice', '/') != '/' or b.get('MDRaid', '/') != '/' or b.get('MDRaidMember', '/') != '/':
                return 'Encrypted or RAID storage.'
            p = interfaces.get(PART, {})
            if str(p.get('Type', '')).lower() in BOOT_TYPES or p.get('IsContainer'):
                return 'Boot or extended partition present.'
    return ''


def identity(path, interfaces, drive):
    b = interfaces[BLOCK]
    # Includes kernel device number and object path, preventing a replugged device
    # from inheriting a pending action even if it has a cloned filesystem UUID.
    generation = None
    number = b.get('DeviceNumber')
    if number is not None:
        device = Path('/sys/dev/block') / (str(os.major(number)) + ':' + str(os.minor(number)))
        try:
            seq = device / 'diskseq'
            if not seq.exists():
                seq = device.resolve().parent / 'diskseq'
            generation = seq.read_text().strip()
        except OSError:
            try:
                generation = device.stat().st_ino
            except OSError:
                pass
    fields = [path, b.get('DeviceNumber'), generation, b.get('Id'), b.get('Size'), b.get('IdUUID'),
              drive.get('Id'), drive.get('Serial'), drive.get('WWN')]
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def inventory(ud, nodes=None):
    objects = ud.objects()
    disks = kernel_disks(kernel_inventory() if nodes is None else nodes)
    devices = []
    for path, interfaces in objects.items():
        b = interfaces.get(BLOCK)
        if not b or PART in interfaces or b.get('Drive', '/') == '/':
            continue
        node = disks.get(decode(b.get('Device', [])))
        if node is None or node['size'] < 512 * 1024**2:
            continue
        drive = objects.get(b['Drive'], {}).get(DRIVE, {})
        reason = protected_reason(node, objects)
        members = [path] + sorted(p for p, i in objects.items() if i.get(PART, {}).get('Table') == path)
        volumes = []
        for p in members:
            i = objects[p]
            block = i.get(BLOCK, {})
            # A whole disk with a partition table isn't a filesystem volume.
            if p == path and TABLE in i:
                continue
            if FS not in i and not block.get('IdType'):
                continue
            mounts = [decode(m) for m in i.get(FS, {}).get('MountPoints', [])]
            total = used = available = None
            if mounts:
                try:
                    usage = os.statvfs(mounts[0])
                    total = usage.f_blocks * usage.f_frsize
                    used = (usage.f_blocks - usage.f_bfree) * usage.f_frsize
                    available = usage.f_bavail * usage.f_frsize
                except OSError:
                    pass
            volumes.append(dict(id=p, identity=identity(p, i, drive), device=decode(block['Device']),
                uuid=block.get('IdUUID', ''), name=block.get('IdLabel') or Path(decode(block['Device'])).name,
                filesystem=block.get('IdType', ''), mountpoint=mounts[0] if mounts else '',
                mountpoints=mounts, capacity=block.get('Size', 0), total=total, used=used, available=available,
                readOnly=bool(block.get('ReadOnly')), mountable=FS in i))
        connection = drive.get('ConnectionBus') or 'Internal'
        kind = 'Hard disk' if drive.get('RotationRate', 0) else 'SSD / flash'
        devices.append(dict(id=path, identity=identity(path, interfaces, drive),
            device=decode(b['Device']), name=drive.get('Model') or Path(decode(b['Device'])).name,
            serial=drive.get('Serial', ''), physicalSize=b.get('Size', 0), type=kind,
            connection=connection, protected=bool(reason), reason=reason, volumes=volumes))
    # UUID alone must never choose between two cloned filesystems.
    counts = {}
    for d in devices:
        for v in d['volumes']:
            counts[v['uuid']] = counts.get(v['uuid'], 0) + 1
    for d in devices:
        for v in d['volumes']:
            v['duplicateUUID'] = bool(v['uuid'] and counts[v['uuid']] > 1)
    return dict(type='storage', available=True, devices=sorted(devices, key=lambda d: d['device']), error='')


def selected(snapshot, request, disk=False):
    for device in snapshot['devices']:
        candidates = [device] if disk else device['volumes']
        for entry in candidates:
            if entry['id'] != request.get('id'):
                continue
            if entry['identity'] != request.get('identity'):
                raise ValueError('The selected drive changed. Refresh and select it again.')
            if device['protected']:
                raise ValueError(device['reason'])
            if not disk and entry.get('duplicateUUID'):
                raise ValueError('Two connected volumes share this UUID. Disconnect the duplicate first.')
            return device, entry
    raise ValueError('The selected drive is no longer connected.')
