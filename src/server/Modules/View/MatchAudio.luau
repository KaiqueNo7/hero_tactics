local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sounds = ReplicatedStorage:WaitForChild("Sounds")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local MatchAudio = {}

-- Sons de gameplay tocam em 2D, não presos ao Part do herói: a câmera fica
-- travada a ~90 studs do tabuleiro, e som 3D com EmitterSize padrão (10) cairia
-- pra ~10% do volume nessa distância.
--
-- Mas 2D no servidor toca pra TODO MUNDO. Com partidas simultâneas, o jogador
-- ouviria o golpe da arena vizinha como se fosse na dele. Então o servidor não
-- toca nada: manda o nome do som pelos clientes daquela partida, e cada um toca
-- localmente (SoundClient). `view.players` é a plateia — em partida contra bot,
-- é uma pessoa só.
local MatchSound = Remotes:FindFirstChild("MatchSound")
if not MatchSound then
	MatchSound = Instance.new("RemoteEvent")
	MatchSound.Name = "MatchSound"
	MatchSound.Parent = Remotes
end

function MatchAudio.Play(name, view, volumeScale)
	if not Sounds:FindFirstChild(name) then return end
	if not view then return end

	for _, player in ipairs(view.players or {}) do
		if player.Parent then
			MatchSound:FireClient(player, name, volumeScale)
		end
	end
end

function MatchAudio.Exists(name)
	return Sounds:FindFirstChild(name) ~= nil
end

return MatchAudio
