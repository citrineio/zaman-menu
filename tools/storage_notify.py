"""Best-effort events through Zaman's existing notification service."""
import json
import os
from pathlib import Path
import socket


def notify(key, title, body='', state='complete'):
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid())))
    message = dict(action='event', source='Zaman Storage', key='storage:' + key,
                   title=title[:160], body=body[:800], category='transfer', state=state)
    try:
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(0.3)
            peer.connect(str(runtime / 'zaman-notifications/control.sock'))
            peer.sendall((json.dumps(message) + '\n').encode())
            with peer.makefile('rb') as stream:
                return json.loads(stream.readline(256 * 1024)).get('type') != 'error'
    except (OSError, ValueError):
        return False
