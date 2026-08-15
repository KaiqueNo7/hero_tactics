--[[
	SoundClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Toca os sons de gameplay que o servidor manda.

	Antes o servidor tocava direto em SoundService, que é 2D e sai igual pra
	todo mundo no servidor. Com partidas simultâneas, o jogador ouviria o golpe,
	a morte e a vitória das arenas vizinhas como se fossem na dele. Agora o
	servidor manda o nome do som só pros jogadores daquela partida e quem toca é
	o cliente — cada um ouve exatamente o próprio jogo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Sounds = ReplicatedStorage:WaitForChild("Sounds")
local MatchSound = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MatchSound")

MatchSound.OnClientEvent:Connect(function(name, volumeScale)
	if type(name) ~= "string" then return end

	local template = Sounds:FindFirstChild(name)
	if not template or not template:IsA("Sound") then return end

	local sound = template:Clone()
	sound.Volume = template.Volume * (tonumber(volumeScale) or 1)
	sound.Parent = SoundService
	sound:Play()

	Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 5) + 0.5)
end)
