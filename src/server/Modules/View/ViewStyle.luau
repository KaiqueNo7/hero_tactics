local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)

local ViewStyle = {}

ViewStyle.TILE_TOP_Y = 0.5
ViewStyle.GUI_MAX_DISTANCE = 200

ViewStyle.BADGE_BG = Color3.fromRGB(26, 23, 32)
ViewStyle.BADGE_GOLD = Color3.fromRGB(255, 205, 90)

ViewStyle.FX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
ViewStyle.FX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
ViewStyle.DUST = Color3.fromRGB(196, 150, 96)

-- ===== AJUSTE FINO =====
-- A casa hexagonal mede ~9,8 studs de ponta a ponta (HEX_RADIUS 6 no
-- BoardSpawner), e o sprite ocupava 4,2 — o herói ficava pequeno no meio do
-- tabuleiro visto de cima. 5,2 dá presença sem transbordar pra casa vizinha nem
-- tapar o vizinho de trás. Tudo que é derivado (altura, elevação da âncora,
-- posição dos selos de ATK/HP e do texto flutuante) acompanha sozinho.
ViewStyle.SPRITE_WIDTH = 5.8
ViewStyle.SPRITE_HEIGHT = ViewStyle.SPRITE_WIDTH * (HeroData.FRAME_HEIGHT / HeroData.FRAME_WIDTH)
ViewStyle.ANCHOR_LIFT = ViewStyle.SPRITE_HEIGHT * 0.4

function ViewStyle.GroundCFrame(hexId, origin)
	return CFrame.new(HexGrid.GetWorldPosition(hexId, origin) + Vector3.new(0, ViewStyle.TILE_TOP_Y, 0))
end

-- Rajada de lascas/poeira presa ao objeto. Usada no golpe e na quebra.
function ViewStyle.DustBurst(part, count, speed, color)
	local attachment = part:FindFirstChild("Dust")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "Dust"
		attachment.Parent = part

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Emitter"
		emitter.Enabled = false
		emitter.Rate = 0
		emitter.Texture = ViewStyle.FX_SMOKE
		emitter.Color = ColorSequence.new(color or ViewStyle.DUST)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.2),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Lifetime = NumberRange.new(0.35, 0.8)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-160, 160)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, -12, 0)
		emitter.Drag = 3
		emitter.LightEmission = 0.2
		emitter.Parent = attachment
	end

	local emitter = attachment:FindFirstChild("Emitter")
	if emitter then
		emitter.Speed = NumberRange.new(speed * 0.5, speed)
		emitter:Emit(count)
	end
end

ViewStyle.TEAM_COLOR_PLAYER_1 = Color3.fromRGB(70, 150, 255)
ViewStyle.TEAM_COLOR_PLAYER_2 = Color3.fromRGB(230, 70, 70)

ViewStyle.RING_SCALE = 0.64
ViewStyle.RING_THICKNESS = 0.32
ViewStyle.RING_HEIGHT = 0.08

-- A cor vem do lado (1 = azul, 2 = vermelho), não de "é o bot?": em PvP os
-- dois lados são jogadores e a câmera é a mesma pros dois.
function ViewStyle.SideColor(sideIndex)
	return sideIndex == 2 and ViewStyle.TEAM_COLOR_PLAYER_2 or ViewStyle.TEAM_COLOR_PLAYER_1
end

-- Pendura uma parte na âncora: sem Anchored e presa por WeldConstraint,
-- então acompanha qualquer movimento/tween da âncora.
function ViewStyle.AttachTo(anchor, part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = anchor

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = anchor
end

function ViewStyle.BuildTeamRing(anchor, hexId, color, origin)
	local center = HexGrid.GetWorldPosition(hexId, origin) + Vector3.new(0, ViewStyle.TILE_TOP_Y + ViewStyle.RING_HEIGHT, 0)
	local circumradius = HexGrid.GetHexSize() * ViewStyle.RING_SCALE
	local apothem = circumradius * math.sqrt(3) / 2

	for side = 0, 5 do
		local midAngle = math.rad(side * 60 + 30)
		local outward = Vector3.new(math.cos(midAngle), 0, math.sin(midAngle))
		local tangent = Vector3.new(-math.sin(midAngle), 0, math.cos(midAngle))
		local position = center + outward * apothem

		local edge = Instance.new("Part")
		edge.Name = "RingEdge" .. side
		edge.Size = Vector3.new(ViewStyle.RING_THICKNESS, ViewStyle.RING_THICKNESS, circumradius + ViewStyle.RING_THICKNESS)
		edge.CFrame = CFrame.new(position, position + tangent)
		edge.Color = color
		edge.Material = Enum.Material.SmoothPlastic
		ViewStyle.AttachTo(anchor, edge)
	end
end

return ViewStyle
