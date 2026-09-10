--[[
	Device.lua
	ModuleScript — ReplicatedStorage/Modules/Device

	Em que tipo de aparelho este cliente está rodando.

	NÃO EXISTE UMA PROPRIEDADE "É CELULAR" no Roblox. O que existe são sinais
	soltos, e cada um deles mente sozinho:

	  TouchEnabled     um notebook com tela de toque também tem
	  KeyboardEnabled  um tablet com teclado bluetooth também tem
	  ViewportSize     uma janela estreita no PC parece um celular em pé

	Por isso a classificação é por ELIMINAÇÃO, na ordem do sinal mais confiável
	pro menos. O `IsTenFootInterface` é o único que não tem ambiguidade nenhuma:
	só console devolve true.

	A regra que resolve o caso do item 44 (PC com touchscreen classificado como
	celular) é a terceira: ter teclado derruba a hipótese de aparelho de toque.

	CELULAR E TABLET SÃO O MESMO CAMINHO. Não existe API pra separá-los, e a
	diagonal do viewport é chute — dois aparelhos com a mesma diagonal em pixels
	podem ter tamanhos físicos bem diferentes. Como os dois seguem exatamente a
	mesma regra de orientação (acompanhar a tela), a distinção não decide nada
	de gameplay: ela existe só pra tela de Settings saber que opções mostrar.
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Device = {}

Device.DESKTOP = "Desktop"
Device.CONSOLE = "Console"
Device.MOBILE = "Mobile"
Device.TABLET = "Tablet"

-- Diagonal em pixels a partir da qual um aparelho de toque é chamado de tablet.
-- É aproximação, e de propósito ela não decide nada além do texto da Settings.
Device.TABLET_DIAGONAL = 1200

local function Diagonal()
	local camera = Workspace.CurrentCamera
	if not camera then return 0 end

	local size = camera.ViewportSize
	return math.sqrt(size.X * size.X + size.Y * size.Y)
end

-- Recalculado a cada chamada, e não guardado: o Roblox pode ligar o gamepad no
-- meio da sessão, e o Studio troca de emulação sem recarregar o script. É uma
-- leitura de propriedades, custa quase nada, e ninguém chama isso por quadro.
function Device.Current()
	local ok, tenFoot = pcall(function() return GuiService:IsTenFootInterface() end)
	if ok and tenFoot then return Device.CONSOLE end

	-- Teclado presente derruba a hipótese de aparelho de toque: é o notebook com
	-- tela sensível, não um celular.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return Diagonal() >= Device.TABLET_DIAGONAL and Device.TABLET or Device.MOBILE
	end

	return Device.DESKTOP
end

-- Quem acompanha a tela e quem não acompanha. É a única pergunta que o resto do
-- jogo faz sobre o aparelho, e deixá-la aqui evita `if device == "Mobile" or
-- device == "Tablet"` espalhado.
--
-- NO STUDIO, SEMPRE ACOMPANHA. O emulador de dispositivo desenha um celular na
-- tela mas NÃO liga o TouchEnabled, e o teclado da máquina continua ativo — medi
-- e confirmei. Com isso o emulador era classificado como Desktop, Desktop é
-- Landscape fixo, e não havia como testar Portrait em lugar nenhum.
--
-- Deixar o Studio seguir a tela é seguro e não vaza pra produção: numa janela
-- normal de edição a tela é larga, então continua Landscape do mesmo jeito. O
-- que muda é o emulador passar a funcionar, que é a razão de ele existir.
function Device.FollowsScreen(device)
	if RunService:IsStudio() then return true end

	device = device or Device.Current()
	return device == Device.MOBILE or device == Device.TABLET
end

function Device.IsTouch(device)
	return Device.FollowsScreen(device)
end

return Device
