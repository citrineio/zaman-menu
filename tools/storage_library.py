"""Unprivileged ROM discovery and deterministic Pegasus metadata generation."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time
import tomllib
import zipfile

ID = re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}$')
MOVED = '# Zaman moved game; local artwork and launch files.\n'
OWNED = '# Managed by Zaman Storage v1; generated launch commands only.\n'
EXPLICIT_COLLECTIONS = '# Collections use explicit file lists.\n'
SKIP = {'bios', 'firmware', 'saves', 'savestates', 'media', 'artwork', 'screenshots',
        'covers', 'cache', 'lost+found', 'system volume information', '$recycle.bin'}
FIELDS = {'developer', 'publisher', 'genre', 'release', 'players', 'rating', 'description'}
ASSETS = {'assets.boxfront', 'assets.boxback', 'assets.screenshot', 'assets.logo',
          'assets.background', 'assets.banner', 'assets.titlescreen', 'assets.marquee'}


def safe_text(value):
    return isinstance(value, str) and bool(value) and not any(ord(c) < 32 or ord(c) == 127 or c in '\\"$`' for c in value)


def atomic_text(path, text, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('Refusing to replace a linked file: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.zaman-storage-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def metadata_records(path):
    if path.stat().st_size > 8 * 1024**2:
        return []
    records, record, last = [], {}, None
    for line in path.read_text(errors='replace').splitlines():
        if line.startswith('#') or not line.strip():
            continue
        if line[:1].isspace() and last:
            record[last] += '\n' + line.strip()
            continue
        key, sep, value = line.partition(':')
        key = key.strip().lower()
        if not sep:
            continue
        if key in ('game', 'collection'):
            if record:
                records.append(record)
            record = {}
        # Lists are retained; repeated singular file keys are a Pegasus feature.
        if key in record and key in ('file', 'files'):
            record[key] += '\n' + value.strip()
        else:
            record[key] = value.strip()
        last = key
    if record:
        records.append(record)
    return records


def registry(roots=None, rom_root=Path('/srv/zaman/roms')):
    if roots is None:
        configured = os.environ.get('ZAMAN_REGISTRY_DIRS')
        if not configured:
            # Match the running launch service when its registry overrides are
            # set in its unit rather than in the resident menu environment.
            try:
                proc = subprocess.run(['systemctl', '--user', 'show', 'zaman-sessiond.service', '-p', 'MainPID', '--value'],
                                      capture_output=True, text=True, timeout=3)
                pid = int(proc.stdout.strip())
                if pid > 1:
                    environment = Path('/proc', str(pid), 'environ').read_bytes().split(b'\0')
                    configured = next((p.split(b'=', 1)[1].decode() for p in environment if p.startswith(b'ZAMAN_REGISTRY_DIRS=')), None)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        roots = (configured or '/usr/share/zaman:/etc/zaman').split(os.pathsep)
    systems, emulators = {}, {}
    for root in roots:
        for path in sorted((Path(root) / 'systems.d').glob('*.toml')):
            doc = tomllib.loads(path.read_text())
            s = doc.get('system', {})
            if doc.get('schema') != 1 or not ID.fullmatch(s.get('id', '')) or not safe_text(s.get('name', '')):
                raise ValueError('Invalid Zaman system definition: ' + str(path))
            extensions = s.get('extensions', [])
            if not extensions or any(not isinstance(e, str) or not re.fullmatch('[a-z0-9]+', e) for e in extensions):
                raise ValueError('Invalid system extensions: ' + str(path))
            systems[s['id']] = dict(id=s['id'], name=s['name'], collection=s['name'], shortname=s['id'], extensions=extensions)
        for path in sorted((Path(root) / 'emulators.d').glob('*.toml')):
            doc = tomllib.loads(path.read_text())
            e = doc.get('emulator', {})
            if doc.get('schema') != 1 or not ID.fullmatch(e.get('id', '')):
                raise ValueError('Invalid Zaman emulator definition: ' + str(path))
            emulators[e['id']] = e
    # Only publish launches that sessiond can actually resolve.
    systems = {sid: s for sid, s in systems.items() if any(sid in e.get('systems', []) for e in emulators.values())}
    for sid, s in systems.items():
        path = rom_root / sid / 'metadata.pegasus.txt'
        if path.is_file() and not path.is_symlink():
            records = metadata_records(path)
            head = next((r for r in records if 'collection' in r), {})
            try:
                args = shlex.split(head.get('launch', ''))
            except ValueError:
                args = []
            if len(args) >= 3 and Path(args[0]).name == 'zamanctl' and args[1:3] == ['launch', sid]:
                if safe_text(head.get('collection', '')):
                    s['collection'] = head['collection']
                if safe_text(head.get('shortname', '')):
                    s['shortname'] = head['shortname']
    if not systems:
        raise ValueError('No launchable systems were found in the active Zaman registry.')
    return systems


def within(path, mount):
    try:
        return path.resolve(strict=True).is_relative_to(mount) and path.stat().st_dev == mount.stat().st_dev
    except OSError:
        return False


def walk_files(mount, max_entries=200000, deadline=None):
    mount = Path(mount).resolve(strict=True)
    mount_device = mount.stat().st_dev
    stack, seen, errors = [(mount, 0)], 0, []
    while stack:
        directory, depth = stack.pop()
        if deadline is not None and time.monotonic() > deadline:
            raise ValueError('Scan time limit reached; the previous index was preserved. Scan a smaller library.')
        try:
            with os.scandir(directory) as iterator:
                entries = list(iterator)
        except OSError as error:
            raise ValueError('Cannot inspect ' + str(directory) + ': ' + error.strerror) from error
        for entry in sorted(entries, key=lambda e: e.name):
            seen += 1
            if seen > max_entries:
                raise ValueError('Drive contains too many entries; the previous index was preserved.')
            if entry.is_symlink() or entry.name.startswith('.') or entry.name.lower() in SKIP:
                continue
            path = Path(entry.path)
            if not safe_text(str(path)):
                errors.append(str(path))
                continue
            info = entry.stat(follow_symlinks=False)
            if info.st_dev != mount_device:
                continue
            if entry.is_dir(follow_symlinks=False):
                if depth >= 24:
                    raise ValueError('Directory depth limit reached; the previous index was preserved.')
                stack.append((path, depth + 1))
            elif entry.is_file(follow_symlinks=False):
                yield path


def aliases(systems):
    result = {}
    for sid, s in systems.items():
        for alias in (sid, s['shortname'], s['name'], s['collection']):
            result.setdefault(alias.casefold(), set()).add(sid)
    return result


def path_hint(path, mount, names, assignments):
    parent = path.parent
    while parent.is_relative_to(mount):
        relative = parent.relative_to(mount).as_posix()
        if relative in assignments:
            return assignments[relative]
        choices = names.get(parent.name.casefold(), set())
        if len(choices) == 1:
            return next(iter(choices))
        if parent == mount:
            break
        parent = parent.parent
    return None


def zip_hint(path, systems):
    try:
        with zipfile.ZipFile(path) as z:
            items = z.infolist()
            if len(items) != 1 or items[0].is_dir():
                return None
            extension = Path(items[0].filename).suffix.lower().lstrip('.')
            candidates = [sid for sid, s in systems.items() if extension in s['extensions'] and 'zip' in s['extensions']]
            return candidates[0] if len(candidates) == 1 else None
    except (OSError, zipfile.BadZipFile):
        return None


def references(path, mount):
    if path.suffix.lower() not in ('.cue', '.m3u') or path.stat().st_size > 1024**2:
        return []
    result = []
    for line in path.read_text(errors='replace').splitlines():
        if path.suffix.lower() == '.cue':
            match = re.match(r'\s*FILE\s+(?:"([^"]+)"|(\S+))', line, re.I)
            if not match:
                continue
            name = match.group(1) or match.group(2)
        else:
            name = line.strip()
            if not name or name.startswith('#'):
                continue
        p = path.parent / name
        if not safe_text(name) or p.is_symlink() or not within(p, mount):
            raise ValueError('Disc playlist references a missing or external file: ' + str(path))
        result.append(p.resolve())
    return result


def scan(mount, systems, assignments=None, extra_metadata=()):
    mount = Path(mount).resolve(strict=True)
    assignments = assignments or {}
    if any(sid not in systems for sid in assignments.values()):
        raise ValueError('A saved folder assignment refers to a removed system. Choose its platform again.')
    files = list(walk_files(mount, deadline=time.monotonic() + 180))
    supported = {e for s in systems.values() for e in s['extensions']}
    names = aliases(systems)
    meta_hints, moved_hints, fields, multi = {}, {}, {}, {}
    metadata = [p for p in files if p.name in ('metadata.pegasus.txt', 'metadata.txt')
                or p.name.endswith(('.metadata.pegasus.txt', '.metadata.txt'))]
    for path in [*extra_metadata, *metadata]:
        with path.open('r', errors='replace') as stream:
            marker = stream.readline(256)
        if marker == OWNED:
            continue
        moved = marker == MOVED and path in metadata
        current = None
        for record in metadata_records(path):
            if 'collection' in record:
                choices = names.get(record.get('shortname', '').casefold(), set()) or names.get(record['collection'].casefold(), set())
                current = next(iter(choices)) if len(choices) == 1 else None
                continue
            sid = current
            if moved and 'launch' in record:
                command = storage_launch(record['launch'])
                if command and command[1] in systems:
                    sid = command[1]
            group = []
            for name in (record.get('files', '') + '\n' + record.get('file', '')).splitlines():
                target = path.parent / name
                if not name or target.is_symlink() or not within(target, mount):
                    continue
                target = target.resolve()
                if sid:
                    (moved_hints if moved else meta_hints)[target] = sid
                if target not in moved_hints or moved:
                    fields[target] = (record, path.parent)
                if target not in group:
                    group.append(target)
            for target in group:
                if target not in moved_hints or moved:
                    multi[target] = group
    candidates = [p for p in files if p.suffix.lower().lstrip('.') in supported]
    suppressed = set()
    invalid = []
    # Only a valid, supported descriptor suppresses its data/disc files.
    for path in candidates:
        try:
            suppressed.update(references(path, mount))
        except ValueError as error:
            invalid.append(str(error))
    games, unresolved, grouped = [], {}, set()
    for path in candidates:
        if path in suppressed or path in grouped or any(str(path) in error for error in invalid):
            continue
        ext = path.suffix.lower().lstrip('.')
        choices = [sid for sid, s in systems.items() if ext in s['extensions']]
        hint = moved_hints.get(path) or path_hint(path, mount, names, assignments) or meta_hints.get(path)
        if not hint and ext == 'zip':
            hint = zip_hint(path, systems)
        sid = hint if hint in choices else choices[0] if len(choices) == 1 else None
        if not sid:
            folder = path.parent.relative_to(mount).as_posix()
            item = unresolved.setdefault(folder, dict(folder=folder, count=0, examples=[], candidates=set()))
            item['count'] += 1
            item['candidates'].update(choices)
            if len(item['examples']) < 3:
                item['examples'].append(path.name)
            continue
        record, base = fields.get(path, ({}, path.parent))
        title = record.get('game', path.stem).replace('\n', ' ')
        title = title if safe_text(title) else path.stem
        extra = {k: v for k, v in record.items() if k in FIELDS}
        for key in ASSETS:
            value = record.get(key)
            if value and safe_text(value):
                asset = base / value
                if not asset.is_symlink() and within(asset, mount):
                    extra[key] = str(asset.resolve())
        group = [p for p in multi.get(path, [path]) if p not in suppressed
                 and p.suffix.lower().lstrip('.') in systems[sid]['extensions']]
        if path not in group:
            group.insert(0, path)
        grouped.update(group)
        games.append(dict(system=sid, file=str(path), files=[str(p) for p in group], title=title, fields=extra))
    return dict(games=sorted(games, key=lambda g: (g['system'], g['file'])),
                unresolved=[dict(v, candidates=sorted(v['candidates'])) for _, v in sorted(unresolved.items())],
                warnings=invalid, inspected=len(files))


def render(games, systems, launcher='/usr/local/bin/zamanctl', relative_to=None):
    if not safe_text(launcher) or not Path(launcher).is_absolute():
        raise ValueError('Invalid Zaman launcher path.')
    lines = [OWNED.rstrip(), EXPLICIT_COLLECTIONS.rstrip()]
    collection_files = {}
    launch_commands = {}
    for game in games:
        sid = game['system']
        if sid not in launch_commands:
            launch_commands[sid] = shlex.quote(launcher) + ' launch ' + sid + ' "{file.path}"'
        filenames = [os.path.relpath(p, relative_to) if relative_to else p
                     for p in game.get('files', [game['file']])]
        if not filenames or not all(safe_text(p) for p in filenames) or not safe_text(game['title']):
            raise ValueError('Unsafe game path; the previous index was preserved.')
        collection_files.setdefault(sid, []).extend(filenames)
        # Pegasus adds each game to every earlier collection in its metafile.
        # Write games first, then attach them by path via each collection's filter.
        lines += ['', 'game: ' + game['title'], 'launch: ' + launch_commands[sid]]
        lines += ['file: ' + filenames[0]] if len(filenames) == 1 else ['files:'] + ['  ' + p for p in filenames]
        for key, value in sorted(game.get('fields', {}).items()):
            if key not in FIELDS | ASSETS:
                continue
            if relative_to and key in ASSETS:
                value = os.path.relpath(value, relative_to)
            parts = str(value).splitlines()
            if parts:
                lines += [key + ': ' + parts[0]] + ['  ' + (p or '.') for p in parts[1:]]
    for sid, filenames in sorted(collection_files.items()):
        system = systems[sid]
        lines += ['', 'collection: ' + system['collection'], 'shortname: ' + system['shortname'],
                  'launch: ' + launch_commands[sid], 'files:']
        lines += ['  ' + path for path in dict.fromkeys(filenames)]
    return '\n'.join(lines) + '\n'


def storage_launch(value):
    try:
        args = shlex.split(value)
    except ValueError:
        return None
    if (len(args) == 4 and Path(args[0]).is_absolute() and safe_text(args[0])
            and args[1] == 'launch' and ID.fullmatch(args[2]) and args[3] == '{file.path}'):
        return args[0], args[2]
    return None


def migrate_indexes(config):
    directory = Path(config) / 'pegasus-frontend/metafiles'
    repaired = 0
    for path in sorted(directory.glob('zaman-storage-*.metadata.pegasus.txt')):
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024**2:
            continue
        with path.open() as stream:
            if stream.readline(256) != OWNED or stream.readline(256) == EXPLICIT_COLLECTIONS:
                continue
        systems, games = {}, []
        launcher = sid = None
        for record in metadata_records(path):
            if 'collection' in record and record.keys() == {'collection', 'shortname', 'launch'}:
                command = storage_launch(record['launch'])
                if not command or (launcher is not None and launcher != command[0]):
                    break
                launcher, sid = command
                systems[sid] = record
            elif sid and 'game' in record and record.keys() <= (FIELDS | ASSETS | {'game', 'file', 'files'}):
                filenames = [name for name in (record.get('file', '') + '\n' + record.get('files', '')).splitlines()
                             if name]
                if not filenames or not all(Path(name).is_absolute() for name in filenames):
                    break
                games.append(dict(system=sid, title=record['game'], file=filenames[0], files=filenames,
                                  fields={key: value for key, value in record.items() if key in FIELDS | ASSETS}))
            else:
                break
        else:
            atomic_text(path, render(games, systems, launcher or '/usr/local/bin/zamanctl'), 0o644)
            repaired += 1
    if repaired:
        signal_refresh(config)
    return repaired


def prepare(root, systems, volume_uuid):
    root = Path(root)
    if root.is_symlink():
        raise ValueError('The Zaman directory is a symlink.')
    marker = root / '.zaman-storage.json'
    if marker.exists():
        doc = json.loads(marker.read_text())
        if doc.get('schema') != 1:
            raise ValueError('Unsupported Zaman storage version; existing files were preserved.')
    for relative in ['roms', 'bios', 'saves', 'savestates', 'media'] + ['roms/' + sid for sid in sorted(systems)]:
        directory = root / relative
        for part in [directory, *directory.parents]:
            if part == root.parent:
                break
            if part.is_symlink():
                raise ValueError('A prepared directory is a symlink: ' + str(part))
        directory.mkdir(exist_ok=True)
        if directory.stat().st_dev != root.stat().st_dev:
            raise ValueError('A prepared directory is on another filesystem.')
    notes = root / 'ADD-GAMES.txt'
    if not notes.exists():
        text = 'Zaman game storage\n\nCopy your games into roms/<system>/. Then open Settings > Storage > Scan for games.\n'
        text += 'Existing games elsewhere on this drive can also be indexed without moving them.\n'
        text += 'BIOS and save folders are reserved for storage; emulator paths are not changed by this setup.\n\n'
        text += '\n'.join(sid + ': ' + ', '.join(s['extensions']) for sid, s in sorted(systems.items())) + '\n'
        atomic_text(notes, text, 0o644)
    atomic_text(marker, json.dumps(dict(schema=1, uuid=volume_uuid), indent=2) + '\n', 0o644)


def export_index(config, volume_uuid, result, systems, drive_root=None, launcher='/usr/local/bin/zamanctl'):
    key = hashlib.sha256(volume_uuid.encode()).hexdigest()[:24]
    target = Path(config) / 'pegasus-frontend/metafiles' / ('zaman-storage-' + key + '.metadata.pegasus.txt')
    content = render(result['games'], systems, launcher)
    changed = not target.exists() or target.read_text() != content
    if target.exists() and not target.read_text().startswith(OWNED):
        raise ValueError('Existing metadata is not owned by Zaman Storage; it was preserved.')
    if drive_root:
        portable = Path(drive_root) / 'storage.metadata.pegasus.txt'
        if portable.exists() and not portable.read_text().startswith(OWNED):
            raise ValueError('The drive already has an unrelated storage metadata file; it was preserved.')
        atomic_text(portable, render(result['games'], systems, launcher, Path(drive_root)), 0o644)
    if changed:
        atomic_text(target, content, 0o644)
        signal_refresh(config)
    return target


def remove_index(config, volume_uuid):
    key = hashlib.sha256(volume_uuid.encode()).hexdigest()[:24]
    target = Path(config) / 'pegasus-frontend/metafiles' / ('zaman-storage-' + key + '.metadata.pegasus.txt')
    if target.is_file() and not target.is_symlink() and target.read_text().startswith(OWNED):
        target.unlink()
        signal_refresh(config)


def signal_refresh(config):
    config = Path(config)
    theme = config / 'pegasus-frontend/themes/zaman'
    profile = config / 'zaman/storage-details.json'
    if profile.is_file():
        try:
            settings = json.loads(profile.read_text())
            if settings.get('schema') == 1:
                theme = Path(settings['theme'])
        except (KeyError, ValueError, OSError):
            pass
    if theme.is_symlink() or not (theme / 'theme.qml').is_file():
        return
    directory = theme / 'rom-library-refresh'
    if directory.is_symlink():
        raise ValueError('The theme refresh directory is a symlink.')
    directory.mkdir(exist_ok=True)
    new = directory / (secrets.token_hex(16) + '.signal')
    new.touch(exist_ok=False)
    for old in directory.glob('*.signal'):
        if old != new:
            old.unlink()
