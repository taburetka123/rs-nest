# rs-nest

**Run a corporate VPN inside Red Shield VPN on macOS — and stop the corporate client from kicking Red Shield off the routing table.**

![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple) ![pf](https://img.shields.io/badge/engine-pf%20route--to-blue) ![bash](https://img.shields.io/badge/bash-3.2%2B-green?logo=gnubash) ![license](https://img.shields.io/badge/license-MIT-lightgrey)

```
 apps ─► en0 ─┐ pf route-to  ┌────────────┐   ┌──────────────┐
              └─────────────►│ Red Shield │──►│ Perimeter 81 │─► corporate
                             │ utunN      │   │ (nested)     │
 LAN, RS servers ─► en0      └─────┬──────┘   └──────────────┘
                                   └──────────────────────────► internet
```

## Why

[Perimeter 81](https://www.perimeter81.com) / Check Point Harmony SASE installs a root helper
(`com.perimeter81d`) that runs even when you are not connected. On start, and on every routing
change it notices, it:

- **deletes the `0.0.0.0/1` + `128.0.0.0/1` routes** every VPN client installs on its `utun` —
  your traffic silently falls back to the physical interface and your real IP, while the VPN
  app still says *Connected*;
- pins its own gateways to the LAN router, so the corporate tunnel can never be nested;
- runs **`pfctl -d`**, switching the packet filter off.

Red Shield VPN (AmneziaWG and sing-box "RedLink TLS Plus" modes alike) depends on exactly those
routes. Result: the two clients cannot coexist, and the corporate one cannot be reached from
networks where its endpoints are blocked.

## How it works

rs-nest does not fight for the routing table. It uses **pf policy routing**, which the corporate
daemon never touches:

```pf
nat on utunN inet from ! <tun ip> to any -> <tun ip>
pass out quick on en0 inet from any to { <LAN> 169.254/16 224/4 255.255.255.255 <RS servers> } no state
pass out quick on en0 route-to (utunN <tun ip>) inet from any to any keep state
```

Whatever the kernel decides to send out of the physical interface, `route-to` redirects into the
Red Shield tunnel. The LAN and Red Shield's own server traffic stay direct. The corporate client's
gateway traffic hits the same rule, so its tunnel is **nested inside Red Shield** — the corporate
side sees Red Shield's exit IP, and a blocked corporate endpoint becomes reachable.

A ~100-line root daemon keeps the rules honest:

| event | action |
|---|---|
| Red Shield `utun` appears (address read from its own `redlink.conf` / `redlink.json`) | load the anchor for that interface |
| Red Shield `utun` disappears | flush the anchor — nothing is changed while Red Shield is off |
| corporate daemon flushes routes | nothing to do: routes are irrelevant |
| corporate daemon runs `pfctl -d` | `pfctl -e` within 10 s |
| Red Shield's daemon replaces the main pf ruleset | re-add the `anchor "rs-nest"` reference |
| default interface changes (Wi-Fi → Ethernet) | regenerate the rules for the new interface |

It is **event-driven**: the daemon blocks on `route -n monitor` (the kernel routing socket) and
wakes only on interface, address or route changes. The single poll is a 10-second
`pfctl -s info` check, because `pfctl -d` raises no routing event. Idle CPU: zero.

## Install

```sh
git clone https://github.com/taburetka123/rs-nest && cd rs-nest
sudo ./install.sh
```

Verify — with Red Shield connected, before and after starting the corporate client:

```sh
curl https://api.ipify.org        # Red Shield's exit IP, both times
tail "/Library/Application Support/rs-nest/rs-nest.log"
```

```
[2026-10-25 13:34:12] loaded tun=utun7 ip=198.18.201.193 ext=en0 lan=192.168.1.0/24 ep=[... ...]
[2026-10-25 13:34:30] pf was disabled; re-enabled
```

Uninstall: `sudo ./uninstall.sh`.

## Files

| path | what |
|---|---|
| `/usr/local/sbin/rs-nest.sh` | the daemon |
| `/Library/LaunchDaemons/local.rs-nest.plist` | runs it as root, restarts it, starts at boot |
| `/Library/Application Support/rs-nest/` | generated pf files and the log |

## Caveats

- **Kill-switch by construction.** While Red Shield's `utun` exists but its tunnel is dead, all
  traffic is black-holed until Red Shield reconnects. If you would rather leak than lose
  connectivity, add a health check to `reconcile()`.
- **Switch order.** The corporate tunnel lives inside Red Shield and cannot survive a Red Shield
  restart. Disconnect the corporate client → toggle Red Shield → reconnect it. Otherwise the
  corporate client may hang and need a restart.
- **Main ruleset.** The daemon replaces the main pf ruleset with a copy of Red Shield's
  `root.conf` plus the anchor line. A Red Shield update that changes `root.conf` needs the
  heredoc in `load()` updated.
- **MTU.** Red Shield's tunnel is 1280 bytes; the nested corporate tunnel sits inside it.
  Expect a few percent of extra overhead on corporate traffic, not a visible slowdown.

## Tested on

macOS 26, Red Shield VPN 4.1.x (AmneziaWG and RedLink TLS Plus), Check Point SASE 13.1.
Nothing is specific to Perimeter 81 beyond the motivation: any daemon that rewrites routes or
disables pf is handled the same way.

## License

[MIT](LICENSE)
