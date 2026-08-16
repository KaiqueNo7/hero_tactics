--[[
	Environment.server.lua
	Script — ServerScriptService

	Aplica a paleta de luz assim que o servidor sobe. Lighting é replicado, então
	basta o servidor definir uma vez: todo cliente que entrar já pega o resultado.

	A regra em si mora em Modules.LightingSetup — este script só é o gatilho, pra
	que dê pra chamar o mesmo Apply() no Studio em modo Edit sem play.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local LightingSetup = require(ServerScriptService.Modules.LightingSetup)

LightingSetup.Apply()
