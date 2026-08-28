local LobbyZones = require(script.Parent.LobbyZones)

local Arenas = {}

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"

Arenas.THEMES = {
	{
		id = "clareira",
		group = 1,
		name = "Clareira Verde",
		master = nil,
		music = "MusicClareira",
		tiles = { a = Color3.fromRGB(126, 134, 96), b = Color3.fromRGB(88, 100, 70) },
		clockTime = 13.2,
		contrast = 0.10,
		saturation = 0.16,
		ground = { color = Color3.fromRGB(104, 152, 84), material = Enum.Material.Grass },
		trim = { color = Color3.fromRGB(78, 104, 62), material = Enum.Material.LeafyGrass },
		backdrop = {
			style = "cliff",
			color = Color3.fromRGB(96, 108, 80),
			material = Enum.Material.Rock,
			height = 20,
		},
		props = {
			{ kind = "tree", count = 8, trunk = Color3.fromRGB(88, 62, 40), leaf = Color3.fromRGB(76, 132, 62), material = Enum.Material.Grass },
			{ kind = "bush", count = 9, color = Color3.fromRGB(86, 146, 70), material = Enum.Material.LeafyGrass },
			{ kind = "rock", count = 6, color = Color3.fromRGB(112, 118, 98), material = Enum.Material.Rock },
		},
		particles = {
			texture = SPARK,
			color = Color3.fromRGB(226, 244, 176),
			rate = 10,
			size = 1.1,
			speed = 1.6,
			lifetime = 7,
			transparency = 0.55,
			drift = Vector3.new(2, 0.6, 0),
		},
		lights = {
			{ class = "PointLight", color = Color3.fromRGB(255, 244, 214), brightness = 1.1, range = 82, height = 30 },
		},
		object = {
			label = "Toco",
			hitSound = "WoodHit",
			breakSound = "WoodBreak",
			part = {
				size = Vector3.new(4.6, 4.4, 4.6),
				color = Color3.fromRGB(112, 78, 48),
				material = Enum.Material.Wood,
				shape = Enum.PartType.Cylinder,
			},
			dust = Color3.fromRGB(196, 150, 96),
		},
		objectHexes = { "B4", "D4" },
	},

	{
		id = "bosque",
		group = 2,
		name = "Bosque Sombrio",
		master = nil,
		music = "MusicBosque",
		tiles = { a = Color3.fromRGB(128, 120, 138), b = Color3.fromRGB(90, 84, 102) },
		clockTime = 15.4,
		contrast = 0.10,
		saturation = 0.02,
		ambient = Color3.fromRGB(66, 60, 82),
		outdoorAmbient = Color3.fromRGB(128, 120, 156),
		brightness = 2.3,
		ground = { color = Color3.fromRGB(78, 74, 90), material = Enum.Material.Ground },
		trim = { color = Color3.fromRGB(46, 42, 54), material = Enum.Material.Slate },
		backdrop = {
			style = "cliff",
			color = Color3.fromRGB(48, 44, 58),
			material = Enum.Material.Slate,
			height = 26,
		},
		atmosphere = { Density = 0.28, Haze = 1.4, Color = Color3.fromRGB(150, 142, 176), Decay = Color3.fromRGB(74, 68, 96) },
		props = {
			{ kind = "deadTree", count = 10, trunk = Color3.fromRGB(56, 48, 52), material = Enum.Material.Wood },
			{ kind = "rock", count = 6, color = Color3.fromRGB(70, 66, 80), material = Enum.Material.Slate },
			{ kind = "bush", count = 5, color = Color3.fromRGB(58, 62, 58), material = Enum.Material.Grass },
		},
		particles = {
			texture = SMOKE,
			color = Color3.fromRGB(150, 138, 178),
			rate = 8,
			size = 9,
			speed = 0.8,
			lifetime = 10,
			transparency = 0.86,
			drift = Vector3.new(1.2, 0.2, 0),
		},
		lights = {
			{ class = "PointLight", color = Color3.fromRGB(186, 180, 235), brightness = 2.6, range = 100, height = 30 },
			{ class = "PointLight", color = Color3.fromRGB(120, 220, 170), brightness = 1.1, range = 38, height = 8, offset = Vector3.new(-26, 0, -20) },
		},
		object = {
			label = "Tronco Podre",
			hitSound = "WoodHit",
			breakSound = "WoodBreak",
			part = {
				size = Vector3.new(4.8, 4.6, 4.8),
				color = Color3.fromRGB(64, 54, 58),
				material = Enum.Material.Wood,
				shape = Enum.PartType.Cylinder,
			},
			dust = Color3.fromRGB(140, 128, 160),
		},
		objectHexes = { "A3", "A4", "E3", "E4" },
	},

	{
		id = "geleira",
		group = 3,
		name = "Geleira",
		master = nil,
		music = "MusicGeleira",
		tiles = { a = Color3.fromRGB(170, 190, 210), b = Color3.fromRGB(124, 146, 170) },
		clockTime = 10.4,
		contrast = 0.14,
		saturation = 0.10,
		exposure = -0.2,
		ambient = Color3.fromRGB(76, 88, 102),
		outdoorAmbient = Color3.fromRGB(148, 168, 188),
		brightness = 1.7,
		tint = Color3.fromRGB(240, 246, 252),
		atmosphere = { Density = 0.30, Haze = 1.4, Color = Color3.fromRGB(206, 222, 238), Decay = Color3.fromRGB(132, 158, 184) },
		ground = { color = Color3.fromRGB(202, 218, 232), material = Enum.Material.Snow },
		trim = { color = Color3.fromRGB(158, 186, 208), material = Enum.Material.Ice },
		backdrop = {
			style = "cliff",
			color = Color3.fromRGB(172, 198, 218),
			material = Enum.Material.Glacier,
			height = 28,
		},
		props = {
			{ kind = "crystal", count = 9, color = Color3.fromRGB(168, 214, 240), material = Enum.Material.Ice, transparency = 0.25 },
			{ kind = "drift", count = 10, color = Color3.fromRGB(240, 248, 255), material = Enum.Material.Snow },
			{ kind = "rock", count = 5, color = Color3.fromRGB(200, 216, 230), material = Enum.Material.Glacier },
		},
		particles = {
			texture = SPARK,
			color = Color3.fromRGB(240, 250, 255),
			rate = 26,
			size = 0.9,
			speed = 3,
			lifetime = 9,
			transparency = 0.4,
			drift = Vector3.new(3, -6, 1),
		},
		lights = {
			{ class = "PointLight", color = Color3.fromRGB(206, 226, 246), brightness = 0.7, range = 76, height = 32 },
		},
		object = {
			label = "Cristal Congelado",
			hitSound = "IceHit",
			breakSound = "IceBreak",
			asset = 8605652118,
			height = 5.6,
			skin = {
				color = Color3.fromRGB(176, 220, 244),
				material = Enum.Material.Ice,
				transparency = 0.15,
				reflectance = 0.22,
			},
			-- reserva de quando o asset não carrega (sem permissão, sem rede)
			part = {
				size = Vector3.new(4.6, 5.6, 4.6),
				color = Color3.fromRGB(184, 224, 246),
				material = Enum.Material.Ice,
				transparency = 0.2,
				reflectance = 0.15,
			},
			dust = Color3.fromRGB(226, 244, 255),
		},
		objectHexes = { "A2", "A5", "E2", "E5" },
	},

	{
		id = "forja",
		group = 4,
		name = "Forja de Brasa",
		master = nil,
		music = "MusicForja",
		tiles = { a = Color3.fromRGB(132, 100, 84), b = Color3.fromRGB(92, 70, 58) },
		clockTime = 18.3,
		contrast = 0.14,
		saturation = 0.12,
		exposure = 0.06,
		ambient = Color3.fromRGB(76, 52, 42),
		outdoorAmbient = Color3.fromRGB(150, 110, 86),
		brightness = 2.4,
		ground = { color = Color3.fromRGB(68, 56, 54), material = Enum.Material.Basalt },
		trim = { color = Color3.fromRGB(44, 36, 35), material = Enum.Material.Slate },
		backdrop = {
			style = "cliff",
			color = Color3.fromRGB(52, 42, 40),
			material = Enum.Material.Basalt,
			height = 30,
		},
		props = {
			{ kind = "pillar", count = 7, color = Color3.fromRGB(58, 48, 46), material = Enum.Material.Basalt },
			{ kind = "rock", count = 7, color = Color3.fromRGB(46, 38, 36), material = Enum.Material.Rock },
			{ kind = "brazier", count = 4, color = Color3.fromRGB(255, 150, 60), material = Enum.Material.Metal },
			{ kind = "lava", count = 4, color = Color3.fromRGB(255, 108, 36), material = Enum.Material.Neon },
		},
		particles = {
			texture = SPARK,
			color = Color3.fromRGB(255, 166, 82),
			rate = 18,
			size = 0.8,
			speed = 5,
			lifetime = 6,
			transparency = 0.35,
			drift = Vector3.new(1.5, 7, 0),
		},
		lights = {
			{ class = "PointLight", color = Color3.fromRGB(255, 158, 84), brightness = 1.5, range = 84, height = 26 },
		},
		object = {
			label = "Rocha de Brasa",
			hitSound = "StoneHit",
			breakSound = "StoneBreak",
			part = {
				size = Vector3.new(4.8, 4.6, 4.8),
				color = Color3.fromRGB(58, 44, 42),
				material = Enum.Material.CrackedLava,
			},
			dust = Color3.fromRGB(255, 150, 80),
		},
		objectHexes = { "B2", "B6", "D2", "D6" },
	},

	{
		id = "santuario",
		group = 5,
		name = "Santuário de Brasa",
		master = nil,
		music = "MusicSantuario",
		tiles = { a = Color3.fromRGB(198, 172, 136), b = Color3.fromRGB(152, 126, 96) },
		clockTime = 16.6,
		contrast = 0.10,
		saturation = 0.12,
		ground = { color = Color3.fromRGB(178, 148, 122), material = Enum.Material.Sand },
		trim = { color = Color3.fromRGB(146, 116, 94), material = Enum.Material.Sandstone },
		backdrop = {
			style = "wall",
			color = Color3.fromRGB(158, 126, 100),
			material = Enum.Material.Sandstone,
			height = 24,
		},
		props = {
			{ kind = "pillar", count = 8, color = Color3.fromRGB(196, 170, 142), material = Enum.Material.Sandstone },
			{ kind = "brazier", count = 4, color = Color3.fromRGB(255, 196, 120), material = Enum.Material.Metal },
			{ kind = "rock", count = 5, color = Color3.fromRGB(162, 132, 108), material = Enum.Material.Sandstone },
			{ kind = "bush", count = 3, color = Color3.fromRGB(126, 132, 92), material = Enum.Material.Grass },
		},
		particles = {
			texture = SMOKE,
			color = Color3.fromRGB(236, 206, 168),
			rate = 6,
			size = 6,
			speed = 1.2,
			lifetime = 9,
			transparency = 0.88,
			drift = Vector3.new(2, 1.4, 0),
		},
		lights = {
			{ class = "PointLight", color = Color3.fromRGB(255, 226, 186), brightness = 1.2, range = 80, height = 28 },
		},
		object = {
			label = "Urna",
			hitSound = "ClayHit",
			breakSound = "ClayBreak",
			part = {
				size = Vector3.new(4.4, 5, 4.4),
				color = Color3.fromRGB(198, 168, 138),
				material = Enum.Material.Sandstone,
				shape = Enum.PartType.Cylinder,
			},
			dust = Color3.fromRGB(230, 202, 166),
		},
		objectHexes = { "B4", "C3", "C4", "D4" },
	},
}

function Arenas.ById(id)
	for _, theme in ipairs(Arenas.THEMES) do
		if theme.id == id then return theme end
	end
	return nil
end

function Arenas.ForGroup(group)
	for _, theme in ipairs(Arenas.THEMES) do
		if theme.group == group then return theme end
	end
	return nil
end

function Arenas.Random()
	return Arenas.THEMES[math.random(1, #Arenas.THEMES)]
end

function Arenas.ForMatch(fight)
	local theme = fight and Arenas.ForGroup(fight.group)
	return theme or Arenas.Random()
end

function Arenas.PaletteOf(id)
	local theme = Arenas.ById(id)
	if not theme then return nil end

	local zone = LobbyZones.ForGroup(theme.group)
	local ambience = zone and zone.ambience or {}

	return {
		Ambient = theme.ambient or ambience.Ambient,
		OutdoorAmbient = theme.outdoorAmbient or ambience.OutdoorAmbient,
		Brightness = theme.brightness or ambience.Brightness,
		Atmosphere = theme.atmosphere or ambience.Atmosphere,
		Tint = theme.tint or ambience.Tint,
		ClockTime = theme.clockTime,
		Exposure = theme.exposure,
		Contrast = theme.contrast,
		Saturation = theme.saturation,
	}
end

return Arenas
