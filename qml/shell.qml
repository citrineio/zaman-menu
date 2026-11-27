//@ pragma ShellId zaman-menu-dev

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Zaman advanced frontend controls v2
    property string pendingFrontendAction: ""
    property string frontendRequest: ""
    property string frontendRequestId: ""
    property string frontendNotice: ""
    property string frontendLaunchError: ""
    property string frontendLaunchOutput: ""
    property bool frontendResultReceived: false
    readonly property string frontendActionPath: Quickshell.shellPath("../tools/zaman-frontend-actions.py")
    function queueFrontendAction(action) {
        if (["refresh", "restart"].indexOf(action) < 0 || exitBusy || closing || !menuOpen
                || foreground !== "library" || storefrontId.length || pendingFrontendAction.length
                || frontendAction.running || frontendActionStatus.running) return;
        stopRepeat();
        pendingFrontendAction = action;
        frontendNotice = "";
        closeMenu();
    }
    function startFrontendAction() {
        if (!pendingFrontendAction.length || menuOpen || opening || closing || !helperIdle || !bridge.running) return;
        frontendRequest = pendingFrontendAction;
        pendingFrontendAction = "";
        frontendRequestId = "";
        frontendResultReceived = false;
        frontendLaunchError = "";
        frontendLaunchOutput = "";
        exitBusy = true;
        // Supply this request's arguments together, before Process starts.
        frontendAction.exec(["/usr/bin/python3", frontendActionPath, "request", frontendRequest]);
    }
    function receiveFrontendOutput(text, fromStatus) {
        if (!fromStatus) frontendLaunchOutput = text.trim().slice(-1500);
        var lines = text.split("\n");
        for (var index = 0; index < lines.length; ++index)
            receiveFrontendResult(lines[index], fromStatus);
    }
    function receiveFrontendResult(line, fromStatus) {
        var result;
        try { result = JSON.parse(line); } catch (error) { return; }
        if (result.type !== "frontend-action") return;
        if (fromStatus && (!frontendRequestId || result.id !== frontendRequestId)) return;
        if (result.id && frontendRequestId && result.id !== frontendRequestId) return;
        if (["queued", "running", "done", "failed"].indexOf(result.phase) < 0) return;
        frontendResultReceived = true;
        if (result.phase === "queued" || result.phase === "running") {
            frontendRequestId = result.id || "";
            return;
        }
        frontendRequestId = "";
        frontendRequest = "";
        frontendNotice = result.message || "Frontend action failed.";
        exitBusy = false;
        if (result.phase === "failed") openMenu();
    }
    function finishFrontendRequest(code) {
        if (frontendResultReceived) return;
        frontendRequest = "";
        frontendRequestId = "";
        frontendNotice = frontendLaunchError.length ? frontendLaunchError
            : "Frontend helper returned no valid response (exit " + code + ")."
              + (frontendLaunchOutput.length ? " " + frontendLaunchOutput : "");
        exitBusy = false;
        openMenu();
    }
    Process {
        id: frontendAction
        stdout: StdioCollector {
            onStreamFinished: root.receiveFrontendOutput(text, false)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                root.frontendLaunchError = text.trim().slice(-1500);
                if (root.frontendLaunchError.length) console.warn(root.frontendLaunchError);
            }
        }
        onExited: (code, status) => root.finishFrontendRequest(code)
    }
    Process {
        id: frontendActionStatus
        command: ["/usr/bin/python3", root.frontendActionPath, "status"]
        property string errorText: ""
        onStarted: errorText = ""
        stdout: StdioCollector {
            onStreamFinished: root.receiveFrontendOutput(text, true)
        }
        stderr: StdioCollector {
            onStreamFinished: frontendActionStatus.errorText = text.trim().slice(-1500)
        }
        onExited: (code, status) => {
            if (code !== 0 && root.frontendRequestId.length) {
                root.frontendRequestId = "";
                root.frontendRequest = "";
                root.frontendNotice = errorText || "Unable to read frontend action status (exit " + code + ").";
                root.exitBusy = false;
                root.openMenu();
            }
        }
    }
    Timer {
        interval: 400; repeat: true
        running: root.frontendRequestId.length > 0
        onTriggered: if (!frontendActionStatus.running) frontendActionStatus.running = true
    }
    Timer {
        interval: 45000
        running: root.exitBusy && root.frontendRequest.length > 0
        onTriggered: {
            root.frontendRequestId = "";
            root.frontendRequest = "";
            root.frontendNotice = "The frontend action timed out. Check the frontend before trying again."
                + (root.frontendLaunchError.length ? " " + root.frontendLaunchError : "");
            root.exitBusy = false;
            root.openMenu();
        }
    }

    // Zaman selectable resident layouts v10
    property string menuStyle: "drawer"
    property bool motionEnabled: true
    readonly property bool menuMotionActive: motionEnabled && menuOpen && !closing && entryPhase === "settled"
    property real contentReveal: 1
    NumberAnimation {
        id: pageReveal
        target: root; property: "contentReveal"
        from: 0; to: 1; duration: 120; easing.type: Easing.OutCubic
    }
    function revealMenuPage() {
        pageReveal.stop();
        if (!menuMotionActive) { contentReveal = 1; return; }
        contentReveal = 0;
        pageReveal.restart();
    }
    Connections {
        target: root
        function onPageChanged() { historyDismissHold.stop(); root.revealMenuPage(); }
        function onMenuStyleChanged() { root.revealMenuPage(); }
        function onMotionEnabledChanged() {
            if (!root.motionEnabled) { pageReveal.stop(); root.contentReveal = 1; }
        }
        function onMenuOpenChanged() {
            if (!root.menuOpen) { historyDismissHold.stop(); pageReveal.stop(); root.contentReveal = 1; }
        }
    }
    Timer {
        id: historyDismissHold
        interval: 500
        onTriggered: if (root.canOpenSystem && !root.editingKeyboard) root.notificationShortcut(false)
    }
    property bool styleReady: false
    property var savedStyleData: ({})
    property string styleNotice: ""
    property string drawerPowerParent: "settings"
    property string chromeZone: "quick"
    property int quickIndex: 0
    property int quickTile: 2
    property int headerIndex: 0
    property string headerReturnZone: "content"
    property bool emulatorAcceptArmed: false
    property bool quickOutputOpen: false
    property var quickOutputNode: null
    property int railIndex: 0
    property int ribbonIndex: 0
    property var notificationReturn: null
    property var settingsReturn: null
    property bool styleDirect: false
    readonly property bool chromeHome: page === ""
    readonly property var audioController: audioPageLoader.item
    readonly property int notificationUnread: notifications.unread
    readonly property bool shortcutBlocked: !menuOpen || opening || closing || exitBusy || editingKeyboard
        || ["exit","reboot","shutdown","store-close","manage-games","move-games"].indexOf(page) >= 0
        || page === "display" && (displayPage.previewing || displayPage.busy)
        || page === "network" && networkPageLoader.item && networkPageLoader.item.busy
        || page === "bluetooth" && bluetoothPageLoader.item && (bluetoothPageLoader.item.busy || bluetoothPageLoader.item.prompt !== null)
        || (page === "audio" || menuStyle === "drawer" && chromeHome) && audioController && audioController.busy
        || page === "controllers" && controllersPage.bluetoothView === true
        || page === "storage" && (storagePage.busy === true || storagePage.view === "confirm" || storagePage.moving === true)
        || page === "transfer" && (transferPage.busy || transferPage.blocked)
        || page === "scrape" && (scrapePage.busy || ["confirm","cancel","clear"].indexOf(scrapePage.view) >= 0)
        || page === "notifications" && notificationsPage.blocked
    readonly property bool canOpenNotifications: !shortcutBlocked && !(page === "advanced" && advancedPage.confirming)
    readonly property bool canFocusHeader: (canOpenNotifications || canOpenSystem) && headerAtTop()
    readonly property bool canOpenSystem: !shortcutBlocked && !pegasusLibraryTool && !(page === "advanced" && advancedPage.confirming)
    readonly property bool hasHistoryDismiss: page === "transfer" || page === "scrape"
    readonly property var railEntries: [
        {key:"actions",label:storefrontId.length ? (storefrontId === "steam" ? "Steam" : "Dukkan") : foreground === "game" ? "Game" : "Library",icon:foreground === "game" && !storefrontId.length ? "resume" : "library"},
        {key:"audio",label:"Audio",icon:"audio"},
        {key:"controllers",label:"Controllers",icon:"controllers"},
        {key:"network",label:"Network",icon:"network"},
        {key:"bluetooth",label:"Bluetooth",icon:"bluetooth"},
        {key:"display",label:"Display",icon:"display"},
        {key:"settings",label:"More settings",icon:"settings"}
    ]
    readonly property var moreSettingsEntries: settingsEntries.filter(entry =>
        !railEntries.some(tab => tab.key === entry.key))
    readonly property var ribbonActionEntries: mainEntries.filter(entry =>
        storefrontId.length ? entry.key === "store-home" || entry.key === "store-close" : entry.key !== "resume")
    readonly property var ribbonEntries: [
        {key:"resume",label:mainEntries[0].label,icon:"resume"}
    ].concat(ribbonActionEntries.length ? [
        {key:"actions",label:storefrontId.length ? (storefrontId === "steam" ? "Steam" : "Dukkan")
            : foreground === "game" ? "Game" : "Library",icon:foreground === "game" && !storefrontId.length ? "resume" : "library"}
    ] : [], [
        {key:"audio",label:"Audio",icon:"audio"},
        {key:"controllers",label:"Controllers",icon:"controllers"},
        {key:"network",label:"Network",icon:"network"},
        {key:"settings",label:"Settings",icon:"settings"},
        {key:"power",label:"Power",icon:"power"}
    ])
    readonly property var ribbonSettingsEntries: settingsEntries.filter(entry =>
        entry.key !== "actions" && !ribbonEntries.some(tab => tab.key === entry.key))
    readonly property bool canSwitchRibbon: canSwitchTab
        && !(page === "advanced" && advancedPage.confirming)
        && !(page === "network" && networkPageLoader.item && networkPageLoader.item.view === "forget")
    readonly property bool contentHasFocus: chromeZone === "content"
    readonly property bool quickHasExit: foreground === "game" && !storefrontId.length
    readonly property bool quickHasStoreClose: storefrontId.length > 0 && (!storeGame || storefrontId === "steam")
    readonly property bool quickHasStorefronts: foreground === "library" && !storefrontId.length
    readonly property bool quickHasStoreHome: storefrontId.length > 0 && !storeGame
    readonly property var quickTopSecondary: quickHasExit
        ? {key:"exit",label:"Exit Game",icon:"exit"}
        : quickHasStoreClose
        ? {key:"store-close",label:"Exit " + (storefrontId === "steam" ? "Steam" : "Dukkan"),icon:"exit"}
        : quickHasStorefronts
        ? {key:"storefronts",label:"Storefronts",icon:"storefronts"}
        : null
    readonly property bool quickHasTopSecondary: quickTopSecondary !== null
    onQuickHasTopSecondaryChanged: if (!quickHasTopSecondary && quickIndex === 7) quickIndex = 0
    onQuickHasStoreHomeChanged: if (!quickHasStoreHome && quickIndex === 8) quickIndex = 0
    readonly property var quickEntries: [
        mainEntries[0],
        {key:"quick-volume",label:"Volume"},
        {key:"network",label:"Network"},
        {key:"bluetooth",label:"Bluetooth"},
        {key:"quick-output",label:"Sound through"},
        {key:"display",label:"Display"},
        {key:"controllers",label:"Controllers"}
    ].concat(quickHasTopSecondary ? [quickTopSecondary] : [])
     .concat(quickHasStoreHome ? [{key:"store-home",label:"Hide " + (storefrontId === "steam" ? "Steam" : "Dukkan")}] : [])
    readonly property string quickScreenName: overlay.screen ? overlay.screen.name : ""
    readonly property string quickNetwork: liveStatus.networkTitle
    readonly property string quickNetworkDetail: liveStatus.networkDetail
    readonly property string chromeTitle: page === "notifications" ? "Notifications"
        : page === "appearance" ? "Menu style" : page === "actions" ? (storefrontId.length
            ? (storefrontId === "steam" ? "Steam options" : "Dukkan options")
            : foreground === "game" ? "Game options" : "Library options")
        : page === "settings" ? (menuStyle === "split" ? "More settings" : "System settings") : page === "notification-settings" ? "Notification settings"
        : page === "power" ? "Power" : page === "" ? "Quick settings" : pageEntry.label
    MenuLiveStatus { id: liveStatus }
    FileView {
        id: styleFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/zaman/resident-menu.json"
        printErrors: false
        blockLoading: true
        onLoaded: {
            try {
                var data = JSON.parse(text());
                if (data === null || typeof data !== "object" || Array.isArray(data)) throw new Error("Invalid preference");
                root.savedStyleData = data;
                root.motionEnabled = data.motion !== false;
                if (["drawer","split","ribbon"].indexOf(data.style) >= 0) root.menuStyle = data.style;
                else root.styleNotice = "Unknown menu style; using Quick Drawer.";
            } catch (error) { root.styleNotice = "Could not read the saved menu style; using Quick Drawer."; }
            root.styleReady = true;
            if (!root.menuOpen) root.restoreChromeSession();
        }
        onLoadFailed: { root.styleReady = true; }
        onSaved: root.styleNotice = ""
        onSaveFailed: root.styleNotice = "This layout is active, but could not be saved. Check your configuration folder."
    }
    function setMenuStyle(style) {
        if (!styleReady || ["drawer","split","ribbon"].indexOf(style) < 0 || closing || exitBusy) return;
        stopRepeat();
        if (audioController) audioController.stopHorizontal();
        menuStyle = style;
        chromeZone = "content";
        notificationReturn = null;
        settingsReturn = null;
        styleDirect = true;
        styleNotice = "";
        savedStyleData = Object.assign({}, savedStyleData, {version:2,style:style,motion:motionEnabled});
        styleFile.setText(JSON.stringify(savedStyleData, null, 2) + "\n");
        // Keep the picker open so changes can be compared without navigating back.
        page = "appearance"; activeTab = 2; returnPage = "settings";
        if (menuStyle === "split") {
            railIndex = railEntries.findIndex(e => e.key === "settings");
            settingsSelected = moreSettingsEntries.findIndex(e => e.key === "appearance");
        } else if (menuStyle === "ribbon") {
            ribbonIndex = ribbonEntries.findIndex(e => e.key === "settings");
            settingsSelected = ribbonSettingsEntries.findIndex(e => e.key === "appearance");
        }
    }
    function chromeStatus(key) {
        if (key === "network") return liveStatus.network;
        if (key === "bluetooth") return liveStatus.bluetooth;
        if (key === "controllers") return controllerCount ? controllerCount + " ready" : "No controllers";
        if (key === "audio" || key === "quick-volume") return audioController && audioController.hasLevel ? (audioController.muted ? "Muted · " : "") + audioController.percent + "%" : "Unavailable";
        if (key === "quick-output") return audioController ? (audioController.outputLabel(audioController.current()) || "No output") : "Unavailable";
        if (key === "appearance") return menuStyle === "drawer" ? "Quick Drawer" : menuStyle === "split" ? "Split Tabs" : "Control Ribbon";
        if (key === "storage") return "Drives and game storage";
        return "";
    }
    function restoreChromeSession() {
        notificationReturn = null;
        settingsReturn = null;
        headerIndex = 0;
        styleDirect = false;
        if (menuStyle === "split") {
            showStyleCategory(railEntries[railIndex].key, false);
            chromeZone = "rail";
        } else {
            activeTab = 0; page = ""; returnPage = "";
            if (menuStyle === "ribbon") ribbonIndex = 0;
            quickIndex = 0; quickTile = 2; closeQuickOutput();
            chromeZone = menuStyle === "ribbon" ? "ribbon" : "quick";
        }
    }
    function showStyleCategory(key, enter) {
        stopRepeat();
        if (audioController) audioController.stopHorizontal();
        if (key === "resume") { closeMenu(); return; }
        if (key === "notifications") { openNotificationCenter(); return; }
        if (key === "quick-volume") { if (audioController && audioController.hasLevel) { audioController.select(1); audioController.activate(); } return; }
        if (key === "quick-output") { openQuickOutput(); return; }
        var entry = settingsEntries.concat(mainEntries).concat([{key:"actions",label:foreground === "game" ? "Game options" : "Library options"},{key:"settings",label:"System settings"}]).find(e => e.key === key);
        if (!entry || entry.disabled) return;
        if ((key === "exit" || key === "store-close") && menuStyle === "drawer" && chromeHome) {
            styleDirect = false;
            returnPage = "";
            pageEntry = entry;
            exitNotice = "";
            chromeZone = "content";
            page = key;
            return;
        }
        if (key === "storefronts" && menuStyle === "drawer" && chromeHome) {
            styleDirect = true;
            returnPage = "";
            pageEntry = entry;
            chromeZone = "content";
            page = "storefronts";
            select(0);
            requestFocusSettle();
            return;
        }
        if (key === "store-home" && menuStyle === "drawer" && chromeHome) {
            queueStoreAction("home", storefrontId, storeGeneration);
            return;
        }
        if (["emulator-menu","store-home","store-close","exit"].indexOf(key) >= 0) {
            page = "actions"; selected = entries.findIndex(e => e.key === key);
            activate(); return;
        }
        styleDirect = true;
        activeTab = key === "actions" ? 0 : 2;
        returnPage = "settings";
        pageEntry = entry; page = key; selected = 0;
        if (key === "bluetooth") bluetoothLoaded = true;
        chromeZone = enter === false ? "rail" : "content";
    }
    function openRibbonTab(index, activateResume) {
        if (!canSwitchRibbon || !ribbonEntries[index]) return;
        emulatorAcceptArmed = false;
        settingsReturn = null;
        notificationReturn = null;
        ribbonIndex = index;
        var key = ribbonEntries[index].key;
        if (key === "resume") {
            if (activateResume) closeMenu();
            else collapseRibbon();
            return;
        }
        showStyleCategory(key, true);
        if (listPage) requestFocusSettle();
        if (key === "controllers") controllersPage.select(0);
        else if (key === "audio" && audioController) {
            audioController.select(0);
            audioController.requestFocusSettle();
        } else if (key === "network" && networkPageLoader.item) {
            networkPageLoader.item.openRibbonRoot();
        }
    }
    function collapseRibbon() {
        stopRepeat();
        if (audioController) audioController.stopHorizontal();
        emulatorAcceptArmed = false;
        styleDirect = false;
        returnPage = "";
        page = "";
        chromeZone = "ribbon";
    }
    function headerAtTop() {
        if (chromeZone === "header") return false;
        if (chromeHome) return menuStyle === "drawer" ? (quickIndex === 0 || quickIndex === 7) && !quickOutputOpen : menuStyle === "ribbon";
        if (chromeZone === "rail") return railIndex === 0;
        if (chromeZone === "ribbon") return false;
        if (listPage) return selected === 0;
        if (page === "notifications") return !notificationsPage.records.length || notificationsPage.records[0].id === notificationsPage.selectedId;
        if (page === "storage") return !storagePage.rows.length || storagePage.rows[0].id === storagePage.selectedId;
        if (page === "transfer") return !transferPage.rows.length || transferPage.rows[0].id === transferPage.selectedId;

        var pane = page === "audio" ? audioPageLoader.item
            : page === "network" ? networkPageLoader.item
            : page === "bluetooth" ? bluetoothPageLoader.item
            : page === "display" ? displayPage
            : page === "controllers" ? controllersPage
            : page === "appearance" ? appearancePage
            : page === "advanced" ? advancedPage
            : page === "scrape" ? scrapePage : null;
        return !pane || pane.selected <= 0;
    }
    function focusHeader(index) {
        if (!(index === 0 ? canOpenNotifications : canOpenSystem)) return false;
        stopRepeat();
        stopQuickVolumeRepeat();
        if (chromeZone !== "header") headerReturnZone = chromeZone;
        headerIndex = index;
        chromeZone = "header";
        return true;
    }
    function leaveHeader() {
        stopRepeat();
        chromeZone = headerReturnZone;
    }
    function activateHeader() {
        if (headerIndex === 0 && canOpenNotifications) {
            if (page === "notifications" && !notificationReturn) leaveHeader();
            openNotificationCenter();
        } else if (headerIndex === 1 && canOpenSystem) {
            if (page === "settings") {
                leaveHeader();
                chromeZone = "content";
            } else openSystemSettings();
        }
    }
    function clickHeader(index) {
        if (focusHeader(index)) activateHeader();
    }
    function emulatorMenuRowFocused() {
        return page === "actions" && chromeZone === "content"
            && !!entries[selected] && entries[selected].key === "emulator-menu";
    }
    function chromeMove(direction) {
        if (chromeZone === "header") {
            if (direction > 0) leaveHeader();
            return true;
        }
        if (direction < 0 && canFocusHeader) {
            if (!focusHeader(headerIndex)) focusHeader(1 - headerIndex);
            return true;
        }
        if (menuStyle === "drawer" && chromeHome) {
            if (audioController && audioController.busy) return true;
            if (quickOutputOpen) {
                var outputs = audioController.outputs;
                var at = outputs.indexOf(quickOutputNode);
                var next = at < 0 ? 0 : Math.max(0, Math.min(outputs.length - 1, at + direction));
                quickOutputNode = outputs[next] || null;
                residentChrome.ensureQuick(quickIndex);
                return true;
            }
            stopQuickVolumeRepeat();
            var nextIndex;
            if (quickIndex === 0 || quickIndex === 7) nextIndex = direction > 0 ? (quickHasStoreHome ? 8 : 1) : 0;
            else if (quickIndex === 8) nextIndex = direction < 0 ? 0 : 1;
            else if (quickIndex === 1 && direction < 0) nextIndex = quickHasStoreHome ? 8 : 0;
            // The two tiles occupy one vertical stop.
            else if (quickIndex === 2 || quickIndex === 3) nextIndex = direction < 0 ? 1 : 4;
            else {
                nextIndex = Math.max(0, Math.min(6, quickIndex + direction));
                if (nextIndex === 2 || nextIndex === 3) nextIndex = quickTile;
            }
            focusQuick(nextIndex);
            return true;
        }
        if (menuStyle === "split" && chromeZone === "rail") {
            railIndex = Math.max(0, Math.min(railEntries.length - 1, railIndex + direction));
            showStyleCategory(railEntries[railIndex].key, false);
            residentChrome.ensureRail(railIndex); return true;
        }
        if (menuStyle === "ribbon" && chromeZone === "ribbon") return true;
        return false;
    }
    function chromeHorizontal(event, value, wasDown) {
        var left = event === "ui_left" || event === "key_left";
        var direction = left ? -1 : 1;
        if (chromeZone === "header") {
            if (value > 0.5 && !wasDown) focusHeader(left ? 0 : 1);
            return true;
        }
        if (menuStyle === "drawer" && chromeHome) {
            if (quickEntries[quickIndex].key === "quick-volume" && audioController) {
                audioController.select(0); audioController.horizontal(event,value);
            } else if (value > 0.5 && !wasDown) {
                if (quickIndex === 2 || quickIndex === 3) focusQuick(left ? 2 : 3);
                else if (quickHasTopSecondary && (quickIndex === 0 || quickIndex === 7)) focusQuick(left ? 0 : 7);
            }
            return true;
        }
        if (menuStyle === "split" && chromeZone === "rail") {
            if (value > 0.5 && !wasDown && !left) chromeZone = "content";
            return true;
        }
        if (menuStyle === "ribbon" && chromeZone === "ribbon") {
            if (value > 0.5 && !wasDown) ribbonIndex = Math.max(0, Math.min(ribbonEntries.length - 1, ribbonIndex + direction));
            return true;
        }
        return false;
    }
    function chromeActivate() {
        if (chromeZone === "header") { activateHeader(); return true; }
        if (menuStyle === "drawer" && chromeHome) {
            if (audioController && audioController.busy) return true;
            if (quickOutputOpen) applyQuickOutput(quickOutputNode);
            else {
                var entry = quickEntries[quickIndex];
                if (entry && !entry.disabled) showStyleCategory(entry.key, true);
            }
            return true;
        }
        if (menuStyle === "split" && chromeZone === "rail") { chromeZone = "content"; return true; }
        if (menuStyle === "ribbon" && chromeZone === "ribbon") { openRibbonTab(ribbonIndex, true); return true; }
        return false;
    }
    function chromeBack() {
        if (menuStyle === "drawer" && returnPage === ""
                && (page === "exit" || page === "store-close" || (page === "storefronts" && styleDirect))) {
            styleDirect = false;
            page = "";
            focusQuick(quickHasTopSecondary ? 7 : 0);
            return true;
        }
        if (page === "settings" && settingsReturn) {
            var saved = settingsReturn;
            settingsReturn = null;
            notificationReturn = saved.inbox;
            restoreChromeLocation(saved);
            return true;
        }
        if (menuStyle === "drawer" && chromeHome) {
            if (audioController && audioController.busy) return true;
            if (quickOutputOpen) { closeQuickOutput(); residentChrome.ensureQuick(quickIndex); return true; }
        }
        if (menuStyle === "split" && chromeZone === "rail") { closeMenu(); return true; }
        if (menuStyle === "ribbon") {
            if (chromeZone === "ribbon") { closeMenu(); return true; }
            if (page === "storefronts") { page = "actions"; select(mainSelected); return true; }
            if (page === "appearance") {
                page = "settings";
                chromeZone = "content";
                select(settingsSelected);
                return true;
            }
            if (page === "actions" || page === "settings" || page === "power") {
                collapseRibbon(); return true;
            }
        }
        if (page === "actions" && !styleDirect && returnPage === "settings") {
            page = "settings"; select(settingsSelected); return true;
        }
        if (menuStyle === "drawer" && !styleDirect) {
            if (page === "storefronts") { page = "actions"; select(mainSelected); return true; }
            if (page === "power") {
                page = drawerPowerParent === "actions" ? "actions" : "settings";
                select(page === "actions" ? mainSelected : settingsSelected);
                return true;
            }
        }
        if (page === "appearance" && menuStyle === "split") {
            page = "settings"; chromeZone = "content";
            select(settingsSelected); return true;
        }
        if (page === "appearance" && !styleDirect) { page = "settings"; chromeZone = "content"; return true; }
        if (page === "settings" || page === "actions" || page === "appearance" || page === "power" || page === "storefronts") {
            if (menuStyle === "split") chromeZone = "rail";
            else { page = ""; chromeZone = menuStyle === "ribbon" ? "ribbon" : "quick"; }
            return true;
        }
        return false;
    }
    function captureChromeLocation() {
        return {page:page,tab:activeTab,selected:selected,returnPage:returnPage,entry:pageEntry,
            zone:chromeZone,direct:styleDirect,quick:quickIndex,rail:railIndex,ribbon:ribbonIndex,
            header:headerIndex,headerOrigin:headerReturnZone,
            main:mainSelected,settings:settingsSelected,power:powerSelected,
            scroll:listPage ? menuList.contentY : 0,
            audio:audioController ? audioController.location() : null};
    }
    function openSystemSettings() {
        if (!canOpenSystem || page === "settings") return;
        stopQuickVolumeRepeat();
        if (!settingsReturn) {
            settingsReturn = captureChromeLocation();
            settingsReturn.inbox = notificationReturn;
        }
        notificationReturn = null;
        closeQuickOutput();
        if (menuStyle === "split") railIndex = railEntries.findIndex(entry => entry.key === "settings");
        var fromGameDrawer = menuStyle === "drawer" && chromeHome && (quickHasExit || quickHasStoreClose);
        if (menuStyle === "ribbon") ribbonIndex = ribbonEntries.findIndex(entry => entry.key === "settings");
        showStyleCategory("settings", true);
        select(fromGameDrawer || menuStyle === "ribbon" ? 0 : settingsSelected);
        if (menuStyle === "ribbon") requestFocusSettle();
    }
    function openNotificationCenter() {
        if (!canOpenNotifications) return;
        stopRepeat();
        if (audioController) audioController.stopHorizontal();
        if (page === "notifications") {
            if (notificationReturn) restoreNotificationLocation();
            else back();
            return;
        }
        notificationReturn = captureChromeLocation();
        if (chromeHome && menuStyle === "drawer") closeQuickOutput();
        page = "notifications"; activeTab = 1; chromeZone = "content";
    }
    function restoreNotificationLocation() {
        var saved = notificationReturn;
        if (!saved) return;
        notificationReturn = null;
        restoreChromeLocation(saved);
    }
    function restoreChromeLocation(saved) {
        stopRepeat();
        page = saved.page; activeTab = saved.tab; selected = saved.selected;
        returnPage = saved.returnPage; pageEntry = saved.entry; chromeZone = saved.zone; styleDirect = saved.direct;
        quickIndex = saved.quick; railIndex = saved.rail; ribbonIndex = saved.ribbon;
        headerIndex = saved.header; headerReturnZone = saved.headerOrigin;
        mainSelected = saved.main; settingsSelected = saved.settings; powerSelected = saved.power;
        if (audioController && saved.audio) audioController.restoreLocation(saved.audio);
        var revision = ++navigationRevision, generation = menuGeneration;
        Qt.callLater(() => {
            if (!menuOpen || closing || menuGeneration !== generation || navigationRevision !== revision || page !== saved.page) return;
            if (listPage) { menuList.forceLayout(); menuList.contentY = saved.scroll; }
            residentChrome.ensureQuick(quickIndex); residentChrome.ensureRail(railIndex);
        });
    }
    function stopQuickVolumeRepeat() {
        if (!audioController) return;
        audioController.stopHorizontal();
        audioController.leftDown = false;
        audioController.rightDown = false;
    }
    function focusQuick(index) {
        if (index !== quickIndex) stopQuickVolumeRepeat();
        quickIndex = Math.max(0, Math.min(quickEntries.length - 1, index));
        if (quickIndex === 2 || quickIndex === 3) quickTile = quickIndex;
        chromeZone = "quick";
        residentChrome.ensureQuick(quickIndex);
    }
    function clickQuick(index) {
        if (shortcutBlocked) return;
        var toggleClosed = index === 4 && quickOutputOpen;
        closeQuickOutput();
        focusQuick(index);
        if (toggleClosed) return;
        chromeActivate();
    }
    function openQuickOutput() {
        if (!audioController || audioController.busy || !audioController.outputs.length) return;
        var outputs = audioController.outputs;
        var current = audioController.current();
        quickOutputNode = outputs.indexOf(current) >= 0 ? current : outputs[0];
        quickOutputOpen = true;
        residentChrome.ensureQuick(quickIndex);
    }
    function closeQuickOutput() {
        quickOutputOpen = false;
        quickOutputNode = null;
    }
    function applyQuickOutput(node) {
        if (!quickOutputOpen || !audioController || audioController.busy
                || !node || audioController.outputs.indexOf(node) < 0) return;
        audioController.select(2);
        audioController.candidateNode = node;
        audioController.activate();
        closeQuickOutput();
        residentChrome.ensureQuick(quickIndex);
    }
    function quickDisplayLabel(value, screenName) {
        var outputs;
        try { outputs = JSON.parse(value); } catch (error) { return "Unavailable"; }
        if (!Array.isArray(outputs)) return "Unavailable";
        var active = outputs.filter(output => output.active && output.current_mode);
        var output = active.find(output => output.name === screenName) || active[0];
        if (!output) return "Unavailable";
        var mode = output.current_mode;
        var resolution = mode.width === 1920 && mode.height === 1080 ? "1080p"
            : mode.width === 1280 && mode.height === 720 ? "720p"
            : mode.width === 2560 && mode.height === 1440 ? "1440p"
            : mode.width === 3840 && mode.height === 2160 ? "4K"
            : mode.width + " × " + mode.height;
        return resolution + " · " + Number((mode.refresh / 1000).toFixed(2)) + " Hz";
    }
    function quickSetVolume(value) {
        if (!audioController || !audioController.hasLevel || audioController.busy) return;
        var sink = audioController.sink;
        sink.audio.volume = Math.max(0, Math.min(100, Math.round(value))) / 100;
    }
    function setMenuMotion(enabled) {
        if (!styleReady || closing || exitBusy) return;
        motionEnabled = enabled === true;
        savedStyleData = Object.assign({}, savedStyleData, {version:2,style:menuStyle,motion:motionEnabled});
        styleFile.setText(JSON.stringify(savedStyleData, null, 2) + "\n");
    }

    property bool menuOpen: false
    property bool opening: false
    property bool ready: false
    property bool closing: false
    property var closeOrigin: ({page:"",tab:0})
    property bool helperIdle: false
    property double openStartedMs: 0
    property double lastReadyMs: -1
    property double lastVisibleMs: -1
    property double firstFrameMs: -1
    property double slideFinishedMs: -1
    property string entryPhase: "hidden"
    readonly property string menuInstance: Date.now().toString()
    property int menuGeneration: 0
    property string sessionAction: "exit-game"
    property bool emulatorMenuAvailable: false
    property bool pendingEmulatorMenu: false
    property bool emulatorMenuResultReceived: false
    property string emulatorMenuNotice: ""
    property bool reopenAfterEmulatorHandoffFailure: false
    property bool selectEmulatorMenuOnReturn: false

    function emulatorMenuFailed(reason) {
        pendingEmulatorMenu = false;
        emulatorMenuNotice = reason.replace(/^GDBus.Error:[^:]+:\s*/, "");
        selectEmulatorMenuOnReturn = true;
    }

    property bool exitBusy: false
    property bool exitResultReceived: false
    property string exitNotice: ""
    readonly property string sessionActionPath: Quickshell.env("ZAMAN_MENU_SESSION_BRIDGE") || ""
    property string foreground: "library"
    property string storefrontId: ""
    property string storeGeneration: "0"
    property bool storeGame: false
    property var pendingStoreAction: null
    property var storeRequest: ({action:"", id:"", generation:"0"})
    property string storeNotice: ""
    property bool storeResultReceived: false
    readonly property string transferClient: Quickshell.env("ZAMAN_TRANSFER_CLIENT") || ""
    property var transferSnapshot: ({jobs:[],systems:[],enabled:false})
    property bool transferAvailable: false
    property string transferError: ""
    property var transferRequest: ({action:"snapshot"})
    property var scrapeReturnLocation: ({page:"",returnPage:"",entry:({label:"",key:"",detail:""})})
    function openTransfers() {
        stopRepeat();
        returnPage = page;
        pageEntry = ({label:"Transfer Games",key:"transfer",detail:"Receive and import games"});
        page = "transfer";
    }
    function openScraping(importId, system, jobId) {
        stopRepeat();
        scrapeReturnLocation=({page:page,returnPage:returnPage,entry:pageEntry});
        if (page === "") mainSelected=selected;
        pageEntry=({label:"Artwork & Game Info",key:"scrape",detail:"Covers, screenshots and descriptions"});
        scrapePage.open(importId || "",system || "",jobId || "");
        page="scrape";
    }
    function transferResult(line) {
        try {
            var result = JSON.parse(line);
            if (result.type === "transfer") {
                transferSnapshot = result;
                transferAvailable = true;
                transferError = "";
            } else if (result.type === "error") transferError = result.error;
        } catch (error) { transferError = "Invalid receiver response"; }
    }
    Process {
        id: transferPoll
        property bool received: false
        command:["/usr/bin/python3",root.transferClient,"snapshot"]
        onStarted: received = false
        stdout: SplitParser { onRead: line => { transferPoll.received = true; root.transferResult(line); } }
        onExited: (code, status) => { if (code !== 0 || !received) root.transferAvailable = false; }
    }
    Process {
        id: transferAction
        command:["/usr/bin/python3",root.transferClient,"request"]
        stdinEnabled:true
        onStarted:write(JSON.stringify(root.transferRequest)+"\n")
        stdout: SplitParser { onRead: line => root.transferResult(line) }
    }
    Timer {
        interval:1000; repeat:true; triggeredOnStart:true
        running:root.menuOpen && root.transferClient.length > 0
        onTriggered: if (!transferPoll.running && !transferAction.running) transferPoll.running = true
    }
    property int controllerCount: 0
    property bool displaySupported: false
    property var controllerDevices: []
    property string controllerWarning: ""
    property int activeTab: 0
    property var tabLocations: [null, null, null]
    property int navigationRevision: 0
    property bool audioLoaded: false
    property bool networkLoaded: false
    readonly property bool canSwitchTab: !shortcutBlocked && !pegasusLibraryTool
    readonly property bool menuPresentsToasts: menuOpen && notifications.available && notifications.outputPresent
        && overlay.screen !== null && overlay.screen.name === notifications.outputName
    readonly property var notificationSettings: [
        {key:"dnd", preference:"dnd", label:"Do Not Disturb", detail:notifications.preferences.dnd ? "On · Critical alerts remain visible" : "Off · Show routine popups"},
        {key:"steam-startup", preference:"steamStartup", label:"Steam startup notice", detail:notifications.preferences.steamStartup ? "On · Notice while starting Steam" : "Off · Startup notice disabled"},
        {key:"steam-reminder", preference:"steamReminder", label:"Steam menu shortcut reminder", detail:notifications.preferences.steamReminder ? "On · Start + Select reminder when Steam opens" : "Off · Reminder disabled"},
        {key:"background-progress", preference:"backgroundProgress", label:"Background progress indicator", detail:notifications.preferences.backgroundProgress !== false ? "On · Circular indicator during background work" : "Off · Background indicator hidden"}
    ]
    NotificationClient {
        id: notifications
        presentingMenu: root.menuPresentsToasts
        viewing: root.menuOpen && root.activeTab === 1
    }
    property int selected: 0
    property string page: ""
    property bool bluetoothLoaded: false
    property int mainSelected: 0
    property int settingsSelected: 0
    property int powerSelected: 0
    property string returnPage: ""
    property var pageEntry: ({ label: "", key: "", detail: "" })
    readonly property bool listPage: page === "actions" || page === "" || page === "settings" || page === "power" || page === "storefronts" || page === "notification-settings"
    readonly property bool navigationPage: page === "appearance" || page === "advanced" || page === "manage-games" || page === "storage" || page === "scrape" || page === "transfer" || page === "notifications" || listPage || page === "audio" || page === "controllers" || page === "network" || page === "bluetooth" || page === "display" || page === "exit" || page === "reboot" || page === "shutdown" || page === "store-close"
    property int heldDirection: 0
    property int heldHorizontal: 0
    property bool keyboardCycleHeld: false
    property var pressed: ({})
    readonly property bool editingKeyboard: page === "network" && networkPageLoader.item && networkPageLoader.item.editingPassword
        || page === "bluetooth" && bluetoothPageLoader.item && bluetoothPageLoader.item.editingCode
        || page === "controllers" && controllersPage.editingCode
        || page === "scrape" && scrapePage.editingText
    readonly property real uiScale: Math.max(0.65, Math.min(1.4, overlay.height / 1080))
    readonly property string helperPath: Quickshell.env("ZAMAN_MENU_DEV_INPUT") || ""
    readonly property string uiFontName: "Sans Serif"
    property string clockText: Qt.formatDateTime(new Date(), "h:mm AP")
    readonly property string monoFontName: monoFont.status === FontLoader.Ready ? monoFont.name : "Monospace"
    readonly property var mainEntries: [
        { label: storefrontId.length ? "Resume " + (storefrontId === "steam" ? "Steam" : "Dukkan") : foreground === "game" ? "Resume" : "Return to library", key: "resume", detail: storefrontId.length ? "Return to the active application" : foreground === "game" ? "Return to your game" : "Continue browsing your games" },
    ].concat(foreground === "game" && !storefrontId.length && emulatorMenuAvailable ? [
        { label: "Emulator Menu", key: "emulator-menu", detail: "Open the emulator's native menu and save controls" },
    ] : []).concat(foreground === "library" ? [
        { label: "Storefronts", key: "storefronts", detail: "Dukkan and Steam" },
        { label: "Manage Games", key: "manage-games", detail: "Delete ROMs or uninstall storefront games", disabled: storefrontId.length > 0 || storeGame }
    ] : []).concat(storefrontId.length && !storeGame ? [
        { label: "Return to library", key: "store-home", detail: "Keep the storefront running in the background" }
    ] : []).concat(storefrontId.length && (!storeGame || storefrontId === "steam") ? [
        { label: "Close " + (storefrontId === "steam" ? "Steam" : "Dukkan"), key: "store-close", detail: storeGame ? "Close Steam and its running game" : "Close the storefront and return to library" }
    ] : []).concat(foreground === "game" && !storefrontId.length ? [
        { label: "Exit Game", key: "exit", detail: "Close the current game" }
    ] : [])
    readonly property var storefrontEntries: [
        { label: "Dukkan", key: "store-dukkan", detail: "Browse and install games" },
        { label: "Steam", key: "store-steam", detail: "Open your Steam library and store" }
    ]
    readonly property var settingsEntries: (foreground === "game" || storefrontId.length ? [
        {label:storefrontId.length ? (storefrontId === "steam" ? "Steam options" : "Dukkan options") : "Game options", key:"actions", detail:quickHasExit ? "Resume, exit and emulator controls" : "Resume, hide or close the active storefront"}
    ] : []).concat([
        { label: "Controllers", key: "controllers", detail: "Pair controllers, manage connections and saved pairings" },
        { label: "Audio", key: "audio", detail: "Volume and audio output" },
        { label: "Display", key: "display", detail: "Resolution and refresh rate" },
        { label: "Network", key: "network", detail: "Connections and saved networks" },
        { label: "Bluetooth", key: "bluetooth", detail: "Headphones, keyboards and other accessories" },
        { label: "Notifications", key: "notification-settings", detail: "Background progress and popup preferences" },
        { label: "Appearance", key: "appearance", detail: "Theme, colors and interface style" },
        { label: "Storage", key: "storage", detail: "Devices, capacity and available space" },
    ], foreground !== "game" && !storefrontId.length ? [
        {label:"Library options", key:"actions", detail:"Resume, storefronts and game actions"}
    ] : [], [
        { label: "Advanced", key: "advanced", detail: "Frontend restart and theme refresh" },
        {label:"Power",key:"power",detail:"Shutdown and restart"}
    ])
    readonly property var powerEntries: [
        { label: "Shutdown", key: "shutdown", detail: "Turn off your device" },
        { label: "Reboot", key: "reboot", detail: "Restart Zaman OS" },
        { label: "Sleep", key: "sleep", detail: "Coming soon", disabled: true }
    ]
    readonly property var entries: page === "actions" ? (menuStyle === "ribbon" ? ribbonActionEntries : mainEntries) : page === "notification-settings" ? notificationSettings : page === "settings" ? (menuStyle === "split" ? moreSettingsEntries : menuStyle === "ribbon" ? ribbonSettingsEntries : settingsEntries) : page === "power" ? powerEntries : page === "storefronts" ? storefrontEntries : mainEntries

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
        horizontalDelay.stop();
        horizontalStep.stop();
        heldDirection = 0;
        heldHorizontal = 0;
    }
    function hold(direction, immediate) {
        if (closing) return;
        stopRepeat();
        if (direction === 0 || !menuOpen || !navigationPage) return;
        heldDirection = direction;
        if (immediate) move(direction);
        repeatDelay.restart();
    }
    function directionPressed(direction) {
        return direction < 0 ? (pressed.ui_up || pressed.key_up) : (pressed.ui_down || pressed.key_down);
    }
    function horizontalPressed(direction) {
        return direction < 0 ? (pressed.ui_left || pressed.key_left) : (pressed.ui_right || pressed.key_right);
    }
    function moveHorizontal(direction) {
        if (!editingKeyboard) return;
        if (page === "scrape") scrapePage.horizontal(direction);
        else if (page === "network") networkPageLoader.item.horizontal(direction);
        else if (page === "controllers") controllersPage.horizontal(direction);
        else bluetoothPageLoader.item.horizontal(direction);
    }
    function holdHorizontal(direction, immediate) {
        if (closing) return;
        stopRepeat();
        if (direction === 0 || !menuOpen || !editingKeyboard) return;
        heldHorizontal = direction;
        if (immediate) moveHorizontal(direction);
        horizontalDelay.restart();
    }

    Component.onCompleted: {
        styleFile.text(); // Read the tiny preference before the first window is shown.
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

    property var pegasusManagement: null
    property var pegasusStorageMove: null
    property string storageHandoffToken: ""
    property string storageHandoffStatus: ""
    property string pegasusLibraryTool: ""

    IpcHandler {
        target: "menu"
        function manageGame(payload: string): string {
            if (root.menuOpen || root.opening || root.closing || root.exitBusy) return "busy";
            var request;
            try { request = JSON.parse(payload); } catch (error) { return "invalid"; }
            if (!request || (["dukkan", "steam", "transfer", "scrape"].indexOf(request.kind) < 0
                    && !(request.kind === "rom" && Array.isArray(request.games) && request.games.length)))
                return "invalid";
            var status = root.openMenu();
            if (status === "opening") root.pegasusManagement = request;
            return status;
        }
        function storageMove(payload: string): string {
            if (root.menuOpen || root.opening || root.closing || root.exitBusy) return "busy";
            var request;
            try { request = JSON.parse(payload); } catch (error) { return "invalid"; }
            if (!request || !Array.isArray(request.paths) || !request.paths.length || request.paths.length > 64
                    || request.paths.some(p => typeof p !== "string" || p.charAt(0) !== "/")) return "invalid";
            if (request.action && request.action !== "move" && request.action !== "delete") return "invalid";
            if (request.token !== undefined && (typeof request.token !== "string" || !/^[0-9a-f]{24}$/.test(request.token))) return "invalid";
            var result = root.openMenu();
            if (result === "opening") {
                root.pegasusStorageMove = request;
                root.storageHandoffToken = request.token || "";
                root.storageHandoffStatus = "opening";
            }
            return result;
        }
        function storageMoveStatus(token: string): string {
            return token && token === root.storageHandoffToken ? root.storageHandoffStatus : "unknown";
        }
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
            readyMs:root.lastReadyMs, visibleMs:root.lastVisibleMs, firstFrameMs:root.firstFrameMs,
            slideFinishedMs:root.slideFinishedMs, entryPhase:root.entryPhase,
            entryProgress:panel.entryProgress, panelX:panel.x, panelWidth:panel.width,
            sessionKey:root.menuInstance + ":" + root.menuGeneration, generation:root.menuGeneration, inputOwned:root.menuOpen || root.opening || root.closing || !root.helperIdle}); }
    }

    function rememberTab() {
        tabLocations[activeTab] = {
            page:page, selected:selected, returnPage:returnPage, pageEntry:pageEntry,
            mainSelected:mainSelected, settingsSelected:settingsSelected, powerSelected:powerSelected,
            scroll:listPage ? menuList.contentY : 0,
            audio:page === "audio" && audioPageLoader.item ? audioPageLoader.item.location() : null
        };
    }
    function restoreTab(index) {
        activeTab = index;
        var location = tabLocations[index];
        mainSelected = location ? location.mainSelected : 0;
        settingsSelected = location ? location.settingsSelected : 0;
        powerSelected = location ? location.powerSelected : 0;
        returnPage = location ? location.returnPage : "";
        pageEntry = location ? location.pageEntry : ({label:"", key:"", detail:""});
        page = location ? location.page : index === 0 ? "" : index === 1 ? "notifications" : "settings";
        selected = location ? location.selected : 0;
        if (listPage) selected = Math.max(0, Math.min(entries.length - 1, selected));
        if (page === "audio" && audioPageLoader.item && location && location.audio)
            audioPageLoader.item.restoreLocation(location.audio);
        var revision = ++navigationRevision;
        var targetPage = page;
        var generation = menuGeneration;
        Qt.callLater(() => {
            if (menuOpen && activeTab === index && page === targetPage && navigationRevision === revision && menuGeneration === generation && listPage) {
                menuList.forceLayout();
                menuList.contentY = location ? location.scroll : 0;
            }
        });
    }
    function switchTab(direction) {
        if (menuStyle === "ribbon") {
            if (direction) openRibbonTab((ribbonIndex + direction + ribbonEntries.length) % ribbonEntries.length, false);
            return;
        }
        if (!canSwitchTab || !direction || page === "notifications" || page === "settings" && settingsReturn) return;
        if (chromeZone === "header") leaveHeader();
        stopRepeat();
        if (audioController) audioController.stopHorizontal();
        if (menuStyle === "split") {
            railIndex = (railIndex + direction + railEntries.length) % railEntries.length;
            showStyleCategory(railEntries[railIndex].key, false);
            residentChrome.ensureRail(railIndex); return;
        }
        if (chromeHome) { closeQuickOutput(); showStyleCategory("settings", true); }
        else { page = ""; chromeZone = "quick"; }
        return;
    }
    function legacySwitchTab(direction) {
        if (!canSwitchTab || direction === 0 || manageGames.removing || (page === "manage-games" && manageGames.direct)) return;
        stopRepeat();
        if (audioPageLoader.item) audioPageLoader.item.stopHorizontal();
        keyboardCycleHeld = false;
        rememberTab();
        restoreTab((activeTab + direction % 3 + 3) % 3);
    }
    function faceShortcut(north) {
        if (page === "notifications") {
            if (!shortcutBlocked) notificationShortcut(north);
        } else if (north) openNotificationCenter();
        else openSystemSettings();
    }
    function notificationShortcut(clear) {
        if (!menuOpen || closing || exitBusy || editingKeyboard || (["transfer","scrape"].indexOf(page)<0 && !notifications.available)) return;
        stopRepeat();
        if (page === "scrape") {
            if (clear) scrapePage.clear();else scrapePage.dismiss();
        } else if (page === "transfer") {
            if (clear) transferPage.clear();
            else transferPage.dismiss();
        } else if (page === "notifications") {
            if (clear) notificationsPage.clear();
            else notificationsPage.dismiss();
        } else if (!clear && notifications.popups.length) {
            notifications.send({action:"dismiss-visible"});
        }
    }
    function select(index) {
        selected = (index + entries.length) % entries.length;
        menuList.positionViewAtIndex(selected, ListView.Contain);
    }
    function move(direction) {
        if (closing || !menuOpen) return;
        if (chromeMove(direction)) return;
        if (page === "appearance") { appearancePage.move(direction); return; }
        if (menuOpen && page === "advanced") { advancedPage.move(direction); return; }
        if (closing) return;
        if (menuOpen && page === "storage") { storagePage.move(direction); return; }
        if (menuOpen && page === "manage-games") { manageGames.move(direction); return; }
        if (menuOpen && page === "scrape") { scrapePage.move(direction); return; }
        if (menuOpen && page === "transfer") { transferPage.move(direction); return; }
        if (menuOpen && page === "notifications") { notificationsPage.move(direction); return; }
        if (menuOpen && (page === "exit" || page === "reboot" || page === "shutdown" || page === "store-close")) { exitPage.move(direction); return; }
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
        if (!menuOpen || closing || exitBusy) return;
        if (chromeActivate()) return;
        if (page === "appearance") { appearancePage.activate(); return; }
        if (!menuOpen || closing || exitBusy) return;
        if (page === "advanced") { stopRepeat(); advancedPage.activate(); return; }
        if (page === "storage") { stopRepeat(); storagePage.activate(); return; }
        if (page === "manage-games") { stopRepeat(); manageGames.activate(); return; }
        if (page === "scrape") { stopRepeat();scrapePage.activate();return; }
        if (page === "transfer") { stopRepeat(); transferPage.activate(); return; }
        if (page === "notifications") { stopRepeat(); notificationsPage.activate(); return; }
        if (page === "notification-settings") {
            var row = entries[selected];
            if (!row) return;
            var preference = row.preference;
            var enabled = preference === "backgroundProgress" ? notifications.preferences[preference] !== false : notifications.preferences[preference];
            notifications.send({action:"preferences", [preference]: !enabled});
            return;
        }
        if (page === "exit" || page === "reboot" || page === "shutdown" || page === "store-close") { stopRepeat(); exitPage.activate(); return; }
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
        styleDirect = false;
        var entry = entries[selected];
        if (!entry || entry.disabled === true) return;
        if (entry.key === "store-dukkan" || entry.key === "store-steam") queueStoreAction("launch", entry.key.slice(6), "0");
        else if (entry.key === "store-home") queueStoreAction("home", storefrontId, storeGeneration);
        else if (entry.key === "store-close") { returnPage = page; pageEntry = entry; page = "store-close"; }
        else if (entry.key === "resume") closeMenu();
        else if (entry.key === "emulator-menu") {
            // Execute only after release of A, reverse animation and helper-idle.
            if (foreground !== "game" || !emulatorMenuAvailable || pendingEmulatorMenu) return;
            pendingEmulatorMenu = true;
            emulatorMenuNotice = "";
            closeMenu();
        }
        else if (entry.key === "manage-games") {
            if (foreground !== "library" || storefrontId.length || storeGame) return;
            mainSelected = selected;
            returnPage = page;
            pageEntry = entry;
            page = "manage-games";
            manageGames.open();
        }
        else if (entry.key === "settings" || entry.key === "power" || entry.key === "storefronts") {
            if (menuStyle === "drawer" && entry.key === "power") {
                drawerPowerParent = page;
                if (page === "settings") settingsSelected = selected;
                else mainSelected = selected;
            } else mainSelected = selected;
            pageEntry = entry;
            page = entry.key;
            select(page === "power" ? powerSelected : page === "storefronts" ? 0 : settingsSelected);
        } else {
            returnPage = page;
            if (page === "settings") settingsSelected = selected;
            else if (page === "power") powerSelected = selected;
            else mainSelected = selected;
            pageEntry = entry;
            if (entry.key === "exit" || entry.key === "reboot" || entry.key === "shutdown") exitNotice = "";
            if (entry.key === "bluetooth") bluetoothLoaded = true;
            page = entry.key;
            if (entry.key === "notification-settings" || entry.key === "actions") {
                selected = 0;
                requestFocusSettle();
            }
        }
    }
    function leaveSettingsPage() {
        if (styleDirect) {
            stopRepeat();
            if (menuStyle === "split") chromeZone = "rail";
            else { page = ""; chromeZone = menuStyle === "ribbon" ? "ribbon" : "quick"; }
            return;
        }
        stopRepeat();
        page = "settings";
        select(settingsSelected);
    }
    function back() {
        if (exitBusy || closing) return;
        if (chromeZone === "header") { leaveHeader(); return; }
        if (page !== "notifications" && chromeBack()) return;
        if (styleDirect && chromeZone === "content" && (page === "audio" || page === "controllers" && controllersPage.bluetoothView !== true)) { leaveSettingsPage(); return; }
        if (page === "advanced") { stopRepeat(); advancedPage.back(); return; }
        stopRepeat();
        if (page === "manage-games") { manageGames.back(); return; }
        if (page === "storage") { storagePage.back(); return; }
        if (page === "scrape") {
            if (!scrapePage.back()) {
                if (pegasusLibraryTool === "scrape") { closeMenu(); return; }
                page=scrapeReturnLocation.page;returnPage=scrapeReturnLocation.returnPage;pageEntry=scrapeReturnLocation.entry;
                if (listPage) select(mainSelected);
            }
            return;
        }
        if (page === "notifications") {
            if (!notificationsPage.back()) { if (notificationReturn) restoreNotificationLocation(); else closeMenu(); }
            return;
        }
        if (page === "transfer") {
            if (!transferPage.back()) {
                if (pegasusLibraryTool === "transfer") closeMenu();
                else { page = returnPage; if (listPage) select(mainSelected); }
            }
            return;
        }
        if (page === "notification-settings") { leaveSettingsPage(); return; }
        if (page === "settings" && activeTab === 2) { closeMenu(); return; }
        if (page === "display") { displayPage.back(); return; }
        if (page === "controllers") { controllersPage.back(); return; }
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
        } else if (page === "settings" || page === "power" || page === "storefronts") {
            if (page === "settings") settingsSelected = selected;
            else if (page === "power") powerSelected = selected;
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
        if (pegasusStorageMove) storageHandoffStatus = "unavailable";
        pegasusStorageMove = null;
        pegasusManagement = null;
        pegasusLibraryTool = "";
        resetEntry();
        menuOpen = false;
        opening = false;
        ready = false;
        closing = false;
        stopRepeat();
        pressed = ({});
        keyboardCycleHeld = false;
        controllerCount = 0;
        controllerDevices = [];
        controllerWarning = "";
        displaySupported = false;
        emulatorMenuAvailable = false;
        bluetoothLoaded = false;
        audioLoaded = false;
        networkLoaded = false;
        notificationsPage.detail = null;
        notificationsPage.confirming = false;
        restoreChromeSession();
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
        firstFrameMs = -1;
        slideFinishedMs = -1;
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
        if (menuOpen && !pegasusLibraryTool) {
            rememberTab();
            // A new opening must not revive an old destructive confirmation.
            if (["exit", "reboot", "shutdown", "store-close"].indexOf(page) >= 0 || (page === "manage-games" && manageGames.direct)) {
                tabLocations[activeTab].page = returnPage;
            }
        }
        if ((menuOpen || opening) && bluetoothPageLoader.item) bluetoothPageLoader.item.shutdown();
        menuOpen = false;
        resetEntry();
        opening = false;
        stopRepeat();
        pressed = ({});
        keyboardCycleHeld = false;
    }
    function resetEntry() {
        entryPhase = "hidden";
        slideIn.stop();
        slideOut.stop();
        closeDeadline.stop();
        panel.entryProgress = 0;
    }
    function startEntryFrame() {
        if (!menuOpen || closing || entryPhase !== "await-frame" || !overlay.backingWindowVisible
                || overlay.width <= 0 || overlay.height <= 0 || panel.width <= 0 || panel.height <= 0) return;
        // This frame was queued with progress=0. Only now start moving the panel.
        firstFrameMs = Date.now() - openStartedMs;
        entryPhase = "sliding";
        slideIn.restart();
        bridge.write(JSON.stringify({action: "opened"}) + "\n");
    }
    function closeMenu(completed) {
        if (completed === true) {
            if (!closing || entryPhase !== "closing") return;
            var origin = closeOrigin;
            entryPhase = "hidden";
            hideMenu();
            // Unmap the exclusive layer before the helper restores input.
            if (bridge.running) bridge.write(JSON.stringify({action:"close",page:origin.page,tab:origin.tab}) + "\n");
            else resetMenuSession();
            return;
        }
        if (manageGames.removing || (exitBusy && completed !== "exit-complete") || closing || !(menuOpen || opening)) return;
        closeOrigin = ({page:page,tab:activeTab});
        closing = true;
        stopRepeat(); pressed = ({}); keyboardCycleHeld = false;
        slideIn.stop();
        entryPhase = "closing";
        if (menuOpen && overlay.backingWindowVisible && panel.entryProgress > 0 && bridge.running) {
            slideOut.from = panel.entryProgress;
            slideOut.duration = Math.max(1,Math.round(slideIn.duration * panel.entryProgress));
            closeDeadline.restart();
            slideOut.restart();
        } else closeMenu(true);
    }
    function input(event, value) {
        if (!menuOpen || closing || typeof value !== "number" || !isFinite(value)) return;
        var down = value > 0.5;
        var wasDown = pressed[event] === true;
        var next = Object.assign({}, pressed);
        next[event] = down;
        pressed = next;
        if (["ui_left","ui_right","key_left","key_right"].indexOf(event) >= 0 && chromeHorizontal(event,value,wasDown)) return;
        if (event === "ui_l1" || event === "ui_r1") {
            if (down && !wasDown) switchTab(event === "ui_l1" ? -1 : 1);
            return;
        }
        if (event === "ui_context" || event === "ui_action") {
            if (down && !wasDown && editingKeyboard && !keyboardCycleHeld) {
                keyboardCycleHeld = true;
                var keyboardPage = page === "scrape" ? scrapePage : page === "network" ? networkPageLoader.item : page === "controllers" ? controllersPage : bluetoothPageLoader.item;
                if (keyboardPage) keyboardPage.cycleKeyboard();
            } else if (down && !wasDown && !editingKeyboard) {
                if (event === "ui_context" && canOpenSystem && hasHistoryDismiss) historyDismissHold.restart();
                else faceShortcut(event === "ui_action");
            } else if (event === "ui_context" && !down && wasDown && historyDismissHold.running) {
                historyDismissHold.stop();
                openSystemSettings();
            }
            else if (!down && !pressed.ui_context && !pressed.ui_action) keyboardCycleHeld = false;
            return;
        }
        if (page === "display" && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            if (down && !wasDown) displayPage.horizontal(event === "ui_left" || event === "key_left" ? -1 : 1);
        } else if ((page === "bluetooth" || page === "network" || page === "controllers" && controllersPage.bluetoothView || page === "scrape" && editingKeyboard) && (event === "ui_left" || event === "ui_right" || event === "key_left" || event === "key_right")) {
            var horizontal = event === "ui_left" || event === "key_left" ? -1 : 1;
            if (editingKeyboard) {
                if (down && !wasDown) holdHorizontal(horizontal, true);
                else if (!down) {
                    var held = heldHorizontal !== 0 && horizontalPressed(heldHorizontal) ? heldHorizontal
                        : (horizontalPressed(-1) ? -1 : (horizontalPressed(1) ? 1 : 0));
                    if (held !== heldHorizontal) holdHorizontal(held, false);
                }
            } else if (down && !wasDown) {
                var item = page === "bluetooth" ? bluetoothPageLoader.item : page === "controllers" ? controllersPage : networkPageLoader.item;
                if (item) item.horizontal(horizontal);
                else if (horizontal < 0) back();
            }
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
        } else if (event === "ui_accept" && !down) {
            var launchEmulatorMenu = wasDown && emulatorAcceptArmed && emulatorMenuRowFocused();
            emulatorAcceptArmed = false;
            if (launchEmulatorMenu) activate();
        } else if (down && !wasDown) {
            // Only release a press that began on the emulator action itself.
            if (event === "ui_accept") {
                emulatorAcceptArmed = emulatorMenuRowFocused();
                if (emulatorAcceptArmed) return;
            }
            if (event === "ui_accept" || event === "ui_right" || event === "key_right") activate();
            else if (event === "ui_back" || event === "ui_cancel" || event === "ui_left" || event === "key_left") back();
        }
    }
    function queueStoreAction(action, id, generation, target) {
        if (exitBusy || pendingStoreAction !== null || closing || !menuOpen || sessionActionPath.length === 0) return;
        pendingStoreAction = ({action:action, id:id, generation:generation, target:target || ""});
        closeMenu();
    }
    function openTransaction(jobId) {
        if (!/^[a-f0-9]{32}$/.test(jobId)) return;
        if (foreground === "game" || storeGame) {
            storeNotice = "Return to the library before opening Dukkan activity.";
            return;
        }
        queueStoreAction("launch", "dukkan", "0", jobId);
    }
    function receiveStoreResult(line) {
        var result;
        try { result = JSON.parse(line); } catch (error) { return; }
        if (result.type !== "store-result") return;
        storeResultReceived = true;
        storeNotice = result.ok ? "" : result.message;
    }
    function requestExitGame() {
        if (page === "store-close") { queueStoreAction("close", storefrontId, storeGeneration); return; }
        var power = page === "reboot" || page === "shutdown";
        if (exitBusy || closing || !menuOpen || (!power && (page !== "exit" || foreground !== "game"))) return;
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
                if (menuOpen || opening) closeMenu("exit-complete");
            }
        }
    }
    function finishExitAction(exitCode) {
        if (!exitResultReceived) exitNotice = "The session action stopped before reporting completion.";
        exitBusy = false;
        if (exitNotice.length > 0) console.warn(exitNotice);
    }

    Process {
        id: storeAction
        command: ["/usr/bin/python3", root.sessionActionPath, "storefront", root.storeRequest.action, root.storeRequest.id, root.storeRequest.generation].concat(root.storeRequest.target ? [root.storeRequest.target] : [])
        stdout: SplitParser { onRead: data => root.receiveStoreResult(data) }
        stderr: SplitParser { onRead: data => console.warn(data) }
        onExited: (exitCode, exitStatus) => {
            root.exitBusy = false;
            if (!root.storeResultReceived) root.storeNotice = "The storefront request stopped before reporting completion.";
            if (root.storeNotice.length) root.openMenu();
        }
    }

    Process {
        id: exitAction
        command: ["/usr/bin/python3", root.sessionActionPath, root.sessionAction]
        stdout: SplitParser { onRead: data => root.receiveExitResult(data) }
        stderr: SplitParser { onRead: data => console.warn(data) }
        onExited: (exitCode, exitStatus) => root.finishExitAction(exitCode)
    }
    Process {
        id: emulatorMenuCapability
        command: ["/usr/bin/python3", root.sessionActionPath, "emulator-menu-capability"]
        stdout: SplitParser { onRead: line => {
            try {
                let msg = JSON.parse(line);
                if (msg.type === "emulator-menu-capability" && root.menuOpen && !root.closing
                        && root.foreground === "game") {
                    root.emulatorMenuAvailable = msg.available === true;
                    if (root.selectEmulatorMenuOnReturn && root.page === "actions"
                            && root.chromeZone === "content" && root.selected === 0) {
                        var index = root.entries.findIndex(entry => entry.key === "emulator-menu");
                        if (index >= 0) root.select(index);
                    }
                    root.selectEmulatorMenuOnReturn = false;
                }
            } catch (error) { console.warn(error); }
        } }
        stderr: SplitParser { onRead: line => console.warn(line) }
    }
    Process {
        id: emulatorMenuAction
        command: ["/usr/bin/python3", root.sessionActionPath, "emulator-menu"]
        stdout: SplitParser { onRead: line => {
            try {
                let msg = JSON.parse(line);
                if (msg.type === "emulator-menu-result") {
                    root.emulatorMenuResultReceived = true;
                    if (msg.ok) root.emulatorMenuNotice = "";
                    else root.emulatorMenuFailed(msg.message || "Unable to open the emulator menu.");
                }
            } catch (error) { console.warn(error); }
        } }
        stderr: SplitParser { onRead: line => console.warn(line) }
        onExited: (code, status) => {
            root.exitBusy = false;
            if (!root.emulatorMenuResultReceived && !root.emulatorMenuNotice.length)
                root.emulatorMenuFailed("The emulator menu request ended before it received a reply.");
            if (root.emulatorMenuNotice.length) root.openMenu();
        }
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
            } else {
                resetMenuSession();
                if (reopenAfterEmulatorHandoffFailure) {
                    reopenAfterEmulatorHandoffFailure = false;
                    openMenu();
                    return;
                }
                startFrontendAction();
                if (pendingStoreAction !== null) {
                    storeRequest = pendingStoreAction;
                    pendingStoreAction = null;
                    exitBusy = true;
                    storeResultReceived = false;
                    storeNotice = "";
                    storeAction.running = true;
                } else if (pendingEmulatorMenu) {
                    pendingEmulatorMenu = false;
                    exitBusy = true;
                    emulatorMenuResultReceived = false;
                    emulatorMenuAction.running = true;
                }
            }
        } else if (message.type === "ready") {
            // A close during acquisition must never be undone by late readiness.
            if (!opening || closing || !bridge.running) return;
            displaySupported = message.display === true;
            foreground = message.foreground;
            if (foreground === "game" && root.sessionActionPath.length > 0
                    && !emulatorMenuCapability.running) emulatorMenuCapability.running = true;
            storefrontId = message.storefront || "";
            storeGeneration = message.storeGeneration || "0";
            storeGame = message.storeGame === true;
            controllerCount = message.controllers;
            controllerDevices = message.devices || [];
            ready = true;
            opening = false;
            resetEntry();
            entryPhase = "await-frame";
            menuOpen = true;
            restoreChromeSession();
            if (selectEmulatorMenuOnReturn) {
                if (foreground === "game" && !storefrontId.length && sessionActionPath.length > 0) {
                    showStyleCategory("actions", true);
                    railIndex = railEntries.findIndex(entry => entry.key === "actions");
                    ribbonIndex = ribbonEntries.findIndex(entry => entry.key === "actions");
                } else {
                    emulatorMenuNotice = "";
                    selectEmulatorMenuOnReturn = false;
                }
            }
            var management = pegasusManagement;
            pegasusManagement = null;
            if (management && foreground === "library" && !storefrontId.length && !storeGame) {
                if (management.kind === "transfer" || management.kind === "scrape") {
                    rememberTab();
                    pegasusLibraryTool = management.kind;
                    chromeZone = "content";
                    if (pegasusLibraryTool === "transfer") openTransfers();
                    else openScraping("", "", "");
                } else if (management.kind === "rom") {
                    returnPage = page;
                    pageEntry = ({label: "Manage Game", key: "manage-games", detail: ""});
                    page = "manage-games";
                    chromeZone = "content";
                    manageGames.openSelected(management.games);
                } else {
                    Qt.callLater(() => {
                        if (root.menuOpen && !root.closing) root.queueStoreAction("launch", management.kind, "0");
                    });
                }
            }
            var selectedStorageGame = pegasusStorageMove;
            pegasusStorageMove = null;
            if (selectedStorageGame && foreground === "library" && !storefrontId.length && !storeGame) {
                returnPage = page;
                pegasusLibraryTool = "storage";
                pageEntry = ({label:"Storage", key:"storage", detail:""});
                chromeZone = "content";
                storagePage.openGameMove(selectedStorageGame);
                page = "storage";
                storageHandoffStatus = "shown";
            } else if (selectedStorageGame) {
                storageHandoffStatus = "unavailable";
            }
            lastReadyMs = Date.now() - openStartedMs;
            console.info("Resident menu input ready after " + lastReadyMs + " ms");
        } else if (message.type === "controllers") {
            stopRepeat();
            controllerCount = message.controllers;
            controllerDevices = message.devices || [];
        } else if (message.type === "input-reset") {
            stopRepeat(); pressed = ({}); keyboardCycleHeld = false;
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
            if (pendingEmulatorMenu) {
                emulatorMenuFailed("Zaman couldn't return controller input to the game. Try opening the emulator menu again.");
                reopenAfterEmulatorHandoffFailure = true;
            }
            pendingFrontendAction = "";
            frontendNotice = "Input restoration failed; frontend action was canceled.";
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
            if (root.pendingFrontendAction.length) {
                root.pendingFrontendAction = "";
                root.frontendNotice = "Input restoration failed; frontend action was canceled.";
            }
            if (root.pendingStoreAction !== null) {
                root.pendingStoreAction = null;
                root.storeNotice = "The input helper stopped before restoring the menu lease. Reopen the menu to try again.";
            }
            if (root.pendingEmulatorMenu) {
                root.emulatorMenuFailed("The controller helper stopped before returning input to the game.");
                root.reopenAfterEmulatorHandoffFailure = true;
            }
            root.helperIdle = false;
            if (exitCode !== 0) console.error("Preview helper exited with code " + exitCode);
            root.resetMenuSession();
            if (root.reopenAfterEmulatorHandoffFailure) {
                root.reopenAfterEmulatorHandoffFailure = false;
                Qt.callLater(() => root.openMenu());
            }
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
    Timer {
        id: horizontalDelay
        interval: 220
        onTriggered: {
            if (root.heldHorizontal !== 0 && root.menuOpen && root.editingKeyboard && root.horizontalPressed(root.heldHorizontal)) {
                root.moveHorizontal(root.heldHorizontal);
                horizontalStep.start();
            }
        }
    }
    Timer {
        id: horizontalStep
        interval: 70
        repeat: true
        onTriggered: {
            if (root.heldHorizontal === 0 || !root.menuOpen || !root.editingKeyboard || !root.horizontalPressed(root.heldHorizontal)) root.stopRepeat();
            else root.moveHorizontal(root.heldHorizontal);
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
            } else if (!backingWindowVisible) {
                if (root.closing && root.entryPhase === "closing") root.closeMenu(true);
                else root.resetEntry();
            }
        }
        onClosed: root.closeMenu()

        Connections {
            target: panel.Window.window
            function onFrameSwapped() { root.startEntryFrame(); }
        }

        NumberAnimation {
            id: slideIn
            target: panel
            property: "entryProgress"
            from: 0
            to: 1
            duration: root.motionEnabled ? 180 : 0
            easing.type: Easing.OutCubic
            onFinished: {
                if (root.menuOpen && root.entryPhase === "sliding") {
                    root.entryPhase = "settled";
                    root.slideFinishedMs = Date.now() - root.openStartedMs;
                }
            }
        }

        NumberAnimation {
            id: slideOut
            target: panel
            property: "entryProgress"
            to: 0
            duration: slideIn.duration
            easing.type: Easing.InCubic
            onFinished: root.closeMenu(true)
        }
        Timer {
            id: closeDeadline
            interval: 600
            onTriggered: root.closeMenu(true)
        }

        Rectangle {
            anchors.fill: parent
            opacity: panel.entryProgress
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
            property real entryProgress: 0
            // Targets use final dimensions, so position is not retargeted every resize frame.
            readonly property real targetWidth: root.menuStyle === "drawer" ? Math.min(parent.width - root.px(56), root.px(root.chromeHome ? 540 : 660))
                : Math.min(parent.width - root.px(64), root.px(root.menuStyle === "split" ? 1320 : 1380))
            readonly property real targetHeight: root.menuStyle === "ribbon" && root.chromeHome ? root.px(200)
                : Math.min(parent.height - root.px(52), root.px(root.menuStyle === "drawer" ? 1028 : 920))
            readonly property real offscreenX: root.menuStyle === "drawer" ? parent.width + root.px(8) : -targetWidth - root.px(8)
            readonly property real targetX: root.menuStyle === "drawer" ? parent.width - targetWidth - root.px(28) : (parent.width - targetWidth) / 2
            readonly property real targetY: root.menuStyle === "ribbon" ? parent.height - targetHeight - root.px(28) : (parent.height - targetHeight) / 2
            x: entryProgress >= 0.9999 || root.menuStyle === "ribbon" ? targetX : offscreenX + (targetX - offscreenX) * entryProgress
            y: entryProgress >= 0.9999 || root.menuStyle !== "ribbon" ? targetY : parent.height + (targetY - parent.height) * entryProgress
            width: targetWidth
            height: targetHeight
            radius: root.px(root.menuStyle === "ribbon" ? 20 : 24)
            Behavior on x { enabled: root.menuMotionActive; NumberAnimation { duration:140; easing.type:Easing.OutCubic } }
            Behavior on y { enabled: root.menuMotionActive; NumberAnimation { duration:140; easing.type:Easing.OutCubic } }
            Behavior on width { enabled: root.menuMotionActive; NumberAnimation { duration:140; easing.type:Easing.OutCubic } }
            Behavior on height { enabled: root.menuMotionActive; NumberAnimation { duration:140; easing.type:Easing.OutCubic } }
            Behavior on radius { enabled: root.menuMotionActive; NumberAnimation { duration:140; easing.type:Easing.OutCubic } }
            border.width: 1
            border.color: "#47505e"
            color: "#202530"
            readonly property real padding: root.px(32)
            MouseArea { anchors.fill: parent; onClicked: mouse => mouse.accepted = true }

            ResidentChrome {
                id: residentChrome
                anchors.fill: parent
                controller: root
            }


            Item {
                id: pageHost
                clip: true
                opacity: 0.88 + 0.12 * root.contentReveal
                transform: Translate { x:root.px(8) * (1 - root.contentReveal) }
                x: residentChrome.contentX; y: residentChrome.contentY
                width: residentChrome.contentWidth; height: residentChrome.contentHeight
                visible: !root.chromeHome
                TapHandler {
                    onPressedChanged: if (pressed) {
                        if (root.chromeZone === "header") root.leaveHeader();
                        if (root.menuStyle === "split") root.chromeZone = "content";
                    }
                }
                HoverHandler { onHoveredChanged: if (hovered && root.menuStyle === "split" && root.page !== "notifications" && root.chromeZone !== "header") root.chromeZone = "content" }
            ListView {
                id: menuList
                property point lastPointerPosition: Qt.point(-100000, -100000)
                visible: root.listPage && !root.chromeHome
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: root.px(8); rightMargin: root.px(8)
                    topMargin: root.px(18); bottomMargin: root.px(18)
                }
                model: root.entries
                currentIndex: root.selected
                spacing: root.px(12)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                delegate: MenuFocusRow {
                    id: menuRow
                    required property var modelData
                    required property int index
                    chosen: root.contentHasFocus && root.selected === index
                    readonly property bool storefrontMark: modelData.key === "store-dukkan" || modelData.key === "store-steam" || (modelData.key === "resume" && root.storefrontId.length > 0)
                    readonly property bool dukkanMark: modelData.key === "store-dukkan" || (modelData.key === "resume" && root.storefrontId === "dukkan")
                    uiScale: root.uiScale
                    width: menuList.width
                    baseHeight: 102
                    height: root.px(102)
                    onFocusSettled: if (menuRow.chosen) root.requestFocusSettle()
                    MenuFocusBackground {
                        chosen: menuRow.chosen
                        uiScale: root.uiScale
                        emphasis: menuRow.focusAmount
                    }
                    Rectangle {
                        x: root.px(14); y: Math.round((parent.height - height) / 2)
                        width: root.px(menuRow.storefrontMark ? 104 : 42 + 4 * menuRow.focusAmount)
                        height: root.px(42 + 4 * menuRow.focusAmount)
                        radius: root.px(12)
                        color: "transparent"
                        MenuIcon {
                            anchors.centerIn: parent
                            name: menuRow.modelData.key === "actions" ? (root.foreground === "game" ? "resume" : "library")
                                : menuRow.modelData.key === "manage-games" ? "library"
                                : menuRow.modelData.key === "resume" && root.storefrontId.length ? "store-" + root.storefrontId : menuRow.modelData.key === "resume" && root.foreground !== "game" ? "library" : menuRow.modelData.key
                            ink: "#EAC28D"
                            width: root.px(menuRow.dukkanMark ? 98 + 4 * menuRow.focusAmount : 25)
                            height: menuRow.dukkanMark ? root.px(39 + 2 * menuRow.focusAmount) : width
                        }
                    }
                    Column {
                        x: root.px(menuRow.storefrontMark ? 134 : 62)
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width - x - root.px(menuRow.modelData.disabled ? 80 : 38)
                        spacing: root.px(4)
                        MenuText {
                            width: parent.width
                            text: menuRow.modelData.label
                            color: menuRow.modelData.disabled ? "#929DAB" : "#F3EEE5"
                            font.pixelSize: root.px(24)
                            elide: Text.ElideRight
                        }
                        MenuText {
                            width: parent.width
                            text: menuRow.modelData.detail
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            color: "#BBC6D3"
                            font.pixelSize: root.px(16)
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        visible: menuRow.modelData.disabled === true || false
                        anchors { right: chevron.left; rightMargin: root.px(10) }
                        y: Math.round((parent.height - height) / 2)
                        width: root.px(45); height: root.px(21); radius: root.px(7)
                        color: "#19281C12"
                        MenuText {
                            anchors.centerIn: parent
                            text: "Soon"; font.pixelSize: root.px(10); color: "#BBC6D3"
                        }
                    }
                    MenuIcon {
                        id: chevron
                        visible: menuRow.modelData.disabled !== true
                        name: "chevron"
                        anchors { right: parent.right; rightMargin: root.px(16) }
                        y: Math.round((parent.height - height) / 2)
                        width: root.px(17); height: root.px(22)
                        ink: menuRow.chosen ? "#EAC28D" : "#7D899B"
                    }
                    MouseArea {
                        id: menuPointer
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: if (menuRow.pointerMoved(menuPointer)) root.select(index)
                        onPositionChanged: if (menuRow.pointerMoved(menuPointer)) root.select(index)
                        onClicked: { root.chromeZone = "content"; root.select(index); root.activate(); }
                    }
                }
            }

            StoragePage {
                id:storagePage
                focusVisible: root.contentHasFocus
                visible:root.page === "storage"
                uiScale:root.uiScale
                active:root.menuOpen && root.page === "storage"
                onBackRequested:{ if (root.pegasusLibraryTool === "storage") root.closeMenu(); else root.leaveSettingsPage(); }
                anchors { left:parent.left;right:parent.right;top:parent.top;bottom:parent.bottom
                    leftMargin:0;rightMargin:0;topMargin:root.px(22);bottomMargin:root.px(18) }
            }
            ManageGamesPage {
                id: manageGames
                focusVisible: root.contentHasFocus
                visible: root.page === "manage-games"
                uiScale: root.uiScale
                client: root.transferClient
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onBackRequested: {
                    if (manageGames.direct) root.closeMenu();
                    else { root.page = root.returnPage; root.select(root.mainSelected); }
                }
                onStoreRequested: id => root.queueStoreAction("launch", id, "0")
            }
            TransferPage {
                id: transferPage
                focusVisible: root.contentHasFocus
                visible: root.page === "transfer"
                snapshot: root.transferSnapshot
                available: root.transferAvailable
                busy: transferAction.running
                error: root.transferError
                uiScale: root.uiScale
                onOpenScraping:(importId,system,jobId)=>root.openScraping(importId,system,jobId)
                anchors {
                    left:parent.left; right:parent.right; top:parent.top; bottom:parent.bottom
                    leftMargin:0; rightMargin:0
                    topMargin:root.px(22); bottomMargin:root.px(18)
                }
                onCommand: request => {
                    if (!transferAction.running && root.transferClient.length > 0) {
                        root.transferRequest = request;
                        transferAction.running = true;
                    }
                }
            }
            ScrapePage {
                id:scrapePage
                focusVisible: root.contentHasFocus
                visible:root.page === "scrape"
                snapshot:root.transferSnapshot.scraper || ({available:false,folders:[],jobs:[]})
                available:root.transferAvailable;busy:transferAction.running;error:root.transferError;uiScale:root.uiScale
                onCloseRequested:root.closeMenu()
                anchors { left:parent.left;right:parent.right;top:parent.top;bottom:parent.bottom
                    leftMargin:0;rightMargin:0;topMargin:root.px(22);bottomMargin:root.px(18) }
                onCommand:request=>{
                    if (!transferAction.running && root.transferClient.length>0) { root.transferRequest=request;transferAction.running=true; }
                }
            }
            NotificationsPage {
                id: notificationsPage
                focusVisible: root.contentHasFocus
                client: notifications
                imports: root.transferSnapshot.jobs || []
                scrapes:root.transferSnapshot.scraper ? root.transferSnapshot.scraper.jobs || [] : []
                onOpenScrape:jobId=>root.openScraping("","",jobId)
                onOpenTransfer: root.openTransfers()
                onOpenTransaction: jobId => root.openTransaction(jobId)
                visible: root.page === "notifications"
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
            }
            DisplayPage {
                id: displayPage
                focusVisible: root.contentHasFocus
                visible: root.page === "display"
                active: root.page === "display" && root.menuOpen
                helperReady: root.displaySupported
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
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
                active: root.menuOpen && (root.bluetoothLoaded || root.page === "bluetooth")
                source: active ? Qt.resolvedUrl("BluetoothPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: { root.bluetoothLoaded = true; item.uiScale = Qt.binding(() => root.uiScale); item.focusVisible = Qt.binding(() => root.contentHasFocus); item.controllerStatus = Qt.binding(() => controllersPage.inventory.bluetooth); }
            }
            Connections {
                target: bluetoothPageLoader.item
                function onBackRequested() { root.leaveSettingsPage(); }
                function onNavigationReset() { root.stopRepeat(); }
            }
            // Visited native pages retain their views while this menu lease is open.
            Loader {
                id: networkPageLoader
                visible: root.page === "network"
                active: root.menuOpen && (root.networkLoaded || root.page === "network")
                source: active ? Qt.resolvedUrl("NetworkPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: { root.networkLoaded = true; item.uiScale = Qt.binding(() => root.uiScale); item.focusVisible = Qt.binding(() => root.contentHasFocus); }
            }
            Connections {
                target: networkPageLoader.item
                function onBackRequested() { root.leaveSettingsPage(); }
                function onNavigationReset() { root.stopRepeat(); }
            }
            ControllersPage {
                id: controllersPage
                focusVisible: root.contentHasFocus
                visible: root.page === "controllers"
                active: root.menuOpen && root.page === "controllers"
                inventoryActive: root.menuOpen && (root.page === "controllers" || root.page === "bluetooth")
                uiScale: root.uiScale
                devices: root.controllerDevices
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onBackRequested: root.leaveSettingsPage()
                onNavigationReset: root.stopRepeat()
            }
            Loader {
                id: audioPageLoader
                visible: root.page === "audio"
                active: root.menuOpen
                source: active ? Qt.resolvedUrl("AudioPage.qml") : ""
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(22); bottomMargin: root.px(18)
                }
                onLoaded: {
                    root.audioLoaded = true;
                    item.uiScale = Qt.binding(() => root.uiScale);
                    item.focusVisible = Qt.binding(() => root.contentHasFocus);
                    item.active = Qt.binding(() => root.menuOpen && (root.page === "audio" || root.menuStyle === "drawer" && root.chromeHome));
                    var location = root.tabLocations[root.activeTab];
                    if (root.page === "audio" && root.menuStyle !== "ribbon" && location && location.audio) item.restoreLocation(location.audio);
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
                    left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 0; rightMargin: 0; topMargin: root.px(32)
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
                MenuCard {
                    width: parent.width; height: root.px(56)
                    uiScale: root.uiScale; cardFocused: root.contentHasFocus
                    MenuText {
                        anchors.centerIn: parent
                        text: "Back"; color: "#F3EEE5"; font.pixelSize: root.px(20)
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.back() }
                }
            }

            AdvancedPage {
                id: advancedPage
                focusVisible: root.contentHasFocus
                visible: root.page === "advanced"
                active: root.menuOpen && visible && !root.closing
                available: root.foreground === "library" && !root.storefrontId.length
                busy: root.exitBusy
                notice: root.frontendNotice
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(24); bottomMargin: root.px(18)
                }
                onActionRequested: action => root.queueFrontendAction(action)
                onBackRequested: root.leaveSettingsPage()
            }

            ExitGamePage {
                id: exitPage
                focusVisible: root.contentHasFocus
                visible: root.page === "exit" || root.page === "reboot" || root.page === "shutdown" || root.page === "store-close"
                active: root.menuOpen && visible
                prompt: root.page === "reboot" ? "Restart Zaman?" : root.page === "shutdown" ? "Shut down Zaman?" : root.page === "store-close" ? "Close " + (root.storefrontId === "steam" ? "Steam" : "Dukkan") + "?" : "Exit this game?"
                detail: root.page === "reboot" ? "Close any running game and restart Zaman." : root.page === "shutdown" ? "Close any running game and turn off Zaman." : root.page === "store-close" ? (root.storeGame ? "Close Steam and its running game, then return to your library. Unsaved progress may be lost. Downloads may stop." : "Close the storefront and return to your library. Downloads may stop.") : "Close the current game and return to your library."
                cancelLabel: root.page === "exit" ? "Keep playing" : "Cancel"
                confirmLabel: root.page === "reboot" ? "Reboot" : root.page === "shutdown" ? "Shutdown" : root.page === "store-close" ? "Close " + (root.storefrontId === "steam" ? "Steam" : "Dukkan") : "Exit Game"
                busyHeading: root.sessionAction === "reboot" ? "Restarting Zaman…" : root.sessionAction === "shutdown" ? "Shutting down Zaman…" : "Closing game…"
                busy: root.exitBusy
                notice: root.exitNotice
                uiScale: root.uiScale
                anchors {
                    left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                    leftMargin: 0; rightMargin: 0
                    topMargin: root.px(32); bottomMargin: root.px(18)
                }
                onConfirmRequested: root.requestExitGame()
                onBackRequested: root.back()
            }

            MenuAppearancePage {
                id: appearancePage
                focusVisible: root.contentHasFocus
                anchors.fill: parent
                visible: root.page === "appearance"
                uiScale: root.uiScale
                currentStyle: root.menuStyle
                settingsReady: root.styleReady
                motionEnabled: root.motionEnabled
                animate: root.menuMotionActive
                onMotionRequested: enabled => root.setMenuMotion(enabled)
                notice: root.styleNotice
                onStyleRequested: style => root.setMenuStyle(style)
                onBackRequested: root.leaveSettingsPage()
            }
            }



        }

        NotificationToastStack {
            anchors { top: parent.top; right: parent.right; margins: root.px(32) }
            width: Math.min(root.px(420), parent.width - root.px(64))
            uiScale: root.uiScale
            popups: notifications.popups
            visible: root.menuPresentsToasts
            z: 100
        }

        FocusScope {
            id: inputScope
            anchors.fill: parent
            focus: true
            enabled: root.menuOpen
            Keys.onPressed: event => {
                if (root.closing) { event.accepted = true; return; }
                if (root.page === "controllers" && controllersPage.physicalKey(event)) { event.accepted = true; return; }
                if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown)) {
                    if (!event.isAutoRepeat) root.switchTab(event.key === Qt.Key_PageUp ? -1 : 1);
                    event.accepted = true; return;
                }
                if (!root.editingKeyboard && (event.key === Qt.Key_X || event.key === Qt.Key_Y)) {
                    if (!event.isAutoRepeat) root.faceShortcut(event.key === Qt.Key_Y);
                    event.accepted = true; return;
                }
                if (root.page === "bluetooth" && bluetoothPageLoader.item && bluetoothPageLoader.item.physicalKey(event)) {
                    event.accepted = true;
                    return;
                }
                if (root.page === "network" && networkPageLoader.item && networkPageLoader.item.physicalKey(event)) {
                    event.accepted = true;
                    return;
                }
                if (root.page === "scrape" && scrapePage.physicalKey(event)) { event.accepted=true;return; }
                if (event.key === Qt.Key_Delete && !root.editingKeyboard) {
                    if (!event.isAutoRepeat) root.notificationShortcut(false);
                    event.accepted = true; return;
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
                if (root.closing) { event.accepted = true; return; }
                if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                    if (!event.isAutoRepeat) root.input(event.key === Qt.Key_Up ? "key_up" : "key_down", 0);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                    if (!event.isAutoRepeat) root.input(event.key === Qt.Key_Left ? "key_left" : "key_right", 0);
                    event.accepted = true;
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            z: 200
            visible: root.closing
            acceptedButtons: Qt.AllButtons
            onWheel: event => { event.accepted = true; }
        }
    }
}
