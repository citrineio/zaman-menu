import QtQuick

Item {
    id: appearance
    property bool focusVisible: true
    property real uiScale: 1
    property string currentStyle: "drawer"
    property bool settingsReady: false
    property bool motionEnabled: true
    property bool animate: false
    property string notice: ""
    property int selected: 0
    readonly property var styles: [
        {key:"drawer", label:"Quick Drawer", detail:"Audio controls and quick actions beside your game"},
        {key:"split", label:"Split Tabs", detail:"Categories on the left, settings on the right"},
        {key:"ribbon", label:"Control Ribbon", detail:"A bottom strip with settings above it"}
    ].concat([{key:"motion",label:"Motion",detail:motionEnabled ? "Subtle slides, fades and focus transitions" : "Reduced motion · Immediate visual changes"}])
    signal motionRequested(bool enabled)
    signal styleRequested(string style)
    signal backRequested()
    function px(n) { return Math.round(n * uiScale); }
    function move(direction) { selected = Math.max(0, Math.min(styles.length - 1, selected + direction)); }
    function activate() {
        if (!settingsReady) return;
        if (styles[selected].key === "motion") motionRequested(!motionEnabled);
        else styleRequested(styles[selected].key);
    }
    function back() { backRequested(); }
    onVisibleChanged: if (visible) selected = Math.max(0, styles.findIndex(s => s.key === currentStyle))
    Column {
        width: parent.width; spacing: appearance.px(12)
        Repeater {
            model: appearance.styles
            delegate: MenuCard {
                required property var modelData
                required property int index
                readonly property bool chosen: appearance.focusVisible && appearance.selected === index
                width: parent.width; height: appearance.px(102); radius: appearance.px(14)
                uiScale: appearance.uiScale; cardFocused: chosen; cardMotion: appearance.animate
                Column {
                    x: appearance.px(20); anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - appearance.px(108); spacing: appearance.px(8)
                    MenuText { text: modelData.label; color:"#F3EEE5"; font.pixelSize:appearance.px(24) }
                    MenuText { text: modelData.detail; width:parent.width; wrapMode:Text.WordWrap; color:"#BBC6D3"; font.pixelSize:appearance.px(16) }
                }
                MenuText {
                    anchors { right:parent.right; rightMargin:appearance.px(18); verticalCenter:parent.verticalCenter }
                    text: modelData.key === "motion" ? (appearance.motionEnabled ? "Subtle" : "Reduced") : appearance.currentStyle === modelData.key ? "Active" : ""
                    color:"#EAC28D"; font.pixelSize:appearance.px(16)
                }
                MouseArea { anchors.fill:parent; enabled:appearance.settingsReady; onClicked:{ appearance.selected=index;appearance.activate(); } }
            }
        }
        MenuText {
            width:parent.width; wrapMode:Text.WordWrap
            text: appearance.notice || (appearance.settingsReady ? "Your choice is saved for the next time you open the menu." : "Loading your preference…")
            color:appearance.notice.length ? "#EAC28D" : "#BBC6D3";font.pixelSize:appearance.px(16)
        }
    }
}
