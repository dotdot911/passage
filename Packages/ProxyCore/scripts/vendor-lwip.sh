#!/usr/bin/env bash
# Vendors lwIP STABLE-2_2_1_RELEASE into Sources/CLwIP/lwip and applies Passage patches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CLwIP/lwip"
TAG="STABLE-2_2_1_RELEASE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -sSfL "https://github.com/lwip-tcpip/lwip/archive/refs/tags/$TAG.tar.gz" -o "$TMP/lwip.tgz"
tar xzf "$TMP/lwip.tgz" -C "$TMP"
SRC="$TMP/lwip-$TAG/src"
rm -rf "$DEST"
mkdir -p "$DEST/core/ipv4" "$DEST/core/ipv6" "$DEST/include"
cp "$SRC"/core/*.c "$DEST/core/"
cp "$SRC"/core/ipv4/*.c "$DEST/core/ipv4/"
cp "$SRC"/core/ipv6/*.c "$DEST/core/ipv6/"
cp -R "$SRC/include/lwip" "$DEST/include/"
cp -R "$SRC/include/netif" "$DEST/include/"
# lwIP ships a template header SPM would try to compile/parse; drop it.
rm -f "$DEST/include/lwip/init.h.cmake.in"
cp "$TMP/lwip-$TAG/COPYING" "$DEST/COPYING"

# Patch 1+2: accept packets for ANY destination address (we are a transparent stack).
perl -0pi -e 's/(ip4_input_accept\(struct netif \*netif\)\n\{\n)/$1  if (netif_is_up(netif)) { return 1; } \/* passage: accept any dest *\/\n/' "$DEST/core/ipv4/ip4.c"
perl -0pi -e 's/(ip6_input_accept\(struct netif \*netif\)\n\{\n)/$1  if (netif_is_up(netif)) { return 1; } \/* passage: accept any dest *\/\n/' "$DEST/core/ipv6/ip6.c"
# Patch 3: a listen PCB with local_port 0 matches every destination port.
perl -0pi -e 's/if \(lpcb->local_port == tcphdr->dest\) \{/if (lpcb->local_port == tcphdr->dest || lpcb->local_port == 0) { \/* passage *\//' "$DEST/core/tcp_in.c"
# Patch 4: the accepted PCB takes the real destination port, not the listener's 0.
perl -0pi -e 's/npcb->local_port = pcb->local_port;/npcb->local_port = tcphdr->dest; \/* passage *\//' "$DEST/core/tcp_in.c"

for f in core/ipv4/ip4.c core/ipv6/ip6.c core/tcp_in.c; do
  grep -q passage "$DEST/$f" || { echo "patch failed: $f" >&2; exit 1; }
done
[ "$(grep -c passage "$DEST/core/tcp_in.c")" = 2 ] || { echo "patch failed: tcp_in.c" >&2; exit 1; }
echo "lwIP $TAG vendored into $DEST"
