import QtQuick

Row {
    id: actions
    required property var controller
    property real uiScale: 1
    function px(value) { return Math.round(value * uiScale); }
    spacing: px(8)

    component Action: MenuCard {
        id: action
        required property string label
        required property string icon
        property int unread: 0
        property bool available: true
        signal triggered
        uiScale: actions.uiScale
        cardMotion: actions.controller.menuMotionActive
        height: actions.px(44)
        width: Math.max(height, contents.width + actions.px(18))
        opacity: available ? 1 : 0.6
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.focused: cardFocused
        Accessible.onPressAction: if (available) triggered()
        Row {
            id: contents
            anchors.centerIn: parent
            spacing: actions.px(5)
            MenuIcon {
                name: action.icon; ink: "#EAC28D"
                width: actions.px(24); height: width
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                visible: action.unread > 0
                width: Math.max(height, count.implicitWidth + actions.px(8))
                height: actions.px(22); radius: height / 2; color: "#EAC28D"
                anchors.verticalCenter: parent.verticalCenter
                MenuText {
                    id: count
                    anchors.centerIn: parent
                    text: action.unread > 99 ? "99+" : String(action.unread)
                    color: "#281f17"; font.pixelSize: actions.px(13)
                }
            }
        }
        MouseArea { anchors.fill: parent; enabled: action.available; onClicked: action.triggered() }
    }

    Action {
        objectName: "notificationHeaderButton"
        label: "Notifications · " + actions.controller.notificationUnread + " unread"
        icon: "notifications"
        unread: actions.controller.notificationUnread
        cardFocused: available && actions.controller.chromeZone === "header" && actions.controller.headerIndex === 0
        available: actions.controller.canOpenNotifications
        onTriggered: actions.controller.clickHeader(0)
    }
    Action {
        objectName: "settingsHeaderButton"
        label: "System settings"
        icon: "settings"
        cardFocused: available && actions.controller.chromeZone === "header" && actions.controller.headerIndex === 1
        available: actions.controller.canOpenSystem
        onTriggered: actions.controller.clickHeader(1)
    }
}
