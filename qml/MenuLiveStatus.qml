import QtQuick
import Quickshell.Networking
import Quickshell.Bluetooth

QtObject {
    function clean(value) { return String(value || "").replace(/[\x00-\x1f\x7f]/g, "").slice(0, 70); }
    readonly property var networkState: {
        if (Networking.backend !== NetworkBackendType.NetworkManager)
            return {title:"Network", detail:"Unavailable"};
        var devices = Networking.devices.values;
        for (var i = 0; i < devices.length; ++i) {
            var device = devices[i];
            if (device.connected && device.type === DeviceType.Wifi) {
                var active = device.networks.values.find(network => network.connected);
                return {title:active && clean(active.name) || "Wi-Fi", detail:"Connected"};
            }
        }
        if (devices.some(device => device.connected && device.type === DeviceType.Wired))
            return {title:"Ethernet", detail:"Connected"};
        return {title:"Network", detail:"Not connected"};
    }
    readonly property string networkTitle: networkState.title
    readonly property string networkDetail: networkState.detail
    readonly property string network: networkState.detail === "Connected" ? networkState.title : networkState.detail
    readonly property string bluetooth: {
        var adapters=Bluetooth.adapters.values;
        if (!adapters.length) return "Unavailable";
        var enabled=adapters.filter(a => a.enabled);
        if (!enabled.length) return "Off · 0 connected";
        var count=0;
        for (var i=0;i<enabled.length;++i) count+=enabled[i].devices.values.filter(d => d.connected).length;
        return count + " connected";
    }
}
