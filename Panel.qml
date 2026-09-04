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

  // Memento mori, on by default so this widget behaves like the upstream clock
  // it was forked from. "mementoMori": false in this widget's shell.json entry
  // takes it out — the life bar and the double-tap on the year bar that reveals
  // it — for anyone who would rather not be reminded. Default true, so only an
  // explicit false counts.
  readonly property bool mementoMori: String(setting("mementoMori", true)) !== "false"
  readonly property int birthYear: mementoMori ? Model.parseBirthYear(setting("birthYear", 0), today.getFullYear()) : 0
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

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
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
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

  readonly property string helperPath:
    Qt.resolvedUrl("fetch-events.py").toString().replace(/^file:\/\//, "")

  // Neither file below is read by the shell itself.
  //
  // FileView has no size ceiling and follows symlinks, so FileView.text() on a
  // path the shell does not own pulls in whatever is behind it. Measured: a
  // 208 MB file takes the Quickshell process to 1.26 GB and crashes it, which
  // takes the whole bar down, not just this widget. Both of these paths sit in
  // the user's own directories where any other program can replace them with a
  // symlink or something enormous.
  //
  // So they are watchers, nothing more. A FileView that is never asked for
  // text() materialises nothing -- the same 208 MB file costs 4 MB when it is
  // only watched. The bytes come instead from `fetch-events.py --read`, which
  // opens both files through their directory fd with O_NOFOLLOW, rejects
  // anything that is not a regular file this user owns, and refuses one over
  // its cap. Same guarantees the fetcher already applies to a downloaded feed.

  // The feed list is the user's own file and is meant to be hand-editable, so
  // a save from any editor re-syncs without the panel being reopened.
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/calendars.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readPluginFiles()
    onFileChanged: {
      root.readPluginFiles()
      root.syncCalendars(true)
    }
    // No calendars.json is the ordinary case for a clock that is only ever a
    // clock: nothing to read, nothing to sync, and no helper spawned at all.
    onLoadFailed: root.configuredFeeds = []
  }

  // Written atomically by fetch-events.py, under a name of this widget's own
  // so a co-installed calendar plugin cannot clobber it.
  FileView {
    id: eventsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/angelv-clock-events.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readPluginFiles()
    onFileChanged: root.readPluginFiles()
  }

  // Both watchers fire on the same sync, so reads are coalesced rather than
  // spawning the reader twice for one write.
  property bool pendingRead: false

  Timer {
    id: readDebounce
    interval: 120
    onTriggered: {
      if (readProc.running) {
        root.pendingRead = true
        return
      }
      readProc.running = true
    }
  }

  function readPluginFiles() {
    readDebounce.restart()
  }

  Process {
    id: readProc
    command: ["python3", root.helperPath, "--read"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyPluginFiles(text)
        if (root.pendingRead) {
          root.pendingRead = false
          readDebounce.restart()
        }
      }
    }
  }

  Process {
    id: fetchProc
    command: ["python3", root.helperPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.syncing = false
        root.readPluginFiles()
      }
    }
  }

  Process { id: notifyProc }
  Process { id: openUrlProc }

  // Runs whether or not the popup is open — a reminder that only fired while
  // you were already looking at the calendar would be pointless.
  Timer {
    interval: Math.max(300000, root.syncIntervalMinutes * 60000)
    repeat: true
    running: root.calendarSync && root.syncIntervalMinutes > 0
    onTriggered: root.syncCalendars(false)
  }

  // 30s rather than a minute, so a stage is never stepped straight over.
  Timer {
    interval: 30000
    repeat: true
    running: root.calendarSync && root.notifyUpcomingEvents
    onTriggered: root.checkUpcomingNotifications()
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

  // A wheel notch and a track click both arrive as a single `moved` followed
  // immediately by `released`; a drag arrives as a stream of them. So one
  // move means the input was discrete, and discrete input always lands on a
  // detent — there is no such thing as scrolling "slowly" to 10:07. The
  // velocity rule below then only has to judge real drags.
  property int _scrubMoves: 0

  readonly property real scrubFastThreshold: 0.30   // minutes travelled per ms

  function scrubTo(next) {
    var now = Date.now()
    var elapsed = now - root._lastScrubAt
    root._scrubMoves += 1

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
    var discrete = root._scrubMoves <= 1
    if (discrete || root._scrubVelocity > root.scrubFastThreshold)
      root.shiftMinutes = Model.clampShift(Model.snapShift(root.shiftMinutes, root.homeMinuteOfDay))
    root._scrubVelocity = 0
    root._lastScrubAt = 0
    root._scrubMoves = 0
  }

  // ---- Calendar feeds.
  //
  // Google's "secret address in iCal format" and Apple's published webcal://
  // link are both plain one-way .ics feeds, so this whole path is read-only:
  // fetch-events.py pulls them, expands the recurrence rules and writes a flat
  // day-keyed file that the FileView below watches. Nothing here talks to a
  // calendar API, and nothing here can write an event back.
  //
  // The feed list lives in ~/.config/omarchy/calendars.json rather than in
  // this widget's shell.json entry: a private iCal URL is a bearer credential
  // in disguise, and shell.json is the file people paste into forums.

  // Sync switches itself on once there is something to sync. Configuring a
  // feed is the consent, so there is no separate boolean to go and find —
  // and with no feeds the python is never spawned, so a clock that is only
  // ever a clock stays exactly as cheap as it was.
  //
  // "calendarSync" still overrides in both directions for the awkward cases:
  // false to stay inert next to a calendars.json some other tool owns.
  property var configuredFeeds: []

  // Whatever the reader refused, and why. A rejected file should read as a
  // message, not as an empty calendar.
  property var readErrors: ({})

  readonly property bool hasConfiguredFeed: {
    for (var i = 0; i < configuredFeeds.length; i++) {
      var feed = configuredFeeds[i]
      if (feed && feed.enabled !== false && String(feed.url || "").length > 0) return true
    }
    return false
  }

  // A config the reader refused is not the same as no config. Staying switched
  // on is what lets the panel say so, instead of a symlinked calendars.json
  // quietly turning the widget back into a plain clock.
  readonly property bool configUnreadable: !!(root.readErrors && root.readErrors.config)

  readonly property bool calendarSync: {
    var override = setting("calendarSync", null)
    if (override === null || String(override) === "") return hasConfiguredFeed || configUnreadable
    return String(override) === "true"
  }

  // Minutes between background pulls. 0 means manual only. Google caches its
  // .ics feed on their side for a while regardless, so anything under about
  // five minutes buys nothing but wakeups.
  readonly property int syncIntervalMinutes: {
    var raw = parseInt(setting("syncIntervalMinutes", 15), 10)
    if (isNaN(raw) || raw < 0) return 15
    return raw === 0 ? 0 : Math.max(5, raw)
  }

  // "webapp" opens Zoom and Meet in their own windows where Omarchy has an
  // app for them, and falls back to the browser for everything else.
  // "browser" always uses xdg-open.
  readonly property string meetingHandler: String(setting("meetingHandler", "webapp"))

  // 12- or 24-hour agenda times. Unset follows the locale, so a US install
  // gets AM/PM and a European one does not, without anyone configuring it.
  readonly property bool hour12: {
    var override = setting("hour12", null)
    if (override !== null && String(override) !== "") return String(override) === "true"
    // Render an actual afternoon time and look for a meridiem, rather than
    // trying to read Qt's format string — the rendered output is the thing
    // that actually matters, and the format tokens vary by backend.
    // Qt returns "h:mm Ap" for en_US — mixed case, and the tokens differ by
    // backend — so match against the rendered output rather than the format.
    var probe = Qt.formatTime(new Date(2000, 0, 1, 13, 0), Qt.locale().timeFormat(Locale.ShortFormat))
    return /[AaPp]\.?[Mm]/.test(String(probe))
  }

  readonly property bool notifyUpcomingEvents: String(setting("notifyUpcomingEvents", true)) !== "false"
  // "staged" nudges at 10m, 5m and 1m; a bare number fires once at that mark.
  readonly property var notifyMinutesBefore: setting("notifyMinutesBefore", "staged")

  property var eventsByDate: ({})
  property var calendarStatuses: []
  property string lastSyncedLabel: ""
  property int totalEvents: 0
  property bool syncing: false

  // Which calendars the filter chips have switched off, by name. Kept as a
  // set of hidden names rather than shown ones so a newly added feed appears
  // without having to be opted in.
  property var hiddenCalendars: ({})

  // The day the agenda is showing. Empty means today — and it is reset on
  // every open, so the panel always comes up on today rather than on whatever
  // was last clicked.
  property string selectedDateKey: ""
  readonly property string agendaDateKey: selectedDateKey || todayKey
  readonly property string agendaDateLabel: Model.formatSelectedDateLabel(agendaDateKey, todayKey, Qt.locale())

  readonly property var agendaEvents: Model.filterEvents(root.eventsByDate[root.agendaDateKey] || [], root.hiddenCalendars)

  function eventsOn(dateKeyStr) {
    return Model.filterEvents(root.eventsByDate[dateKeyStr] || [], root.hiddenCalendars)
  }

  function selectDate(dateKeyStr) {
    root.selectedDateKey = (root.selectedDateKey === dateKeyStr) ? "" : dateKeyStr
  }

  function toggleCalendar(name) {
    var next = {}
    for (var k in root.hiddenCalendars) next[k] = root.hiddenCalendars[k]
    if (next[name]) delete next[name]
    else next[name] = true
    root.hiddenCalendars = next
  }

  // Throttled, because the config file watcher, the open, the timer and the
  // sync button can all land within a second of each other.
  property real lastSyncAt: 0

  function syncCalendars(force) {
    if (!root.calendarSync) return
    var now = Date.now()
    if (!force && (now - root.lastSyncAt < 30000)) return
    if (fetchProc.running) return
    root.lastSyncAt = now
    root.syncing = true
    fetchProc.running = true
  }

  // The one place either file's contents enter the shell, and they arrive
  // already bounded and parsed by the helper.
  function applyPluginFiles(text) {
    var payload = Model.parsePluginFiles(text)
    root.configuredFeeds = payload.config
    root.readErrors = payload.errors

    var parsed = Model.parseEventsData(payload.state)
    root.eventsByDate = parsed.eventsByDate
    root.calendarStatuses = parsed.calendars
    root.lastSyncedLabel = parsed.lastSyncedFormatted
    root.totalEvents = parsed.totalEvents

    root.checkUpcomingNotifications()
  }

  function openEvent(url) {
    // Same shape as openMeeting, and deliberately the same handler setting:
    // a calendar link and a call link are the same kind of click, and a second
    // switch to find would be one too many.
    var command = Model.calendarLaunchCommand(url, root.meetingHandler)
    if (!command) return
    openUrlProc.command = command
    openUrlProc.running = true
    root.close()
  }

  function openMeeting(url) {
    // Every element is its own argv entry, never interpolated into a shell
    // string: the URL comes off the network inside a calendar description.
    var command = Model.meetingLaunchCommand(url, root.meetingHandler)
    if (!command) return
    openUrlProc.command = command
    openUrlProc.running = true
    root.close()
  }

  // ---- Reminders.
  //
  // Fires from a timer rather than off the sync, so a meeting still nudges on
  // a manual-sync setup. `notified` is keyed by event id plus stage, which is
  // what lets a staged reminder ring three times without ringing twice.
  property var notified: ({})

  function checkUpcomingNotifications() {
    if (!root.calendarSync || !root.notifyUpcomingEvents) return
    var now = new Date()
    var todaysEvents = root.eventsByDate[Model.keyForDate(now)] || []
    for (var i = 0; i < todaysEvents.length; i++) {
      var evt = todaysEvents[i]
      if (!evt || evt.allDay) continue
      var stage = Model.notificationStage(Model.minutesUntil(evt.startIso, now), root.notifyMinutesBefore)
      if (!stage) continue
      var mark = String(evt.id) + ":" + stage
      if (root.notified[mark]) continue
      root.notified[mark] = true
      var when = stage === "t1" ? "in 1 minute" : ("in " + stage.substring(1) + " minutes")
      var body = evt.startTime + "  ·  " + when + (evt.location ? "\n" + evt.location : "")
      // "--" matters: an event title starting with a dash would otherwise be
      // parsed as a notify-send flag, and titles come off the network.
      notifyProc.command = ["notify-send", "-a", "Clock & Zones", "-i", "x-office-calendar",
                            "--", String(evt.title || "Upcoming event"), body]
      notifyProc.running = true
    }
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    // Zones collapse on every open: a normal click is a look at the calendar,
    // and a scrub left over from last time would be actively misleading.
    root.zonesExpanded = false
    root.shiftMinutes = 0
    if (!zoneProbe.running) zoneProbe.running = true
    // Same reasoning as the zones collapse: a day selected last time is not
    // what this open is about.
    root.selectedDateKey = ""
    // A read on every open, not just a sync: the file watchers stop firing if
    // the state file is deleted rather than replaced in place, and an open is
    // the moment the contents actually have to be right.
    root.readPluginFiles()
    root.syncCalendars(false)
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

  function startEditingLife() {
    if (!root.mementoMori) return
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
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
      blocked: root.editingLife
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

              // Inert unless memento mori is switched on, so nobody stumbles
              // into a life expectancy prompt by double-tapping the year.
              TapHandler {
                enabled: root.mementoMori && !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                visible: !root.editingLife
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
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
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

          // ---- Memento mori. Only here once it has been switched on and a
          //      birth year given; the same rail as the year above it,
          //      measured against a nominal lifetime.
          Item {
            visible: root.mementoMori && root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
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
                      id: dayCell
                      required property var modelData

                      // Empty whenever sync is off, which is what keeps the
                      // grid the plain read-out it was built as.
                      readonly property var dayEvents: root.calendarSync ? root.eventsOn(modelData.key) : []
                      readonly property bool selected: root.calendarSync && root.selectedDateKey === modelData.key

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet. A picked day is the one thing
                      // allowed a fill, and only a faint one, so that the two
                      // marks can sit on the same cell without fighting.
                      color: dayCell.selected ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        id: dayNumber
                        anchors.horizontalCenter: parent.horizontalCenter
                        // Nudged up off centre only when there are dots to
                        // make room for, so an empty month is unchanged.
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: dayCell.dayEvents.length > 0 ? -Style.space(3) : 0
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      // One dot per calendar with something on that day, in
                      // that calendar's own colour, capped at three.
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: dayNumber.bottom
                        anchors.topMargin: Style.space(1)
                        spacing: Style.space(2)
                        visible: dayCell.dayEvents.length > 0

                        Repeater {
                          model: Model.dayDotColors(dayCell.dayEvents)

                          Rectangle {
                            required property var modelData
                            width: Style.space(4)
                            height: Style.space(4)
                            radius: width / 2
                            color: modelData
                            // Days either side of the month read as context,
                            // not as content, and their dots should too.
                            opacity: dayCell.modelData.inMonth ? 0.95 : 0.4
                          }
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        enabled: root.calendarSync
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDate(dayCell.modelData.key)
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

          // ---- Agenda for the selected day, or for today until a day is
          //      clicked. The whole section is absent unless sync is on, so
          //      the popup keeps its original height for anyone using this
          //      as a plain clock.
          Item {
            width: parent.width
            height: root.calendarSync ? agendaColumn.y + agendaColumn.height : 0
            visible: root.calendarSync

            Column {
              id: agendaColumn
              y: Style.space(10)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(2)

              PanelSeparator {
                width: parent.width
                foreground: root.contentForeground
              }

              // Header: which day on the left, the two actions on the right.
              Item {
                width: parent.width
                height: Math.max(agendaHeader.implicitHeight, Style.space(20))

                PanelSectionHeader {
                  id: agendaHeader
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.agendaDateLabel
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰑐"
                    tooltipText: root.syncing
                      ? "Syncing…"
                      : ("Sync now" + (root.lastSyncedLabel ? " (last " + root.lastSyncedLabel + ")" : ""))
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    enabled: !root.syncing
                    opacity: root.syncing ? 0.5 : 1.0
                    onClicked: root.syncCalendars(true)
                  }
                }
              }

              // Filter chips. Only earn their row once there is more than one
              // feed to tell apart.
              Flow {
                width: parent.width
                spacing: Style.space(3)
                visible: root.calendarStatuses.length > 1

                Repeater {
                  model: root.calendarStatuses

                  Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool on: !root.hiddenCalendars[chip.modelData.name]

                    height: Style.space(16)
                    width: chipLabel.implicitWidth + Style.space(22)
                    radius: height / 2
                    color: chip.on ? Style.hoverFillFor(root.contentForeground, chip.modelData.color) : "transparent"
                    border.width: Style.spacing.hairline
                    border.color: chip.on ? chip.modelData.color : Qt.darker(root.contentForeground, 2.2)

                    Row {
                      anchors.centerIn: parent
                      spacing: Style.space(3)

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(5)
                        height: Style.space(5)
                        radius: width / 2
                        color: chip.modelData.color
                        opacity: chip.on ? 1.0 : 0.35
                      }

                      Text {
                        id: chipLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: chip.modelData.name
                        color: chip.on ? root.contentForeground : Qt.darker(root.contentForeground, 1.9)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleCalendar(chip.modelData.name)
                    }
                  }
                }
              }

              // The day itself. A feed that failed says so here rather than
              // silently reading as an empty day.
              Text {
                width: parent.width
                visible: root.agendaEvents.length === 0
                // AutoText would sniff a calendar name for markup.
                textFormat: Text.PlainText
                text: {
                  // A file the reader refused -- symlinked, oversized, not a
                  // regular file -- is a different problem from an empty day.
                  if (root.readErrors && root.readErrors.config) return "Calendar config could not be read"
                  if (root.readErrors && root.readErrors.state) return "Event cache could not be read"
                  if (root.calendarStatuses.length === 0) return "No calendars configured"
                  for (var i = 0; i < root.calendarStatuses.length; i++) {
                    var st = String(root.calendarStatuses[i].status || "")
                    if (st.indexOf("error") === 0)
                      return root.calendarStatuses[i].name + " failed to sync"
                  }
                  return "Nothing scheduled"
                }
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                topPadding: Style.space(4)
                bottomPadding: Style.space(4)
              }

              Repeater {
                model: root.agendaEvents

                Item {
                  id: eventItem
                  required property var modelData
                  width: agendaColumn.width
                  height: Math.max(eventRow.implicitHeight, Style.space(20))

                  // Only a Google feed can produce a link, so a row from
                  // anywhere else stays exactly as inert as it was.
                  readonly property bool linked: String(eventItem.modelData.eventUrl || "") !== ""

                  // Hover fill for the whole row. The negative margins let it
                  // breathe past the text without moving anything: the row's
                  // height is what spaces the agenda, and growing it here
                  // would push the zones section down.
                  Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: -Style.space(4)
                    anchors.rightMargin: -Style.space(4)
                    radius: Style.space(4)
                    color: eventMouse.containsMouse
                      ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : "transparent"
                  }

                  // Declared before the Row on purpose. A later sibling paints
                  // and handles input on top, so the join button inside the Row
                  // keeps its own clicks and only the rest of the strip falls
                  // through to here.
                  MouseArea {
                    id: eventMouse
                    anchors.fill: parent
                    enabled: eventItem.linked
                    hoverEnabled: eventItem.linked
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openEvent(eventItem.modelData.eventUrl)

                    PanelToolTip {
                      visible: eventMouse.containsMouse
                      text: "Open in Google Calendar"
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Row {
                    id: eventRow
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    spacing: Style.space(6)

                    // The calendar's colour as a rule down the left, which
                    // survives a long title better than a dot would.
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.spacing.hairline * 2
                      height: Style.space(14)
                      radius: width / 2
                      color: eventItem.modelData.color
                    }

                    // The time column. Digits are right-aligned so the colons
                    // stack whatever the hour's width, and the meridiem sits
                    // outside that column, smaller and dimmer — it is the least
                    // interesting part of "9:30 AM" and should read that way.
                    // Fixed overall width, so titles line up down the day.
                    Item {
                      anchors.verticalCenter: parent.verticalCenter
                      readonly property var parts: Model.formatEventTime(eventItem.modelData.startTime, root.hour12)
                      width: root.hour12 ? Style.space(58) : Style.space(46)
                      height: timeDigits.implicitHeight

                      Text {
                        id: timeDigits
                        anchors.left: parent.left
                        width: root.hour12 ? Style.space(40) : parent.width
                        horizontalAlignment: root.hour12 ? Text.AlignRight : Text.AlignLeft
                        textFormat: Text.PlainText
                        text: eventItem.modelData.allDay ? "All day" : parent.parts.time
                        color: Qt.darker(root.contentForeground, 1.4)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        anchors.left: timeDigits.right
                        anchors.leftMargin: Style.space(3)
                        anchors.baseline: timeDigits.baseline
                        visible: !eventItem.modelData.allDay && parent.parts.meridiem !== ""
                        textFormat: Text.PlainText
                        text: parent.parts.meridiem
                        color: Qt.darker(root.contentForeground, 2.0)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - (root.hour12 ? Style.space(58) : Style.space(46)) - Style.space(30)
                        - (joinButton.visible ? joinButton.width + Style.space(6) : 0)
                      text: eventItem.modelData.title
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      // The title arrives off the network; rendering it as
                      // rich text would let a calendar entry inject markup.
                      textFormat: Text.PlainText
                    }

                    PanelActionButton {
                      id: joinButton
                      anchors.verticalCenter: parent.verticalCenter
                      visible: String(eventItem.modelData.meetingUrl || "") !== ""
                      iconText: "󰕧"
                      // The provider patterns match known domains, but a bare URL
                      // in an event's LOCATION also earns a button — and that
                      // event can come from anyone who can send an invite. Show
                      // the host so the click is never a blind one.
                      tooltipText: {
                        var host = String(eventItem.modelData.meetingUrl || "").replace(/^https?:\/\//, "").split("/")[0]
                        var provider = eventItem.modelData.meetingProvider || "meeting"
                        return host ? ("Join " + provider + "  ·  " + host) : ("Join " + provider)
                      }
                      foreground: root.contentForeground
                      hoverColor: Color.accent
                      fontFamily: root.contentFontFamily
                      onClicked: root.openMeeting(eventItem.modelData.meetingUrl)
                    }
                  }
                }
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
