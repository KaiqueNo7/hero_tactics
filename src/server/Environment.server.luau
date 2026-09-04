local ServerScriptService = game:GetService("ServerScriptService")

local LightingSetup = require(ServerScriptService.Modules.LightingSetup)
local SeatBuilder = require(ServerScriptService.Modules.SeatBuilder)

LightingSetup.Apply()
SeatBuilder.Build()
