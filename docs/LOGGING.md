# Logging

The rules for logging in the app and its extensions. Every spec includes a
**Logging** section that points here and lists the events to log for that
change.

## Why

The tunnel runs in the background, inside an extension you can't attach a UI
to. When something goes wrong on a device, the logs are often the only way to
see what happened. New code should log enough that a problem can be traced
from the logs alone.

## API

- Use Apple's unified logging (`os.Logger`). Don't use `print` or `NSLog`.
- **Subsystem:** `com.iblocker`, the same for every target, so one filter
  shows everything.
- **Category:** the component, for example `tunnel`, `engine`, `upstream`,
  `network-dns`, `path`, `lists`, `settings`, `ui`.
- `IBlockerKit` must still compile and test on Linux, where `os` isn't
  available. Code there logs through a small wrapper in `IBlockerKit` that
  uses `os.Logger` on Apple platforms and does nothing on Linux. Create the
  wrapper the first time it's needed, and reuse it after that.

The existing tunnel logger (`PacketTunnelProvider`, subsystem
`com.iblocker.tunnel`) moves to subsystem `com.iblocker`, category `tunnel`,
the next time that file is changed.

## Levels

| Level | Use for | Examples |
|---|---|---|
| `error` | Something failed that shouldn't have | upstream error, file can't be read, IPC message can't be decoded, settings can't be applied |
| `notice` | Important state changes, rare | tunnel start/stop, upstream switched, alternative resolver marked down or back up |
| `info` | Normal events, at most a few per minute | network path changed (old → new interface), rules reloaded (with counts), list refresh result |
| `debug` | Per-query and step-by-step detail | each lookup's verdict and which upstream answered it, upstream timing, raw `dns_sd` results, retry decisions |

- **Never log per query above `debug`.** There can be hundreds of lookups a
  minute. `info` and above are stored on the device, so logging every query
  there costs battery and storage.
- Log **both sides** of anything that can fail or hang: started → succeeded
  or failed, with the duration where it matters (upstream queries, list
  downloads).
- Errors include the reason (error code or message) and enough context to act
  on: which upstream, which interface, which file.

## Privacy

- Domain names and IP addresses reveal browsing activity. Log them **only at
  `debug` level**, marked `privacy: .public`. Debug messages are kept in memory
  only and are visible while streaming logs; they aren't written to disk.
- At `info` and above, don't log domain names. Log counts, types, states and
  error codes instead.
- Resolver names and URLs (Cloudflare, `https://1.1.1.1/dns-query`) and
  interface names (`en0`, `pdp_ip0`) aren't personal. Log them `.public` at
  any level.

## Reading the logs

- **Console.app on the Mac:** connect the iPhone, select it in the sidebar,
  turn on **Action ▸ Include Info Messages** and **Include Debug Messages**,
  then filter on `subsystem:com.iblocker`. Narrow it with `category:`.
- **Xcode:** messages from the app show in the debug console while running
  from Xcode. For the tunnel extension, use Console.app, since the extension
  runs in its own process.

## In specs

Every spec has a `## Logging` section that:

1. Links to this file.
2. Lists the specific events the change must log, with their levels.

Add an acceptance criterion that the listed events are logged at the stated
levels. The reviewer checks it.
