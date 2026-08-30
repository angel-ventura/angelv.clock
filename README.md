# angelv.clock

An Omarchy bar widget: the clock, with a **time-zone converter** folded into
the calendar popup.

Based on Omarchy's built-in `omarchy.clock` widget — see
[Attribution](#attribution).

## What it does differently

- **A zones section under the calendar**, collapsed by default. Each row gets a
  sun/moon glyph, a 24-hour day/night rail, and a magnetic scrubber, so a time
  quoted in someone else's zone lands in yours at a glance.
- **The home row is detected from `timedatectl`**, so it is always this
  machine's real zone. You never list it yourself.
- **Memento mori is opt-in.** Upstream hides the life bar behind a double-tap
  on the year bar, where you can find it by accident. Here the whole feature —
  the gesture included — stays inert until you ask for it. See
  [Memento mori](#memento-mori).

Everything themes with Omarchy: there is no hardcoded colour in the plugin, every
value goes through `Color.*`, `Style.*`, or `bar.foreground`.

## Install

```bash
omarchy plugin add https://github.com/angel-ventura/angelv.clock.git --enable
```

Pick `center` when it asks for a section. Then remove the stock clock, since
you now have two:

```bash
omarchy plugin disable omarchy.clock
omarchy restart shell
```

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
| `mementoMori` | `true` turns the life bar on. Off by default |

Notes:

- **Never put your home zone in `zones`** — it is added automatically.
- Rows sort by UTC offset, west to east, whatever order you write them in.
- Changes apply the **next time you open the panel**, not while it is open.

## Memento mori

Off by default. To switch it on, add this to the widget's entry in
`shell.json`:

```json
"mementoMori": true
```

Then double-tap the year bar in the panel and it asks for **BORN** and
**LIVE TO** — Tab moves between the two, Enter saves, Escape cancels. A LIFE
bar appears under the year bar showing how much of that span is behind you.
Double-tap the life bar to put it away again; your expectancy stays in the
config, so setting a birth year later brings your own number back rather than
the default of 90.

A birth year rather than an age, so the bar keeps counting on its own instead
of going stale. Without one the bar stays hidden even with the setting on. The
values live in `shell.json` as `birthYear` and `lifeExpectancy`, and the panel
writes them there itself, so you never have to type them in by hand.

With `mementoMori` unset or false, none of this exists: no bar, and the
double-tap does nothing.

## Hacking on it

Zone offsets are read by shelling out to `date`. Qt's JS engine accepts the
`timeZone` option on `Intl`/`toLocaleString` and then silently ignores it, so
IANA zones cannot be resolved in QML directly.

After editing `Panel.qml`, reload with `omarchy restart shell` — a
`rescanPlugins` is not enough for panel changes.

To turn the widget off, use `omarchy plugin disable angelv.clock`. Avoid
`omarchy plugin remove`: it renames the folder to a hidden `.bak` and quietly
puts the stock clock back.

## Attribution

This work is **based on Omarchy**. It began as a byte-for-byte clone of the
Omarchy shell's first-party clock widget, made with `omarchy plugin clone
omarchy.clock`, and `BarWidget.qml`, `Model.js` and `Panel.qml` still contain
substantial portions of that original code.

- Upstream: [basecamp/omarchy](https://github.com/basecamp/omarchy)
- Upstream author: David Heinemeier Hansson / Basecamp
- Upstream license: MIT

Unofficial and independent — not endorsed by or affiliated with the Omarchy
project or Basecamp. See [NOTICE](NOTICE) for the full derivation record.

## License

MIT, retaining the upstream copyright notice. See [LICENSE](LICENSE).
