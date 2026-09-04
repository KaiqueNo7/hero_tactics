--[[
	PreviewHeroUI.server.luau
	Script — ReplicatedStorage/Dev/PreviewHeroUI

	Ferramenta de DESENVOLVIMENTO. Monta a UI real do herói (crachá de
	ATK/HP, selo de passiva, veneno, gelo) e o efeito de ataque à distância
	direto no Workspace, em modo EDIT — sem dar Play e sem passar pelo
	MatchManager. Usa o HeroView de verdade, então o que aparece aqui é
	exatamente o que aparece numa partida.

	Fica em ReplicatedStorage (não roda sozinho) de propósito: Script dentro
	de ServerScriptService/Workspace executa pra valer quando alguém entra no
	jogo. NUNCA mova este script pra lá.

	USO (no Explorer do Studio, com o jogo em modo Edit):
	  1. Botão direito em cima do script -> Run.
	     Aparece uma fileira de heróis de mentirinha, flutuando bem acima do
	     tabuleiro (Y = 40), cada um com o painel de status real.
	  2. Edite HeroView.luau (cores, tamanho, texto, ícone...) à vontade.
	  3. Botão direito -> Run de novo. Ele apaga a rodada anterior e remonta
	     com o código atualizado — não precisa fechar o Studio nem dar Play.
	  4. Quando terminar, apague Workspace.Heroes_preview e
	     Workspace.Graves_preview (ou rode este script de novo e apague
	     depois — ele não deixa lixo de rodadas antigas, só da atual).

	Pra mudar QUAIS heróis e em quais estados aparecem, edite a lista
	PREVIEW abaixo. `dataId` é o id em HeroData.CATALOG (1=Ralph, 2=Vic,
	3=Mineiro, 4=Blade, 5=Dante, 6=Ceos, 7=Noctin, 8=Elaria, 9=Bramm, 10=Kor,
	11=Merlin).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local HeroView = require(ServerScriptService.Modules.HeroView)


local PREVIEW = {
	{ dataId = 1,  hex = "A1", hpRatio = 1 },                                    -- Ralph, normal
	{ dataId = 1,  hex = "A3", hpRatio = 1,    buffed = true },                  -- Ralph, ATK buffado (verde)
	{ dataId = 1,  hex = "A5", hpRatio = 0.4 },                                  -- Ralph, vida machucada (laranja)
	{ dataId = 1,  hex = "B1", hpRatio = 0.12 },                                 -- Ralph, vida crítica (vermelho)
	{ dataId = 5,  hex = "B3", hpRatio = 1 },                                    -- Dante, passiva Ranged
	{ dataId = 6,  hex = "B5", hpRatio = 1 },                                    -- Ceos, passiva Taunt
	{ dataId = 3,  hex = "C1", hpRatio = 1 },                                    -- Mineiro, passiva Sprint
	{ dataId = 2,  hex = "C3", hpRatio = 0.6,  poison = 3 },                     -- Vic, veneno recém aplicado
	{ dataId = 2,  hex = "C5", hpRatio = 0.6,  poison = 1 },                     -- Vic, veneno no último turno
	{ dataId = 10, hex = "D1", hpRatio = 1,    frozen = true },                  -- Kor, congelado
	{ dataId = 6,  hex = "D3", hpRatio = 0.5,  buffed = true, poison = 2, frozen = true }, -- Ceos, pior caso: passiva + buff + veneno + gelo juntos
}

local RANGED_DEMO = { attackerHex = "B3", targetHex = "D3" }

local PREVIEW_ORIGIN = Vector3.new(0, 40, 0)
local MATCH_ID = "preview"

local previousView = {
	heroesFolder = Workspace:FindFirstChild("Heroes_" .. MATCH_ID),
	gravesFolder = Workspace:FindFirstChild("Graves_" .. MATCH_ID),
}
HeroView.DestroyView(previousView)

HexGrid.Generate()

local view = HeroView.CreateView(MATCH_ID, PREVIEW_ORIGIN, {})

local built = {}

for index, entry in ipairs(PREVIEW) do
	local data = HeroData.GetById(entry.dataId)
	if not data then
		warn(("PreviewHeroUI: dataId %s não existe em HeroData.CATALOG"):format(tostring(entry.dataId)))
	else
		local maxHp = data.hp
		local currentHp = math.max(1, math.floor(maxHp * (entry.hpRatio or 1) + 0.5))
		local baseAttack = data.attack
		local attack = baseAttack + (entry.buffed and 1 or 0)

		local statusEffects = {}
		if entry.poison then
			table.insert(statusEffects, { type = "poison", duration = entry.poison })
		end
		if entry.frozen then
			table.insert(statusEffects, { type = "freeze" })
		end

		local hero = {
			uid = MATCH_ID .. "_" .. index .. "_" .. data.id,
			dataId = data.id,
			position = entry.hex,
			maxHp = maxHp,
			currentHp = currentHp,
			attack = attack,
			baseAttack = baseAttack,
			ability = data.ability,
			statusEffects = statusEffects,
			view = view,
		}

		HeroView.Create(hero)
		built[entry.hex] = hero
	end
end

if RANGED_DEMO then
	local attacker = built[RANGED_DEMO.attackerHex]
	local target = built[RANGED_DEMO.targetHex]
	if attacker and target then
		task.wait(0.3)
		HeroView.ShowRangedAttack(attacker, target)
	end
end

print(("PreviewHeroUI: %d heróis montados em Workspace.Heroes_%s (Y=%d). Rode de novo pra atualizar depois de mexer no HeroView."):format(#PREVIEW, MATCH_ID, PREVIEW_ORIGIN.Y))
