--[[
	LeaderboardBoard.server.lua
	Script — ServerScriptService

	Liga o ranking persistido (LeaderboardService) ao placar físico do lobby
	(LeaderboardBoardView). A montagem do quadro mora no módulo de view pra
	também poder ser chamada no Studio em modo Edit.

	Atualiza na hora após cada vitória e num timer, pra pegar vitórias
	registradas em OUTROS servidores — o OrderedDataStore é eventualmente
	consistente entre eles.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local LeaderboardService = require(ServerScriptService.Modules.LeaderboardService)
local LeaderboardBoardView = require(ServerScriptService.Modules.LeaderboardBoardView)

local REFRESH_INTERVAL = 60

LeaderboardBoardView.EnsureBoard()

local function Refresh()
	LeaderboardBoardView.Render(LeaderboardService.GetTop(LeaderboardBoardView.ROW_COUNT))
end

Refresh()
LeaderboardService.Updated:Connect(Refresh)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		Refresh()
	end
end)
