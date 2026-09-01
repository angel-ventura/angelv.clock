#!/usr/bin/env python3
"""
iCalendar (.ics / webcal) fetcher and parser for the angelv.clock widget.

Reads the feeds listed in ~/.config/omarchy/calendars.json and writes the
parsed events to ~/.local/state/omarchy/calendar-events.json, which Panel.qml
watches. Read-only on purpose: Google's "secret address in iCal format" and
Apple's published webcal:// link are both one-way feeds, so there is no OAuth,
no JMAP and no write path in here.

Derived from sync-calendar-omarchy by promaaa (MIT):
https://github.com/promaaa/sync-calendar-omarchy
The iCalendar parser and the RRULE expanders are theirs; see NOTICE.
"""

import os
import sys
import json
import re
import secrets
import stat
import time
import calendar
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime, date, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    ZoneInfo = None

CONFIG_PATH = os.path.expanduser("~/.config/omarchy/calendars.json")
STATE_DIR = os.path.expanduser("~/.local/state/omarchy")
# Deliberately not promaa.clock's "calendar-events.json": if both widgets are
# installed they would clobber each other's cache, and the two schemas differ.
OUTPUT_PATH = os.path.join(STATE_DIR, "angelv-clock-events.json")

# Some providers (iCloud in particular) refuse a bare urllib user-agent.
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 (OmarchyCalendar/1.0)"

WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

MAX_ICAL_BYTES = 10 * 1024 * 1024   # 10 MB limit for calendar .ics content
MAX_CONFIG_BYTES = 1 * 1024 * 1024  # 1 MB limit for local config files
MAX_OUTPUT_JSON_BYTES = 25 * 1024 * 1024  # 25 MB limit for generated event state
MAX_RECURRENCE_ITERATIONS = 2000    # CPU-work ceiling for expanding recurrence rules
MAX_EXPANDED_INSTANCES = 500        # Maximum instances generated per recurring/multiday event


def safe_read_bytes(stream, max_bytes=MAX_ICAL_BYTES):
    """
    Reads binary content from stream up to max_bytes + 1.
    Raises ValueError if content exceeds max_bytes to prevent unbounded memory consumption.
    """
    chunks = []
    total = 0
    chunk_size = 64 * 1024
    while total <= max_bytes:
        chunk = stream.read(min(chunk_size, max_bytes - total + 1))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            raise ValueError(f"Content size exceeded safety limit of {max_bytes} bytes")
    return b"".join(chunks)


def safe_read_text(stream, max_bytes=MAX_ICAL_BYTES):
    """
    Reads text content from stream up to max_bytes + 1 chars.
    Raises ValueError if content exceeds max_bytes to prevent unbounded memory consumption.
    """
    chunks = []
    total = 0
    chunk_size = 64 * 1024
    while total <= max_bytes:
        chunk = stream.read(min(chunk_size, max_bytes - total + 1))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            raise ValueError(f"Content size exceeded safety limit of {max_bytes} characters")
    return "".join(chunks)


def safe_load_json(file_path, max_bytes=MAX_CONFIG_BYTES):
    """
    Read JSON from one descriptor, rejecting links, non-files, foreign owners,
    and files larger than the configured limit.
    """
    dir_name = os.path.dirname(os.path.abspath(file_path))
    file_name = os.path.basename(file_path)
    dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)

    try:
        dir_fd = os.open(dir_name, dir_flags)
    except FileNotFoundError:
        return None
    try:
        dir_stat = os.fstat(dir_fd)
        if not stat.S_ISDIR(dir_stat.st_mode) or dir_stat.st_uid != os.getuid():
            raise PermissionError(f"Unsafe JSON directory: {dir_name}")
        try:
            fd = os.open(file_name, file_flags, dir_fd=dir_fd)
        except FileNotFoundError:
            return None
        try:
            file_stat = os.fstat(fd)
            if not stat.S_ISREG(file_stat.st_mode):
                raise ValueError(f"JSON path is not a regular file: {file_path}")
            if file_stat.st_uid != os.getuid():
                raise PermissionError(f"JSON file is not owned by the current user: {file_path}")
            if file_stat.st_size > max_bytes:
                raise ValueError(f"JSON file exceeds safety limit of {max_bytes} bytes")
            with os.fdopen(fd, "rb", closefd=False) as f:
                raw = safe_read_bytes(f, max_bytes=max_bytes)
            return json.loads(raw.decode("utf-8"))
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)


def write_secure_json(path, data, mode=0o600, max_bytes=MAX_CONFIG_BYTES):
    """Atomically replace an owned regular JSON file through its directory fd."""
    payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
    if len(payload) > max_bytes:
        raise ValueError(f"JSON output exceeds safety limit of {max_bytes} bytes")
    abs_path = os.path.abspath(path)
    dir_name = os.path.dirname(abs_path)
    file_name = os.path.basename(abs_path)
    os.makedirs(dir_name, mode=0o700, exist_ok=True)
    dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    dir_fd = os.open(dir_name, dir_flags)
    tmp_name = None
    try:
        dir_stat = os.fstat(dir_fd)
        if not stat.S_ISDIR(dir_stat.st_mode) or dir_stat.st_uid != os.getuid():
            raise PermissionError(f"Unsafe JSON directory: {dir_name}")
        try:
            existing = os.stat(file_name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if not stat.S_ISREG(existing.st_mode):
                raise ValueError(f"JSON path is not a regular file: {path}")
            if existing.st_uid != os.getuid():
                raise PermissionError(f"JSON file is not owned by the current user: {path}")

        create_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        for _ in range(128):
            candidate = f".{file_name}.tmp-{secrets.token_hex(16)}"
            try:
                fd = os.open(candidate, create_flags, mode, dir_fd=dir_fd)
                tmp_name = candidate
                break
            except FileExistsError:
                continue
        else:
            raise FileExistsError("Unable to allocate an exclusive JSON temporary file")
        try:
            tmp_stat = os.fstat(fd)
            if not stat.S_ISREG(tmp_stat.st_mode) or tmp_stat.st_uid != os.getuid():
                raise PermissionError("Unsafe JSON temporary file")
            os.fchmod(fd, mode)
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp_name, file_name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        tmp_name = None
        os.fsync(dir_fd)
    finally:
        if tmp_name is not None:
            try:
                os.unlink(tmp_name, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
        os.close(dir_fd)

def ensure_config_exists():
    """Create a default sample config if it does not exist."""
    try:
        existing = safe_load_json(CONFIG_PATH, max_bytes=MAX_CONFIG_BYTES)
    except (json.JSONDecodeError, OSError, ValueError):
        return
    if existing is None:
        sample = [
            {
                "name": "Personal Calendar",
                "url": "",
                "color": "#4A90E2",
                "enabled": True,
            }
        ]
        write_secure_json(CONFIG_PATH, sample, mode=0o600)


def unfold_lines(raw_text):
    """Unfold lines in an iCalendar stream according to RFC 5545."""
    lines = []
    for line in raw_text.splitlines():
        if not line:
            continue
        if (line.startswith(" ") or line.startswith("\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def unescape_ical_text(val):
    if not val:
        return ""
    val = val.replace("\\n", "\n").replace("\\N", "\n")
    val = val.replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
    return val.strip()


# Common Windows/Exchange TZID names that are not IANA identifiers.
WINDOWS_TZ_ALIASES = {
    "EASTERN STANDARD TIME": "America/New_York",
    "CENTRAL STANDARD TIME": "America/Chicago",
    "MOUNTAIN STANDARD TIME": "America/Denver",
    "US MOUNTAIN STANDARD TIME": "America/Phoenix",
    "PACIFIC STANDARD TIME": "America/Los_Angeles",
    "ALASKAN STANDARD TIME": "America/Anchorage",
    "HAWAIIAN STANDARD TIME": "Pacific/Honolulu",
    "ATLANTIC STANDARD TIME": "America/Halifax",
    "GMT STANDARD TIME": "Europe/London",
    "GREENWICH STANDARD TIME": "Atlantic/Reykjavik",
    "W. EUROPE STANDARD TIME": "Europe/Berlin",
    "CENTRAL EUROPE STANDARD TIME": "Europe/Budapest",
    "CENTRAL EUROPEAN STANDARD TIME": "Europe/Warsaw",
    "ROMANCE STANDARD TIME": "Europe/Paris",
    "E. EUROPE STANDARD TIME": "Europe/Bucharest",
    "FLE STANDARD TIME": "Europe/Kiev",
    "GTB STANDARD TIME": "Europe/Athens",
    "RUSSIAN STANDARD TIME": "Europe/Moscow",
    "INDIA STANDARD TIME": "Asia/Kolkata",
    "CHINA STANDARD TIME": "Asia/Shanghai",
    "SINGAPORE STANDARD TIME": "Asia/Singapore",
    "TOKYO STANDARD TIME": "Asia/Tokyo",
    "KOREA STANDARD TIME": "Asia/Seoul",
    "AUS EASTERN STANDARD TIME": "Australia/Sydney",
    "NEW ZEALAND STANDARD TIME": "Pacific/Auckland",
    "UTC": "UTC",
}

_zone_cache = {}


def resolve_timezone(tzid):
    """
    Resolve an iCal TZID value to a tzinfo object, or None when it is unknown.
    Handles quoted names, prefixed forms (/mozilla.org/.../America/New_York)
    and the common Windows/Exchange zone names.
    """
    if not tzid or ZoneInfo is None:
        return None

    key = tzid.strip().strip('"')
    if not key:
        return None
    if key in _zone_cache:
        return _zone_cache[key]

    candidates = [key]
    if "/" in key:
        parts = [part for part in key.split("/") if part]
        if len(parts) >= 2:
            candidates.append("/".join(parts[-2:]))
        if parts:
            candidates.append(parts[-1])
    alias = WINDOWS_TZ_ALIASES.get(key.upper())
    if alias:
        candidates.append(alias)

    zone = None
    for cand in candidates:
        try:
            zone = ZoneInfo(cand)
            break
        except Exception:
            continue

    _zone_cache[key] = zone
    return zone


def to_local_naive(dt, tz):
    """Interpret naive dt as being in tz, then re-express it as local wall time."""
    try:
        return dt.replace(tzinfo=tz).astimezone().replace(tzinfo=None)
    except Exception:
        return dt


def extract_tzid(params):
    """Return the TZID parameter value from a property's parameter list."""
    for param in params or []:
        if param.upper().startswith("TZID="):
            return param.split("=", 1)[1]
    return None


def parse_datetime_value(val_str, params=None):
    """
    Parse an iCal date or datetime string into local wall time.

    UTC values (trailing Z), explicit numeric offsets and TZID=... parameters are
    all converted to the system timezone. Floating values (no zone information)
    are kept as-is, per RFC 5545.
    Returns: (is_all_day: bool, dt: datetime)
    """
    val_str = val_str.strip()
    if params and any("VALUE=DATE" in p.upper() for p in params):
        # e.g. 20260816
        try:
            d = datetime.strptime(val_str[:8], "%Y%m%d").date()
            return True, datetime(d.year, d.month, d.day, 0, 0, 0)
        except ValueError:
            pass

    if len(val_str) == 8 and val_str.isdigit():
        try:
            d = datetime.strptime(val_str, "%Y%m%d").date()
            return True, datetime(d.year, d.month, d.day, 0, 0, 0)
        except ValueError:
            pass

    # Capture the zone marker before it is stripped off for parsing
    is_utc = val_str.endswith("Z")
    offset_match = re.search(r"([+-])(\d\d):?(\d\d)$", val_str)

    # Try datetime formats: 20260816T143000Z or 20260816T143000
    cleaned = re.sub(r"[+-]\d\d:?\d\d$", "", val_str).rstrip("Z")
    for fmt in (
        "%Y%m%dT%H%M%S", "%Y%m%dT%H%M",
        "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"
    ):
        try:
            dt = datetime.strptime(cleaned[:19], fmt)
        except ValueError:
            continue

        if is_utc:
            return False, to_local_naive(dt, timezone.utc)
        if offset_match:
            sign = -1 if offset_match.group(1) == "-" else 1
            delta = timedelta(hours=int(offset_match.group(2)), minutes=int(offset_match.group(3)))
            return False, to_local_naive(dt, timezone(sign * delta))
        zone = resolve_timezone(extract_tzid(params))
        if zone is not None:
            return False, to_local_naive(dt, zone)
        return False, dt

    try:
        d = datetime.strptime(val_str[:8], "%Y%m%d").date()
        return True, datetime(d.year, d.month, d.day, 0, 0, 0)
    except Exception:
        return True, datetime.now()


def parse_rrule(rrule_str):
    """Parse a basic RRULE string into key-value pairs."""
    rule = {}
    for part in rrule_str.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            rule[k.upper()] = v
    return rule


def validate_meeting_url(url):
    """
    Validates and sanitizes meeting/conference URLs.
    Accepts only valid http:// or https:// URLs with well-formed hostnames.
    Rejects javascript:, file:, data:, HTML strings, control chars, quotes, and malformed URLs.
    Returns sanitized URL string or '' if invalid/unsafe.
    """
    if not isinstance(url, str) or not url:
        return ""
    url = url.strip().rstrip(";,)>]\"'")
    if not url:
        return ""
    # Reject strings with any control characters, whitespace, newlines, or HTML delimiters (<, >, ", ', `)
    if any(ord(c) < 0x21 or ord(c) > 0x7E or c in '<>"\'`' for c in url):
        return ""
    if not re.match(r"^https?://[a-zA-Z0-9.\-]+(?::\d+)?(?:/[^\s<>'\"`]*)?$", url, re.IGNORECASE):
        return ""
    try:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() not in ("http", "https"):
            return ""
        if not parsed.hostname:
            return ""
        if parsed.username or parsed.password:
            return ""
        # Validate hostname encoding
        parsed.hostname.rstrip(".").encode("idna").decode("ascii")
        return url
    except Exception:
        return ""


def extract_meeting_info(location, description, summary):
    """
    Scans text fields for video conference / meeting URLs and identifies the provider.
    Returns: (meeting_url: str, meeting_provider: str) or (None, None)
    """
    combined = f"{location}\n{description}\n{summary}"
    if not combined.strip():
        return None, None

    patterns = [
        (r'https?://meet\.google\.com/[a-zA-Z0-9\-?=_&%.\-/#+~]+', "Google Meet"),
        (r'https?://(?:[a-zA-Z0-9-]+\.)?zoom\.us/(?:j/|my/|w/|wc/join/)[a-zA-Z0-9?=_&%.\-/#+~]+', "Zoom"),
        (r'https?://(?:teams\.microsoft\.com|teams\.live\.com)/(?:l/meetup-join|meet)/[a-zA-Z0-9?=_&%.\-/#+~]+', "Teams"),
        (r'https?://[a-zA-Z0-9-]+\.webex\.com/(?:meet|join|m)/[a-zA-Z0-9?=_&%.\-/#+~]+', "Webex"),
        (r'https?://meet\.jit\.si/[a-zA-Z0-9?=_&%.\-/#+~]+', "Jitsi"),
        (r'https?://whereby\.com/[a-zA-Z0-9?=_&%.\-/#+~]+', "Whereby"),
        (r'https?://chime\.aws/[a-zA-Z0-9?=_&%.\-/#+~]+', "Amazon Chime"),
    ]

    for pat, name in patterns:
        m = re.search(pat, combined, re.IGNORECASE)
        if m:
            url = validate_meeting_url(m.group(0))
            if url:
                return url, name

    # Check if location contains any valid HTTP/HTTPS URL
    loc_url_m = re.search(r'https?://[^\s<>"\'\)\]]+', location or "")
    if loc_url_m:
        url = validate_meeting_url(loc_url_m.group(0))
        if url:
            return url, "Meeting Link"

    return None, None


def get_monthly_dates(year, month, start_dt, rrule):
    byday_str = rrule.get("BYDAY", "")
    bymonthday_str = rrule.get("BYMONTHDAY", "")
    bysetpos_str = rrule.get("BYSETPOS", "")
    num_days = calendar.monthrange(year, month)[1]

    if bymonthday_str:
        dates = []
        for mday_str in bymonthday_str.split(","):
            mday_str = mday_str.strip()
            if not mday_str:
                continue
            try:
                mday = int(mday_str)
                if mday < 0:
                    mday = num_days + 1 + mday
                if 1 <= mday <= num_days:
                    dates.append(datetime(year, month, mday, start_dt.hour, start_dt.minute, start_dt.second))
            except ValueError:
                pass
        return dates

    if byday_str:
        target_days = []
        bysetpos = int(bysetpos_str) if bysetpos_str and bysetpos_str.lstrip("-+").isdigit() else None

        for part in byday_str.split(","):
            part = part.strip()
            if not part:
                continue
            m = re.match(r"^([+-]?\d+)?([A-Za-z]{2})$", part)
            if m:
                ord_str, day_code = m.group(1), m.group(2).upper()
                if day_code in WEEKDAYS:
                    w_idx = WEEKDAYS.index(day_code)
                    ordinal = int(ord_str) if ord_str else (bysetpos if bysetpos is not None else None)

                    matching_days = [
                        d for d in range(1, num_days + 1)
                        if datetime(year, month, d).weekday() == w_idx
                    ]

                    if ordinal is not None:
                        if ordinal > 0 and ordinal <= len(matching_days):
                            target_days.append(matching_days[ordinal - 1])
                        elif ordinal < 0 and abs(ordinal) <= len(matching_days):
                            target_days.append(matching_days[ordinal])
                    else:
                        target_days.extend(matching_days)

        target_days = sorted(list(set(target_days)))
        return [datetime(year, month, d, start_dt.hour, start_dt.minute, start_dt.second) for d in target_days]

    day = start_dt.day
    if day <= num_days:
        return [datetime(year, month, day, start_dt.hour, start_dt.minute, start_dt.second)]
    return []


def expand_weekly(event, window_start, window_end, rrule, until_dt, max_count):
    start_dt = event["start_dt"]
    end_dt = event["end_dt"]
    duration = end_dt - start_dt
    interval = max(1, int(rrule.get("INTERVAL", 1)))
    byday_str = rrule.get("BYDAY", "")
    wkst_str = rrule.get("WKST", "MO").upper()
    wkst_idx = WEEKDAYS.index(wkst_str) if wkst_str in WEEKDAYS else 0

    if byday_str:
        target_weekdays = []
        for day_code in byday_str.split(","):
            code = day_code.strip()[-2:].upper()
            if code in WEEKDAYS:
                target_weekdays.append(WEEKDAYS.index(code))
        target_weekdays = sorted(list(set(target_weekdays)), key=lambda d: (d - wkst_idx) % 7)
    else:
        target_weekdays = [start_dt.weekday()]

    exdates = set(event.get("exdates", []))
    instances = []

    days_since_wkst = (start_dt.weekday() - wkst_idx) % 7
    week_start_date = (start_dt - timedelta(days=days_since_wkst)).date()

    count = 0
    cur_week_start = week_start_date
    has_count = bool(rrule.get("COUNT"))

    # Fast forward if event started long before window and has no fixed COUNT
    if not has_count and cur_week_start < (window_start - timedelta(weeks=interval)).date():
        weeks_behind = (window_start.date() - cur_week_start).days // 7
        if weeks_behind > 0:
            cur_week_start += timedelta(weeks=(weeks_behind // interval) * interval)

    iterations = 0
    while count < max_count and iterations < MAX_RECURRENCE_ITERATIONS and len(instances) < MAX_EXPANDED_INSTANCES:
        iterations += 1
        week_start_dt = datetime.combine(cur_week_start, datetime.min.time())
        if week_start_dt > window_end:
            break
        if until_dt and week_start_dt > until_dt:
            break

        for day_offset in range(7):
            cur_date = cur_week_start + timedelta(days=day_offset)
            weekday = cur_date.weekday()
            if weekday in target_weekdays:
                cur_dt = datetime.combine(cur_date, start_dt.time())
                if cur_dt < start_dt:
                    continue
                if until_dt and cur_dt > until_dt:
                    break

                count += 1
                date_key = cur_dt.strftime("%Y-%m-%d")
                if cur_dt >= window_start and cur_dt <= window_end and date_key not in exdates:
                    inst = dict(event)
                    inst["start_dt"] = cur_dt
                    inst["end_dt"] = cur_dt + duration
                    inst["date_key"] = date_key
                    instances.append(inst)

                if count >= max_count or len(instances) >= MAX_EXPANDED_INSTANCES:
                    break

        cur_week_start += timedelta(weeks=interval)

    return instances


def expand_daily(event, window_start, window_end, rrule, until_dt, max_count):
    start_dt = event["start_dt"]
    end_dt = event["end_dt"]
    duration = end_dt - start_dt
    interval = max(1, int(rrule.get("INTERVAL", 1)))
    byday_str = rrule.get("BYDAY", "")

    target_weekdays = None
    if byday_str:
        target_weekdays = []
        for day_code in byday_str.split(","):
            code = day_code.strip()[-2:].upper()
            if code in WEEKDAYS:
                target_weekdays.append(WEEKDAYS.index(code))

    exdates = set(event.get("exdates", []))
    instances = []
    cur_dt = start_dt
    count = 0
    has_count = bool(rrule.get("COUNT"))

    # Fast forward if event started long before window and has no fixed COUNT
    if not has_count and cur_dt < (window_start - timedelta(days=interval)):
        days_behind = (window_start.date() - cur_dt.date()).days
        if days_behind > 0:
            cur_dt += timedelta(days=(days_behind // interval) * interval)

    iterations = 0
    while count < max_count and cur_dt <= window_end and iterations < MAX_RECURRENCE_ITERATIONS and len(instances) < MAX_EXPANDED_INSTANCES:
        iterations += 1
        if until_dt and cur_dt > until_dt:
            break

        match = True
        if target_weekdays is not None:
            match = cur_dt.weekday() in target_weekdays

        if match:
            count += 1
            date_key = cur_dt.strftime("%Y-%m-%d")
            if cur_dt >= window_start and date_key not in exdates:
                inst = dict(event)
                inst["start_dt"] = cur_dt
                inst["end_dt"] = cur_dt + duration
                inst["date_key"] = date_key
                instances.append(inst)

        cur_dt += timedelta(days=interval)

    return instances


def expand_monthly(event, window_start, window_end, rrule, until_dt, max_count):
    start_dt = event["start_dt"]
    end_dt = event["end_dt"]
    duration = end_dt - start_dt
    interval = max(1, int(rrule.get("INTERVAL", 1)))
    exdates = set(event.get("exdates", []))

    instances = []
    cur_year = start_dt.year
    cur_month = start_dt.month
    count = 0
    has_count = bool(rrule.get("COUNT"))

    if not has_count and cur_year < window_start.year - 1:
        years_behind = window_start.year - 1 - cur_year
        cur_year += years_behind

    iterations = 0
    while count < max_count and iterations < MAX_RECURRENCE_ITERATIONS and len(instances) < MAX_EXPANDED_INSTANCES:
        iterations += 1
        month_start_dt = datetime(cur_year, cur_month, 1, 0, 0, 0)
        if until_dt and month_start_dt > until_dt:
            break
        if month_start_dt > window_end:
            break

        cand_dates = get_monthly_dates(cur_year, cur_month, start_dt, rrule)
        for cur_dt in cand_dates:
            if cur_dt < start_dt:
                continue
            if until_dt and cur_dt > until_dt:
                break
            count += 1
            date_key = cur_dt.strftime("%Y-%m-%d")
            if cur_dt >= window_start and cur_dt <= window_end and date_key not in exdates:
                inst = dict(event)
                inst["start_dt"] = cur_dt
                inst["end_dt"] = cur_dt + duration
                inst["date_key"] = date_key
                instances.append(inst)
            if count >= max_count or len(instances) >= MAX_EXPANDED_INSTANCES:
                break

        total_months = (cur_year * 12 + cur_month - 1) + interval
        cur_year = total_months // 12
        cur_month = (total_months % 12) + 1

    return instances


def expand_yearly(event, window_start, window_end, rrule, until_dt, max_count):
    start_dt = event["start_dt"]
    end_dt = event["end_dt"]
    duration = end_dt - start_dt
    interval = max(1, int(rrule.get("INTERVAL", 1)))
    exdates = set(event.get("exdates", []))
    bymonth_str = rrule.get("BYMONTH", "")

    target_months = []
    if bymonth_str:
        for m_str in bymonth_str.split(","):
            if m_str.strip().isdigit():
                m_val = int(m_str.strip())
                if 1 <= m_val <= 12:
                    target_months.append(m_val)
    if not target_months:
        target_months = [start_dt.month]

    instances = []
    cur_year = start_dt.year
    count = 0
    has_count = bool(rrule.get("COUNT"))

    if not has_count and cur_year < window_start.year - 1:
        years_behind = window_start.year - 1 - cur_year
        cur_year += (years_behind // interval) * interval

    iterations = 0
    while count < max_count and iterations < MAX_RECURRENCE_ITERATIONS and len(instances) < MAX_EXPANDED_INSTANCES:
        iterations += 1
        year_start_dt = datetime(cur_year, 1, 1, 0, 0, 0)
        if until_dt and year_start_dt > until_dt:
            break
        if year_start_dt > window_end:
            break

        for month in target_months:
            cand_dates = get_monthly_dates(cur_year, month, start_dt, rrule)
            for cur_dt in cand_dates:
                if cur_dt < start_dt:
                    continue
                if until_dt and cur_dt > until_dt:
                    break
                count += 1
                date_key = cur_dt.strftime("%Y-%m-%d")
                if cur_dt >= window_start and cur_dt <= window_end and date_key not in exdates:
                    inst = dict(event)
                    inst["start_dt"] = cur_dt
                    inst["end_dt"] = cur_dt + duration
                    inst["date_key"] = date_key
                    instances.append(inst)
                if count >= max_count or len(instances) >= MAX_EXPANDED_INSTANCES:
                    break

        cur_year += interval

    return instances


def expand_recurring_event(event, window_start, window_end):
    """
    Expands a recurring VEVENT within [window_start, window_end].
    Bounded by MAX_RECURRENCE_ITERATIONS and MAX_EXPANDED_INSTANCES.
    """
    rrule = event.get("rrule")
    if not rrule:
        return [event]

    freq = rrule.get("FREQ", "").upper()
    until_str = rrule.get("UNTIL")
    count_str = rrule.get("COUNT")

    until_dt = None
    if until_str:
        is_all_day_until, parsed_until = parse_datetime_value(until_str)
        if is_all_day_until:
            until_dt = datetime(parsed_until.year, parsed_until.month, parsed_until.day, 23, 59, 59)
        else:
            until_dt = parsed_until
        if until_dt < window_start:
            return []

    max_count = min(int(count_str) if count_str and count_str.isdigit() else 1000, 1000)

    start_dt = event["start_dt"]
    if freq == "WEEKLY":
        return expand_weekly(event, window_start, window_end, rrule, until_dt, max_count)
    elif freq == "DAILY":
        return expand_daily(event, window_start, window_end, rrule, until_dt, max_count)
    elif freq == "MONTHLY":
        return expand_monthly(event, window_start, window_end, rrule, until_dt, max_count)
    elif freq == "YEARLY":
        return expand_yearly(event, window_start, window_end, rrule, until_dt, max_count)
    else:
        if start_dt.strftime("%Y-%m-%d") not in event.get("exdates", []):
            if window_start <= start_dt <= window_end:
                return [event]
        return []


def expand_multiday_event(event, window_start, window_end):
    """
    Expands a multi-day event across all affected calendar days within the window.
    Strictly clamped to window bounds to enforce an immediate CPU work ceiling.
    """
    start_dt = event["start_dt"]
    end_dt = event["end_dt"]
    all_day = event.get("all_day", False)

    start_date = start_dt.date()
    # RFC 5545 specifies DTEND is exclusive
    if all_day:
        end_date = end_dt.date() - timedelta(days=1)
        if end_date < start_date:
            end_date = start_date
    elif end_dt > start_dt and end_dt.time() == datetime.min.time():
        end_date = end_dt.date() - timedelta(days=1)
        if end_date < start_date:
            end_date = start_date
    else:
        end_date = end_dt.date()

    if start_date == end_date:
        event["date_key"] = start_date.strftime("%Y-%m-%d")
        return [event]

    w_start_d = window_start.date()
    w_end_d = window_end.date()

    # Drop immediately if entirely outside the time window
    if end_date < w_start_d or start_date > w_end_d:
        return []

    # Clamp iteration range to the time window to enforce an immediate CPU work ceiling
    effective_start = max(start_date, w_start_d)
    effective_end = min(end_date, w_end_d)

    instances = []
    cur_date = effective_start
    max_days = (w_end_d - w_start_d).days + 10
    iterations = 0

    while cur_date <= effective_end and iterations < max_days and len(instances) < MAX_EXPANDED_INSTANCES:
        inst = dict(event)
        inst["date_key"] = cur_date.strftime("%Y-%m-%d")
        instances.append(inst)
        cur_date += timedelta(days=1)
        iterations += 1

    return instances if instances else [event]


def parse_ics(content, cal_info, window_start, window_end):
    """
    Parses an ICS file string into structured events within the time window.
    """
    lines = unfold_lines(content)
    raw_events = []
    in_vevent = False
    current = {}

    for line in lines:
        if line == "BEGIN:VEVENT":
            in_vevent = True
            current = {"exdates": []}
            continue
        elif line == "END:VEVENT":
            if in_vevent and "DTSTART" in current:
                # Skip cancelled events
                if current.get("STATUS", "").upper() != "CANCELLED":
                    raw_events.append(current)
            in_vevent = False
            current = {}
            continue

        if not in_vevent:
            continue

        parts = line.split(":", 1)
        if len(parts) != 2:
            continue
        key_part, val_part = parts[0], parts[1]

        prop_parts = key_part.split(";")
        prop_name = prop_parts[0].upper()
        prop_params = prop_parts[1:] if len(prop_parts) > 1 else []

        if prop_name == "DTSTART":
            all_day, dt = parse_datetime_value(val_part, prop_params)
            current["DTSTART"] = dt
            current["all_day"] = all_day
        elif prop_name == "DTEND":
            _, dt = parse_datetime_value(val_part, prop_params)
            current["DTEND"] = dt
        elif prop_name == "SUMMARY":
            current["SUMMARY"] = unescape_ical_text(val_part)
        elif prop_name == "LOCATION":
            current["LOCATION"] = unescape_ical_text(val_part)
        elif prop_name == "DESCRIPTION":
            current["DESCRIPTION"] = unescape_ical_text(val_part)
        elif prop_name == "UID":
            current["UID"] = val_part.strip()
        elif prop_name == "STATUS":
            current["STATUS"] = val_part.strip().upper()
        elif prop_name == "URL":
            current["URL"] = val_part.strip()
        elif prop_name == "RRULE":
            current["RRULE"] = parse_rrule(val_part)
        elif prop_name == "EXDATE":
            for ex_val in val_part.split(","):
                ex_val = ex_val.strip()
                if ex_val:
                    _, ex_dt = parse_datetime_value(ex_val, prop_params)
                    current["exdates"].append(ex_dt.strftime("%Y-%m-%d"))

    normalized = []
    for raw in raw_events:
        start_dt = raw.get("DTSTART")
        if not start_dt:
            continue
        all_day = raw.get("all_day", False)
        end_dt = raw.get("DTEND", start_dt + (timedelta(days=1) if all_day else timedelta(hours=1)))
        if end_dt < start_dt:
            end_dt = start_dt

        title = raw.get("SUMMARY", "(Untitled Event)")
        location = raw.get("LOCATION", "")
        description = raw.get("DESCRIPTION", "")
        raw_url = raw.get("URL", "")

        meeting_url, meeting_provider = extract_meeting_info(
            f"{location} {raw_url}", description, title
        )

        evt = {
            "id": raw.get("UID", f"evt_{int(start_dt.timestamp())}"),
            "title": title,
            "location": location,
            "description": description,
            "calendar": cal_info.get("name", "Calendar"),
            "color": cal_info.get("color", "#4A90E2"),
            "all_day": all_day,
            "start_dt": start_dt,
            "end_dt": end_dt,
            "date_key": start_dt.strftime("%Y-%m-%d"),
            "meetingUrl": meeting_url or "",
            "meetingProvider": meeting_provider or "",
            "rrule": raw.get("RRULE"),
            "exdates": raw.get("exdates", []),
        }

        if evt["rrule"]:
            expanded = expand_recurring_event(evt, window_start, window_end)
            for rec_inst in expanded:
                multidays = expand_multiday_event(rec_inst, window_start, window_end)
                normalized.extend(multidays)
        else:
            if start_dt.strftime("%Y-%m-%d") not in evt["exdates"]:
                multidays = expand_multiday_event(evt, window_start, window_end)
                for inst in multidays:
                    inst_dt = datetime.strptime(inst["date_key"], "%Y-%m-%d")
                    if window_start <= inst_dt <= window_end:
                        normalized.append(inst)

    return normalized

def fetch_calendar(cal_info, window_start, window_end):
    """Fetch single calendar from URL or local file."""
    name = cal_info.get("name", "Calendar")
    raw_url = cal_info.get("url", "").strip()

    if not raw_url:
        return {"name": name, "color": cal_info.get("color", "#4A90E2"), "events": [], "status": "no_url", "count": 0}

    # Convert webcal:// or webcals:// to https://
    if raw_url.startswith("webcal://"):
        url = "https://" + raw_url[9:]
    elif raw_url.startswith("webcals://"):
        url = "https://" + raw_url[10:]
    elif raw_url.startswith("http://") or raw_url.startswith("https://") or raw_url.startswith("file://"):
        url = raw_url
    else:
        # Fallback to https:// or local path
        if os.path.exists(os.path.expanduser(raw_url)):
            url = os.path.expanduser(raw_url)
        else:
            url = "https://" + raw_url

    try:
        if url.startswith("file://") or url.startswith("/"):
            path = url[7:] if url.startswith("file://") else url
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                content = safe_read_text(f, max_bytes=MAX_ICAL_BYTES)
        else:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=12) as resp:
                raw = safe_read_bytes(resp, max_bytes=MAX_ICAL_BYTES)
                content = raw.decode("utf-8", errors="ignore")

        events = parse_ics(content, cal_info, window_start, window_end)
        return {
            "name": name,
            "color": cal_info.get("color", "#4A90E2"),
            "events": events,
            "status": "ok",
            "count": len(events),
        }
    except Exception as e:
        return {
            "name": name,
            "color": cal_info.get("color", "#4A90E2"),
            "events": [],
            "status": f"error: {str(e)}",
            "count": 0,
        }

def purge_plugin_data():
    """Remove the calendar config and cached event state."""
    removed = []
    for path in (CONFIG_PATH, OUTPUT_PATH):
        try:
            if os.path.exists(path):
                os.unlink(path)
                removed.append(path)
        except OSError:
            pass
    return {"status": "success", "removed": removed}


def sync_all_events():
    """Fetch every enabled feed and write calendar-events.json."""
    ensure_config_exists()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)

    try:
        calendars = safe_load_json(CONFIG_PATH, max_bytes=MAX_CONFIG_BYTES) or []
    except Exception:
        calendars = []

    now = datetime.now()
    window_start = now - timedelta(days=45)
    window_end = now + timedelta(days=90)

    enabled_cals = [
        c for c in calendars
        if c.get("enabled", True) and c.get("url")
    ]

    all_events = []
    cal_statuses = []

    if enabled_cals:
        with ThreadPoolExecutor(max_workers=min(8, len(enabled_cals))) as executor:
            futures = [
                executor.submit(fetch_calendar, c, window_start, window_end)
                for c in enabled_cals
            ]
            for f in futures:
                res = f.result()
                all_events.extend(res["events"])
                cal_statuses.append({
                    "name": res["name"],
                    "color": res["color"],
                    "status": res["status"],
                    "count": res["count"],
                })

    events_by_date = {}
    for evt in all_events:
        d_key = evt["date_key"]
        if d_key not in events_by_date:
            events_by_date[d_key] = []

        start_time_str = evt["start_dt"].strftime("%H:%M")
        end_time_str = evt["end_dt"].strftime("%H:%M")

        events_by_date[d_key].append({
            "id": evt["id"],
            "title": evt["title"],
            "calendar": evt["calendar"],
            "description": evt.get("description", ""),
            "color": evt["color"],
            "allDay": evt["all_day"],
            "startTime": start_time_str if not evt["all_day"] else "All Day",
            "endTime": end_time_str if not evt["all_day"] else "",
            "location": evt["location"],
            "startIso": evt["start_dt"].isoformat(),
            "meetingUrl": evt.get("meetingUrl") or "",
            "meetingProvider": evt.get("meetingProvider") or "",
        })

    for d_key in events_by_date:
        events_by_date[d_key].sort(
            key=lambda x: (0 if x["allDay"] else 1, x["startTime"], x["title"])
        )

    output_data = {
        "lastSynced": int(time.time()),
        "lastSyncedFormatted": now.strftime("%H:%M"),
        "totalEvents": len(all_events),
        "configuredCount": len(enabled_cals),
        "calendars": cal_statuses,
        "eventsByDate": events_by_date,
    }

    write_secure_json(OUTPUT_PATH, output_data, mode=0o600, max_bytes=MAX_OUTPUT_JSON_BYTES)

    return {
        "status": "success",
        "totalEvents": len(all_events),
        "calendars": len(cal_statuses),
    }


def read_stdin_payload(max_bytes=MAX_CONFIG_BYTES):
    """Read a JSON payload from stdin without blocking or deadlocking."""
    try:
        line = sys.stdin.readline()
        if line and line.strip():
            return line
    except Exception:
        pass
    try:
        return sys.stdin.read(max_bytes + 1)
    except Exception:
        return ""


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("--purge-data", "--cleanup", "--uninstall"):
        res = purge_plugin_data()
        print(json.dumps(res, indent=2))
        sys.exit(0)

    ensure_config_exists()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)

    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "--save-config":
            try:
                raw_input = sys.argv[2] if len(sys.argv) > 2 else read_stdin_payload(MAX_CONFIG_BYTES)
                if len(raw_input) > MAX_CONFIG_BYTES:
                    raise ValueError(f"Config payload exceeds maximum size of {MAX_CONFIG_BYTES} bytes")
                new_config = json.loads(raw_input)
                if not isinstance(new_config, list):
                    raise ValueError("Config must be a JSON array of calendar entries")
                write_secure_json(CONFIG_PATH, new_config, mode=0o600)
                print(json.dumps({"status": "success"}))
                sys.exit(0)
            except Exception as e:
                print(json.dumps({"status": "error", "message": str(e)}))
                sys.exit(1)
        elif arg == "--get-config":
            content = safe_load_json(CONFIG_PATH, max_bytes=MAX_CONFIG_BYTES)
            print(json.dumps(content, ensure_ascii=False, indent=2))
            sys.exit(0)

    result = sync_all_events()
    print(json.dumps(result))


if __name__ == "__main__":
    main()
