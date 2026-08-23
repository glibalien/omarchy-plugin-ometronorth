import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Metro-North bar widget with an anchored popup panel, following the same
// pattern as erruviel.docker: all state comes from `bin/mnr-panel` — one
// process spawn per refresh — which reads MTA's GTFS-RT feed and reports the
// next trains between the configured origin and destination. The bar shows the
// next departure and turns urgent-red when the train is late; the panel lists
// the next three departures and, separately, the next three arrivals at the
// destination.
//
// Everything runs unprivileged. The only dependency is python3's stdlib; the
// GTFS-RT protobuf is decoded by the helper itself. Station picks made in the
// panel persist to ~/.local/state/omarchy/starke.mnr.json and override the
// shell.json `from`/`to` settings until changed again.
Panel {
  id: root
  moduleName: "starke.mnr"
  ipcTarget: "starke.mnr"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : "#cc6666"
  readonly property color faint: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.25)

  // Paths resolved relative to this file so the plugin works straight out of
  // `omarchy plugin add` with nothing installed on PATH.
  readonly property string panelScript: Qt.resolvedUrl("../bin/mnr-panel").toString().replace(/^file:\/\//, "")
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string stateFile: stateDir + "/starke.mnr.json"

  // ------------------------------------------------------------- settings ---
  readonly property string cfgFrom: String(setting("from", "Grand Central"))
  readonly property string cfgTo: String(setting("to", "White Plains"))
  readonly property string apiKey: String(setting("apiKey", ""))
  readonly property int lateMinutes: Math.max(1, Number(setting("lateMinutes", 5)))
  readonly property int pollSeconds: Math.max(30, Number(setting("interval", 60)))

  // Runtime route, chosen with the panel pickers and persisted in stateFile.
  // Wins over the shell.json settings when set.
  property string overrideFrom: ""
  property string overrideTo: ""
  readonly property string fromName: overrideFrom !== "" ? overrideFrom : cfgFrom
  readonly property string toName: overrideTo !== "" ? overrideTo : cfgTo

  // ---------------------------------------------------------------- state ---
  property var info: ({})
  readonly property bool okData: info.ok === true
  readonly property var trips: okData ? (info.trips || []) : []
  readonly property var nextTrip: trips.length > 0 ? trips[0] : null
  readonly property bool nextLate: nextTrip !== null && (nextTrip.depDelay || 0) >= lateMinutes * 60
  readonly property string errorText: okData ? "" : (info.error || "")
  readonly property string hintText: okData ? "" : (info.hint || "")
  readonly property bool pickerOpen: fromDrop.popupOpen || toDrop.popupOpen

  property var stations: []
  property bool queued: false

  function inMin(epoch) {
    if (!info.now || !epoch) return ""
    var m = Math.round((epoch - info.now) / 60)
    return m <= 0 ? "now" : "in " + m + " min"
  }

  function statusFor(t, arrival) {
    var delay = arrival ? (t.arrDelay || 0) : (t.depDelay || 0)
    if (delay >= lateMinutes * 60) return "+" + Math.round(delay / 60) + " min late"
    if (!arrival && t.depStatus === "Departed") return "Departed"
    return "On time"
  }

  function isLate(t, arrival) {
    var delay = arrival ? (t.arrDelay || 0) : (t.depDelay || 0)
    return delay >= lateMinutes * 60
  }

  // --------------------------------------------------------------- refresh ---
  function refresh() {
    if (pollProc.running) {
      queued = true
      return
    }
    pollProc.running = true
  }

  function updateInfo(raw) {
    // Keep the last known state across a transient bad read so the widget
    // never blinks out while the network hiccups.
    try {
      var next = JSON.parse(raw)
      if (next && typeof next === "object") info = next
    } catch (e) {}
  }

  function updateStations(raw) {
    var out = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var n = lines[i].trim()
      if (n) out.push({ value: n, label: n })
    }
    if (out.length) stations = out
  }

  function loadState(raw) {
    try {
      var s = JSON.parse(raw)
      if (s && typeof s === "object") {
        if (s.from) overrideFrom = String(s.from)
        if (s.to) overrideTo = String(s.to)
        // The startup poll may already have run against the shell.json route;
        // redo it against the restored one.
        refresh()
      }
    } catch (e) {}
  }

  function applyRoute(which, name) {
    if (which === "from") overrideFrom = name
    else overrideTo = name
    saveState()
    refresh()
  }

  function swapRoute() {
    var f = fromName, t = toName
    overrideFrom = t
    overrideTo = f
    // The pickers' internal select breaks their `value` bindings, so push the
    // swapped values in explicitly.
    fromDrop.value = t
    toDrop.value = f
    saveState()
    refresh()
  }

  function saveState() {
    if (saveProc.running) return
    saveProc.running = true
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------- processes ---
  Process {
    id: pollProc
    command: [root.panelScript, "--from", root.fromName, "--to", root.toName]
    environment: ({ "MNR_API_KEY": root.apiKey })
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
    onExited: if (root.queued) { root.queued = false; root.refresh() }
  }

  Process {
    id: stationsProc
    command: [root.panelScript, "--stations"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateStations(text) }
  }

  Process {
    id: stateLoadProc
    command: ["bash", "-c", "cat \"$1\" 2>/dev/null || true", "bash", root.stateFile]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadState(text) }
  }

  Process {
    id: saveProc
    command: ["bash", "-c", "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"",
              "bash", root.stateDir,
              JSON.stringify({ from: root.fromName, to: root.toName }),
              root.stateFile]
  }

  Component.onCompleted: {
    stationsProc.running = true
    stateLoadProc.running = true
  }

  // Background poll while closed; a quicker cadence while the panel is open.
  Timer {
    interval: root.pollSeconds * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------------- bar ---
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.nextTrip ? "\uf238 " + root.nextTrip.depLabel : "\uf238 --"
    active: root.nextLate
    dimmed: root.nextTrip === null
    tooltipText: root.okData
      ? root.fromName + " → " + root.toName
      : (root.errorText || "Metro-North: loading…")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- panel ---
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // Extra headroom while a station picker is open so its result list isn't
    // clipped by the card edge.
    contentHeight: panel.fittedContentHeight(column.implicitHeight + (root.pickerOpen ? Style.space(300) : 0))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pickerOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "s") root.swapRoute()
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(14)

          // -------------------------------------------------- hero ---
          PanelHero {
            width: parent.width
            title: "OmiRail"
            meta: root.okData
              ? root.fromName + "  →  " + root.toName
              : "Metro-North Railroad"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            iconOpacity: root.okData ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "\uf238"
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                iconText: "󰑐"
                tooltipText: "Refresh"
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          // -------------------------------------------------- errors ---
          Text {
            visible: !root.okData && root.errorText !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.errorText + (root.hintText !== "" ? "\n" + root.hintText : "")
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // -------------------------------------------------- route ---
          PanelSeparator { foreground: root.barForeground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(routeHeader.implicitHeight, swapButton.implicitHeight)

              PanelSectionHeader {
                id: routeHeader
                text: "ROUTE"
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.barForeground
                fontFamily: root.fontFamily
              }

              Button {
                id: swapButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰓡"
                text: "Swap"
                tooltipText: "Swap origin and destination (s)"
                fontSize: Style.font.caption
                bordered: true
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: root.swapRoute()
              }
            }

            SearchableDropdown {
              id: fromDrop
              width: parent.width
              label: "From"
              options: root.stations
              value: root.fromName
              placeholderText: "Search stations..."
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.applyRoute("from", v) }
            }

            SearchableDropdown {
              id: toDrop
              width: parent.width
              label: "To"
              options: root.stations
              value: root.toName
              placeholderText: "Search stations..."
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.applyRoute("to", v) }
            }
          }

          // ---------------------------------------------- departures ---
          PanelSeparator {
            visible: root.trips.length > 0
            foreground: root.barForeground
          }

          Column {
            visible: root.trips.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "DEPARTURES  ·  " + root.fromName.toUpperCase()
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.trips.slice(0, 3)
              TrainRow {
                required property var modelData
                width: parent.width
                trip: modelData
                arrival: false
              }
            }
          }

          // ------------------------------------------------ arrivals ---
          PanelSeparator {
            visible: root.trips.length > 0
            foreground: root.barForeground
          }

          Column {
            visible: root.trips.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ARRIVING AT  ·  " + root.toName.toUpperCase()
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.trips.slice(0, 3)
              TrainRow {
                required property var modelData
                width: parent.width
                trip: modelData
                arrival: true
              }
            }
          }

          // --------------------------------------------------- empty ---
          Text {
            visible: root.okData && root.trips.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No upcoming trains from " + root.fromName + " to " + root.toName +
                  ". Late at night the feed may have nothing scheduled yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // -------------------------------------------------- footer ---
          Text {
            visible: root.okData
            width: parent.width
            text: "Updated " + (root.info.updated || "") + "  ·  MTA GTFS-RT"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // One train line: big time on the left (red when late), route/track under
  // it, delay status and countdown on the right.
  component TrainRow: Item {
    id: trow
    property var trip: ({})
    property bool arrival: false

    readonly property int delay: arrival ? (trip.arrDelay || 0) : (trip.depDelay || 0)
    readonly property bool late: root.isLate(trip, arrival)
    readonly property int epoch: arrival ? (trip.arr || 0) : (trip.dep || 0)
    readonly property string label: arrival ? (trip.arrLabel || "") : (trip.depLabel || "")

    implicitHeight: Math.max(leftCol.implicitHeight, rightCol.implicitHeight)

    Column {
      id: leftCol
      anchors.left: parent.left
      anchors.right: rightCol.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        text: trow.label
        color: trow.late ? root.urgent : root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        elide: Text.ElideRight
        text: (trow.trip.route || "") +
              (!trow.arrival && trow.trip.depTrack ? "  ·  Track " + trow.trip.depTrack : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Column {
      id: rightCol
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        anchors.right: parent.right
        text: root.statusFor(trow.trip, trow.arrival)
        color: trow.late ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: trow.late
      }

      Text {
        anchors.right: parent.right
        text: root.inMin(trow.epoch)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
