// Derived from the Omarchy shell's built-in clock widget (omarchy.clock),
// Copyright (c) David Heinemeier Hansson, MIT licensed.
// https://github.com/basecamp/omarchy — see LICENSE and NOTICE.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  readonly property string nextWeekStartLabel: Qt.locale().dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Zones.
  //
  // Qt's JS engine has no `Intl` and no IANA zone support, so the offsets
  // cannot be computed in here. `date` reads the system tz database and is
  // asked once every ten minutes: an offset only moves at a DST boundary, so
  // polling per tick would be a process spawn a second to learn nothing. %Z
  // comes back too, which is why no CEST/CET table appears anywhere.
  // Which zones to show, from shell.json. Either shape works:
  //   "zones": ["Asia/Tokyo", { "tz": "America/Chicago", "name": "Chicago" }]
  readonly property var zones: Model.normalizeZoneSetting(setting("zones", null))

  // Home is discovered, never configured — see Model.probeScript. The one
  // thing the machine cannot know is what you call the place: `timedatectl`
  // says America/New_York whether you are in Atlanta or Manhattan, so
  // "homeName" renames that row and nothing else.
  readonly property string homeNameOverride: String(setting("homeName", "") || "").replace(/^\s+|\s+$/g, "")

  // Your own row in 12-hour, everything else in 24. Deliberately asymmetric:
  // the other rows exist to be matched against a time someone quoted, and
  // those are quoted on a 24-hour clock.
  readonly property bool homeHour12: String(setting("homeHour12", false)) === "true"

  property var zoneData: []
  property string homeTz: ""
  property bool zonesExpanded: false
  property int shiftMinutes: 0

  // Everything the rows draw, recomputed when the clock ticks, the shift
  // moves, or a fresh probe lands — one pass, so no two rows can disagree
  // about what "now" is mid-render.
  // Names come from config where given, from the zone itself otherwise, and
  // from "homeName" for the machine's own row.
  readonly property var zoneNames: {
    var names = ({})
    for (var i = 0; i < zones.length; i++) names[zones[i].tz] = zones[i].name
    if (root.homeTz) {
      names[root.homeTz] = root.homeNameOverride
        || names[root.homeTz]
        || Model.zoneDisplayName(root.homeTz)
    }
    return names
  }

  readonly property var zoneView: {
    var out = []
    if (!zoneData.length || !root.homeTz) return out

    var at = root.today.getTime() + root.shiftMinutes * 60000

    var home = null
    for (var i = 0; i < zoneData.length; i++)
      if (zoneData[i].tz === root.homeTz) home = zoneData[i]
    if (!home) return out
    var homeClock = Model.zoneClock(at, home.offset)

    // Sorted rather than taken in config order, so the day/night rails read
    // as one west-to-east progression and the home row sits where it belongs
    // instead of wherever it happened to be typed.
    var ordered = Model.sortByOffset(zoneData)

    for (var j = 0; j < ordered.length; j++) {
      var probe = ordered[j]
      var clock = Model.zoneClock(at, probe.offset)
      out.push({
        name: root.zoneNames[probe.tz] || Model.zoneDisplayName(probe.tz),
        home: probe.tz === root.homeTz,
        abbr: probe.abbr,
        clock: (probe.tz === root.homeTz && root.homeHour12)
          ? Model.formatClock12(clock)
          : Model.formatClock(clock),
        minuteOfDay: clock.minuteOfDay,
        daylight: Model.isDaylight(clock),
        dayShift: Model.dayShiftLabel(clock, homeClock),
        offsetLabel: probe.tz === root.homeTz
          ? ""
          : Model.relativeOffsetLabel(probe.offset, home.offset)
      })
    }
    return out
  }

  // The font is monospace, so the longest string in a column is that column's
  // width — measured in characters here and turned into pixels by one glyph's
  // advance below. Every row then shares the same three columns, which is what
  // makes the times line up on their digits instead of on their right edge.
  readonly property real zoneCharWidth: zoneCharMetric.implicitWidth

  readonly property var zoneColumns: {
    var clock = 0, day = 0, offset = 0
    for (var i = 0; i < zoneView.length; i++) {
      clock = Math.max(clock, String(zoneView[i].clock).length)
      day = Math.max(day, String(zoneView[i].dayShift).length)
      offset = Math.max(offset, String(zoneView[i].offsetLabel).length)
    }
    return { clock: clock, day: day, offset: offset }
  }

  readonly property int homeMinuteOfDay: {
    if (!zoneData.length || !root.homeTz) return 0
    for (var i = 0; i < zoneData.length; i++) {
      if (zoneData[i].tz === root.homeTz)
        return Model.zoneClock(root.today.getTime(), zoneData[i].offset).minuteOfDay
    }
    return 0
  }

  Process {
    id: zoneProbe
    running: false
    command: ["sh", "-c", Model.probeScript(root.zones)]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseZoneProbe(text)
        root.homeTz = parsed.homeTz
        root.zoneData = parsed.zones
      }
    }
  }

  // Re-probe when the zone list is edited in shell.json, which hot-reloads.
  onZonesChanged: if (!zoneProbe.running) zoneProbe.running = true

  Timer {
    // Ten minutes is far finer than DST needs and still cheap. The panel also
    // reprobes on open, so a resume from suspend never shows stale math.
    interval: 600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!zoneProbe.running) zoneProbe.running = true
  }

  function toggleZones() {
    root.zonesExpanded = !root.zonesExpanded
    if (root.zonesExpanded && !zoneProbe.running) zoneProbe.running = true
  }

  function resetShift() {
    root.shiftMinutes = 0
  }

  // Velocity, not step size, decides whether this snaps. A flick lands on the
  // half hour; a slow drag keeps every minute reachable, which is the whole
  // point — 10:15 and 10:01 have to stay reachable by hand.
  property real _lastScrubValue: 0
  property real _lastScrubAt: 0
  property real _scrubVelocity: 0

  readonly property real scrubFastThreshold: 0.30   // minutes travelled per ms

  function scrubTo(next) {
    var now = Date.now()
    var elapsed = now - root._lastScrubAt

    if (root._lastScrubAt > 0 && elapsed > 0) {
      var instant = Math.abs(next - root._lastScrubValue) / elapsed
      // Smoothed, so one jittery sample cannot flip the feel mid-drag.
      root._scrubVelocity = root._scrubVelocity * 0.6 + instant * 0.4
    }
    root._lastScrubValue = next
    root._lastScrubAt = now

    var value = root._scrubVelocity > root.scrubFastThreshold
      ? Model.snapShift(next, root.homeMinuteOfDay)
      : next
    root.shiftMinutes = Model.clampShift(value)
  }

  function settleScrub(next) {
    if (root._scrubVelocity > root.scrubFastThreshold)
      root.shiftMinutes = Model.clampShift(Model.snapShift(root.shiftMinutes, root.homeMinuteOfDay))
    root._scrubVelocity = 0
    root._lastScrubAt = 0
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    // Zones collapse on every open: a normal click is a look at the calendar,
    // and a scrub left over from last time would be actively misleading.
    root.zonesExpanded = false
    root.shiftMinutes = 0
    if (!zoneProbe.running) zoneProbe.running = true
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // Locale short day names, trimmed of the trailing period some locales
  // carry ("man." -> "MAN") so the header row stays a clean band of caps.
  function weekdayLabel(weekday) {
    return String(Qt.locale().dayName(weekday, Locale.ShortFormat)).replace(/\.$/, "").toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              Text {
                id: yearLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet.
                      color: "transparent"
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        anchors.centerIn: parent
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- Zones. Collapsed by default: opening the clock is almost
          //      always a glance at the calendar, and a converter nobody
          //      asked for would push the grid down every single time.
          Item {
            width: parent.width
            height: zoneColumn.y + zoneColumn.height

            // One glyph's advance. The bar font is monospace, so this is the
            // width of every character, and a column of N characters is
            // exactly N of these — no guessing at pixel widths that would
            // break the moment the font or its size changed.
            Text {
              id: zoneCharMetric
              visible: false
              text: "0"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              id: zoneColumn
              y: Style.space(10)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(2)

              PanelSeparator {
                width: parent.width
                foreground: root.contentForeground
              }

              // The header is the control: label on the left, and on the
              // right the shift, which stays visible while collapsed so a
              // panel left scrubbed cannot quietly lie about the time.
              Item {
                width: parent.width
                height: Math.max(zonesHeader.implicitHeight, Style.space(20))

                PanelSectionHeader {
                  id: zonesHeader
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.zonesExpanded ? "󰅃  " : "󰅀  ") + "ZONES"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily

                  // Parented to the label rather than the row: ToolTip centres
                  // itself on its parent, and a full-width parent put this
                  // squarely on top of "AUGUST 2026". The month chevrons read
                  // cleanly for the same reason — theirs hangs off a 22px
                  // button, not the row it sits in.
                  PanelToolTip {
                    visible: zonesToggleMouse.containsMouse
                    text: root.zonesExpanded ? "Hide time zones" : "Show time zones"
                    fontFamily: root.contentFontFamily
                  }
                }

                Text {
                  id: shiftLabel
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.formatShift(root.shiftMinutes)
                  color: root.shiftMinutes === 0
                    ? Qt.darker(root.contentForeground, 1.5)
                    : Style.selectedStateColor(root.contentForeground, Color.accent)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                // Sized to the label, not the row. The same shape the hero
                // date uses above: the words are the button, so the pointer
                // only changes and the tooltip only opens over the thing that
                // actually does something.
                MouseArea {
                  id: zonesToggleMouse
                  x: zonesHeader.x
                  y: zonesHeader.y
                  width: zonesHeader.width
                  height: zonesHeader.height
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleZones()
                }
              }

              // Rows and scrubber. Height is driven rather than animated on
              // visibility alone, so the popup grows and shrinks in one move
              // instead of snapping.
              Item {
                width: parent.width
                clip: true
                height: root.zonesExpanded ? zoneBody.height : 0
                opacity: root.zonesExpanded ? 1 : 0

                Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 140 } }

                Column {
                  id: zoneBody
                  width: parent.width
                  spacing: Style.space(1)

                  Repeater {
                    model: root.zoneView

                    Item {
                      required property var modelData
                      width: zoneBody.width
                      height: Style.space(34)

                      Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: -Style.space(6)
                        anchors.rightMargin: -Style.space(6)
                        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                        color: Style.selectedStateColor(root.contentForeground, Color.accent)
                        // Hover only. Home is carried by weight instead of a
                        // filled box, which fought the calendar's own today
                        // marker for attention.
                        opacity: zoneMouse.containsMouse ? 0.06 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                      }

                      // Sun or moon, in the theme's own foreground rather
                      // than a colour of its own: it answers "is anyone
                      // awake there", which a flag never could.
                      Text {
                        id: dayNightGlyph
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.topMargin: Style.space(1)
                        width: Style.space(16)
                        text: modelData.daylight ? "󰖙" : "󰖔"
                        color: modelData.daylight
                          ? root.contentForeground
                          : Qt.darker(root.contentForeground, 1.6)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        id: zoneName
                        anchors.left: dayNightGlyph.right
                        anchors.leftMargin: Style.space(4)
                        anchors.top: parent.top
                        text: modelData.name + "  (" + modelData.abbr + ")"
                        color: modelData.home
                          ? root.contentForeground
                          : Qt.darker(root.contentForeground, 1.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: modelData.home
                      }

                      Text {
                        id: zoneOffsetLabel
                        anchors.right: parent.right
                        anchors.top: parent.top
                        width: root.zoneColumns.offset * root.zoneCharWidth
                        horizontalAlignment: Text.AlignRight
                        text: modelData.offsetLabel
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      // Its own cell rather than tacked onto the time, so a
                      // "+1" on one row cannot shove that row's clock out of
                      // line with the rest.
                      Text {
                        id: zoneDayShift
                        anchors.right: zoneOffsetLabel.left
                        anchors.rightMargin: root.zoneColumns.offset > 0 ? Style.space(8) : 0
                        anchors.top: parent.top
                        width: root.zoneColumns.day * root.zoneCharWidth
                        horizontalAlignment: Text.AlignRight
                        text: modelData.dayShift
                        color: Style.selectedStateColor(root.contentForeground, Color.accent)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        id: zoneTime
                        anchors.right: zoneDayShift.left
                        anchors.rightMargin: root.zoneColumns.day > 0 ? Style.space(8) : 0
                        anchors.top: parent.top
                        width: root.zoneColumns.clock * root.zoneCharWidth
                        horizontalAlignment: Text.AlignRight
                        text: modelData.clock
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: modelData.home
                      }

                      // The zone's own 24 hours: midnight to midnight, lit
                      // between 06:00 and 20:00, with the accent marking
                      // where it stands. The same rail the year uses above.
                      Rectangle {
                        id: dayRail
                        anchors.left: zoneName.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(5)
                        height: Style.space(6)
                        radius: Style.cornerRadius > 0 ? height / 2 : 0
                        color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                       root.contentForeground.b, 0.10)
                        clip: true

                        Rectangle {
                          x: parent.width * 0.25
                          width: parent.width * (14 / 24)
                          height: parent.height
                          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                         root.contentForeground.b, 0.10)
                        }

                        Rectangle {
                          width: Math.max(2, Style.space(2))
                          height: parent.height + Style.space(4)
                          y: -Style.space(2)
                          radius: 1
                          color: Style.selectedStateColor(root.contentForeground, Color.accent)
                          x: Math.max(0, Math.min(parent.width - width,
                               parent.width * (modelData.minuteOfDay / 1440) - width / 2))

                          Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        }
                      }

                      MouseArea {
                        id: zoneMouse
                        anchors.fill: parent
                        hoverEnabled: true
                      }
                    }
                  }

                  Item { width: 1; height: Style.space(6) }

                  // Magnetic scrubbing. The slider itself is plain minutes;
                  // the snapping lives in onMoved, because whether to snap
                  // depends on how fast the pointer is travelling, not on
                  // where it landed.
                  PanelSlider {
                    id: zoneScrub
                    width: zoneBody.width
                    bar: root.bar
                    minimum: -720
                    maximum: 720
                    step: Model.ZONE_DETENT
                    integer: true
                    // No progress fill: this slider measures a distance from
                    // NOW in both directions, and a bar growing from the left
                    // edge would read as "50% of something" instead.
                    fillColor: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "#333"
                    value: root.shiftMinutes
                    tickCount: 25
                    onMoved: function(next) { root.scrubTo(next) }
                    onReleased: function(next) { root.settleScrub(next) }
                    onRightClicked: root.resetShift()
                  }

                  Item {
                    width: zoneBody.width
                    height: scrubHint.implicitHeight + Style.space(2)

                    Text {
                      id: scrubHint
                      anchors.left: parent.left
                      text: "−12H"
                      color: Qt.darker(root.contentForeground, 1.8)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: root.shiftMinutes === 0 ? "NOW" : "RESET"
                      color: resetMouse.containsMouse
                        ? Style.hoverStateColor(root.contentForeground, Color.accent)
                        : Qt.darker(root.contentForeground, 1.8)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1

                      MouseArea {
                        id: resetMouse
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        hoverEnabled: root.shiftMinutes !== 0
                        cursorShape: Qt.PointingHandCursor
                        enabled: root.shiftMinutes !== 0
                        onClicked: root.resetShift()
                      }
                    }

                    Text {
                      anchors.right: parent.right
                      text: "+12H"
                      color: Qt.darker(root.contentForeground, 1.8)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }
                  }
                }
              }
            }
          }

        }
      }
    }
  }
}
