--[[
	Orientation.lua
	ModuleScript — ReplicatedStorage/Modules/Orientation

	Qual layout vale AGORA: Landscape ou Portrait.

	Mora num módulo e não num LocalScript porque quem precisa da resposta são
	vários scripts do cliente (câmera hoje, HUD e lobby depois), e LocalScript
	não se requer. O estado é um só, o cálculo é um só, e quem quiser saber
	quando mudou assina o OnChange.

	A CONTA, na ordem do item 14 do pedido:

	  1. escolha manual do jogador, se houver
	  2. restrição do aparelho (console e desktop são sempre Landscape)
	  3. o formato da tela agora
	  4. Landscape, que é o fallback seguro

	MANUAL NÃO ACOMPANHA ROTAÇÃO. Só o Automatic olha a tela. Girar o aparelho
	com Portrait travado continua em Portrait — é a promessa do modo manual, e
	quebrar isso faria a opção não ter sentido.

	HISTERESE. Tela quase quadrada e o meio de uma rotação passam por proporções
	ambíguas, e trocar de perfil a cada quadro dali seria pior que não ter
	Portrait. A faixa morta de 5% resolve os dois: dentro dela, mantém o que já
	valia.

	SEM LOOP POR QUADRO. Quem avisa que a tela mudou é o próprio evento de
	ViewportSize da câmera. É o mesmo caminho que o PlacementClient já usava.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Device = require(ReplicatedStorage.Modules.Device)

local Orientation = {}

Orientation.LANDSCAPE = "Landscape"
Orientation.PORTRAIT = "Portrait"
Orientation.AUTOMATIC = "Automatic"

-- Quanto um lado precisa passar do outro pra valer a troca. 1.05 = 5%.
Orientation.HYSTERESIS = 1.05

local preference = Orientation.AUTOMATIC
local effective = Orientation.LANDSCAPE
local watchers = {}
local listening = false

-- O formato da tela, com a faixa morta. Devolve nil quando está ambíguo, e o
-- nil é a resposta certa: significa "não mexe no que já estava".
local function ScreenShape()
	local camera = Workspace.CurrentCamera
	if not camera then return nil end

	local size = camera.ViewportSize
	if size.X <= 0 or size.Y <= 0 then return nil end

	if size.Y / size.X >= Orientation.HYSTERESIS then return Orientation.PORTRAIT end
	if size.X / size.Y >= Orientation.HYSTERESIS then return Orientation.LANDSCAPE end
	return nil
end

local function Resolve()
	if preference ~= Orientation.AUTOMATIC then return preference end

	-- Console e desktop nunca viram Portrait sozinhos. No desktop isso é a
	-- diferença entre "a janela ficou estreita" e "o jogador quer Portrait" —
	-- a primeira não é um pedido.
	if not Device.FollowsScreen() then return Orientation.LANDSCAPE end

	return ScreenShape() or effective
end

local function Publish()
	local wanted = Resolve()
	if wanted == effective then return end

	effective = wanted
	for callback in pairs(watchers) do
		task.spawn(callback, effective)
	end
end

local function Listen()
	if listening then return end

	local camera = Workspace.CurrentCamera
	if not camera then return end

	listening = true
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(Publish)
end

-- Primeira leitura sem histerese: na entrada não existe "o que já valia", então
-- a faixa morta não tem o que preservar e um celular quase quadrado ficaria em
-- Landscape por acidente.
local function FirstRead()
	if preference ~= Orientation.AUTOMATIC then return preference end
	if not Device.FollowsScreen() then return Orientation.LANDSCAPE end

	local camera = Workspace.CurrentCamera
	if not camera then return Orientation.LANDSCAPE end

	local size = camera.ViewportSize
	if size.X <= 0 or size.Y <= 0 then return Orientation.LANDSCAPE end

	return size.Y > size.X and Orientation.PORTRAIT or Orientation.LANDSCAPE
end

function Orientation.Current()
	return effective
end

function Orientation.Preference()
	return preference
end

-- A preferência salva chega do servidor depois do login, então isto pode ser
-- chamado com o jogo já rodando. Valor desconhecido cai em Automatic em vez de
-- travar num perfil errado.
function Orientation.SetPreference(value)
	if value ~= Orientation.LANDSCAPE and value ~= Orientation.PORTRAIT then
		value = Orientation.AUTOMATIC
	end

	if value == preference then return end
	preference = value
	Publish()
end

function Orientation.OnChange(callback)
	watchers[callback] = true
	return function() watchers[callback] = nil end
end

-- ===== FORÇAR NO STUDIO =====
-- Pela barra de comando do cliente, sem mexer em preferência salva nem depender
-- do emulador classificar o aparelho:
--
--   require(game.ReplicatedStorage.Modules.Orientation).Force("Portrait")
--   require(game.ReplicatedStorage.Modules.Orientation).Force("Landscape")
--   require(game.ReplicatedStorage.Modules.Orientation).Force(nil)
--
-- É a mesma porta do SetPreference de propósito: forçar aqui é exatamente o que
-- a opção manual da Settings vai fazer quando ela existir, então testar isto é
-- testar aquilo.
function Orientation.Force(value)
	Orientation.SetPreference(value or Orientation.AUTOMATIC)
	return effective
end

function Orientation.Start()
	effective = FirstRead()
	Listen()
	return effective
end

return Orientation
