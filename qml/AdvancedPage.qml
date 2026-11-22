import QtQuick

Item {
    id: advanced
    property bool focusVisible: true
    property real uiScale: 1
    property bool active: false
    property bool available: false
    property bool busy: false
    property string notice: ""
    property int selected: 0
    property bool confirming: false
    signal actionRequested(string action)
    signal backRequested()
    readonly property var rows: confirming ? [
        {label: "Cancel", detail: "Keep browsing", action: "cancel"},
        {label: "Restart frontend", detail: "Restart the Zaman shell and return to your library", action: "restart"}
    ] : [
        {label: "Refresh Pegasus theme", detail: "Reload the current theme", action: "refresh"},
        {label: "Restart frontend", detail: "Restart the Zaman shell", action: "confirm"}
    ]
    function px(value) { return Math.round(value * uiScale); }
    function move(direction) {
        if (!active || busy) return;
        selected = Math.max(0, Math.min(rows.length - 1, selected + direction));
    }
    function activate() {
        if (!active || busy || !available) return;
        var action = rows[selected].action;
        if (action === "cancel") { confirming = false; selected = 1; }
        else if (action === "confirm") { confirming = true; selected = 0; }
        else { confirming = false; selected = 0; actionRequested(action); }
    }
    function back() {
        if (busy) return;
        if (confirming) { confirming = false; selected = 1; }
        else backRequested();
    }
    onActiveChanged: if (!active) { confirming = false; selected = 0; }
    onAvailableChanged: if (!available) { confirming = false; selected = 0; }
    Column {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: advanced.px(14)
        MenuText {
            width: parent.width
            text: advanced.confirming ? "Restart frontend?" : "Frontend controls"
            font.pixelSize: advanced.px(25)
        }
        MenuText {
            width: parent.width
            wrapMode: Text.WordWrap
            color: "#BBC6D3"
            font.pixelSize: advanced.px(17)
            text: !advanced.available ? "Return to the library and close any game or storefront to use these controls."
                : advanced.confirming ? "The screen will briefly go blank while Zaman returns to your library."
                : "Refresh the theme after making changes, or restart the frontend."
        }
        Repeater {
            model: advanced.rows
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: advanced.px(102)
                radius: advanced.px(14)
                opacity: advanced.available && !advanced.busy ? 1 : 0.48
                readonly property bool chosen: advanced.focusVisible && advanced.selected === index
                color: chosen ? "#2E3947" : "#202936"; border.width: chosen ? 2 : 1; border.color: chosen ? "#EAC28D" : "#3D4B5C"
                Column {
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: advanced.px(18) }
                    spacing: advanced.px(5)
                    MenuText {
                        width: parent.width; elide: Text.ElideRight
                        text: modelData.label
                        readonly property bool chosen: advanced.focusVisible && advanced.selected === index
                color: chosen ? "#F3EEE5" : "#EDF2F7"
                        font.pixelSize: advanced.px(24)
                    }
                    MenuText {
                        width: parent.width
                        text: modelData.detail
                        readonly property bool chosen: advanced.focusVisible && advanced.selected === index
                color: "#BBC6D3"
                        font.pixelSize: advanced.px(16)
                        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: advanced.active && advanced.available && !advanced.busy
                    onClicked: { advanced.selected = index; advanced.activate(); }
                }
            }
        }
        MenuText {
            width: parent.width
            text: advanced.notice
            visible: text.length > 0
            wrapMode: Text.WordWrap
            color: "#EAC28D"
            font.pixelSize: advanced.px(17)
        }
    }
}
