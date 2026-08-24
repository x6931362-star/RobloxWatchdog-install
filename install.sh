#!/data/data/com.termux/files/usr/bin/bash
# roblox-watchdog one-shot bootstrap for a fresh Termux (rooted Android).
#
# Fresh phone -> ready in one command:
#
#   HUB=http://<hub-tailscale-ip>:8777  TS_KEY=tskey-auth-...  bash install.sh
#
# It: installs deps + Tailscale (Android PIE build), joins your tailnet, pulls
# the auto-configured installer from the hub, installs the watchdog, sets up
# boot autostart, and starts it. Re-running updates in place and keeps config.
#
# Env:
#   HUB       hub URL (http://<tailscale-ip>:8777). Prompted if unset.
#   TS_KEY    Tailscale reusable auth key. Read from ~/roblox-watchdog/tailscale.key
#             or prompted if unset.
#   HOSTNAME  tailnet name for this phone (default: device serial).
#   SOCKS     local SOCKS port (default 1055).
set -uo pipefail

DIR="$HOME/roblox-watchdog"
SOCKS="${SOCKS:-1055}"
TS_INSTALLER="${TS_INSTALLER:-https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh}"
say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$DIR"

# ---- 1. dependencies ------------------------------------------------------
say "installing packages"
pkg update -y >/dev/null 2>&1 || true
pkg install -y git curl coreutils sed grep procps inetutils termux-api sqlite termux-services >/dev/null \
  || die "package install failed (check your network / mirror)"

# ---- 2. Tailscale (PIE Android build) ------------------------------------
ts_ok(){ command -v tailscaled-start >/dev/null 2>&1 && tailscale version >/dev/null 2>&1; }
if ! ts_ok; then
  say "installing Tailscale (Android build)"
  rm -f "$PREFIX/bin/tailscale" "$PREFIX/bin/tailscaled" 2>/dev/null
  curl -fsSL "$TS_INSTALLER" | bash || die "tailscale install failed"
  dpkg --configure -a >/dev/null 2>&1 || true
fi
ts_ok || die "tailscale still not runnable (unexpected e_type means a non-PIE binary slipped in)"

# pin SOCKS port + start daemon
mkdir -p "$HOME/.tailscale"
echo "TS_SOCKS5_PORT=$SOCKS" > "$HOME/.tailscale/.env"
say "starting tailscaled (userspace, socks5 127.0.0.1:$SOCKS)"
pgrep -f "tailscaled.*$HOME/.tailscale" >/dev/null 2>&1 || tailscaled-start >/dev/null 2>&1
for _ in $(seq 1 20); do [ -S "$HOME/.tailscale/tailscaled.sock" ] && break; sleep 0.5; done

# auth key
[ -z "${TS_KEY:-}" ] && [ -r "$DIR/tailscale.key" ] && TS_KEY="$(cat "$DIR/tailscale.key")"
if [ -z "${TS_KEY:-}" ]; then
  printf "Tailscale auth key (tskey-auth-...): "; read -r TS_KEY
fi
[ -n "${TS_KEY:-}" ] || die "no Tailscale auth key"
printf '%s' "$TS_KEY" > "$DIR/tailscale.key"; chmod 600 "$DIR/tailscale.key"

HOST="${HOSTNAME:-$(getprop ro.serialno 2>/dev/null | tr -cd 'A-Za-z0-9')}"
[ -n "$HOST" ] || HOST="phone"
say "joining tailnet as '$HOST'"
tailscale-cli up --auth-key="$TS_KEY" --hostname="$HOST" --accept-routes=false --accept-dns=false \
  || die "tailscale up failed (bad/expired key?)"

# ---- 3. hub URL + pull the auto-configured installer ----------------------
if [ -z "${HUB:-}" ]; then
  printf "Hub URL (e.g. http://<hub-tailscale-ip>:8777): "; read -r HUB
fi
[ -n "${HUB:-}" ] || die "no HUB url"
HUB="${HUB%/}"

say "fetching installer from hub ($HUB)"
tmp="$DIR/.setup.$$.sh"
if ! curl -fsS --socks5-hostname "127.0.0.1:$SOCKS" -m 20 "$HUB/setup.sh" -o "$tmp"; then
  die "cannot reach the hub over the tailnet. Is hub.py running and is this phone approved in the Tailscale admin?"
fi
say "installing watchdog"
bash "$tmp" || die "setup.sh failed"
rm -f "$tmp"

# ---- 4. boot autostart ----------------------------------------------------
if [ -x "$DIR/boot-start.sh" ]; then
  mkdir -p "$HOME/.termux/boot"
  ln -sf "$DIR/boot-start.sh" "$HOME/.termux/boot/boot-start.sh"
  say "boot autostart linked (install Termux:Boot from F-Droid to arm it)"
fi

# ---- 5. start it ----------------------------------------------------------
say "starting the watchdog"
su 0 /system/bin/sh -c "export HOME='$HOME' && export PATH=\$PATH:$PREFIX/bin && cd '$DIR' && nohup bash roblox-watchdog.sh '$DIR/watchdog.conf' >> '$DIR/run.log' 2>&1 &" 2>/dev/null

cat <<DONE

\033[1;32mDone.\033[0m This phone should appear on your dashboard within ~20s.
  logs:    tail -f $DIR/watchdog.log
  status:  bash $DIR/roblox-watchdog.sh $DIR/watchdog.conf check
DONE
