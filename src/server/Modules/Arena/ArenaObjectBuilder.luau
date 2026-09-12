local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local InsertService = game:GetService("InsertService")
local ServerScriptService = game:GetService("ServerScriptService")

local Arenas = require(ReplicatedStorage.Modules.Arenas)
local ViewStyle = require(ServerScriptService.Modules.View.ViewStyle)
local MatchAudio = require(ServerScriptService.Modules.View.MatchAudio)

local ArenaObjectBuilder = {}

-- ===== BARRIL =====
-- O asset (130205426920176) é um Model com um MeshPart dentro. Aqui ele é
-- remontado como Part + SpecialMesh a partir da malha e da textura dele: assim o
-- barril nasce por código, versionado junto com o resto, sem depender de um
-- modelo guardado no place — que não entra no Rojo nem no git.
--
-- A malha nasce com ~3,0 x 3,6 studs. A casa mede ~9,8 de ponta a ponta e o
-- herói desenhado tem ~8 de altura: sem ampliar, o barril viraria um pontinho no
-- meio do hexágono. 1,45 deixa ele com pouco mais de 5 de altura — objeto de
-- cenário que dá pra acertar, sem competir com o herói.
local BARREL_MESH = "rbxassetid://119956806509588"
local BARREL_TEXTURE = "rbxassetid://137018550249951"
local BARREL_NATIVE = Vector3.new(3.011, 3.583, 3.011)
local BARREL_SCALE = 1.45

local BARREL_DUST = ViewStyle.DUST

-- O objeto neutro muda de cara com a arena (ver Arenas): barril na clareira,
-- bloco de gelo na geleira, urna no santuário. A REGRA é a mesma — mesma
-- contagem de golpes, mesma casa ocupada, mesmo prêmio. Sem tema (simulação de
-- balanceamento, partida antiga) cai no barril de sempre.
local function ObjectSpec(view)
	return view and view.theme and view.theme.object or nil
end

-- Asset do catálogo, carregado UMA vez e guardado fora da DataModel pra ser
-- clonado a cada objeto. Antes eu só extraía MeshId/textura pra remontar como
-- Part + SpecialMesh, e isso só funciona pra asset que É uma malha: o cristal
-- do gelo é um Model de Parts, então não sobrava nada e o tema caía no cubo de
-- reserva. Agora vale qualquer modelo — Part, Union ou MeshPart.
--
-- Falhou o carregamento (asset privado, sem rede), o tema usa o `part` de
-- reserva e a partida segue: objeto invisível no tabuleiro seria bem pior.
local assetModelCache = {}

-- O que separa "achei alguma coisa" de "tenho um molde": embrulha BasePart solta
-- num Model (pro resto do código só existir uma forma), recusa o que não tem
-- geometria nenhuma e estaciona o molde FORA da DataModel.
--
-- Vale pras duas origens de objeto — o modelo do catálogo e o montado à mão no
-- place —, e é por isso que a limpeza de scripts mora aqui: modelo grátis é o
-- vetor de backdoor mais antigo do Roblox, e este código roda no SERVIDOR. Um
-- modelo do próprio place não é código de terceiro, mas passar pela mesma peneira
-- não custa nada e tira a pergunta de cima da mesa.
local function PrepareTemplate(found)
	if found and found:IsA("BasePart") then
		local wrapper = Instance.new("Model")
		found.Parent = wrapper
		found = wrapper
	end

	if not (found and found:FindFirstChildWhichIsA("BasePart", true)) then return nil end

	for _, descendant in ipairs(found:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then descendant:Destroy() end
	end

	-- Parent nil, e não Destroy: o molde segue vivo pela referência do cache,
	-- fora da árvore, sem replicar pra ninguém.
	found.Parent = nil
	return found
end

local function ModelFromAsset(assetId)
	if assetModelCache[assetId] ~= nil then
		return assetModelCache[assetId] or nil
	end

	local ok, container = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)

	local template = false
	if ok and container then
		template = PrepareTemplate(
			container:FindFirstChildWhichIsA("Model") or container:FindFirstChildWhichIsA("BasePart")
		) or false
		container:Destroy()
	end

	if not template then
		warn(("ArenaObjectBuilder: nao consegui carregar o modelo do asset %s — objeto do board no visual de reserva.")
			:format(tostring(assetId)))
	end

	assetModelCache[assetId] = template
	return template or nil
end

-- Objeto MONTADO À MÃO no place, em vez de vindo do catálogo. Mesma fronteira do
-- resto do cenário Studio-owned (o LobbyTrail, os pads, os Sounds): o Rojo não
-- versiona aquilo, então o tema guarda só o CAMINHO relativo ao Workspace
-- ("Objects.MeshPart") e quem resolve é aqui.
--
-- CLONA em vez de adotar: o que está no place é a fonte, e ela continua lá,
-- intocada, pra ser editada no Explorer. Arrancá-la pra dentro do cache faria o
-- objeto sumir do cenário no primeiro combate.
local instanceModelCache = {}

local function ModelFromInstance(path)
	if instanceModelCache[path] ~= nil then
		return instanceModelCache[path] or nil
	end

	local node = Workspace
	for name in path:gmatch("[^%.]+") do
		node = node and node:FindFirstChild(name)
	end

	local template = node and PrepareTemplate(node:Clone()) or false
	if not template then
		warn(("ArenaObjectBuilder: nao achei Workspace.%s (ou ele nao tem geometria) — objeto do board no visual de reserva.")
			:format(path))
	end

	instanceModelCache[path] = template
	return template or nil
end

local function TemplateVisual(template, height, skin, rotation)
	if not template then return nil end

	local extents = template:GetExtentsSize()
	local scale = height and (height / math.max(extents.Y, 0.001)) or 1
	return {
		model = template,
		scale = scale,
		size = extents * scale,
		skin = skin,
		rotation = rotation,
	}
end

local function FinishVisual(visual, sourceSpec)
	if not visual then return nil end

	visual.rotationX = sourceSpec.rotationX
	visual.rotationZ = sourceSpec.rotationZ

	return visual
end

local function ObjectVisual(view)
	local spec = ObjectSpec(view)
	if not spec then return nil end

	local visual

	if spec.instance then
		visual = FinishVisual(
			TemplateVisual(ModelFromInstance(spec.instance), spec.height, spec.skin, spec.rotation),
			spec
		)
		if visual then return visual end
	end

	if spec.asset then
		visual = FinishVisual(
			TemplateVisual(ModelFromAsset(spec.asset), spec.height, spec.skin, spec.rotation),
			spec
		)
		if visual then return visual end
	end

	local fallback = Arenas.DEFAULT_OBJECT

	if fallback and fallback.asset then
		visual = TemplateVisual(
			ModelFromAsset(fallback.asset),
			spec.height or fallback.height,
			spec.skin or fallback.skin,
			spec.rotation or fallback.rotation
		)

		if visual then
			visual.rotationX = spec.rotationX or fallback.rotationX
			visual.rotationZ = spec.rotationZ or fallback.rotationZ
			return visual
		end
	end

	if spec.mesh then
		return { mesh = spec.mesh }
	end

	if spec.part then
		return { part = spec.part }
	end

	return nil
end

function ArenaObjectBuilder.Size(view)
	local visual = ObjectVisual(view)
	if visual then
		if visual.model then return visual.size end
		if visual.mesh then return visual.mesh.native * visual.mesh.scale end
		if visual.part then return visual.part.size end
	end
	return BARREL_NATIVE * BARREL_SCALE
end

function ArenaObjectBuilder.Dust(view)
	local spec = ObjectSpec(view)
	return spec and spec.dust or BARREL_DUST
end

-- Gelo não estala como madeira. O tema pede o som pelo NOME, e o nome tem que
-- existir em ReplicatedStorage.Sounds — os áudios são do place, como todos os
-- outros. Faltando, cai no som do barril e avisa UMA vez por nome: silêncio
-- seria pior, e um aviso por pancada seria spam.
local warnedSounds = {}

function ArenaObjectBuilder.SoundName(view, key, fallback)
	local spec = ObjectSpec(view)
	local name = spec and spec[key]
	if not name then return fallback end

	if MatchAudio.Exists(name) then return name end

	if not warnedSounds[name] then
		warnedSounds[name] = true
		warn(("ArenaObjectBuilder: som '%s' nao existe em ReplicatedStorage.Sounds — usando '%s'.")
			:format(name, fallback))
	end

	return fallback
end

local function IsLyingCylinder(view)
	local visual = ObjectVisual(view)
	return visual ~= nil and visual.part ~= nil and visual.part.shape == Enum.PartType.Cylinder
end

function ArenaObjectBuilder.CFrameAt(view, hexId)
	local size = ArenaObjectBuilder.Size(view)
	local base = ViewStyle.GroundCFrame(hexId, view.origin) * CFrame.new(0, size.Y / 2, 0)

	-- Part cilíndrica do Roblox nasce deitada no eixo X: a rotação entra na CFrame
	-- BASE pra sobreviver aos tweens de pancada.
	if IsLyingCylinder(view) then
		base = base * CFrame.Angles(0, 0, math.rad(90))
	end

	return base
end

-- Modelo de catálogo vem com a aparência de quem o publicou — o cristal do gelo
-- é uma Union PRETA, e Union ignora Color enquanto UsePartColor for falso. Aqui
-- ele veste a pele do tema: cor, material e brilho do gelo, sem textura de
-- terceiro por cima. Sem `skin` no tema, o modelo fica como veio.
local function PaintSkin(part, skin)
	if part:IsA("UnionOperation") then part.UsePartColor = true end
	if part:IsA("MeshPart") then part.TextureID = "" end

	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("SurfaceAppearance") or child:IsA("Decal") then child:Destroy() end
	end

	if skin.color then part.Color = skin.color end
	if skin.material then part.Material = skin.material end
	part.Transparency = skin.transparency or 0
	part.Reflectance = skin.reflectance or 0
end

-- O modelo do asset vira FILHO da caixa: as peças dele ficam sem âncora e
-- soldadas nela, que é o que faz o conjunto inteiro acompanhar os tweens de
-- pancada (a caixa é a raiz ancorada da montagem). Sem colisão e sem query: quem
-- recebe o clique é a caixa, senão o golpe acertaria uma quina do cristal e o
-- cliente não acharia o BarrelUid.
local function AttachObjectModel(part, visual)
	local model = visual.model:Clone()

	model.Name = "ObjectModel"
	model.Parent = part

	if math.abs(visual.scale - 1) > 0.01 then
		model:ScaleTo(visual.scale)
	end

	local anchor = part.CFrame

	-- Mantém a rotação Y que o sistema já utilizava.
	if visual.rotation then
		anchor = anchor * CFrame.Angles(0, math.rad(visual.rotation), 0)
	end

	-- Primeiro posiciona o modelo normalmente.
	local boxCFrame = model:GetBoundingBox()

	model:PivotTo((anchor * boxCFrame:Inverse()) * model:GetPivot())

	-- Depois aplica a correção de orientação diretamente
	-- no pivot do ObjectModel.
	local rotationX = visual.rotationX or 0
	local rotationZ = visual.rotationZ or 0

	if rotationX ~= 0 or rotationZ ~= 0 then
		model:PivotTo(model:GetPivot() * CFrame.Angles(math.rad(rotationX), 0, math.rad(rotationZ)))
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CastShadow = false

			if visual.skin then
				PaintSkin(descendant, visual.skin)
			end

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = part
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	return model
end

function ArenaObjectBuilder.Spawn(view, hexId, name)
	local visual = ObjectVisual(view)
	local size = ArenaObjectBuilder.Size(view)

	local part = Instance.new("Part")
	part.Name = name
	-- A caixa é o que recebe o clique. Na arena que usa MALHA é ela quem aparece:
	-- NÃO adianta pôr Transparency em 1 achando que esconde só o bloco — com
	-- SpecialMesh a transparência vale pro desenho todo e o objeto some.
	part.Size = IsLyingCylinder(view) and Vector3.new(size.Y, size.X, size.Z) or size
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CFrame = ArenaObjectBuilder.CFrameAt(view, hexId)

	if visual and visual.model then
		part.Transparency = 1
		AttachObjectModel(part, visual)
	elseif visual and visual.part then
		part.Shape = visual.part.shape or Enum.PartType.Block
		part.Color = visual.part.color
		part.Material = visual.part.material
		part.Transparency = visual.part.transparency or 0
		part.Reflectance = visual.part.reflectance or 0
	else
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = (visual and visual.mesh and visual.mesh.id) or BARREL_MESH
		mesh.TextureId = (visual and visual.mesh and visual.mesh.texture) or BARREL_TEXTURE
		local scale = (visual and visual.mesh and visual.mesh.scale) or BARREL_SCALE
		mesh.Scale = Vector3.new(scale, scale, scale)
		mesh.Parent = part
	end

	return part
end

return ArenaObjectBuilder
