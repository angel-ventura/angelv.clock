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
//   "zones": ["Asia/Tokyo", { "tz": "America/New_York", "name": "Miami" }]
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
    isoWeekLiteral: isoWeekLiteral
  }
}
