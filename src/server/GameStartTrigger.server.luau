local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local BoardReady = ReplicatedStorage.Remotes.BoardReady
local PlaceHero = ReplicatedStorage.Remotes.PlaceHero
local GameAction = ReplicatedStorage.Remotes.GameAction

local startZone = Workspace:WaitForChild("StartBotMatch")
local playersInZone = {}

startZone.Touched:Connect(function(hit)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if not player or playersInZone[player] then return end
	playersInZone[player] = true

	if not Workspace:FindFirstChild("Board") then
		BoardSpawner.SpawnBoard()
	end

	BoardReady:FireClient(player, HexGrid.GetHexSize(), HexGrid.GetBoardOffset())
	MatchManager.StartMatch(player)
end)

PlaceHero.OnServerEvent:Connect(function(player, dataId, hexId)
	MatchManager.PlaceHero(player, dataId, hexId)
end)

GameAction.OnServerEvent:Connect(function(player, action, arg1, arg2)
	if action == "move" then
		MatchManager.MoveHero(player, arg1, arg2)
	elseif action == "attack" then
		MatchManager.AttackHero(player, arg1, arg2)
	elseif action == "endTurn" then
		MatchManager.EndTurn(player)
	elseif action == "replay" then
		MatchManager.Replay(player)
	elseif action == "leaveMatch" then
		MatchManager.LeaveMatch(player)
		playersInZone[player] = nil
	end
end)

Players.PlayerRemoving:Connect(function(player)
	playersInZone[player] = nil
end)
