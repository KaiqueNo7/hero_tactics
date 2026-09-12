local ServerScriptService = game:GetService("ServerScriptService")

local LightingSetup = require(ServerScriptService.Modules.Arena.LightingSetup)
local SeatBuilder = require(ServerScriptService.Modules.Lobby.SeatBuilder)

LightingSetup.Apply()
SeatBuilder.Build()
