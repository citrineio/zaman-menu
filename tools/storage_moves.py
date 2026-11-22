"""Journaled, verified moves. All game and metadata writes run as the user."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time
import uuid

from storage_library import (ASSETS, FIELDS, MOVED, OWNED, SKIP, atomic_text, export_index, metadata_records,
                             references, render, safe_text, scan, signal_refresh, walk_files)
from storage_notify import notify

INTERNAL = Path('/srv/zaman/roms')
MANAGED_INTERNAL = Path(os.environ.get('XDG_DATA_HOME', Path.home()/'.local/share'))/'zaman/storage-games'
TERMINAL = {'complete', 'cancelled'}


def fingerprint(path):
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode):
        raise ValueError('Game data must be a regular file: ' + str(path))
    return [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def save(path, value):
    atomic_text(path, json.dumps(value, indent=2) + '\n')
    fsync_dir(Path(path).parent)


def session_idle():
    service = 'com.kawnelectro.Zaman.Session1'
    def call(method):
        result = subprocess.run(['busctl', '--user', '--json=short', '--timeout=2', 'call', service,
            '/com/kawnelectro/Zaman/Session1', service, method], capture_output=True, text=True, timeout=3, check=True)
        return json.loads(result.stdout)['data']
    try:
        state, fg, native, store = [call(m) for m in ('Status', 'ForegroundStatus', 'InstalledGameStatus', 'StorefrontStatus')]
        idle = (len(state) == 6 and state[0] == 'Idle' and len(fg) == 3 and fg[0] in ('library', 'menu')
            and fg[1] in ('', 'library') and len(native) == 6 and native[3] not in ('Starting', 'Running', 'Stopping', 'CleanupFailed')
            and len(store) == 6 and not store[4] and store[2] not in ('Starting', 'Stopping', 'CleanupFailed'))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        idle = False
    if not idle:
        raise ValueError('Return to the library and close active games before moving game files.')


def sources(api, snapshot=None):
    result = []
    MANAGED_INTERNAL.mkdir(parents=True,exist_ok=True)
    if MANAGED_INTERNAL.is_symlink():raise ValueError('Internal storage location is linked.')
    result.append(dict(id='internal', identity=str(MANAGED_INTERNAL.stat().st_dev), name='Built-in game storage',
                       internal=True, writable=os.access(MANAGED_INTERNAL,os.W_OK)))
    if snapshot is None:
        snapshot = api.broker(dict(action='inventory'))
    for disk in snapshot['devices']:
        if disk['protected']:
            continue
        for v in disk['volumes']:
            if v.get('mountable', True) and v['uuid'] and not v['duplicateUUID']:
                result.append(dict(id=v['id'], identity=v['identity'], name=disk['name'] + ' · ' + v['name'], internal=False,
                                   writable=not v['readOnly']))
    return result


def resolve(api, request, destination=False):
    if request.get('id') == 'internal':
        MANAGED_INTERNAL.mkdir(parents=True,exist_ok=True)
        if MANAGED_INTERNAL.is_symlink() or request.get('identity') != str(MANAGED_INTERNAL.stat().st_dev):
            raise ValueError('Built-in game storage changed. Select it again.')
        roots=list(dict.fromkeys(p.resolve() for p in (INTERNAL, MANAGED_INTERNAL) if p.is_dir()))
        selected_root=MANAGED_INTERNAL if destination else roots[0]
        return dict(request, root=str(selected_root.resolve()),roots=[str(p.resolve()) for p in roots],
                    deviceNumber=selected_root.stat().st_dev,uuid='internal',internal=True,
                    name='Built-in game storage',filesystem='ext4')
    v, _ = api.mounted(request)
    if destination and v.get('readOnly'):
        raise ValueError('This storage is read-only.')
    return dict(v, root=str(Path(v['mountpoint']).resolve()), internal=False)


def prepared_root(storage):
    if storage['internal']:
        return Path(storage['root'])
    root = Path(storage['root'])
    workspace = root / 'zaman'
    try:
        with os.fdopen(open_under(root, workspace / '.zaman-storage.json')) as marker:
            doc = json.loads(marker.read(4096))
        if isinstance(doc, dict) and doc.get('schema') == 1 and doc.get('uuid') == storage['uuid']:
            return workspace
    except (OSError, ValueError):
        pass
    return None


def existing_folder(storage, relative):
    if not safe_text(relative) or Path(relative).is_absolute():
        raise ValueError('Choose an existing directory on this drive.')
    parts = Path(relative).parts
    if any(part.startswith('.') or part.casefold() in SKIP for part in parts):
        raise ValueError('Choose a game directory on this drive.')
    root = Path(storage['root'])
    folder = root.joinpath(*parts)
    fd = open_under(root, folder, os.O_RDONLY | os.O_DIRECTORY) if parts else os.open(
        root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    os.close(fd)
    return folder


def selected_game(api, request):
    source = resolve(api, request['source'])
    systems = api.registry()
    prefs = api.settings()['volumes'].get(source['uuid'], {})
    games = scan_source(source, systems, prefs.get('assignments', {}), api.CONFIG)['games']
    enrich_games(games, api.CONFIG)
    game = next((g for g in games if game_id(g) == request.get('game')), None)
    if game is None:
        raise ValueError('The selected game changed. Refresh the game list.')
    return select_source_root(source, game), games, game, systems


def collection_choices(game, systems):
    extensions = {Path(path).suffix.lower().lstrip('.') for path in game['files']}
    return [dict(id=sid, name=system['collection']) for sid, system in sorted(
        systems.items(), key=lambda pair: pair[1]['collection'].casefold())
        if extensions <= set(system['extensions'])]


def destination_options(api, request):
    dest = resolve(api, request['destination'], destination=True)
    workspace = prepared_root(dest)
    if workspace is None:
        if request.get('useFolders') is not True:
            return dict(mode='unprepared', name=dest['name'])
        folder = existing_folder(dest, request.get('folder', '.'))
        dirs = []
        for path in sorted(folder.iterdir(), key=lambda path: path.name.casefold()):
            if (not path.name.startswith('.') and path.name.casefold() not in SKIP
                    and safe_text(path.name) and not path.is_symlink()
                    and path.is_dir() and path.stat().st_dev == folder.stat().st_dev
                    and os.access(path, os.R_OK | os.X_OK)):
                dirs.append(dict(name=path.name, path=path.relative_to(dest['root']).as_posix()))
        return dict(mode='folders', name=dest['name'], folder=folder.relative_to(dest['root']).as_posix(),
                    folders=dirs, writable=os.access(folder, os.W_OK | os.X_OK))
    _, _, game, systems = selected_game(api, request)
    same = request['source']['id'] == request['destination']['id']
    return dict(mode='collections', name=dest['name'], same=same, current=game['system'],
                collections=collection_choices(game, systems))


def game_id(game):
    return hashlib.sha256((game['system'] + '\0' + game['file']).encode()).hexdigest()[:32]


def library(api, request):
    source = resolve(api, request)
    systems = api.registry()
    prefs = api.settings()['volumes'].get(source['uuid'], {})
    result = scan_source(source,systems,prefs.get('assignments',{}),api.CONFIG)
    enrich_games(result['games'],api.CONFIG)
    games = [dict(id=game_id(g), title=g['title'], system=g['system'], collection=systems[g['system']]['collection'])
             for g in result['games']]
    return dict(source=request, games=games, message=str(len(games)) + ' games available to move.')


def intent(api,paths):
    if not isinstance(paths,list) or not 1<=len(paths)<=64 or any(not safe_text(p) or not Path(p).is_absolute() for p in paths):
        raise ValueError('Invalid game selection.')
    wanted = set()
    for raw in paths:
        path = Path(raw)
        if path.is_relative_to(INTERNAL):
            path = INTERNAL.resolve() / path.relative_to(INTERNAL)
        wanted.add(path)
    if any(not p.is_file() or p != p.resolve() for p in wanted):
        raise ValueError('One of the selected game files is unavailable or uses a link.')
    snapshot = api.broker(dict(action='inventory'))
    choices = sources(api, snapshot)
    source_request=None
    matching_volumes = []
    for disk in snapshot['devices']:
        if disk['protected']:
            continue
        for volume in disk['volumes']:
            mount = volume['mountpoint']
            if mount and not volume['duplicateUUID'] and all(p.is_relative_to(mount) for p in wanted):
                matching_volumes.append(volume)
    for volume in sorted(matching_volumes, key=lambda v: len(v['mountpoint']), reverse=True):
        source_request = next((s for s in choices if s['id'] == volume['id']), None)
        if source_request:
            break
    if source_request is None and all(
            any(p.is_relative_to(root) for root in (INTERNAL.resolve(), MANAGED_INTERNAL.resolve())) for p in wanted):
        source_request = next(s for s in choices if s['id'] == 'internal')
    if source_request is None:raise ValueError('This game is not on connected Zaman game storage.')
    source=resolve(api,source_request)
    result=scan_source(source,api.registry(),api.settings()['volumes'].get(source['uuid'],{}).get('assignments',{}),api.CONFIG)
    enrich_games(result['games'],api.CONFIG)
    matches=[]
    for game in result['games']:
        launches = {Path(p) for p in game['files']}
        if wanted <= launches:
            matches.append(game)
        elif wanted & launches:
            resolved = select_source_root(source, game)
            if wanted <= dependencies(game, resolved['root']):
                matches.append(game)
    if len(matches)!=1:raise ValueError('The selected game could not be identified uniquely. Use Storage to review its platform first.')
    game=matches[0]
    return dict(sources=choices,source=source_request,game=dict(id=game_id(game),title=game['title'],system=game['system']))


def scan_source(source, systems, assignments, config=None):
    games = {}
    for root in source.get('roots', [source['root']]):
        extra = configured_metadata(config, root) if config else ()
        for game in scan(root, systems, assignments, extra)['games']:
            games[game['file']] = game
    return dict(games=list(games.values()))


def enrich_games(games,config):
    lookup={str(Path(g['file']).resolve()):g for g in games}
    directory=Path(config)/'pegasus-frontend/metafiles'
    for p in directory.glob('*.metadata.pegasus.txt'):
        if p.is_symlink():continue
        for record in metadata_records(p):
            if 'game' not in record:continue
            for name in (record.get('file','')+'\n'+record.get('files','')).splitlines():
                target=str((p.parent/name).resolve())
                game=lookup.get(target)
                if not game:continue
                if game['title']==Path(game['file']).stem and safe_text(record['game']):game['title']=record['game']
                for key,value in record.items():
                    if key in FIELDS:game['fields'].setdefault(key,value)
                    elif key in ASSETS and safe_text(value):
                        asset=p.parent/value
                        if asset.is_file() and not asset.is_symlink():game['fields'].setdefault(key,str(asset.resolve()))


def select_source_root(source,game):
    roots=[Path(r) for r in source.get('roots',[source['root']])]
    root=next((r for r in roots if Path(game['file']).is_relative_to(r)),None)
    if root is None:raise ValueError('The game no longer belongs to the selected storage.')
    return dict(source,root=str(root),deviceNumber=root.stat().st_dev)


def dependencies(game, root):
    root = Path(root).resolve()
    found, stack = set(), [Path(p) for p in game.get('files', [game['file']])]
    while stack:
        path = stack.pop()
        if path in found:
            continue
        if not path.is_relative_to(root) or path.is_symlink() or path.stat().st_dev != root.stat().st_dev:
            raise ValueError('A game dependency is outside its storage: ' + str(path))
        if path.suffix.lower() in ('.gdi', '.ccd', '.mds'):
            raise ValueError('Moving this disc descriptor is not supported yet. Its original files were preserved.')
        fingerprint(path)
        found.add(path)
        stack.extend(references(path, root))
    return found


def assets(game, root):
    result = {k: Path(v) for k, v in game.get('fields', {}).items() if k in ASSETS}
    # Pegasus's automatic artwork layout, plus common separate scraper outputs.
    parent = Path(game['file']).parent
    stems = [Path(game['file']).stem, game['title']]
    roles = {'boxfront':['covers','cover','boxfront'], 'screenshot':['screenshots','screenshot'],
             'logo':['wheels','wheel','logos','logo'], 'background':['backgrounds','fanart','background'], 'marquee':['marquees','marquee']}
    for role, folders in roles.items():
        key = 'assets.' + role
        if key in result and result[key].is_file():
            continue
        result.pop(key, None)
        candidates = []
        for stem in stems:
            for ext in ('png','jpg','jpeg','webp'):
                candidates += [parent/'media'/stem/(role+'.'+ext)]
                candidates += [parent/'media'/folder/(stem+'.'+ext) for folder in folders]
        for p in candidates:
            if safe_text(str(p)) and p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(root):
                result[key] = p.resolve()
                break
    return {key: p for key, p in result.items() if p.is_relative_to(root) and not p.is_symlink()
            and p.is_file() and p.stat().st_dev == Path(root).stat().st_dev}


def prune_text(text, directory, moved):
    """Remove only complete game blocks that reference the moved launch files."""
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.match(r'(?i)^(game|collection)\s*:', line)] + [len(lines)]
    remove = []
    for start, end in zip(starts, starts[1:]):
        if not re.match(r'(?i)^game\s*:', lines[start]):
            continue
        block = ''.join(lines[start:end])
        # Parse the small block through the same line/list rules as Pegasus.
        names, collecting = [], False
        for line in block.splitlines()[1:]:
            if line[:1].isspace():
                if collecting: names.append(line.strip())
                continue
            key, sep, value = line.partition(':')
            collecting = bool(sep and key.strip().lower() in ('file','files'))
            if collecting and value.strip(): names.append(value.strip())
        targets = {str((Path(directory)/n).resolve()) for n in names}
        if targets & moved:
            if not targets <= moved:
                raise ValueError('A metadata entry shares launch files with another game; the move needs review.')
            remove.append((start,end))
    for start,end in reversed(remove): del lines[start:end]
    return ''.join(lines)


def configured_metadata(config, root):
    root, config = Path(root), Path(config)
    directories = [config/'pegasus-frontend/metafiles']
    dirs = config/'pegasus-frontend/game_dirs.txt'
    if dirs.is_file() and dirs.stat().st_size < 1024**2:
        directories += [Path(s.strip()) for s in dirs.read_text().splitlines() if s.strip().startswith('/')]
    found = set()
    for directory in directories:
        if directory.is_symlink() or not directory.is_dir() or directory.resolve().is_relative_to(root):
            continue
        for path in directory.iterdir():
            if (path.is_file() and not path.is_symlink()
                    and path.name.endswith(('metadata.txt', 'metadata.pegasus.txt'))):
                found.add(path)
    return sorted(found)


def metadata_paths(root, config):
    root = Path(root)
    local = {p for p in walk_files(root) if p.name in ('metadata.txt', 'metadata.pegasus.txt')
             or p.name.endswith(('.metadata.txt', '.metadata.pegasus.txt'))}
    return sorted(local | set(configured_metadata(config, root)))


def metadata_edits(root, config, launches):
    edits = []
    for path in metadata_paths(root, config):
        if path.stat().st_size > 8*1024**2:
            raise ValueError('A metadata file is too large to update safely.')
        before = path.read_text()
        after = prune_text(before, path.parent, {str(p) for p in launches})
        if before != after:
            if not os.access(path.parent, os.W_OK | os.X_OK):
                raise ValueError('Source metadata is not writable: ' + str(path))
            edits.append(dict(path=str(path), before=before, after=after))
    return edits


def destination_parent(request, source, dest, game, systems):
    workspace = prepared_root(dest)
    if workspace is None:
        if request.get('useFolders') is not True:
            raise ValueError('Confirm using existing folders on this drive first.')
        folder = existing_folder(dest, request.get('folder', '.'))
        # Keep the collection when storing a game on an unprepared drive.
        return folder, game['system']
    sid = request.get('collection', game['system'])
    if sid not in {entry['id'] for entry in collection_choices(game, systems)}:
        raise ValueError('The chosen collection cannot launch this file type.')
    # An unprepared volume can still hold games. A prepared volume uses its
    # collection folders, including when the selected game is on that volume.
    folder = workspace / sid if dest['internal'] else workspace / 'roms' / sid
    return folder, sid


def game_parts(source, games, game):
    payload = dependencies(game, source['root'])
    shared = set()
    for other in games:
        if other is game: continue
        if not Path(other['file']).is_relative_to(source['root']):continue
        try: shared.update(dependencies(other, source['root']) & payload)
        except (OSError, ValueError):
            # Unknown descriptors could refer to these tracks. Keep dependencies
            # conservatively, while still moving the selected launch descriptor.
            shared.update(payload - {Path(p) for p in game.get('files',[game['file']])})
    launches = {Path(p) for p in game.get('files',[game['file']])}
    if launches & shared:
        raise ValueError('Another game uses the same launch file. It cannot be removed safely.')
    return payload, shared, launches


def create_plan(api, request):
    session_idle()
    source, games, game, systems = selected_game(api, request)
    deleting = request.get('action') == 'delete-plan'
    dest = None if deleting else resolve(api, request['destination'], destination=True)
    payload, shared, launches = game_parts(source, games, game)
    if deleting:
        return create_delete_plan(api, request, source, game, payload - shared, launches)
    target_parent, system = destination_parent(request, source, dest, game, systems)
    with_parent = target_parent
    while not with_parent.exists() and not with_parent.is_symlink():
        with_parent = with_parent.parent
    if with_parent.is_symlink() or not os.access(with_parent, os.W_OK | os.X_OK):
        raise ValueError('The destination folder is not writable.')
    if system == game['system'] and request['source']['id'] == request['destination']['id']:
        workspace = prepared_root(dest)
        game_parent = Path(game['file']).parent
        moved_here = game_parent.parent == target_parent and (game_parent / '.zaman-move.json').is_file()
        if workspace is not None or game_parent == target_parent or moved_here:
            raise ValueError('This game is already in that collection or folder. Choose a different destination.')
    art = assets(game, Path(source['root']))
    paths = payload | set(art.values())
    common = Path(os.path.commonpath([str(p.parent) for p in paths]))
    ident = uuid.uuid4().hex
    slug = re.sub(r'[^A-Za-z0-9._ -]', '_', game['title']).strip(' .')[:72] or 'Game'
    final = target_parent / (slug + '-' + ident[:8])
    stage = target_parent / ('.zaman-move-' + ident)
    items = []
    for p in sorted(paths):
        if not safe_text(str(p)): raise ValueError('A filename cannot be moved safely.')
        if not os.access(p.parent, os.W_OK | os.X_OK) and p in payload - shared:
            raise ValueError('The original game folder is not writable: ' + str(p.parent))
        fp = fingerprint(p)
        if dest.get('filesystem') == 'vfat' and fp[2] >= 2**32:
            raise ValueError('This game is too large for FAT32. Choose exFAT or ext4 storage.')
        items.append(dict(source=str(p), relative=p.relative_to(common).as_posix(), fingerprint=fp,
                          remove=p in payload - shared, sha256=None, removed=False))
    total = sum(i['fingerprint'][2] for i in items)
    if shutil.disk_usage(dest['root']).free < total + 128*1024**2:
        raise ValueError('The destination does not have enough free space, including a 128 MiB margin.')
    edits = metadata_edits(source['root'], api.CONFIG, launches)
    job = dict(schema=1,id=ident,phase='planned',title=game['title'],system=system,game=game,
               source=source,destination=dest,sourceRequest=request['source'],destinationRequest=request['destination'],
               useFolders=request.get('useFolders') is True, folder=request.get('folder', '.'),
               stage=str(stage),final=str(final),common=str(common),items=items,total=total,edits=edits,
               art={k:str(p) for k,p in art.items()},created=time.time(),error='')
    folder = api.STATE/'moves'/ident
    folder.mkdir(parents=True,mode=0o700)
    save(folder/'job.json',job)
    return dict(plan=dict(id=ident,title=game['title'],source=source['name'],destination=dest['name'],
                          target=str(target_parent.relative_to(dest['root'])) if job['useFolders'] else systems[system]['collection'],
                          bytes=total,files=len(items),shared=len(shared),message='Files will be copied and verified before the originals are removed.'))


def load_job(api, ident):
    if not isinstance(ident,str) or not re.fullmatch('[0-9a-f]{32}',ident): raise ValueError('Invalid move request.')
    path = api.STATE/'moves'/ident/'job.json'
    job = json.loads(path.read_text())
    if job.get('schema') != 1 or job.get('id') != ident: raise ValueError('Unsupported move journal.')
    return path,job


def open_under(root, path, flags=os.O_RDONLY, mode=0o600):
    root,path=Path(root),Path(path)
    relative=path.relative_to(root)
    if '..' in relative.parts or not relative.parts: raise ValueError('Invalid file path.')
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    device=os.fstat(fd).st_dev
    try:
        for part in relative.parts[:-1]:
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=nxt
            if os.fstat(fd).st_dev != device: raise ValueError('A path crosses another filesystem.')
        result=os.open(relative.name,flags|os.O_NOFOLLOW,mode,dir_fd=fd)
        if os.fstat(result).st_dev != device:
            os.close(result);raise ValueError('A file crosses another filesystem.')
        return result
    finally: os.close(fd)


def digest_file(root,path):
    digest=hashlib.sha256()
    with os.fdopen(open_under(root,path),'rb') as stream:
        for block in iter(lambda:stream.read(4*1024**2),b''): digest.update(block)
    return digest.hexdigest()


def mkdirs_under(root,directory):
    root,directory=Path(root),Path(directory)
    current=root
    for name in directory.relative_to(root).parts:
        current=current/name
        try:current.mkdir(mode=0o755)
        except FileExistsError:pass
        if current.is_symlink() or not current.is_dir() or current.stat().st_dev != root.stat().st_dev:
            raise ValueError('The destination directory changed or is linked.')


def publish_directory(stage,final):
    libc=ctypes.CDLL(None,use_errno=True)
    if not hasattr(libc,'renameat2'):raise ValueError('Atomic moves are unavailable on this system.')
    if libc.renameat2(-100,os.fsencode(stage),-100,os.fsencode(final),1):
        code=ctypes.get_errno()
        raise OSError(code,os.strerror(code),str(final))
    fsync_dir(Path(final).parent)


def stream_progress(job,phase,done=0,message=''):
    print(json.dumps(dict(type='storage-progress',job=job['id'],phase=phase,total=job['total'],
                          done=done,message=message or phase,canCancel=phase in ('copying','verifying'))),flush=True)


class Cancelled(Exception):pass


def execute(api, ident, progress=stream_progress):
    path,job=load_job(api,ident)
    if job['phase']=='complete':return dict(message='Game move is already complete.')
    if job['phase']=='cancelled':raise ValueError('This move was cancelled. Start a new move.')
    if job['phase']=='planned' and time.time()-job['created']>300:raise ValueError('Move confirmation expired. Select the destination again.')
    session_idle()
    if job.get('operation') == 'delete':
        return execute_delete(api, path, job)
    source=select_source_root(resolve(api,job['sourceRequest']),job['game'])
    dest=resolve(api,job['destinationRequest'],destination=True)
    if source['root']!=job['source']['root'] or dest['root']!=job['destination']['root']:
        raise ValueError('A storage location changed. Reconnect it at its previous location before resuming this move.')
    if 'useFolders' in job:
        selection = dict(useFolders=job['useFolders'], folder=job['folder'], collection=job['system'])
        parent, _ = destination_parent(selection, source, dest, job['game'], api.registry())
        if parent != Path(job['final']).parent:
            raise ValueError('The destination setup changed. Choose it again before moving.')
    cancel=path.parent/'cancel'
    stage,final=Path(job['stage']),Path(job['final'])
    root=Path(dest['root'])
    def check():
        expected=os.stat(dest['device']).st_rdev if not dest['internal'] else dest['deviceNumber']
        if root.stat().st_dev != expected:
            raise ValueError('Destination storage was disconnected.')
        if Path(source['root']).stat().st_dev != job['items'][0]['fingerprint'][0]:
            raise ValueError('Source storage was disconnected.')
    def cancelled():
        if cancel.exists():raise Cancelled('Move cancelled. Original files were kept.')
    check()
    notify('move:'+ident+':started','Moving game',job['title'],'copying')
    try:
        if not final.exists():
            mkdirs_under(root,stage.parent)
            if not stage.exists():
                stage.mkdir(mode=0o700)
                save(stage/'.zaman-move.json',dict(id=ident))
            if stage.is_symlink() or json.loads((stage/'.zaman-move.json').read_text()).get('id')!=ident:
                raise ValueError('The temporary game folder is not owned by this move.')
            job['phase']='copying';save(path,job)
            done=0;last=0
            for item in job['items']:
                cancelled();check()
                src=Path(item['source']);dst=stage/item['relative']
                if fingerprint(src)!=item['fingerprint']:raise ValueError('The source game changed during the move.')
                if item['sha256'] and dst.exists() and digest_file(root,dst)==item['sha256']:
                    done+=item['fingerprint'][2];continue
                mkdirs_under(root,dst.parent)
                temporary=dst.with_name('.'+dst.name+'.partial')
                temporary.unlink(missing_ok=True)
                digest=hashlib.sha256()
                with os.fdopen(open_under(source['root'],src),'rb') as reader, os.fdopen(open_under(root,temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL),'wb') as writer:
                    if [os.fstat(reader.fileno()).st_dev,os.fstat(reader.fileno()).st_ino] != item['fingerprint'][:2]:raise ValueError('The source game changed.')
                    while True:
                        block=reader.read(4*1024**2)
                        if not block:break
                        cancelled();writer.write(block);digest.update(block);done+=len(block)
                        if time.monotonic()-last>0.5:
                            progress(job,'copying',done,'Copying '+src.name);last=time.monotonic()
                    writer.flush();os.fsync(writer.fileno())
                if fingerprint(src)!=item['fingerprint']:raise ValueError('The source game changed while being copied.')
                progress(job,'verifying',done,'Verifying '+src.name)
                if digest_file(root,temporary)!=digest.hexdigest():raise ValueError('Copy verification failed. Originals were preserved.')
                os.replace(temporary,dst);fsync_dir(dst.parent)
                item['sha256']=digest.hexdigest();save(path,job)
            cancelled();check();session_idle()
            progress(job,'publishing',job['total'],'Preparing the verified game copy…')
            copied=dict(job['game'],system=job['system'],file=str(final/Path(job['game']['file']).relative_to(job['common'])),
                files=[str(final/Path(p).relative_to(job['common'])) for p in job['game'].get('files',[job['game']['file']])],
                fields={k: v for k, v in job['game'].get('fields', {}).items() if k not in ASSETS})
            copied['fields'].update({k:str(final/Path(p).relative_to(job['common'])) for k,p in job['art'].items()})
            metadata=render([copied],api.registry(),shutil.which('zamanctl') or '/usr/local/bin/zamanctl',final)
            # The local sidecar is deliberately readable by the normal scanner.
            metadata=metadata.replace(OWNED, MOVED, 1)
            atomic_text(stage/'game.metadata.pegasus.txt',metadata,0o644);fsync_dir(stage)
            publish_directory(stage,final)
            job['phase']='published';save(path,job)
        if final.is_symlink() or json.loads((final/'.zaman-move.json').read_text()).get('id')!=ident:
            raise ValueError('Destination folder identity changed. Originals were preserved.')
        check()
        # Reverify the published copy, including recovery after a crash/reboot.
        for item in job['items']:
            if not item['sha256'] or digest_file(root,final/item['relative'])!=item['sha256']:
                raise ValueError('The destination copy changed. Originals were preserved.')
            original=Path(item['source'])
            if original.exists() and not item['removed'] and fingerprint(original)!=item['fingerprint']:
                raise ValueError('An original changed. Both versions were kept and library metadata was preserved.')
        session_idle();progress(job,'metadata',job['total'],'Updating your library…')
        resuming_cleanup=job.get('committed',False)
        job['phase']='metadata';save(path,job)
        apply_metadata(job, resuming_cleanup)
        remember_removal(api, job)
        removed = {item['source'] for item in job['items'] if item['remove']}
        new_paths = {str(final / Path(p).relative_to(job['common'])) for p in job['game']['files']}
        index_storage(api, dest, removed if dest['root'] == source['root'] else set(),
                      required=(new_paths, job['system']))
        if dest['root'] != source['root']:
            index_storage(api, source, removed)
        job['phase']='removing-originals';job['committed']=True;save(path,job)
        progress(job,'removing-originals',job['total'],'Finishing verified move…')
        remove_originals(path, job, source, check)
        job['phase']='complete';job['error']='';save(path,job)
        signal_refresh(api.CONFIG)
        notify('move:'+ident+':complete','Game moved',job['title']+' → '+dest['name'])
        return dict(message=job['title']+' moved to '+dest['name']+'.',job=ident)
    except Cancelled as error:
        if not final.exists() and stage.is_dir() and not stage.is_symlink():shutil.rmtree(stage)
        job['phase']='cancelled';job['error']=str(error);save(path,job)
        notify('move:'+ident+':cancelled','Move cancelled','Original game files were kept.','cancelled')
        return dict(message=str(error),job=ident)
    except Exception as error:
        job['error']=str(error);save(path,job)
        notify('move:'+ident+':failed','Game move needs attention',job['title']+': '+str(error),'failed')
        raise


def remember_removal(api, job):
    tomb = api.STATE / 'moved-files.json'
    rules = json.loads(tomb.read_text()) if tomb.exists() else []
    if not any(rule['id'] == job['id'] for rule in rules):
        rules.append(dict(files=job['game']['files'], metadata=[e['path'] for e in job['edits']], id=job['id']))
        save(tomb, rules)


def apply_metadata(job, committed):
    for edit in job['edits']:
        path = Path(edit['path'])
        if path.is_symlink():
            raise ValueError('Source metadata is linked. Game files were preserved.')
        current = path.read_text()
        if current == edit['after']:
            continue
        if current == edit['before']:
            revised = edit['after']
        elif committed:
            revised = prune_text(current, path.parent, set(job['game']['files']))
        else:
            raise ValueError('Source metadata changed. Game files were kept.')
        if revised != current:
            atomic_text(path, revised, path.stat().st_mode & 0o777)


def remove_originals(path, job, source, check):
    root = Path(source['root'])
    for item in job['items']:
        if not item['remove'] or item['removed']:
            continue
        check()
        session_idle()
        original = Path(item['source'])
        parent_fd = (open_under(root, original.parent, os.O_RDONLY | os.O_DIRECTORY)
                     if original.parent != root else os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        try:
            try:
                info = os.stat(original.name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass  # An interrupted cleanup may already have removed this file.
            else:
                current = [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
                if current != item['fingerprint']:
                    raise ValueError('An original file changed. Its new version was preserved.')
                os.unlink(original.name, dir_fd=parent_fd)
                os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        item['removed'] = True
        save(path, job)


def create_delete_plan(api, request, source, game, files, launches):
    if source.get('readOnly'):
        raise ValueError('This storage is read-only.')
    items = []
    for path in sorted(files):
        if not os.access(path.parent, os.W_OK | os.X_OK):
            raise ValueError('The original game folder is not writable: ' + str(path.parent))
        items.append(dict(source=str(path), fingerprint=fingerprint(path), remove=True, removed=False))
    ident = uuid.uuid4().hex
    job = dict(schema=1, id=ident, operation='delete', phase='planned', title=game['title'],
               game=game, source=source, sourceRequest=request['source'], items=items,
               edits=metadata_edits(source['root'], api.CONFIG, launches), created=time.time(), error='')
    save(api.STATE / 'moves' / ident / 'job.json', job)
    return dict(plan=dict(id=ident, title=game['title'], source=source['name'], files=len(items),
                          message='This permanently deletes the game files. Shared files and artwork are kept.'))


def execute_delete(api, path, job):
    source = select_source_root(resolve(api, job['sourceRequest']), job['game'])
    root = Path(source['root'])

    def check():
        if source['root'] != job['source']['root'] or root.stat().st_dev != job['items'][0]['fingerprint'][0]:
            raise ValueError('The original storage changed. Reconnect it before continuing.')

    try:
        check()
        committed = job.get('committed', False)
        if not committed:
            for item in job['items']:
                if fingerprint(Path(item['source'])) != item['fingerprint']:
                    raise ValueError('An original changed. The game was preserved.')
        job['phase'] = 'metadata'
        save(path, job)
        apply_metadata(job, committed)
        remember_removal(api, job)
        index_storage(api, source, {item['source'] for item in job['items']})
        job.update(phase='removing-originals', committed=True)
        save(path, job)
        remove_originals(path, job, source, check)
        job.update(phase='complete', error='')
        save(path, job)
        signal_refresh(api.CONFIG)
        return dict(message=job['title'] + ' was deleted.', job=job['id'])
    except Exception as error:
        job['error'] = str(error)
        save(path, job)
        raise


def index_storage(api, storage, removed, required=None):
    if storage['internal'] and Path(storage['root']) == INTERNAL.resolve() and required is None:
        return
    systems = api.registry()
    prefs = api.settings()['volumes'].get(storage['uuid'], {})
    root = storage['root']
    result = scan(root, systems, prefs.get('assignments', {}), configured_metadata(api.CONFIG, root))
    result['games'] = [g for g in result['games'] if not set(g['files']) & removed]
    if required:
        paths, sid = required
        if not any(g['system'] == sid and set(g['files']) == paths for g in result['games']):
            raise ValueError('The destination game could not be indexed in the selected collection. Originals were kept.')
    workspace = prepared_root(storage)
    portable = workspace if workspace and not storage['internal'] and os.access(workspace, os.W_OK) else None
    launcher = shutil.which('zamanctl') or '/usr/local/bin/zamanctl'
    export_index(api.CONFIG, storage['uuid'], result, systems, portable, launcher)
    if not storage['internal']:
        api.update_settings(storage['uuid'], indexed=True, prepared=workspace is not None,
                            count=len(result['games']), unresolved=sum(g['count'] for g in result['unresolved']))


def recoveries(api):
    result=[]
    for path in (api.STATE/'moves').glob('*/job.json'):
        try:
            job=json.loads(path.read_text())
            if job['phase'] not in TERMINAL and job['phase']!='planned':
                result.append(dict(id=job['id'],title=job['title'],phase=job['phase'],operation=job.get('operation', 'move'),error=job.get('error','')))
        except (OSError,ValueError,KeyError):continue
    return result


def repair_source_metadata(api):
    path=api.STATE/'moved-files.json'
    if not path.exists():return
    for rule in json.loads(path.read_text()):
        if any(Path(p).exists() for p in rule['files']):continue
        moved={str(Path(p).absolute()) for p in rule['files']}
        for name in rule['metadata']:
            p=Path(name)
            if not p.is_file() or p.is_symlink() or p.stat().st_size>8*1024**2:continue
            before=p.read_text();after=prune_text(before,p.parent,moved)
            if before!=after:
                atomic_text(p,after,p.stat().st_mode&0o777);signal_refresh(api.CONFIG)
