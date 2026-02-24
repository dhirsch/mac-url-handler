# macOS URL Handler Tool

A practical CLI for people who want control over which macOS apps open links.

macOS lets you set default apps for broad schemes like `http`, `https`, and `mailto`, but it does not natively let you route specific domains (for example, `meet.google.com`) to a different app. This tool solves that gap:

- inspect and change scheme handlers quickly
- verify your setup with a built-in doctor check
- install a lightweight shim that routes specific hosts to specific apps while keeping a default browser fallback

## What it does

- `list`: show URL scheme handlers currently recorded in LaunchServices.
- `doctor`: run health checks for shim install, handlers, and config.
- `get <scheme>`: show the app bundle ID currently handling a URL scheme.
- `set <scheme> <bundle-id>`: set the default app for a scheme.
- `open <url>`: open a URL to verify handler behavior.
- `host-rule ...`: manage host-based routing rules for the shim app.
- `build-shim`: build `~/Applications/URLHandlerShim.app`.
- `install-shim`: build shim and set `http/https` handlers to shim.

## Run directly

```bash
cd macos-url-handlers
chmod +x url-handler.swift
./url-handler.swift get mailto
```

## Examples

```bash
./url-handler.swift doctor
./url-handler.swift list
./url-handler.swift get mailto
./url-handler.swift set mailto com.apple.mail
./url-handler.swift open mailto:test@example.com
```

## Host-based routing

Because macOS only supports defaults by scheme (`https`), this shim app can route by hostname.

```bash
./url-handler.swift host-rule init
./url-handler.swift host-rule add meet.google.com us.zoom.xos
./url-handler.swift host-rule add "*.figma.com" com.google.Chrome
./url-handler.swift host-rule list
./url-handler.swift install-shim
```

### How routing works

- If a host rule matches, the URL opens in that app.
- Otherwise it opens in the configured fallback browser (`defaultHTTPSBundleID`).
- Rules support exact hosts (`meet.google.com`) and wildcard rules (`*.example.com`).
- Matching is host-based, so `meet.google.com` covers all paths on that host (for example, `/abc-defg-hij`).

### When to run `install-shim`

- Run it the first time (or any time macOS handler assignments need to be repaired/reset).
- You do **not** need to run it after each `host-rule add/remove/default` change.
- Rule changes are read from config on each new open.

To change fallback browser:

```bash
./url-handler.swift host-rule default com.apple.Safari
```

To revert:

```bash
./url-handler.swift set https com.apple.Safari
./url-handler.swift set http com.apple.Safari
```

## Notes

- Uses LaunchServices (`LSSetDefaultHandlerForURLScheme`) and LaunchServices preferences for listing handlers.
- Setting handlers may require a valid installed app bundle ID (for example: `com.apple.Safari`).
- Shim config location: `~/Library/Application Support/URLHandlerShim/config.json`.

## License

MIT. See `LICENSE`.
