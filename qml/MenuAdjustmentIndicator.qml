import QtQuick

Item {
    id: hint
    property real uiScale: 1
    property bool editing: false
    property bool chosen: false
    signal stepped(int direction)
    implicitWidth: Math.round(56 * uiScale)
    implicitHeight: Math.round(36 * uiScale)
    Rectangle {
        anchors.fill: parent
        radius: Math.round(8 * hint.uiScale)
        color: hint.chosen ? "#2E3947" : "#202936"
        border.width: 1
        border.color: hint.chosen ? "#EAC28D" : "#3D4B5C"
    }
    Repeater {
        model: [-1, 1]
        delegate: Item {
            required property int modelData
            width: hint.width / 2; height: hint.height
            x: modelData < 0 ? 0 : width
            MenuText {
                anchors.centerIn: parent
                text: modelData < 0 ? "‹" : "›"
                font.pixelSize: Math.round(24 * hint.uiScale)
                color: hint.chosen ? "#EAC28D" : "#BCCDDD"
            }
            MouseArea { anchors.fill: parent; onClicked: hint.stepped(modelData) }
        }
    }
}
