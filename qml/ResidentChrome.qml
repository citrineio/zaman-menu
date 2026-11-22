import QtQuick

Item {
    id: chrome
    property var controller
    readonly property real uiScale: controller.uiScale
    readonly property bool animate: controller.menuMotionActive
    readonly property bool split: controller.menuStyle === "split"
    readonly property bool ribbon: controller.menuStyle === "ribbon"
    readonly property bool ribbonHome: ribbon && controller.chromeHome
    readonly property real contentX: split ? px(280) : ribbon ? Math.max(px(24), (width - px(920)) / 2) : px(24)
    readonly property real bodyTop: px(ribbonHome ? 0 : split ? 140 : 112)
    readonly property real contentY: bodyTop + (emulatorWarning.visible ? emulatorWarning.height + px(8) : 0)
    readonly property real contentWidth: Math.max(0, Math.min(split ? px(900) : width, width - contentX - (ribbon ? contentX : px(24))))
    readonly property real contentHeight: Math.max(0, ribbon ? ribbonBar.y - contentY - px(18) : footer.y - contentY - px(26))
    function px(n) { return Math.round(n * uiScale); }
    readonly property bool inbox: controller.page === "notifications"
    readonly property bool drawerHome: controller.menuStyle === "drawer" && controller.chromeHome
    function ensureQuick(index) { if (quick.visible) quick.ensure(index); }
    function ensureRail(index) { if (rail.visible) rail.positionViewAtIndex(index, ListView.Contain); }

    Item {
        visible: !chrome.drawerHome
        x:chrome.px(24);y:chrome.px(17);width:parent.width-chrome.px(48);height:chrome.px(88)
        ZamanMark { part:"wordmark";width:chrome.px(117);height:chrome.px(25);y:chrome.px(4);ink:"#EEE1CF" }
        MenuText {
            anchors {right:bell.left;rightMargin:chrome.px(18)}
            y:chrome.px(10);text:chrome.controller.clockText;font.pixelSize:chrome.px(14);color:"#BBC6D3"
        }
        MenuHeaderActions {
            id: bell
            anchors.right: parent.right
            controller: chrome.controller
            uiScale: chrome.uiScale
        }
        MenuText {
            visible:chrome.controller.controllerWarning.length>0 && !chrome.ribbonHome
            x:0;y:chrome.px(89);width:parent.width;text:chrome.controller.controllerWarning
            color:"#EAC28D";font.pixelSize:chrome.px(13);elide:Text.ElideRight
        }
        MenuText {
            visible:!chrome.ribbonHome;x:0;y:chrome.px(53);width:parent.width
            opacity: 0.88 + 0.12 * chrome.controller.contentReveal
            text:chrome.controller.chromeTitle;elide:Text.ElideRight
            color:"#F3EEE5";font.pixelSize:chrome.px(27);font.weight:Font.DemiBold
        }
    }

    MenuText {
        id: emulatorWarning
        visible: !chrome.drawerHome && !chrome.ribbonHome && text.length > 0
        x: chrome.contentX; y: chrome.bodyTop; width: chrome.contentWidth
        text: chrome.controller.emulatorMenuNotice
        textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
        color: "#EAC28D"; font.pixelSize: chrome.px(15)
    }

    ListView {
        id:rail
        visible:chrome.split
        x:chrome.px(18);y:chrome.contentY;width:chrome.px(236);height:chrome.contentHeight
        model:chrome.controller.railEntries;currentIndex:chrome.controller.railIndex
        spacing:chrome.px(8);clip:true
        boundsBehavior:Flickable.StopAtBounds
        delegate:MenuCard {
            required property var modelData
            required property int index
            readonly property bool current:chrome.controller.railIndex === index
            readonly property bool chosen:current && chrome.controller.chromeZone === "rail" && !chrome.controller.notificationReturn
            width:rail.width;height:chrome.px(60);radius:chrome.px(11)
            uiScale: chrome.uiScale; cardFocused: chosen; cardMotion: chrome.animate
            MenuIcon {x:chrome.px(13);anchors.verticalCenter:parent.verticalCenter;width:chrome.px(24);height:width;name:modelData.icon;ink:current ? "#EAC28D" : "#AFBDCD"}
            MenuText {
                x:chrome.px(47)
                anchors.verticalCenter:parent.verticalCenter
                width:parent.width-x-chrome.px(12)
                text:modelData.label
                elide:Text.ElideRight
                color:"#F3EEE5";font.pixelSize:chrome.px(22)
            }
            MouseArea {anchors.fill:parent;enabled:!chrome.controller.shortcutBlocked;onClicked:{chrome.controller.railIndex=index;chrome.controller.showStyleCategory(modelData.key,true);}}
        }
    }
    Rectangle {
        visible:chrome.split
        x:chrome.px(264);y:chrome.contentY;width:chrome.px(3);height:chrome.contentHeight
        radius:width/2;color:"#35404D"
        Rectangle {
            visible:rail.visibleArea.heightRatio < 1
            y:parent.height * rail.visibleArea.yPosition
            width:parent.width;height:parent.height * rail.visibleArea.heightRatio
            radius:width/2;color:"#A6ACB8"
        }
    }

    QuickDrawer {
        id: quick
        anchors.fill: parent
        visible: chrome.drawerHome
        controller: chrome.controller
    }

    Row {
        id:ribbonBar
        visible:chrome.ribbon
        x:chrome.px(18);y:footer.y-height-chrome.px(8);width:parent.width-chrome.px(36)
        height:chrome.px(91);spacing:chrome.px(7)
        Repeater {
            id: ribbonTabs
            model: chrome.controller.ribbonEntries
            delegate: MenuCard {
                id: tile
                required property var modelData
                required property int index
                readonly property bool current: chrome.controller.ribbonIndex === index
                readonly property bool chosen: current && chrome.controller.chromeZone === "ribbon"
                readonly property bool opened: current && !chrome.ribbonHome && !chrome.inbox && !chrome.controller.pegasusLibraryTool
                width: (ribbonBar.width - ribbonBar.spacing * (ribbonTabs.count - 1)) / Math.max(1, ribbonTabs.count)
                height: ribbonBar.height
                radius: chrome.px(12)
                uiScale: chrome.uiScale
                cardFocused: chosen
                cardMotion: chrome.animate
                color: chosen ? "#2E3947" : opened ? "#293443" : "#202936"
                scale: chosen ? 1.018 : 1
                Behavior on scale { enabled:chrome.animate; NumberAnimation { duration:110; easing.type:Easing.OutCubic } }
                Accessible.role: Accessible.Button
                Accessible.name: modelData.label
                Accessible.focused: chosen
                Accessible.onPressAction: chrome.controller.openRibbonTab(index, true)
                MenuIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: chrome.px(12)
                    width: chrome.px(27); height: width
                    name: tile.modelData.icon
                    ink: tile.current ? "#EAC28D" : "#AFBDCD"
                }
                MenuText {
                    x: chrome.px(5); y: chrome.px(53); width: parent.width - 2 * x
                    text: tile.modelData.label
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    color: "#F3EEE5"; font.pixelSize: chrome.px(17)
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: chrome.controller.canSwitchRibbon
                    onClicked: chrome.controller.openRibbonTab(tile.index, true)
                }
            }
        }
    }
    Flow {
        id: footer
        visible: !chrome.drawerHome
        x:chrome.px(24);width:parent.width-chrome.px(48)
        anchors.bottom:parent.bottom;anchors.bottomMargin:chrome.px(9)
        height:Math.max(implicitHeight, chrome.px(29));spacing:chrome.px(19)
        Repeater {
            model:[
                {face:"south",key:"Enter",label:chrome.controller.chromeZone === "rail" ? "Adjust" : chrome.controller.page === "appearance" && chrome.controller.chromeZone !== "header" ? "Use style" : "Select"},
                {face:"east",key:"Esc",label:chrome.ribbon ? (chrome.ribbonHome && chrome.controller.chromeZone === "ribbon" ? "Resume" : "Back") : chrome.inbox || chrome.controller.notificationReturn || chrome.controller.chromeZone === "header" ? "Back" : "Back / Resume"},
                {face:"north",key:chrome.controller.editingKeyboard ? "Tab" : "Y",label:chrome.inbox ? "Clear all" : chrome.controller.editingKeyboard ? "Keyboard" : "Notifications",show:chrome.controller.editingKeyboard || !chrome.controller.shortcutBlocked},
                {face:"west",key:"X",label:chrome.inbox ? "Dismiss" : "Settings",show:chrome.inbox ? !chrome.controller.shortcutBlocked : chrome.controller.canOpenSystem},
                {face:"",key:"↑",label:"Header",show:chrome.controller.canFocusHeader},
                {face:"",key:chrome.controller.controllerCount>0 ? "L1 / R1" : "Ctrl+PgUp / PgDn",label:"Switch tab",show:chrome.ribbon && chrome.controller.canSwitchRibbon}
            ]
            delegate:Row {
                required property var modelData
                visible:modelData.show !== false
                spacing:chrome.px(7)
                MenuButtonDiamond {visible:modelData.face !== "" && chrome.controller.controllerCount>0;uiScale:chrome.uiScale;activeFaces:[modelData.face]}
                MenuText {visible:modelData.face === "" || chrome.controller.controllerCount===0;text:modelData.key;color:"#EAC28D";font.pixelSize:chrome.px(13);y:chrome.px(4)}
                MenuText {text:modelData.label;color:"#BBC6D3";font.pixelSize:chrome.px(14);y:chrome.px(4)}
            }
        }
    }
    MenuText {
        visible:!chrome.drawerHome && chrome.controller.styleNotice.length>0 && chrome.controller.page !== "appearance"
        x:chrome.contentX;y:chrome.contentY;width:chrome.contentWidth
        text:chrome.controller.styleNotice;wrapMode:Text.WordWrap;color:"#EAC28D";font.pixelSize:chrome.px(15)
    }
}
