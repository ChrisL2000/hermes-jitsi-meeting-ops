#!/usr/bin/env python3
"""meeting_ctl — agent client for the Jitsi meeting control plane.

The control plane is mod_meeting_ctl inside Prosody on dobbscloudeast. Prosody
publishes nothing, so this client reaches it the same way the rest of the tooling
does: ssh to the host, `docker exec` into the web container, and curl Prosody's
container-local HTTP with the XMPP host header.

Auth is two-factor and fail-closed: a bearer token (stored on zeppo at
~/.hermes/jitsi-ctl-token, mode 600) plus an X-Admin-Email actor header. The
module rejects anything without both, and appends every write to
/config/jitsi-ctl/audit.jsonl on the host.

Usage:
    meeting_ctl.py rooms
    meeting_ctl.py room <room>
    meeting_ctl.py subject <room> "New title"
    meeting_ctl.py kick <room> <nick>
    meeting_ctl.py mute <room> <nick>        # documents that Jitsi mutes client-side
"""
import json
import os
import shlex
import subprocess
import sys
import urllib.parse

SSH_TARGET = os.environ.get("JITSI_SSH", "chrismok@100.83.185.118")
WEB_CONTAINER = os.environ.get("JITSI_WEB_CONTAINER", "jitsi-migrate-11248-web-1")
PROSODY = os.environ.get("JITSI_PROSODY_URL", "http://prosody:5280")
TOKEN_FILE = os.path.expanduser(os.environ.get("JITSI_CTL_TOKEN_FILE", "~/.hermes/jitsi-ctl-token"))
ACTOR = os.environ.get("JITSI_CTL_ACTOR", "chrismok@meet.dobbscloud.com")


def _token():
    try:
        with open(TOKEN_FILE) as fh:
            tok = fh.read().strip()
    except FileNotFoundError:
        sys.exit(f"FATAL: token file {TOKEN_FILE} missing (fetch it from "
                 f"/root/.jitsi-meet-cfg/prosody/config/jitsi-ctl/token on the host)")
    if not tok:
        sys.exit(f"FATAL: token file {TOKEN_FILE} is empty")
    return tok


def _call(method, path, body=None):
    tok = _token()
    url = f"{PROSODY}{path}"
    cmd = ["curl", "-s", "-S", "-X", method,
           "-H", "Host: meet.jitsi",
           "-H", f"Authorization: Bearer {tok}",
           "-H", f"X-Admin-Email: {ACTOR}",
           "-H", "Content-Type: application/json",
           "-w", "\n%{http_code}"]
    if body is not None:
        cmd += ["--data", json.dumps(body)]
    cmd.append(url)
    remote = f"sudo docker exec {WEB_CONTAINER} " + " ".join(shlex.quote(c) for c in cmd)
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", SSH_TARGET, remote],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        sys.exit(f"ssh/docker failed: {r.stderr.strip()[:300]}")
    out = r.stdout.rsplit("\n", 1)
    code = out[-1].strip()
    payload = out[0]
    try:
        data = json.loads(payload) if payload.strip() else {}
    except Exception:
        data = {"raw": payload}
    return code, data


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]

    if cmd == "rooms":
        code, data = _call("GET", "/ctl/rooms")
    elif cmd == "room":
        room = urllib.parse.quote(sys.argv[2].lower(), safe="")
        code, data = _call("GET", f"/ctl/room/{room}")
    elif cmd == "subject":
        room = urllib.parse.quote(sys.argv[2].lower(), safe="")
        code, data = _call("POST", f"/ctl/room/{room}/subject", {"subject": sys.argv[3]})
    elif cmd == "kick":
        room = urllib.parse.quote(sys.argv[2].lower(), safe="")
        code, data = _call("POST", f"/ctl/room/{room}/kick", {"nick": sys.argv[3]})
    elif cmd == "mute":
        room = urllib.parse.quote(sys.argv[2].lower(), safe="")
        code, data = _call("POST", f"/ctl/room/{room}/mute", {"nick": sys.argv[3]})
    else:
        print(__doc__)
        sys.exit(2)

    print(json.dumps({"http": code, "data": data}, indent=2))
    sys.exit(0 if str(code).startswith("2") else 1)


if __name__ == "__main__":
    main()
