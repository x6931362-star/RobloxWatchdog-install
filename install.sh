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
PKGS="git curl coreutils sed grep procps inetutils termux-api sqlite termux-services"
OFFICIAL_MAIN="https://packages.termux.dev/apt/termux-main"
pkg update -y >/dev/null 2>&1 || true
# shellcheck disable=SC2086
if ! pkg install -y $PKGS >/dev/null; then
  # A community mirror mid-sync fails with "File has unexpected size ... Mirror
  # sync in progress?" and stays broken until it finishes. Point the main repo
  # at the official Termux server (old file kept as .bak) and retry once.
  # TERMUX_PKG_NO_MIRROR_SELECT stops pkg from rotating to a random mirror
  # again (pkg's select_mirror rewrites the repo file on every install/update
  # otherwise). Newer Termux keeps the main repo in sources.list.d/main.sources
  # (deb822); older ones in sources.list.
  say "package install failed; switching to the official Termux mirror and retrying"
  SRC822="$PREFIX/etc/apt/sources.list.d/main.sources"
  SRC="$PREFIX/etc/apt/sources.list"
  if [ -f "$SRC822" ]; then
    cp -f "$SRC822" "$SRC822.bak"
    sed -i "s|^\([[:space:]]*URIs:\).*|\1 $OFFICIAL_MAIN|" "$SRC822"
  else
    [ -f "$SRC" ] && cp -f "$SRC" "$SRC.bak"
    echo "deb $OFFICIAL_MAIN stable main" > "$SRC"
  fi
  export TERMUX_PKG_NO_MIRROR_SELECT=1
  pkg update -y >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  pkg install -y $PKGS >/dev/null \
    || die "package install failed on the official mirror too (check your network)"
fi

# ---- 2. Tailscale (PIE Android build) ------------------------------------
ts_ok(){ command -v tailscaled-start >/dev/null 2>&1 && tailscale version >/dev/null 2>&1; }
if ! ts_ok; then
  say "installing Tailscale (Android build)"
  rm -f "$PREFIX/bin/tailscale" "$PREFIX/bin/tailscaled" 2>/dev/null
  curl -fsSL "$TS_INSTALLER" | bash || die "tailscale install failed"
  dpkg --configure -a >/dev/null 2>&1 || true
fi
ts_ok || die "tailscale still not runnable (unexpected e_type means a non-PIE binary slipped in)"

# pin SOCKS port + keep the proxy OPEN + start the daemon. bropines
# tailscale-termux >=1.102.4 defaults the SOCKS5 proxy to require a password AND
# ships a runsv service that starts its own tailscaled on 1055 without reading this
# .env (so it demands auth and squats the port). Our curl to the hub sends no
# credentials, so without NO_AUTH the very next step (fetch setup.sh over SOCKS)
# dies with `curl (97) No authentication method was acceptable`. Set NO_AUTH,
# disable that service, then start our own daemon.
mkdir -p "$HOME/.tailscale"
printf 'TS_SOCKS5_PORT=%s\nTS_SOCKS5_NO_AUTH=1\n' "$SOCKS" > "$HOME/.tailscale/.env"
command -v sv-disable >/dev/null 2>&1 && sv-disable tailscaled >/dev/null 2>&1 || true
command -v sv >/dev/null 2>&1 && { sv down tailscaled >/dev/null 2>&1 || true; sleep 1; }
say "starting tailscaled (userspace, socks5 127.0.0.1:$SOCKS)"
if ! pgrep -f "tailscaled.*$HOME/.tailscale" >/dev/null 2>&1; then
  rm -f "$HOME/.tailscale/tailscaled.sock" 2>/dev/null
  tailscaled-start >/dev/null 2>&1
fi
for _ in $(seq 1 20); do [ -S "$HOME/.tailscale/tailscaled.sock" ] && break; sleep 0.5; done

# auth key
[ -z "${TS_KEY:-}" ] && [ -r "$DIR/tailscale.key" ] && TS_KEY="$(cat "$DIR/tailscale.key")"
if [ -z "${TS_KEY:-}" ]; then
  printf "Tailscale auth key (tskey-auth-...): "; read -r TS_KEY
fi
[ -n "${TS_KEY:-}" ] || die "no Tailscale auth key"
printf '%s' "$TS_KEY" > "$DIR/tailscale.key"; chmod 600 "$DIR/tailscale.key"

# NOT $HOSTNAME: that is a shell builtin already set to 'localhost' on Termux, so
# ${HOSTNAME:-...} never reaches the fallback and every phone would join as
# 'localhost'. Use an explicit TS_HOSTNAME override, else the serial, else random.
HOST="${TS_HOSTNAME:-}"
[ -n "$HOST" ] || HOST="$(getprop ro.serialno 2>/dev/null | tr -cd 'A-Za-z0-9')"
[ -n "$HOST" ] || HOST="phone-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
say "joining tailnet as '$HOST'"
# </dev/null: this script is often run as `curl … | bash`, so its stdin IS the
# script. tailscale reads stdin, which would eat the rest of the script and derail
# parsing ("bash: <garbage>: No such file or directory"). Feed it /dev/null.
tailscale-cli up --auth-key="$TS_KEY" --hostname="$HOST" --accept-routes=false --accept-dns=false </dev/null \
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
bash "$tmp" </dev/null || die "setup.sh failed"
rm -f "$tmp"

# ---- 4. boot autostart ----------------------------------------------------
if [ -x "$DIR/boot-start.sh" ]; then
  mkdir -p "$HOME/.termux/boot"
  ln -sf "$DIR/boot-start.sh" "$HOME/.termux/boot/boot-start.sh"
  say "boot autostart linked (install Termux:Boot from F-Droid to arm it)"
fi

# ---- 5. start it ----------------------------------------------------------
say "starting the watchdog"
su 0 /system/bin/sh -c "export HOME='$HOME' && export PATH=\$PATH:$PREFIX/bin && cd '$DIR' && nohup bash roblox-watchdog.sh '$DIR/watchdog.conf' >> '$DIR/run.log' 2>&1 &" </dev/null 2>/dev/null

cat <<DONE

\033[1;32mDone.\033[0m This phone should appear on your dashboard within ~20s.
  logs:    tail -f $DIR/watchdog.log
  status:  bash $DIR/roblox-watchdog.sh $DIR/watchdog.conf check
DONE
