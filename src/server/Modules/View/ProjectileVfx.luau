local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local ViewStyle = require(script.Parent.ViewStyle)
local VfxLibrary = require(script.Parent.VfxLibrary)

local FX_SMOKE = ViewStyle.FX_SMOKE
local FX_SPARK = ViewStyle.FX_SPARK

-- As duas peças do tiro (a bolinha e a retícula) são criadas UMA vez por
-- partida e reaproveitadas. Antes nasciam e morriam a cada ataque à distância —
-- e como o servidor só resolve uma ação por vez, nunca houve mais de um tiro no
-- ar: criar e destruir era trabalho de replicação puro, no meio do golpe.
local Bolt = {
	SIZE = 0.9,
	SPEED = 60,
	MIN_TIME = 0.16,
	MAX_TIME = 0.5,
	TRAIL_LIFETIME = 0.32,
	RETICLE_SPAN = ViewStyle.RING_THICKNESS * 9,
	RETICLE_HOLD = 0.24,
	ARCANE_TAIL = Color3.fromRGB(120, 205, 255),
	SPELL_TAIL = Color3.fromRGB(190, 255, 235),
	STYLES = { gustPush = "wind", clean = "arcane", longShot = "spell" },

	TRAIL_WIDTH = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.6, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	}),
	TRAIL_FADE = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	}),

	WIND_WIDTH = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.6),
		NumberSequenceKeypoint.new(0.35, 3.4),
		NumberSequenceKeypoint.new(1, 0.6),
	}),
	WIND_FADE = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.4, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	}),

	ARCANE_WIDTH = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4),
		NumberSequenceKeypoint.new(0.5, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	}),
	ARCANE_FADE = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.55, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	}),

	SPELL_WIDTH = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.2),
		NumberSequenceKeypoint.new(0.3, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	}),
	SPELL_FADE = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	}),
}

function Bolt.Ensure(view)
	if view.bolt and view.bolt.Parent then return view.bolt, view.reticle end

	local part = Instance.new("Part")
	part.Name = "RangedBolt"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(Bolt.SIZE, Bolt.SIZE, Bolt.SIZE)
	part.Color = Color3.fromRGB(255, 235, 150)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = view.heroesFolder

	local top = Instance.new("Attachment")
	top.Name = "TrailTop"
	top.Position = Vector3.new(0, Bolt.SIZE * 0.62, 0)
	top.Parent = part

	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailBottom"
	bottom.Position = Vector3.new(0, -Bolt.SIZE * 0.62, 0)
	bottom.Parent = part

	local trail = Instance.new("Trail")
	trail.Name = "BoltTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = Bolt.TRAIL_LIFETIME
	trail.MinLength = 0
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.WidthScale = Bolt.TRAIL_WIDTH
	trail.Transparency = Bolt.TRAIL_FADE
	trail.Enabled = false
	trail.Parent = part

	local glow = Instance.new("PointLight")
	glow.Name = "BoltGlow"
	glow.Range = 10
	glow.Brightness = 2.2
	glow.Enabled = false
	glow.Parent = part

	local reticle = Instance.new("Part")
	reticle.Name = "RangedTarget"
	reticle.Shape = Enum.PartType.Cylinder
	reticle.Size = Vector3.new(0.15, Bolt.RETICLE_SPAN, Bolt.RETICLE_SPAN)
	reticle.Color = Color3.fromRGB(255, 90, 80)
	reticle.Material = Enum.Material.Neon
	reticle.Anchored = true
	reticle.CanCollide = false
	reticle.CanQuery = false
	reticle.CastShadow = false
	reticle.Transparency = 1
	reticle.Parent = view.heroesFolder

	view.bolt, view.reticle, view.boltTrail, view.boltGlow = part, reticle, trail, glow
	return part, reticle
end

function Bolt.Wind(part)
	local existing = part:FindFirstChild("BoltWind")
	if existing then return existing end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "BoltWind"
	emitter.Texture = FX_SMOKE
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.3, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.45, 3.2),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	emitter.Lifetime = NumberRange.new(0.22, 0.42)
	emitter.Rate = 260
	emitter.Speed = NumberRange.new(1, 5)
	emitter.SpreadAngle = Vector2.new(45, 45)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-260, 260)
	emitter.Drag = 3
	emitter.LightEmission = 0.45
	emitter.LightInfluence = 0
	emitter.Enabled = false
	emitter.Parent = part

	return emitter
end

function Bolt.Motes(part)
	local existing = part:FindFirstChild("BoltMotes")
	if existing then return existing end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "BoltMotes"
	emitter.Texture = FX_SPARK
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.6, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.35, 1.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.62)
	emitter.Rate = 160
	emitter.Speed = NumberRange.new(0.5, 2.5)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.Drag = 4
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Enabled = false
	emitter.Parent = part

	return emitter
end

function Bolt.Sparks(part)
	local existing = part:FindFirstChild("BoltSparks")
	if existing then return existing end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "BoltSparks"
	emitter.Texture = FX_SPARK
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.3, 1.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.18, 0.34)
	emitter.Rate = 240
	emitter.Speed = NumberRange.new(0, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-420, 420)
	emitter.Drag = 8
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Enabled = false
	emitter.Parent = part

	return emitter
end

function Bolt.Style(hero)
	for _, key in ipairs(hero.abilities or {}) do
		local style = Bolt.STYLES[key]
		if style then return style end
	end
	return nil
end

function Bolt.Color(hero)
	local data = hero and hero.dataId and HeroData.GetById(hero.dataId)
	local color = (data and data.color) or Color3.fromRGB(255, 235, 150)
	return color:Lerp(Color3.new(1, 1, 1), 0.42)
end

function Bolt.SpellSpectrum(color)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(0.35, color),
		ColorSequenceKeypoint.new(1, Bolt.SPELL_TAIL),
	})
end

function Bolt.Spectrum(color)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, color:Lerp(Color3.new(1, 1, 1), 0.55)),
		ColorSequenceKeypoint.new(0.45, color),
		ColorSequenceKeypoint.new(1, Bolt.ARCANE_TAIL),
	})
end

function Bolt.Quiet(part)
	for _, name in ipairs({ "BoltWind", "BoltMotes", "BoltSparks" }) do
		local emitter = part:FindFirstChild(name)
		if emitter then emitter.Enabled = false end
	end
end

function Bolt.ApplyStyle(part, trail, glow, color, style)
	if not (trail and glow) then return end

	Bolt.Quiet(part)
	part.Size = Vector3.new(Bolt.SIZE, Bolt.SIZE, Bolt.SIZE)
	glow.Range = 10

	if style == "wind" then
		part.Transparency = 0.8
		trail.Color = ColorSequence.new(color)
		trail.WidthScale = Bolt.WIND_WIDTH
		trail.Transparency = Bolt.WIND_FADE
		glow.Brightness = 1.1

		local emitter = Bolt.Wind(part)
		emitter.Color = ColorSequence.new(color)
		emitter.Enabled = true
		return
	end

	if style == "spell" then
		local spectrum = Bolt.SpellSpectrum(color)

		part.Size = Vector3.new(Bolt.SIZE * 1.3, Bolt.SIZE * 1.3, Bolt.SIZE * 1.3)
		part.Transparency = 0.05
		trail.Color = spectrum
		trail.WidthScale = Bolt.SPELL_WIDTH
		trail.Transparency = Bolt.SPELL_FADE
		glow.Brightness = 3.2
		glow.Range = 14

		local emitter = Bolt.Sparks(part)
		emitter.Color = spectrum
		emitter.Enabled = true
		return
	end

	if style == "arcane" then
		local spectrum = Bolt.Spectrum(color)

		part.Transparency = 0.25
		trail.Color = spectrum
		trail.WidthScale = Bolt.ARCANE_WIDTH
		trail.Transparency = Bolt.ARCANE_FADE
		glow.Brightness = 2.6

		local emitter = Bolt.Motes(part)
		emitter.Color = spectrum
		emitter.Enabled = true
		return
	end

	part.Transparency = 0
	trail.Color = ColorSequence.new(color)
	trail.WidthScale = Bolt.TRAIL_WIDTH
	trail.Transparency = Bolt.TRAIL_FADE
	glow.Brightness = 2.2
end

function Bolt.Reticle(view, groundPos, color, delay)
	local _, reticle = Bolt.Ensure(view)

	reticle.Color = color
	reticle.CFrame = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90))
	reticle.Size = Vector3.new(0.15, Bolt.RETICLE_SPAN * 1.7, Bolt.RETICLE_SPAN * 1.7)
	reticle.Transparency = 0.25

	TweenService:Create(reticle, TweenInfo.new(math.max(delay, 0.08), Enum.EasingStyle.Quad), {
		Size = Vector3.new(0.15, Bolt.RETICLE_SPAN, Bolt.RETICLE_SPAN),
		Transparency = 0.1,
	}):Play()

	task.delay(delay + Bolt.RETICLE_HOLD, function()
		if not reticle.Parent then return end
		TweenService:Create(reticle, TweenInfo.new(0.2), {
			Size = Vector3.new(0.15, Bolt.RETICLE_SPAN * 1.35, Bolt.RETICLE_SPAN * 1.35),
			Transparency = 1,
		}):Play()
	end)
end

function Bolt.Launch(view, fromPos, toPos, color, speed, style)
	local part = Bolt.Ensure(view)
	local trail, glow = view.boltTrail, view.boltGlow
	local travel = math.clamp((toPos - fromPos).Magnitude / (speed or Bolt.SPEED),
		Bolt.MIN_TIME, Bolt.MAX_TIME)

	part.Color = color
	part.CFrame = CFrame.new(fromPos)

	if trail then trail.Enabled = false end
	if glow then
		glow.Color = color
		glow.Enabled = true
	end

	Bolt.ApplyStyle(part, trail, glow, color, style)

	task.defer(function()
		if trail and trail.Parent then trail.Enabled = true end
	end)

	local tween = TweenService:Create(part, TweenInfo.new(travel, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(toPos),
	})
	tween:Play()
	tween.Completed:Once(function()
		if part.Parent then part.Transparency = 1 end
		if trail and trail.Parent then trail.Enabled = false end
		if glow and glow.Parent then glow.Enabled = false end
		if part.Parent then Bolt.Quiet(part) end
	end)

	return travel
end

-- Bolinha de energia viajando do atacante até o alvo + retícula no impacto,
-- pra deixar ataques à distância (Ranged) mais perceptíveis. A Wren é a exceção:
-- o tiro dela é o tracejante montado no place (ver Bolt.Tracer, lá embaixo, ao
-- lado do carregador de VFX que ele precisa).
-- ===== O TRACEJANTE DA WREN =====
-- O tiro dela deixou de ser a bolinha genérica e passou a ser o risco montado à
-- mão em ReplicatedStorage.VFX.Wren.Bullet_Tracer — oito esferas neon esticadas,
-- ~16 studs de comprimento, sem emissor e sem animação própria. Quem anima é
-- daqui: o risco cruza o tabuleiro e some.
--
-- ELE MORA NO EIXO Z. O modelo é fino em X e Y e comprido em Z, e o pivô dele
-- já está alinhado com esse comprimento (foi assim que a caixa envolvente saiu
-- 0.74 x 0.74 x 16.30). Por isso `CFrame.lookAt` basta pra apontar: o risco cai
-- em cima da linha do tiro sem correção de rotação nenhuma.
--
-- ANDA SOLDADO, não peça por peça. O PrepareVfx ancora tudo; aqui a primeira
-- peça vira o boneco que o tween move e as outras sete soltam a âncora e
-- acompanham por WeldConstraint. É o mesmo arranjo da bolha da Kira, e é o que
-- evita um laço por quadro pra reposicionar oito peças.
local WREN_TRACER_HOME = { "VFX", "Wren", "Bullet_Tracer" }

function Bolt.Tracer(view, fromPos, toPos, travel)
	local template = VfxLibrary.Template(WREN_TRACER_HOME, "o tiro da Wren sai com a bolinha generica")
	if not template then return false end

	local _, size = template:GetBoundingBox()
	local tracer = template:Clone()

	-- parenteia ANTES de posicionar e soldar: mesma ordem do AttachObjectModel e
	-- da bolha da Kira, que é a que engata a solda
	tracer.Parent = view.heroesFolder

	-- Meio comprimento pra trás: quem chega na casa do alvo é a PONTA do risco,
	-- não o meio dele. O `+Z` é o que sobra atrás no lookAt (a frente dele é -Z).
	local aim = CFrame.lookAt(fromPos, toPos)
	local tail = CFrame.new(0, 0, size.Z / 2)
	tracer:PivotTo(aim * tail)

	local root = tracer:FindFirstChildWhichIsA("BasePart", true)
	if not root then
		tracer:Destroy()
		return false
	end

	for _, piece in ipairs(tracer:GetDescendants()) do
		if piece:IsA("BasePart") and piece ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = piece
			weld.Parent = root
			piece.Anchored = false
		end
	end

	-- A direção não muda no caminho, só a posição: o destino é o mesmo risco
	-- deslocado pelo vetor do tiro. Translação pura, sem remontar CFrame nenhum.
	TweenService:Create(root, TweenInfo.new(travel, Enum.EasingStyle.Linear), {
		CFrame = root.CFrame + (toPos - fromPos),
	}):Play()

	Debris:AddItem(tracer, travel + 0.15)
	return true
end


return Bolt
