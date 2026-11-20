local Lib = LibStub and LibStub:GetLibrary("LibChessMultiplayer-1.0", true)
local ns = Lib and Lib._ns
if not ns or ns.sealed then return end

local Chess = ns.Chess
local TEXT = ns.TEXT

function Chess:Query(player, onId)
    local promise = ns.promise()
    local function deliver(peer)
        promise:ok(peer)
        if onId then onId(peer) end
    end
    if type(player) == "string" then player = self.session:Player(player) end
    if type(player) ~= "table" then
        promise:err("no-route", TEXT["no-route"])
        return promise
    end
    player = self:Peer(player)
    local key = self:Key(player)
    if self:Identity(player) then
        deliver(player)
        return promise
    end
    local waiting = self.queries[key]
    if not waiting then
        waiting = { fail = {} }
        self.queries[key] = waiting
    end
    waiting[#waiting + 1] = deliver
    waiting.fail[#waiting.fail + 1] = promise
    if waiting.sent then return promise end
    waiting.sent = true
    local payload = self:IdentityPayload({ t = "id", ask = true })
    local sent = self:Send(player, payload, function(code, message)
        local pending = self.queries[key]
        self.queries[key] = nil
        if not pending or not pending.fail then return end
        for i = 1, #pending.fail do pending.fail[i]:err(code, message) end
    end)
    if sent.state == "err" then
        self.queries[key] = nil
        return promise
    end
    return promise
end

function Chess:Discover(opts)
    opts = opts or {}
    local promise = ns.promise()
    local ok = self.session:Discover({
        where = opts.where,
        wait = opts.wait,
        onPlayer = function(player)
            player = self:Peer(player)
            if opts.onPlayer then opts.onPlayer(player) end
        end,
        onDone = function(list, reason)
            if reason == "trial" then
                promise:err("trial", TEXT.trial)
                if opts.onDone then opts.onDone({}, reason) end
                return
            end
            local peers = {}
            for i = 1, #(list or {}) do peers[i] = self:Peer(list[i]) end
            promise:ok(peers)
            if opts.onDone then opts.onDone(peers, reason) end
        end,
    })
    if not ok and not promise.state then
        promise:err("no-route", TEXT["no-route"])
    end
    return promise
end

function Chess:Lobbies()
    local list = self.session:Lobbies()
    for i = 1, #list do ns.attachLobby(list[i]) end
    return list
end

function Chess:ListLobby(spec)
    spec = spec or {}
    if self.hosted and self.hosted.lobby then return self.hosted.lobby end
    local source = {}
    for key, value in pairs(spec) do source[key] = value end
    local clock = nil
    if spec.clock ~= nil then
        clock = ns.clock(spec.clock)
        if not clock then return nil end
        source.clock = clock
    end
    local using = ns.collect(source, ns.LOBBY_RESERVED)
    local missing, labels = self:Missing(self.options, ns.names(using), self:LabelMap())
    if #missing > 0 then return nil end
    local title = spec.title
    if type(title) ~= "string" or title == "" then title = ns.clockTitle(clock) end
    local info = {
        name = self.name,
        version = self.version,
        protocol = ns.PROTOCOL,
        options = ns.names(using),
        labels = {},
        color = ns.resolveColor(spec.color),
        ranked = spec.ranked == true,
        settings = using,
    }
    if spec.matchmake then info.matchmake = true end
    if type(self.elo) == "number" then info.elo = self.elo end
    for i = 1, #info.options do
        info.labels[info.options[i]] = self:Label(info.options[i])
    end
    local lobby = self.session:ListLobby({
        title = title,
        capacity = spec.capacity or 2,
        password = spec.password,
        spectators = spec.spectators,
        info = info,
    })
    if not lobby then return nil end
    ns.attachLobby(lobby)
    self.hosted = {
        lobby = lobby,
        onGame = spec.onGame,
        onFail = spec.onFail,
        started = false,
        greeted = {},
    }
    return lobby
end

function Chess:ConsiderGuest(player)
    local hosted = self.hosted
    if not hosted or hosted.started or type(player) ~= "table" then return end
    if self.session:IsMe(player) then return end
    local key = self:Key(player)
    if hosted.greeted[key] then return end
    -- The seat message is the guest's id. The game starts once that arrives.
    if not self:Identity(player) then return end
    hosted.greeted[key] = true
    local peer = self:Peer(player)
    local info = hosted.lobby:Info() or {}
    local known = self:Identity(peer)
    if not known or known.protocol ~= ns.PROTOCOL then
        self:Send(peer, self:IdentityPayload({
            t = "unwelcome",
            code = "incompatible",
            message = TEXT.incompatible,
        }))
        return
    end
    local missing, labels = self:Missing(known.options, info.options or {}, info.labels)
    if #missing > 0 then
        self:Send(peer, {
            t = "unwelcome",
            code = "unsupported",
            message = ns.unsupportedMessage("lobby", labels),
            features = missing,
        })
        return
    end
    hosted.started = true
    local spec = {}
    for name, value in pairs(info.settings or {}) do spec[name] = value end
    spec.color = info.color or "white"
    spec.ranked = info.ranked == true
    local queued = self:Challenge(peer, spec, {
        auto = true,
        onGame = hosted.onGame,
        onFail = function(code, message, detail)
            if self.hosted == hosted then hosted.started = false end
            if hosted.onFail then hosted.onFail(code, message, detail) end
        end,
    })
    if queued.state == "err" and self.hosted == hosted then hosted.started = false end
end

function Chess:ReviewGuests()
    local hosted = self.hosted
    if not hosted or hosted.started or not hosted.lobby then return end
    local members = hosted.lobby:Members()
    for i = 1, #members do self:ConsiderGuest(members[i]) end
end

function Chess:Join(lobby, callbacks)
    callbacks = callbacks or {}
    local promise = ns.promise()
    local wrapped = {
        password = callbacks.password,
        onGame = function(game)
            promise:ok(game)
            if callbacks.onGame then callbacks.onGame(game) end
        end,
        onFail = function(code, message, detail)
            promise:err(code, message, detail)
            if callbacks.onFail then callbacks.onFail(code, message, detail) end
        end,
    }
    local function refuse(code, message, detail)
        ns.report(wrapped, code, message, detail)
        return promise
    end
    if self.game then
        return refuse("busy", "You are already in a game.")
    end
    if self.busy then
        return refuse("busy", "You are not accepting challenges.")
    end
    if type(lobby) ~= "table" or type(lobby.Info) ~= "function" or type(lobby.Id) ~= "function" then
        return refuse("no-route", TEXT["no-route"])
    end
    local info = lobby:Info() or {}
    if info.protocol ~= ns.PROTOCOL then
        return refuse("incompatible", TEXT.incompatible)
    end
    local missing, labels = self:Missing(self.options, info.options or {}, info.labels)
    if #missing > 0 then
        return refuse("unsupported", ns.unsupportedMessage("lobby", labels), { features = missing })
    end
    self.joining = { id = lobby:Id(), callbacks = wrapped, info = info }
    local joinOpts = nil
    if type(callbacks.password) == "string" and callbacks.password ~= "" then
        joinOpts = { password = callbacks.password }
    end
    local ok = self.session:Join(lobby, joinOpts)
    if ok == false then
        if self.joining and self.joining.id == lobby:Id() then
            self.joining = nil
            return refuse("no-route", TEXT["no-route"])
        end
        return promise
    end
    return promise
end

function Chess:Bind()
    local chess = self
    self.session:OnJoinResult(function(id, accepted, reason)
        local joining = chess.joining
        if not joining or joining.id ~= id then return end
        if not accepted then
            chess.joining = nil
            local code = reason or "no-route"
            ns.report(joining.callbacks, code, ns.reasonText(code))
            return
        end
        local host
        local list = chess.session:Lobbies()
        for i = 1, #list do
            if list[i]:Id() == id then host = list[i]:Host() end
        end
        if host and not chess.session:IsMe(host) then
            chess:Send(host, chess:IdentityPayload({ t = "seat", lobby = id }))
        end
    end)
    self.session:OnLobbies(function()
        chess:ReviewGuests()
    end)
end

local function releaseQuery(chess, player)
    if not chess:Identity(player) then return end
    local key = chess:Key(player)
    local waiting = chess.queries[key]
    if not waiting then return end
    chess.queries[key] = nil
    local peer = chess:Peer(player)
    for i = 1, #waiting do waiting[i](peer) end
end

local function onId(chess, player, payload)
    chess:Remember(player, payload)
    if payload.ask then
        chess:Send(player, chess:IdentityPayload({ t = "id" }))
    end
    releaseQuery(chess, player)
end

local function onSeat(chess, player, payload)
    chess:Remember(player, payload)
    local hosted = chess.hosted
    if not hosted or not hosted.lobby or hosted.lobby:Id() ~= payload.lobby then return end
    chess:ConsiderGuest(player)
    releaseQuery(chess, player)
end

local function onUnwelcome(chess, _, payload)
    local joining = chess.joining
    if not joining then return end
    chess.joining = nil
    chess.session:Leave()
    local detail = nil
    if type(payload.features) == "table" then detail = { features = payload.features } end
    ns.report(joining.callbacks, payload.code or "unsupported", payload.message or TEXT.incompatible, detail)
end

local function sameValue(left, right, depth)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if depth > 4 then return false end
    for key, value in pairs(left) do
        if not sameValue(value, right[key], depth + 1) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function onNewLobby(session, fn)
    if type(session.OnLobby) == "function" then
        session:OnLobby(fn)
        return
    end
    local seen = {}
    local current = session:Lobbies()
    for i = 1, #current do seen[current[i]:Id()] = true end
    session:OnLobbies(function(list)
        for i = 1, #list do
            local lobby = list[i]
            local id = lobby:Id()
            if not seen[id] then
                seen[id] = true
                fn(lobby)
            end
        end
    end)
end

function Chess:Matchmake(spec)
    spec = spec or {}
    if self.matchmake and not self.matchmake.state then return self.matchmake end
    local promise = ns.promise()
    self.matchmake = promise
    local wanted = ns.collect(spec, ns.LOBBY_RESERVED)
    wanted.clock = nil
    local hostedClock = nil
    if spec.clock ~= nil then
        hostedClock = ns.clock(spec.clock)
        if not hostedClock then
            promise:err("clock", TEXT.clock)
            if spec.onFail then spec.onFail("clock", TEXT.clock) end
            return promise
        end
    elseif spec.filter and (spec.filter.time or spec.filter.inc) then
        local time = spec.filter.time or {}
        local inc = spec.filter.inc or {}
        local minutes = time.min or time.max or 10
        local seconds = inc.min or inc.max or 0
        hostedClock = ns.clock({
            hostTime = minutes,
            hostInc = seconds,
            opponentTime = minutes,
            opponentInc = seconds,
        })
    end
    if hostedClock then wanted.clock = true end
    local missing, labels = self:Missing(self.options, ns.names(wanted), self:LabelMap())
    if #missing > 0 then
        local message = "This addon does not support " .. ns.joinLabels(labels) .. "."
        promise:err("unsupported", message, { features = missing })
        if spec.onFail then spec.onFail("unsupported", message, { features = missing }) end
        return promise
    end
    if self.game then
        promise:err("busy", "You are already in a game.")
        if spec.onFail then spec.onFail("busy", "You are already in a game.") end
        return promise
    end
    if self.busy then
        promise:err("busy", "You are not accepting challenges.")
        if spec.onFail then spec.onFail("busy", "You are not accepting challenges.") end
        return promise
    end

    local chess = self
    local stopped = false
    local skipped = {}

    local function score(lobby)
        if type(lobby) ~= "table" or type(lobby.Id) ~= "function" then return nil end
        if skipped[lobby:Id()] then return nil end
        if lobby:IsMine() then return nil end
        if lobby:HasPassword() and (type(spec.password) ~= "string" or spec.password == "") then return nil end
        local cap = lobby:Capacity()
        if type(cap) == "number" and cap > 0 and lobby:Count() >= cap then return nil end
        local info = lobby:Info() or {}
        if info.protocol ~= ns.PROTOCOL then return nil end
        if (info.ranked == true) ~= (spec.ranked == true) then return nil end
        local absent = chess:Missing(chess.options, info.options or {}, info.labels)
        if #absent > 0 then return nil end
        local settings = info.settings or {}
        for key, value in pairs(wanted) do
            if key ~= "clock" and not sameValue(settings[key], value, 0) then return nil end
        end
        if not ns.clockFits(settings.clock, spec.filter) then return nil end
        local eloFilter = spec.filter and spec.filter.elo
        if eloFilter then
            local elo = info.elo
            if type(elo) ~= "number" then return nil end
            if type(eloFilter.min) == "number" and elo < eloFilter.min then return nil end
            if type(eloFilter.max) == "number" and elo > eloFilter.max then return nil end
        end
        local extra = 0
        for key in pairs(settings) do
            if key ~= "clock" and wanted[key] == nil then extra = extra + 1 end
        end
        local closeness = 0
        local time = spec.filter and spec.filter.time
        if time and type(settings.clock) == "table" then
            local mid = time.min
            if type(time.min) == "number" and type(time.max) == "number" then
                mid = (time.min + time.max) / 2
            elseif type(time.max) == "number" then
                mid = time.max
            end
            if type(mid) == "number" then
                closeness = math.abs(settings.clock.hostTime - mid) + math.abs(settings.clock.opponentTime - mid)
            end
        end
        return 1000 - closeness * 10 - extra * 10 + (lobby:Count() or 0)
    end

    local function best()
        local list = chess:Lobbies()
        local winner, winnerScore, winnerId
        for i = 1, #list do
            local lobby = list[i]
            local points = score(lobby)
            if points then
                local id = lobby:Id()
                if not winner or points > winnerScore or (points == winnerScore and id < winnerId) then
                    winner, winnerScore, winnerId = lobby, points, id
                end
            end
        end
        return winner
    end

    local function finish(game)
        if stopped then return end
        stopped = true
        promise:ok(game)
        if spec.onGame then spec.onGame(game) end
    end

    local function host()
        if stopped or chess.game then return end
        if chess.hosted and chess.hosted.lobby then
            chess.hosted.matchmake = true
            return
        end
        local listed = {}
        for key, value in pairs(spec) do listed[key] = value end
        listed.matchmake = true
        listed.filter = nil
        if hostedClock then listed.clock = hostedClock end
        listed.onGame = finish
        listed.onFail = spec.onFail
        local lobby = chess:ListLobby(listed)
        if lobby and chess.hosted then chess.hosted.matchmake = true end
        if lobby then return end
        stopped = true
        promise:err("no-route", TEXT["no-route"])
        if spec.onFail then spec.onFail("no-route", TEXT["no-route"]) end
    end

    local function tryJoin(lobby)
        if stopped or chess.game or not lobby then return end
        skipped[lobby:Id()] = true
        chess:Join(lobby, {
            password = spec.password,
            onGame = finish,
            onFail = function()
                if stopped or chess.game then return end
                chess.session:Leave()
                local nextLobby = best()
                if nextLobby then tryJoin(nextLobby) else host() end
            end,
        })
    end

    local function consider()
        if stopped or chess.game then return end
        local hosted = chess.hosted
        if not hosted or not hosted.matchmake or not hosted.lobby or hosted.started then return end
        if hosted.lobby:Count() > 1 then return end
        local winner = best()
        if not winner then return end
        local info = winner:Info() or {}
        if info.matchmake and winner:Id() > hosted.lobby:Id() then return end
        chess.hosted = nil
        chess.session:DelistLobby()
        tryJoin(winner)
    end

    function promise:Cancel()
        if stopped or promise.state then return false end
        stopped = true
        if chess.joining then
            chess.joining = nil
            chess.session:Leave()
        end
        if chess.hosted and chess.hosted.matchmake then
            chess.session:DelistLobby()
            chess.hosted = nil
        end
        promise:err("declined", "The challenge was cancelled.")
        return true
    end

    onNewLobby(self.session, function()
        consider()
    end)
    local chosen = best()
    if chosen then tryJoin(chosen) else host() end
    return promise
end

ns.on("id", onId)
ns.on("seat", onSeat)
ns.on("unwelcome", onUnwelcome)

ns.sealed = true
