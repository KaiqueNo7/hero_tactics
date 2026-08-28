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

-- ===== TRILHA DA ARENA =====
-- Uma música por região (ver Arenas), e no CLIENTE pelo mesmo motivo dos sons de
-- golpe: SoundService é 2D e sai igual pra todo mundo do servidor, então uma
-- trilha tocada lá poria a Geleira na partida de quem está na Forja. O snapshot
-- já diz em que região a batalha acontece — cada um toca a sua.
--
-- Entra e sai em fade: corte seco no fim da partida soa como bug de áudio, e a
-- entrada por cima do som de início de partida ficava abafada.
local TweenService = game:GetService("TweenService")
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local Arenas = require(ReplicatedStorage.Modules.Arenas)

local MUSIC_FADE = TweenInfo.new(1.2)

-- A trilha própria da região é OPCIONAL: enquanto o Sound com o nome do tema não
-- existir em ReplicatedStorage.Sounds, a arena toca esta. É só criar o
-- MusicGeleira (ou o da região que for) que ele passa a valer sozinho, sem
-- mexer em código.
local DEFAULT_MUSIC = "BattleDefault"

local playingName, playingTrack = nil, nil
local warnedDefault = false

local function stopTrack(track)
	if not track then return end

	local fade = TweenService:Create(track, MUSIC_FADE, { Volume = 0 })
	fade.Completed:Connect(function()
		track:Destroy()
	end)
	fade:Play()
end

local function musicTemplate(arenaId)
	local theme = arenaId and Arenas.ById(arenaId)
	local name = theme and theme.music
	local own = name and Sounds:FindFirstChild(name)
	if own and own:IsA("Sound") then return own end

	local fallback = Sounds:FindFirstChild(DEFAULT_MUSIC)
	if fallback and fallback:IsA("Sound") then return fallback end

	if not warnedDefault then
		warnedDefault = true
		warn(("SoundClient: nao achei '%s' em ReplicatedStorage.Sounds — as partidas ficam sem trilha."):format(DEFAULT_MUSIC))
	end

	return nil
end

local function playArenaMusic(template)

	local track = template:Clone()
	track.Name = "ArenaMusic"
	track.Looped = true
	track.Volume = 0
	track.Parent = SoundService
	track:Play()

	TweenService:Create(track, MUSIC_FADE, { Volume = template.Volume }):Play()
	playingTrack = track
	playingName = template.Name
end

-- Compara a TRILHA, não a arena: enquanto todas caem na padrão, trocar de
-- região não reinicia a música do zero.
MatchUpdate.OnClientEvent:Connect(function(state)
	local arenaId = state.phase ~= "lobby" and state.arena or nil
	local template = arenaId and musicTemplate(arenaId) or nil

	if (template and template.Name or nil) == playingName then return end

	stopTrack(playingTrack)
	playingTrack, playingName = nil, nil

	if template then playArenaMusic(template) end
end)
