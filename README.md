# Clock, Zones & Calendar

An Omarchy bar widget: the clock, with a **time-zone converter** and optional
**read-only calendar sync** folded into the calendar popup. Installs as
`angelv.clock` — the plugin id is unchanged, only the repository was renamed.

Based on Omarchy's built-in `omarchy.clock` widget — see
[Attribution](#attribution).

<p align="center">
  <img src="preview.png" alt="The calendar popup: a month grid with event dots, calendar filter chips, a day agenda with Meet and Zoom join buttons, and the zones section open below showing five cities with day/night rails and the scrubber" width="420">
</p>

## What it does differently

- **A zones section under the calendar**, collapsed by default. Each row gets a
  sun/moon glyph, a 24-hour day/night rail, and a magnetic scrubber, so a time
  quoted in someone else's zone lands in yours at a glance.
- **The home row is detected from `timedatectl`**, so it is always this
  machine's real zone. You never list it yourself.
- **Memento mori can be switched off.** Set `"mementoMori": false` and the life
  bar and its double-tap gesture are gone. On by default, as upstream.
- **Calendar sync, read-only and off by default.** Point it at Google's or
  Apple's iCal link and the month grid gets event dots, with an agenda for the
  day you click and optional reminders before a meeting. See
  [Calendar sync](#calendar-sync).

Everything themes with Omarchy: there is no hardcoded colour in the plugin, every
value goes through `Color.*`, `Style.*`, or `bar.foreground`.

## Install

```bash
omarchy plugin add https://github.com/angel-ventura/omarchy-clock-zones-calendar.git --enable
```

Pick `center` when it asks for a section. Then remove the stock clock, since
you now have two:

```bash
omarchy plugin disable omarchy.clock
omarchy restart shell
```

## Remove

```bash
omarchy plugin remove angelv.clock
omarchy restart shell
```

Removal moves the folder to a hidden timestamped backup beside it rather than
deleting it, and puts Omarchy's own `omarchy.clock` back in the bar in its
place. To keep it installed but switch it off instead:

```bash
omarchy plugin disable angelv.clock
```

## Requirements

Omarchy 4 (`omarchy-shell`). Zone offsets are read with `date` from GNU
coreutils and the home zone with `timedatectl` from systemd, both of which are
already part of a standard Omarchy install.

Calendar sync, if you switch it on, additionally needs `python3` (standard
library only — no pip packages) and `wl-copy` from wl-clipboard for the copy
button. It is the only part of this plugin that touches the network, and only
to GET the feed URLs you configure.

## Configure

The zones are configuration, not code. Edit this widget's entry in
`~/.config/omarchy/shell.json`:

```json
{
  "id": "angelv.clock",
  "format": "dddd h:mm AP",
  "formatAlt": "d MMMM 'W'ww yyyy",
  "verticalFormat": "h\n—\nmm\nAP",
  "homeName": "Atlanta",
  "homeHour12": true,
  "zones": [
    "America/Los_Angeles",
    "Europe/London",
    "Asia/Tokyo"
  ]
}
```

| Key | What it does |
| --- | --- |
| `format` / `formatAlt` | The bar label, and what it shows when clicked through |
| `verticalFormat` | The label when the bar is on a vertical edge |
| `homeName` | The **label** for the home row only — the zone itself is detected |
| `homeHour12` | 12-hour clock for the home row |
| `zones` | IANA zone names to show as extra rows |
| `mementoMori` | `false` removes the life bar and its gesture. On by default |
| `calendarSync` | `true` switches on calendar sync. Off by default |
| `syncIntervalMinutes` | Minutes between background pulls. `0` is manual only. Default 15, floor 5 |
| `notifyUpcomingEvents` | `false` silences reminders. On by default when sync is on |
| `notifyMinutesBefore` | `"staged"` (10m, 5m, 1m) or a single number of minutes |
| `meetingHandler` | `"webapp"` (default) opens Zoom and Meet in their own window; `"browser"` always uses xdg-open |

Notes:

- **Never put your home zone in `zones`** — it is added automatically.
- Rows sort by UTC offset, west to east, whatever order you write them in.
- Changes apply the **next time you open the panel**, not while it is open.

## Calendar sync

Off until you ask for it. Once on, the popup grows a dot under every day that
has something on it and an agenda for the day you click; days are only clickable
once sync is on, so the grid stays the plain read-out it was designed as when it
is off.

### Setting it up

**1. Copy your calendar's link.**

- **Google** — [calendar.google.com](https://calendar.google.com) → hover the
  calendar in the left sidebar → **⋮** → *Settings and sharing* → scroll to
  **Integrate calendar** → copy **Secret address in iCal format**. It is shown
  as dots; use the copy button rather than trying to read it.
- **Apple iCloud** — [icloud.com/calendar](https://www.icloud.com/calendar) →
  the share icon next to the calendar → turn on **Public Calendar** → copy the
  `webcal://` link. Note that this genuinely publishes the calendar: anyone with
  the link can read it. iCloud offers no private `.ics` equivalent.
- **Outlook / Office 365** — *Settings → Calendar → Shared calendars →
  Publish a calendar* → copy the **ICS** link. Many company tenants disable
  this; if the option is missing, your admin has turned it off.
- Anything else that gives you an `.ics` or `webcal://` link works too —
  Proton, Nextcloud, Fastmail, a plain file on disk.

**2. Turn sync on and save the link.** With the link on your clipboard:

```bash
omarchy bar set angelv.clock calendarSync true --json

python3 - <<'PY'
import json, os, re, stat, subprocess
url = subprocess.run(["wl-paste"], capture_output=True, text=True).stdout.strip()
if not re.match(r"^(https?|webcals?)://[A-Za-z0-9.\-]+/", url):
    raise SystemExit("No calendar link on the clipboard — copy it first.")
path = os.path.expanduser("~/.config/omarchy/calendars.json")
feeds = [{"name": "Personal", "url": url, "color": "#4A90E2", "enabled": True}]
tmp = path + ".tmp"
json.dump(feeds, open(tmp, "w"), indent=2)
os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
os.replace(tmp, path)
print("Saved:", url.split("://")[0] + "://" + url.split("://")[1].split("/")[0] + "/…")
PY
```

The link goes from the clipboard straight into a `0600` file. It is never
printed, so it does not end up in your scrollback — and because it is not typed
as a command argument, it stays out of your shell history too. That matters: a
feed URL is a **bearer credential**, and anyone holding it can read your
calendar.

**3. Reload the shell.**

```bash
omarchy restart shell
```

If you would rather not run the snippet, just edit
`~/.config/omarchy/calendars.json` by hand — the format is below. Either way,
`chmod 600` it.

### The feed list

Feeds live in `~/.config/omarchy/calendars.json`, **not** in `shell.json` — a
private iCal URL is a bearer credential in disguise, and `shell.json` is the file
people paste into forum posts. The file is written `0600` and re-read whenever it
changes, so no restart is needed after an edit.

```json
[
  {
    "name": "Personal",
    "url": "https://calendar.google.com/calendar/ical/you%40gmail.com/private-xxxxxxxx/basic.ics",
    "color": "#4A90E2",
    "enabled": true
  },
  {
    "name": "Family",
    "url": "webcal://p00-caldav.icloud.com/published/2/xxxxxxxx",
    "color": "#e5c07b",
    "enabled": true
  }
]
```

Add as many as you like — each gets its own colour, a filter chip in the agenda
header, and can be switched off with `"enabled": false` without deleting it.

This is deliberately **read-only**: both of those are one-way feeds, so events
cannot be created or edited from the panel. Two things follow from that, and
neither is a bug in this plugin:

- Google caches its own iCal feed, so an edit made on the web can take a while
  to show up here. A sync interval under five minutes buys nothing, which is
  why five is the floor.
- Apple's link requires the calendar to be *published*, which means anyone who
  has the URL can read it. Treat it accordingly.

If you need writable calendars, OAuth against a restricted Google calendar, or
JMAP/Fastmail, use [sync-calendar-omarchy](https://github.com/promaaa/sync-calendar-omarchy),
which this borrows its iCalendar reader from and which does all of that. Note
that it is also a clock widget, so the two replace each other rather than
stacking — run one or the other.

| In the panel | |
| --- | --- |
| Click a day | Show that day's agenda; click again to go back to today |
| Chips | Filter by calendar |
| `󰆏` or `y` | Copy the day's agenda as Markdown checkboxes |
| `󰑐` | Sync now |
| `󰕧` | Join a detected Meet / Zoom / Teams / Webex / Jitsi link. The tooltip names the host it will open |

Reminders fire whether or not the popup is open: `"staged"` nudges at 10, 5 and
1 minutes before an event, and a number fires once at that mark.

### Where a join click lands

By default (`"meetingHandler": "webapp"`) a call opens in its own window rather
than a browser tab. Camera and microphone permission is per-origin and sticks,
and a real window can carry a Hyprland rule — a browser tab cannot.

| Provider | Opens |
| --- | --- |
| Zoom | `zoommtg://`, which Omarchy's own handler turns into the web client. A natively installed Zoom claims that scheme first, which is better still |
| Google Meet | The Meet web app, via `omarchy-launch-webapp` |
| Teams, Webex, Jitsi, anything else | Your default browser |

Zoom ships with Omarchy. For Meet, create the web app once:

```bash
omarchy-webapp-install "Google Meet" "https://meet.google.com/" \
  "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/google-meet.png"
```

Set `"meetingHandler": "browser"` to send everything to the browser instead.

## Hacking on it

Zone offsets are read by shelling out to `date`. Qt's JS engine accepts the
`timeZone` option on `Intl`/`toLocaleString` and then silently ignores it, so
IANA zones cannot be resolved in QML directly.

After editing `Panel.qml`, reload with `omarchy restart shell` — a
`rescanPlugins` is not enough for panel changes.

If you are developing against this rather than using it, prefer
`omarchy plugin disable angelv.clock` over `omarchy plugin remove` — remove
moves your working copy to a hidden `.bak` folder and restores the stock clock.

## Attribution

This work is **based on Omarchy**. It began as a byte-for-byte clone of the
Omarchy shell's first-party clock widget, made with `omarchy plugin clone
omarchy.clock`, and `BarWidget.qml`, `Model.js` and `Panel.qml` still contain
substantial portions of that original code.

- Upstream: [basecamp/omarchy](https://github.com/basecamp/omarchy)
- Upstream author: David Heinemeier Hansson / Basecamp
- Upstream license: MIT

The calendar sync is **derived from
[sync-calendar-omarchy](https://github.com/promaaa/sync-calendar-omarchy)** by
promaaa, also MIT. `fetch-events.py` keeps that project's iCalendar reader and
its RRULE expanders; the Google API, OAuth, JMAP and event-writing paths were
removed, since none of them are needed for a read-only .ics feed.

- Upstream: [promaaa/sync-calendar-omarchy](https://github.com/promaaa/sync-calendar-omarchy)
- Upstream author: promaaa
- Upstream license: MIT

Unofficial and independent — not endorsed by or affiliated with the Omarchy
project or Basecamp. See [NOTICE](NOTICE) for the full derivation record.

## License

MIT, retaining the upstream copyright notice. See [LICENSE](LICENSE).
