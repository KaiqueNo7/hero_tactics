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

local Sounds = ReplicatedStorage:WaitForChild("Sounds")
local MatchSound = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MatchSound")

-- ===== POOL =====
-- Antes cada som clonava um Sound novo, tocava e mandava pro Debris destruir.
-- Numa troca de golpes saem vários por segundo (batida, espada, passos, morte,
-- skill) e a criação/destruição caía no meio da ação.
--
-- Agora cada nome guarda uns poucos Sounds prontos e a gente reaproveita o
-- primeiro que estiver parado. Vozes simultâneas continuam funcionando — se
-- todos estiverem tocando, um novo é clonado e entra no pool.
--
-- O teto existe pra um som repetido em rajada não inflar o pool sem limite;
-- passando dele, a voz mais antiga é reaproveitada por cima.
local MAX_VOICES_PER_SOUND = 4

local pools = {}

local function acquire(template)
	local pool = pools[template.Name]
	if not pool then
		pool = {}
		pools[template.Name] = pool
	end

	for _, sound in ipairs(pool) do
		if not sound.IsPlaying then return sound end
	end

	if #pool >= MAX_VOICES_PER_SOUND then
		return pool[1]
	end

	local sound = template:Clone()
	sound.Parent = SoundService
	table.insert(pool, sound)
	return sound
end

MatchSound.OnClientEvent:Connect(function(name, volumeScale)
	if type(name) ~= "string" then return end

	local template = Sounds:FindFirstChild(name)
	if not template or not template:IsA("Sound") then return end

	local sound = acquire(template)
	sound.Volume = template.Volume * (tonumber(volumeScale) or 1)
	sound.TimePosition = 0
	sound:Play()
end)
