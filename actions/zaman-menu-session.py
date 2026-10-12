#!/usr/bin/env python3
"""One exit action on the session bus; sessiond owns emulator shutdown."""
import json
import os
from pathlib import Path
import socket
import sys
import time

SERVICE = 'com.kawnelectro.Zaman.Session1'
PATH = '/com/kawnelectro/Zaman/Session1'
INTERFACE = SERVICE
STATUS_SIGNATURE = '(ssssss)'


def emit(kind, **fields):
    print(json.dumps({'type': kind, **fields}), flush=True)


def log(message):
    try:
        with (Path(os.environ['XDG_RUNTIME_DIR']) / 'zaman-menu-timing.log').open('a') as stream:
            stream.write(f'pid={os.getpid()} [menu-exit] {message}\n')
    except (KeyError, OSError):
        pass


def exit_game(call, emit_event=emit, clock=time.monotonic, pause=time.sleep, timeout=120):
    """call is already pinned to one unique sessiond bus owner."""
    deadline = clock() + timeout
    initial = call('Status', STATUS_SIGNATURE)
    identity = initial[1:4]
    if initial[0] == 'Idle':
        emit_event('exit-result', ok=True, message='The game has already closed.')
        return
    if initial[0] not in ('Active', 'Stopping'):
        raise RuntimeError(initial[5] or 'There is no active game session to close.')
    if initial[0] == 'Active':
        foreground = call('ForegroundStatus', '(sss)')[0]
        if foreground != 'game':
            raise RuntimeError('Another Zaman screen has control. Return to the game before trying again.')
        # Never resend this call after an error/timeout: its delivery may already
        # have succeeded. A subsequent explicit retry reads Stopping and waits.
        call('ExitGame', '()')
        log('ExitGame accepted')
    emit_event('exit-progress', message='Closing game…')
    while clock() < deadline:
        status = call('Status', STATUS_SIGNATURE)
        if status[1:4] != identity:
            raise RuntimeError('The game session changed while closing. No further exit request was sent.')
        if status[0] == 'Idle':
            log('game finished; sessiond reports Idle')
            emit_event('exit-result', ok=True, message='Game closed.')
            return
        if status[0] == 'Failed':
            raise RuntimeError(status[5] or 'The game could not be closed normally.')
        if status[0] not in ('Active', 'Stopping'):
            raise RuntimeError('Unexpected game state: ' + status[0])
        pause(0.5)
    raise RuntimeError('The game is still closing. Check its state before trying again.')


def power_action(call, kind, emit_event=emit, clock=time.monotonic, pause=time.sleep, timeout=120):
    method = {'reboot': 'Reboot', 'shutdown': 'Shutdown'}[kind]
    foreground = call('ForegroundStatus', '(sss)')[0]
    if foreground not in ('library', 'game'):
        raise RuntimeError('Close Transfer or the other foreground screen first.')
    # Only sessiond may stop the game and request power from logind. A successful
    # method reply acknowledges acceptance; it does not prove the system is off.
    call(method, '()')
    log(method + ' accepted')
    emit_event('power-progress', message='Restarting Zaman…' if kind == 'reboot' else 'Shutting down Zaman…')
    deadline = clock() + timeout
    while clock() < deadline:
        state = call('Status', STATUS_SIGNATURE)
        if state[0] == 'Failed':
            raise RuntimeError(state[5] or 'The power request failed.')
        pause(0.5)
    raise RuntimeError('The power request is still pending. Check the session state before trying again.')


def main():
    lock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('exit-game', 'reboot', 'shutdown'):
            raise RuntimeError('Expected exit-game, reboot or shutdown.')
        runtime = os.environ['XDG_RUNTIME_DIR']
        lock.bind('\0zaman-menu-exit:' + runtime)
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        owner = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                              'org.freedesktop.DBus', 'GetNameOwner', GLib.Variant('(s)', (SERVICE,)),
                              GLib.VariantType.new('(s)'), Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]

        def call(method, signature):
            # A service restart invalidates the action; never stop a replacement
            # daemon's game because the well-known bus name was reused.
            return bus.call_sync(owner, PATH, INTERFACE, method, None,
                                 GLib.VariantType.new(signature),
                                 Gio.DBusCallFlags.NO_AUTO_START, 5000, None).unpack()

        if sys.argv[1] == 'exit-game':
            exit_game(call)
        else:
            power_action(call, sys.argv[1])
        return 0
    except Exception as error:
        message = str(error)
        if 'the Zaman system menu is not open' in message:
            message = 'Sessiond needs the included ExitGame API update. Build and deploy it, then try again.'
        log('failed: ' + message.replace('\n', ' '))
        emit('exit-result', ok=False, message=message)
        return 1
    finally:
        lock.close()


if __name__ == '__main__':
    sys.exit(main())
