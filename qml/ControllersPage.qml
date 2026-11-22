import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: controllers
    property bool focusVisible: true
    property real uiScale: 1
    property bool active: false
    property bool inventoryActive: active
    property bool bluetoothView: false
    property var inventory: ({devices:[],bluetooth:[],error:""})
    property string inventoryError: ""
    readonly property bool editingCode: bluetoothView && controllerBluetooth.editingCode
    signal navigationReset()
    function mergedDevices() {
        var connected = devices.map(d => {
            var info = inventory.devices.find(i => i.id === d.id);
            return info ? Object.assign({}, d, info) : Object.assign({}, d, {connection:"Connection not reported"});
        });
        var paths = connected.map(d => d.bluetoothPath || "");
        var saved = inventory.bluetooth.filter(d => (d.paired || d.connected) && paths.indexOf(d.id) < 0)
            .map(d => ({id:d.id,name:d.name,bluetoothPath:d.id,connection:"Bluetooth",saved:true,
                connected:d.connected,inputReady:d.inputReady,profile:"",targets:[],menuInput:false}));
        return connected.concat(saved);
    }
    function receiveInventory(text) {
        try {
            var result = JSON.parse(text);
            if (result.type !== "controller-inventory" || result.ok === false) {
                inventoryError = result.error || "Controller information is unavailable."; return;
            }
            inventory = result; inventoryError = result.error || "";
        } catch (error) { inventoryError = "Unable to read controller information."; }
    }
    function back() { if (bluetoothView) controllerBluetooth.back(); else backRequested(); }
    function horizontal(direction) { if (bluetoothView) controllerBluetooth.horizontal(direction); }
    function cycleKeyboard() { if (bluetoothView) controllerBluetooth.cycleKeyboard(); }
    function physicalKey(event) { return bluetoothView && controllerBluetooth.physicalKey(event); }
    function shutdown() { controllerBluetooth.shutdown(); }
    onActiveChanged: if (!active) { shutdown(); bluetoothView = false; }
    Timer {
        interval: 1500; repeat: true; triggeredOnStart: true; running: controllers.inventoryActive
        onTriggered: if (!inventoryProcess.running) inventoryProcess.running = true
    }
    Process {
        id: inventoryProcess
        command: ["/usr/bin/python3", Quickshell.shellPath("../tools/zaman-controller-inventory.py"), "snapshot"]
        stdout: StdioCollector { onStreamFinished: controllers.receiveInventory(text) }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) controllers.inventoryError = text.trim().slice(-800) }
    }
    BluetoothPage {
        focusVisible: controllers.focusVisible
        id: controllerBluetooth
        anchors.fill: parent; uiScale: controllers.uiScale
        controllersOnly: true; controllerStatus: controllers.inventory.bluetooth
        visible: controllers.active && controllers.bluetoothView
        onBackRequested: { controllers.bluetoothView = false; controllers.navigationReset(); }
        onNavigationReset: controllers.navigationReset()
    }
    property var devices: []
    property int selected: 0
    property string selectedId: ""
    readonly property int connectedCount: mergedDevices().filter(d => !d.saved || d.connected).length
    readonly property var rows: [{id:"pair",name:"Pair controller"}].concat(mergedDevices()).concat([{id:"back",name:"Back"}])
    readonly property var current: rows[selected] && rows[selected].id !== "pair" && rows[selected].id !== "back" ? rows[selected] : null
    signal backRequested()

    // The page owns deferred layout work; destroyed delegates are never captured.
    Timer {
        id: focusSettle
        interval: 1
        repeat: false
        onTriggered: controllers.settleFocus()
    }
    function requestFocusSettle() { focusSettle.restart(); }
    function settleFocus() {
        if (!(visible) || selected < 0 || selected >= controllerList.count) return;
        controllerList.forceLayout();
        controllerList.positionViewAtIndex(selected, ListView.Contain);
    }

    function px(value) { return Math.round(value * uiScale); }
    function clean(value) { return String(value || "").replace(/[\x00-\x1f\x7f]/g, "").slice(0, 100); }
    function inputTag(device) {
        if (device.saved) return "";
        var targets = device.targets || [];
        var tags = [];
        for (var i = 0; i < targets.length; i++) {
            var tag = String(targets[i]).split("/").pop();
            if (/^(?:SDL-\d+|gamepad\d+)$/i.test(tag) && tags.indexOf(tag) < 0) tags.push(tag);
        }
        if (tags.length) return tags.join(", ");
        var composite = String(device.id || "").split("/").pop();
        return /^CompositeDevice\d+$/.test(composite) ? composite : "";
    }
    function targetLabel(path) {
        var token = String(path).split("/").pop().toLowerCase();
        return /keyboard/.test(token) ? "Keyboard output" : /mouse/.test(token) ? "Mouse output" : "Game input";
    }
    function targetSummary(device) {
        if (!device || !device.targets || device.targets.length === 0) return "No game input output";
        var labels = device.targets.filter(path => !/dbus[0-9]*$/.test(path)).map(targetLabel);
        return labels.filter((label, index) => labels.indexOf(label) === index).join(" · ") || "Menu input only";
    }
    function select(index) {
        selected = Math.max(0, Math.min(rows.length - 1, index));
        selectedId = rows[selected].id;
        if (controllerList) controllerList.positionViewAtIndex(selected, ListView.Contain);
    }
    function move(direction) { if (bluetoothView) controllerBluetooth.move(direction); else select((selected + direction + rows.length) % rows.length); }
    function activate() {
        if (bluetoothView) { controllerBluetooth.activate(); return; }
        var item = rows[selected];
        if (!item) return;
        if (item.id === "back") { backRequested(); return; }
        if (item.id === "pair" || item.bluetoothPath) {
            bluetoothView = true; navigationReset();
            if (item.bluetoothPath) controllerBluetooth.openController(item.bluetoothPath);
            else {
                controllerBluetooth.device = null; controllerBluetooth.changeView("list");
                Qt.callLater(() => { if (controllers.active && controllers.bluetoothView) controllerBluetooth.scan(); });
            }
        }
    }
    onRowsChanged: {
        var index = rows.findIndex(row => row.id === selectedId);
        select(index >= 0 ? index : Math.min(selected, rows.length - 1));
    }
    Component.onCompleted: select(0)

    Column {
        id: status
        visible: !controllers.bluetoothView
        width: parent.width
        spacing: controllers.px(8)
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: controllers.connectedCount === 0 ? "No controllers connected."
                : controllers.connectedCount + (controllers.connectedCount === 1 ? " controller connected" : " controllers connected")
            font.pixelSize: controllers.px(21); color: "#ECEEF1"
        }
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: controllers.connectedCount === 0
                ? "Select Pair controller, or connect a USB controller / receiver."
                : "Select a Bluetooth controller to reconnect, disconnect or forget it."
            font.pixelSize: controllers.px(15); color: "#BBC6D3"
        }
    }
    Column {
        id: detail
        visible: !controllers.bluetoothView
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        spacing: controllers.px(8)
        Rectangle { width: parent.width; height: 1; color: "#265C6E85" }
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: controllers.current
                ? "Connection: " + controllers.clean(controllers.current.connection) + " · " + (controllers.current.saved ? (controllers.current.connected ? "Connected" : "Saved · Disconnected") : "Connected")
                : "Put the controller into Bluetooth pairing mode. The pairing button combination depends on your controller."
            font.pixelSize: controllers.px(15); color: "#C7CFD8"
        }
        MenuText {
            width: parent.width; wrapMode: Text.WordWrap
            text: controllers.current
                ? "Profile: " + controllers.clean(controllers.current.profile || "Not reported")
                : controllers.inventoryError || "Pairing and saved-controller management are here in Controllers."
            font.pixelSize: controllers.px(14); color: "#BBC6D3"
        }
    }
    ListView {
        id: controllerList
        visible: !controllers.bluetoothView
        property point lastPointerPosition: Qt.point(-100000, -100000)
        anchors { left: parent.left; right: parent.right; top: status.bottom; bottom: detail.top
            topMargin: controllers.px(20); bottomMargin: controllers.px(22) }
        model: controllers.rows
        currentIndex: controllers.selected
        spacing: controllers.px(8)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        delegate: MenuFocusRow {
            id: row
            required property var modelData
            required property int index
            chosen: controllers.focusVisible && controllers.selected === index
            uiScale: controllers.uiScale
            readonly property bool backRow: modelData.id === "back"
            readonly property string inputTag: controllers.inputTag(modelData)
            readonly property bool pairRow: modelData.id === "pair"
            width: controllerList.width
            baseHeight: 102; height: Math.max(controllers.px(102), rowText.implicitHeight + controllers.px(24))
            onFocusSettled: if (row.chosen) controllers.requestFocusSettle()
            MenuFocusBackground {
                chosen: row.chosen
                uiScale: controllers.uiScale
                emphasis: row.focusAmount
                idleStart: "#162F425C"
                idleEnd: "#10121820"
            }
            MenuIcon {
                x: controllers.px(16); anchors.verticalCenter: parent.verticalCenter
                name: row.backRow ? "back" : "controllers"
                width: controllers.px(28 + 2 * row.focusAmount); height: width
                ink: row.chosen ? "#EAC28D" : "#DEC09A"
            }
            Column {
                id: rowText; x: controllers.px(58); anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - controllers.px(78) - (row.inputTag.length ? inputTagLabel.width + controllers.px(14) : 0))
                spacing: controllers.px(6)
                MenuText {
                    width: parent.width; elide: Text.ElideRight
                    text: controllers.clean(row.modelData.name || "Controller")
                    font.pixelSize: controllers.px(24)
                    color: row.chosen ? "#F3EEE5" : "#ECEEF1"
                }
                MenuText {
                    visible: !row.backRow
                    width: parent.width; elide: Text.ElideRight
                    text: row.pairRow ? "Find and pair a Bluetooth controller" : controllers.clean(row.modelData.connection) + (row.modelData.saved && !row.modelData.connected ? " · Saved · Disconnected" : " · Connected")
                    font.pixelSize: controllers.px(16)
                    color: row.chosen ? "#BBC6D3" : (row.modelData.menuInput ? "#91BBA7" : "#BBC6D3")
                }
                MenuText {
                    visible: !row.backRow && !row.pairRow
                    width: parent.width; elide: Text.ElideRight
                    text: row.modelData.saved ? (row.modelData.inputReady ? "Controller input detected" : "Select to manage this pairing") : (row.modelData.menuInput ? "Menu input available" : "Menu input unavailable")
                    font.pixelSize: controllers.px(16)
                    color: row.chosen ? "#BBC6D3" : "#BBC6D3"
                }
            }
            MenuText {
                id: inputTagLabel
                visible: row.inputTag.length > 0
                anchors { right: parent.right; rightMargin: controllers.px(19); verticalCenter: parent.verticalCenter }
                width: Math.min(implicitWidth, parent.width * 0.33)
                text: row.inputTag
                font.pixelSize: controllers.px(17)
                color: "#BBC6D3"
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }
            MouseArea {
                id: controllerPointer
                anchors.fill: parent; hoverEnabled: true
                onEntered: if (row.pointerMoved(controllerPointer)) controllers.select(index)
                onPositionChanged: if (row.pointerMoved(controllerPointer)) controllers.select(index)
                onClicked: { controllers.select(index); controllers.activate(); }
                onWheel: wheel => { controllers.move(wheel.angleDelta.y > 0 ? -1 : 1); wheel.accepted = true; }
            }
        }
    }
}
