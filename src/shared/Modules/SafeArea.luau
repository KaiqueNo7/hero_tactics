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
SafeArea.MARGIN = 10

function SafeArea.TopInset()
	local topLeft = GuiService:GetGuiInset()
	local top = topLeft.Y

	local ok, rect = pcall(function() return GuiService.TopbarInset end)
	if ok and typeof(rect) == "Rect" then
		top = math.max(top, rect.Max.Y)
	end

	return top
end

function SafeArea.Top()
	return SafeArea.TopInset() + SafeArea.MARGIN
end

function SafeArea.Left()
	local ok, rect = pcall(function() return GuiService.TopbarInset end)
	if ok and typeof(rect) == "Rect" then
		return rect.Min.X + SafeArea.MARGIN
	end
	return SafeArea.MARGIN
end

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
