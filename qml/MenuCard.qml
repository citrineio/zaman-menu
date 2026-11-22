import QtQuick

Rectangle {
    property real uiScale: 1
    property bool cardFocused: false
    property bool cardMotion: false
    property color focusInk: "#EAC28D"
    radius: Math.round(12 * uiScale)
    color: cardFocused ? "#2E3947" : "#202936"
    border.width: cardFocused ? 2 : 1
    border.color: cardFocused ? focusInk : "#3D4B5C"
    Behavior on color { enabled: cardMotion; ColorAnimation { duration: 100 } }
}
