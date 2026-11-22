import QtQuick

Item {
    id: exitPage
    property bool focusVisible: true
    property string prompt: "Exit this game?"
    property string detail: "Close the current game and return to your library."
    property string cancelLabel: "Keep playing"
    property string confirmLabel: "Exit Game"
    property string busyHeading: "Closing game…"
    property bool active: false
    property bool busy: false
    property string notice: ""
    property real uiScale: 1
    property int selected: 0
    signal confirmRequested()
    signal backRequested()
    function px(value) { return Math.round(value * uiScale); }
    function move(direction) {
        if (active && !busy) selected = (selected + direction + 2) % 2;
    }
    function activate() {
        if (!active || busy) return;
        if (selected === 0) backRequested();
        else confirmRequested();
    }
    onActiveChanged: if (active && !busy) selected = 0

    Column {
        width: parent.width
        spacing: exitPage.px(18)
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: exitPage.busy ? exitPage.busyHeading : exitPage.prompt
            font.pixelSize: exitPage.px(30)
        }
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: exitPage.busy ? "Please wait…" : exitPage.detail
            font.pixelSize: exitPage.px(19); color: "#BBC6D3"
        }
        MenuText {
            visible: exitPage.notice.length > 0
            width: parent.width; wrapMode: Text.WordWrap
            text: exitPage.notice; textFormat: Text.PlainText
            font.pixelSize: exitPage.px(17); color: "#EAC28D"
        }
        Repeater {
            model: [exitPage.cancelLabel, exitPage.confirmLabel]
            delegate: Rectangle {
                required property int index
                required property string modelData
                width: exitPage.width; height: exitPage.px(102)
                radius: exitPage.px(13)
                readonly property bool highlighted: exitPage.focusVisible && exitPage.selected === index
                color: highlighted ? "#2E3947" : "#202936"; border.width: highlighted ? 2 : 1; border.color: highlighted ? "#EAC28D" : "#3D4B5C"
                opacity: exitPage.busy ? 0.45 : 1
                MenuText {
                    anchors.centerIn: parent
                    width: parent.width - exitPage.px(28)
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                    text: modelData
                    font.pixelSize: exitPage.px(24)
                    color: parent.highlighted ? "#F3EEE5" : "#E9EDF2"
                }
                MouseArea {
                    anchors.fill: parent; enabled: exitPage.active && !exitPage.busy
                    onClicked: { exitPage.selected = index; exitPage.activate(); }
                }
            }
        }
    }
}
