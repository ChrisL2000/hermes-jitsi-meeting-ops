#!/usr/bin/env python3
"""ops_seat — a real XMPP moderator seat for meet.dobbscloud.com.

Why: the Prosody control module can rename a meeting, but a MUC role change (kick)
is ignored for Jigasi/SIP occupants on stable-11248 — measured, see
hermes-jitsi-meeting-ops. Real moderation needs an XMPP CLIENT holding a moderator
role, issuing muc#admin IQs.

This logs in as ops@meet.jitsi on the local Prosody, joins the room, runs ONE
action, and exits. The `ops` account must hold affiliation=owner on that room (the
control module grants it: POST /ctl/room/<room>/affil with the ops JID).

Runs on the Jitsi host (Prosody c2s listens on 127.0.0.1:5222 only):

    ops_seat.py roster  <room>
    ops_seat.py kick    <room> <nick> [reason]
    ops_seat.py ban     <room> <jid|nick> [reason]
    ops_seat.py grant   <room> <nick>
    ops_seat.py subject <room> "New title"
"""
import argparse
import asyncio
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

MUC_ADMIN = "http://jabber.org/protocol/muc#admin"
PASS_FILE = os.environ.get("OPS_PASS_FILE", "/root/.jitsi-meet-cfg/prosody/config/jitsi-ctl/ops.pass")
JID = os.environ.get("OPS_JID", "ops@meet.jitsi")
HOST = os.environ.get("OPS_HOST", "127.0.0.1")
PORT = int(os.environ.get("OPS_PORT", "5222"))
MUC_HOST = os.environ.get("OPS_MUC_HOST", "muc.meet.jitsi")


def password():
    try:
        with open(PASS_FILE) as fh:
            raw = fh.read().strip()
    except (PermissionError, FileNotFoundError):
        r = subprocess.run(["sudo", "cat", PASS_FILE], capture_output=True, text=True)
        raw = r.stdout.strip()
    if not raw:
        sys.exit(f"FATAL: cannot read ops password from {PASS_FILE}")
    return raw.split("=", 1)[1] if raw.startswith("PW=") else raw


def build_admin_iq(xmpp, room, args, occupants):
    iq = xmpp.make_iq_set(ito=room)
    query = ET.SubElement(iq.xml, f"{{{MUC_ADMIN}}}query")
    item = ET.SubElement(query, "item")
    target = args.target

    if args.action in ("kick", "grant") and target not in occupants:
        for nick, info in occupants.items():
            if (info.get("jid") or "").startswith(target or ""):
                target = nick
                break

    if args.action == "kick":
        item.set("nick", target or "")
        item.set("role", "none")
    elif args.action == "grant":
        item.set("nick", target or "")
        item.set("role", "moderator")
    elif args.action == "ban":
        jid = target if "@" in (target or "") else (occupants.get(target, {}) or {}).get("jid", "")
        item.set("jid", jid)
        item.set("affiliation", "outcast")
    elif args.action == "subject":
        item.set("subject", target or "")
    else:
        return None
    ET.SubElement(item, "reason").text = args.reason or "requested by hermes ops"
    return iq


async def run(args):
    import slixmpp

    room = f"{args.room.lower()}@{MUC_HOST}"
    import ssl
    xmpp = slixmpp.ClientXMPP(JID, password())
    # Prosody's c2s cert is self-signed for meet.jitsi; we are on loopback.
    xmpp.ssl_context.check_hostname = False
    xmpp.ssl_context.verify_mode = ssl.CERT_NONE
    for plugin in ("xep_0030", "xep_0045", "xep_0199"):
        xmpp.register_plugin(plugin)

    result = {"jid": JID, "room": room, "joined": False, "occupants": [], "action": None}
    try:
        await asyncio.wait_for(
            xmpp.connect(host=HOST, port=PORT),
            timeout=15)
        xmpp.send_presence()
        await asyncio.wait_for(xmpp.get_roster(), timeout=10)
        nick = f"ops-{os.getpid() % 10000}"
        await asyncio.wait_for(
            xmpp.plugin["xep_0045"].join_muc_wait(room, nick, maxstanzas=0, timeout=10), timeout=20)
        result["joined"] = True

        occupants = xmpp.plugin["xep_0045"].rooms.get(room, {}).get("occupants", {})
        result["occupants"] = sorted(occupants.keys())
        result["self_role"] = (occupants.get(nick) or {}).get("role")

        if args.action != "roster":
            iq = build_admin_iq(xmpp, room, args, occupants)
            if iq is None:
                result["action"] = "unknown action"
            else:
                try:
                    resp = await asyncio.wait_for(iq.send(), timeout=15)
                    result["action"] = f"ok ({resp['type']})"
                except Exception as e:
                    result["action"] = f"error: {e}"
        else:
            result["action"] = "roster"
    except Exception as e:
        result["error"] = f"{type(e).__name__}: {e}"
    finally:
        try:
            await xmpp.disconnect(wait=True)
        except Exception:
            pass
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["roster", "kick", "grant", "ban", "subject"])
    ap.add_argument("room")
    ap.add_argument("target", nargs="?")
    ap.add_argument("reason", nargs="?")
    args = ap.parse_args()
    res = asyncio.run(run(args))
    print(res)
    return 0 if res.get("joined") else 1


if __name__ == "__main__":
    sys.exit(main())
