--[[
	PixelIcons.lua
	ModuleScript — ReplicatedStorage/Modules/PixelIcons

	Ícones de pixel art desenhados em tempo de execução, sem depender de asset
	nenhum: cada um é um mapa 7x7 de texto que vira Frames.

	POR QUE DESENHAR EM VEZ DE USAR IMAGEM
	O Roblox não traz ícone de espada, coração, muro, bota ou mira, e inventar
	id de asset é receita para quadrado cinza no lugar do ícone. Desenhando aqui,
	o crachá funciona no primeiro play, sem upload e sem nada para configurar.

	QUANDO ENTRAREM SPRITES DE VERDADE
	Cole o id em ASSETS e pronto — o Build passa a usar a imagem e ignora o
	desenho. Nenhum outro arquivo muda. É a mesma ponte que o HeroData já usa
	para a folha de heróis.

	Sete por sete é o menor tamanho em que espada, coração e mira ainda se
	distinguem no crachá embaixo do herói. Abaixo disso viram manchas iguais.
]]

local PixelIcons = {}

PixelIcons.PATTERNS = {
	sword = {
		".....##",
		"....##.",
		"...##..",
		"#.##...",
		".##....",
		"#.#....",
		"##.....",
	},

	heart = {
		".##.##.",
		"#######",
		"#######",
		"#######",
		".#####.",
		"..###..",
		"...#...",
	},

	taunt = {
		"###.###",
		"###.###",
		".......",
		"#.###.#",
		"#.###.#",
		".......",
		"###.###",
	},

	sprint = {
    "...##..",
    "..####.",
    "..####.",
    "..##...",
    "..##...",
    "######.",
    "######.",
  },

	flag = {
		"######.",
		"#####..",
		"######.",
		"#####..",
		"#......",
		"#......",
		"#......",
	},

	freeze = {
		"#..#..#",
		".#.#.#.",
		"..###..",
		"#######",
		"..###..",
		".#.#.#.",
		"#..#..#",
	},

	book = {
		"#######",
		"#.#...#",
		"#.#.#.#",
		"#.#...#",
		"#.#.#.#",
		"#.#...#",
		"#######",
	},

	agility = {
		"#..#...",
		"##.##..",
		"###.###",
		"#######",
		"###.###",
		"##.##..",
		"#..#...",
	},

	ranged = {
		"...#...",
		".##.##.",
		".#...#.",
		"##.#.##",
		".#...#.",
		".##.##.",
		"...#...",
	},
}

PixelIcons.ASSETS = {}

local function BuildImage(holder, assetId, color)
	local image = Instance.new("ImageLabel")
	image.Name = "Sprite"
	image.Size = UDim2.fromScale(1, 1)
	image.BackgroundTransparency = 1
	image.Image = assetId
	image.ImageColor3 = color
	image.ScaleType = Enum.ScaleType.Fit
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.ZIndex = holder.ZIndex
	image.Parent = holder
end

function PixelIcons.Build(name, parent, color, zIndex)
	local holder = Instance.new("Frame")
	holder.Name = "Icon"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = zIndex or 2
	holder.Parent = parent

	local assetId = PixelIcons.ASSETS[name]
	if assetId and assetId ~= "" then
		BuildImage(holder, assetId, color)
		return holder
	end

	local pattern = PixelIcons.PATTERNS[name]
	if not pattern then
		warn("PixelIcons: ícone desconhecido: " .. tostring(name))
		return holder
	end

	local rows = #pattern
	local cols = #pattern[1]

	for y = 1, rows do
		local line = pattern[y]
		local x = 1

		while x <= cols do
			if line:sub(x, x) == "#" then
				local runStart = x
				repeat
					x += 1
				until x > cols or line:sub(x, x) ~= "#"

				local run = Instance.new("Frame")
				run.Name = ("Run%d_%d"):format(y, runStart)
				run.BorderSizePixel = 0
				run.BackgroundColor3 = color
				run.Size = UDim2.fromScale((x - runStart) / cols, 1 / rows)
				run.Position = UDim2.fromScale((runStart - 1) / cols, (y - 1) / rows)
				run.ZIndex = holder.ZIndex
				run.Parent = holder
			else
				x += 1
			end
		end
	end

	return holder
end

function PixelIcons.SetColor(holder, color)
	if not holder then return end

	for _, child in ipairs(holder:GetChildren()) do
		if child:IsA("ImageLabel") then
			child.ImageColor3 = color
		elseif child:IsA("Frame") then
			child.BackgroundColor3 = color
		end
	end
end

return PixelIcons

