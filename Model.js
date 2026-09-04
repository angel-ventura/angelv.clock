// Derived from the Omarchy shell's built-in clock widget (omarchy.clock),
// Copyright (c) David Heinemeier Hansson, MIT licensed.
// https://github.com/basecamp/omarchy — see LICENSE and NOTICE.

// Pure date and format math for the clock widget and its calendar panel.
// Everything here is locale- and Qt-free so it can be unit tested under node
// (test/shell.d/clock-test.sh); the QML owns month/weekday naming through
// Qt.locale().

var MS_PER_DAY = 86400000

// Weekday indices match both JS Date.getDay() and QML's Locale.Sunday…
// Locale.Saturday, so a locale's firstDayOfWeek can be passed straight in.
var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

// ---- Bar label formats. Right-clicking the clock walks these in order and
//      writes the result back to shell.json, so the label the bar shows and
//      the format the config stores are always the same thing.
//
// The locale-shaped time presets are each followed by their 12-hour twin, so
// the walk from a 24-hour label to the same label in AM/PM is a single right
// click rather than a lap of the ring. The ISO preset is deliberately left
// without one: ISO 8601 writes time on a 24-hour clock, so an AM/PM variant
// would contradict the only thing that format is for.
var CLOCK_FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

// Vertical bars have room for a few stacked lines and nothing else, so the
// ring stays short. AM/PM costs a fourth line, which is why only the plain
// time carries it here.
var VERTICAL_CLOCK_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww\n''yy",
  "HH\nmm"
]

function clockFormats(vertical) {
  return vertical ? VERTICAL_CLOCK_FORMATS.slice() : CLOCK_FORMATS.slice()
}

// The presets in a fixed order, plus the configured alternate and current
// format when they are something else. The order must not depend on which
// entry is current: cycling writes the result back to shell.json, and a ring
// that reshuffled itself around the current value would bounce between two
// entries instead of walking.
function clockFormatRing(configured, configuredAlt, presets) {
  var ring = []
  var candidates = (presets || []).concat([configuredAlt, configured])
  for (var i = 0; i < candidates.length; i++) {
    var format = String(candidates[i] === undefined || candidates[i] === null ? "" : candidates[i])
    if (format === "" || ring.indexOf(format) !== -1) continue
    ring.push(format)
  }
  return ring.length > 0 ? ring : ["HH:mm"]
}

// Next entry after `current`. An unknown current format (a hand-written one
// that is not in the ring) starts the walk at the top.
function nextClockFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  var index = ring.indexOf(String(current === undefined || current === null ? "" : current))
  return ring[(index + 1) % ring.length]
}

// Two-digit ISO week, substituted into a format's 'ww' token before Qt
// formats it -- Qt has no ISO week specifier of its own.
function isoWeekLiteral(year, month, day) {
  return pad2(isoWeek(year, month, day))
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// Stable "yyyy-MM-dd" identity for a day, so a grid cell can be compared
// against today without dragging Date objects through bindings.
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null

  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return null

  for (var i = 0; i < WEEKDAY_NAMES.length; i++)
    if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) return i

  var parsed = parseInt(text, 10)
  return isFinite(parsed) ? ((parsed % 7) + 7) % 7 : null
}

// Configured week start, falling back to the locale's own first day when
// the setting is missing or nonsense.
function normalizedWeekStart(value, fallback) {
  var configured = coerceWeekStart(value)
  if (configured !== null) return configured
  var fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekStartSettingName(index) {
  return WEEKDAY_NAMES[normalizedWeekStart(index, 1)]
}

// The toggle flips between the two conventions people actually switch
// between. A calendar configured to any other start (Saturday, say) is
// shown as-is and lands on Monday the first time it is toggled.
function toggledWeekStart(index) {
  return normalizedWeekStart(index, 1) === 1 ? 0 : 1
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

// ISO-8601 week number: the week owning the Thursday of that date's
// Monday-based week. Mirrors the clock widget's 'ww' format token.
function isoWeek(year, month, day) {
  var date = new Date(Date.UTC(year, month, day))
  var weekday = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - weekday)
  var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

// Share of the year already behind you: whole days completed over days in
// the year, so January 1 reads 0% and December 31 reads 100%.
function yearProgress(year, month, day) {
  var total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

// Memento mori. Off unless "mementoMori" is set in shell.json — see Panel.qml.
// The default span is a round number rather than anything from an actuarial
// table: the point of the bar is the reminder, not the arithmetic, and whoever
// wants a different number can say so.
var DEFAULT_LIFE_EXPECTANCY = 90

// A birth year rather than an age, so the bar keeps counting on its own
// instead of going stale the moment it is entered. 0 means "not set", which
// is also what a blank, malformed, future, or implausibly distant year means.
function parseBirthYear(value, currentYear) {
  var now = Math.round(Number(currentYear))
  if (!isFinite(now)) return 0
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d{4}$/.test(text)) return 0
  var year = parseInt(text, 10)
  if (!isFinite(year) || year > now || year < now - 120) return 0
  return year
}

// Whole years, the way people say their age: born in 1979 makes you 47 for
// all of 2026, whichever side of your birthday today falls.
function ageFromBirthYear(birthYear, currentYear) {
  var born = parseBirthYear(birthYear, currentYear)
  if (born <= 0) return 0
  return Math.round(Number(currentYear)) - born
}

// 0 means "not set", which is also what a blank, negative, fractional, or
// absurd entry means — the life bar simply stays hidden.
function parseAge(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return 0
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 120) return 0
  return years
}

// Unset or nonsense falls back to the default rather than to zero, so the
// bar always has something to measure against.
function parseLifeExpectancy(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return DEFAULT_LIFE_EXPECTANCY
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 150) return DEFAULT_LIFE_EXPECTANCY
  return years
}

function lifeProgress(age, expectancy) {
  var years = parseAge(age)
  var span = parseLifeExpectancy(expectancy)
  if (years <= 0 || span <= 0) return 0
  return Math.max(0, Math.min(1, years / span))
}

function lifeProgressPercent(age, expectancy) {
  return Math.round(lifeProgress(age, expectancy) * 100)
}

// Always six rows of seven days. A fixed grid keeps the popup exactly the
// same height in every month, so stepping through the year never makes the
// panel jump under the pointer.
function monthGrid(year, month, weekStart, todayKey) {
  var start = normalizedWeekStart(weekStart, 1)
  var leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  var cursor = new Date(year, month, 1 - leading)
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getFullYear()
      var cellMonth = cursor.getMonth()
      var cellDay = cursor.getDate()
      var weekday = cursor.getDay()
      var key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    // Number every row by the ISO week owning its Thursday. That is the
    // definition itself for Monday-start weeks, and the only answer that
    // stays stable for the other starts, where a row straddles two ISO
    // weeks but shares all of Monday through Thursday with one of them.
    var anchor = thursday || days[0]
    weeks.push({
      week: isoWeek(anchor.year, anchor.month, anchor.day),
      days: days
    })
  }
  return weeks
}

function stepMonth(year, month, delta) {
  var target = new Date(year, Number(month) + Number(delta), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

// ---- Time zones.
//
// Qt's JS engine has neither `Intl` nor IANA zone support — `typeof Intl` is
// "undefined" and `toLocaleString` silently ignores a timeZone option — so
// none of the usual browser tricks are available. Offsets and abbreviations
// come from `date` instead, which reads the system tz database, and these
// functions only do arithmetic on what it returned. That also means nothing
// here hardcodes CEST vs CET: %Z hands back whichever is in force.

var ZONE_DETENT = 30  // minutes between magnetic stops on the scrubber

// Only the zones you are curious about. Home is never in here — it is read
// off the machine at runtime, so this plugin works for whoever installs it
// rather than for whoever wrote it.
var DEFAULT_ZONES = [
  "America/Los_Angeles",
  "America/Chicago",
  "Europe/Berlin",
  "Asia/Tokyo"
]

// A zone is passed to `sh`, so nothing but the characters IANA names actually
// use gets through. Belt and braces: the list comes from a config file the
// user owns, but that file is not a good place to learn about quoting.
function sanitizeTz(value) {
  return String(value || "").replace(/[^A-Za-z0-9_\/+-]/g, "")
}

// "America/Los_Angeles" -> "Los Angeles". Right often enough that most rows
// need no name at all; the ones it gets wrong take a name from config.
function zoneDisplayName(tz) {
  var parts = String(tz || "").split("/")
  var last = parts[parts.length - 1] || String(tz || "")
  return last.replace(/_/g, " ")
}

// Accepts either shape in shell.json, because one of them is nicer to type
// and the other is the only one that can carry a name:
//   "zones": ["Asia/Tokyo", { "tz": "America/New_York", "name": "Atlanta" }]
function normalizeZoneSetting(value) {
  var source = (value && value.length) ? value : DEFAULT_ZONES
  var list = []
  var seen = ({})
  for (var i = 0; i < source.length; i++) {
    var entry = source[i]
    var tz = "", name = ""
    if (typeof entry === "string") {
      tz = entry
    } else if (entry && typeof entry === "object") {
      tz = entry.tz || entry.timeZone || ""
      name = entry.name || ""
    }
    tz = sanitizeTz(tz)
    if (!tz || seen[tz]) continue
    seen[tz] = true
    list.push({ tz: tz, name: String(name || zoneDisplayName(tz)) })
  }
  // A list that was written but survives as nothing — every entry misspelled,
  // or the wrong shape entirely — falls back rather than rendering an empty
  // section that looks like the feature is broken.
  if (!list.length && source !== DEFAULT_ZONES) return normalizeZoneSetting(null)
  return list
}

// The probe reports the machine's own zone first, then one line per zone.
// `timedatectl` is the answer on any systemd box; the /etc/localtime symlink
// is the fallback for the ones where it is missing or masked.
function probeScript(list) {
  var lines = [
    'H=$(timedatectl show -p Timezone --value 2>/dev/null)',
    '[ -n "$H" ] || H=$(readlink -f /etc/localtime 2>/dev/null | sed "s|.*/zoneinfo/||")',
    '[ -n "$H" ] || H=UTC',
    'printf "HOME|%s\\n" "$H"',
    'TZ="$H" date "+$H|%z|%Z"'
  ]
  for (var i = 0; i < list.length; i++) {
    var tz = sanitizeTz(list[i].tz)
    if (tz) lines.push("TZ='" + tz + "' date '+" + tz + "|%z|%Z'")
  }
  return lines.join("\n")
}

// "+0900" / "-0430" -> minutes east of UTC. Anything unparseable is 0, which
// shows the zone sitting on UTC rather than dropping the row.
function parseUtcOffset(text) {
  var m = String(text || "").match(/^([+-])(\d{2})(\d{2})$/)
  if (!m) return 0
  var mins = parseInt(m[2], 10) * 60 + parseInt(m[3], 10)
  return m[1] === "-" ? -mins : mins
}

// A leading "HOME|<tz>" line, then one "tz|+0900|JST" line per zone. Home
// arrives as data rather than as a flag in the config, which is the whole
// point: the same shell.json works on a machine in another country.
function parseZoneProbe(output) {
  var rows = []
  var homeTz = ""
  var seen = ({})
  var lines = String(output || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line) continue
    var parts = line.split("|")
    if (parts[0] === "HOME") {
      homeTz = parts.length > 1 ? parts[1] : ""
      continue
    }
    if (parts.length < 3 || seen[parts[0]]) continue
    seen[parts[0]] = true
    rows.push({ tz: parts[0], offset: parseUtcOffset(parts[1]), abbr: parts[2] })
  }
  return { homeTz: homeTz, zones: rows }
}

// West to east, so the day/night rails below read as one progression and the
// home row lands wherever it genuinely belongs rather than pinned to the top.
function sortByOffset(rows) {
  return rows.slice().sort(function(a, b) { return a.offset - b.offset })
}

// Minutes-of-day in a zone, plus how far its calendar date has drifted from
// the reference. Both fall out of the same division, so they cannot disagree.
function zoneClock(utcMs, offsetMinutes) {
  var shifted = Math.floor(utcMs / 60000) + Number(offsetMinutes || 0)
  var dayIndex = Math.floor(shifted / 1440)
  var minuteOfDay = shifted - dayIndex * 1440
  return { dayIndex: dayIndex, minuteOfDay: minuteOfDay,
           hour: Math.floor(minuteOfDay / 60), minute: minuteOfDay % 60 }
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function formatClock(clock) {
  return pad2(clock.hour) + ":" + pad2(clock.minute)
}

// 12-hour, for the home row only. The rest of the panel stays 24-hour on
// purpose: announcements are quoted that way, and the whole job here is
// matching what a post said. Your own row is the one you read as a human, so
// it can be the format you actually think in.
function formatClock12(clock) {
  var hour = clock.hour % 12
  if (hour === 0) hour = 12
  return hour + ":" + pad2(clock.minute) + (clock.hour < 12 ? " AM" : " PM")
}

// "" when the zone is on the same date as home — the chip only earns its
// space on the days it would otherwise catch someone out.
function dayShiftLabel(zoneClockValue, homeClockValue) {
  var delta = zoneClockValue.dayIndex - homeClockValue.dayIndex
  if (delta === 0) return ""
  return delta > 0 ? "+" + delta : String(delta)
}

// Whole hours where it divides, "+5:30" where it does not — India and Nepal
// are the reason this cannot just print an integer.
function relativeOffsetLabel(zoneOffset, homeOffset) {
  var delta = Number(zoneOffset) - Number(homeOffset)
  if (delta === 0) return "—"
  var sign = delta < 0 ? "−" : "+"
  var abs = Math.abs(delta)
  var hours = Math.floor(abs / 60)
  var mins = abs % 60
  return sign + hours + (mins ? ":" + pad2(mins) : "") + "h"
}

function formatShift(minutes) {
  var value = Number(minutes) || 0
  if (value === 0) return "NOW"
  var sign = value < 0 ? "−" : "+"
  var abs = Math.abs(value)
  var hours = Math.floor(abs / 60)
  var mins = abs % 60
  return sign + (hours ? hours + "h" : "") + (mins ? (hours ? " " : "") + mins + "m" : "")
}

// The detents belong on the resulting time, not on the shift. At 20:14 a
// shift of +30 lands on 20:44, which is no easier to read than 20:44 was —
// so solve for the shift that puts the home clock on :00 or :30 instead.
function snapShift(rawShift, homeMinuteOfDay, span) {
  var detent = Number(span) || ZONE_DETENT
  var base = Number(homeMinuteOfDay) || 0
  return Math.round((base + Number(rawShift)) / detent) * detent - base
}

function clampShift(value, limit) {
  var bound = Number(limit) || 720
  return Math.max(-bound, Math.min(bound, Math.round(Number(value) || 0)))
}

// Civil daylight, not real sunrise: the panel is telling you whether it is a
// reasonable hour to expect a human to be awake there, and an almanac would
// be a lot of machinery to answer a question nobody asked that precisely.
function isDaylight(clock) {
  return clock.hour >= 6 && clock.hour < 20
}

// ---- Calendar feeds.
//
// fetch-events.py does the fetching and the RRULE expansion; by the time a
// day reaches here it is already a flat, sorted list. These are only the
// readers for that file and the formatters the panel needs.
//
// The iCalendar reader is derived from sync-calendar-omarchy by promaaa (MIT)
// — see NOTICE.

// A missing or half-written state file reads as "no events" rather than
// throwing: fetch-events.py writes it atomically, but it simply does not
// exist until the first sync completes.
function emptyEventsData() {
  return { eventsByDate: {}, calendars: [], lastSyncedFormatted: "", totalEvents: 0, configuredCount: 0 }
}

// Takes the already-decoded state object. The shell no longer sees the state
// file's bytes -- `fetch-events.py --read` reads it under a size cap and hands
// back JSON -- so the text-taking wrapper below is only kept for callers that
// still have a string.
function parseEventsData(data) {
  if (!data || typeof data !== "object") return emptyEventsData()
  return {
    eventsByDate: data.eventsByDate || {},
    calendars: data.calendars || [],
    lastSyncedFormatted: data.lastSyncedFormatted || "",
    totalEvents: data.totalEvents || 0,
    configuredCount: data.configuredCount !== undefined
      ? data.configuredCount
      : (data.calendars ? data.calendars.length : 0)
  }
}

function parseEventsFile(text) {
  if (!text || typeof text !== "string") return emptyEventsData()
  try {
    return parseEventsData(JSON.parse(text))
  } catch (e) {
    return emptyEventsData()
  }
}

// calendars.json is the user's own file and may be edited by hand, so a
// syntax error mid-edit has to leave the panel standing.
function parseCalendarsConfig(text) {
  if (!text || typeof text !== "string") return []
  try {
    var data = JSON.parse(text)
    return Array.isArray(data) ? data : []
  } catch (e) {
    return []
  }
}

// The bounded reader returns both of the plugin's files in one object, plus a
// reason for anything it refused to read. A file it rejected comes back null
// rather than half-read, so a symlinked or oversized config leaves the panel
// standing and says why instead of quietly showing an empty calendar.
function parsePluginFiles(text) {
  var empty = { config: [], state: null, errors: {} }
  if (!text || typeof text !== "string") return empty
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object") return empty
    return {
      config: Array.isArray(data.config) ? data.config : [],
      state: (data.state && typeof data.state === "object") ? data.state : null,
      errors: (data.errors && typeof data.errors === "object") ? data.errors : {}
    }
  } catch (e) {
    return empty
  }
}

// The dots under a day cell. Capped, because a day with eleven events should
// read as "busy", not as a second row of pixels — and the count is what the
// agenda below is for.
var MAX_DAY_DOTS = 3

function dayDotColors(events, maxDots) {
  var cap = maxDots || MAX_DAY_DOTS
  var seen = {}
  var colors = []
  for (var i = 0; i < events.length && colors.length < cap; i++) {
    var c = events[i] && events[i].color
    if (!c || seen[c]) continue
    seen[c] = true
    colors.push(c)
  }
  return colors
}

// Only the calendars actually switched on in the filter chips. An empty or
// missing filter set means "all of them" rather than "none".
function filterEvents(events, hidden) {
  if (!events || !events.length) return []
  if (!hidden) return events
  var out = []
  for (var i = 0; i < events.length; i++) {
    if (!hidden[events[i].calendar]) out.push(events[i])
  }
  return out
}

function formatSelectedDateLabel(dateKeyStr, todayKeyStr, locale) {
  if (!dateKeyStr) return "TODAY"
  if (dateKeyStr === todayKeyStr) return "TODAY"
  var parts = dateKeyStr.split("-")
  if (parts.length !== 3) return dateKeyStr
  var y = parseInt(parts[0], 10)
  var m = parseInt(parts[1], 10) - 1
  var d = parseInt(parts[2], 10)
  var dt = new Date(y, m, d)
  var dayName = (locale && typeof locale.dayName === "function")
    ? locale.dayName(dt.getDay(), 1)
    : WEEKDAY_NAMES[dt.getDay()]
  var monthName = (locale && typeof locale.monthName === "function")
    ? locale.monthName(dt.getMonth(), 1)
    : ("" + (m + 1))
  return (dayName + ", " + monthName + " " + d).toUpperCase()
}

// Split a stored "HH:MM" into a display time and its meridiem, so the panel can
// render "AM"/"PM" smaller and quieter than the digits rather than letting a
// four-character suffix shout as loudly as the hour.
//
// The stored form stays 24-hour — it is data, and it sorts. Only the display
// changes.
function formatEventTime(hhmm, hour12) {
  var raw = String(hhmm || "")
  var parts = raw.split(":")
  if (parts.length !== 2) return { time: raw, meridiem: "" }

  var hour = parseInt(parts[0], 10)
  var minute = parts[1]
  if (isNaN(hour)) return { time: raw, meridiem: "" }

  if (!hour12) return { time: raw, meridiem: "" }

  var suffix = hour < 12 ? "AM" : "PM"
  var shown = hour % 12
  if (shown === 0) shown = 12
  return { time: shown + ":" + minute, meridiem: suffix }
}

// Where a join click should actually land.
//
// "browser" always uses xdg-open. "webapp" prefers a dedicated window, which
// matters for a call: camera and microphone permission is per-origin and
// sticks, and a real window can carry a Hyprland rule where a browser tab
// cannot.
//
// Zoom is handed its own deep link rather than a rebuilt web-client URL —
// Omarchy already owns that rewrite in omarchy-webapp-handler-zoom, and
// routing through the scheme means a natively installed Zoom would claim it
// instead, which is the better client anyway.
//
// Anything with no app of its own falls through to the browser.
function meetingLaunchCommand(url, handler) {
  var link = String(url || "")
  if (!link) return null

  var plain = ["xdg-open", link]
  if (String(handler || "webapp") === "browser") return plain

  var zoom = link.match(/^https?:\/\/(?:[a-zA-Z0-9-]+\.)?zoom\.us\/(?:j|w|wc\/join)\/(\d+)/)
  if (zoom) {
    var deep = "zoommtg://zoom.us/join?confno=" + zoom[1]
    // Only a well-formed passcode travels; it is going into a URL built here.
    var pwd = link.match(/[?&]pwd=([a-zA-Z0-9._-]+)/)
    if (pwd) deep += "&pwd=" + pwd[1]
    return ["xdg-open", deep]
  }

  // Meet has no scheme to hand off to, so the web app is launched directly.
  if (/^https:\/\/meet\.google\.com\//.test(link))
    return ["omarchy-launch-webapp", link]

  return plain
}

// Where an agenda row goes when it is clicked. Unlike a meeting link this URL
// is built by fetch-events.py rather than lifted out of a feed, but it still
// reaches here through a file on disk, so the destination is checked again
// rather than trusted: only Google Calendar's own two hosts are ever launched,
// and requiring the "/" straight after the host means a credential-confusion
// URL like https://www.google.com@example.com/ cannot match.
function calendarLaunchCommand(url, handler) {
  var link = String(url || "")
  if (!/^https:\/\/(?:www\.google\.com\/calendar\/|calendar\.google\.com\/)/.test(link))
    return null
  if (String(handler || "webapp") === "browser") return ["xdg-open", link]
  return ["omarchy-launch-webapp", link]
}

// "New event on this day" in Google Calendar.
//
// action=TEMPLATE is the same link every "Add to Calendar" button on the web
// uses, and it is the one Google documents. `dates` as a bare day pair opens
// the form as an all-day event on that date: one click from a timed one, and
// better than inventing a start hour nobody asked for. The end is the *next*
// day because Google reads the range as half-open.
//
// The event lands in whichever calendar is the default for the signed-in
// account. There is a &src= for naming one, deliberately not used: a feed can
// be a calendar you only subscribe to, and a create link aimed at one you
// cannot write to fails in a way that reads like the button is broken.
function googleNewEventUrl(dateKeyStr) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dateKeyStr || ""))
  if (!m) return ""
  var year = Number(m[1]), month = Number(m[2]), day = Number(m[3])
  // Built in UTC so month-end arithmetic cannot be dragged over a boundary by
  // the local zone: these are calendar dates, not instants.
  var start = new Date(Date.UTC(year, month - 1, day))
  // Date.UTC rolls a nonsense date forward rather than refusing it, so the
  // shape check above is not enough on its own -- "2026-13-99" would sail
  // through as some day the following April.
  if (start.getUTCFullYear() !== year || start.getUTCMonth() !== month - 1
      || start.getUTCDate() !== day) return ""
  // The end is the *next* day: Google reads the range as half-open.
  var next = new Date(start.getTime() + 86400000)
  var pad = function (n) { return (n < 10 ? "0" : "") + n }
  var stamp = function (dt) {
    return dt.getUTCFullYear() + pad(dt.getUTCMonth() + 1) + pad(dt.getUTCDate())
  }
  return "https://calendar.google.com/calendar/render?action=TEMPLATE&dates="
    + stamp(start) + "/" + stamp(next)
}

// Minutes from now until an ISO start stamp, negative once it has begun.
function minutesUntil(startIso, now) {
  if (!startIso) return NaN
  var start = new Date(startIso)
  if (isNaN(start.getTime())) return NaN
  return Math.floor((start.getTime() - (now || new Date()).getTime()) / 60000)
}

// Which reminder, if any, is due for an event this many minutes out.
// "staged" fires three times on the way in; a bare number fires once. The
// returned string is also the dedupe key, so an event notified at 10m still
// gets its 5m and 1m nudges but never the same one twice.
var STAGED_NOTICES = [10, 5, 1]

function notificationStage(diffMin, noticeSetting) {
  if (isNaN(diffMin) || diffMin < 0) return ""
  var setting = String(noticeSetting === undefined || noticeSetting === null ? "staged" : noticeSetting).toLowerCase()
  if (setting === "staged") {
    for (var i = 0; i < STAGED_NOTICES.length; i++) {
      if (diffMin === STAGED_NOTICES[i]) return "t" + STAGED_NOTICES[i]
    }
    return ""
  }
  var mins = parseInt(setting, 10)
  if (isNaN(mins) || mins <= 0) return ""
  return diffMin === mins ? "t" + mins : ""
}


if (typeof module !== "undefined") {
  module.exports = {
    ZONE_DETENT: ZONE_DETENT,
    DEFAULT_ZONES: DEFAULT_ZONES,
    sanitizeTz: sanitizeTz,
    zoneDisplayName: zoneDisplayName,
    normalizeZoneSetting: normalizeZoneSetting,
    probeScript: probeScript,
    sortByOffset: sortByOffset,
    parseUtcOffset: parseUtcOffset,
    parseZoneProbe: parseZoneProbe,
    zoneClock: zoneClock,
    formatClock: formatClock,
    formatClock12: formatClock12,
    dayShiftLabel: dayShiftLabel,
    relativeOffsetLabel: relativeOffsetLabel,
    formatShift: formatShift,
    snapShift: snapShift,
    parseBirthYear: parseBirthYear,
    ageFromBirthYear: ageFromBirthYear,
    parseAge: parseAge,
    parseLifeExpectancy: parseLifeExpectancy,
    lifeProgress: lifeProgress,
    lifeProgressPercent: lifeProgressPercent,
    clampShift: clampShift,
    isDaylight: isDaylight,
    dateKey: dateKey,
    keyForDate: keyForDate,
    normalizedWeekStart: normalizedWeekStart,
    weekStartSettingName: weekStartSettingName,
    toggledWeekStart: toggledWeekStart,
    weekdayOrder: weekdayOrder,
    isoWeek: isoWeek,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    monthGrid: monthGrid,
    stepMonth: stepMonth,
    clockFormats: clockFormats,
    clockFormatRing: clockFormatRing,
    nextClockFormat: nextClockFormat,
    isoWeekLiteral: isoWeekLiteral,
    parseEventsFile: parseEventsFile,
    parseCalendarsConfig: parseCalendarsConfig,
    dayDotColors: dayDotColors,
    filterEvents: filterEvents,
    formatSelectedDateLabel: formatSelectedDateLabel,
    minutesUntil: minutesUntil,
    notificationStage: notificationStage,
    meetingLaunchCommand: meetingLaunchCommand,
    calendarLaunchCommand: calendarLaunchCommand,
    googleNewEventUrl: googleNewEventUrl,
    formatEventTime: formatEventTime
  }
}
