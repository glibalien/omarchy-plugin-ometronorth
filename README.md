# OmetroNorth

Next MTA Metro-North trains on the [Omarchy](https://omarchy.org) bar.

The bar shows the time of the next train from your origin to your destination,
and turns red when that train is running late. Click it for a panel with the
next three departures and, in a separate section, the next three arrivals at
the destination — each with delay status, route, track (when the feed knows
it), and a countdown.
![Expanded panel](preview.png?v=2)

- **Live data** — reads MTA's Metro-North GTFS-RT feed, so times and delays
  are the railroad's own real-time estimates.
- **Configurable route** — pick origin and destination from a searchable list
  of every Metro-North station right in the panel (or pin them in settings).
  A swap button flips the commute for the ride home.
- **Late means red** — the bar time and the panel rows highlight once a train
  is at least `lateMinutes` behind.
- **Zero dependencies** — the helper is python3 stdlib only and decodes the
  GTFS-RT protobuf itself. Nothing runs as root.

## Install

```bash
omarchy plugin add https://github.com/brianstarke/omarchy-plugin-ometronorth --enable
```

## Settings

In `~/.config/omarchy/shell.json`, on the widget entry:

| Key | Default | Meaning |
|-----|---------|---------|
| `from` | `"Grand Central"` | Origin station. Any name from the station list (also accept stop ids); unique substrings work too. |
| `to` | `"White Plains"` | Destination station. |
| `apiKey` | `""` | MTA API key from <https://api.mta.info>. The feed currently answers without one; set this if that changes or you hit rate limits. |
| `interval` | `60` | Background poll interval in seconds while the panel is closed (minimum 30). The open panel polls every 15 s. |
| `lateMinutes` | `5` | Delay threshold in minutes before a train counts as late (and turns red). |

```json
{ "id": "brianstarke.ometronorth", "from": "Grand Central", "to": "Croton-Harmon", "lateMinutes": 3 }
```

Stations picked in the panel are saved to
`~/.local/state/omarchy/brianstarke.ometronorth.json` and take precedence over `from`/`to`
until you pick again. Delete that file to fall back to the settings.

## Keys

With the panel open: `r` refreshes, `s` swaps the route, `Esc` closes,
`Tab`/`Shift+Tab` moves to the neighboring panel. The station pickers are
fully keyboard-driven (type to filter, arrows to move, Enter to select).

## Uninstall

```bash
omarchy plugin remove brianstarke.ometronorth
```

## License

MIT — see [LICENSE](LICENSE).
