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

-- '#' = pixel aceso, '.' = vazio. Todas as linhas de um ícone têm que ter o
-- mesmo comprimento — a largura sai da primeira.
PixelIcons.PATTERNS = {
	-- Espada na diagonal, ponta no canto superior direito.
	--
	-- Em pé ela virava uma cruz: a guarda horizontal no meio de uma lâmina
	-- vertical é literalmente o desenho de uma cruz, e nenhum ajuste de altura
	-- resolvia. Na diagonal o problema some — a lâmina inclinada não tem como
	-- ser confundida com outra coisa, e a guarda vira uma diagonal na direção
	-- contrária, cruzando a lâmina num X curto.
	--
	--   lâmina:  (1,6)(1,7) até (5,2)(5,3)
	--   guarda:  (4,1) (5,2) (6,3)   — perpendicular à lâmina
	--   punho:   (6,1)                — segue o eixo pra baixo-esquerda
	--   pomo:    (7,1)(7,2)
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

	-- TAUNT: três fiadas separadas por linhas de argamassa vazias, com as juntas
	-- verticais alternando entre elas.
	--
	-- A primeira versão só tinha as juntas verticais, sem as linhas horizontais:
	-- o tijolo tomava quase o ícone inteiro e as juntas viravam furos soltos —
	-- de longe lia como a face de um dado. São as faixas vazias horizontais que
	-- fazem o olho enxergar fiadas empilhadas.
	taunt = {
		"###.###",
		"###.###",
		".......",
		"#.###.#",
		"#.###.#",
		".......",
		"###.###",
	},

	-- SPRINT: bota (cano nas colunas 4-5, pé abrindo pra direita) com uma asa
	-- triangular no tornozelo, à esquerda.
	--
	-- As duas primeiras tentativas usaram traços soltos de velocidade à
	-- esquerda: no tamanho real eles viravam pontinhos avulsos e sobrava um "L".
	-- A asa como triângulo cheio, colada na altura do tornozelo e separada da
	-- bota por uma coluna vazia, é o que faz ler "bota alada" e não "letra".
	sprint = {
    "...##..",
    "..####.",
    "..####.",
    "..##...",
    "..##...",
    "######.",
    "######.",
  },

	-- Bandeira de rendição: mastro na coluna 1 descendo inteiro, e o pano
	-- ondulado à direita. A borda irregular é o que separa de um retângulo
	-- qualquer no tamanho real.
	flag = {
		"######.",
		"#####..",
		"######.",
		"#####..",
		"#......",
		"#......",
		"#......",
	},

	-- GELO: floco de neve — os três eixos (vertical, horizontal e as duas
	-- diagonais) cruzando no centro. É o desenho que mais aguenta o tamanho do
	-- crachá: mesmo virando uma estrelinha de longe, ninguém confunde com espada
	-- ou coração.
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

	-- AGILITY: duas setas apontando pra frente, uma atrás da outra — o segundo
	-- passo do turno desenhado. Duas pontas em vez de uma é o que separa do
	-- sprint (bota), que já ocupa a ideia de "anda mais".
	agility = {
		"#..#...",
		"##.##..",
		"###.###",
		"#######",
		"###.###",
		"##.##..",
		"#..#...",
	},

	-- RANGED: círculo com os quatro traços e o ponto no centro
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

-- [nome] = "rbxassetid://..." para trocar o desenho por uma imagem
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

-- Monta o ícone dentro de `parent`, preenchendo o espaço todo dele.
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

	-- Sequências horizontais viram UM Frame em vez de um por pixel. O coração
	-- sozinho tem 30 pixels acesos; com seis heróis em campo seriam 180 Frames
	-- só de coração. Agrupando, cai para 7 por ícone — e o desenho na tela é
	-- exatamente o mesmo.
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

-- Recolore sem remontar: o buff de ataque troca a cor a cada turno.
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

