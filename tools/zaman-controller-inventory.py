#!/usr/bin/env python3
"""Controller transport inventory and selected-device BlueZ operations."""
import argparse
import json
from pathlib import Path
import re
import sys

COMPOSITE='org.shadowblip.Input.CompositeDevice'
UDEV='org.shadowblip.Input.Source.UdevDevice'
EVENT='org.shadowblip.Input.Source.EventDevice'
DEVICE='org.bluez.Device1'
MAC=re.compile(r'^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$',re.I)


def address(value):
    v=str(value or '').lower()
    return v if MAC.fullmatch(v) else ''


def controller(props, confirmed=()):
    cod=int(props.get('Class',0));appearance=int(props.get('Appearance',0))
    return (props.get('Icon')=='input-gaming' or appearance in (0x3c3,0x3c4)
        or (cod&0x1f00==0x0500 and cod&0x0c in (4,8))
        or address(props.get('Address')) in confirmed)


def transport(source):
    props=source.get('Properties',{})
    bus=str(source.get('IdBustype','')).lower()
    if props.get('ID_BUS')=='bluetooth' or bus in ('5','0005','0x5'):return 'Bluetooth'
    if props.get('ID_BUS')=='usb' or bus in ('3','0003','0x3'):
        words=' '.join(str(v) for v in [source.get('Name',''),source.get('Manufacturer',''),
            props.get('ID_VENDOR',''),props.get('ID_MODEL',''),props.get('ID_SERIAL','')])
        if re.search(r'\breceiver\b|\bdongle\b',words,re.I):
            return '2.4 GHz USB receiver' if re.search(r'\b2[._]?4\s*g(?:hz)?\b',words,re.I) else 'USB receiver'
        return 'USB'
    return 'Unknown connection'


def combine(bluez, objects, kernel_ready=()):
    blue_devices={p:i[DEVICE] for p,i in bluez.items() if DEVICE in i}
    sources={}
    for path, interfaces in objects.items():
        info=dict(interfaces.get(UDEV,{}))
        raw=interfaces.get(EVENT,{})
        for key,value in raw.items():info.setdefault(key,value)
        dev=info.get('DevicePath') or info.get('DevPath')
        if dev:sources[dev]=info
    rows=[];detected=set()
    for path, interfaces in objects.items():
        if COMPOSITE not in interfaces:continue
        c=interfaces[COMPOSITE]
        physical=[sources[p] for p in c.get('SourceDevicePaths',[]) if p in sources]
        physical=[p for p in physical if '/devices/virtual/input/' not in str(p.get('SysfsPath',''))]
        methods=sorted(set(transport(p) for p in physical))
        addresses={address(p.get('UniqueId')) for p in physical};addresses.discard('')
        if 'Bluetooth' in methods and address(c.get('PersistentId')):addresses.add(address(c['PersistentId']))
        if "Bluetooth" in methods: detected.update(addresses)
        bp=next((p for p,d in blue_devices.items() if 'Bluetooth' in methods and len(addresses)==1 and address(d.get('Address')) in addresses),'')
        name=next((p.get('Name') for p in physical if p.get('DeviceClass') in ('joystick','gamepad')),
                  next((p.get('Name') for p in physical if p.get('Name')),c.get('Name','Controller')))
        rows.append(dict(id=path,name=name,connection=' + '.join(methods) or 'Unknown connection',
            bluetoothPath=bp,address=next(iter(addresses),'') if len(addresses)==1 else '',
            sourcePaths=c.get('SourceDevicePaths',[]),profile=c.get('ProfileName',''),
            targets=c.get('TargetDevices',[]),menuInput=bool(c.get('DbusDevices',[]))))
    blue_devices={p:d for p,d in blue_devices.items() if controller(d,set(kernel_ready)|detected)}
    return rows,blue_devices,detected


def kernel_gamepads(sysfs=Path('/sys/class/input')):
    found=set()
    for event in sysfs.glob('event*'):
        node=event/'device'
        try:
            if (node/'id/bustype').read_text().strip()!='0005':continue
            unique=address((node/'uniq').read_text().strip())
            if not unique:continue
            # BTN_JOYSTICK through the standard gamepad button range.
            bits=int(''.join((node/'capabilities/key').read_text().split()),16)
            if (bits>>0x120)&0xffffffff:found.add(unique)
        except (OSError,ValueError):continue
    return found


class Bluez:
    def __init__(self):
        import gi
        gi.require_version('Gio','2.0')
        from gi.repository import Gio,GLib
        self.Gio,self.GLib=Gio,GLib
        self.bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
        self.owner=self.bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'GetNameOwner',GLib.Variant('(s)',('org.bluez',)),None,0,3000,None).unpack()[0]
    def call(self,path,interface,method,params=None,timeout=5000):
        return self.bus.call_sync(self.owner,path,interface,method,params,None,0,timeout,None)
    def objects(self):return self.call('/','org.freedesktop.DBus.ObjectManager','GetManagedObjects').unpack()[0]
    def props(self,path):return self.call(path,'org.freedesktop.DBus.Properties','GetAll',self.GLib.Variant('(s)',(DEVICE,))).unpack()[0]
    def inputs(self):
        return self.bus.call_sync('org.shadowblip.InputPlumber','/org/shadowblip/InputPlumber',
            'org.freedesktop.DBus.ObjectManager','GetManagedObjects',None,None,0,3000,None).unpack()[0]
    def act(self,operation,path,expected):
        if not re.fullmatch(r'/org/bluez/hci\d+/dev_[0-9A-Fa-f_]+',path):raise ValueError('Invalid controller path.')
        d=self.props(path)
        if address(d.get('Address'))!=address(expected) or not address(expected):
            raise ValueError('The selected controller identity changed.')
        if operation=='connect':
            if not d.get('Paired') and not d.get('Bonded'):raise ValueError('Pair this controller before reconnecting.')
            self.call(path,'org.freedesktop.DBus.Properties','Set',self.GLib.Variant('(ssv)',(DEVICE,'Trusted',self.GLib.Variant('b',True))))
            if not self.props(path).get('Trusted'):raise RuntimeError('Automatic reconnection could not be enabled.')
            if not self.props(path).get('Connected'):
                try:self.call(path,DEVICE,'Connect',timeout=15000)
                except Exception as e:
                    if 'AlreadyConnected' not in str(e):raise
        elif operation=='disconnect':
            if d.get('Connected'):self.call(path,DEVICE,'Disconnect',timeout=10000)
        elif operation=='forget':
            adapter=d.get('Adapter')
            if not adapter or not path.startswith(str(adapter)+'/'):raise ValueError('Controller adapter identity changed.')
            self.call(adapter,'org.bluez.Adapter1','RemoveDevice',self.GLib.Variant('(o)',(path,)))
        else:raise ValueError('Unsupported controller operation.')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('operation',choices=['snapshot','connect','disconnect','forget'])
    p.add_argument('path',nargs='?');p.add_argument('address',nargs='?');a=p.parse_args()
    try:
        b=Bluez()
        if a.operation=='snapshot':
            error=''
            try:inputs=b.inputs()
            except Exception as e:inputs={};error=str(e)
            kernel_ready=kernel_gamepads()
            rows,devices,detected=combine(b.objects(),inputs,kernel_ready)
            ready=kernel_ready|detected
            saved=[dict(id=p,name=d.get('Alias') or d.get('Name') or 'Controller',
                address=address(d.get('Address')),connected=bool(d.get('Connected')),
                paired=bool(d.get('Paired') or d.get('Bonded')),trusted=bool(d.get('Trusted')),
                inputReady=address(d.get('Address')) in ready and bool(d.get('ServicesResolved')))
                for p,d in devices.items()]
            result=dict(type='controller-inventory',devices=rows,bluetooth=saved,error=error)
        else:
            if not a.path or not a.address:raise ValueError('A selected controller is required.')
            b.act(a.operation,a.path,a.address)
            result=dict(type='controller-operation',operation=a.operation,address=address(a.address),ok=True)
        print(json.dumps(result),flush=True);return 0
    except Exception as e:
        print(json.dumps(dict(type='controller-operation' if a.operation!='snapshot' else 'controller-inventory',
            operation=a.operation,address=address(a.address),ok=False,error=str(e))),flush=True);return 1

if __name__=='__main__':raise SystemExit(main())
