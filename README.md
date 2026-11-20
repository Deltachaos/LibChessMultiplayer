# LibChessMultiplayer

LibChessMultiplayer lets two chess addons play each other. It sits on [LibMultiplayer](https://github.com/Deltachaos/LibMultiplayer) and speaks one shared prefix, `ChessMP`. The opponent does not need the same addon. They need this library.

```
## Dependencies: LibMultiplayer, LibChessMultiplayer
```

Games start from the standard position. Moves are UCI long algebraic (`e2e4`, `e7e8q`). A clock is minutes, or minutes plus an increment in seconds. `10` and `"10+0"` are ten minutes. `"10+1"` adds one second per move. `1.5` is one minute and thirty seconds. A challenge or lobby with no `clock` is untimed. The library protocol is `1`.

```lua
local chess = LibStub("LibChessMultiplayer-1.0"):New({
    name = "DeltaChess",
    version = "1.0.0",
    options = { "clock", "draw" },
})

chess:OnChallenge(function(offer)
    offer:Accept()
end)

local pending = chess:Challenge("Thrall", {
    color = "white",
    clock = "10+0",
}, {
    onGame = function(game) end,
    onFail = function(code, message, detail) end,
})

pending:resolve(function(game)
    game:Move("e2e4", { hostTime = 9.5, opponentTime = 10 })
end, function(code, message, detail) end)
```

## Promises

Every send returns a promise. LibMultiplayer acknowledges delivery, so the call returns before the opponent has the message.

`promise:resolve(onOk, onErr)` waits for the real reply. `onOk` receives that reply. `onErr` receives `code`, `message`, and sometimes `detail`. Either function can be left out. If the promise has already settled, the matching function runs immediately. `resolve` returns the promise.

From a coroutine, `local ok, ... = promise:resolve()` yields until the reply. `ok` is `true` and the remaining values are the reply, or `ok` is `false` and the remaining values are `code`, `message`, `detail`.

A trailing callback on a game command is the same wait in one function. It is called as `callback(true, ...)` or `callback(false, code, message, detail)`.

`Challenge`, `Join`, and `offer:Accept()` resolve with the `game`. `Query` resolves with the `player`. `Discover` resolves with the list of players. `Resign`, `Over`, `Flag`, `Send`, `offer:Decline()`, and a draw or pause offer's `Accept` or `Decline` resolve when the opponent acknowledges the message, with no extra success values. `OfferDraw` and `OfferPause` wait for the answer. Each resolves when the opponent accepts, and rejects with `declined` when the opponent declines. `Move` waits until the opponent accepts or rejects the move.

An immediate failure rejects the promise before the call returns. Where the call also takes `onFail`, that function runs as well.

`pending:Cancel()` withdraws a challenge that has not been answered. It rejects the promise with `declined` and `"The challenge was cancelled."` `Cancel` on any other promise returns `false`.

## Registration

```lua
local chess, err = LibStub("LibChessMultiplayer-1.0"):New({
    name = "DeltaChess",   -- required
    version = "1.0.0",     -- defaults to "0"
    options = { "clock", "draw" },
})
```

`New` works once per client. A second addon gets `false` and `"LibChessMultiplayer is already registered by DeltaChess."` `name` must be a non-empty string, or `New` errors. The library also errors when LibMultiplayer is not loaded.

`chess.session` is the shared LibMultiplayer session. `chess.name` and `chess.version` are the values passed to `New`. `chess.game` is the current game, or `nil`.

```lua
chess:Id()
-- { name = "DeltaChess", version = "1.0.0", protocol = 1, options = { "clock", "draw" } }

chess:SupportedList()  -- { "clock", "draw" }, sorted
chess:Label("clock")   -- "clocks"
chess:Label("handicap")
```

`Label` uses the label registered with `Option`, otherwise `"clocks"` for `clock`, `"draw offers"` for `draw`, `"pause offers"` for `pause`, and the option name for anything else.

## Options

`options` lists the optional features this addon implements. Required play is always present and is not an option: identity, challenge, accept, decline, cancel, game start, move, resign, and result.

A field on a challenge or lobby other than the reserved ones below is a required option. The recipient must support every feature the challenge uses. `OnChallenge` is not called on a mismatch. Extra features on the recipient do not matter. A clock challenge to an addon that also supports draw offers succeeds.

After the game starts, the legal options are the intersection of both advertised lists. `game:OfferDraw()` from an addon that supports draw, against one that does not, rejects with `unsupported` and `"Opponent does not support draw offers."` `game:OfferPause()` does the same for `pause` and `"pause offers"`. The game stays up.

```lua
chess:Option("clock")                         -- true or false, local check
chess:Option("handicap", { label = "time handicaps" })  -- register, returns true
chess:Option("", {})                          -- false

chess:OnCommand("handicap", function(player, game, data) end)
```

`OnCommand` registers the option when it is missing, then stores the handler. The handler runs for `game:Send("handicap", data)` when both sides advertised `handicap`. `player` is the sender.

`chess:Busy()` returns whether new challenges are refused. `chess:Busy(true)` refuses them. `chess:Busy(false)` accepts them again. An ongoing game is left alone. While busy, an incoming challenge is declined with `busy`.

## Players

Players are LibMultiplayer players. After this library has seen an `id`, it adds two methods.

```lua
player:Option("clock")  -- true, false, or nil when no id has arrived
player:ChessId()        -- nil, or { name, version, protocol, options, elo }
player:ToString()       -- "Thrall", or "Thrall · 1520 · DeltaChess" after the id arrives
```

`ChessId().options` is a sorted array of option names. `elo` is present when that player has set a rating. `chess:Identity(player)` is the cached record, or `nil`. Its `options` field is a set (`options.clock == true`) and it also keeps `labels`. `ToString` is the line to put in a list or a button. It uses the display name, then the rating and addon name once `Query` has filled the id. The rating is part of that id.

```lua
local pending = chess:Query("Thrall", function(player) end)
pending:resolve(function(player) end, function(code, message) end)
```

`Query` accepts a name or a player. When the id is already cached it resolves immediately and calls the callback before returning. Otherwise it asks the player. The promise resolves with the player. A failed send rejects the promise. The callback is only called on success.

## Challenges

```lua
local pending = chess:Challenge("Thrall", {
    color = "white", -- "white", "black", or "random"; anything else is white
    clock = "10+0", -- or 10, "10+1", 1.5, or { hostTime = "10+1", opponentTime = 5 }
    ranked = true, -- rated game; omit or false for unranked
    handicap = { side = "white", ms = 30000 },
}, {
    onGame = function(game) end,
    onFail = function(code, message, detail) end,
    timeout = 30, -- seconds, default 30
})

pending:resolve(function(game) end, function(code, message, detail) end)
pending:Cancel()
```

`color` is the challenger's color. `"random"` is resolved by the challenger before the message is sent. `ranked = true` marks a rated game. Omit it, or pass `false`, for an unrated game. `clock` and `handicap` are required options: the sender must have registered them, and so must the recipient. `detail.features` lists the missing option ids. `ranked` is not an option.

The clock is stored as minutes and increment seconds for each side:

```lua
offer.clock.hostTime       -- minutes
offer.clock.hostInc        -- seconds
offer.clock.opponentTime
offer.clock.opponentInc
```

`10`, `1.5`, and `"10+1"` set both sides. `"10+1"` is ten minutes plus one second. A float is a fraction of a minute, so `1.5` is ninety seconds and `"1.5+2"` is ninety seconds plus two seconds of increment. Different sides use `hostTime` and `opponentTime`. The host is the challenger, or the player who listed the lobby. `game.isHost` is true on that side. On a move, `hostTime` and `opponentTime` are the remaining minutes for those same sides.

`onGame` and the promise both receive the game when the opponent accepts. `onFail` and the promise both hear a refusal, a timeout, or a send failure. Only one challenge is outgoing. Starting another one cancels the previous one with `declined` and `"The challenge was cancelled."`

`chess:OnChallenge(function(offer) end)` handles an incoming challenge. The offer is not created when the challenge uses an option this addon did not register, when the library protocols differ, or when this addon is busy or already in a game. With no handler, the challenge is declined.

```lua
offer.name            -- challenger's addon name
offer.version
offer.color           -- challenger's color
offer.yourColor       -- the opposite color
offer.player          -- challenger
offer.clock           -- present when the challenge used a clock
offer.ranked          -- true when the challenge was ranked
offer.using           -- the option fields, such as clock and handicap
offer.peerOptions     -- challenger's advertised option names
offer:ToString()      -- "Thrall · 1520 · DeltaChess · plays White · 10+0 · Ranked"

offer:Accept({
    onGame = function(game) end,
    onFail = function(code, message) end,
})
offer:Decline()
```

`Accept` returns a promise that resolves with the game when play starts. `Decline` returns a promise that resolves when the decline is acknowledged. Accepting an offer that was already answered rejects with `declined` and `"The challenge is no longer available."` Declining one rejects with `declined` and `"Opponent declined the challenge."`

`chess:OnGame(function(game) end)` runs for both sides when the game starts, before the `onGame` callback passed to `Challenge`, `Accept`, or `Join`.

## Games

```lua
game.id
game.player            -- the opponent
game.color             -- color played by this addon
game.yourColor         -- same as color
game.opponentColor
game.ply               -- starts at 0
game.over              -- true after the game ends
game.paused            -- true after a pause offer is accepted
game.clock             -- normalized clock, or nil
game.isHost            -- true for the challenger or lobby host
game.ranked            -- true when the challenge, lobby, or match was ranked
game.settings          -- option fields from the challenge
game:Allows("clock")   -- true only when both sides advertised it
game:ToString()        -- "You play Black · Thrall · 1520 · DeltaChess · 10+0 · Ranked"
```

```lua
game:OnMove(function(move) end)
game:OnOver(function(result, reason) end)
game:OnDrawOffer(function(offer) end)
game:OnPauseOffer(function(offer) end)
game:OnPause(function(paused) end)
```

`move.uci` is the UCI move. `move.ply` is the ply it would become. `move.times` is `{ hostTime = ..., opponentTime = ... }` in remaining minutes when the move carried a clock, otherwise `nil`. `move:ToString()` is the UCI move. `result` is `"1-0"`, `"0-1"`, or `"1/2-1/2"`. `reason` is `"resign"`, `"mate"`, `"flag"`, `"draw"`, or the reason passed to `Over`. After the game ends, `ToString` appends that result. `game.result` and `game.reason` hold the same values.

```lua
game:Move("e2e4", function(ok, code, message)
    -- opponent rejected it: ok == false, code == "illegal"
end)
game:Move("e7e8q", { hostTime = 9.5, opponentTime = 10 }, function(ok, code, message) end)

game:Resign(function(ok) end)
game:Over("1-0", "mate", function(ok) end)
game:Over("1/2-1/2", function(ok) end)   -- reason defaults to "mate"
game:Flag("white", function(ok) end)     -- the side that ran out of time

game:OfferDraw(function(ok, code, message)
    -- opponent declined: ok == false, code == "declined"
end)
game:OfferPause(function(ok, code, message)
    -- opponent declined: ok == false, code == "declined"
end)
game:Resume(function(ok) end)
game:Send("handicap", { side = "white", ms = 30000 }, function(ok) end)
game:Send("handicap", function(ok) end)  -- data is nil
```

`Move` requires a UCI move. The sender's ply advances when the move is sent. The promise and the callback stay open until the opponent accepts or rejects it. `OnMove` receives the move. Call `move:Accept()` to play it, or `move:Reject()` when the engine treats it as illegal. A rejection calls the sender's callback as `false, "illegal", "Opponent rejected the move."`, puts the sender's ply back, and leaves the receiver's ply unchanged. With no `OnMove` handler, the move is accepted. Passing `times` requires `clock` on both sides. `hostTime` and `opponentTime` are the remaining minutes. `Flag` requires `clock` and a color of `"white"` or `"black"`. White losing on time produces `"0-1"`. Black losing on time produces `"1-0"`. `Resign` sends `"0-1"` when this side is white and `"1-0"` when this side is black, with reason `"resign"`.

```lua
game:OnMove(function(move)
    move.uci
    move.ply
    move.times
    move:ToString()   -- "e2e4"
    move:Accept()
    move:Reject()
end)
```

`Over` announces a finished position. `result` must be `"1-0"`, `"0-1"`, or `"1/2-1/2"`. These three end the local game immediately, then the promise waits for the acknowledgement.

`OfferDraw` is legal only when both sides advertised `draw`. `OfferPause` is legal only when both sides advertised `pause`. Register either in `options` or with `chess:Option`. An offer is tied to the current ply. The promise and the callback stay open until the opponent answers. A decline calls the callback as `false, "declined", "Opponent declined the draw."` or `"Opponent declined the pause."` and rejects the promise the same way. The game stays in progress. An accepted draw resolves the promise, ends the game, and `OnOver` runs with `"1/2-1/2"` and `"draw"`. An accepted pause resolves the promise, sets `game.paused`, and runs `OnPause(true)` on both sides. `Move` and `Flag` then reject with `paused` and `"The game is paused."` `Resume` clears the pause locally and tells the opponent, and `OnPause(false)` runs on both sides. `OnDrawOffer` and `OnPauseOffer` run only for an offer you receive. With no handler, that offer is declined.

```lua
offer:Accept()    -- draw ends 1/2-1/2; pause sets game.paused
offer:Decline()
offer:ToString()  -- "Thrall · 1520 · DeltaChess · offers a draw"
                  -- "Thrall · 1520 · DeltaChess · offers a pause"
```

Both return a promise that resolves on acknowledgement. An offer for a ply that is no longer current rejects with `"The draw offer is no longer available."` or `"The pause offer is no longer available."`

`Send` delivers an addon command. Both sides must have advertised that command name. `OnCommand` on the opponent receives `player`, `game`, and `data`.

`game:Finish(result, reason)` marks the local game over and runs `OnOver`. It does not send. The library uses it when a result arrives from the opponent.

## Discover

Discover is optional. It uses LibMultiplayer's ping and does not ask for chess options. Peers answer even when they never call `Discover`. `Query` loads a player's addon, version, and options once that player is selected.

```lua
local pending = chess:Discover({
    where = "all",              -- or { "guild", "group", "friends", "battlenet", "channel" }
    wait = 3,                   -- seconds for the ping
    onPlayer = function(player) end,
    onDone = function(list) end,
})

pending:resolve(function(list)
    chess:Query(list[1], function(player)
        player:Option("clock")
        player:ChessId()
    end)
end, function(code, message) end)
```

`onPlayer` runs for each pong. `Option` and `ChessId` are `nil` until `Query`. `onDone` receives the list. On a trial account it receives `{}` and `"trial"`, and the promise rejects with `trial`. The promise resolves with the same list.

## Lobbies

Lobbies are optional. `ListLobby` stores the addon name, version, protocol, required options, labels, color, settings, and Elo in the lobby info. Capacity defaults to 2. With no title, the title is the clock, such as `10+0`, `10+1 vs 5+0`, or `Untimed`.

```lua
chess:Elo(1520)          -- set your rating; chess:Elo() reads it
chess:Elo(-1)            -- false, the stored rating is unchanged

-- "1-0", "0-1", and "1/2-1/2" are White's result. K defaults to 32.
local whiteNew, blackNew, whiteDelta, blackDelta = chess:EloAfter(1520, 1480, "1-0")
chess:Elo(whiteNew)
```

`EloAfter` only computes. It leaves the stored rating as it is. Ratings stay unrounded. A bad rating, result, or a negative K returns `nil`.

```lua
local lobby = chess:ListLobby({
    capacity = 2,
    password = "secret",   -- optional, never advertised
    spectators = 0,
    color = "white",       -- host color; "white", "black", or "random"
    ranked = true,         -- rated lobby; omit or false for unranked
    clock = "10+0",        -- omitted title becomes "10+0"
    onGame = function(game) end,
    onFail = function(code, message, detail) end,
})

chess:Lobbies()            -- LibMultiplayer lobby list
lobby:Info()               -- info.elo is 1520 when Elo was set
```

`color`, `title`, `capacity`, `password`, `spectators`, `ranked`, `onGame`, `onFail`, `matchmake`, and `filter` are lobby fields. Any other field, such as `clock`, is a required option. `ListLobby` returns `nil` when this addon did not register one of those options, or when the clock cannot be read. Calling it again while hosting returns the same lobby.

`Info()` includes `name`, `version`, `protocol`, `options`, `labels`, `color`, `ranked`, `settings`, `elo`, and `matchmake`. `info.ranked` is true only for a ranked lobby. `lobby:ToString()` is the list line, such as `10+0 · Thrall · 1520 · 1/2 · Ranked`. A locked lobby includes `Locked`. An unranked lobby leaves `Ranked` off the line. The other lobby methods (`Id`, `Host`, `Members`, `Count`, `Capacity`, `Title`, `IsMine`) come from LibMultiplayer. `chess:Lobbies()` and `ListLobby` add `ToString` to each lobby they return.

```lua
local pending = chess:Join(chess:Lobbies()[1], {
    password = "secret",   -- when the lobby is locked
    onGame = function(game) end,
    onFail = function(code, message, detail) end,
})

pending:resolve(function(game) end, function(code, message, detail) end)
```

`Join` checks the advertised protocol and options locally before LibMultiplayer sends the join. A guest without clocks gets `unsupported` and `"This lobby requires clocks."`, and nothing is sent. `detail.features` lists the missing ids.

When the guest is seated, the host checks the guest's id again. On a mismatch the guest is removed and `onFail` runs. When the check passes, the host starts the game with the lobby color and settings, and the guest accepts it without `OnChallenge`.

```lua
local pending = chess:Matchmake({
    color = "white",
    ranked = true, -- join and list only ranked lobbies; omit for unranked
    filter = {
        time = { min = 5, max = 15 }, -- minutes, both sides
        inc = { min = 0, max = 2 },   -- seconds, optional
        elo = { min = 1400, max = 1800 }, -- host rating, optional
    },
    onGame = function(game) end,
    onFail = function(code, message, detail) end,
})

pending:resolve(function(game) end, function(code, message, detail) end)
pending:Cancel()
```

`Matchmake` joins an open lobby that fits `filter`, has the same `ranked` flag, and whose required options you support. `ranked = true` joins only ranked lobbies and, when nothing matches, lists a ranked lobby. Omit `ranked` to stay unranked. `time` and `inc` apply to both `hostTime` and `opponentTime`. A lobby with no clock does not fit a time filter. A lobby with no Elo does not fit an Elo filter. Among several matches, a clock nearer the middle of the time range wins, then fewer extra settings, then more players, then the lowest lobby id. A locked lobby is skipped unless you pass its password. A full lobby is skipped.

If nothing matches, `Matchmake` lists your lobby and keeps watching. The listed clock is the `clock` you passed, or the low end of the filter when you only passed a range. LibMultiplayer's `OnLobby` reports a lobby the first time it is seen. When a matching lobby appears while you are still the only player, you delist and join it. Two matchmaking lobbies do not both leave: the higher lobby id joins the lower one. A lobby that was listed directly, not by matchmaking, is joined by whoever is waiting. `pending` resolves with the game either way. `Cancel` delists a matchmade lobby and leaves a join that has not started.

## Errors

`onFail(code, message, detail)` and `promise:resolve`'s failure function are the places to show an error. `detail.features` is the list of missing option ids when the code is `unsupported`.

| Code | Message |
| --- | --- |
| `unsupported` | `Opponent does not support clocks.` or `This lobby requires clocks.` A custom option uses its label, such as `time handicaps`. A missing local option says `This addon does not support clocks.` |
| `incompatible` | `Opponent's chess multiplayer is not compatible.` |
| `busy` | `Opponent is already in a game.` Locally, `You are already in a game.` or `You are not accepting challenges.` |
| `declined` | `Opponent declined the challenge.` A rejected draw says `Opponent declined the draw.` A rejected pause says `Opponent declined the pause.` Cancelling says `The challenge was cancelled.` An offer that is already gone says `The challenge is no longer available.` |
| `paused` | `The game is paused.` |
| `timeout` | `Opponent did not answer.` Also used when a send is not acknowledged in time. |
| `offline` | `Opponent is offline.` |
| `no-route` | `Opponent could not be reached.` |
| `trial` | `Trial accounts cannot send addon messages.` |
| `serialize` | `The message could not be sent.` |
| `password` | `The lobby password was not accepted.` |
| `full` | `The lobby is full.` |
| `spectators` | `The lobby has no spectator seats.` |
| `clock` | `Clock must be minutes, or minutes+seconds such as 10 or "10+1".` |
| `move` | `Move must be UCI long algebraic.` A second move while the first is unanswered says `The previous move is still pending.` |
| `illegal` | `Opponent rejected the move.` |
| `over` | `The game is over.` |
| `result` | `Result must be 1-0, 0-1, or 1/2-1/2.` |
| `flag` | `Color must be white or black.` |
| `command` | `Command name is required.` |
| `draw` | `The draw offer is no longer available.` |

Challenges time out after 30 seconds unless `timeout` says otherwise.

## Low-level send

`chess:Send(player, payload, onFail)` sets `payload.v` to the library protocol and sends it through LibMultiplayer. The promise resolves on acknowledgement and rejects on `offline`, `no-route`, `trial`, `serialize`, or `timeout`. `onFail(code, message)` is the failure function. Game commands, challenges, and queries are easier through the methods above. `Send` is for a payload this library does not already build.

## Tests

```
lua5.1 ../LibUnitWow/run.lua
```

The suite is `Test.suite("LibChessMultiplayer", "protocol")`.
