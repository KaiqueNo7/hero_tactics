--[[
	SafeStore.lua
	ModuleScript — ServerScriptService/Modules/SafeStore

	Uma camada fina sobre o DataStore: espera o orçamento, tenta de novo quando
	falha e só desiste depois de algumas tentativas.

	POR QUE ISSO EXISTE
	O XP e as moedas eram gravados com um `pcall` seco em volta do UpdateAsync.
	Uma falha transitória do DataStore — que acontece, e não é raro — significava
	a partida inteira do jogador virando pó, com um warn no log e nada mais. Quem
	perde 60 de XP por um soluço de rede não volta pra reclamar; simplesmente
	acha que o jogo não guarda progresso.

	O orçamento importa por outro motivo: quando ele zera, o Roblox NÃO recusa a
	chamada — ele enfileira internamente, e a chamada pode ficar pendurada bem
	mais tempo do que esperar aqui de propósito. Checar antes é mais rápido e
	deixa o log honesto sobre o que aconteceu.
]]

local DataStoreService = game:GetService("DataStoreService")

local SafeStore = {}

local MAX_ATTEMPTS = 4
local BUDGET_TIMEOUT = 8 -- segundos esperando o orçamento voltar
local BACKOFF = { 0.4, 1.5, 4 } -- pausa entre tentativas; a última repete

local function Backoff(attempt)
	return BACKOFF[math.min(attempt, #BACKOFF)]
end

local function WaitForBudget(requestType)
	local waited = 0
	while DataStoreService:GetRequestBudgetForRequestType(requestType) < 1
		and waited < BUDGET_TIMEOUT do
		task.wait(0.5)
		waited += 0.5
	end
	return DataStoreService:GetRequestBudgetForRequestType(requestType) >= 1
end

-- Roda `call` até dar certo. Devolve (ok, valor). `label` só entra no log.
local function Attempt(requestType, label, call)
	local lastError

	for attempt = 1, MAX_ATTEMPTS do
		if not WaitForBudget(requestType) then
			lastError = "orçamento de DataStore esgotado"
		else
			local ok, result = pcall(call)
			if ok then return true, result end
			lastError = result
		end

		if attempt < MAX_ATTEMPTS then
			task.wait(Backoff(attempt))
		end
	end

	warn(("SafeStore: %s falhou em %d tentativas: %s")
		:format(label, MAX_ATTEMPTS, tostring(lastError)))
	return false, nil
end

function SafeStore.Get(store, key, label)
	return Attempt(Enum.DataStoreRequestType.GetAsync, label or "GetAsync", function()
		return store:GetAsync(key)
	end)
end

function SafeStore.Update(store, key, transform, label)
	return Attempt(Enum.DataStoreRequestType.UpdateAsync, label or "UpdateAsync", function()
		return store:UpdateAsync(key, transform)
	end)
end

function SafeStore.Set(store, key, value, label)
	return Attempt(Enum.DataStoreRequestType.SetIncrementAsync, label or "SetAsync", function()
		return store:SetAsync(key, value)
	end)
end

return SafeStore
