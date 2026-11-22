import QtQuick
import "StorageCapacity.js" as Capacity
import Quickshell
import Quickshell.Io

Item {
    id: page
    property bool focusVisible: true
    property real uiScale: 1
    property bool active: false
    property var snapshot: ({available:false, devices:[], error:""})
    property bool loading: false
    property bool operationBusy: false
    readonly property bool busy: operationBusy || moves.busy
    property bool moving: false
    property bool directGameMove: false
    property string view: "devices"
    property string diskId: ""
    property string volumeId: ""
    property string selectedId: ""
    property string notice: ""
    property string operation: ""
    property var report: null
    property var formatPlan: null
    property var assignment: null
    property bool operationReceived: false
    readonly property var devices: snapshot.devices || []
    readonly property var disk: devices.find(d => d.id === diskId) || null
    readonly property var volume: disk ? (disk.volumes.find(v => v.id === volumeId) || null) : null
    readonly property var rows: buildRows()
    signal backRequested()
    function openGameMove(requestData) {
        directGameMove = true;
        moves.openForGame(requestData);
        moving = true;
    }
    function px(n) { return Math.round(n * uiScale); }
    function bytes(value) {
        if (value === null || value === undefined) return "Unknown";
        var n = Number(value);
        if (!isFinite(n) || n < 0) return "Unknown";
        if (n >= 1099511627776) return (n / 1099511627776).toFixed(2) + " TiB";
        if (n >= 1073741824) return (n / 1073741824).toFixed(1) + " GiB";
        return (n / 1048576).toFixed(0) + " MiB";
    }
    function usage(v) {
        return v.mountpoint ? bytes(v.available) + " available · " + bytes(v.used) + " used" : bytes(v.capacity) + " · Not in use";
    }
    function row(id, label, detail) { return {id:id, label:label, detail:detail || ""}; }
    function buildRows() {
        var result = [];
        if (view === "confirm-prepare")
            return [row("cancel", "Cancel"),
                    row("confirm-prepare", "Prepare for Zaman", "Create game folders and scan this drive")];
        if (view === "confirm")
            return [row("cancel", "Cancel"), row("format", "Format this empty drive", "Erase its partition layout and create one ext4 volume")];
        if (view === "assign") {
            var systems = report ? report.systems || [] : [];
            result = systems.filter(s => assignment && assignment.candidates.indexOf(s.id) >= 0)
                .map(s => row("system:" + s.id, s.name));
        } else if (view === "review") {
            result = (report ? report.unresolved || [] : []).map((g, i) => row("folder:" + i,
                (g.folder === "." ? "Drive root" : g.folder) + " · " + g.count + " unassigned",
                (g.examples || []).join(" · ")));
        } else if (view === "volume" && volume && disk) {
            if (disk.protected) result.push(row("protected", "System storage · View only", disk.reason));
            else {
                result.push(row(volume.mountpoint ? "eject" : "mount", volume.mountpoint ? "Eject storage" : "Use storage"));
                result.push(row("mode", "Connect automatically: " + (volume.mode === "auto" ? "On" : "Off"),
                    volume.mode === "auto" ? "Ready to use when inserted" : "Use this storage manually"));
                if (volume.suspended && volume.mode === "auto") result.push(row("mount", "Use storage again", "Eject pauses automatic connection until you reconnect it"));
                result.push(row("prepare", volume.prepared ? "Check Zaman setup" : "Prepare for Zaman", "Create game folders and scan existing games · Keeps your files"));
                result.push(row("scan", "Scan for games", "Index supported games in place using Zaman’s emulator settings"));
                if (volume.unresolved > 0 || (report && (report.unresolved || []).length))
                    result.push(row("review", "Choose platforms for unassigned games"));
            }
        } else if (view === "device" && disk) {
            result = disk.volumes.map(v => row(v.id, v.name + " · " + (v.filesystem || "Unknown filesystem"), usage(v)));
            if (disk.protected) result.push(row("protected", "System storage · View only", disk.reason));
            else result.push(row("format-plan", "Format an empty drive…", "Checks for files first · GPT + ext4"));
        } else if (view === "devices") {
            result = devices.map(d => ({
                id:d.id, label:d.name,
                detail:d.connection + " · " + d.type + (d.protected ? " · System storage" : ""),
                drive:d, usage:Capacity.drive(d)
            }));
            result.push(row("move-games", "Move games", "Choose a game, then its destination"));
        }
        if (view !== "assign") result.push(row("refresh", "Refresh devices"));
        result.push(row("back", "Back"));
        return result;
    }
    function select(index) {
        if (!rows.length) return;
        index = (index + rows.length) % rows.length;
        selectedId = rows[index].id;
        list.positionViewAtIndex(index, ListView.Contain);
    }
    function move(direction) { if(moving){moves.move(direction);return;} if (!busy) select(rows.findIndex(r => r.id === selectedId) + direction); }
    function setView(next) { view = next; selectedId = rows.length ? rows[0].id : ""; }
    function request(action, extra) {
        if (busy) return;
        var target = action === "format-plan" ? disk : volume;
        if (!target && action !== "format") { notice = "Drive disconnected. Refresh devices."; return; }
        var payload = {action:action, id:target ? target.id : "", identity:target ? target.identity : ""};
        if (extra) Object.keys(extra).forEach(k => payload[k] = extra[k]);
        operation = action; notice = ""; operationReceived = false; operationBusy = true;
        operationProcess.exec(["/usr/bin/python3", Quickshell.shellPath("../tools/zaman-storage.py"), "request", JSON.stringify(payload)]);
    }
    function activate() {
        if(moving){moves.activate();return;}
        if (busy) return;
        var key = selectedId;
        if (key === "back" || key === "cancel") { back(); return; }
        if (key === "refresh") { refresh(); return; }
        if (key === "protected") return;
        if (key === "move-games") { moving=true; return; }
        if (view === "devices") { diskId = key; report = null; setView("device"); return; }
        if (view === "device" && key !== "format-plan") { volumeId = key; report = null; setView("volume"); return; }
        if (key === "prepare" && volume && !volume.prepared) {
            setView("confirm-prepare");
            return;
        }
        if (key === "confirm-prepare") {
            request("prepare");
            return;
        }
        if (key === "format-plan") { request("format-plan"); return; }
        if (key === "format") { request("format", {token:formatPlan.token}); return; }
        if (key === "mode") { request("mode", {mode:volume.mode === "auto" ? "manual" : "auto"}); return; }
        if (key === "review") { if (report) setView("review"); else request("report"); return; }
        if (view === "review" && key.indexOf("folder:") === 0) {
            assignment = report.unresolved[Number(key.slice(7))]; setView("assign"); return;
        }
        if (view === "assign" && key.indexOf("system:") === 0) {
            request("assign", {folder:assignment.folder, system:key.slice(7)}); return;
        }
        request(key);
    }
    function back() {
        if(moving){moves.back();return;}
        if (busy) return;
        notice = "";
        if (view === "confirm-prepare") { setView("volume"); return; }
        if (view === "confirm") { formatPlan = null; setView("device"); }
        else if (view === "assign") setView("review");
        else if (view === "review") setView("volume");
        else if (view === "volume") setView("device");
        else if (view === "device") setView("devices");
        else backRequested();
    }
    function refresh() { if (!moving && !busy && !inventoryProcess.running) inventoryProcess.running = true; }
    function receiveInventory(text) {
        try {
            var result = JSON.parse(text);
            if (!result.ok || result.type !== "storage") { notice = result.error || "Storage inventory failed."; return; }
            snapshot = result;
            if (view !== "devices" && !disk && !busy) setView("devices");
            else if ((view === "volume" || view === "review" || view === "assign") && !volume && !busy) setView("device");
        } catch (error) { notice = "Could not read storage inventory."; }
    }
    function receiveOperation(text) {
        try {
            var result = JSON.parse(text); operationReceived = true;
            if (!result.ok) { notice = result.error || "Storage operation failed."; return; }
            notice = result.message || "Storage updated.";
            if (result.report) report = result.report;
            if (operation === "prepare") setView("volume");
            if (operation === "format-plan") { formatPlan = result; setView("confirm"); }
            else if (operation === "format") { formatPlan = null; volumeId = result.volume.id; setView("volume"); }
            else if (operation === "assign") setView("review");
            else if (operation === "report") setView("review");
        } catch (error) { notice = "Could not read the storage operation result."; }
    }
    onRowsChanged: if (!rows.some(r => r.id === selectedId)) selectedId = rows.length ? rows[0].id : ""
    onActiveChanged: {
        if (active) refresh();
        else {
            moving = false;
            directGameMove = false;
        }
    }
    Process {
        id: inventoryProcess
        command: ["/usr/bin/python3", Quickshell.shellPath("../tools/zaman-storage.py"), "inventory"]
        onStarted: page.loading = true
        stdout: StdioCollector { onStreamFinished: page.receiveInventory(text) }
        stderr: StdioCollector {}
        onExited: (code, status) => { page.loading = false; if (code !== 0 && !page.notice) page.notice = "Storage service could not be reached."; }
    }
    Process {
        id: operationProcess
        stdout: StdioCollector { onStreamFinished: page.receiveOperation(text) }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            page.operationBusy = false;
            if (!page.operationReceived) page.notice = "The storage action could not start. " + (operationProcess.stderr.text || "");
            if (page.operation !== "format-plan") page.refresh();
        }
    }
    Timer { interval:5000; repeat:true; running:page.active && !page.busy && page.view !== "confirm"; onTriggered:page.refresh() }
    Column {
        id: heading
        visible:!page.moving
        width:parent.width; spacing:page.px(7)
        MenuText {
            width:parent.width; wrapMode:Text.Wrap; font.pixelSize:page.px(21); color:"#ECEEF1"
            text:page.busy ? (page.operation === "format" ? "Formatting drive… Keep it connected." : "Working on storage…")
                : page.view === "confirm-prepare" ? "Prepare " + (page.volume ? page.volume.name : "drive") + "?"
                : page.view === "confirm" ? "Format " + (page.formatPlan ? page.formatPlan.name : "drive") + "?"
                : page.view === "assign" ? "Choose the platform for this folder"
                : page.view === "review" ? "Unassigned games"
                : page.view === "volume" && page.volume ? page.volume.name + " · " + page.volume.filesystem
                : page.view === "device" && page.disk ? page.disk.name
                : page.loading && !page.devices.length ? "Checking storage…" : "Connected storage"
        }
        MenuText {
            width:parent.width; wrapMode:Text.Wrap; font.pixelSize:page.px(14); color:"#BBC6D3"
            text:page.view === "confirm" && page.formatPlan ? page.formatPlan.device + " · " + page.bytes(page.formatPlan.capacity) + "\n" + page.formatPlan.message
                : page.view === "assign" && page.assignment ? page.assignment.folder + "\n" + page.assignment.examples.join(" · ")
                : page.view === "volume" && page.volume ? page.usage(page.volume) + (page.volume.mountpoint ? "\n" + page.volume.mountpoint : "")
                    + (page.volume.indexed ? "\n" + page.volume.count + " games indexed · " + page.volume.unresolved + " unassigned" : "")
                : page.view === "device" && page.disk ? page.disk.device + (page.disk.serial ? " · " + page.disk.serial : "")
                : "Choose a drive to see its volumes or manage games."
        }
        MenuText { visible:!!page.notice; width:parent.width; wrapMode:Text.Wrap; text:page.notice; font.pixelSize:page.px(15); color:"#EAC28D" }
        MenuText {
            visible:page.view === "review" && page.report && (page.report.warnings || []).length > 0
            width:parent.width; wrapMode:Text.Wrap; text:page.report ? (page.report.warnings || []).join("\n") : ""; font.pixelSize:page.px(14); color:"#EAC28D"
        }
    }
    ListView {
        id:list
        visible:!page.moving
        anchors { left:parent.left; right:parent.right; top:heading.bottom; bottom:parent.bottom; topMargin:page.px(16) }
        model:page.rows; spacing:page.px(8); clip:true; boundsBehavior:Flickable.StopAtBounds
        delegate:Rectangle {
            id:card
            required property var modelData
            required property int index
            readonly property bool chosen:page.focusVisible && page.selectedId === modelData.id
            width:list.width; height:Math.max(page.px(102), content.height + page.px(18)); radius:page.px(11)
            color:chosen ? "#2E3947" : "#202936"; border.width: chosen ? 2 : 1; border.color: chosen ? "#EAC28D" : "#3D4B5C"; opacity:page.busy ? 0.6 : 1
            Column {
                id:content
                x:page.px(15); anchors.verticalCenter:parent.verticalCenter; width:parent.width - page.px(30); spacing:page.px(4)
                MenuText { width:parent.width; wrapMode:Text.Wrap; text:card.modelData.label; font.pixelSize:page.px(24); color:card.chosen ? "#F3EEE5" : "#ECEEF1" }
                MenuText { visible:!!card.modelData.detail; width:parent.width; wrapMode:Text.Wrap; text:card.modelData.detail; font.pixelSize:page.px(16); color:"#BBC6D3" }
                StorageCapacityBar {
                    visible: !!card.modelData.drive
                    width: parent.width; uiScale: page.uiScale
                    usage: card.modelData.usage || null
                    deviceSize: card.modelData.drive ? card.modelData.drive.physicalSize : 0
                }
            }
            MouseArea { anchors.fill:parent; enabled:!page.busy; onClicked:{page.select(index);page.activate();} }
        }
    }
    MoveGamesPage {
        focusVisible: page.focusVisible
        id:moves;anchors.fill:parent;uiScale:page.uiScale;visible:page.moving
        active:page.active&&page.moving
        onBackRequested:{page.moving=false;if(page.directGameMove){page.directGameMove=false;page.backRequested();}else page.refresh();}
    }
}
