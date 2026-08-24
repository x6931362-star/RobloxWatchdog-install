# roblox-watchdog installer

One-command bootstrap for the roblox-watchdog Termux agent (rooted Android).
The program code and dashboard live in a private repo; this repo holds only the
public installer so a fresh phone can bootstrap with a single command.

## Install (per phone)

In Termux (root granted once):

```bash
curl -fsSL https://raw.githubusercontent.com/x6931362-star/RobloxWatchdog-install/main/install.sh \
  | HUB=http://<your-hub-tailscale-ip>:8777 TS_KEY=tskey-auth-... bash
```

- `HUB`    — your hub's Tailscale URL.
- `TS_KEY` — a reusable Tailscale auth key (login.tailscale.com → Settings → Keys).

It installs dependencies + Tailscale, joins your tailnet, pulls the
auto-configured agent from your hub (URL + token injected server-side), arms
boot autostart, and starts. The phone appears on your dashboard within ~20s.

Run with no env vars to be prompted interactively instead.

## Notes

- No secrets are in this repo. The hub token is injected by your hub when the
  installer fetches the agent over the tailnet; the Tailscale key is provided by
  you at install time and stored only on the phone.
- Updates are automatic afterwards (the agent self-updates from your hub); no
  need to re-run this.
