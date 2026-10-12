//@ pragma ShellId zaman-menu-dev

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property bool menuOpen: false
    property bool opening: false
    property bool ready: false
    property bool closing: false
    property bool helperIdle: false
    property double openStartedMs: 0
    property double lastReadyMs: -1
    property double lastVisibleMs: -1
    readonly property string menuInstance: Date.now().toString()
    property int menuGeneration: 0
    property string sessionAction: "exit-game"
    property bool exitBusy: false
    property bool exitResultReceived: false
    property string exitNotice: ""
    readonly property string sessionActionPath: Quickshell.env("ZAMAN_MENU_SESSION_BRIDGE") || ""
    property string foreground: "library"
    property int controllerCount: 0
    property bool displaySupported: false
    property var controllerDevices: []
    property string controllerWarning: ""
    property int selected: 0
    property string page: ""
    property bool bluetoothLoaded: false
    property int mainSelected: 0
    property int settingsSelected: 0
    property int powerSelected: 0
    property string returnPage: ""
    property var pageEntry: ({ label: "", key: "", detail: "" })
    readonly property bool listPage: page === "" || page === "settings" || page === "power"
    readonly property bool navigationPage: listPage || page === "audio" || page === "controllers" || page === "network" || page === "bluetooth" || page === "display" || page === "exit" || page === "reboot" || page === "shutdown"
    property int heldDirection: 0
    property var pressed: ({})
    readonly property real uiScale: Math.max(0.65, Math.min(1.4, overlay.height / 1080))
    readonly property string helperPath: Quickshell.env("ZAMAN_MENU_DEV_INPUT") || ""
    readonly property string uiFontName: "Sans Serif"
    property string clockText: Qt.formatDateTime(new Date(), "h:mm AP")
    readonly property string monoFontName: monoFont.status === FontLoader.Ready ? monoFont.name : "Monospace"
    readonly property var mainEntries: [
        { label: foreground === "game" ? "Resume" : "Return to library", key: "resume", detail: foreground === "game" ? "Return to your game" : "Continue browsing your games" },
        { label: "Audio", key: "audio", detail: "Volume and audio output" },
        { label: "Settings", key: "settings", detail: "Devices, connections and appearance" },
        { label: "Power", key: "power", detail: "Device power options" }
    ].concat(foreground === "game" ? [
        { label: "Exit Game", key: "exit", detail: "Close the current game" }
    ] : [])
    readonly property var settingsEntries: [
        { label: "Controllers", key: "controllers", detail: "Connected controllers and active input profiles" },
        { label: "Network", key: "network", detail: "Connections and saved networks" },
        { label: "Bluetooth", key: "bluetooth", detail: "Pair and manage your devices" },
        { label: "Display", key: "display", detail: "Resolution and refresh rate" },
        { label: "Appearance", key: "appearance", detail: "Theme, colors and interface style" }
    ]
    readonly property var powerEntries: [
        { label: "Shutdown", key: "shutdown", detail: "Turn off your device" },
        { label: "Reboot", key: "reboot", detail: "Restart Zaman OS" },
        { label: "Sleep", key: "sleep", detail: "Coming soon", disabled: true }
    ]
    readonly property var entries: page === "settings" ? settingsEntries : page === "power" ? powerEntries : mainEntries

    FontLoader {
        id: menuFont
        source: Quickshell.env("ZAMAN_MENU_DEV_FONT") ? "file://" + Quickshell.env("ZAMAN_MENU_DEV_FONT") : ""
    }
    FontLoader {
        id: monoFont
        source: Quickshell.env("ZAMAN_MENU_DEV_MONO") ? "file://" + Quickshell.env("ZAMAN_MENU_DEV_MONO") : ""
    }

    // The page owns deferred layout work; destroyed delegates are never captured.
    Timer {
        id: focusSettle
        interval: 1
        repeat: false
        onTriggered: root.settleFocus()
    }
    function requestFocusSettle() { focusSettle.restart(); }
    function settleFocus() {
        if (!(menuOpen && listPage) || selected < 0 || selected >= menuList.count) return;
        menuList.forceLayout();
        menuList.positionViewAtIndex(selected, ListView.Contain);
    }

    function px(value) { return Math.round(value * uiScale); }
    function stopRepeat() {
        repeatDelay.stop();
        repeatStep.stop();
        heldDirection = 0;
    }
    function hold(direction, immediate) {
        stopRepeat();
        if (direction === 0 || !menuOpen || !navigationPage) return;
        heldDirection = direction;
        if (immediate) move(direction);
        repeatDelay.restart();
    }
    function directionPressed(direction) {
        return direction < 0 ? (pressed.ui_up || pressed.key_up) : (pressed.ui_down || pressed.key_down);
    }

    Component.onCompleted: {
        // Manual restart avoids reloading an input lease during development.
        Quickshell.watchFiles = false;
        if (helperPath.length === 0) {
            console.error("Launch this prototype with its run.sh helper.");
            Qt.quit();
        } else {
            bridge.running = true;
            if (Quickshell.env("ZAMAN_MENU_DEV_OPEN_ON_START") === "1") openMenu();
        }
    }

    IpcHandler {
        target: "menu"
        function open(): string { return root.openMenu(); }
        function close(): string { root.closeMenu(); return root.menuStatus(); }
        function closeSession(key: string): string {
            if (key === root.menuInstance + ":" + root.menuGeneration && root.menuOpen && !root.exitBusy && !root.opening && !root.closing) root.closeMenu();
            return root.menuStatus();
        }
        function toggle(): string {
            if (root.exitBusy || root.opening || root.closing) return root.menuStatus();
            if (root.menuOpen) root.closeMenu();
            else root.openMenu();
            return root.menuStatus();
        }
        function status(): string { return root.menuStatus(); }
        function audioDiagnostics(): string {
            return JSON.stringify({ page: root.page, loaded: audioPageLoader.item !== null, loaderStatus: audioPageLoader.status,
                audio: audioPageLoader.item ? audioPageLoader.item.diagnostics() : null });
        }
        function timings(): string { return JSON.stringify({status:root.menuStatus(), helperIdle:root.helperIdle,
            readyMs:root.lastReadyMs, visibleMs:root.lastVisibleMs,
            sessionKey:root.menuInstance + ":" + root.menuGeneration, generation:root.menuGeneration}); }
    }

    function select(index) {
        selected = (index + entries.length) % entries.length;
        menuList.positionViewAtIndex(selected, ListView.Contain);
    }
    function move(direction) {
        if (menuOpen && (page === "exit" || page === "reboot" || page === "shutdown")) { exitPage.move(direction); return; }
        if (menuOpen && page === "display") {
            displayPage.move(direction);
            return;
        }
        if (menuOpen && page === "bluetooth") {
            if (bluetoothPageLoader.item) bluetoothPageLoader.item.move(direction);
            return;
        }
        if (menuOpen && page === "network") {
            if (networkPageLoader.item) networkPageLoader.item.move(direction);
            return;
        }
        if (menuOpen && page === "controllers") {
            controllersPage.move(direction);
            return;
        }
        if (menuOpen && page === "audio") {
            if (audioPageLoader.item) audioPageLoader.item.move(direction);
            return;
        }
        if (!menuOpen || !listPage) return;
        select(selected + direction);
    }
    function activate() {
        if (!menuOpen || exitBusy) return;
        if (page === "exit" || page === "reboot" || page === "shutdown") { stopRepeat(); exitPage.activate(); return; }
        if (page === "display") {
            stopRepeat(); displayPage.activate(); return;
        }
        if (page === "bluetooth") {
            stopRepeat();
            if (bluetoothPageLoader.item) bluetoothPageLoader.item.activate();
            else back();
            return;
        }
        if (page === "network") {
            stopRepeat();
            if (networkPageLoader.item) networkPageLoader.item.activate();
            else back();
            return;
        }
        if (page === "controllers") {
            stopRepeat();
            controllersPage.activate();
            return;
        }
        if (page === "audio") {
            stopRepeat();
            if (audioPageLoader.item) audioPageLoader.item.activate();
            else back();
            return;
        }
        if (!listPage) { back(); return; }
        stopRepeat();
        var entry = entries[selected];
        if (!entry || entry.disabled === true) return;
        if (entry.key === "resume") closeMenu();
        else if (entry.key === "settings" || entry.key === "power") {
            mainSelected = selected;
            pageEntry = entry;
            page = entry.key;
            select(page === "power" ? powerSelected : settingsSelected);
        } else {
            returnPage = page;
            if (page === "settings") settingsSelected = selected;
            else if (page === "power") powerSelected = selected;
            else mainSelected = selected;
            pageEntry = entry;
            if (entry.key === "exit" || entry.key === "reboot" || entry.key === "shutdown") exitNotice = "";
            if (entry.key === "bluetooth") bluetoothLoaded = true;
            page = entry.key;
        }
    }
    function leaveSettingsPage() {
        stopRepeat();
        page = "settings";
        select(settingsSelected);
    }
    function back() {
        if (exitBusy) return;
        stopRepeat();
        if (page === "display") { displayPage.back(); return; }
        if (page === "bluetooth" && bluetoothPageLoader.item) {
            bluetoothPageLoader.item.back();
            return;
        }
        if (page === "network" && networkPageLoader.item) {
            networkPageLoader.item.back();
            return;
        }
        if (!listPage) {
            page = returnPage;
            select(page === "settings" ? settingsSelected : page === "power" ? powerSelected : mainSelected);
        } else if (page === "settings" || page === "power") {
            if (page === "settings") settingsSelected = selected;
            else powerSelected = selected;
            page = "";
            select(mainSelected);
        } else closeMenu();
    }
    function menuStatus() {
        if (exitBusy) return "busy";
        if (closing) return "closing";
        if (menuOpen) return "open";
        if (opening) return "opening";
        return "hidden";
    }
    function resetMenuSession() {
        menuOpen = false;
        opening = false;
        ready = false;
        closing = false;
        stopRepeat();
        pressed = ({});
        controllerCount = 0;
        controllerDevices = [];
        controllerWarning = "";
        displaySupported = false;
        bluetoothLoaded = false;
        page = "";
        selected = 0;
        mainSelected = 0;
        settingsSelected = 0;
        powerSelected = 0;
        returnPage = "";
        pageEntry = ({ label: "", key: "", detail: "" });
    }
    function openMenu() {
        // Repeated open requests never toggle a visible menu or overlap leases.
        if (exitBusy) return "exiting-game";
        if (menuOpen || opening || closing) return menuStatus();
        resetMenuSession();
        menuGeneration += 1;
        opening = true;
        openStartedMs = Date.now();
        clockText = Qt.formatDateTime(new Date(), "h:mm AP");
        lastReadyMs = -1;
        lastVisibleMs = -1;
        if (!bridge.running) {
            helperIdle = false;
            bridge.running = true;
        } else if (helperIdle) {
            helperIdle = false;
            bridge.write(JSON.stringify({action: "open"}) + "\n");
        }
        return "opening";
    }
    function hideMenu() {
        if ((menuOpen || opening) && bluetoothPageLoader.item) bluetoothPageLoader.item.shutdown();
        menuOpen = false;
        opening = false;
        stopRepeat();
        pressed = ({});
    }
    function closeMenu() {
        if (exitBusy || closing || !(menuOpen || opening)) return;
        closing = true;
        hideMenu();
        // Hide the exclusive layer first, then let the helper restore the lease.
        if (bridge.running) bridge.write(JSON.stringify({action: "close"}) + "\n");
        else resetMenuSession();
    }
    function input(event, value) {
        if (!menuOpen || typeof value !== "number" || !isFinite(value)) return;
        var down = value > 0.5;
        var wasDown = pressed[event] === true;
        var next = Object.assign({}, pressed);
        next[event] = down;
        pressed = next;
        if (page === "display" && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            if (down && !wasDown) displayPage.horizontal(event === "ui_left" || event === "key_left" ? -1 : 1);
        } else if (page === "bluetooth" && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            if (down && !wasDown && bluetoothPageLoader.item) bluetoothPageLoader.item.horizontal(event === "ui_left" || event === "key_left" ? -1 : 1);
            else if (down && !wasDown && !bluetoothPageLoader.item && (event === "ui_left" || event === "key_left")) back();
        } else if (page === "network" && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            if (down && !wasDown && networkPageLoader.item) networkPageLoader.item.horizontal(event === "ui_left" || event === "key_left" ? -1 : 1);
            else if (down && !wasDown && !networkPageLoader.item && (event === "ui_left" || event === "key_left")) back();
        } else if (page === "audio" && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            if (audioPageLoader.item) audioPageLoader.item.horizontal(event, value);
            else if (down && !wasDown && (event === "ui_left" || event === "key_left")) back();
        } else if (event === "ui_up" || event === "ui_down" || event === "key_up" || event === "key_down") {
            if (down && !wasDown) {
                hold(event === "ui_up" || event === "key_up" ? -1 : 1, true);
            } else if (!down) {
                var remaining = heldDirection !== 0 && directionPressed(heldDirection) ? heldDirection
                    : (directionPressed(-1) ? -1 : (directionPressed(1) ? 1 : 0));
                if (remaining !== heldDirection) hold(remaining, false);
            }
        } else if (down && !wasDown) {
            if (event === "ui_accept" || event === "ui_right" || event === "key_right") activate();
            else if (event === "ui_back" || event === "ui_cancel" || event === "ui_left" || event === "key_left") back();
        }
    }
    function requestExitGame() {
        var power = page === "reboot" || page === "shutdown";
        if (exitBusy || !menuOpen || (!power && (page !== "exit" || foreground !== "game"))) return;
        if (sessionActionPath.length === 0) {
            exitNotice = "The menu action helper is unavailable. Restart the menu service after updating.";
            return;
        }
        stopRepeat();
        sessionAction = power ? page : "exit-game";
        exitBusy = true;
        exitResultReceived = false;
        exitNotice = "";
        exitAction.running = true;
    }
    function receiveExitResult(line) {
        var message;
        try { message = JSON.parse(line); } catch (error) { return; }
        if (message.type === "exit-progress" || message.type === "power-progress") {
            exitNotice = message.message || "Closing game…";
        } else if (message.type === "exit-result" && exitBusy) {
            exitResultReceived = true;
            exitNotice = message.ok ? "" : (message.message || "Unable to complete the session action.");
            // Keep duplicate requests blocked until the process exits. This also
            // prevents a second running=true while its first result is draining.
            if (message.ok) {
                foreground = "library";
                if (menuOpen || opening) {
                    closing = true;
                    hideMenu();
                    if (bridge.running) bridge.write(JSON.stringify({action: "close"}) + "\n");
                }
            }
        }
    }
    function finishExitAction(exitCode) {
        if (!exitResultReceived) exitNotice = "The session action stopped before reporting completion.";
        exitBusy = false;
        if (exitNotice.length > 0) console.warn(exitNotice);
    }

    Process {
        id: exitAction
        command: ["/usr/bin/python3", root.sessionActionPath, root.sessionAction]
        stdout: SplitParser { onRead: data => root.receiveExitResult(data) }
        stderr: SplitParser { onRead: data => console.warn(data) }
        onExited: (exitCode, exitStatus) => root.finishExitAction(exitCode)
    }

    function receive(line) {
        if (!line.startsWith("{")) return;
        var message;
        try { message = JSON.parse(line); }
        catch (error) { console.error("Invalid preview message: " + line); return; }
        if (message.type === "helper-idle") {
            if (!bridge.running || message.protocol !== 1) return;
            if (menuOpen && !closing) return;
            // Idle is acknowledged only after the helper restores its lease.
            helperIdle = true;
            if (opening && !closing) {
                helperIdle = false;
                bridge.write(JSON.stringify({action: "open"}) + "\n");
            } else resetMenuSession();
        } else if (message.type === "ready") {
            // A close during acquisition must never be undone by late readiness.
            if (!opening || closing || !bridge.running) return;
            displaySupported = message.display === true;
            foreground = message.foreground;
            controllerCount = message.controllers;
            controllerDevices = message.devices || [];
            ready = true;
            opening = false;
            menuOpen = true;
            selected = 0;
            lastReadyMs = Date.now() - openStartedMs;
            console.info("Resident menu input ready after " + lastReadyMs + " ms");
        } else if (message.type === "controllers") {
            stopRepeat();
            controllerCount = message.controllers;
            controllerDevices = message.devices || [];
        } else if (message.type === "input-reset") {
            stopRepeat(); pressed = ({});
            if (audioPageLoader.item) {
                audioPageLoader.item.stopHorizontal();
                audioPageLoader.item.leftDown = false;
                audioPageLoader.item.rightDown = false;
            }
        } else if (message.type === "display") displayPage.receive(message);
        else if (message.type === "input") input(message.event, message.value);
        else if (message.type === "warning") {
            controllerWarning = "Controller input interrupted. Reconnect and press a button, or use the keyboard.";
            console.warn(message.message);
        } else if (message.type === "controller-recovered") controllerWarning = "";
        else if (message.type === "closing") {
            closing = true;
            hideMenu();
        } else if (message.type === "closed") {
            // Wait for helper-idle before allowing a new input lease.
            closing = true;
            hideMenu();
        }
        else if (message.type === "error") {
            console.error(message.message);
            closing = true;
            hideMenu();
        }
    }

    Process {
        id: bridge
        command: [root.helperPath, "--resident"]
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.receive(data) }
        stderr: SplitParser { onRead: data => console.warn(data) }
        onExited: (exitCode, exitStatus) => {
            root.hideMenu();
            root.helperIdle = false;
            if (exitCode !== 0) console.error("Preview helper exited with code " + exitCode);
            root.resetMenuSession();
        }
    }
    Timer {
        interval: 2000
        running: !bridge.running
        repeat: true
        onTriggered: {
            root.helperIdle = false;
            bridge.running = true;
        }
    }
    Timer {
        interval: 12000
        running: root.opening && !root.ready
        onTriggered: {
            console.error("Preview helper did not become ready.");
            root.closeMenu();
        }
    }
    Timer {
        interval: 1000
        running: root.menuOpen
        repeat: true
        onTriggered: bridge.write(JSON.stringify({action: "heartbeat"}) + "\n")
    }
    Timer {
        interval: 30000
        running: root.menuOpen
        repeat: true
        onTriggered: root.clockText = Qt.formatDateTime(new Date(), "h:mm AP")
    }
    Timer {
        id: repeatDelay
        interval: 220
        onTriggered: {
            if (root.heldDirection !== 0 && root.menuOpen && root.navigationPage) {
                root.move(root.heldDirection);
                repeatStep.start();
            }
        }
    }
    Timer {
        id: repeatStep
        interval: 70
        repeat: true
        onTriggered: {
            if (root.heldDirection === 0 || !root.menuOpen || !root.navigationPage) stop();
            else root.move(root.heldDirection);
        }
    }

    PanelWindow {
        id: overlay
        visible: root.menuOpen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "zaman-menu-dev"
        WlrLayershell.keyboardFocus: root.menuOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onBackingWindowVisibleChanged: {
            if (backingWindowVisible && root.menuOpen) {
                root.lastVisibleMs = Date.now() - root.openStartedMs;
                console.info("Resident menu visible after " + root.lastVisibleMs + " ms");
                Qt.callLater(() => inputScope.forceActiveFocus());
                panel.slideOffset = -panel.width - root.px(36);
                slideIn.restart();
                bridge.write(JSON.stringify({action: "opened"}) + "\n");
            } else if (!backingWindowVisible) {
                slideIn.stop();
                panel.slideOffset = -panel.width - root.px(36);
            }
        }
        onClosed: root.closeMenu()

        NumberAnimation {
            id: slideIn
            target: panel
            property: "slideOffset"
            to: 0
            duration: 300
            easing.type: Easing.InOutCubic
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#89080C13" }
                GradientStop { position: 0.55; color: "#57080B11" }
                GradientStop { position: 1.0; color: "#31080A0F" }
            }
        }
        MouseArea { anchors.fill: parent; onClicked: root.back() }

        // Two small static shadow surfaces; navigation has no animation delay.
        Rectangle {
            x: panel.x + root.px(5); y: panel.y + root.px(12)
            width: panel.width; height: panel.height
            radius: panel.radius
            color: "#35000000"
        }
        Rectangle {
            x: panel.x + root.px(2); y: panel.y + root.px(5)
            width: panel.width; height: panel.height
            radius: panel.radius
            color: "#25000000"
        }
        Rectangle {
            id: panel
            property real slideOffset: -width - root.px(36)
            x: root.px(28) + slideOffset
            y: root.px(26)
            width: Math.min(Math.round(parent.width * 0.44), root.px(700))
            height: parent.height - root.px(52)
            radius: root.px(24)
            border.width: 1
            border.color: "#405D718C"
            // Keep the surface almost opaque so background titles do not
            // compete with menu text; retain the restrained blue gradient.
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#FE171D28" }
                GradientStop { position: 0.45; color: "#FE12161E" }
                GradientStop { position: 1.0; color: "#FE17191F" }
            }
            readonly property real padding: root.px(32)
            MouseArea { anchors.fill: parent; onClicked: mouse => mouse.accepted = true }

            Column {
                id: heading
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    margins: panel.padding
                }
                spacing: root.px(12)

                Item {
                    width: parent.width
                    height: root.px(52)
                    ZamanMark {
                        id: brandMark
                        part: "bird"
                        width: root.px(50); height: root.px(48)
                        y: root.px(2)
                        ink: "#EEE1CF"
                    }
                    Column {
                        anchors { left: brandMark.right; leftMargin: root.px(16) }
                        y: root.px(3)
                        spacing: root.px(7)
                        Row {
                            spacing: root.px(10)
                            ZamanMark {
                                part: "wordmark"
                                width: root.px(166); height: root.px(31)
                                ink: "#EEE1CF"
                            }
                            MenuText {
                                text: "OS"
                                font.pixelSize: root.px(13)
                                color: "#C3CEDB"
                                y: root.px(16)
                            }
                        }
                        MenuText {
                            text: "PLAY  EXPLORE  BELONG"
                            color: "#BBC6D3"
                            font.family: root.monoFontName
                            font.pixelSize: root.px(9)
                            font.letterSpacing: 1
                        }
                    }
                    Row {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: root.px(12)
                        MenuIcon {
                            visible: root.controllerCount > 0
                            name: "controllers"; ink: "#9CAFC5"
                            width: root.px(22); height: width
                        }
                        MenuText {
                            text: root.clockText
                            color: "#C7CFD8"
                            font.family: root.monoFontName
                            font.pixelSize: root.px(13)
                            y: root.px(3)
                        }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: "#265C6E85" }
                MenuText {
                    text: root.page === "" ? "System menu" : (root.page === "settings" ? "Settings" : root.page === "power" ? "Power" : root.pageEntry.label)
                    font.pixelSize: root.px(29)
                    font.weight: Font.DemiBold
                    color: "#F0E5D6"
                }
                Row {
                    spacing: root.px(9)
                    Rectangle {
                        width: root.px(6); height: width; radius: width / 2
                        y: root.px(7)
                        color: "#88A8C9"
                    }
                    MenuText {
                        text: root.page === "settings" ? "Devices, connections and personalization."
                            : root.page === "power" ? "Shutdown and reboot require confirmation."
                            : (root.foreground === "game" ? "Your game is still running." : "Your library is waiting.")
                        color: "#BBC6D3"
                        font.pixelSize: root.px(15)
                    }
                }
                MenuText {
                    visible: root.controllerWarning.length > 0
                    width: parent.width
                    text: root.controllerWarning
                    wrapMode: Text.WordWrap
                    color: "#E8C08C"
                    font.pixelSize: root.px(15)
                }
            }

            ListView {
                id: menuList
                property point lastPointerPosition: Qt.point(-100000, -100000)
                visible: root.listPage
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: root.px(18); rightMargin: root.px(18)
                    topMargin: root.px(18); bottomMargin: root.px(18)
                }
                model: root.entries
                currentIndex: root.selected
                spacing: root.px(4)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                delegate: MenuFocusRow {
                    id: menuRow
                    required property var modelData
                    required property int index
                    chosen: root.selected === index
                    uiScale: root.uiScale
                    width: menuList.width
                    baseHeight: 66
                    onFocusSettled: if (menuRow.chosen) root.requestFocusSettle()
                    MenuFocusBackground {
                        chosen: menuRow.chosen
                        uiScale: root.uiScale
                        emphasis: menuRow.focusAmount
                    }
                    Rectangle {
                        x: root.px(14); y: Math.round((parent.height - height) / 2)
                        width: root.px(42 + 4 * menuRow.focusAmount); height: width
                        radius: root.px(12)
                        color: menuRow.chosen ? "#16291D10" : "#112F425C"
                        MenuIcon {
                            anchors.centerIn: parent
                            name: menuRow.modelData.key === "resume" && root.foreground !== "game" ? "library" : menuRow.modelData.key
                            ink: menuRow.chosen ? "#30271E" : "#DEC09A"
                            width: root.px(30 + 2 * menuRow.focusAmount); height: width
                        }
                    }
                    Column {
                        x: root.px(72)
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width - root.px(160)
                        spacing: root.px(2)
                        MenuText {
                            width: parent.width
                            text: menuRow.modelData.label
                            color: menuRow.modelData.disabled === true ? (menuRow.chosen ? "#78634D" : "#7F8A98") : menuRow.chosen ? "#211E1B" : "#ECEEF1"
                            font.pixelSize: root.px(22 + 2 * menuRow.focusAmount)
                            elide: Text.ElideRight
                        }
                        MenuText {
                            width: parent.width
                            text: menuRow.modelData.detail
                            color: menuRow.chosen ? "#473627" : "#BBC6D3"
                            font.pixelSize: root.px(14)
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        visible: menuRow.modelData.disabled === true || (menuRow.modelData.key === "appearance" && menuRow.chosen)
                        anchors { right: chevron.left; rightMargin: root.px(10) }
                        y: Math.round((parent.height - height) / 2)
                        width: root.px(45); height: root.px(21); radius: root.px(7)
                        color: "#19281C12"
                        MenuText {
                            anchors.centerIn: parent
                            text: "Soon"; font.pixelSize: root.px(10); color: "#473627"
                        }
                    }
                    MenuIcon {
                        id: chevron
                        visible: menuRow.modelData.disabled !== true
                        name: "chevron"
                        anchors { right: parent.right; rightMargin: root.px(16) }
                        y: Math.round((parent.height - height) / 2)
                        width: root.px(17); height: root.px(22)
                        ink: menuRow.chosen ? "#614930" : "#7D899B"
                    }
                    MouseArea {
                        id: menuPointer
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: if (menuRow.pointerMoved(menuPointer)) root.select(index)
                        onPositionChanged: if (menuRow.pointerMoved(menuPointer)) root.select(index)
                        onClicked: { root.select(index); root.activate(); }
                    }
                }
            }

            DisplayPage {
                id: displayPage
                visible: root.page === "display"
                active: root.page === "display" && root.menuOpen
                helperReady: root.displaySupported
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onCommand: request => { if (bridge.running) bridge.write(JSON.stringify(request) + "\n"); }
                onBackRequested: root.leaveSettingsPage()
                onNavigationReset: root.stopRepeat()
            }
            // Keep Bluetooth alive while the menu is open to finish scan cleanup.
            Loader {
                id: bluetoothPageLoader
                visible: root.page === "bluetooth"
                active: root.bluetoothLoaded && root.menuOpen
                source: active ? Qt.resolvedUrl("BluetoothPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: item.uiScale = Qt.binding(() => root.uiScale)
            }
            Connections {
                target: bluetoothPageLoader.item
                function onBackRequested() { root.leaveSettingsPage(); }
                function onNavigationReset() { root.stopRepeat(); }
            }
            // Optional native integrations load only while their page is open.
            Loader {
                id: networkPageLoader
                visible: root.page === "network"
                active: root.page === "network" && root.menuOpen
                source: active ? Qt.resolvedUrl("NetworkPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: item.uiScale = Qt.binding(() => root.uiScale)
            }
            Connections {
                target: networkPageLoader.item
                function onBackRequested() { root.leaveSettingsPage(); }
                function onNavigationReset() { root.stopRepeat(); }
            }
            ControllersPage {
                id: controllersPage
                visible: root.page === "controllers"
                uiScale: root.uiScale
                devices: root.controllerDevices
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onBackRequested: root.back()
            }
            Loader {
                id: audioPageLoader
                visible: root.page === "audio"
                active: root.page === "audio" && root.menuOpen
                source: active ? Qt.resolvedUrl("AudioPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: {
                    item.uiScale = Qt.binding(() => root.uiScale);
                    item.active = true;
                }
            }
            Connections {
                target: audioPageLoader.item
                function onBackRequested() { root.back(); }
            }
            Column {
                visible: (root.page === "audio" && audioPageLoader.status === Loader.Error)
                    || (root.page === "network" && networkPageLoader.status === Loader.Error)
                    || (root.page === "bluetooth" && bluetoothPageLoader.status === Loader.Error)
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom
                    leftMargin: panel.padding; rightMargin: panel.padding; topMargin: root.px(32)
                }
                spacing: root.px(20)
                MenuText {
                    width: parent.width; wrapMode: Text.WordWrap
                    text: root.page === "bluetooth" ? "Bluetooth is unavailable." : root.page === "network" ? "Network settings are unavailable." : "Audio is unavailable."
                    font.pixelSize: root.px(24)
                }
                MenuText {
                    width: parent.width; wrapMode: Text.WordWrap
                    text: root.page === "audio" ? "Press B or Escape to return to the main menu." : "Press B or Escape to return to Settings."
                    color: "#BBC6D3"; font.pixelSize: root.px(17)
                }
                Rectangle {
                    width: parent.width; height: root.px(56); radius: root.px(13)
                    color: "#EAC28D"
                    MenuText {
                        anchors.centerIn: parent
                        text: "Back"; color: "#29221C"; font.pixelSize: root.px(20)
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.back() }
                }
            }

            ExitGamePage {
                id: exitPage
                visible: root.page === "exit" || root.page === "reboot" || root.page === "shutdown"
                active: root.menuOpen && visible
                prompt: root.page === "reboot" ? "Restart Zaman?" : root.page === "shutdown" ? "Shut down Zaman?" : "Exit this game?"
                detail: root.page === "reboot" ? "Close any running game and restart Zaman." : root.page === "shutdown" ? "Close any running game and turn off Zaman." : "Close the current game and return to your library."
                cancelLabel: root.page === "exit" ? "Keep playing" : "Cancel"
                confirmLabel: root.page === "reboot" ? "Reboot" : root.page === "shutdown" ? "Shutdown" : "Exit Game"
                busyHeading: root.sessionAction === "reboot" ? "Restarting Zaman…" : root.sessionAction === "shutdown" ? "Shutting down Zaman…" : "Closing game…"
                busy: root.exitBusy
                notice: root.exitNotice
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom; bottom: footer.top
                    leftMargin: panel.padding; rightMargin: panel.padding
                    topMargin: root.px(32); bottomMargin: root.px(18)
                }
                onConfirmRequested: root.requestExitGame()
                onBackRequested: root.back()
            }

            Column {
                visible: root.page === "appearance"
                anchors {
                    left: parent.left; right: parent.right; top: heading.bottom
                    leftMargin: panel.padding; rightMargin: panel.padding; topMargin: root.px(32)
                }
                spacing: root.px(20)
                Rectangle {
                    width: root.px(72); height: width; radius: root.px(20)
                    color: "#1E3C5579"; border.width: 1; border.color: "#305F7B9A"
                    MenuIcon {
                        anchors.centerIn: parent
                        name: root.pageEntry.key
                        ink: "#DAB991"
                        width: root.px(38); height: width
                    }
                }
                MenuText {
                    text: root.pageEntry.detail
                    width: parent.width; wrapMode: Text.WordWrap
                    font.pixelSize: root.px(24)
                }
                MenuText {
                    text: root.pageEntry.key === "appearance"
                        ? "Customize your system's appearance in a future update."
                        : "These controls are coming next."
                    color: "#BBC6D3"; width: parent.width; wrapMode: Text.WordWrap
                    font.pixelSize: root.px(17)
                }
                Rectangle {
                    width: parent.width; height: root.px(56); radius: root.px(13)
                    border.width: 1; border.color: "#E8C498"
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#EAC28D" }
                        GradientStop { position: 1.0; color: "#CB986C" }
                    }
                    MenuText {
                        x: Math.round((parent.width - width) / 2)
                        y: Math.round((parent.height - height) / 2)
                        text: "Back"; color: "#29221C"; font.pixelSize: root.px(20)
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.back() }
                }
            }

            Column {
                id: footer
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: panel.padding }
                spacing: root.px(12)
                Rectangle { width: parent.width; height: 1; color: "#265C6E85" }
                Row {
                    width: parent.width
                    spacing: root.px(16)
                    id: navigationGuide
                    readonly property bool adjusting: (root.page === "display" && displayPage.adjustable)
                        || (root.page === "audio" && audioPageLoader.item && audioPageLoader.item.adjustable)
                    readonly property bool textEntry: (root.page === "network" && networkPageLoader.item && networkPageLoader.item.editingPassword)
                        || (root.page === "bluetooth" && bluetoothPageLoader.item && bluetoothPageLoader.item.editingCode)
                    Repeater {
                        model: [
                            {faces: navigationGuide.adjusting ? ["west", "east"] : navigationGuide.textEntry ? ["north", "south", "east", "west"] : ["north", "south"], label: navigationGuide.adjusting ? "Adjust ←→" : navigationGuide.textEntry ? "Move ↑↓←→" : "Navigate ↑↓", key: navigationGuide.adjusting ? "←→" : "↑↓"},
                            {faces: ["south"], show: !navigationGuide.adjusting || (root.page === "audio" && audioPageLoader.item && audioPageLoader.item.rows[audioPageLoader.item.selected].key === "output"), label: navigationGuide.adjusting ? "Apply" : navigationGuide.textEntry ? "Select" : "Select / →", key: "↵"},
                            {faces: ["east"], label: navigationGuide.adjusting || navigationGuide.textEntry ? "Back" : "Back / ←", key: "Esc"}
                        ]
                        delegate: Row {
                            required property var modelData
                            visible: modelData.show !== false
                            spacing: root.px(7)
                            MenuButtonDiamond {
                                visible: root.controllerCount > 0
                                uiScale: root.uiScale
                                activeFaces: modelData.faces
                                width: implicitWidth; height: implicitHeight
                            }
                            MenuText {
                                visible: root.controllerCount === 0
                                text: modelData.key
                                font.family: root.monoFontName
                                font.pixelSize: root.px(12); color: "#EAC28D"
                                y: root.px(5)
                            }
                            MenuText {
                                text: modelData.label
                                font.pixelSize: root.px(13); color: "#B8C1CE"
                                y: root.px(5)
                            }
                        }
                    }
                }
                Item {
                    width: parent.width; height: root.px(14)
                    MenuText {
                        text: "KAWN ELECTRO"
                        color: "#9FADBF"; font.family: root.monoFontName
                        font.pixelSize: root.px(9); font.letterSpacing: 1
                    }
                    MenuText {
                        anchors.right: parent.right
                        text: "PREVIEW"; color: "#9FADBF"; font.family: root.monoFontName
                        font.pixelSize: root.px(9); font.letterSpacing: 1
                    }
                }
            }
        }

        FocusScope {
            id: inputScope
            anchors.fill: parent
            focus: true
            enabled: root.menuOpen
            Keys.onPressed: event => {
                if (root.page === "bluetooth" && bluetoothPageLoader.item && bluetoothPageLoader.item.physicalKey(event)) {
                    event.accepted = true;
                    return;
                }
                if (root.page === "network" && networkPageLoader.item && networkPageLoader.item.physicalKey(event)) {
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Up) {
                    if (!event.isAutoRepeat) root.input("key_up", 1);
                } else if (event.key === Qt.Key_Down) {
                    if (!event.isAutoRepeat) root.input("key_down", 1);
                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Left) {
                    if (!event.isAutoRepeat) {
                        root.input(event.key === Qt.Key_Left ? "key_left" : "key_right", 1);
                    }
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    if (!event.isAutoRepeat) root.activate();
                } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                    if (!event.isAutoRepeat) root.back();
                } else return;
                event.accepted = true;
            }
            Keys.onReleased: event => {
                if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                    if (!event.isAutoRepeat) root.input(event.key === Qt.Key_Up ? "key_up" : "key_down", 0);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                    if (!event.isAutoRepeat) root.input(event.key === Qt.Key_Left ? "key_left" : "key_right", 0);
                    event.accepted = true;
                }
            }
        }
    }
}
