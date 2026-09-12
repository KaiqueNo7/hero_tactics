local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VfxLibrary = {}

function VfxLibrary.SetEmitters(model, enabled)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then descendant.Enabled = enabled end
	end
end


local function DescendFrom(root, path)
	local node = root
	for _, name in ipairs(path) do
		node = node and node:FindFirstChild(name)
	end
	return node
end

local function UsableAsVfx(instance)
	if not instance then return false end
	if instance:IsA("BasePart") then return true end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam") or descendant:IsA("Trail") then
			return true
		end
	end
	return false
end

-- ===== VFX MONTADO À MÃO NO PLACE =====
-- Mesma fronteira do resto do cenário Studio-owned: o Rojo não versiona efeito
-- montado no Explorer, então o código guarda só o CAMINHO e procura em dois
-- lugares — ReplicatedStorage primeiro (onde um VFX "de biblioteca" ficaria) e
-- Workspace depois, que é onde eles realmente estão hoje (Workspace.VFX.*).
--
-- O aviso antigo já prometia essa segunda busca; ela é que nunca existiu, e por
-- isso o anel de fogo do Karo nunca apareceu — o efeito estava em
-- Workspace.VFX.Karo.FireCircle e a procura só olhava ReplicatedStorage.
--
-- Clonado UMA vez e guardado fora da árvore: cada uso clona o molde, e os
-- emissores nascem desligados pra nenhum deles cuspir partícula no molde.
local vfxTemplates = {}

local function PrepareVfx(source)
	local template = source:Clone()
	VfxLibrary.SetEmitters(template, false)

	local parts = template:GetDescendants()
	if template:IsA("BasePart") then table.insert(parts, template) end

	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end

	return template
end

-- Diz ONDE o caminho quebrou, e o que existe naquele nível. Um VFX que não
-- aparece é sempre a mesma dúvida — "o nome está errado, a pasta está errada, ou
-- o objeto está vazio?" —, e sem isso a única saída era caçar no Explorer.
-- Nomes do Roblox distinguem maiúscula, então listar os irmãos entrega de bandeja
-- um "KIra" escrito "Kira" ou um "Fire Circle" com espaço.
local function DescribeVfxMiss(path)
	for _, root in ipairs({ ReplicatedStorage, Workspace }) do
		local node, walked = root, root.Name

		for _, name in ipairs(path) do
			local child = node:FindFirstChild(name)
			if not child then
				local irmaos = {}
				for _, sibling in ipairs(node:GetChildren()) do
					table.insert(irmaos, sibling.Name)
				end
				return ("em %s nao existe '%s'. O que tem la: %s"):format(
					walked, name,
					#irmaos > 0 and table.concat(irmaos, ", ") or "(vazio)")
			end
			node, walked = child, walked .. "." .. name
		end

		-- chegou ao fim do caminho: existe, mas não serve como VFX
		return ("%s existe mas nao tem geometria nem emissor dentro (e um %s vazio nao desenha nada)")
			:format(walked, node.ClassName)
	end

	return "caminho nao resolvido"
end

-- ===== OPACIDADE DE UM VFX INTEIRO =====
-- Transparência não mora num lugar só. Uma Part guarda um NÚMERO; ParticleEmitter,
-- Beam e Trail guardam uma NumberSequence (transparência ao longo da vida da
-- partícula / do comprimento do feixe); Decal e Texture guardam outro número.
--
-- É por isso que mexer só em `part.Transparency` não pegava na bolha da Kira: se
-- o que desenha a esfera é um emissor (ou um decalque numa Part invisível), a
-- Part já estava em 1 e o ajuste caía no vazio — a peça ficava "mais
-- transparente" sem nunca ter sido ela quem aparecia.
local function FadeNumber(value, opacity)
	return math.clamp(1 - (1 - value) * opacity, 0, 1)
end

local function FadeSequence(sequence, opacity)
	local keys = {}
	for _, key in ipairs(sequence.Keypoints) do
		local value = FadeNumber(key.Value, opacity)
		-- o envelope não pode estourar [0,1] em volta do novo valor, senão o
		-- construtor da NumberSequence recusa
		local envelope = math.min(key.Envelope, value, 1 - value)
		table.insert(keys, NumberSequenceKeypoint.new(key.Time, value, envelope))
	end
	return NumberSequence.new(keys)
end

function VfxLibrary.Fade(root, opacity)
	if opacity >= 1 then return end

	local pieces = root:GetDescendants()
	table.insert(pieces, root)

	for _, piece in ipairs(pieces) do
		if piece:IsA("ParticleEmitter") or piece:IsA("Beam") or piece:IsA("Trail") then
			piece.Transparency = FadeSequence(piece.Transparency, opacity)
		elseif piece:IsA("BasePart") or piece:IsA("Decal") then
			-- Texture herda de Decal, então entra aqui junto
			piece.Transparency = FadeNumber(piece.Transparency, opacity)
		end
	end
end

function VfxLibrary.StripLights(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Light") then descendant:Destroy() end
	end
	if instance:IsA("Light") then instance:Destroy() end
end

function VfxLibrary.Template(path, label)
	local key = table.concat(path, "/")
	if vfxTemplates[key] ~= nil then return vfxTemplates[key] or nil end

	local source = DescendFrom(ReplicatedStorage, path)
	if not UsableAsVfx(source) then
		source = DescendFrom(Workspace, path)
	end

	if not UsableAsVfx(source) then
		vfxTemplates[key] = false
		warn(("VfxLibrary: VFX %s nao encontrado — %s.\n  %s"):format(
			key:gsub("/", "."), label, DescribeVfxMiss(path)))
		return nil
	end

	local template = PrepareVfx(source)
	vfxTemplates[key] = template
	return template
end

return VfxLibrary
