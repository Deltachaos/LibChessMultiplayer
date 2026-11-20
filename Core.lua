--[[
LibChessMultiplayer-1.0
Cross-addon chess challenges on top of LibMultiplayer.

    local chess = LibStub("LibChessMultiplayer-1.0"):New({
        name = "DeltaChess",
        version = "1.0.0",
        options = { "clock", "draw" },
    })

One client registers one addon. Every addon shares the prefix and channel
"ChessMP", so two different chess addons can play each other. See README.md.
]]

if not LibStub then return end

local MAJOR, MINOR = "LibChessMultiplayer-1.0", 10
local Lib = LibStub:NewLibrary(MAJOR, MINOR)
if not Lib then return end

local PROTOCOL = 1
local PREFIX = "ChessMP"
local CHANNEL = "ChessMP"
local CHALLENGE_TIMEOUT = 30
local ELO_K = 32

local DEFAULT_LABEL = {
    clock = "clocks",
    draw = "draw offers",
    pause = "pause offers",
}

local TEXT = {
    incompatible = "Opponent's chess multiplayer is not compatible.",
    busy = "Opponent is already in a game.",
    declined = "Opponent declined the challenge.",
    ["draw-declined"] = "Opponent declined the draw.",
    ["pause-declined"] = "Opponent declined the pause.",
    paused = "The game is paused.",
    timeout = "Opponent did not answer.",
    offline = "Opponent is offline.",
    ["no-route"] = "Opponent could not be reached.",
    trial = "Trial accounts cannot send addon messages.",
    serialize = "The message could not be sent.",
    password = "The lobby password was not accepted.",
    full = "The lobby is full.",
    spectators = "The lobby has no spectator seats.",
    move = "Move must be UCI long algebraic.",
    illegal = "Opponent rejected the move.",
    clock = "Clock must be minutes, or minutes+seconds such as 10 or \"10+1\".",
}

local CHALLENGE_RESERVED = { color = true, ranked = true }
local LOBBY_RESERVED = {
    color = true,
    title = true,
    capacity = true,
    password = true,
    spectators = true,
    onGame = true,
    onFail = true,
    matchmake = true,
    filter = true,
    ranked = true,
}

local Chess = {}
Chess.__index = Chess

local ns = {
    Lib = Lib,
    Chess = Chess,
    PROTOCOL = PROTOCOL,
    PREFIX = PREFIX,
    CHANNEL = CHANNEL,
    CHALLENGE_TIMEOUT = CHALLENGE_TIMEOUT,
    TEXT = TEXT,
    CHALLENGE_RESERVED = CHALLENGE_RESERVED,
    LOBBY_RESERVED = LOBBY_RESERVED,
    handlers = {},
}
Lib._ns = ns

function ns.defaultLabel(name)
    return DEFAULT_LABEL[name] or name
end

function ns.reasonText(code)
    return TEXT[code] or TEXT["no-route"]
end

function ns.report(callbacks, code, message, detail)
    if callbacks and callbacks.onFail then
        callbacks.onFail(code, message, detail)
    end
end

local Promise = {}
Promise.__index = Promise

function ns.promise()
    return setmetatable({ waiters = {} }, Promise)
end

function ns.rejected(code, message, detail)
    local promise = ns.promise()
    promise:err(code, message, detail)
    return promise
end

function Promise:_settle(state, ...)
    if self.state then return false end
    self.state = state
    self.n = select("#", ...)
    self.values = { ... }
    local waiters = self.waiters
    self.waiters = {}
    for i = 1, #waiters do waiters[i]() end
    return true
end

function Promise:ok(...)
    return self:_settle("ok", ...)
end

function Promise:err(...)
    return self:_settle("err", ...)
end

function Promise:_deliver(onOk, onErr)
    local a, b, c, d = unpack(self.values, 1, self.n)
    if self.state == "ok" then
        if onOk then
            onOk(a, b, c, d)
            return self
        end
        return true, a, b, c, d
    end
    if onErr then
        onErr(a, b, c, d)
        return self
    end
    return false, a, b, c, d
end

-- Wait for the ack or the chess reply. Pass onOk and onErr, or call resolve()
-- from a coroutine to yield until the response arrives.
function Promise:resolve(onOk, onErr)
    if self.state then return self:_deliver(onOk, onErr) end
    if onOk ~= nil or onErr ~= nil then
        self.waiters[#self.waiters + 1] = function()
            self:_deliver(onOk, onErr)
        end
        return self
    end
    local co = coroutine.running()
    if not co then return nil end
    self.waiters[#self.waiters + 1] = function()
        local function pack(...)
            return { n = select("#", ...), ... }
        end
        coroutine.resume(co, pack(self:_deliver()))
    end
    local packed = coroutine.yield()
    return unpack(packed, 1, packed.n)
end

function Promise:Cancel()
    return false
end

function ns.plain(value, depth)
    local kind = type(value)
    if kind ~= "table" then
        if kind == "string" or kind == "number" or kind == "boolean" then return value end
        return nil
    end
    if depth > 4 then return nil end
    local out = {}
    for key, item in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            local copied = ns.plain(item, depth + 1)
            if copied ~= nil then out[key] = copied end
        end
    end
    return out
end

function ns.collect(spec, reserved)
    local using = {}
    for key, value in pairs(spec or {}) do
        if type(key) == "string" and not reserved[key] and value ~= nil and type(value) ~= "function" then
            local copied = ns.plain(value, 0)
            if copied ~= nil then using[key] = copied end
        end
    end
    return using
end

function ns.names(map)
    local list = {}
    for name in pairs(map or {}) do list[#list + 1] = name end
    table.sort(list)
    return list
end

function ns.toSet(list)
    local set = {}
    if type(list) ~= "table" then return set end
    for i = 1, #list do
        if type(list[i]) == "string" then set[list[i]] = true end
    end
    return set
end

function ns.intersect(left, right)
    local out = {}
    for name in pairs(left or {}) do
        if right and right[name] then out[name] = true end
    end
    return out
end

function ns.labelsFor(names, labelMap)
    local text = {}
    for i = 1, #names do
        local name = names[i]
        text[i] = (labelMap and labelMap[name]) or ns.defaultLabel(name)
    end
    table.sort(text)
    return text
end

function ns.joinLabels(list)
    if #list == 0 then return "that feature" end
    if #list == 1 then return list[1] end
    if #list == 2 then return list[1] .. " and " .. list[2] end
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    local last = table.remove(copy)
    return table.concat(copy, ", ") .. ", and " .. last
end

local function trimNumber(value)
    if value == math.floor(value) then return string.format("%d", value) end
    local text = string.format("%.4f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

ns.trimNumber = trimNumber

function ns.joinText(parts)
    local out = {}
    for i = 1, #parts do
        local part = parts[i]
        if part ~= nil and part ~= "" then out[#out + 1] = part end
    end
    return table.concat(out, " · ")
end

function ns.colorName(color)
    if color == "white" then return "White" end
    if color == "black" then return "Black" end
    return nil
end

function ns.playerText(chess, player)
    local name = "Player"
    if type(player) == "table" and type(player.DisplayName) == "function" then
        local shown = player:DisplayName()
        if type(shown) == "string" and shown ~= "" then name = shown end
    end
    local known = chess and type(player) == "table" and chess:Identity(player) or nil
    local elo = known and type(known.elo) == "number" and ns.trimNumber(known.elo) or nil
    local addon = known and known.name or nil
    return ns.joinText({ name, elo, addon })
end

function ns.lobbyText(lobby)
    local info = type(lobby.Info) == "function" and lobby:Info() or {}
    info = info or {}
    local title = type(lobby.Title) == "function" and lobby:Title() or ""
    if type(title) ~= "string" or title == "" then
        local settings = info.settings
        title = ns.clockTitle(settings and settings.clock)
    end
    local hostName = "Host"
    if type(lobby.Host) == "function" then
        local host = lobby:Host()
        if type(host) == "table" and type(host.DisplayName) == "function" then
            local shown = host:DisplayName()
            if type(shown) == "string" and shown ~= "" then hostName = shown end
        end
    end
    local elo = type(info.elo) == "number" and ns.trimNumber(info.elo) or nil
    local count = type(lobby.Count) == "function" and lobby:Count() or 0
    local cap = type(lobby.Capacity) == "function" and lobby:Capacity() or nil
    local seats = tostring(count or 0)
    if type(cap) == "number" and cap > 0 then seats = tostring(count or 0) .. "/" .. tostring(cap) end
    local locked = type(lobby.HasPassword) == "function" and lobby:HasPassword() and "Locked" or nil
    local ranked = info.ranked == true and "Ranked" or nil
    return ns.joinText({ title, hostName, elo, seats, locked, ranked })
end

function ns.attachLobby(lobby)
    if type(lobby) ~= "table" then return lobby end
    function lobby:ToString()
        return ns.lobbyText(self)
    end
    return lobby
end

local function parseSide(value, inc)
    if type(value) == "number" then
        if value < 0 then return nil end
        if type(inc) ~= "number" or inc < 0 then inc = 0 end
        return value, inc
    end
    if type(value) ~= "string" then return nil end
    local minutes, increment = value:match("^(%d+%.?%d*)%+(%d+%.?%d*)$")
    if minutes then
        minutes, increment = tonumber(minutes), tonumber(increment)
        if not minutes or not increment or minutes < 0 or increment < 0 then return nil end
        return minutes, increment
    end
    local only = value:match("^(%d+%.?%d*)$")
    if not only then return nil end
    only = tonumber(only)
    if not only or only < 0 then return nil end
    if type(inc) ~= "number" or inc < 0 then inc = 0 end
    return only, inc
end

function ns.clock(value)
    if value == nil then return nil end
    if type(value) == "number" or type(value) == "string" then
        local minutes, inc = parseSide(value)
        if not minutes then return nil end
        return {
            hostTime = minutes,
            hostInc = inc,
            opponentTime = minutes,
            opponentInc = inc,
        }
    end
    if type(value) ~= "table" then return nil end
    local host = value.hostTime
    local opponent = value.opponentTime
    if host == nil then host = opponent end
    if opponent == nil then opponent = host end
    if host == nil then return nil end
    local hostTime, hostInc = parseSide(host, value.hostInc)
    local opponentTime, opponentInc = parseSide(opponent, value.opponentInc)
    if not hostTime or not opponentTime then return nil end
    return {
        hostTime = hostTime,
        hostInc = hostInc,
        opponentTime = opponentTime,
        opponentInc = opponentInc,
    }
end

function ns.clockTitle(clock)
    if type(clock) ~= "table" then return "Untimed" end
    local function side(minutes, inc)
        return trimNumber(minutes) .. "+" .. trimNumber(inc)
    end
    local host = side(clock.hostTime, clock.hostInc)
    local opponent = side(clock.opponentTime, clock.opponentInc)
    if host == opponent then return host end
    return host .. " vs " .. opponent
end

function ns.clockFits(clock, filter)
    filter = filter or {}
    local function inRange(value, range)
        if not range then return true end
        if type(value) ~= "number" then return false end
        if type(range.min) == "number" and value < range.min then return false end
        if type(range.max) == "number" and value > range.max then return false end
        return true
    end
    if filter.time or filter.inc then
        if type(clock) ~= "table" then return false end
        if not inRange(clock.hostTime, filter.time) or not inRange(clock.opponentTime, filter.time) then
            return false
        end
        if not inRange(clock.hostInc, filter.inc) or not inRange(clock.opponentInc, filter.inc) then
            return false
        end
    end
    return true
end

function ns.unsupportedMessage(kind, labelList)
    local text = ns.joinLabels(labelList)
    if kind == "lobby" then
        return "This lobby requires " .. text .. "."
    end
    return "Opponent does not support " .. text .. "."
end

function ns.resolveColor(color)
    if color == "white" or color == "black" then return color end
    if color == "random" then
        if math.random(1, 2) == 1 then return "white" end
        return "black"
    end
    return "white"
end

function ns.opposite(color)
    if color == "black" then return "white" end
    return "black"
end

function ns.validUci(uci)
    return type(uci) == "string" and uci:match("^[a-h][1-8][a-h][1-8][qrbn]?$") ~= nil
end

function ns.newId(chess)
    chess._seq = (chess._seq or 0) + 1
    local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local out = {}
    for i = 1, 6 do
        local n = math.random(1, #alphabet)
        out[i] = alphabet:sub(n, n)
    end
    out[#out + 1] = string.format("%x", chess._seq)
    return table.concat(out)
end

function ns.on(name, fn)
    ns.handlers[name] = fn
end

function ns.dispatch(chess, player, payload)
    if type(payload) ~= "table" or type(payload.t) ~= "string" then return end
    if not player or chess.session:IsMe(player) then return end
    if payload.v ~= PROTOCOL then
        if payload.t == "challenge" then
            chess:Reject(player, payload.id, "incompatible", TEXT.incompatible)
        end
        return
    end
    local fn = ns.handlers[payload.t]
    if fn then fn(chess, player, payload) end
end

function Chess:Key(player)
    if type(player) ~= "table" then return tostring(player) end
    if player.key and player.key ~= "" then return player.key end
    if player.Address then return player:Address() end
    return tostring(player)
end

function Chess:Peer(player)
    if type(player) ~= "table" then return player end
    if not player.Option then
        local chess = self
        function player:Option(name)
            local known = chess.identities[chess:Key(self)]
            if not known then return nil end
            return known.options[name] == true
        end
        function player:ChessId()
            local known = chess.identities[chess:Key(self)]
            if not known then return nil end
            local options = ns.names(known.options)
            local id = {
                name = known.name,
                version = known.version,
                protocol = known.protocol,
                options = options,
            }
            if type(known.elo) == "number" then id.elo = known.elo end
            return id
        end
        function player:ToString()
            return ns.playerText(chess, self)
        end
    end
    return player
end

function Chess:Remember(player, payload)
    if type(payload) ~= "table" or type(payload.name) ~= "string" or type(payload.options) ~= "table" then
        return nil
    end
    local id = {
        name = payload.name,
        version = payload.version,
        protocol = payload.v or PROTOCOL,
        options = ns.toSet(payload.options),
        labels = type(payload.labels) == "table" and payload.labels or {},
    }
    if type(payload.elo) == "number" and payload.elo >= 0 then id.elo = payload.elo end
    self.identities[self:Key(player)] = id
    self:Peer(player)
    return id
end

function Chess:Identity(player)
    return self.identities[self:Key(player)]
end

function Chess:SupportedList()
    return ns.names(self.options)
end

function Chess:Label(name)
    local spec = self.options[name]
    if spec and spec.label then return spec.label end
    return ns.defaultLabel(name)
end

function Chess:LabelMap()
    local map = {}
    for name in pairs(self.options) do map[name] = self:Label(name) end
    return map
end

function Chess:IdentityPayload(extra)
    local payload = extra or {}
    payload.name = self.name
    payload.version = self.version
    payload.options = self:SupportedList()
    payload.labels = self:LabelMap()
    if type(self.elo) == "number" then payload.elo = self.elo end
    return payload
end

function Chess:Missing(supported, names, labelMap)
    local missing = {}
    for i = 1, #names do
        if not supported[names[i]] then missing[#missing + 1] = names[i] end
    end
    table.sort(missing)
    return missing, ns.labelsFor(missing, labelMap)
end

function Chess:Send(player, payload, onFail)
    payload.v = PROTOCOL
    local promise = ns.promise()
    if type(onFail) == "function" then promise:resolve(nil, onFail) end
    local queued = self.session:Send(player, payload, {
        onAck = function()
            promise:ok()
        end,
        onFail = function(_, reason)
            local code = reason or "no-route"
            promise:err(code, ns.reasonText(code))
        end,
        onTimeout = function()
            promise:err("timeout", TEXT.timeout)
        end,
    })
    if not queued and not promise.state then
        promise:err("no-route", TEXT["no-route"])
    end
    return promise
end

function Chess:Id()
    local id = {
        name = self.name,
        version = self.version,
        protocol = PROTOCOL,
        options = self:SupportedList(),
    }
    if type(self.elo) == "number" then id.elo = self.elo end
    return id
end

function Chess:Elo(value)
    if value == nil then return self.elo end
    if type(value) ~= "number" or value < 0 then return false end
    self.elo = value
    return self.elo
end

local function eloScore(result, color)
    if color ~= "white" and color ~= "black" then return nil end
    if result == "1/2-1/2" then return 0.5 end
    if result == "1-0" then return color == "white" and 1 or 0 end
    if result == "0-1" then return color == "black" and 1 or 0 end
    return nil
end

local function eloExpected(rating, opponent)
    if type(rating) ~= "number" or type(opponent) ~= "number" then return nil end
    if rating < 0 or opponent < 0 then return nil end
    return 1 / (1 + 10 ^ ((opponent - rating) / 400))
end

local function eloNext(rating, opponent, score, k)
    local expected = eloExpected(rating, opponent)
    if not expected then return nil end
    if type(score) ~= "number" or score < 0 or score > 1 then return nil end
    if k == nil then k = ELO_K end
    if type(k) ~= "number" or k < 0 then return nil end
    local delta = k * (score - expected)
    return rating + delta, delta
end

-- Result is from White. Returns the new ratings and the deltas, unrounded.
function Chess:EloAfter(white, black, result, k)
    local whiteScore = eloScore(result, "white")
    if whiteScore == nil then return nil end
    local whiteNew, whiteDelta = eloNext(white, black, whiteScore, k)
    if whiteNew == nil then return nil end
    local blackNew, blackDelta = eloNext(black, white, 1 - whiteScore, k)
    return whiteNew, blackNew, whiteDelta, blackDelta
end

function Chess:Option(name, spec)
    if spec == nil then return self.options[name] ~= nil end
    if type(name) ~= "string" or name == "" then return false end
    local label = ns.defaultLabel(name)
    if type(spec) == "table" and type(spec.label) == "string" and spec.label ~= "" then
        label = spec.label
    end
    self.options[name] = { label = label }
    return true
end

function Chess:Busy(flag)
    if flag == nil then return self.busy == true end
    self.busy = flag and true or false
    return self.busy
end

function Chess:OnChallenge(fn)
    self.onChallenge = fn
end

function Chess:OnGame(fn)
    self.onGame = fn
end

function Chess:OnCommand(name, fn)
    if type(name) ~= "string" or name == "" then return false end
    if not self.options[name] then self:Option(name, {}) end
    self.commands[name] = fn
    return true
end

function Chess:Begin(game, extra)
    self.game = game
    self.outgoing = nil
    self.incoming = nil
    self.pendingStart = nil
    self.joining = nil
    if self.onGame then self.onGame(game) end
    if extra then extra(game) end
end

function Lib:New(opts)
    if Lib.owner then
        local who = Lib.owner
        if who and who ~= "" then
            return false, "LibChessMultiplayer is already registered by " .. who .. "."
        end
        return false, "LibChessMultiplayer is already registered."
    end
    if type(opts) ~= "table" or type(opts.name) ~= "string" or opts.name == "" then
        error("LibChessMultiplayer: name is required", 2)
    end
    local MP = LibStub:GetLibrary("LibMultiplayer-1.0", true)
    if not MP then error("LibChessMultiplayer requires LibMultiplayer-1.0", 2) end
    local chess = setmetatable({
        name = opts.name,
        version = type(opts.version) == "string" and opts.version or "0",
        options = {},
        commands = {},
        identities = {},
        queries = {},
        busy = false,
    }, Chess)
    for i = 1, #(opts.options or {}) do
        local name = opts.options[i]
        if type(name) == "string" and name ~= "" then chess:Option(name, {}) end
    end
    chess.session = MP:New({ prefix = PREFIX })
    chess.session:EnableChannel(CHANNEL)
    chess.session:OnMessage(function(player, payload)
        ns.dispatch(chess, player, payload)
    end)
    if chess.Bind then chess:Bind() end
    Lib.owner = opts.name
    Lib.chess = chess
    return chess
end
