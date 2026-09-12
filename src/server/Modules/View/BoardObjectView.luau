local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ViewStyle = require(script.Parent.ViewStyle)
local MatchAudio = require(script.Parent.MatchAudio)
local ArenaObjectBuilder = require(ServerScriptService.Modules.Arena.ArenaObjectBuilder)

local BoardObjectView = {}

-- ===== VIDA DO BARRIL =====
-- Um quadradinho por golpe que ele ainda aguenta, na mesma casca escura com
-- moldura dourada dos crachás de herói. Bolinhas e não número porque a vida do
-- barril não é vida: são DUAS pancadas, e duas pecinhas se leem sem contar.
-- Apaga da direita pra esquerda conforme apanha.
local BARREL_PIP_ON = Color3.fromRGB(232, 172, 74) -- o mesmo âmbar que o cliente pinta na casa
local BARREL_PIP_OFF = Color3.fromRGB(64, 54, 44)
local BARREL_PIP = 9

local function BuildBadge(part, barrel)
	local gui = Instance.new("BillboardGui")
	gui.MaxDistance = ViewStyle.GUI_MAX_DISTANCE
	gui.Name = "BarrelInfo"
	gui.Size = UDim2.new(0, barrel.hitsLeft * (BARREL_PIP + 3) + 7, 0, BARREL_PIP + 8)
	gui.StudsOffset = Vector3.new(0, ArenaObjectBuilder.Size(barrel.view).Y * 0.72, 0)
	-- sem AlwaysOnTop: nada fica na frente do barril no tabuleiro, e assim ele
	-- não atravessa cenário nem rouba o clique de quem estiver atrás
	gui.Parent = part

	local shell = Instance.new("Frame")
	shell.Name = "Shell"
	shell.Size = UDim2.fromScale(1, 1)
	shell.BackgroundColor3 = ViewStyle.BADGE_BG
	shell.BorderSizePixel = 0
	shell.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = shell

	local stroke = Instance.new("UIStroke")
	stroke.Color = ViewStyle.BADGE_GOLD
	stroke.Thickness = 1.1
	stroke.Transparency = 0.15
	stroke.Parent = shell

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = shell

	for index = 1, barrel.hitsLeft do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. index
		pip.LayoutOrder = index
		pip.Size = UDim2.new(0, BARREL_PIP, 0, BARREL_PIP)
		pip.BackgroundColor3 = BARREL_PIP_ON
		pip.BorderSizePixel = 0
		pip.Parent = shell

		local pipCorner = Instance.new("UICorner")
		pipCorner.CornerRadius = UDim.new(0, 2)
		pipCorner.Parent = pip
	end

	return gui
end

function BoardObjectView.UpdateBadge(barrel)
	local part = barrel.part
	if not (part and part.Parent) then return end

	local gui = part:FindFirstChild("BarrelInfo")
	local shell = gui and gui:FindFirstChild("Shell")
	if not shell then return end

	for _, pip in ipairs(shell:GetChildren()) do
		local index = tonumber(pip.Name:match("^Pip(%d+)$") or "")
		if index then
			local aceso = index <= barrel.hitsLeft
			TweenService:Create(pip, TweenInfo.new(0.2), {
				BackgroundColor3 = aceso and BARREL_PIP_ON or BARREL_PIP_OFF,
			}):Play()
		end
	end
end

function BoardObjectView.Create(barrel)
	local part = ArenaObjectBuilder.Spawn(barrel.view, barrel.position, "Barrel_" .. barrel.uid)
	part:SetAttribute("BarrelUid", barrel.uid)

	BuildBadge(part, barrel)

	part.Parent = barrel.view.heroesFolder
	barrel.part = part
	return part
end

-- Primeiro golpe: apaga um quadradinho do crachá, sacode, solta poeira e fica
-- TORTO até a próxima pancada. A inclinação é redundante com o crachá de
-- propósito: o barril fica óbvio mesmo pra quem está com a câmera longe.
function BoardObjectView.PlayHit(barrel)
	local part = barrel.part
	if not (part and part.Parent) then return end

	MatchAudio.Play(ArenaObjectBuilder.SoundName(barrel.view, "hitSound", "Hit"), barrel.view)
	ViewStyle.DustBurst(part, 10, 9, ArenaObjectBuilder.Dust(barrel.view))
	BoardObjectView.UpdateBadge(barrel)

	local base = ArenaObjectBuilder.CFrameAt(barrel.view, barrel.position)
	local tombado = base * CFrame.Angles(math.rad(9), 0, math.rad(13))
	local repouso = (barrel.hitsLeft <= 1) and tombado or base

	TweenService:Create(part, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = base * CFrame.new(0, 0.5, 0) * CFrame.Angles(math.rad(-12), 0, math.rad(10)),
	}):Play()

	task.delay(0.1, function()
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { CFrame = repouso }):Play()
		end
	end)
end

function BoardObjectView.Break(barrel)
	local part = barrel.part
	barrel.part = nil
	if not (part and part.Parent) then return end

	-- Som próprio, e não o HeroDeath: barril quebrando é madeira estourando, não
	-- alguém morrendo. Emprestar o som de morte fazia o jogador olhar pro
	-- tabuleiro procurando qual herói tinha caído.
	MatchAudio.Play(ArenaObjectBuilder.SoundName(barrel.view, "breakSound", "BarrelBreak"), barrel.view)
	ViewStyle.DustBurst(part, 30, 20, ArenaObjectBuilder.Dust(barrel.view))

	-- o crachá some junto com o barril, não com o Part: ele ainda vive ~1s pra
	-- as partículas terminarem, e um placar de vida boiando sobre os cacos seria
	-- a única coisa na tela dizendo que ainda tem barril ali
	local badge = part:FindFirstChild("BarrelInfo")
	if badge then badge.Enabled = false end

	-- o barril some rápido, mas o Part só é destruído depois: destruir na hora
	-- levaria as partículas junto e a quebra não apareceria
	local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
	if mesh then
		TweenService:Create(mesh, TweenInfo.new(0.25), { Scale = Vector3.new(0.1, 0.1, 0.1) }):Play()
	end

	-- Modelo do asset some por transparência, não por escala: as peças estão
	-- soldadas, e encolher briga com a solda.
	local model = part:FindFirstChild("ObjectModel")
	if model then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				TweenService:Create(descendant, TweenInfo.new(0.25), { Transparency = 1 }):Play()
			end
		end
	end
	part.CanQuery = false
	Debris:AddItem(part, 1.2)
end

return BoardObjectView
