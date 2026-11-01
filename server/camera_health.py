# A camera's health: its battery and how hot the phone is running. The
# camera reports it over the socket as `camera-health` (on connect, every
# minute, and when it's plugged in or unplugged); the server keeps the last
# report on the device row, so an offline camera still shows how it was
# when it dropped off.
#
# Phones only expose temperature as a coarse level, not degrees (iOS has no
# API for degrees at all), so `thermal_state` is iOS's four
# ProcessInfo.ThermalState levels, with Android's thermal statuses mapped
# onto them by the app.

THERMAL_STATES = ('nominal', 'fair', 'serious', 'critical')

# At or below this, an unplugged camera's battery counts as low.
LOW_BATTERY_PERCENT = 20

COLUMNS = ('battery_level', 'battery_charging', 'thermal_state')


def parse_report(data):
    """The health columns from a camera's report. A field the phone couldn't
    read (e.g. no thermal API on an old Android) or that's malformed is None."""
    data = data if isinstance(data, dict) else {}
    level = data.get('battery_level')
    charging = data.get('battery_charging')
    thermal = data.get('thermal_state')
    return {
        # bool is an int subclass, so it's ruled out explicitly.
        'battery_level': level if isinstance(level, int) and not isinstance(level, bool) and 0 <= level <= 100 else None,
        'battery_charging': charging if isinstance(charging, bool) else None,
        'thermal_state': thermal if thermal in THERMAL_STATES else None,
    }


def from_row(row):
    """The health part of a device row, for rosters; None if the camera has
    never reported. SQLite stores the boolean as 0/1."""
    if all(row.get(column) is None for column in COLUMNS):
        return None
    charging = row.get('battery_charging')
    return {
        'battery_level': row.get('battery_level'),
        'battery_charging': None if charging is None else bool(charging),
        'thermal_state': row.get('thermal_state'),
    }


def _battery_low(health):
    return (
        health is not None
        and health['battery_level'] is not None
        and health['battery_level'] <= LOW_BATTERY_PERCENT
        and not health['battery_charging']
    )


def _running_hot(health):
    return health is not None and health['thermal_state'] in ('serious', 'critical')


def alerts_for(previous, current):
    """The alerts a change in health calls for: 'battery-low' as an unplugged
    battery drops to the threshold (or is unplugged below it), and 'hot' as
    the phone starts throttling. Only on the change, so a camera that stays
    low isn't re-announced every minute; `previous` comes from the database,
    so a reconnect or server restart doesn't repeat them either."""
    alerts = []
    if _battery_low(current) and not _battery_low(previous):
        alerts.append('battery-low')
    if _running_hot(current) and not _running_hot(previous):
        alerts.append('hot')
    return alerts
