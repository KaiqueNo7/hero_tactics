local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local ViewStyle = require(script.Parent.ViewStyle)
local VfxLibrary = require(script.Parent.VfxLibrary)
local MatchAudio = require(script.Parent.MatchAudio)

local BoardVfx = {}

local TILE_TOP_Y = ViewStyle.TILE_TOP_Y
local SPRITE_HEIGHT = ViewStyle.SPRITE_HEIGHT
local SideColor = ViewStyle.SideColor
local BuildTeamRing = ViewStyle.BuildTeamRing
local PlaySound = MatchAudio.Play
local SetEmitters = VfxLibrary.SetEmitters

local FX_SMOKE = ViewStyle.FX_SMOKE
local FX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

local FIRE_CIRCLE_HOME = { "VFX", "Karo", "FireCircle" }

-- ===== FOGO NO CHÃO (Karo) =====
-- Nasce por código como o barril, e pelo mesmo motivo: nada que dependa de um
-- modelo guardado no place, que não entra no Rojo nem no git.
--
-- Vive na pasta de heróis da partida (não numa terceira pasta) porque o
-- ClearMatch já apaga aquela pasta inteira no fim do jogo — chama esquecida
-- queimando numa arena vazia seria um vazamento silencioso entre partidas.
--
-- O nome do Part carrega o hexId: é assim que o DestroyFlame acha a chama certa
-- sem o servidor ter que guardar uma segunda tabela de Parts em paralelo à
-- match.flames.
local FLAME_COLOR = Color3.fromRGB(255, 140, 60)
local FLAME_CORE = Color3.fromRGB(255, 225, 150)



local function FlameName(hexId)
	return "Flame_" .. hexId
end

function BoardVfx.CreateFlame(view, hexId, sideIndex)
	if not view then return end

	local existing = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if existing then existing:Destroy() end -- reacendeu a mesma casa: começa limpo

	local center = HexGrid.GetWorldPosition(hexId, view.origin)
	local size = HexGrid.GetHexSize()

	-- Âncora invisível e fina, rente ao topo da casa. O fogo em si é partícula:
	-- um bloco laranja sólido tamparia a casa e brigaria com a pintura de
	-- movimento que o cliente já faz por cima do tabuleiro.
	local part = Instance.new("Part")
	part.Name = FlameName(hexId)
	part.Size = Vector3.new(size * 0.9, 0.2, size * 0.9)
	part.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y, 0))
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	-- CanQuery false: a chama não pode roubar o clique da casa embaixo dela, ou
	-- o jogador perderia a jogada tentando andar pro fogo.
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = view.heroesFolder

	if sideIndex then
		BuildTeamRing(part, hexId, SideColor(sideIndex), view.origin)
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Texture = FX_SMOKE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, FLAME_CORE),
		ColorSequenceKeypoint.new(1, FLAME_COLOR),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.4),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Rate = 14
	emitter.Speed = NumberRange.new(3, 5.5)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.Parent = attachment

	return part
end

function BoardVfx.DestroyFlame(view, hexId)
	if not view then return end

	local part = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if not part then return end

	-- Para de EMITIR e só então destrói: apagar o Part na hora levaria junto as
	-- partículas ainda no ar, e a chama sumiria num corte seco.
	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter", true)
	if emitter then emitter.Enabled = false end

	Debris:AddItem(part, 1.2)
end

-- Quanto tempo o brilho de alcance do Karo fica na casa — só um telegraph
-- visual, não um efeito de jogo (não mora em match.flames, ninguém pisa
-- "nele"), então some rápido em vez dos 2 turnos do fogo de verdade.
local ATTACK_RANGE_FLASH_LIFETIME = 0.5

-- Karo: brilho rápido nas casas a distância 1 dele, sincronizado com o golpe
-- giratório do Soco de Chamas — mostra ONDE o golpe alcança antes/durante o
-- impacto, mesmo nas casas vazias que GetEnemiesInRange nem chega a marcar
-- (só quem está lá dentro leva efeito de acerto). Mesma construção do
-- CreateFlame (âncora fina rente ao topo da casa, mesma paleta laranja do
-- Karo) — pra ficar reconhecível como "o mesmo fogo dele", só que num pulso
-- só em vez de rastro persistente.
function BoardVfx.FlashAttackRange(view, hexIds, coreColor, edgeColor)
	if not view then return end

	local size = HexGrid.GetHexSize()
	coreColor = coreColor or FLAME_CORE
	edgeColor = edgeColor or FLAME_COLOR

	for _, hexId in ipairs(hexIds) do
		local center = HexGrid.GetWorldPosition(hexId, view.origin)

		local part = Instance.new("Part")
		part.Name = "RangeFlash_" .. hexId
		part.Size = Vector3.new(size * 0.9, 0.2, size * 0.9)
		part.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y, 0))
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false -- não pode roubar o clique da casa embaixo, mesma regra da chama
		part.CastShadow = false
		part.Parent = view.heroesFolder

		local attachment = Instance.new("Attachment")
		attachment.Parent = part

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Emitter"
		emitter.Texture = FX_SPARK
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, coreColor),
			ColorSequenceKeypoint.new(1, edgeColor),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		-- cresce pra preencher a casa e desaparece — o "anel" da área de
		-- alcance, não fumaça subindo (isso já é a linguagem visual do rastro)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, size * 0.7),
			NumberSequenceKeypoint.new(1, size * 0.95),
		})
		emitter.Lifetime = NumberRange.new(ATTACK_RANGE_FLASH_LIFETIME, ATTACK_RANGE_FLASH_LIFETIME)
		emitter.Rate = 0
		emitter.Speed = NumberRange.new(0, 0)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.LightEmission = 0.9
		emitter.LightInfluence = 0
		emitter.Parent = attachment
		emitter:Emit(1)

		Debris:AddItem(part, ATTACK_RANGE_FLASH_LIFETIME + 0.2)
	end
end

local POISON_CORE = Color3.fromRGB(196, 255, 150)
local POISON_EDGE = Color3.fromRGB(96, 200, 70)
local POISON_BOMB_TIME = 1.1

local function PlayBlast(view, hexId, coreColor, edgeColor)
	if not view then return end

	local size = HexGrid.GetHexSize()
	local center = HexGrid.GetWorldPosition(hexId, view.origin)

	local hexIds = { hexId }
	for _, hex in ipairs(HexGrid.GetNeighbors(hexId)) do
		table.insert(hexIds, hex.id)
	end
	BoardVfx.FlashAttackRange(view, hexIds, coreColor, edgeColor)

	local cloud = Instance.new("Part")
	cloud.Name = "Blast"
	cloud.Shape = Enum.PartType.Ball
	cloud.Size = Vector3.new(size * 0.5, size * 0.5, size * 0.5)
	cloud.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y + size * 0.4, 0))
	cloud.Color = coreColor
	cloud.Material = Enum.Material.Neon
	cloud.Transparency = 0.45
	cloud.Anchored = true
	cloud.CanCollide = false
	cloud.CanQuery = false
	cloud.CastShadow = false
	cloud.Parent = view.heroesFolder

	local blast = size * 3.6
	TweenService:Create(cloud,
		TweenInfo.new(POISON_BOMB_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = Vector3.new(blast, blast, blast),
			Transparency = 1,
			Color = edgeColor,
		}):Play()

	Debris:AddItem(cloud, POISON_BOMB_TIME + 0.15)
end

function BoardVfx.PlayPoisonBomb(view, hexId)
	PlayBlast(view, hexId, POISON_CORE, POISON_EDGE)
end

local ICE_CORE = Color3.fromRGB(236, 252, 255)
local ICE_EDGE = Color3.fromRGB(120, 200, 245)
local ICE_STORM_TIME = 0.7

local FIRE_CIRCLE_GROW = 0.22
local FIRE_CIRCLE_HOLD = 0.14
local FIRE_CIRCLE_CLOSE = 0.26
local FIRE_CIRCLE_SEED = 0.06
local FIRE_CIRCLE_TAIL = 1.6

local function FireCircleTemplate()
	return VfxLibrary.Template(FIRE_CIRCLE_HOME, "o giro do Karo sai sem o anel de fogo")
end

function BoardVfx.PlayFireCircle(view, hexId)
	if not view then return end

	local template = FireCircleTemplate()
	if not template then return end

	local circle = template:Clone()
	VfxLibrary.StripLights(circle)
	local center = HexGrid.GetWorldPosition(hexId, view.origin)
		+ Vector3.new(0, TILE_TOP_Y + 0.15, 0)

	-- SÓ pega a peça solta quando o efeito INTEIRO é uma peça. Antes ele pescava
	-- a primeira BasePart de dentro de um Model e movia/encolhia só ela: num
	-- efeito de várias peças, uma ia pro hexágono e as outras ficavam onde o
	-- molde estava. Model tem PivotTo e é assim que ele se move — inteiro.
	local part = circle:IsA("BasePart") and circle or nil

	if not part and not circle:IsA("PVInstance") then
		local host = Instance.new("Part")
		host.Name = "FireCircleHost"
		host.Size = Vector3.new(0.2, 0.2, 0.2)
		host.Transparency = 1
		host.Anchored = true
		host.CanCollide = false
		host.CanQuery = false
		host.CastShadow = false
		circle.Parent = host
		circle = host
		part = host
	end

	local anchor = part or circle
	-- a orientação com que o efeito foi montado no Explorer é preservada: um anel
	-- deitado no chão continua deitado, e não é endireitado pelo reposicionamento
	local spin = part and part.CFrame.Rotation
		or (circle:IsA("PVInstance") and circle:GetPivot().Rotation)
		or CFrame.identity
	local full, seed = nil, nil

	if part then
		full = part.Size
		seed = Vector3.new(full.X, full.Y * FIRE_CIRCLE_SEED, full.Z * FIRE_CIRCLE_SEED)
		part.Size = seed
	end

	if anchor:IsA("BasePart") then
		anchor.CFrame = CFrame.new(center) * spin
	else
		anchor:PivotTo(CFrame.new(center) * spin)
	end

	circle.Parent = view.heroesFolder
	SetEmitters(circle, true)

	if part then
		TweenService:Create(part,
			TweenInfo.new(FIRE_CIRCLE_GROW, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Size = full }):Play()
	end

	task.delay(FIRE_CIRCLE_GROW + FIRE_CIRCLE_HOLD, function()
		if not circle.Parent then return end

		if part and part.Parent then
			TweenService:Create(part,
				TweenInfo.new(FIRE_CIRCLE_CLOSE, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = seed }):Play()
		end

		task.delay(FIRE_CIRCLE_CLOSE, function()
			if circle.Parent then SetEmitters(circle, false) end
		end)
	end)

	Debris:AddItem(circle, FIRE_CIRCLE_GROW + FIRE_CIRCLE_HOLD + FIRE_CIRCLE_CLOSE + FIRE_CIRCLE_TAIL)
end

local CHAIN_CORE_COLOR = Color3.fromRGB(255, 250, 190)
local CHAIN_GLOW_COLOR = Color3.fromRGB(255, 214, 40)
local CHAIN_STEP = 0.07
local CHAIN_LIFE = 0.26
local CHAIN_SEGMENTS = 3
local CHAIN_JITTER = 0.9
local CHAIN_THICKNESS = 0.22

local function BuildArcSegment(parent, fromPoint, toPoint, thickness, color)
	local delta = toPoint - fromPoint
	local segment = Instance.new("Part")
	segment.Name = "ChainArc"
	segment.Size = Vector3.new(thickness, thickness, delta.Magnitude)
	segment.CFrame = CFrame.new(fromPoint + delta * 0.5, toPoint)
	segment.Color = color
	segment.Material = Enum.Material.Neon
	segment.Anchored = true
	segment.CanCollide = false
	segment.CanQuery = false
	segment.CastShadow = false
	segment.Parent = parent
	return segment
end

local function PlayArc(view, fromHex, toHex)
	local lift = Vector3.new(0, TILE_TOP_Y + SPRITE_HEIGHT * 0.35, 0)
	local origin = HexGrid.GetWorldPosition(fromHex, view.origin) + lift
	local target = HexGrid.GetWorldPosition(toHex, view.origin) + lift

	local previous = origin
	for index = 1, CHAIN_SEGMENTS do
		local straight = origin:Lerp(target, index / CHAIN_SEGMENTS)
		local point = index < CHAIN_SEGMENTS and straight + Vector3.new(
			(math.random() - 0.5) * CHAIN_JITTER,
			(math.random() - 0.5) * CHAIN_JITTER,
			(math.random() - 0.5) * CHAIN_JITTER
		) or target

		local glow = BuildArcSegment(view.heroesFolder, previous, point, CHAIN_THICKNESS * 2.1, CHAIN_GLOW_COLOR)
		glow.Transparency = 0.55
		local core = BuildArcSegment(view.heroesFolder, previous, point, CHAIN_THICKNESS, CHAIN_CORE_COLOR)

		for _, part in ipairs({ glow, core }) do
			TweenService:Create(part, TweenInfo.new(CHAIN_LIFE), { Transparency = 1 }):Play()
			Debris:AddItem(part, CHAIN_LIFE + 0.05)
		end

		previous = point
	end
end

function BoardVfx.PlayChainArcs(view, edges)
	if not view then return end

	for _, edge in ipairs(edges) do
		local delay = edge.depth * CHAIN_STEP
		if delay <= 0 then
			PlayArc(view, edge.from, edge.to)
		else
			task.delay(delay, function()
				if view.heroesFolder and view.heroesFolder.Parent then
					PlayArc(view, edge.from, edge.to)
				end
			end)
		end
	end
end

function BoardVfx.PlayIceStorm(view, hexId)
	if not view then return end

	PlayBlast(view, hexId, ICE_CORE, ICE_EDGE)

	local size = HexGrid.GetHexSize()
	local center = HexGrid.GetWorldPosition(hexId, view.origin)

	local hexIds = {}
	for _, hex in ipairs(HexGrid.GetNeighbors(hexId)) do
		table.insert(hexIds, hex.id)
	end
	table.insert(hexIds, hexId)
	BoardVfx.FlashAttackRange(view, hexIds, ICE_CORE, ICE_EDGE)

	local ring = Instance.new("Part")
	ring.Name = "IceStormRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.2, size * 0.6, size * 0.6)
	ring.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y + 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = ICE_CORE
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.35
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Parent = view.heroesFolder

	local grow = TweenInfo.new(ICE_STORM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, grow, {
		Size = Vector3.new(0.2, size * 4.2, size * 4.2),
		Transparency = 1,
		Color = ICE_EDGE,
	}):Play()

	Debris:AddItem(ring, ICE_STORM_TIME + 0.15)
end

-- Alguém atravessou a chama: lufada curta pra amarrar o número de dano à casa.
-- Toca sempre que uma chama é CONSUMIDA — o pedágio que mata o fogo (ver
-- MatchManager.MoveHero: dano, depois ClearFlame na mesma casa). Som próprio,
-- não o "Hit" genérico de golpe corpo a corpo: isto é a chama acabando, não
-- uma pancada.
function BoardVfx.PlayFlameHit(view, hexId)
	if not view then return end

	local part = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if not part then return end

	PlaySound("FlameConsume", view)

	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter", true)
	if emitter then emitter:Emit(18) end
end

return BoardVfx
