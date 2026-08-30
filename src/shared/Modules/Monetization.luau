--[[
	Monetization.lua
	ModuleScript — ReplicatedStorage/Modules/Monetization

	Nome e formatação da moeda do jogo.

	Fica em ReplicatedStorage porque os dois lados leem daqui: o servidor credita
	a carteira (CoinService) e o cliente desenha o saldo no lobby.
]]

local Monetization = {}

Monetization.COIN_NAME = "Moedas"

-- Aviso da vitrine: hoje as moedas não compram nada, são crédito pro conteúdo
-- que vem. Melhor deixar isso escrito na cara do que deixar alguém juntar moeda
-- achando que desbloqueia algo agora.
Monetization.FUTURE_CONTENT_NOTICE =
	"As moedas ficam guardadas na sua conta. Elas vão servir para desbloquear os " ..
	"novos heróis que serão adicionados em atualizações futuras — por enquanto os " ..
	"9 heróis atuais já estão liberados para todo mundo, sem custo."

-- 13000 -> "13.000" (ponto de milhar, como se escreve em português)
function Monetization.FormatCoins(amount)
	local digits = tostring(math.max(0, math.floor(tonumber(amount) or 0)))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1."):reverse()
	return (grouped:gsub("^%.", ""))
end

return Monetization
