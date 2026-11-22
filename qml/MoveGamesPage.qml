import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: pane
    property real uiScale: 1
    property bool focusVisible: true
    property bool active: false
    property bool busy: false
    property string view: "sources"
    property string selectedId: ""
    property string notice: ""
    property string operation: ""
    property var sources: []
    property var recoveries: []
    property var games: []
    property var source: null
    property var game: null
    property var destination: null
    property var choices: null
    property var plan: null
    property var progress: ({done:0,total:0,canCancel:false,message:""})
    property bool received: false
    property var directRequest: null
    property bool deleting: false
    readonly property var rows: makeRows()
    signal backRequested()

    function px(n) { return Math.round(n * uiScale); }
    function row(id, label, detail) { return {id:id, label:label, detail:detail || ""}; }
    function makeRows() {
        var result = [];
        if (view === "progress")
            return progress.canCancel ? [row("cancel-move", "Cancel move", "Original files will be kept")] : [];
        if (view === "confirm")
            return [row("cancel", "Cancel"), row("commit", deleting ? "Delete game" : "Move game")];
        if (view === "loading") return busy ? [] : [row("refresh", "Try again"), row("back", "Back")];
        if (view === "unprepared")
            return [row("back", "Back"), row("use-folders", "Use existing folders", "Keep the drive’s current layout")];
        if (view === "sources") {
            result = recoveries.map(j => row("resume:" + j.id,
                (j.operation === "delete" ? "Finish deleting: " : "Finish moving: ") + j.title, j.error));
            result = result.concat(sources.map(s => row("source:" + s.id, s.name)));
            result.push(row("refresh", "Refresh storage"));
        } else if (view === "games") {
            result = games.map(g => row("game:" + g.id, g.title, g.collection || g.system));
        } else if (view === "destinations") {
            result = sources.filter(s => s.writable).map(s => row("dest:" + s.id, s.name,
                s.id === source.id ? "Current storage" : ""));
        } else if (view === "collections" && choices) {
            result = choices.collections.map(c => row("collection:" + c.id, c.name,
                c.id === choices.current ? "Current collection" : ""));
        } else if (view === "folders" && choices) {
            if (choices.writable)
                result.push(row("use-folder", choices.folder === "." ? "Use drive root" : "Use this folder"));
            result = result.concat(choices.folders.map(d => row("folder:" + d.path, d.name, "Open folder")));
        }
        result.push(row("back", "Back"));
        return result;
    }

    function select(index) {
        if (!rows.length) return;
        index = (index + rows.length) % rows.length;
        selectedId = rows[index].id;
        list.positionViewAtIndex(index, ListView.Contain);
    }
    function setView(next, preferred) {
        view = next;
        var index = preferred ? rows.findIndex(r => r.id === preferred) : -1;
        if (rows.length) select(Math.max(0, index));
        else selectedId = "";
    }
    function move(direction) {
        if (!busy || view === "progress") select(rows.findIndex(r => r.id === selectedId) + direction);
    }
    function command(payload) {
        return ["/usr/bin/python3", Quickshell.shellPath("../tools/zaman-storage.py"),
                "request", JSON.stringify(payload)];
    }
    function request(action, extra) {
        if (busy) return;
        operation = action;
        received = false;
        busy = true;
        notice = "";
        process.exec(command(Object.assign({action:action}, extra || {})));
    }
    function open() {
        setView(directRequest ? "loading" : "sources");
        choices = null;
        plan = null;
        deleting = !!directRequest && directRequest.action === "delete";
        if (directRequest) {
            request("move-for-game", {paths:directRequest.paths});
        } else {
            request("move-sources");
        }
    }
    function openForGame(requestData) {
        directRequest = requestData;
        if (active && !busy) open();
    }
    function destinationRequest(extra) {
        return Object.assign({source:source, destination:destination, game:game.id}, extra || {});
    }
    function showFolders(folder) {
        request("move-destination", destinationRequest({useFolders:true, folder:folder}));
    }
    function activate() {
        var key = selectedId;
        if (view === "progress" && key === "cancel-move" && progress.canCancel) {
            progress = Object.assign({}, progress, {canCancel:false});
            cancellation.exec(command({action:"move-cancel", job:plan.id}));
            return;
        }
        if (busy) return;
        if (key === "back" || key === "cancel") { back(); return; }
        if (key === "refresh") { open(); return; }
        if (key.indexOf("resume:") === 0) {
            var recovery = recoveries.find(j => j.id === key.slice(7));
            deleting = recovery.operation === "delete";
            plan = {id:recovery.id};
            startMove();
        } else if (view === "sources" && key.indexOf("source:") === 0) {
            source = sources.find(s => s.id === key.slice(7));
            request("move-library", {source:source});
        } else if (view === "games" && key.indexOf("game:") === 0) {
            game = games.find(g => g.id === key.slice(5));
            setView("destinations", "dest:" + source.id);
        } else if (view === "destinations" && key.indexOf("dest:") === 0) {
            destination = sources.find(s => s.id === key.slice(5));
            request("move-destination", destinationRequest());
        } else if (view === "unprepared" && key === "use-folders") {
            showFolders(".");
        } else if (view === "folders" && key.indexOf("folder:") === 0) {
            showFolders(key.slice(7));
        } else if (view === "folders" && key === "use-folder") {
            request("move-plan", destinationRequest({useFolders:true, folder:choices.folder}));
        } else if (view === "collections" && key.indexOf("collection:") === 0) {
            var collection = key.slice(11);
            if (choices.same && collection === choices.current) {
                notice = "Choose a different collection on this storage.";
            } else request("move-plan", destinationRequest({collection:collection}));
        } else if (view === "confirm" && key === "commit") {
            startMove();
        }
    }
    function startMove() {
        progress = {done:0,total:plan.bytes || 0,canCancel:false,message:deleting ? "Deleting game…" : "Starting the move…"};
        setView("progress");
        request("move", {job:plan.id});
    }
    function back() {
        if (busy) return;
        notice = "";
        if (view === "confirm" && !deleting) setView(choices.mode, plan.selection);
        else if (view === "folders" && choices.folder !== ".") {
            var parts = choices.folder.split("/");
            parts.pop();
            showFolders(parts.join("/") || ".");
        } else if (view === "folders") setView("unprepared");
        else if (view === "unprepared" || view === "collections")
            setView("destinations", "dest:" + destination.id);
        else if (directRequest) backRequested();
        else if (view === "destinations") setView("games", "game:" + game.id);
        else if (view === "games" || view === "result") open();
        else backRequested();
    }
    function receive(line) {
        var result;
        try { result = JSON.parse(line); }
        catch (error) { notice = "Could not read the storage result."; return; }
        if (result.type === "storage-progress") { progress = result; return; }
        received = true;
        if (!result.ok) {
            notice = result.error || "Storage action failed.";
            if (operation === "move" || operation === "delete-plan") setView("result");
            return;
        }
        if (operation === "move-for-game") {
            sources = result.sources || [];
            source = result.source;
            game = result.game;
            if (!deleting) setView("destinations", "dest:" + source.id);
        } else if (operation === "move-sources") {
            sources = result.sources || [];
            recoveries = result.recoveries || [];
            setView("sources");
        } else if (operation === "move-library") {
            games = result.games || [];
            setView("games");
            if (!games.length) notice = "No supported games were found on this storage.";
        } else if (operation === "move-destination") {
            choices = result;
            var other = result.same && result.collections ? result.collections.find(c => c.id !== result.current) : null;
            setView(result.mode, result.mode === "collections" ? "collection:" + (other ? other.id : result.current) : "");
        } else if (operation === "move-plan" || operation === "delete-plan") {
            plan = Object.assign({selection:selectedId}, result.plan);
            setView("confirm");
        } else if (operation === "move") {
            notice = result.message;
            setView("result");
        }
    }
    onRowsChanged: if (!rows.some(r => r.id === selectedId)) selectedId = rows.length ? rows[0].id : ""
    onActiveChanged: {
        if (active && !busy) open();
        if (!active) directRequest = null;
    }
    Process {
        id: process
        stdout: SplitParser { onRead: line => pane.receive(line) }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            pane.busy = false;
            if (!pane.received) {
                pane.notice = "The storage action could not start. " + (process.stderr.text || "");
                if (pane.view === "progress") pane.setView("result");
            } else if (code === 0 && pane.active && pane.deleting && pane.operation === "move-for-game") {
                Qt.callLater(() => {
                    if (pane.active && pane.directRequest)
                        pane.request("delete-plan", {source:pane.source, game:pane.game.id});
                });
            }
        }
    }
    Process {
        id: cancellation
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Column {
        id: heading
        width: parent.width
        spacing: pane.px(10)
        MenuText {
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: pane.px(23)
            text: {
                switch (pane.view) {
                case "sources": return "Move games · Choose the source";
                case "games": return "Choose a game";
                case "destinations": return "Choose the storage";
                case "collections": return "Choose the collection";
                case "unprepared": return "Drive isn’t prepared for Zaman";
                case "folders": return pane.choices.folder === "." ? "Drive root" : pane.choices.folder;
                case "confirm": return (pane.deleting ? "Delete " : "Move ") + pane.plan.title + "?";
                case "progress": return pane.deleting ? "Deleting game…" : "Moving game…";
                case "loading": return pane.deleting ? "Find game to delete" : "Find game to move";
                default: return pane.deleting ? "Delete game" : "Game move";
                }
            }
        }
        MenuText {
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: pane.px(15)
            color: "#BBC6D3"
            text: {
                if (pane.view === "confirm" && pane.plan) {
                    var p = pane.plan;
                    if (pane.deleting) return p.source + " · " + p.files + " files\n" + p.message;
                    return p.destination + " · " + (p.target === "." ? "Drive root" : p.target)
                        + "\n" + p.files + " files · " + (p.bytes / 1073741824).toFixed(2) + " GiB\n" + p.message;
                }
                if (pane.view === "progress") return pane.progress.message
                    + (pane.progress.total > 0 ? " · " + Math.min(100, Math.floor(100 * pane.progress.done / pane.progress.total)) + "%" : "");
                if (pane.busy) return "Checking storage…";
                if (pane.view === "unprepared") return "Choose an existing folder or the drive root. Zaman puts the game in its own folder.";
                if (pane.view === "destinations" || pane.view === "collections") return pane.game.title;
                if (pane.view === "folders" && !pane.choices.writable) return "This folder is read-only. Open another folder.";
                return "";
            }
        }
        Rectangle {
            visible: pane.view === "progress" && pane.progress.total > 0
            width: parent.width
            height: pane.px(7)
            radius: height / 2
            color: "#35465C"
            Rectangle {
                height: parent.height
                radius: parent.radius
                color: "#EAC28D"
                width: parent.width * Math.max(0, Math.min(1, pane.progress.done / (pane.progress.total || 1)))
            }
        }
        MenuText {
            visible: !!pane.notice
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: pane.px(16)
            color: "#EAC28D"
            text: pane.notice
        }
    }
    ListView {
        id:list;anchors{left:parent.left;right:parent.right;top:heading.bottom;bottom:parent.bottom;topMargin:pane.px(18)}
        model:pane.rows;spacing:pane.px(9);clip:true;boundsBehavior:Flickable.StopAtBounds
        delegate:Rectangle {
            id:card;required property var modelData;required property int index
            readonly property bool chosen:pane.focusVisible && pane.selectedId===modelData.id
            width:list.width;height:Math.max(pane.px(102),content.height+pane.px(28));radius:pane.px(11);color:chosen ? "#2E3947" : "#202936"; border.width: chosen ? 2 : 1; border.color: chosen ? "#EAC28D" : "#3D4B5C"
            Column{id:content;x:pane.px(15);y:pane.px(14);width:parent.width-pane.px(30);spacing:pane.px(4)
                MenuText{width:parent.width;wrapMode:Text.Wrap;font.pixelSize:pane.px(24);text:card.modelData.label;color:card.chosen?"#F3EEE5":"#ECEEF1"}
                MenuText{visible:!!card.modelData.detail;width:parent.width;wrapMode:Text.Wrap;font.pixelSize:pane.px(16);text:card.modelData.detail;color:card.chosen?"#BBC6D3":"#BBC6D3"}
            }
            MouseArea{anchors.fill:parent;enabled:!pane.busy||pane.view==="progress";onClicked:{pane.select(index);pane.activate();}}
        }
    }
}
