---
name: hermes-jitsi-meeting-ops
description: "Control a live Jitsi meeting out-of-band of SIP."
version: 0.1.0
author: chrismok, Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [jitsi, meeting-ops, prosody, control-plane, moderation, meet.dobbscloud.com]
---

# Hermes Jitsi meeting ops (out-of-band control plane)

## When to Use

Use when an agent must operate a live meet.dobbscloud.com room without going
through the SIP/audio path: read the roster, rename the meeting, kick someone,
or later admit from lobby / start a recording. The SIP bot
(`hermes-integration-sip-jitsi`) is the *voice*; this is the *hands*.

## What the Jitsi service actually exposes (probed on stable-11248)

| surface | endpoints | usable for control? |
|---|---|---|
| Jicofo :8888 | `/debug`, `/debug/conferences`, `/debug/conference/<room>@muc.meet.jitsi`, `/metrics` | NO — read-only debug. No moderation API, POST 404s |
| JVB :8080 | `/about/version`, `/metrics` | NO — `/colibri/*` not exposed; no per-participant control |
| Jigasi | none | NO — media/signalling glue |
| Prosody :5280 | `/http-bind` + custom modules | YES — the only place room state (subject, roster, roles, affiliations) lives |

Consequence: a control plane must be built inside Prosody (module) or spoken to it
over XMPP. This skill uses the module.

## Elevation policy: delegated, never granted

Jitsi moderation is MUC role/affiliation based, and a Jigasi participant is
always a plain participant. The decision for this deployment:

- The module acts **as the room owner** on the agent's behalf. Nothing is granted
to the SIP participant, so there is no moderation privilege attached to the thing
that also holds a microphone.
- A separate "ops seat" (a non-media XMPP occupant with affiliation=owner) is
  the fallback if a human-visible moderator identity is ever needed.
- Granting the jigasi participant role=moderator is available in Jitsi but
  deliberately NOT used: the speaker should not hold the kick button.

## Components

| piece | where |
|---|---|
| `mod_meeting_ctl.lua` | `/root/.jitsi-meet-cfg/prosody/prosody-plugins-custom/` on dobbscloudeast |
| enable | `.env` `GLOBAL_MODULES=…,meeting_ctl` then force-recreate prosody |
| token | `/root/.jitsi-meet-cfg/prosody/config/jitsi-ctl/token` (uid 1000, 600) |
| audit | `/root/.jitsi-meet-cfg/prosody/config/jitsi-ctl/audit.jsonl` (append-only) |
| client | `~/src/jitsi-hermes-bot/bot/meeting_ctl.py`, token copied to `~/.hermes/jitsi-ctl-token` (600) |

## API (v0.1) — verified against a live room 2026-11-23

    GET  /ctl/rooms                  {"rooms":[...],"count":N,"source":"jicofo+ctl"}
    GET  /ctl/room/<room>            subject, locked, occupants[{nick,jid,real_jid,role,affiliation,is_bot}]
    POST /ctl/room/<room>/subject    {"subject":"..."}   VERIFIED: sets and reads back
    POST /ctl/room/<room>/kick       → 501 NOT SUPPORTED on this build (see below)
    POST /ctl/room/<room>/mute       → 501 BY DESIGN

### Kick/mute: measured limits, not guesses

`room:set_role(actor, nick, "none")` returns WITHOUT error for every actor form
(human moderator occupant JID, focus JID, `nil`, `true`) and the occupant stays in
the room. A probe endpoint tried all four in one request: all reported ok, none
removed anybody. Jitsi keeps SIP/Jigasi occupants under Jicofo's control, so a
MUC-level role change is ignored.

The module now returns 501 with that evidence instead of a fake 200. Working
alternatives: join a real XMPP moderator seat and send muc#admin IQs; terminate the
conference from Jicofo (drops everyone); or end the SIP leg on the bot side
(`fs_cli uuid_kill`).

Mute is refused for the same class of reason: audio state lives in the client.

### Roster field quirks (this build)

- `room:each_occupant()` yields PAIRS keyed by the full occupant JID
  (`room@muc.host/<nick>`); iterating one variable gives strings, not occupants.
  The nick is the last path segment.
- The subject is behind `room:get_subject()`; `room._data.subject` alone returns nil
  even after a successful rename.
- There is no live-room registry exposed to modules — reading `muc.rooms` raises
  "Attempt to read a non-existent global 'rooms'". `/ctl/rooms` reports empty and the
  client enumerates via Jicofo + one GET per room.
- `is_bot` is heuristic (MUC JID contains jigasi/jibri); Jigasi guests show as
  ordinary UUID JIDs, so a SIP bot can appear as `participant` with is_bot=false.

## Auth (both required, fail-closed)

1. `Authorization: Bearer <token>` — compared to the token file; no token file
   means every request 401s.
2. `X-Admin-Email: <actor>` — must be present; in production it is set by the
   mTLS identity-proxy (fsck Test PKI), never by a client.

Every write appends `{ts,actor,action,room,target,detail}` to audit.jsonl. Read the
last lines with:

    ssh chrismok@100.83.185.118 'sudo tail -5 /root/.jitsi-meet-cfg/prosody/config/jitsi-ctl/audit.jsonl'

## Reaching it

Prosody publishes nothing outside its container network. The client therefore
ssh's to the host, `docker exec`s into the web container, and curls Prosody's
container-local HTTP with `Host: meet.jitsi`. Same shape as the room-profile
collector in the SIP bot.

    python3 ~/src/jitsi-hermes-bot/bot/meeting_ctl.py rooms
    python3 ~/src/jitsi-hermes-bot/bot/meeting_ctl.py room BasilsHouse
    python3 ~/src/jitsi-hermes-bot/bot/meeting_ctl.py subject BasilsHouse "Q4 planning"
    python3 ~/src/jitsi-hermes-bot/bot/meeting_ctl.py kick BasilsHouse Scarlett-wdZ

## Deployment

    scp prosody/mod_meeting_ctl.lua chrismok@100.83.185.118:/tmp/
    ssh chrismok@100.83.185.118 '
      sudo install -m 644 -o root -g root /tmp/mod_meeting_ctl.lua \
        /root/.jitsi-meet-cfg/prosody/prosody-plugins-custom/ && rm /tmp/mod_meeting_ctl.lua
      sudo mkdir -p /root/.jitsi-meet-cfg/prosody/config/jitsi-ctl
      [ -s .../jitsi-ctl/token ] || head -c 32 /dev/urandom | base64 | tr -d "\n" > .../jitsi-ctl/token
      sudo chown -R 1000:1000 .../jitsi-ctl && sudo chmod 700 .../jitsi-ctl && sudo chmod 600 .../jitsi-ctl/token
      cd ~/jitsi-migrate-11248
      sed -i "s/^GLOBAL_MODULES=.*/&,meeting_ctl/" .env    # only once
      sudo docker compose -f docker-compose.yml -f jigasi-host.yml up -d --force-recreate --no-deps prosody
    '

A Prosody recreate DROPS every live conference — schedule it, and expect clients
to re-enter the room.

### Reload WITHOUT dropping the room (use this after the first deploy)

    ssh chrismok@100.83.185.118 \
      'sudo docker exec jitsi-migrate-11248-prosody-1 prosodyctl \
        --config /run/prosody/config/prosody.cfg.lua shell module reload meeting_ctl meet.jitsi'

Output `Reloaded on meet.jitsi` / `OK: Module reloaded on 1 host`. Zig-zagging with
`docker compose ... --force-recreate prosody` while iterating kicks every participant
and looks exactly like "the room is crashing on join". Recreate only to change
`.env`/GLOBAL_MODULES.

## Gotchas (each cost a deploy cycle)

- Prosody's HTTP layer lowercases header names AND turns `-` into `_`:
  `X-Admin-Email` arrives as `x_admin_email`. Compare case-insensitively after
  normalising dashes, or every authenticated request 401s with "X-Admin-Email
  missing".
- Route keys must be real patterns. `["/*"]` is rejected at load time
  ("Invalid route in meeting_ctl"); use explicit `GET /rooms`, `GET /room/*`,
  `POST /room/*` and dispatch from one router function.
- The module lives under `default_path = "ctl"`, so the handler sees the path
  WITHOUT the prefix (`/room/<room>/subject`).
- Empty Lua arrays encode as `{}` not `[]` — the client prints `rooms: {}` when no
  room is live; that is not an error.
- The token directory must be `1000:1000`; Prosody runs as uid 1000 and a
  root-owned 600 file makes the module fail closed on every call.
- Room names are case-insensitive: Jicofo/Prosody lower-case the JID. Always
  lower() before lookups.

## Verification

    # negative (no room needed)
    meeting_ctl.py room nosuchroom      -> 404 {"error":"no such room"}
    # auth actually enforced
    JITSI_CTL_TOKEN_FILE=/dev/null meeting_ctl.py rooms -> FATAL (client) / 401 (server)
    # live
    meeting_ctl.py rooms                -> 200 with your room + subject
    meeting_ctl.py room <room>          -> roster with role/affiliation/is_bot
    meeting_ctl.py subject <room> "x"   -> 200, then re-read room to confirm
    ssh … 'sudo tail -3 …/audit.jsonl'   -> one line per write, with actor

## Roadmap (not in v0.1)

- lobby: list waiting participants, admit/reject
- recording: start/stop Jibri via a control channel
- mute enforcement: needs a client-side control path, not server state
- tailnet publication of `/ctl` through the identity-proxy instead of ssh/docker exec
