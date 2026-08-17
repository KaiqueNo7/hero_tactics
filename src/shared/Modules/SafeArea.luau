--[[
	SafeArea.lua
	ModuleScript — ReplicatedStorage/Modules/SafeArea

	Onde a nossa interface pode desenhar sem brigar com os controles do Roblox.

	No topo da tela o Roblox põe o botão de menu, o chat e o microfone. A faixa
	que eles ocupam muda de tamanho conforme o aparelho — e é justamente no
	celular, onde ela é proporcionalmente maior, que os nossos painéis batiam nos
	botões dele: o toque ia parar no menu do Roblox em vez do nosso.

	QUEM PRECISA DISTO
	Só as ScreenGui com `IgnoreGuiInset = true`, que é o caso das telas que
	precisam cobrir o vídeo inteiro (fundo escurecido de modal, HUD de batalha).
	Numa ScreenGui normal o próprio motor já desce o conteúdo abaixo da faixa —
	usar o SafeArea nela desceria duas vezes.
]]

local GuiService = game:GetService("GuiService")

local SafeArea = {}

-- Respiro entre a barra do Roblox e o nosso primeiro elemento. Não é firula:
-- colado, o dedo que mira no nosso botão acerta o do Roblox.
SafeArea.MARGIN = 10

-- Altura da faixa do topo, em pixels.
--
-- Duas fontes porque elas discordam: o GetGuiInset é o deslocamento clássico
-- (existe em todo lugar) e o TopbarInset é a barra unificada nova, que pode ser
-- mais alta. Fica a maior — errar pra baixo é o que produz o toque roubado.
function SafeArea.TopInset()
	local topLeft = GuiService:GetGuiInset()
	local top = topLeft.Y

	local ok, rect = pcall(function() return GuiService.TopbarInset end)
	if ok and typeof(rect) == "Rect" then
		top = math.max(top, rect.Max.Y)
	end

	return top
end

-- Primeiro Y livre pra uma GUI que ignora o inset.
function SafeArea.Top()
	return SafeArea.TopInset() + SafeArea.MARGIN
end

-- Primeiro X livre DENTRO da faixa do topo. Só interessa a quem insiste em
-- desenhar lá em cima; abaixo da faixa a largura é toda nossa.
function SafeArea.Left()
	local ok, rect = pcall(function() return GuiService.TopbarInset end)
	if ok and typeof(rect) == "Rect" then
		return rect.Min.X + SafeArea.MARGIN
	end
	return SafeArea.MARGIN
end

-- A faixa muda: o celular gira, o jogador entra em tela cheia, o Roblox liga um
-- botão novo — e, o caso que pegou este código de surpresa, ela nasce ESCONDIDA
-- atrás da tela de carregamento. Os scripts sobem nesse instante, medem zero e
-- desenham colado no topo; segundos depois a barra aparece por cima de tudo.
--
-- Por que vigiar em vez de escutar um sinal: quem muda nessa hora é o
-- GetGuiInset, que não tem sinal de mudança, e o TopbarInset (que tem) fica
-- parado. Reler dois números quatro vezes por segundo custa nada perto de
-- reposicionar a interface na mão em cada tela.
local RunService = game:GetService("RunService")

local watchers = {}
local watching = false
local lastTop = nil
local accumulated = 0

local function pump(delta)
	accumulated += delta
	if accumulated < 0.25 then return end
	accumulated = 0

	local top = SafeArea.TopInset()
	if top == lastTop then return end
	lastTop = top

	for callback in pairs(watchers) do
		task.spawn(callback)
	end
end

function SafeArea.OnChange(callback)
	watchers[callback] = true

	if not watching then
		watching = true
		lastTop = SafeArea.TopInset()
		RunService.Heartbeat:Connect(pump)
	end

	return function()
		watchers[callback] = nil
	end
end

return SafeArea
