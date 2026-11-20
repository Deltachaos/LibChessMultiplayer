local Lib = LibStub and LibStub:GetLibrary("LibChessMultiplayer-1.0", true)
local ns = Lib and Lib._ns
if not ns or ns.sealed then return end

local Chess = ns.Chess
local TEXT = ns.TEXT

local Game = {}
Game.__index = Game
ns.Game = Game

local function clockTimes(payload)
    if type(payload) ~= "table" then return nil end
    if type(payload.hostTime) ~= "number" and type(payload.opponentTime) ~= "number" then return nil end
    return { hostTime = payload.hostTime, opponentTime = payload.opponentTime }
end

function Game:Allows(name)
    return self.options[name] == true
end

function Game:Finish(result, reason)
    if self.over then return end
    self.over = true
    self.result = result
    self.reason = reason
    if self.chess.game == self then self.chess.game = nil end
    local pending = self.drawAnswer
    self.drawAnswer = nil
    if pending and not pending.state then
        if result == "1/2-1/2" and reason == "draw" then
            pending:ok()
        else
            pending:err("draw", "The draw offer is no longer available.")
        end
    end
    local pausePending = self.pauseAnswer
    self.pauseAnswer = nil
    self.pausePly = nil
    if pausePending and not pausePending.state then
        pausePending:err("pause", "The pause offer is no longer available.")
    end
    local resumePending = self.resumeAnswer
    self.resumeAnswer = nil
    self.resumePly = nil
    if resumePending and not resumePending.state then
        resumePending:err("resume", "The resume offer is no longer available.")
    end
    local movePending = self.moveAnswer
    self.moveAnswer = nil
    if movePending and not movePending.state then
        movePending:err("move", "The move is no longer available.")
    end
    if self.onOver then self.onOver(result, reason) end
end

function Game:OnMove(fn)
    self.onMove = fn
end

function Game:OnOver(fn)
    self.onOver = fn
end

function Game:OnDrawOffer(fn)
    self.onDraw = fn
end

function Game:OnPauseOffer(fn)
    self.onPauseOffer = fn
end

function Game:OnResumeOffer(fn)
    self.onResumeOffer = fn
end

function Game:OnPause(fn)
    self.onPause = fn
end

local function hook(promise, callback)
    if type(callback) ~= "function" then return promise end
    promise:resolve(function(...)
        callback(true, ...)
    end, function(...)
        callback(false, ...)
    end)
    return promise
end

function Game:Move(uci, times, onAck)
    if type(times) == "function" then
        onAck, times = times, nil
    end
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if self.paused then return hook(ns.rejected("paused", TEXT.paused), onAck) end
    if not ns.validUci(uci) then return hook(ns.rejected("move", TEXT.move), onAck) end
    if self.moveAnswer and not self.moveAnswer.state then
        return hook(ns.rejected("move", "The previous move is still pending."), onAck)
    end
    local clock
    if times ~= nil then
        if not self:Allows("clock") then
            return hook(ns.rejected("unsupported", ns.unsupportedMessage("opponent", { ns.defaultLabel("clock") })), onAck)
        end
        if type(times) ~= "table" then return hook(ns.rejected("move", TEXT.move), onAck) end
        if type(times.hostTime) ~= "number" or type(times.opponentTime) ~= "number" then
            return hook(ns.rejected("clock", TEXT.clock), onAck)
        end
        if times.hostTime < 0 or times.opponentTime < 0 then
            return hook(ns.rejected("clock", TEXT.clock), onAck)
        end
        clock = { hostTime = times.hostTime, opponentTime = times.opponentTime }
    end
    self.ply = self.ply + 1
    local answer = ns.promise()
    self.moveAnswer = answer
    self.movePly = self.ply
    local payload = { t = "move", id = self.id, ply = self.ply, uci = uci }
    if clock then
        payload.hostTime = clock.hostTime
        payload.opponentTime = clock.opponentTime
    end
    local sent = self.chess:Send(self.player, payload)
    sent:resolve(nil, function(code, message, detail)
        if self.moveAnswer ~= answer or answer.state then return end
        self.moveAnswer = nil
        if self.ply == self.movePly then self.ply = self.ply - 1 end
        answer:err(code, message, detail)
    end)
    return hook(answer, onAck)
end

function Game:Resign(onAck)
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    local result = self.color == "white" and "0-1" or "1-0"
    local promise = self.chess:Send(self.player, { t = "resign", id = self.id })
    self:Finish(result, "resign")
    return hook(promise, onAck)
end

function Game:Over(result, reason, onAck)
    if type(reason) == "function" then
        onAck, reason = reason, nil
    end
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if result ~= "1-0" and result ~= "0-1" and result ~= "1/2-1/2" then
        return hook(ns.rejected("result", "Result must be 1-0, 0-1, or 1/2-1/2."), onAck)
    end
    local promise = self.chess:Send(self.player, {
        t = "result", id = self.id, result = result, reason = reason or "mate",
    })
    self:Finish(result, reason or "mate")
    return hook(promise, onAck)
end

function Game:Flag(color, onAck)
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if self.paused then return hook(ns.rejected("paused", TEXT.paused), onAck) end
    if color ~= "white" and color ~= "black" then
        return hook(ns.rejected("flag", "Color must be white or black."), onAck)
    end
    if not self:Allows("clock") then
        return hook(ns.rejected("unsupported", ns.unsupportedMessage("opponent", { ns.defaultLabel("clock") })), onAck)
    end
    local result = color == "white" and "0-1" or "1-0"
    local promise = self.chess:Send(self.player, { t = "flag", id = self.id, color = color })
    self:Finish(result, "flag")
    return hook(promise, onAck)
end

local OFFER = {
    draw = {
        declined = TEXT["draw-declined"],
        gone = "The draw offer is no longer available.",
        verb = "offers a draw",
        handler = "onDraw",
    },
    pause = {
        declined = TEXT["pause-declined"],
        gone = "The pause offer is no longer available.",
        verb = "offers a pause",
        handler = "onPauseOffer",
    },
    resume = {
        declined = TEXT["resume-declined"],
        gone = "The resume offer is no longer available.",
        verb = "offers to resume",
        handler = "onResumeOffer",
    },
}

local function setPaused(game, paused)
    paused = paused and true or false
    if game.paused == paused then return end
    game.paused = paused
    if game.onPause then game.onPause(game.paused) end
end

local function beginOffer(game, kind, onAck)
    local spec = OFFER[kind]
    if game.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if not game:Allows(kind) then
        return hook(ns.rejected("unsupported", ns.unsupportedMessage("opponent", { ns.defaultLabel(kind) })), onAck)
    end
    local pending = game[kind .. "Answer"]
    if pending and not pending.state then pending:err(kind, spec.gone) end
    game[kind .. "Ply"] = game.ply
    local answer = ns.promise()
    game[kind .. "Answer"] = answer
    local sent = game.chess:Send(game.player, { t = kind, id = game.id, ply = game.ply, answer = "offer" })
    sent:resolve(nil, function(code, message, detail)
        if game[kind .. "Answer"] ~= answer or answer.state then return end
        game[kind .. "Answer"] = nil
        game[kind .. "Ply"] = nil
        answer:err(code, message, detail)
    end)
    return hook(answer, onAck)
end

function Game:OfferDraw(onAck)
    return beginOffer(self, "draw", onAck)
end

function Game:OfferPause(onAck)
    if self.paused then return hook(ns.rejected("paused", TEXT.paused), onAck) end
    return beginOffer(self, "pause", onAck)
end

function Game:Resume(onAck)
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if not self:Allows("pause") then
        return hook(ns.rejected("unsupported", ns.unsupportedMessage("opponent", { ns.defaultLabel("pause") })), onAck)
    end
    if not self.paused then return hook(ns.rejected("pause", "The game is not paused."), onAck) end
    local spec = OFFER.resume
    local pending = self.resumeAnswer
    if pending and not pending.state then pending:err("resume", spec.gone) end
    self.resumePly = self.ply
    local answer = ns.promise()
    self.resumeAnswer = answer
    local sent = self.chess:Send(self.player, { t = "pause", id = self.id, ply = self.ply, answer = "resume" })
    sent:resolve(nil, function(code, message, detail)
        if self.resumeAnswer ~= answer or answer.state then return end
        self.resumeAnswer = nil
        self.resumePly = nil
        answer:err(code, message, detail)
    end)
    return hook(answer, onAck)
end

function Game:ToString()
    local color = ns.colorName(self.color) or "White"
    return ns.joinText({
        "You play " .. color,
        ns.playerText(self.chess, self.player),
        ns.clockTitle(self.clock),
        self.ranked and "Ranked" or nil,
        self.result,
    })
end

function Game:Send(cmd, data, onAck)
    if type(data) == "function" then
        onAck, data = data, nil
    end
    if self.over then return hook(ns.rejected("over", "The game is over."), onAck) end
    if type(cmd) ~= "string" or cmd == "" then
        return hook(ns.rejected("command", "Command name is required."), onAck)
    end
    if not self:Allows(cmd) then
        return hook(ns.rejected("unsupported", ns.unsupportedMessage("opponent", { self.chess:Label(cmd) })), onAck)
    end
    return hook(self.chess:Send(self.player, { t = "ext", id = self.id, cmd = cmd, data = ns.plain(data, 0) }), onAck)
end

function Chess:MakeGame(player, id, color, options, using, isHost, ranked)
    local game = setmetatable({
        id = id,
        player = self:Peer(player),
        color = color,
        yourColor = color,
        opponentColor = ns.opposite(color),
        options = options or {},
        ply = 0,
        over = false,
        paused = false,
        chess = self,
        clock = using and using.clock or nil,
        settings = using,
        isHost = isHost and true or false,
        ranked = ranked == true,
    }, Game)
    return game
end

function Chess:Reject(player, id, code, message, features)
    local payload = self:IdentityPayload({
        t = "decline",
        id = id,
        code = code,
        message = message,
    })
    if features then payload.features = features end
    return self:Send(player, payload)
end

function Chess:FailOutgoing(outgoing, code, message, detail)
    if not outgoing or outgoing.done then return end
    outgoing.done = true
    if self.outgoing == outgoing then self.outgoing = nil end
    ns.report(outgoing.callbacks, code, message, detail)
end

function Chess:Challenge(target, spec, callbacks)
    callbacks = callbacks or {}
    spec = spec or {}
    local promise = ns.promise()
    local wrapped = {
        auto = callbacks.auto,
        timeout = callbacks.timeout,
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
    local player = target
    if type(target) == "string" then player = self.session:Player(target) end
    if type(player) ~= "table" then
        return refuse("no-route", TEXT["no-route"])
    end
    player = self:Peer(player)
    local source = spec
    if spec.clock ~= nil then
        local clock = ns.clock(spec.clock)
        if not clock then return refuse("clock", TEXT.clock) end
        source = {}
        for key, value in pairs(spec) do source[key] = value end
        source.clock = clock
    end
    local using = ns.collect(source, ns.CHALLENGE_RESERVED)
    local names = ns.names(using)
    local missing = self:Missing(self.options, names, self:LabelMap())
    if #missing > 0 then
        local _, labels = self:Missing(self.options, names, self:LabelMap())
        return refuse("unsupported", "This addon does not support " .. ns.joinLabels(labels) .. ".", {
            features = missing,
        })
    end
    local known = self:Identity(player)
    if known then
        if known.protocol ~= ns.PROTOCOL then
            return refuse("incompatible", TEXT.incompatible)
        end
        local peerMissing, peerLabels = self:Missing(known.options, names, self:LabelMap())
        if #peerMissing > 0 then
            return refuse("unsupported", ns.unsupportedMessage("opponent", peerLabels), {
                features = peerMissing,
            })
        end
    end
    if self.outgoing and not self.outgoing.done then
        local previous = self.outgoing
        self:FailOutgoing(previous, "declined", "The challenge was cancelled.")
        self:Send(previous.player, { t = "cancel", id = previous.id })
    end
    local id = ns.newId(self)
    local color = ns.resolveColor(spec.color)
    local ranked = spec.ranked == true
    local outgoing = {
        id = id,
        player = player,
        color = color,
        ranked = ranked,
        using = using,
        callbacks = wrapped,
        done = false,
    }
    self.outgoing = outgoing
    local payload = self:IdentityPayload({
        t = "challenge",
        id = id,
        color = color,
        ranked = ranked,
        using = using,
    })
    if callbacks.auto then payload.auto = true end
    local sent = self:Send(player, payload, function(code, message)
        self:FailOutgoing(outgoing, code, message)
    end)
    if sent.state == "err" then
        outgoing.done = true
        if self.outgoing == outgoing then self.outgoing = nil end
        return promise
    end
    local timeout = callbacks.timeout or ns.CHALLENGE_TIMEOUT
    self.session:After(timeout, function()
        if outgoing.done then return end
        self:FailOutgoing(outgoing, "timeout", TEXT.timeout)
        self:Send(player, { t = "cancel", id = id })
    end)
    local chess = self
    function promise:Cancel()
        if outgoing.done then return false end
        chess:FailOutgoing(outgoing, "declined", "The challenge was cancelled.")
        chess:Send(player, { t = "cancel", id = id })
        return true
    end
    return promise
end

function Chess:Accept(offer, extra)
    extra = extra or {}
    if not offer or offer.done then
        return ns.rejected("declined", "The challenge is no longer available.")
    end
    local promise = ns.promise()
    offer.done = true
    if self.incoming and self.incoming.id == offer.id then self.incoming = nil end
    local payload = self:IdentityPayload({ t = "accept", id = offer.id })
    local sent = self:Send(offer.player, payload, function(code, message)
        promise:err(code, message)
        ns.report(extra, code, message)
    end)
    if sent.state == "err" then return promise end
    local userOnGame = extra.onGame
    local peerOptions = ns.toSet(offer.peerOptions)
    self.pendingStart = {
        id = offer.id,
        player = offer.player,
        color = offer.yourColor,
        options = ns.intersect(self.options, peerOptions),
        using = offer.using,
        ranked = offer.ranked == true,
        onGame = function(game)
            promise:ok(game)
            if userOnGame then userOnGame(game) end
        end,
    }
    return promise
end

function Chess:Offer(player, payload)
    local using = type(payload.using) == "table" and payload.using or {}
    local offer = {
        id = payload.id,
        player = self:Peer(player),
        name = payload.name,
        version = payload.version,
        color = payload.color,
        yourColor = ns.opposite(payload.color),
        ranked = payload.ranked == true,
        using = using,
        peerOptions = payload.options,
        done = false,
        chess = self,
    }
    for key, value in pairs(using) do offer[key] = value end
    function offer:Accept(extra)
        return offer.chess:Accept(offer, extra)
    end
    function offer:Decline()
        if offer.done then return ns.rejected("declined", TEXT.declined) end
        offer.done = true
        if offer.chess.incoming and offer.chess.incoming.id == offer.id then
            offer.chess.incoming = nil
        end
        return offer.chess:Reject(offer.player, offer.id, "declined", TEXT.declined)
    end
    function offer:ToString()
        local color = ns.colorName(offer.color) or "White"
        return ns.joinText({
            ns.playerText(offer.chess, offer.player),
            "plays " .. color,
            ns.clockTitle(offer.clock),
            offer.ranked and "Ranked" or nil,
        })
    end
    return offer
end

local function onChallenge(chess, player, payload)
    chess:Remember(player, payload)
    local id = payload.id
    if chess.busy or chess.game or (chess.incoming and not chess.incoming.done) then
        chess:Reject(player, id, "busy", TEXT.busy)
        return
    end
    local using = type(payload.using) == "table" and payload.using or {}
    local missing, labels = chess:Missing(chess.options, ns.names(using), payload.labels)
    if #missing > 0 then
        chess:Reject(player, id, "unsupported", ns.unsupportedMessage("opponent", labels), missing)
        return
    end
    local offer = chess:Offer(player, payload)
    chess.incoming = offer
    if payload.auto and chess.joining then
        local onGame = chess.joining.callbacks and chess.joining.callbacks.onGame or nil
        offer:Accept({ onGame = onGame })
        return
    end
    if not chess.onChallenge then
        offer:Decline()
        return
    end
    chess.onChallenge(offer)
end

local function onAccept(chess, player, payload)
    chess:Remember(player, payload)
    local outgoing = chess.outgoing
    if not outgoing or outgoing.done or outgoing.id ~= payload.id then return end
    if not player:Same(outgoing.player) and chess:Key(player) ~= chess:Key(outgoing.player) then return end
    outgoing.done = true
    chess.outgoing = nil
    local options = ns.intersect(chess.options, ns.toSet(payload.options))
    local game = chess:MakeGame(player, outgoing.id, outgoing.color, options, outgoing.using, true, outgoing.ranked)
    chess:Send(player, { t = "ucinewgame", id = outgoing.id })
    chess:Begin(game, outgoing.callbacks.onGame)
end

local function onDecline(chess, player, payload)
    chess:Remember(player, payload)
    local outgoing = chess.outgoing
    if not outgoing or outgoing.done or outgoing.id ~= payload.id then return end
    local detail = nil
    if type(payload.features) == "table" then detail = { features = payload.features } end
    chess:FailOutgoing(outgoing, payload.code or "declined", payload.message or TEXT.declined, detail)
end

local function onCancel(chess, player, payload)
    local incoming = chess.incoming
    if not incoming or incoming.done or incoming.id ~= payload.id then return end
    incoming.done = true
    incoming.cancelled = true
    chess.incoming = nil
end

local function onUciNewGame(chess, player, payload)
    local pending = chess.pendingStart
    if not pending or pending.id ~= payload.id then return end
    if chess.game and chess.game.id == payload.id then return end
    local game = chess:MakeGame(player, pending.id, pending.color, pending.options, pending.using, false, pending.ranked)
    local onGame = pending.onGame
    chess.pendingStart = nil
    chess:Begin(game, onGame)
end

local function live(chess, payload)
    local game = chess.game
    if not game or game.over or game.id ~= payload.id then return nil end
    return game
end

local function onMove(chess, player, payload)
    local game = live(chess, payload)
    if not game then return end
    if payload.answer == "accept" or payload.answer == "reject" then
        local pending = game.moveAnswer
        if not pending or pending.state or payload.ply ~= game.movePly then return end
        game.moveAnswer = nil
        if payload.answer == "reject" then
            if game.ply == game.movePly then game.ply = game.ply - 1 end
            pending:err("illegal", TEXT.illegal)
        else
            pending:ok()
        end
        return
    end
    local function reject()
        game.chess:Send(player, {
            t = "move", id = game.id, ply = payload.ply, uci = payload.uci, answer = "reject",
        })
    end
    if not ns.validUci(payload.uci) or payload.ply ~= game.ply + 1 then
        reject()
        return
    end
    local move = {
        uci = payload.uci,
        ply = payload.ply,
        times = clockTimes(payload),
    }
    local settled = false
    function move:Accept()
        if settled or game.over or game.ply + 1 ~= move.ply then
            return ns.rejected("move", "The move is no longer available.")
        end
        settled = true
        game.ply = move.ply
        return game.chess:Send(player, {
            t = "move", id = game.id, ply = move.ply, uci = move.uci, answer = "accept",
        })
    end
    function move:Reject()
        if settled or game.over then return ns.rejected("illegal", TEXT.illegal) end
        settled = true
        return game.chess:Send(player, {
            t = "move", id = game.id, ply = move.ply, uci = move.uci, answer = "reject",
        })
    end
    function move:ToString()
        return move.uci
    end
    if game.onMove then game.onMove(move) else move:Accept() end
end

local function onResign(chess, _, payload)
    local game = live(chess, payload)
    if not game then return end
    local result = game.color == "white" and "1-0" or "0-1"
    game:Finish(result, "resign")
end

local function onResult(chess, _, payload)
    local game = live(chess, payload)
    if not game then return end
    game:Finish(payload.result, payload.reason or "mate")
end

local function onFlag(chess, _, payload)
    local game = live(chess, payload)
    if not game or not game:Allows("clock") then return end
    local result = payload.color == "white" and "0-1" or "1-0"
    game:Finish(result, "flag")
end

local function onOffer(game, player, payload, kind)
    local spec = OFFER[kind]
    local ply = payload.ply
    local resuming = kind == "pause" and payload.answer == "resume"
    if resuming then spec = OFFER.resume end
    if payload.answer == "offer" or resuming then
        local offer = {}
        function offer:Accept()
            if game.over or game.ply ~= ply then
                return ns.rejected(resuming and "resume" or kind, spec.gone)
            end
            local promise = game.chess:Send(player, { t = kind, id = game.id, ply = ply, answer = "accept" })
            if resuming then
                setPaused(game, false)
            elseif kind == "draw" then
                game:Finish("1/2-1/2", "draw")
            else
                setPaused(game, true)
            end
            return promise
        end
        function offer:Decline()
            if game.over or game.ply ~= ply then
                return ns.rejected(resuming and "resume" or kind, spec.gone)
            end
            return game.chess:Send(player, { t = kind, id = game.id, ply = ply, answer = "decline" })
        end
        function offer:ToString()
            return ns.joinText({ ns.playerText(game.chess, player), spec.verb })
        end
        local handler = game[spec.handler]
        if handler then handler(offer) else offer:Decline() end
    elseif payload.answer == "accept" then
        if kind == "pause" and game.resumeAnswer and not game.resumeAnswer.state and (ply == game.ply or ply == game.resumePly) then
            setPaused(game, false)
            local pending = game.resumeAnswer
            game.resumeAnswer = nil
            game.resumePly = nil
            if pending and not pending.state then pending:ok() end
        elseif ply == game.ply or ply == game[kind .. "Ply"] then
            if kind == "draw" then
                game:Finish("1/2-1/2", "draw")
            else
                setPaused(game, true)
                local pending = game.pauseAnswer
                game.pauseAnswer = nil
                game.pausePly = nil
                if pending and not pending.state then pending:ok() end
            end
        end
    elseif payload.answer == "decline" then
        local key, plyKey = kind .. "Answer", kind .. "Ply"
        if kind == "pause" and game.resumeAnswer and not game.resumeAnswer.state then
            key, plyKey, spec = "resumeAnswer", "resumePly", OFFER.resume
        end
        local pending = game[key]
        if pending and not pending.state and (ply == game[plyKey] or ply == nil) then
            game[key] = nil
            game[plyKey] = nil
            pending:err("declined", spec.declined)
        end
    end
end

local function onDraw(chess, player, payload)
    local game = live(chess, payload)
    if not game or not game:Allows("draw") then return end
    onOffer(game, player, payload, "draw")
end

local function onPause(chess, player, payload)
    local game = live(chess, payload)
    if not game or not game:Allows("pause") then return end
    onOffer(game, player, payload, "pause")
end

local function onExt(chess, player, payload)
    local game = live(chess, payload)
    if not game or type(payload.cmd) ~= "string" or not game:Allows(payload.cmd) then return end
    local fn = chess.commands[payload.cmd]
    if fn then fn(player, game, payload.data) end
end

ns.on("challenge", onChallenge)
ns.on("accept", onAccept)
ns.on("decline", onDecline)
ns.on("cancel", onCancel)
ns.on("ucinewgame", onUciNewGame)
ns.on("move", onMove)
ns.on("resign", onResign)
ns.on("result", onResult)
ns.on("flag", onFlag)
ns.on("draw", onDraw)
ns.on("pause", onPause)
ns.on("ext", onExt)
