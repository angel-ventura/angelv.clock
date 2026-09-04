// Derived from the Omarchy shell's built-in clock widget (omarchy.clock),
// Copyright (c) David Heinemeier Hansson, MIT licensed.
// https://github.com/basecamp/omarchy — see LICENSE and NOTICE.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The settings window: everything this plugin used to need a text editor for.
//
// A real toplevel window rather than a view inside the clock popup. The popup
// is capped to the width of the month grid — around 420 logical pixels — which
// is not somewhere a searchable zone picker or a pasted iCal URL can live, and
// its dropdowns have nowhere to open downward on a short screen.
//
// It is a second entry point of the same plugin ("panel" alongside
// "bar-widget"), so it is a separate QML instance from the popup and shares no
// state with it. Both ends read the same two files instead:
//
//   shell.json      the widget's own inline entry, through the shell's
//                   updateEntryInline() — the same call persistSettings() in
//                   Panel.qml already makes
//   calendars.json  through fetch-events.py, never written from QML: the 0600
//                   atomic replace belongs in one place, and the file holds a
//                   bearer token
//
// Every control writes on change. There is no Save button because there is no
// draft — the popup picks changes up the next time it opens, which is the
// contract hand-editing the files always had.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool closingFromHost: false

  readonly property string widgetId: "angelv.clock"

  // The widget's whole shell.json entry, held as one object. updateEntryInline
  // replaces the entry wholesale rather than merging, so writing a partial one
  // here would silently drop every key this window does not know about.
  property var entry: ({})

  // calendars.json, as read back from fetch-events.py.
  property var calendars: []

  property var zoneList: []

  // Whatever this system actually closes a window with. Asserting "Super+Q"
  // is wrong the moment somebody rebinds it, and this is a window precisely so
  // that the key works on it -- so it is worth getting right rather than
  // guessing. Empty until read, and the footer says "your close-window key"
  // until then.
  property string closeKeyLabel: ""
  property string tab: "calendars"

  // Nothing is written while this is false.
  //
  // The shell's controls emit their change signal while their bindings settle,
  // not only when a person moves them -- opening the window once wrote
  // settings that nobody had chosen. A settings window
  // that edits the config by being looked at is worse than no settings window,
  // so writes are gated until the tree has stopped moving, and put() ignores a
  // value that already matches what is stored.
  property bool ready: false

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    return path.replace(/\/$/, "")
  }

  // Fitted to the screen it is about to open on, before it opens.
  function sizeWindow() {
    var screen = (Quickshell.screens && Quickshell.screens.length > 0)
      ? Quickshell.screens[0] : null
    var sw = screen && screen.width > 0 ? screen.width : 1920
    var sh = screen && screen.height > 0 ? screen.height : 1080
    window.implicitWidth = Math.max(520, Math.min(900, Math.round(sw * 0.42)))
    window.implicitHeight = Math.max(420, Math.min(820, Math.round(sh * 0.62)))
  }

  function open(payloadJson) {
    root.ready = false
    root.sizeWindow()
    root.closingFromHost = false
    root.loadEntry()
    root.loadCalendars()
    if (root.zoneList.length === 0) zoneListProc.running = true
    if (root.closeKeyLabel === "") bindsProc.running = true
    window.visible = true
    settleTimer.restart()
  }

  function close() {
    root.ready = false
    settleTimer.stop()
    root.closingFromHost = true
    window.visible = false
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.ready = true
  }

  // ---- shell.json ---------------------------------------------------------

  function loadEntry() {
    var config = root.shell ? root.shell.shellConfig : null
    var found = null
    if (config && config.bar && config.bar.layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length && !found; s++) {
        var arr = config.bar.layout[sections[s]] || []
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && String(arr[i].id) === root.widgetId) { found = arr[i]; break }
        }
      }
    }
    // A deep copy: the shell's own config object must not be edited in place.
    root.entry = found ? JSON.parse(JSON.stringify(found)) : ({ id: root.widgetId })
  }

  function setting(name, fallback) {
    var value = root.entry ? root.entry[name] : undefined
    return (value === undefined || value === null) ? fallback : value
  }

  function isUnset(name) {
    var value = root.entry ? root.entry[name] : undefined
    return value === undefined || value === null
  }

  function put(name, value) {
    if (!root.ready) return
    // A control that re-emits its current value has nothing to say.
    var current = root.entry ? root.entry[name] : undefined
    if (JSON.stringify(current) === JSON.stringify(value)) return
    var next = JSON.parse(JSON.stringify(root.entry || {}))
    if (value === undefined) delete next[name]
    else next[name] = value
    next.id = root.widgetId
    root.entry = next
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.widgetId, next)
  }

  // ---- calendars.json -----------------------------------------------------

  function loadCalendars() {
    getConfigProc.buffer = ""
    getConfigProc.running = true
  }

  function saveCalendars(next) {
    if (!root.ready) return
    root.calendars = next
    saveConfigProc.running = true
  }

  function mutateCalendar(index, key, value) {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    if (index < 0 || index >= next.length) return
    next[index][key] = value
    root.saveCalendars(next)
  }

  function addCalendar() {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    next.push({ name: "New calendar", url: "", color: "#4A90E2", enabled: true })
    root.saveCalendars(next)
  }

  function removeCalendar(index) {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    if (index < 0 || index >= next.length) return
    next.splice(index, 1)
    root.saveCalendars(next)
  }

  // Clears the keys one tab owns, and nothing else. There is deliberately no
  // reset for the calendars: a feed URL is a secret that exists nowhere else
  // once this file is gone, and "reset" is not a word anyone reads carefully
  // enough to risk that on.
  readonly property var clockKeys: ["hour12", "weekStartDay"]
  readonly property var zoneKeys: ["zones", "homeName", "homeHour12"]
  readonly property var calendarKeys: ["syncIntervalMinutes", "notifyUpcomingEvents",
    "notifyMinutesBefore", "meetingHandler"]

  function resetCurrentTab() {
    if (root.tab === "clock") root.resetKeys(root.clockKeys)
    else if (root.tab === "zones") root.resetKeys(root.zoneKeys)
    else root.resetKeys(root.calendarKeys)
  }

  readonly property string resetHint: root.tab === "clock"
    ? "Reset the clock settings on this tab"
    : (root.tab === "zones" ? "Reset the zone settings on this tab"
                            : "Reset the calendar settings on this tab — your feeds are kept")

  function resetKeys(keys) {
    if (!root.ready) return
    var next = JSON.parse(JSON.stringify(root.entry || {}))
    for (var i = 0; i < keys.length; i++) delete next[keys[i]]
    next.id = root.widgetId
    root.entry = next
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.widgetId, next)
  }

  // ---- zones --------------------------------------------------------------

  // A zone is stored either as a bare "Area/City" or as { tz, name } when it
  // carries a label. The popup reads both; this normalises only for editing.
  function zonesAsPairs() {
    var zones = root.setting("zones", [])
    var out = []
    for (var i = 0; i < zones.length; i++) {
      var z = zones[i]
      if (typeof z === "string") out.push({ tz: z, name: "" })
      else out.push({ tz: String(z && z.tz ? z.tz : ""), name: String(z && z.name ? z.name : "") })
    }
    return out
  }

  function writeZones(list) {
    var out = []
    for (var i = 0; i < list.length; i++)
      out.push(list[i].name ? { tz: list[i].tz, name: list[i].name } : list[i].tz)
    root.put("zones", out)
  }

  function addZone(tz) {
    if (!tz) return
    var list = root.zonesAsPairs()
    for (var i = 0; i < list.length; i++) if (list[i].tz === tz) return
    list.push({ tz: tz, name: "" })
    root.writeZones(list)
  }

  function removeZone(index) {
    var list = root.zonesAsPairs()
    if (index < 0 || index >= list.length) return
    list.splice(index, 1)
    root.writeZones(list)
  }

  function renameZone(index, name) {
    var list = root.zonesAsPairs()
    if (index < 0 || index >= list.length) return
    list[index].name = String(name || "")
    root.writeZones(list)
  }

  // ---- processes ----------------------------------------------------------

  Process {
    id: getConfigProc
    property string buffer: ""
    command: ["python3", root.pluginDir + "/fetch-events.py", "--get-config"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (data) { getConfigProc.buffer += data }
    }
    onExited: function (code, status) {
      var parsed = []
      try {
        var value = JSON.parse(getConfigProc.buffer)
        if (Array.isArray(value)) parsed = value
      } catch (e) { /* an unreadable config leaves the list empty */ }
      root.calendars = parsed
    }
  }

  // The payload goes over stdin, never argv: a private iCal URL is a bearer
  // credential, and argv is readable by anything that can list /proc.
  Process {
    id: saveConfigProc
    command: ["python3", root.pluginDir + "/fetch-events.py", "--save-config"]
    stdinEnabled: true
    onStarted: {
      saveConfigProc.write(JSON.stringify(root.calendars) + "\n")
      saveConfigProc.stdinEnabled = false
    }
  }

  // Omarchy routes its binds through a Lua dispatcher, so a bind cannot be
  // found by looking for the killactive dispatcher -- but it carries the
  // human-readable description the bind was declared with, and Omarchy's is
  // "Close window". A rebind keeps that description; anything else falls back.
  Process {
    id: bindsProc
    property string buffer: ""
    command: ["hyprctl", "binds", "-j"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (data) { bindsProc.buffer += data }
    }
    onExited: function (code, status) {
      var label = ""
      try {
        var binds = JSON.parse(bindsProc.buffer)
        for (var i = 0; i < binds.length; i++) {
          if (String(binds[i].description || "").toLowerCase() !== "close window") continue
          // Hyprland's modmask is the Wayland one: shift 1, ctrl 4, alt 8,
          // super 64. Anything else is not worth naming in a hint.
          var mods = []
          var mask = Number(binds[i].modmask) || 0
          if (mask & 64) mods.push("Super")
          if (mask & 4) mods.push("Ctrl")
          if (mask & 8) mods.push("Alt")
          if (mask & 1) mods.push("Shift")
          var key = String(binds[i].key || "")
          if (!key) continue
          if (key.length === 1) key = key.toUpperCase()
          mods.push(key)
          label = mods.join("+")
          break
        }
      } catch (e) { /* no hyprctl, or a shape we do not know: fall back */ }
      root.closeKeyLabel = label
    }
  }

  Process {
    id: zoneListProc
    property string buffer: ""
    command: ["timedatectl", "list-timezones"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (data) { zoneListProc.buffer += data }
    }
    onExited: function (code, status) {
      var lines = zoneListProc.buffer.split("\n")
      var out = []
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line) out.push(line)
      }
      root.zoneList = out
    }
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Clock, Zones & Calendar — Settings"
    color: Color.background

    // Sized from the screen rather than fixed, so this is not a window that
    // only fits the machine it was written on. Clamped at both ends: small
    // enough for a 768px laptop with a bar on it, and not so wide on a 4K
    // panel that a form of short rows is stretched across it.
    //
    // Assigned in open() before the window is shown rather than bound, so it
    // maps at its final size and a compositor centring rule has the real size
    // to work from.
    //
    // Screen dimensions come back in logical pixels, so this is already
    // correct on a scaled display: a 2560x1440 panel at scale 1.25 reports
    // 2048x1152 and gets a window sized for what the user actually sees.
    //
    // Deliberately not left to a Hyprland `size` rule: a percentage there is
    // silently ignored, with no configerror to say so, and a plugin should fit
    // the screen without anyone writing a window rule first.
    implicitWidth: 760
    implicitHeight: 700
    minimumSize: Qt.size(520, 420)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell
          && typeof root.shell.hide === "function")
        root.shell.hide(root.widgetId)
    }

    ConfirmDialog {
      id: resetDialog
      anchors.fill: parent
      // Each message says what survives as well as what goes. The calendars
      // one matters most: the feed list is not settings, it is a credential
      // that exists nowhere else, so no button in here deletes it.
      message: root.tab === "clock"
        ? "Reset clock settings?\n\nAgenda times and week start go back to their "
          + "defaults. Your zones and calendars are not touched."
        : (root.tab === "zones"
          ? "Reset zone settings?\n\nRemoves every zone you have added, along with your "
            + "home label. Your calendars are not touched."
          : "Reset calendar settings?\n\nSync interval, reminders and where links open go "
            + "back to their defaults. Your calendar feeds are kept — remove those one at a time.")
      confirmText: "Reset"
      onConfirmed: root.resetCurrentTab()
    }

    FocusScope {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }

      Row {
        id: tabRow
        spacing: Style.space(6)

        Button {
          text: "Calendars"
          bordered: true
          selected: root.tab === "calendars"
          onClicked: root.tab = "calendars"
        }
        Button {
          text: "Zones"
          bordered: true
          selected: root.tab === "zones"
          onClicked: root.tab = "zones"
        }
        Button {
          text: "Clock"
          bordered: true
          selected: root.tab === "clock"
          onClicked: root.tab = "clock"
        }
      }

      // Right of the tabs, because it acts on whichever tab is showing. An
      // icon rather than a word so it cannot be mistaken for a normal action,
      // and a tooltip that names what it clears before you click it.
      Button {
        anchors.right: parent.right
        anchors.top: parent.top
        // A word, not a glyph. The obvious icon for this (nf-md-backup-restore,
        // U+F0455) draws as notdef here even though the font's cmap carries it
        // and its neighbours render -- and a plugin cannot assume anything
        // about the font on someone else's machine anyway. The tooltip says
        // which settings go.
        text: "Reset"
        tooltipText: root.resetHint
        bordered: true
        onClicked: resetDialog.opened = true
      }

      PanelSeparator {
        id: tabRule
        anchors.top: tabRow.bottom
        anchors.topMargin: Style.space(10)
        width: parent.width
        foreground: Color.foreground
      }

      // A real window, so Super+Q closes this and not whatever is behind it.
      // Said out loud because the alternative -- a layer-shell overlay, which
      // is what most shell settings panels are -- gets that wrong, and the
      // habit it teaches is hard to unlearn.
      Row {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Esc or " + (root.closeKeyLabel !== "" ? root.closeKeyLabel : "your close-window key")
            + " closes this window · changes save as you make them"
          color: Qt.darker(Color.foreground, 1.9)
          font.pixelSize: Style.font.caption
        }
      }

      Flickable {
        id: scroll
        anchors.top: tabRule.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(10)
        contentWidth: width
        contentHeight: body.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: body
          width: scroll.width
          spacing: Style.space(14)

          // --------------------------------------------------- calendars ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "calendars"

            PanelSectionHeader {
              text: "FEEDS"
              foreground: Color.foreground
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "A Google \"secret address in iCal format\", or an Apple published "
                + "webcal:// link. Read-only — nothing here is written back to a "
                + "calendar. The file is kept 0600 because the URL is a password."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.calendars

              Rectangle {
                id: calRow
                required property var modelData
                required property int index

                // The URL is a bearer credential: anyone holding it can read
                // the calendar, indefinitely, without signing in to anything.
                // So it stays masked until asked for, and a screenshot of this
                // window does not hand the calendar away. Found the hard way
                // while screenshotting this very row.
                property bool urlRevealed: false

                width: body.width
                height: calBody.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: Style.spacing.hairline
                border.color: Qt.darker(Color.foreground, 2.4)

                Column {
                  id: calBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    TextField {
                      width: calBody.width * 0.34
                      text: String(calRow.modelData.name || "")
                      placeholderText: "Name"
                      onEditingFinished: root.mutateCalendar(calRow.index, "name", text)
                    }

                    TextField {
                      id: colorField
                      width: calBody.width * 0.22
                      text: String(calRow.modelData.color || "#4A90E2")
                      placeholderText: "#RRGGBB"
                      onEditingFinished: root.mutateCalendar(calRow.index, "color", text)
                    }

                    // The swatch reads the field as it is typed, not the saved
                    // value, so a wrong code shows itself before it is
                    // committed. A code QML cannot parse would throw, so it is
                    // checked first and the swatch goes hollow instead --
                    // which is also the only signal that the code is bad.
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(20)
                      height: Style.space(20)
                      radius: Style.cornerRadius > 0 ? width / 2 : 0
                      readonly property bool valid: /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(colorField.text)
                      color: valid ? colorField.text : "transparent"
                      border.width: Style.spacing.hairline
                      border.color: valid ? Qt.darker(Color.foreground, 2.4)
                        : Qt.darker(Color.foreground, 1.4)

                      Text {
                        anchors.centerIn: parent
                        visible: !parent.valid
                        text: "?"
                        color: Qt.darker(Color.foreground, 1.4)
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: calRow.modelData.enabled !== false
                      onToggled: root.mutateCalendar(calRow.index, "enabled",
                        calRow.modelData.enabled === false)
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Remove"
                      bordered: true
                      onClicked: root.removeCalendar(calRow.index)
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    TextField {
                      width: calBody.width - revealButton.width - Style.space(8)
                      password: !calRow.urlRevealed
                      text: String(calRow.modelData.url || "")
                      placeholderText: "https://calendar.google.com/calendar/ical/…/basic.ics"
                      onEditingFinished: root.mutateCalendar(calRow.index, "url", text)
                    }

                    Button {
                      id: revealButton
                      anchors.verticalCenter: parent.verticalCenter
                      text: calRow.urlRevealed ? "Hide" : "Show"
                      bordered: true
                      onClicked: calRow.urlRevealed = !calRow.urlRevealed
                    }
                  }
                }
              }
            }

            Button {
              text: "Add calendar"
              bordered: true
              onClicked: root.addCalendar()
            }

            PanelSeparator {
              width: parent.width
              foreground: Color.foreground
            }

            PanelSectionHeader {
              text: "SYNC"
              foreground: Color.foreground
            }

            NumberField {
              label: "Minutes between syncs (0 is manual only)"
              value: root.setting("syncIntervalMinutes", 15)
              from: 0
              to: 720
              onModified: function (v) { root.put("syncIntervalMinutes", v) }
            }

            Row {
              spacing: Style.space(10)

              ToggleSwitch {
                id: notifyToggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.setting("notifyUpcomingEvents", true) !== false
                onToggled: root.put("notifyUpcomingEvents", !notifyToggle.checked)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Remind me before an event starts"
                color: Color.foreground
                font.pixelSize: Style.font.body
              }
            }

            Dropdown {
              label: "When to remind"
              value: String(root.setting("notifyMinutesBefore", "staged"))
              options: ["staged", "1", "5", "10", "15", "30", "60"]
              onChanged: function (v) { root.put("notifyMinutesBefore", v) }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "\"staged\" nudges three times — 10, 5 and 1 minutes before. "
                + "A number nudges once, that many minutes before. Either way each "
                + "event notifies once per stage, and all-day events never do."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            Dropdown {
              label: "Open meetings and calendar links in"
              value: String(root.setting("meetingHandler", "webapp"))
              options: ["webapp", "browser"]
              onChanged: function (v) { root.put("meetingHandler", v) }
            }
          }

          // ------------------------------------------------------- zones ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "zones"

            PanelSectionHeader {
              text: "HOME"
              foreground: Color.foreground
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Your own zone is detected from the system and is never listed below. "
                + "Rows sort by UTC offset, west to east, whatever order you add them in."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: body.width * 0.55
              text: String(root.setting("homeName", ""))
              placeholderText: "Label for your own row"
              onEditingFinished: root.put("homeName", text)
            }

            Row {
              spacing: Style.space(10)

              ToggleSwitch {
                id: homeHour12Toggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.setting("homeHour12", false) === true
                onToggled: root.put("homeHour12", !homeHour12Toggle.checked)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Show my own row in 12-hour time"
                color: Color.foreground
                font.pixelSize: Style.font.body
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: Color.foreground
            }

            PanelSectionHeader {
              text: "ZONES"
              foreground: Color.foreground
            }

            Repeater {
              model: root.zonesAsPairs()

              Row {
                id: zoneRow
                required property var modelData
                required property int index

                width: body.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: body.width * 0.36
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: zoneRow.modelData.tz
                  color: Color.foreground
                  font.pixelSize: Style.font.body
                }

                TextField {
                  width: body.width * 0.3
                  text: zoneRow.modelData.name
                  placeholderText: "Label (optional)"
                  onEditingFinished: root.renameZone(zoneRow.index, text)
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Remove"
                  bordered: true
                  onClicked: root.removeZone(zoneRow.index)
                }
              }
            }

SearchableDropdown {
              width: body.width * 0.62
              label: "Add a zone"
              triggerLabel: "Add a zone"
              value: ""
              options: root.zoneList
              placeholderText: "Search time zones…"
              emptyText: "No matching zone"
              onChanged: function (v) { root.addZone(v) }
            }
          }

          // ------------------------------------------------------- clock ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "clock"

            PanelSectionHeader {
              text: "CALENDAR"
              foreground: Color.foreground
            }

            Dropdown {
              label: "Agenda times"
              value: root.isUnset("hour12") ? "follow locale"
                : (root.setting("hour12", false) === true ? "12-hour" : "24-hour")
              options: ["follow locale", "12-hour", "24-hour"]
              onChanged: function (v) {
                if (v === "follow locale") root.put("hour12", undefined)
                else root.put("hour12", v === "12-hour")
              }
            }

            // Unset means the locale decides, exactly as the popup reads it --
            // and for a US locale that is Sunday, not Monday. Offering only
            // Monday and Sunday would have shown the wrong one as current and
            // then written it.
            //
            // Stored as a weekday *name*, which is the form the popup's own
            // `w` toggle writes. coerceWeekStart() takes a number too, but two
            // spellings of one setting in one file is how they drift.
            Dropdown {
              label: "Week starts on"
              value: {
                var raw = String(root.setting("weekStartDay", "")).toLowerCase()
                if (raw === "monday" || raw === "mon" || raw === "1") return "Monday"
                if (raw === "sunday" || raw === "sun" || raw === "0") return "Sunday"
                return "follow locale"
              }
              options: ["follow locale", "Monday", "Sunday"]
              onChanged: function (v) {
                if (v === "follow locale") root.put("weekStartDay", undefined)
                else root.put("weekStartDay", v.toLowerCase())
              }
            }


          }
        }
      }
    }
  }
}
