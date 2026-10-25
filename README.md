# rs-nest

**Keeps Red Shield VPN in the data path on macOS when Perimeter 81 rewrites the routing table. Runs the Perimeter 81 tunnel inside Red Shield.**

![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple) ![pf](https://img.shields.io/badge/engine-pf%20route--to-blue) ![bash](https://img.shields.io/badge/bash-3.2%2B-green?logo=gnubash) ![license](https://img.shields.io/badge/license-MIT-lightgrey)

```
 apps ─► en0 ─┐ pf route-to  ┌────────────┐   ┌──────────────┐
              └─────────────►│ Red Shield │──►│ Perimeter 81 │─► corporate
                             │ utunN      │   │ (nested)     │
 LAN, RS servers ─► en0      └─────┬──────┘   └──────────────┘
                                   └──────────────────────────► internet
```

## The problem

Perimeter 81 (sold as Check Point Harmony SASE) installs a root helper, `com.perimeter81d`.
The helper runs while the app is disconnected. On start, and on each routing change it sees, the helper:

- deletes the `0.0.0.0/1` and `128.0.0.0/1` routes that a VPN client installs on its `utun`.
  Traffic then leaves through the physical interface with your real IP. The VPN app still shows *Connected*.
- pins its own gateways to the LAN router. The Perimeter 81 tunnel can not run inside another tunnel.
- runs `pfctl -d`, which switches the packet filter off.

Red Shield depends on those two routes in both of its modes, AmneziaWG and sing-box "RedLink TLS Plus".
So the two clients do not work together. And if a network blocks the Perimeter 81 endpoints, Perimeter 81 can not connect at all.

## How rs-nest works

rs-nest does not touch the routing table. It uses pf policy routing, which the Perimeter 81 helper does not change:

```pf
nat on utunN inet from ! <tun ip> to any -> <tun ip>
pass out quick on en0 inet from any \
    to { <LAN> 169.254/16 224/4 255.255.255.255 <RS servers> } no state
pass out quick on en0 route-to (utunN <tun ip>) inet from any to any keep state
```

The kernel picks the physical interface for a packet. `route-to` then moves the packet into the Red Shield tunnel.
LAN traffic and Red Shield's own server traffic stay on the physical interface.
Perimeter 81 gateway traffic matches the same rule. So the Perimeter 81 tunnel runs inside Red Shield, and the corporate side sees the Red Shield exit IP.

A root daemon of about 100 lines keeps the rules current:

| event | action |
|---|---|
| The Red Shield `utun` appears. The daemon reads its address from `redlink.conf` or `redlink.json`. | load the anchor for that interface |
| The Red Shield `utun` disappears. | flush the anchor; with Red Shield off, nothing is changed |
| The Perimeter 81 helper flushes routes. | nothing; the routes do not matter |
| The Perimeter 81 helper runs `pfctl -d`. | run `pfctl -e` within 10 s |
| The Red Shield daemon replaces the main pf ruleset. | add the `anchor "rs-nest"` reference again |
| The default interface changes, for example Wi-Fi to Ethernet. | generate the rules for the new interface |

The daemon is event-driven. It blocks on `route -n monitor`, the kernel routing socket, and wakes on interface, address and route changes.
The only poll is a `pfctl -s info` check every 10 s, because `pfctl -d` raises no routing event. Idle CPU use is zero.

## Install

```sh
git clone https://github.com/taburetka123/rs-nest && cd rs-nest
sudo ./install.sh
```

To verify, connect Red Shield and run these commands before and after you start Perimeter 81:

```sh
curl https://api.ipify.org        # shows the Red Shield exit IP both times
tail "/Library/Application Support/rs-nest/rs-nest.log"
```

```
[13:34:12] loaded tun=utun7 ip=198.18.201.193 ext=en0 lan=192.168.1.0/24 ep=[...]
[13:34:30] pf was disabled; re-enabled
```

To remove: `sudo ./uninstall.sh`.

## Files

| path | what |
|---|---|
| `/usr/local/sbin/rs-nest.sh` | the daemon |
| `/Library/LaunchDaemons/local.rs-nest.plist` | runs the daemon as root, restarts it, starts it at boot |
| `/Library/Application Support/rs-nest/` | the generated pf files and the log |

## Limits

- **Kill switch.** If the Red Shield `utun` exists but the tunnel is dead, no traffic leaves the machine until Red Shield reconnects.
  If you prefer a leak to a dead link, add a health check to `reconcile()`.
- **Switch order.** The Perimeter 81 tunnel runs inside Red Shield, so a Red Shield restart kills it.
  Disconnect Perimeter 81, then restart Red Shield, then connect Perimeter 81 again. In another order Perimeter 81 can hang and needs a restart.
- **Main ruleset.** The daemon replaces the main pf ruleset with a copy of the Red Shield `root.conf` plus the anchor line.
  If a Red Shield update changes `root.conf`, update the heredoc in `load()`.
- **MTU.** The Red Shield tunnel MTU is 1280 bytes, and the Perimeter 81 tunnel runs inside it.
  Expect a few percent of extra overhead on corporate traffic.

## Tested on

macOS 26, Red Shield VPN 4.1.x (AmneziaWG and RedLink TLS Plus), Check Point SASE 13.1.
Only the motivation is specific to Perimeter 81. The daemon handles any helper that rewrites routes or disables pf the same way.

## License

[MIT](LICENSE)
