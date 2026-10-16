import QtQuick
import QtQml.Models

Item {
    id: page
    property real uiScale: 1
    property var client
    property string selectedId: ""
    property var detail: null
    property var clearIds: []
    property bool confirming: false
    property int confirmSelected: 0
    readonly property bool blocked: confirming || detail !== null
    readonly property var records: client ? client.records.filter(record => !record.dismissed) : []
    readonly property var selected: records.find(r => r.id === selectedId) || null
    function px(n) { return Math.round(n * uiScale); }
    ListModel { id: visibleRecords }
    function sync() {
        // Preserve delegates and the nearest selected neighbor during dismissal.
        var oldIndex = 0;
        for (var i = 0; i < visibleRecords.count; ++i) if (visibleRecords.get(i).recordId === selectedId) oldIndex = i;
        for (var i = visibleRecords.count - 1; i >= 0; --i) {
            if (!records.some(record => record.id === visibleRecords.get(i).recordId)) visibleRecords.remove(i);
        }
        for (var i = 0; i < records.length; ++i) {
            var found = -1;
            for (var j = i; j < visibleRecords.count; ++j) if (visibleRecords.get(j).recordId === records[i].id) found = j;
            if (found < 0) visibleRecords.insert(i, {recordId:records[i].id, payload:records[i]});
            else {
                if (found !== i) visibleRecords.move(found, i, 1);
                visibleRecords.setProperty(i, "payload", records[i]);
            }
        }
        // IDs keep focus anchored when newer records arrive above it.
        if (!records.some(r => r.id === selectedId)) selectedId = records.length ? records[Math.min(oldIndex, records.length - 1)].id : "";
        Qt.callLater(() => {
            if (visible) history.positionViewAtIndex(Math.max(0, records.findIndex(r => r.id === selectedId)), ListView.Contain);
        });
    }
    onRecordsChanged: sync()
    function move(direction) {
        if (confirming) { confirmSelected = (confirmSelected + direction + 2) % 2; return; }
        if (detail) { details.contentY = Math.max(0, Math.min(details.contentHeight - details.height, details.contentY + direction * px(70))); return; }
        if (!records.length) return;
        var index = records.findIndex(r => r.id === selectedId);
        selectedId = records[(index + direction + records.length) % records.length].id;
        sync();
    }
    function activate() {
        if (confirming) {
            if (confirmSelected === 1) client.send({action:"clear", ids:clearIds});
            confirming = false; clearIds = []; return;
        }
        if (!detail && selected) detail = Object.assign({}, selected);
    }
    function back() {
        if (confirming) { confirming = false; clearIds = []; return true; }
        if (detail) { detail = null; return true; }
        return false;
    }
    function dismiss() {
        if (!confirming && !detail && selected && client.available) client.send({action:"dismiss", id:selectedId});
    }
    function clear() {
        if (blocked || !client.records.length || !client.available) return;
        clearIds = client.records.map(r => r.id);
        confirmSelected = 0;
        confirming = true;
    }
    function stamp(record) { return Qt.formatDateTime(new Date(record.timestamp * 1000), "ddd h:mm AP"); }

    ListView {
        id: history
        anchors.fill: parent
        visible: !page.blocked
        model: visibleRecords
        add: Transition { NumberAnimation { property:"opacity"; from:0; to:1; duration:120 } }
        remove: Transition {
            ParallelAnimation {
                NumberAnimation { property:"dismissOffset"; to:page.px(96); duration:180; easing.type:Easing.OutCubic }
                NumberAnimation { property:"opacity"; to:0; duration:180; easing.type:Easing.OutCubic }
            }
        }
        removeDisplaced: Transition { NumberAnimation { properties:"x,y"; duration:180; easing.type:Easing.OutCubic } }
        spacing: page.px(7)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
            id: notificationRow
            required property var payload
            // Keep the horizontal exit separate from ListView's row placement.
            property real dismissOffset: 0
            property bool retiring: false
            ListView.onRemove: retiring = true
            transform: Translate { x: notificationRow.dismissOffset }
            readonly property bool chosen: payload.id === page.selectedId
            width: history.width
            height: page.px(96)
            radius: page.px(12)
            color: chosen ? "#EAC28D" : "#1D2634"
            MenuIcon {
                x: page.px(14); y: page.px(20)
                width: page.px(29); height: width
                name: payload.category
                ink: parent.chosen ? "#30271E" : "#DEC09A"
            }
            Column {
                x: page.px(58); y: page.px(12)
                width: parent.width - page.px(76)
                spacing: page.px(4)
                MenuText {
                    width: parent.width
                    text: payload.title
                    font.pixelSize: page.px(22)
                    elide: Text.ElideRight
                    color: chosen ? "#211E1B" : "#ECEEF1"
                }
                MenuText {
                    width: parent.width
                    text: (payload.urgency === 2 ? "Critical · " : "") + page.stamp(payload) + (payload.source ? " · " + payload.source : "")
                    font.pixelSize: page.px(14)
                    elide: Text.ElideRight
                    color: chosen ? "#473627" : "#BBC6D3"
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: !notificationRow.retiring
                onClicked: { page.selectedId = payload.id; page.activate(); }
            }
        }
    }
    Column {
        visible: !page.records.length && !page.blocked
        width: parent.width
        spacing: page.px(15)
        MenuIcon { name:"notifications"; width:page.px(42); height:width; ink:"#DEC09A" }
        MenuText { text:"You're all caught up"; font.pixelSize:page.px(26) }
        MenuText { width:parent.width; text:page.client && page.client.error ? page.client.error : "System updates appear here."; wrapMode:Text.WordWrap; color:"#BBC6D3"; font.pixelSize:page.px(18) }
    }
    Flickable {
        id: details
        anchors.fill: parent
        visible: page.detail !== null && !page.confirming
        contentHeight: detailContent.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: detailContent
            width: parent.width
            spacing: page.px(18)
            MenuText { width:parent.width; text:page.detail ? page.detail.title : ""; wrapMode:Text.Wrap; font.pixelSize:page.px(28) }
            MenuText { width:parent.width; text:page.detail ? page.stamp(page.detail) + " · " + page.detail.source : ""; wrapMode:Text.Wrap; font.pixelSize:page.px(16); color:"#BBC6D3" }
            MenuText { width:parent.width; text:page.detail ? page.detail.body : ""; wrapMode:Text.Wrap; font.pixelSize:page.px(21) }
            MenuText { visible:page.detail !== null && page.detail.target === "transfer-pending"; text:"Open Transfer to review pending files."; width:parent.width; wrapMode:Text.Wrap; font.pixelSize:page.px(18); color:"#DEC09A" }
        }
    }
    Column {
        visible: page.confirming
        width: parent.width
        spacing: page.px(18)
        MenuText { text:"Clear notification history?"; font.pixelSize:page.px(26) }
        MenuText { width:parent.width; text:"Downloads and pending imports will continue. New notifications will stay."; wrapMode:Text.WordWrap; color:"#BBC6D3"; font.pixelSize:page.px(18) }
        Repeater {
            model: ["Cancel", "Clear history"]
            delegate: Rectangle {
                required property string modelData
                required property int index
                width: page.width; height:page.px(60); radius:page.px(12)
                color:page.confirmSelected === index ? "#EAC28D" : "#1D2634"
                MenuText { anchors.centerIn:parent; text:modelData; font.pixelSize:page.px(22); color:page.confirmSelected === index ? "#211E1B" : "#ECEEF1" }
                MouseArea { anchors.fill:parent; onClicked:{ page.confirmSelected = index; page.activate(); } }
            }
        }
    }
}
