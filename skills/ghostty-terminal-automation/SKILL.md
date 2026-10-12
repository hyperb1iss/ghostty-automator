---
name: ghostty-terminal-automation
description: Control and inspect Ghostty Automator terminal sessions from the CLI. Use for TUI interaction, terminal screenshots, rendered screen reads, keyboard or mouse input, and window management. Requires the Automator build, not stock Ghostty.
---

# Ghostty Terminal Automation

Use `ghostty-automator +<action>` to inspect and control real terminal surfaces.
The binary includes the terminal and its socket client. No MCP server or Python
package is required. Use your host's shell execution and image inspection tools.

## Locate and bootstrap

Find `ghostty-automator` on PATH. If missing, check
`~/.local/bin/ghostty-automator` and use that absolute path in every command.
Shell environment changes may not persist between tool calls.

If neither path exists, install the binary and skill:

```bash
curl -fsSL https://raw.githubusercontent.com/hyperb1iss/ghostty-automator/automator/install.sh | bash
```

The installer defaults to `~/.local`, installs this skill under `~/.agents/skills`,
and links it under `~/.claude/skills` when no separate Claude skill exists.
Run `install.sh --help` for custom paths or local build/archive installation.

Check `ghostty-automator +help` after locating or installing the binary. Older
releases such as `v1.3.1-auto.1` predate doctor and bootstrap. If those actions
are missing, update with the installer above. You can also install a source build
with `bash install.sh --build-dir zig-out` from the checkout or install a matching
local archive. The [repository README](https://github.com/hyperb1iss/ghostty-automator#build-and-package)
has build instructions. Do not retry an unknown action or infer that its
failure means the terminal is unreachable.

```bash
ghostty-automator +doctor
ghostty-automator +bootstrap
```

The diagnostic command (`+doctor`) does not launch the app. Its JSON reports the
binary, socket, capabilities, and a `data.next_command` argv array. A failed
connectivity check can mean the app has not started yet; use the reported next
command rather than reinstalling a working binary.

The bootstrap command (`+bootstrap`) launches Automator if needed and waits for
an initialized terminal grid. Parse `data.surface_id` from its successful JSON response:

```json
{
  "schema_version": 1,
  "ok": true,
  "data": {
    "surface_id": "0x153872000",
    "socket_path": "/run/user/1000/ghostty-automator/ghostty-automator.sock",
    "started": false,
    "status": "reused",
    "log_path": null
  },
  "error": null
}
```

The example shows selected fields; the response also includes the full
`data.windows` hierarchy. The status is `reused`, `created`, or
`launched`. The `started` field records ownership of a directly launched Linux
process; macOS leaves it false because LaunchServices does not expose the GUI
PID. Reuse prefers a focused surface, then an active-tab surface, then the
first surface. Read the selected surface before sending input. When a separate
test terminal is needed, open `+new-window` and compare discovery before and
after to identify the new surface.

Bootstrap accepts `--timeout-ms=10000` (the default), `--working-directory=<path>`,
and `--command=<string>`. The directory defaults to the caller's cwd. Directory
and command apply only when launching or creating a window, not to reused
sessions. A failed launch includes diagnostics; inspect the error and startup
log rather than repeatedly launching competing instances.

On Linux, use a valid GTK application ID with `--class=<id>` for a separate
instance, and pass the same class to all later actions. macOS uses one socket;
bootstrap rejects custom classes. Launching requires a graphical desktop.

## Discover and read

```bash
ghostty-automator +list-surfaces --format=json
ghostty-automator +get-screen --surface=<id> --format=json
```

Discovery output contains `windows` at the top level:

```json
{
  "windows": [
    {
      "id": "0xABC",
      "focused": true,
      "tabs": [
        {
          "id": "0xDEF",
          "title": "zsh",
          "active": true,
          "surfaces": [
            {
              "id": "0x153872000",
              "title": "zsh",
              "focused": true,
              "pwd": "/home/user",
              "rows": 24,
              "cols": 80
            }
          ]
        }
      ]
    }
  ]
}
```

Discovery and screen commands print the socket's `data` object directly,
without an `ok`/`data` wrapper. Additional unused fields may be null. Doctor and
bootstrap use the versioned envelope shown above.

Screen JSON contains `content`, `cursor_x`, and `cursor_y`. Use raw text when
cursor position is unnecessary:

```bash
ghostty-automator +get-screen --surface=<id>
ghostty-automator +get-screen --surface=<id> --screen=active
ghostty-automator +get-screen --surface=<id> --screen=screen
```

The default `viewport` is currently visible content. The `active` screen excludes
scrollback; `screen` includes it. Treat IDs as opaque, valid only while the
surface exists. Rediscover after a close or restart.

## Send input

Text goes to the PTY without appending Enter. The CLI decodes escapes including
`\r`, `\n`, `\t`, `\\`, `\e`, `\0`, and `\xNN`. Use `\r` to execute a shell command;
quote arguments so the calling shell does not expand them unexpectedly.

```bash
ghostty-automator +send-text --surface=<id> --text='ls -la\r'
ghostty-automator +send-text --surface=<id> --text='partial input'
ghostty-automator +send-key --surface=<id> --key=Enter
ghostty-automator +send-key --surface=<id> --key=Escape
ghostty-automator +send-key --surface=<id> --key=KeyC --mods=ctrl
ghostty-automator +send-key --surface=<id> --key=ArrowUp
```

Key names use W3C codes: `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`,
`ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`,
`PageDown`, `F1` through `F12`, `KeyA` through `KeyZ`, and `Digit0` through
`Digit9`. Modifiers are comma-separated `ctrl`, `shift`, `alt`, and `super`.

Mouse coordinates are surface-relative pixels. Click with a press and release:

```bash
ghostty-automator +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=press
ghostty-automator +send-mouse --surface=<id> --x=100 --y=200 --button=left --button-action=release
ghostty-automator +send-scroll --surface=<id> --y=3
ghostty-automator +send-scroll --surface=<id> --y=-5
```

Positive vertical scroll moves down; negative moves up.

## Observe completion and capture

An input acknowledgement confirms delivery, not command completion. Read the
screen until the expected output or application state appears, with a deadline
appropriate to the operation. A fixed sleep is not a readiness check. For shell
commands, a unique completion marker and exit status can distinguish finished
output from a still-running process; match the marker's output line, not only
its appearance in the echoed command.

For a TUI, inspect screen state before a mode-dependent key. For example, after
opening Neovim, confirm its interface is visible before pressing `KeyI`; confirm
insert mode before typing; return with `Escape` before sending `:wq\r`.

```bash
ghostty-automator +screenshot-surface --surface=<id> --output=/tmp/terminal.png
```

Open the PNG with the host's image inspection tool to check colors, layout,
selection, and clipping. Output paths must be absolute and must not contain
`..` components. The normal CLI returns text and cursor position on both
platforms. Styled cells require the macOS-only raw socket extension; do not
request `--format=cells` from this CLI.

## Manage windows

```bash
ghostty-automator +new-window
ghostty-automator +new-tab
ghostty-automator +focus-surface --surface=<id>
ghostty-automator +resize-surface --surface=<id> --rows=40 --cols=120
ghostty-automator +close-surface --surface=<id>
```

Use the surface requested by the user or created for this task. Close only a
surface whose work is finished; focus and resize affect the user's desktop.

The shipped protocol does not implement `wait_for`, `send_keys`, `focused`
aliases, or inline screenshot base64. Use explicit discovered IDs and the
commands above. Automation actions return exit code 0 on success and 1 on
failure; read stderr and any JSON error rather than treating empty output as
success. Run `ghostty-automator +<action> --help` for command-specific flags.
