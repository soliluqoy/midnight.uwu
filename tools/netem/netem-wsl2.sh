#!/usr/bin/env bash
# Link shaping for Phase 0 spikes 2 and 5, on the WSL2 (Linux) side.
#
# Windows-side shaping is clumsy (see clumsy-profile.ps1). This script shapes
# traffic inside WSL2, which is what you want when the Go interop harness
# runs in WSL2 and talks to the Flutter app on the Windows host.
#
# Usage:
#   ./netem-wsl2.sh apply  <iface> <rate> [delay] [loss]     # shape
#   ./netem-wsl2.sh clear  <iface>                           # remove shaping
#   ./netem-wsl2.sh list                                     # show current qdisc
#
# Examples matching the build plan's Phase 0 spike 2:
#   ./netem-wsl2.sh apply eth0 100mbit 5ms 1%      # "100 Mbps broadband"
#   ./netem-wsl2.sh apply eth0 4mbit  60ms 2%     # "4G / LTE"
#   ./netem-wsl2.sh clear eth0                     # unshaped LAN baseline
# Only WSL harness traffic traversing this interface is shaped, not arbitrary
# Windows/Android traffic. Delay/loss do not emulate CGNAT or symmetric NAT.

set -euo pipefail

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run inside WSL2 as root:  sudo $0 $*" >&2
    echo "       from Windows:  wsl -d Ubuntu -u root -- bash $0 $*" >&2
    exit 1
  fi
}

case "${1:-}" in
  apply)
    need_root
    iface="${2:?iface required}"
    rate="${3:?rate required, e.g. 100mbit}"
    delay="${4:-0ms}"
    loss="${5:-0%}"
    tc qdisc replace dev "$iface" root netem \
      rate "$rate" delay "$delay" loss "$loss"
    echo "applied: rate=$rate delay=$delay loss=$loss on $iface"
    ;;
  clear)
    need_root
    iface="${2:?iface required}"
    if ! tc qdisc show dev "$iface" >/dev/null; then
      echo "cannot inspect interface $iface" >&2
      exit 1
    fi
    if tc qdisc show dev "$iface" | grep -q 'qdisc noqueue'; then
      echo "no root qdisc on $iface"
      exit 0
    fi
    tc qdisc del dev "$iface" root
    echo "cleared $iface"
    ;;
  list)
    tc qdisc show
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
