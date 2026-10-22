# WhereDidMyTimeGo

I built this while learning DevOps. Bash was the first thing I wanted to understand, so I learned it by building this project. A small KWin script reports the focused application to a Bash daemon, which records app changes and idle, lock, and suspend boundaries, then turns that log into daily and weekly reports.

## Try it

It runs on KDE Plasma 6 with Wayland. The required tools are Bash 5, `qdbus6`, `busctl`, `jq`, and `flock`. Idle detection also needs the optional C helper and Wayland development files.

```bash
git clone https://github.com/tinsaeabreham45/WhereDidMyTimeGo.git
cd WhereDidMyTimeGo
./detective.sh start
./detective.sh status
./detective.sh report
```

## Commands

| Command | What it does |
| --- | --- |
| `./detective.sh start` | Start tracking in the background. |
| `./detective.sh stop` | Stop tracking and close the current interval. |
| `./detective.sh restart` | Stop and start again. |
| `./detective.sh status` | Show the current app and tracker state. |
| `./detective.sh pause` | Stop recording app changes. |
| `./detective.sh resume` | Resume recording. |
| `./detective.sh report [--date YYYY-MM-DD] [--no-color]` | Show a daily report. |
| `./detective.sh weekly [--date YYYY-MM-DD] [--no-color]` | Show a Monday-Sunday weekly report. |
| `./detective.sh config show` | Show the current configuration. |
| `./detective.sh config edit` | Edit the configuration file. |
| `./detective.sh config path` | Print the configuration file path. |
| `./detective.sh config init` | Create the default configuration. |
| `./detective.sh build` | Build the optional idle helper. |
| `./detective.sh export [--format csv\|json] [--output PATH] [--force]` | Export events. |
| `./detective.sh delete [--before YYYY-MM-DD] [--yes]` | Preview or delete activity data. |
| `./detective.sh help` | Show command help. |
| `./detective.sh version` | Show the version. |

`status` exits with code 0 while tracking and 3 when stopped. `delete` only previews unless `--yes` is supplied.

Activity data stays in `~/.local/share/wheredidmytimego/` as monthly CSV files. The tracker records application IDs, timestamps, and event types; it does not collect window titles or send data over the network.
