local Test = require("test")
local assertEq = Test.assertEq
local assertTrue = Test.assertTrue

local world = {
    time = 1000,
    clients = {},
    channelSeq = 0,
    channelByName = {},
    channelById = {},
}

Test.suite("LibChessMultiplayer", "protocol")

local register = Test.test
function Test.test(name, fn)
    register(name, function()
        world.clients = {}
        world.channelSeq = 0
        world.channelByName = {}
        world.channelById = {}
        world.time = world.time + 5
        fn()
    end)
end

local function exists(path)
    local handle = io.open(path, "r")
    if not handle then return false end
    handle:close()
    return true
end

local function multiplayerToc()
    if exists("Libs/LibMultiplayer/LibMultiplayer.toc") then
        return "Libs/LibMultiplayer/LibMultiplayer.toc"
    end
    if exists("../LibMultiplayer/LibMultiplayer.toc") then
        return "../LibMultiplayer/LibMultiplayer.toc"
    end
    error("LibMultiplayer.toc not found")
end

local MP_TOC = multiplayerToc()

local function kindOf(text)
    return type(text) == "string" and text:match("^([^\001]+)") or ""
end

local function advance(clients, dt)
    local left = dt
    while left > 0 do
        local step = math.min(0.25, left)
        world.time = world.time + step
        for i = 1, #clients do clients[i]:pump(step) end
        left = left - step
    end
end

local function findClient(target)
    for i = 1, #world.clients do
        if world.clients[i]:matches(target) then return world.clients[i] end
    end
end

function world:channelId(name)
    local id = self.channelByName[name]
    if not id then
        self.channelSeq = self.channelSeq + 1
        id = self.channelSeq
        self.channelByName[name] = id
        self.channelById[id] = name
    end
    return id
end

function world:route(from, prefix, text, distribution, target)
    if distribution == "WHISPER" then
        local to = findClient(target)
        if to then
            to:event("CHAT_MSG_ADDON", prefix, text, "WHISPER", from:label())
        end
        return 0
    end
    for i = 1, #self.clients do
        local other = self.clients[i]
        if other ~= from then
            local okDist = false
            if distribution == "GUILD" then
                okDist = other.guild and other.guild == from.guild
            elseif distribution == "CHANNEL" then
                local name = type(target) == "number" and self.channelById[target] or target
                okDist = type(name) == "string" and from.channels[name] ~= nil and other.channels[name] ~= nil
            end
            if okDist then
                other:event("CHAT_MSG_ADDON", prefix, text, distribution, from:label())
            end
        end
    end
    return 0
end

local function newClient(spec)
    spec = spec or {}
    local env = { _G = nil }
    env._G = env
    setmetatable(env, { __index = function(_, key)
        if key == "LibStub" then return nil end
        return _G[key]
    end })
    local client = {
        id = spec.id,
        unit = spec.unit,
        realm = spec.realm or "Stormrage",
        faction = spec.faction or "Alliance",
        guild = spec.guild,
        channels = {},
        sends = {},
        env = env,
    }
    function client:label()
        if self.session then
            local ok, name = pcall(function() return self.session:MyName() end)
            if ok and name then return name end
        end
        return self.unit .. "-" .. (self.realm:gsub("[%s%-]", ""))
    end
    function client:matches(target)
        if target == nil then return false end
        local text = tostring(target)
        local folded = text:gsub("[%s%-]", ""):lower()
        local names = { self.unit, self.unit .. "-" .. self.realm, self:label() }
        if self.session then
            local me = self.session:Me()
            if me then
                names[#names + 1] = me:Address()
                names[#names + 1] = me:DisplayName()
            end
        end
        for i = 1, #names do
            local name = names[i]
            if name and (name:lower() == text:lower() or name:gsub("[%s%-]", ""):lower() == folded) then
                return true
            end
        end
        return false
    end
    function client:event(event, ...)
        local frame = self.mp._frame
        frame:GetScript("OnEvent")(frame, event, ...)
    end
    function client:pump(dt)
        local frame = self.mp._frame
        frame:GetScript("OnUpdate")(frame, dt)
    end

    function env.strmatch(s, pattern, init)
        return string.match(tostring(s), pattern, init)
    end
    function env.CreateFrame()
        local frame = { scripts = {} }
        function frame:RegisterEvent() end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        function frame:GetScript(name) return self.scripts[name] end
        return frame
    end
    function env.GetTime() return world.time end
    function env.UnitName(unit)
        if unit == "player" then return spec.unit end
        return nil
    end
    function env.UnitFactionGroup() return client.faction end
    function env.GetNormalizedRealmName() return client.realm:gsub("[%s%-]", "") end
    function env.GetRealmName() return client.realm end
    function env.InCombatLockdown() return false end
    function env.IsInInstance() return false end
    function env.IsTrialAccount() return false end
    function env.IsInGuild() return client.guild ~= nil end
    function env.GetNumGuildMembers() return 0 end
    function env.IsInGroup() return false end
    function env.IsInRaid() return false end
    function env.GetNumGroupMembers() return 0 end
    function env.GetChannelList() return 1, "General" end
    function env.GetChannelName(channelName)
        local id = client.channels[channelName]
        if id then return id, channelName end
        return 0
    end
    function env.JoinTemporaryChannel(channelName)
        client.channels[channelName] = world:channelId(channelName)
    end
    function env.JoinChannelByName(channelName)
        client.channels[channelName] = world:channelId(channelName)
    end
    function env.LeaveChannelByName(channelName)
        client.channels[channelName] = nil
    end
    function env.ChatFrame_RemoveChannel() end
    function env.ChatFrame_AddMessageEventFilter() end
    env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    env.WOW_PROJECT_ID = 1
    env.BNET_CLIENT_WOW = "WoW"
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, text, distribution, target)
            client.sends[#client.sends + 1] = {
                prefix = prefix, text = text, distribution = distribution, target = target,
            }
            return world:route(client, prefix, text, distribution, target)
        end,
    }
    function env.BNGetNumFriends() return 0 end
    env.C_BattleNet = {
        GetFriendAccountInfo = function() return nil end,
        GetFriendNumGameAccounts = function() return 0 end,
        GetFriendGameAccountInfo = function() return nil end,
        SendGameData = function() return 0 end,
    }
    env.C_FriendList = {
        GetNumFriends = function() return 0 end,
        GetFriendInfoByIndex = function() return nil end,
    }

    Test.loadToc(MP_TOC, env)
    Test.loadToc("LibChessMultiplayer.toc", env)
    client.mp = env.LibStub("LibMultiplayer-1.0")
    client.lib = env.LibStub("LibChessMultiplayer-1.0")
    client.chess = client.lib:New({
        name = spec.name or spec.unit,
        version = spec.version or "1.0.0",
        options = spec.options,
    })
    client.session = client.chess.session
    world.clients[#world.clients + 1] = client
    return client
end

local CLOCK = "10+0"

Test.test("clock challenge is rejected when the recipient has no clock", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "TavernChess", options = { "draw" } })
    local opened = false
    bob.chess:OnChallenge(function() opened = true end)
    local code, message
    local ok = alice.chess:Challenge("Bob", { color = "white", clock = CLOCK }, {
        onFail = function(gotCode, gotMessage)
            code, message = gotCode, gotMessage
        end,
    })
    assertTrue(ok)
    advance({ alice, bob }, 1)
    assertEq(code, "unsupported")
    assertEq(message, "Opponent does not support clocks.")
    assertTrue(not opened, "recipient ui opened")

    local againCode
    local again = alice.chess:Challenge("Bob", { color = "white", clock = CLOCK }, {
        onFail = function(gotCode) againCode = gotCode end,
    })
    again:resolve(nil, function(code) againCode = code end)
    assertEq(againCode, "unsupported")
    assertTrue(not opened, "cached challenge opened the ui")
end)

Test.test("a peer with more options accepts a clock challenge", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", version = "2.0.0", options = { "clock", "draw" } })
    local opened = false
    local gameA, gameB
    bob.chess:OnChallenge(function(offer)
        opened = true
        assertEq(offer.name, "DeltaChess")
        assertEq(offer.clock.hostTime, 10)
        assertEq(offer.clock.hostInc, 0)
        assertEq(offer.clock.opponentTime, 10)
        offer:Accept()
    end)
    bob.chess:OnGame(function(game) gameB = game end)
    local promised
    local ok = alice.chess:Challenge("Bob", { color = "white", clock = CLOCK }, {
        onGame = function(game) gameA = game end,
    })
    ok:resolve(function(game) promised = game end)
    assertTrue(ok)
    advance({ alice, bob }, 1)
    assertTrue(opened, "challenge was not shown")
    assertTrue(gameA ~= nil, "challenger game")
    assertTrue(promised == gameA, "challenge promise")
    assertTrue(gameB ~= nil, "recipient game")
    local drawCode, drawMessage
    gameB:OfferDraw():resolve(nil, function(code, message)
        drawCode, drawMessage = code, message
    end)
    assertEq(drawCode, "unsupported")
    assertEq(drawMessage, "Opponent does not support draw offers.")
    assertTrue(not gameB.over, "draw ended the game")
end)

Test.test("uci move and resign reach the other board", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess" })
    local bob = newClient({ id = "bob", unit = "Bob", name = "WoWChess" })
    local gameA, gameB
    bob.chess:OnChallenge(function(offer) offer:Accept() end)
    bob.chess:OnGame(function(game) gameB = game end)
    alice.chess:Challenge("Bob", { color = "white" }, {
        onGame = function(game) gameA = game end,
    })
    advance({ alice, bob }, 1)
    assertTrue(gameA ~= nil and gameB ~= nil, "game did not start")
    local uci, ply
    gameB:OnMove(function(move)
        uci, ply = move.uci, move.ply
        assertEq(move:ToString(), "e2e4")
        move:Accept()
    end)
    local acked, viaCallback = false, false
    local pending = gameA:Move("e2e4", function(ok)
        viaCallback = ok
    end)
    pending:resolve(function() acked = true end)
    assertTrue(not acked and not viaCallback, "move resolved before the ack")
    advance({ alice, bob }, 1)
    assertTrue(acked and viaCallback, "move was not acknowledged")
    assertEq(uci, "e2e4")
    assertEq(ply, 1)
    local waited
    local co = coroutine.create(function()
        waited = gameB:Move("e7e5"):resolve()
    end)
    coroutine.resume(co)
    assertEq(coroutine.status(co), "suspended")
    advance({ alice, bob }, 1)
    assertEq(waited, true)
    local result, reason
    gameB:OnOver(function(gotResult, gotReason)
        result, reason = gotResult, gotReason
    end)
    assertTrue(gameA:Resign())
    advance({ alice, bob }, 1)
    assertEq(result, "0-1")
    assertEq(reason, "resign")
end)

Test.test("the opponent can reject a move the engine treats as illegal", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess" })
    local bob = newClient({ id = "bob", unit = "Bob", name = "WoWChess" })
    local gameA, gameB
    bob.chess:OnChallenge(function(offer) offer:Accept() end)
    bob.chess:OnGame(function(game) gameB = game end)
    alice.chess:Challenge("Bob", { color = "white" }, {
        onGame = function(game) gameA = game end,
    })
    advance({ alice, bob }, 1)
    gameB:OnMove(function(move)
        if move.uci == "e2e5" then move:Reject() else move:Accept() end
    end)
    local rejected
    gameA:Move("e2e5", function(ok, code, message)
        rejected = { ok = ok, code = code, message = message }
    end)
    advance({ alice, bob }, 1)
    assertEq(rejected.ok, false)
    assertEq(rejected.code, "illegal")
    assertEq(rejected.message, "Opponent rejected the move.")
    assertEq(gameA.ply, 0)
    assertEq(gameB.ply, 0)
    local accepted
    gameA:Move("e2e4", function(ok) accepted = ok end)
    advance({ alice, bob }, 1)
    assertEq(accepted, true)
    assertEq(gameA.ply, 1)
    assertEq(gameB.ply, 1)
end)

Test.test("discover lists ping replies and query resolves options", function()
    local alice = newClient({ id = "alice", unit = "Alice", guild = "guild", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({
        id = "bob", unit = "Bob", guild = "guild",
        name = "ChessCraft", version = "2.0.0", options = { "clock", "draw" },
    })
    local carol = newClient({
        id = "carol", unit = "Carol", guild = "guild",
        name = "TavernChess", version = "1.0.4", options = {},
    })
    local seen = 0
    local list
    alice.chess:Discover({
        where = { "guild" },
        wait = 3,
        onPlayer = function(player)
            seen = seen + 1
            assertEq(player:ChessId(), nil)
            assertEq(player:Option("clock"), nil)
        end,
        onDone = function(found) list = found end,
    })
    advance({ alice, bob, carol }, 5)
    assertEq(seen, 2)
    assertEq(#list, 2)
    local byName = {}
    for i = 1, #list do byName[list[i]:DisplayName()] = list[i] end
    assertTrue(byName.Bob ~= nil, "Bob was missing")
    assertTrue(byName.Carol ~= nil, "Carol was missing")
    local queried
    alice.chess:Query(byName.Bob, function(player) queried = player end)
    advance({ alice, bob, carol }, 2)
    assertEq(queried:ChessId().name, "ChessCraft")
    assertEq(queried:ChessId().version, "2.0.0")
    assertEq(queried:Option("clock"), true)
    assertEq(queried:Option("draw"), true)
    assertEq(byName.Carol:Option("clock"), nil)
end)

Test.test("joining a clock lobby without clock fails before the join is sent", function()
    local host = newClient({ id = "host", unit = "Host", name = "ChessCraft", options = { "clock" } })
    local guest = newClient({ id = "guest", unit = "Guest", name = "TavernChess" })
    advance({ host, guest }, 0.5)
    local lobby = host.chess:ListLobby({ title = "10+0", clock = CLOCK })
    assertTrue(lobby ~= nil, "lobby was not listed")
    advance({ host, guest }, 1)
    local listed = guest.chess:Lobbies()
    assertEq(#listed, 1)
    local before = #guest.sends
    local code, message
    local ok = guest.chess:Join(listed[1], {
        onFail = function(gotCode, gotMessage)
            code, message = gotCode, gotMessage
        end,
    })
    local resolvedCode, resolvedMessage
    ok:resolve(nil, function(gotCode, gotMessage)
        resolvedCode, resolvedMessage = gotCode, gotMessage
    end)
    assertEq(code, "unsupported")
    assertEq(message, "This lobby requires clocks.")
    assertEq(resolvedCode, code)
    assertEq(resolvedMessage, message)
    local joins = 0
    for i = before + 1, #guest.sends do
        if kindOf(guest.sends[i].text) == "J" then joins = joins + 1 end
    end
    assertEq(joins, 0)
end)

Test.test("a custom handicap is required like a built-in option", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess" })
    local bob = newClient({ id = "bob", unit = "Bob", name = "WoWChess" })
    alice.chess:Option("handicap", { label = "time handicaps" })
    local opened = false
    bob.chess:OnChallenge(function() opened = true end)
    local code, message
    alice.chess:Challenge("Bob", {
        color = "black",
        handicap = { side = "white", ms = 30000 },
    }, {
        onFail = function(gotCode, gotMessage)
            code, message = gotCode, gotMessage
        end,
    })
    advance({ alice, bob }, 1)
    assertEq(code, "unsupported")
    assertEq(message, "Opponent does not support time handicaps.")
    assertTrue(not opened, "handicap challenge opened the ui")
end)

Test.test("a second registration names the addon that owns the library", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess" })
    local again, err = alice.lib:New({ name = "Other", version = "1" })
    assertEq(again, false)
    assertEq(err, "LibChessMultiplayer is already registered by DeltaChess.")
end)

Test.test("two clock addons start a game from a lobby", function()
    local host = newClient({ id = "host", unit = "Host", name = "ChessCraft", options = { "clock" } })
    local guest = newClient({ id = "guest", unit = "Guest", name = "DeltaChess", options = { "clock" } })
    local hostGame, guestGame
    advance({ host, guest }, 0.5)
    local lobby = host.chess:ListLobby({
        title = "10+0",
        color = "white",
        clock = CLOCK,
        onGame = function(game) hostGame = game end,
    })
    assertTrue(lobby ~= nil, "lobby was not listed")
    advance({ host, guest }, 1)
    local ok = guest.chess:Join(guest.chess:Lobbies()[1], {
        onGame = function(game) guestGame = game end,
    })
    assertTrue(ok)
    advance({ host, guest }, 4)
    assertTrue(hostGame ~= nil, "host game")
    assertTrue(guestGame ~= nil, "guest game")
    assertEq(hostGame.color, "white")
    assertEq(guestGame.color, "black")
    local uci
    guestGame:OnMove(function(move)
        uci = move.uci
        move:Accept()
    end)
    assertTrue(hostGame:Move("e2e4", { hostTime = 9.5, opponentTime = 10 }))
    advance({ host, guest }, 1)
    assertEq(uci, "e2e4")
end)

Test.test("matchmake joins the lobby with the requested clock", function()
    local carol = newClient({ id = "carol", unit = "Carol", name = "TavernChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", options = { "clock" } })
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bobGame, aliceGame, carolGame
    advance({ carol, bob, alice }, 0.5)
    carol.chess:ListLobby({
        color = "white",
        clock = 5,
        onGame = function(game) carolGame = game end,
    })
    bob.chess:ListLobby({
        color = "white",
        clock = CLOCK,
        onGame = function(game) bobGame = game end,
    })
    advance({ carol, bob, alice }, 1)
    alice.chess:Matchmake({
        color = "white",
        filter = { time = { min = 10, max = 10 } },
        onGame = function(game) aliceGame = game end,
    })
    advance({ carol, bob, alice }, 5)
    assertTrue(bobGame ~= nil and aliceGame ~= nil, "matched the wrong lobby")
    assertTrue(carolGame == nil, "joined the other clock")
    assertEq(bobGame.color, "white")
    assertEq(aliceGame.color, "black")
end)

Test.test("matchmake hosts, then yields when a matching lobby appears", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", options = { "clock" } })
    local aliceGame, bobGame
    advance({ alice, bob }, 0.5)
    alice.chess:Matchmake({ clock = CLOCK, onGame = function(game) aliceGame = game end })
    bob.chess:Matchmake({ clock = CLOCK, onGame = function(game) bobGame = game end })
    advance({ alice, bob }, 6)
    assertTrue(aliceGame ~= nil and bobGame ~= nil, "the two hosts never met")
    assertTrue(aliceGame.color ~= bobGame.color, "both kept the same color")
    local hosted = (alice.chess.hosted and 1 or 0) + (bob.chess.hosted and 1 or 0)
    assertEq(hosted, 1)
end)

Test.test("matchmake keeps its own lobby when the clocks differ", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", options = { "clock" } })
    local aliceGame, bobGame
    advance({ alice, bob }, 0.5)
    alice.chess:Matchmake({
        filter = { time = { min = 10, max = 15 } },
        onGame = function(game) aliceGame = game end,
    })
    bob.chess:Matchmake({
        filter = { time = { min = 1, max = 3 } },
        onGame = function(game) bobGame = game end,
    })
    advance({ alice, bob }, 2)
    assertTrue(alice.chess.hosted ~= nil and bob.chess.hosted ~= nil, "a different clock was joined")
    assertTrue(aliceGame == nil and bobGame == nil, "a different clock started a game")
end)

Test.test("a lobby lists elo and titles itself from the clock", function()
    local host = newClient({ id = "host", unit = "Host", name = "ChessCraft", options = { "clock" } })
    local guest = newClient({ id = "guest", unit = "Guest", name = "DeltaChess", options = { "clock" } })
    advance({ host, guest }, 0.5)
    assertEq(host.chess:Elo(), nil)
    assertEq(host.chess:Elo(1520.5), 1520.5)
    assertEq(host.chess:Elo(-1), false)
    assertEq(host.chess:Elo(), 1520.5)
    local lobby = host.chess:ListLobby({
        clock = { hostTime = "10+1", opponentTime = 5 },
    })
    assertTrue(lobby ~= nil, "lobby was not listed")
    assertEq(lobby:Title(), "10+1 vs 5+0")
    advance({ host, guest }, 1)
    local info = guest.chess:Lobbies()[1]:Info()
    assertEq(info.elo, 1520.5)
    assertEq(info.settings.clock.hostTime, 10)
    assertEq(info.settings.clock.hostInc, 1)
    assertEq(info.settings.clock.opponentTime, 5)
    assertEq(info.settings.clock.opponentInc, 0)
    local code
    local bad = guest.chess:Challenge("Host", { clock = "nope" }, {
        onFail = function(got) code = got end,
    })
    bad:resolve(nil, function(got) code = got end)
    assertEq(code, "clock")
    local low = newClient({ id = "low", unit = "Low", name = "TavernChess", options = { "clock" } })
    low.chess:Elo(900)
    advance({ host, guest, low }, 0.5)
    low.chess:ListLobby({ clock = "10+0" })
    advance({ host, guest, low }, 1)
    local matched
    guest.chess:Matchmake({
        filter = {
            time = { min = 5, max = 15 },
            elo = { min = 1400, max = 1600 },
        },
        onGame = function(game) matched = game end,
    })
    advance({ host, guest, low }, 5)
    assertTrue(matched ~= nil, "elo filter skipped the listed lobby")
    assertEq(matched.player:DisplayName(), "Host")
    local floater = newClient({ id = "floater", unit = "Floater", name = "WoWChess", options = { "clock" } })
    advance({ floater }, 0.5)
    assertEq(floater.chess:ListLobby({ clock = 1.5 }):Title(), "1.5+0")
end)

Test.test("elo after a match moves both ratings", function()
    local host = newClient({ id = "host", unit = "Host", name = "DeltaChess" })
    local chess = host.chess
    local white, black, up, down = chess:EloAfter(1500, 1500, "1-0")
    assertEq(white, 1516)
    assertEq(black, 1484)
    assertEq(up, 16)
    assertEq(down, -16)
    assertEq(chess:Elo(), nil)

    local drawnWhite, drawnBlack = chess:EloAfter(1500, 1500, "1/2-1/2")
    assertEq(drawnWhite, 1500)
    assertEq(drawnBlack, 1500)

    local function near(actual, expected)
        assertTrue(type(actual) == "number" and math.abs(actual - expected) < 1e-9, tostring(actual))
    end
    local whiteNew, blackNew, whiteDelta, blackDelta = chess:EloAfter(1400, 1600, "0-1", 32)
    local expectedWhite = 1 / (1 + 10 ^ ((1600 - 1400) / 400))
    near(whiteDelta, 32 * (0 - expectedWhite))
    near(blackDelta, -whiteDelta)
    near(whiteNew, 1400 + whiteDelta)
    near(blackNew, 1600 + blackDelta)
    assertEq(chess:EloAfter(1500, 1500, "resign"), nil)
    assertEq(chess:EloAfter(1500, 1500, "1-0", -1), nil)
end)

Test.test("ToString is the line a list can show", function()
    local alice = newClient({
        id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock", "draw" },
    })
    local bob = newClient({
        id = "bob", unit = "Bob", name = "ChessCraft", options = { "clock", "draw" },
    })
    alice.chess:Elo(1520.5)
    advance({ alice, bob }, 0.5)
    local unnamed = alice.chess:Peer(alice.session:Player("Bob"))
    assertEq(unnamed:ToString(), "Bob")
    local lobby = alice.chess:ListLobby({ clock = "10+0", password = "secret" })
    assertEq(lobby:ToString(), "10+0 · Alice · 1520.5 · 1/2 · Locked")
    advance({ alice, bob }, 1)
    local seen = bob.chess:Lobbies()
    assertEq(#seen, 1)
    assertEq(seen[1]:ToString(), "10+0 · Alice · 1520.5 · 1/2 · Locked")

    local offerText, gameB, drawText
    bob.chess:OnChallenge(function(offer)
        offerText = offer:ToString()
        assertEq(offer.player:ToString(), "Alice · 1520.5 · DeltaChess")
        assertEq(offer.player:ChessId().elo, 1520.5)
        offer:Accept()
    end)
    bob.chess:OnGame(function(game) gameB = game end)
    alice.chess:Challenge("Bob", { color = "white", clock = "10+0" })
    advance({ alice, bob }, 1)
    assertEq(offerText, "Alice · 1520.5 · DeltaChess · plays White · 10+0")
    assertEq(gameB:ToString(), "You play Black · Alice · 1520.5 · DeltaChess · 10+0")
    gameB:OnDrawOffer(function(offer) drawText = offer:ToString() end)
    local gameA = alice.chess.game
    assertEq(gameA:ToString(), "You play White · Bob · ChessCraft · 10+0")
    gameA:OfferDraw()
    advance({ alice, bob }, 1)
    assertEq(drawText, "Alice · 1520.5 · DeltaChess · offers a draw")
    gameA:Resign()
    assertEq(gameA:ToString(), "You play White · Bob · ChessCraft · 10+0 · 0-1")
end)

Test.test("a declined draw is returned to OfferDraw", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "draw" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", options = { "draw" } })
    local gameA, gameB
    bob.chess:OnChallenge(function(offer) offer:Accept() end)
    bob.chess:OnGame(function(game) gameB = game end)
    alice.chess:Challenge("Bob", { color = "white" }, { onGame = function(game) gameA = game end })
    advance({ alice, bob }, 1)
    local declined
    bob.chess.game = gameB
    gameB:OnDrawOffer(function(offer) offer:Decline() end)
    gameA:OfferDraw(function(ok, code, message)
        declined = { ok = ok, code = code, message = message }
    end)
    advance({ alice, bob }, 1)
    assertEq(declined.ok, false)
    assertEq(declined.code, "declined")
    assertEq(declined.message, "Opponent declined the draw.")
    assertTrue(not gameA.over, "a declined draw ended the game")
end)

Test.test("pause is optional and an accepted pause blocks moves until resume", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "pause" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft" })
    local gameA
    bob.chess:OnChallenge(function(offer) offer:Accept() end)
    alice.chess:Challenge("Bob", { color = "white" }, { onGame = function(game) gameA = game end })
    advance({ alice, bob }, 1)
    local code, message
    gameA:OfferPause(function(ok, gotCode, gotMessage)
        code, message = gotCode, gotMessage
    end)
    assertEq(code, "unsupported")
    assertEq(message, "Opponent does not support pause offers.")

    local cara = newClient({ id = "cara", unit = "Cara", name = "DeltaChess", options = { "pause" } })
    local dave = newClient({ id = "dave", unit = "Dave", name = "ChessCraft", options = { "pause" } })
    local white, black
    dave.chess:OnChallenge(function(offer) offer:Accept() end)
    dave.chess:OnGame(function(game) black = game end)
    cara.chess:Challenge("Dave", { color = "white" }, { onGame = function(game) white = game end })
    advance({ cara, dave }, 1)
    local answer = "decline"
    black:OnPauseOffer(function(offer)
        assertEq(offer:ToString(), "Cara · DeltaChess · offers a pause")
        if answer == "decline" then offer:Decline() else offer:Accept() end
    end)
    local flags = {}
    white:OnPause(function(paused) flags.white = paused end)
    black:OnPause(function(paused) flags.black = paused end)
    local declined
    white:OfferPause(function(ok, gotCode, gotMessage)
        declined = { ok = ok, code = gotCode, message = gotMessage }
    end)
    advance({ cara, dave }, 1)
    assertEq(declined.ok, false)
    assertEq(declined.code, "declined")
    assertEq(declined.message, "Opponent declined the pause.")
    assertEq(white.paused, false)

    answer = "accept"
    local accepted
    white:OfferPause(function(ok) accepted = ok end)
    advance({ cara, dave }, 1)
    assertEq(accepted, true)
    assertEq(white.paused, true)
    assertEq(black.paused, true)
    assertEq(flags.white, true)
    assertEq(flags.black, true)
    local moveCode
    white:Move("e2e4", function(ok, got) moveCode = got end)
    assertEq(moveCode, "paused")
    white:Resume()
    advance({ cara, dave }, 1)
    assertEq(white.paused, false)
    assertEq(black.paused, false)
    assertEq(flags.white, false)
    assertEq(flags.black, false)
end)

Test.test("ranked is marked on a challenge, a lobby, and matchmaking", function()
    local alice = newClient({ id = "alice", unit = "Alice", name = "DeltaChess", options = { "clock" } })
    local bob = newClient({ id = "bob", unit = "Bob", name = "ChessCraft", options = { "clock" } })
    local offerRanked, gameA, gameB
    bob.chess:OnChallenge(function(offer)
        offerRanked = offer.ranked
        assertEq(offer:ToString(), "Alice · DeltaChess · plays White · Untimed · Ranked")
        offer:Accept()
    end)
    bob.chess:OnGame(function(game) gameB = game end)
    alice.chess:Challenge("Bob", { color = "white", ranked = true }, {
        onGame = function(game) gameA = game end,
    })
    advance({ alice, bob }, 1)
    assertEq(offerRanked, true)
    assertEq(gameA.ranked, true)
    assertEq(gameB.ranked, true)
    assertEq(gameA:ToString(), "You play White · Bob · ChessCraft · Untimed · Ranked")

    local host = newClient({ id = "host", unit = "Host", name = "DeltaChess", options = { "clock" } })
    local guest = newClient({ id = "guest", unit = "Guest", name = "TavernChess", options = { "clock" } })
    local seeker = newClient({ id = "seeker", unit = "Seeker", name = "ChessCraft", options = { "clock" } })
    advance({ host, guest, seeker }, 0.5)
    local lobby = host.chess:ListLobby({ clock = "10+0", ranked = true })
    assertEq(lobby:Info().ranked, true)
    assertEq(lobby:ToString(), "10+0 · Host · 1/2 · Ranked")
    advance({ host, guest, seeker }, 1)
    local casual
    guest.chess:Matchmake({
        clock = "10+0",
        filter = { time = { min = 5, max = 15 } },
        onGame = function(game) casual = game end,
    })
    advance({ host, guest, seeker }, 3)
    assertEq(casual, nil)
    assertEq(guest.chess:Lobbies()[1]:IsMine() or guest.chess.hosted ~= nil, true)
    local hosted = nil
    local list = guest.chess:Lobbies()
    for i = 1, #list do
        if list[i]:IsMine() then hosted = list[i] end
    end
    assertTrue(hosted ~= nil, "unranked matchmaking did not list a lobby")
    assertEq(hosted:Info().ranked, false)

    local rankedGame
    seeker.chess:Matchmake({
        ranked = true,
        filter = { time = { min = 5, max = 15 } },
        onGame = function(game) rankedGame = game end,
    })
    advance({ host, guest, seeker }, 5)
    assertTrue(rankedGame ~= nil, "ranked matchmaking skipped the ranked lobby")
    assertEq(rankedGame.ranked, true)
    assertEq(rankedGame.player:DisplayName(), "Host")
end)
