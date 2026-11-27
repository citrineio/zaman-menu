import QtQuick
import Quickshell.Io

Item {
    id: drawer
    required property var controller
    readonly property var audio: controller.audioController
    readonly property bool motion: controller.menuMotionActive
    readonly property color gold: "#e2be82"
    readonly property color ink: "#f5efe7"
    readonly property color muted: "#adb6c5"
    readonly property real scaleFactor: Math.min(controller.uiScale, width / 500)
    readonly property int gutter: px(36)
    readonly property bool hasExit: controller.quickHasExit
    readonly property bool hasTopSecondary: controller.quickHasTopSecondary
    readonly property var topSecondaryEntry: controller.quickTopSecondary
    readonly property bool hasStoreHome: controller.quickHasStoreHome
    readonly property string storefrontName: controller.storefrontId === "steam" ? "Steam" : "Dukkan"
    property string displayStatus: "Reading…"

    function px(value) { return Math.round(scaleFactor * value); }
    function ensure(index) {
        Qt.callLater(function() {
            if (!drawer.visible || drawer.controller.quickIndex !== index) return;
            var target = [resume, volume, network, bluetooth, output, displayRow, players, topSecondary, hideStore][index];
            if (index === 4 && drawer.controller.quickOutputOpen) {
                var at = drawer.audio.outputs.indexOf(drawer.controller.quickOutputNode);
                target = outputs.itemAt(at) || output;
            }
            if (!target || !target.visible) return;
            var top = target.mapToItem(body, 0, 0).y;
            var bottom = top + target.height;
            if (top < scroll.contentY) scroll.contentY = Math.max(0, top);
            else if (bottom > scroll.contentY + scroll.height)
                scroll.contentY = Math.min(Math.max(0, scroll.contentHeight - scroll.height), bottom - scroll.height);
        });
    }

    onVisibleChanged: {
        if (!visible) return;
        displayStatus = "Reading…";
        ensure(controller.quickIndex);
    }
    // Read the active mode without opening or disturbing the Display preview page.
    Timer {
        interval: 2000
        running: drawer.visible && drawer.controller.menuOpen && !drawer.controller.closing
        triggeredOnStart: true
        repeat: true
        onTriggered: if (!displayQuery.running) displayQuery.running = true
    }
    Process {
        id: displayQuery
        command: ["swaymsg", "-r", "-t", "get_outputs"]
        stdout: StdioCollector {
            onStreamFinished: if (drawer.visible)
                drawer.displayStatus = drawer.controller.quickDisplayLabel(text, drawer.controller.quickScreenName)
        }
        onExited: code => { if (code !== 0 && drawer.visible) drawer.displayStatus = "Unavailable"; }
    }

    component ControlSurface: MenuCard {
        id: control
        required property int entry
        property string accessibleLabel: drawer.controller.quickEntries[entry]?.label || ""
        property bool available: true
        readonly property bool focused: drawer.controller.chromeZone === "quick" && drawer.controller.quickIndex === entry
            && (!drawer.controller.quickOutputOpen || entry !== 4)
        uiScale: drawer.scaleFactor
        cardFocused: focused
        cardMotion: drawer.motion
        Accessible.role: Accessible.Button
        Accessible.name: accessibleLabel
        Accessible.focused: focused
        Accessible.onPressAction: if (available) drawer.controller.clickQuick(entry)
        MouseArea {
            anchors.fill: parent
            enabled: control.available && !drawer.controller.shortcutBlocked
            onClicked: drawer.controller.clickQuick(control.entry)
        }
    }

    component ActionCard: ControlSurface {
        id: action
        required property string label
        required property string icon
        height: drawer.px(72)
        accessibleLabel: label
        Row {
            anchors.centerIn: parent
            width: actionIcon.width + spacing + actionText.width
            spacing: drawer.px(10)
            MenuIcon {
                id: actionIcon
                name: action.icon; width: drawer.px(24); height: width; ink: drawer.gold
                anchors.verticalCenter: parent.verticalCenter
            }
            MenuText {
                id: actionText
                width: Math.min(implicitWidth, Math.max(0, action.width - actionIcon.width - parent.spacing - drawer.px(24)))
                text: action.label; color: drawer.ink; font.pixelSize: drawer.px(23)
                elide: Text.ElideRight
            }
        }
    }

    component StatusTile: ControlSurface {
        id: tile
        required property string icon
        required property string title
        required property string detail
        accessibleLabel: title + ", " + detail
        MenuIcon {
            x: drawer.px(17); y: drawer.px(16)
            width: drawer.px(25); height: width
            name: tile.icon; ink: drawer.ink
        }
        MenuText {
            x: drawer.px(17); y: drawer.px(49); width: parent.width - 2 * x
            text: tile.title; color: drawer.ink
            font.pixelSize: drawer.px(24); elide: Text.ElideRight
        }
        MenuText {
            x: drawer.px(17); y: drawer.px(84); width: parent.width - 2 * x
            text: tile.detail; color: drawer.muted
            font.pixelSize: drawer.px(19); elide: Text.ElideRight
        }
    }

    component StatusRow: ControlSurface {
        id: statusRow
        required property string value
        width: body.width; height: drawer.px(62)
        accessibleLabel: drawer.controller.quickEntries[entry].label + ", " + value
        MenuText {
            x: drawer.px(17)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - x - rowValue.width - drawer.px(26))
            text: drawer.controller.quickEntries[statusRow.entry].label
            elide: Text.ElideRight
            color: drawer.ink; font.pixelSize: drawer.px(23)
        }
        MenuText {
            id: rowValue
            anchors { right: parent.right; rightMargin: drawer.px(17); verticalCenter: parent.verticalCenter }
            width: parent.width * 0.52
            horizontalAlignment: Text.AlignRight
            text: statusRow.value; color: drawer.gold
            font.pixelSize: drawer.px(19); elide: Text.ElideLeft
        }

    }

    Item {
        id: header
        x: drawer.gutter; y: drawer.px(32)
        width: parent.width - 2 * x; height: drawer.px(53)
        MenuText {
            anchors.verticalCenter: parent.verticalCenter
            width: bell.x - drawer.px(10)
            text: "Quick settings"; color: drawer.ink
            font.pixelSize: drawer.px(38); font.weight: Font.Medium; elide: Text.ElideRight
        }
        MenuHeaderActions {
            id: bell
            controller: drawer.controller
            uiScale: drawer.scaleFactor
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        }
    }
    MenuText {
        id: warning
        x: drawer.gutter; y: header.y + header.height
        width: parent.width - 2 * x
        visible: text.length > 0
        text: drawer.controller.emulatorMenuNotice || drawer.controller.controllerWarning || drawer.controller.styleNotice
        textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3
        color: drawer.gold; font.pixelSize: drawer.px(14); elide: Text.ElideRight
    }

    Flickable {
        id: scroll
        x: drawer.gutter; width: parent.width - 2 * x
        y: warning.y + (warning.visible ? warning.height + drawer.px(6) : drawer.px(18))
        height: Math.max(0, footer.y - y - drawer.px(12))
        contentWidth: width; contentHeight: body.height
        clip: true; boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        opacity: 0.88 + 0.12 * drawer.controller.contentReveal
        transform: Translate { x: drawer.px(8) * (1 - drawer.controller.contentReveal) }

        Column {
            id: body
            width: scroll.width
            spacing: drawer.px(13)

            Row {
                width: parent.width
                spacing: drawer.px(13)
                ActionCard {
                    id: resume
                    entry: 0
                    width: drawer.hasTopSecondary ? Math.floor((parent.width - parent.spacing) / 2) : parent.width
                    label: drawer.hasExit ? "Resume game"
                        : drawer.controller.storefrontId ? "Resume " + drawer.storefrontName
                        : drawer.hasTopSecondary ? "Library"
                        : drawer.controller.quickEntries[0].label
                    icon: drawer.controller.foreground === "game" || drawer.controller.storefrontId ? "resume" : "library"
                }
                ActionCard {
                    id: topSecondary
                    visible: drawer.hasTopSecondary
                    entry: 7
                    width: parent.width - parent.spacing - resume.width
                    label: drawer.topSecondaryEntry ? drawer.topSecondaryEntry.label : ""
                    icon: drawer.topSecondaryEntry ? drawer.topSecondaryEntry.icon : "exit"
                }
            }

            ControlSurface {
                id: hideStore
                visible: drawer.hasStoreHome
                entry: 8
                width: parent.width
                height: drawer.px(68)
                accessibleLabel: "Hide " + drawer.storefrontName + ", return to library and keep running"
                MenuIcon {
                    x: drawer.px(17)
                    anchors.verticalCenter: parent.verticalCenter
                    width: drawer.px(24); height: width
                    name: "store-home"; ink: drawer.gold
                }
                Column {
                    x: drawer.px(52)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - drawer.px(17)
                    spacing: drawer.px(2)
                    MenuText {
                        width: parent.width
                        text: "Hide " + drawer.storefrontName
                        color: drawer.ink; font.pixelSize: drawer.px(21)
                        elide: Text.ElideRight
                    }
                    MenuText {
                        width: parent.width
                        text: "Return to library · Keep running in background"
                        color: drawer.muted; font.pixelSize: drawer.px(15)
                        elide: Text.ElideRight
                    }
                }
            }

            ControlSurface {
                id: volume
                entry: 1; width: parent.width; height: drawer.px(115)
                available: !!drawer.audio && drawer.audio.hasLevel && !drawer.audio.busy
                readonly property string status: drawer.controller.chromeStatus("quick-volume")
                accessibleLabel: "Volume, " + status
                MenuText {
                    x: drawer.px(17); y: drawer.px(16)
                    text: "Volume"; color: drawer.ink; font.pixelSize: drawer.px(23)
                }
                MenuText {
                    anchors { right: parent.right; rightMargin: drawer.px(17) }
                    y: drawer.px(16)
                    text: volume.status; color: drawer.gold; font.pixelSize: drawer.px(22)
                }
                Item {
                    x: drawer.px(17); y: drawer.px(57)
                    width: parent.width - 2 * x; height: drawer.px(45)
                    Rectangle {
                        id: track
                        x: thumb.width / 2
                        width: parent.width - 2 * x; height: drawer.px(10)
                        anchors.verticalCenter: parent.verticalCenter
                        radius: height / 2; color: "#3c4149"; border.width: 1; border.color: "#767a80"
                        Rectangle {
                            id: fillLevel
                            width: drawer.audio && drawer.audio.hasLevel ? track.width * Math.min(100, drawer.audio.percent) / 100 : 0
                            height: parent.height; radius: height / 2; color: drawer.gold
                            Behavior on width {
                                enabled: drawer.motion && !volumePointer.pressed
                                NumberAnimation { duration: 80; easing.type: Easing.OutCubic }
                            }
                        }
                        Rectangle {
                            id: thumb
                            x: fillLevel.width - width / 2
                            width: drawer.px(24); height: width; radius: width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: drawer.gold; visible: !!drawer.audio && drawer.audio.hasLevel
                        }
                    }
                    MouseArea {
                        id: volumePointer
                        anchors.fill: parent
                        enabled: volume.available && !drawer.controller.shortcutBlocked
                        preventStealing: true
                        function setAt(position) {
                            drawer.controller.quickSetVolume((position - track.x) * 100 / track.width);
                        }
                        onPressed: mouse => {
                            drawer.controller.closeQuickOutput();
                            drawer.controller.focusQuick(1);
                            setAt(mouse.x);
                        }
                        onPositionChanged: mouse => { if (pressed) setAt(mouse.x); }
                    }
                }
            }
            Row {
                width: parent.width; spacing: drawer.px(13)
                StatusTile {
                    id: network
                    entry: 2; width: Math.floor((parent.width - parent.spacing) / 2); height: drawer.px(127)
                    icon: "network"; title: drawer.controller.quickNetwork; detail: drawer.controller.quickNetworkDetail
                }
                StatusTile {
                    id: bluetooth
                    entry: 3; width: parent.width - parent.spacing - network.width; height: network.height
                    icon: "bluetooth"; title: "Bluetooth"; detail: drawer.controller.chromeStatus("bluetooth")
                }
            }

            Column {
                width: parent.width; spacing: drawer.px(8)
                MenuText { text: "Sound through"; color: drawer.ink; font.pixelSize: drawer.px(22) }
                ControlSurface {
                    id: output
                    entry: 4; width: parent.width; height: drawer.px(62)
                    radius: drawer.px(11)
                    available: !!drawer.audio && drawer.audio.outputs.length > 0 && !drawer.audio.busy
                    accessibleLabel: "Sound through, " + outputName.text
                    MenuText {
                        id: outputName
                        x: drawer.px(19); width: parent.width - x - drawer.px(42)
                        anchors.verticalCenter: parent.verticalCenter
                        text: drawer.audio && drawer.audio.busy ? "Switching output…" : drawer.controller.chromeStatus("quick-output")
                        color: drawer.ink; font.pixelSize: drawer.px(22); elide: Text.ElideRight
                    }
                    MenuIcon {
                        anchors { right: parent.right; rightMargin: drawer.px(15); verticalCenter: parent.verticalCenter }
                        name: "chevron"; ink: drawer.muted
                        rotation: drawer.controller.quickOutputOpen ? -90 : 90
                        width: drawer.px(19); height: width
                    }
                }
                MenuText {
                    width: parent.width
                    visible: !drawer.controller.quickOutputOpen && text.length > 0
                    text: drawer.audio ? drawer.audio.errorText : ""
                    color: drawer.gold; font.pixelSize: drawer.px(16); wrapMode: Text.WordWrap
                }
                Column {
                    width: parent.width; spacing: drawer.px(3)
                    visible: drawer.controller.quickOutputOpen
                    Repeater {
                        id: outputs
                        model: drawer.controller.quickOutputOpen && drawer.audio ? drawer.audio.outputs : []
                        delegate: MenuCard {
                            id: option
                            required property var modelData
                            readonly property bool picked: modelData === drawer.controller.quickOutputNode
                            readonly property bool current: modelData === drawer.audio.current()
                            width: body.width; height: drawer.px(45); radius: drawer.px(8)
                            uiScale: drawer.scaleFactor
                            cardFocused: picked; cardMotion: drawer.motion
                            Accessible.role: Accessible.Button
                            Accessible.name: optionName.text + (current ? ", active" : "")
                            Accessible.focused: picked
                            Accessible.onPressAction: drawer.controller.applyQuickOutput(modelData)
                            MenuText {
                                id: optionName
                                x: drawer.px(14); width: parent.width - x - drawer.px(option.current ? 65 : 14)
                                anchors.verticalCenter: parent.verticalCenter
                                text: drawer.audio.outputLabel(option.modelData); elide: Text.ElideRight
                                color: drawer.ink; font.pixelSize: drawer.px(18)
                            }
                            MenuText {
                                visible: option.current
                                anchors { right: parent.right; rightMargin: drawer.px(12); verticalCenter: parent.verticalCenter }
                                text: "Active"; color: drawer.gold; font.pixelSize: drawer.px(14)
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: !drawer.controller.shortcutBlocked
                                onClicked: drawer.controller.applyQuickOutput(option.modelData)
                            }
                        }
                    }
                }
            }

            Column {
                width: parent.width; spacing: drawer.px(9)
                StatusRow { id: displayRow; entry: 5; value: drawer.displayStatus }
                StatusRow {
                    id: players; entry: 6
                    value: drawer.controller.controllerCount === 1 ? "1 ready"
                        : drawer.controller.controllerCount > 1 ? drawer.controller.controllerCount + " ready" : "None connected"
                }
            }
        }
    }

    Flow {
        id: footer
        x: drawer.gutter; width: parent.width - 2 * x
        height: Math.max(implicitHeight, drawer.px(40))
        anchors.bottom: parent.bottom
        anchors.bottomMargin: drawer.px(25)
        spacing: drawer.px(12)
        Repeater {
            model: [
                {face:"north", key:"Y", label:"Notifications"},
                {face:"west", key:"X", label:"Settings"},
                {face:"east", key:"Esc", label:drawer.controller.quickOutputOpen || drawer.controller.chromeZone === "header" ? "Back" : "Resume"},
                {face:"", key:"↑", label:"Header", show:drawer.controller.canFocusHeader}
            ]
            delegate: Row {
                required property var modelData
                visible: modelData.show !== false
                spacing: drawer.px(5)
                MenuButtonDiamond {
                    visible: modelData.face !== "" && drawer.controller.controllerCount > 0
                    uiScale: drawer.scaleFactor
                    activeFaces: [modelData.face]
                }
                MenuText {
                    visible: modelData.face === "" || drawer.controller.controllerCount === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.key; color: drawer.gold; font.pixelSize: drawer.px(14)
                }
                MenuText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label; color: drawer.muted; font.pixelSize: drawer.px(16)
                }
            }
        }
    }
}
