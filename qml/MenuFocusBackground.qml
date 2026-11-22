import QtQuick

Rectangle {
    id: card
    property bool chosen: false
    property real uiScale: 1
    property color idleStart: "#00121820"
    property color idleEnd: "#00121820"
    property real emphasis: chosen ? 1 : 0

    // Follow the row's shared focus animation. The row owns its layout growth.
    x: Math.round(8 * uiScale * (1 - emphasis))
    y: Math.round(2 * uiScale * (1 - emphasis))
    width: Math.max(0, parent.width - 2 * x)
    height: Math.max(0, parent.height - 2 * y)
    radius: Math.round(13 * uiScale)
    color: chosen ? "#2E3947" : "#202936"
    border.width: chosen ? 2 : 1
    border.color: chosen ? "#EAC28D" : "#3D4B5C"
}
