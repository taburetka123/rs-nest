#!/bin/bash
# rs-nest: keep all outbound traffic of the default interface inside the Red Shield tunnel via pf route-to,
# independent of the routing table (Perimeter 81 daemon rewrites it).
# Loaded only while a Red Shield tunnel interface exists; flushed when it disappears.
# The macOS user whose Red Shield VPN config to read (default: the console user).
RS_USER="${RS_USER:-$(stat -f %Su /dev/console 2>/dev/null)}"
RS="/Users/$RS_USER/Library/Application Support/redshieldvpn/Red Shield VPN"
ST="${RS_NEST_STATE:-/Library/Application Support/rs-nest}"
LOG="$ST/rs-nest.log"
mkdir -p "$ST"
if [[ $EUID -eq 0 ]]; then PF=/sbin/pfctl; ROUTE=/sbin/route; else PF="sudo -n /sbin/pfctl"; ROUTE="sudo -n /sbin/route"; fi
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

rs_addrs(){  # tunnel addresses RS may use (awg conf + singbox json)
  { sed -nE 's/^Address *= *([0-9.]+)\/.*/\1/p' "$RS/redlink.conf"
    sed -n '/"inbounds"/,/"outbounds"/p' "$RS/redlink.json" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32"' | tr -d '"' | cut -d/ -f1; } 2>/dev/null | sort -u
}
rs_endpoints(){
  { sed -nE 's/^Endpoint *= *([0-9.]+):.*/\1/p' "$RS/redlink.conf"
    sed -nE 's/.*"server": *"([0-9.]+)".*/\1/p' "$RS/redlink.json"; } 2>/dev/null | sort -u
}
find_tun(){  # prints "utunN ip" of the RS tunnel, or nothing
  local addrs; addrs=$(rs_addrs | tr '\n' ' ')
  ifconfig | awk -v A="$addrs" 'BEGIN{n=split(A,a," "); for(i=1;i<=n;i++) want[a[i]]=1}
    /^[a-z0-9]+:/{i=""} /^utun[0-9]+:/{i=$1; sub(":","",i)} /^\tinet /{ if(i!="" && $2 in want) print i, $2 }' | head -1
}
def_if(){  # physical interface that carries the default route
  local i; i=$($ROUTE -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ -n $i && $i != utun* ]] && { echo "$i"; return; }
  netstat -rn -f inet | awk '$1=="default" && $NF !~ /^utun/{print $NF; exit}'
}
lan_net(){
  local ip m; ip=$(ipconfig getifaddr "$EXT" 2>/dev/null); m=$(ipconfig getoption "$EXT" subnet_mask 2>/dev/null)
  [[ -n $ip && -n $m ]] || return 1
  IFS=. read -r a b c d <<<"$ip"; IFS=. read -r e f g h <<<"$m"
  local bits=0; for o in $e $f $g $h; do for ((k=7;k>=0;k--)); do (( (o>>k)&1 )) && ((bits++)); done; done
  echo "$((a&e)).$((b&f)).$((c&g)).$((d&h))/$bits"
}
load(){ # $1=tun $2=ip
  EXT=$(def_if); [[ -n $EXT ]] || { log "no default interface; skip"; return 1; }
  local lan ep; lan=$(lan_net) || lan=192.168.0.0/16; ep=$(rs_endpoints | tr '\n' ' ')
  cat > "$ST/main.conf" <<M
set block-policy drop
set ruleset-optimization basic
set skip on lo0
nat-anchor "rs-nest"
pass quick proto udp from any to any port 67:68 no state
anchor "com.redshieldvpn"
anchor "rs-nest"
M
  cat > "$ST/rs-nest.conf" <<R
nat on $1 inet from ! $2 to any -> $2
pass out quick on $EXT inet from any to { $lan 169.254.0.0/16 224.0.0.0/4 255.255.255.255 ${ep} } no state
pass out quick on $EXT route-to ($1 $2) inet from any to any keep state
R
  $PF -sr 2>/dev/null | grep -q 'anchor "rs-nest"' || $PF -f "$ST/main.conf" >/dev/null 2>&1
  $PF -a rs-nest -f "$ST/rs-nest.conf" >/dev/null 2>&1 && $PF -e >/dev/null 2>&1
  log "loaded tun=$1 ip=$2 ext=$EXT lan=$lan ep=[$ep]"
}
flush(){ $PF -a rs-nest -F all >/dev/null 2>&1; log "flushed"; }

reconcile(){
  local t mainok anc
  t=$(find_tun)
  if [[ -n $t ]]; then
    mainok=$($PF -sr 2>/dev/null | grep -c 'anchor "rs-nest"')
    anc=$($PF -a rs-nest -sr 2>/dev/null | grep -c route-to)
    if [[ $t != "$cur" || $mainok -eq 0 || $anc -eq 0 || $(def_if) != "$EXT" ]]; then load $t && cur=$t; fi
    # Perimeter 81's daemon runs `pfctl -d` on start; rules stay loaded but inert.
    if ! $PF -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      $PF -e >/dev/null 2>&1; log "pf was disabled; re-enabled"
    fi
  else
    if [[ -n $cur ]] || $PF -a rs-nest -sr 2>/dev/null | grep -q route-to; then flush; cur=""; fi
  fi
}

cur=""
reconcile
# Event-driven: the kernel routing socket reports interface/address/route changes
# (RTM_IFINFO, RTM_NEWADDR, RTM_DELADDR, RTM_ADD, RTM_DELETE); the only poll is the 10 s backstop below.
# Events arrive in bursts, so debounce with a short settle delay.
trap 'kill $MON 2>/dev/null; exit 0' INT TERM
exec 3< <(exec $ROUTE -n monitor 2>/dev/null)
MON=$!
# `pfctl -d` raises no routing-socket event, so a 10 s timeout is the backstop.
last=$SECONDS
while :; do
  read -r -t 10 -u 3 line; rc=$?
  (( rc == 0 || rc > 128 )) || break
  if (( SECONDS - last >= 10 )); then reconcile; last=$SECONDS; fi   # RTM_MISS noise keeps read from timing out
  (( rc == 0 )) || continue
  case $line in
    RTM_IFINFO*|RTM_NEWADDR*|RTM_DELADDR*|RTM_ADD*|RTM_DELETE*|RTM_CHANGE*)
      sleep 0.3
      for _ in $(seq 1 200); do read -r -t 1 -u 3 _ || break; done   # drain the burst, bounded
      reconcile; last=$SECONDS ;;
  esac
done
log "route monitor ended; exiting for launchd restart"
exit 1
