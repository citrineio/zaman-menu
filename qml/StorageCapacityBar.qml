import QtQuick
import "StorageCapacity.js" as Capacity

Column {
    id: meter
    property var usage: null
    property real deviceSize: 0
    property real uiScale: 1
    function px(size) { return Math.round(size * uiScale); }
    spacing: px(4)
    MenuText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: meter.usage
            ? Capacity.gb(meter.usage.used) + " used of " + Capacity.gb(meter.usage.total) + " · " + Capacity.gb(meter.usage.free) + " free" + (meter.usage.partial ? " · Mounted volumes" : "")
            : "Free space unavailable" + (meter.deviceSize > 0 ? " · " + Capacity.gb(meter.deviceSize) + " device" : "")
        font.pixelSize: meter.px(16)
        color: meter.usage ? "#D0E4DB" : "#BBC6D3"
    }
    Rectangle {
        visible: !!meter.usage
        width: parent.width
        height: meter.px(9)
        radius: height / 2
        color: "#485769"
        Rectangle {
            width: meter.usage ? parent.width * meter.usage.used / meter.usage.total : 0
            height: parent.height
            radius: parent.radius
            color: "#8DC9B2"
        }
    }
}
