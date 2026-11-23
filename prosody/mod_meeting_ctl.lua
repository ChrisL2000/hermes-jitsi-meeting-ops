-- mod_meeting_ctl.lua  (read + gated write)
--
-- Out-of-band control plane for meet.dobbscloud.com, inside Prosody, so the agent
-- can operate a meeting without touching SIP media at all.
--
-- Model: DELEGATED ACTIONS. The module acts as the room owner; it never elevates
-- the jigasi/SIP participant to moderator. Everything it does is audited.
--
-- Auth (both required, fail closed):
--   1. Authorization: Bearer <token>   token read from meeting_ctl_token_file
--   2. X-Admin-Email: <actor>          set by the mTLS proxy, never by clients
--
-- Routes (relative to /ctl):
--   GET  /rooms                        live rooms: subject + occupant count
--   GET  /room/<room>                  roster with role, affiliation, jid
--   POST /room/<room>/subject          {"subject": "..."}
--   POST /room/<room>/kick             {"nick": "..."}   (role -> none)
--   POST /room/<room>/mute             -> 501 by design (see below)
--
-- Mute is deliberately NOT faked: Jitsi enforces audio state in the CLIENT. A
-- server-side "mute" would only be a request the client may ignore, so v0.1
-- refuses it instead of reporting success for something it cannot guarantee.

local module = module;
local json = require "util.json";

local MUC_HOST = module:get_option_string("meeting_ctl_muc_host", "muc.meet.jitsi");
local TOKEN_FILE = module:get_option_string("meeting_ctl_token_file", "/config/jitsi-ctl/token");
local AUDIT_FILE = module:get_option_string("meeting_ctl_audit_file", "/config/jitsi-ctl/audit.jsonl");

local function read_file(path)
    local fh = io.open(path, "r");
    if not fh then return nil end
    local s = fh:read("*a");
    fh:close();
    if not s then return nil end
    return (s:gsub("%s+$", ""));
end

local function log_event(actor, action, room, target, detail)
    local fh = io.open(AUDIT_FILE, "a");
    if not fh then return end
    local rec = {
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        actor = actor or "",
        action = action or "",
        room = room or "",
        target = target or "",
        detail = detail or "",
    };
    local ok, body = pcall(json.encode, rec);
    if ok then fh:write(body, "\n") end
    fh:close();
end

local function reply(code, tbl)
    local ok, body = pcall(json.encode, tbl or {});
    if not ok then body = '{"error":"encode failed"}' end
    return {
        status_code = code,
        headers = { ["Content-Type"] = "application/json" },
        body = body,
    };
end

local function authorized(event)
    local hdr = event.request.headers or {};
    -- Prosody passes header names through with arbitrary casing (it sends them
    -- as received by the HTTP parser), so match case-insensitively.
    local function get_header(name)
        -- Prosody's HTTP layer lowercases AND converts '-' to '_'
        -- (X-Admin-Email arrives as x_admin_email), so normalise both sides.
        local want = name:lower():gsub("-", "_");
        for k, v in pairs(hdr) do
            if type(k) == "string" and k:lower():gsub("-", "_") == want then return v end
        end
        return nil;
    end
    local auth = get_header("authorization") or "";
    local expected = read_file(TOKEN_FILE);
    if not expected or expected == "" then
        return nil, "token file missing on the server";
    end
    local given = auth:match("^Bearer%s+(.+)$");
    if not given or given ~= expected then
        return nil, "bad or missing bearer token";
    end
    local actor = get_header("x-admin-email") or "";
    if actor == "" then
        return nil, "X-Admin-Email missing (proxy must set it)";
    end
    return actor;
end

local function get_room(name)
    local host = prosody.hosts and prosody.hosts[MUC_HOST];
    local muc = host and host.modules and host.modules.muc;
    if not muc or not muc.get_room_from_jid then return nil end
    return muc.get_room_from_jid(name:lower() .. "@" .. MUC_HOST);
end

local function get_subject(room)
    -- newer Prosody keeps the subject behind a method; older builds used _data
    local ok, value = pcall(function() return room:get_subject() end);
    if ok and value ~= nil then return value end
    if room._data then return room._data.subject end
    return nil;
end


local function room_view(room, name)
    local occ = {};
    local role_manager = {};
    -- room:each_occupant() returns pairs(self._occupants): the FIRST value is the
    -- nick, the second is the occupant object. Iterating single-variable yields
    -- strings, which is why an earlier version returned empty records.
    for key, o in room:each_occupant() do
        -- this build keys occupants by full MUC occupant JID
        -- ("room@muc.host/<nick>"), so the human-facing nick is the last segment
        local nick = tostring(key):match("/(.+)$") or tostring(key);
        local jid = o.jid or "";
        occ[#occ + 1] = {
            nick = nick,
            jid = jid,
            real_jid = o.real_jid,
            role = o.role,
            affiliation = o.affiliation,
            is_bot = (jid:match("jigasi") ~= nil or jid:match("jibri") ~= nil),
        };
    end
    if room.get_role_manager then
        local ok, manager = pcall(function() return room:get_role_manager() end);
        if ok and manager and manager.get_role then
            for _, o in ipairs(occ) do
                local ok2, role = pcall(function() return manager:get_role(o.jid) end);
                if ok2 then role_manager[o.jid] = role end
            end
        end
    end
    return {
        room = name:lower(),
        jid = room.jid,
        subject = get_subject(room),
        name = room._data and room._data.name or nil,
        locked = room._data and room._data.locked or nil,
        occupants = occ,
        occupant_count = #occ,
        role_manager = role_manager,
    };
end

-- ------------------------------------------------------------------ handlers
local function list_rooms(event)
    local actor, err = authorized(event);
    if not actor then return reply(401, { error = err }) end
    local host = prosody.hosts and prosody.hosts[MUC_HOST];
    local muc = host and host.modules and host.modules.muc;
    if not muc or not muc.get_room_from_jid then return reply(503, { error = "muc unavailable" }) end
    local out = {};
    -- This build has no rooms registry exposed to modules; touching muc.rooms
    -- raises "non-existent global 'rooms'". Probe defensively, never assume.
    local rooms;
    local ok_rooms, value = pcall(function() return muc.rooms end);
    if ok_rooms then rooms = value end
    if not rooms then
        local ok_get, got = pcall(function() return muc.get_rooms and muc.get_rooms() end);
        if ok_get then rooms = got end
    end
    if rooms then
        for jid, room in pairs(rooms) do
            local subject = get_subject(room);
            local count = 0;
            for _ in room:each_occupant() do count = count + 1 end
            out[#out + 1] = { room = jid, subject = subject, occupants = count };
        end
    end
    return reply(200, { rooms = out, count = #out,
        note = (#out == 0 and "list unavailable on this build; enumerate via Jicofo and GET /ctl/room/<room>") or nil });
end

local function room_get(event, name)
    local actor, err = authorized(event);
    if not actor then return reply(401, { error = err }) end
    local room = get_room(name);
    if not room then return reply(404, { error = "no such room", room = name }) end
    return reply(200, room_view(room, name));
end

local function room_post(event, name, action)
    local actor, err = authorized(event);
    if not actor then return reply(401, { error = err }) end
    local room = get_room(name);
    if not room then return reply(404, { error = "no such room", room = name }) end

    local body = {};
    if event.request.body and event.request.body ~= "" then
        local ok, parsed = pcall(json.decode, event.request.body);
        if ok and type(parsed) == "table" then body = parsed end
    end

    if action == "subject" then
        local subject = body.subject;
        if type(subject) ~= "string" then return reply(400, { error = "subject (string) required" }) end
        local before = room._data and room._data.subject or nil;
        local ok = pcall(function() room:set_subject(subject) end);
        if not ok then return reply(500, { error = "set_subject failed" }) end
        log_event(actor, "subject", name, "", (tostring(before) .. " -> " .. subject));
        return reply(200, { ok = true, room = name, subject = subject, before = before });
    elseif action == "kick" then
        -- set_role is ignored on this build (see skill), but set_affiliation IS
        -- honored. A kick is therefore: affiliation outcast (removes + bans), then
        -- restore the affiliation a moment later so it is a removal, not a ban.
        local nick = body.nick;
        if type(nick) ~= "string" then return reply(400, { error = "nick (string) required" }) end
        local target, prior = nil, nil;
        for key, o in room:each_occupant() do
            local n = tostring(key):match("/(.+)$") or tostring(key);
            if n == nick then target, prior = o, o.affiliation end
        end
        if not target then return reply(404, { error = "no such occupant", nick = nick }) end
        local jid = target.jid;
        if not jid or jid == "" then return reply(500, { error = "occupant has no jid" }) end

        local ok = pcall(function() room:set_affiliation(true, jid, "outcast") end);
        if not ok then return reply(500, { error = "set_affiliation(outcast) failed" }) end

        -- restore so the person is removed, not permanently banned
        module:add_timer(3, function()
            pcall(function() room:set_affiliation(true, jid, prior == "owner" and "none" or "none") end);
        end);

        local still = false;
        for key in room:each_occupant() do
            local n = tostring(key):match("/(.+)$") or tostring(key);
            if n == nick then still = true end
        end
        log_event(actor, "kick", name, nick, "affiliation " .. tostring(prior) .. " -> outcast -> none; removed=" .. tostring(not still));
        if still then
            return reply(409, { error = "occupant still present after affiliation change", nick = nick });
        end
        return reply(200, { ok = true, room = name, kicked = nick, jid = jid,
                            mechanism = "affiliation outcast, restored to none after 3s" });
    elseif action == "mute" then
        log_event(actor, "mute-refused", name, body.nick or "", "server cannot enforce client mute");
        return reply(501, {
            error = "mute is client-enforced in Jitsi",
            detail = "audio state lives in the participant's client; a server-side mute is a request the client may ignore. Refusing rather than reporting a false success.",
            hint = "kick or use the moderator UI; real enforcement needs a client-side control channel",
        });
    end
    return reply(404, { error = "unknown action", action = action });
end

local function router(event)
    local path = (event.request.path or ""):gsub("^/ctl", "");
    local method = event.request.method;

    if path == "/rooms" and method == "GET" then return list_rooms(event) end

    local name, action = path:match("^/room/([^/]+)/?([^/]*)$");
    if name then
        if method == "GET" and (action == nil or action == "") then
            return room_get(event, name);
        end
        if method == "POST" and action ~= "" then
            return room_post(event, name, action);
        end
    end
    return reply(404, { error = "unknown route", path = path, method = method });
end

module:provides("http", {
    default_path = "ctl";
    route = {
        ["GET /rooms"] = router;
        ["GET /room/*"] = router;
        ["POST /room/*"] = router;
    };
});
