--[[
	Monetization.lua
	ModuleScript — ReplicatedStorage/Modules/Monetization

	Catálogo dos apoios (Developer Products) e quanto cada um paga em moedas.

	Fica em ReplicatedStorage porque os dois lados leem a MESMA tabela: o cliente
	monta a vitrine a partir daqui e o servidor consulta a mesma entrada quando o
	recibo chega. O cliente nunca diz quanto vale a compra — ele só abre o prompt
	do produto, e quem converte Robux em moedas é o CoinService, pelo id do
	produto que veio no recibo.

	COMO LIGAR DE VERDADE
	Os `productId` nascem zerados de propósito. Crie os Developer Products no
	Creator Dashboard (Criações > o jogo > Monetização > Produtos), cole o id de
	cada um aqui e pronto. Enquanto o id for 0 o botão aparece desabilitado com
	um aviso, em vez de abrir uma compra que o Roblox recusaria.
]]

local Monetization = {}

Monetization.COIN_NAME = "Moedas"

-- Aviso obrigatório da vitrine: hoje as moedas não compram nada, são crédito
-- pro conteúdo que vem. Melhor deixar isso escrito na cara do que deixar
-- alguém apoiar achando que vai desbloquear algo agora.
Monetization.FUTURE_CONTENT_NOTICE =
	"As moedas ficam guardadas na sua conta. Elas vão servir para desbloquear os " ..
	"novos heróis que serão adicionados em atualizações futuras — por enquanto os " ..
	"9 heróis atuais já estão liberados para todo mundo, sem custo."

Monetization.THANK_YOU =
	"Táticas de Herói é feito por uma dupla, nas horas vagas. Qualquer apoio ajuda " ..
	"a pagar os assets e a manter o jogo crescendo. Obrigado por jogar!"

-- Os degraus maiores pagam bônus: quem apoia mais leva proporcionalmente mais
-- moeda. `robux` é só o preço exibido — quem cobra de verdade é o produto no
-- Creator Dashboard, então mantenha os dois números iguais ao configurar.
Monetization.TIPS = {
	{
		key = "coffee",
		productId = 0,
		robux = 25,
		coins = 250,
		title = "Um cafezinho",
		blurb = "Para o combustível de quem programa de madrugada.",
	},
	{
		key = "snack",
		productId = 0,
		robux = 100,
		coins = 1100,
		title = "Um lanche",
		blurb = "Paga um asset novo para a taverna.",
		bonus = "10% de bônus",
	},
	{
		key = "dinner",
		productId = 0,
		robux = 400,
		coins = 4800,
		title = "Um jantar",
		blurb = "Ajuda a bancar arte e sons dos próximos heróis.",
		bonus = "20% de bônus",
	},
	{
		key = "patron",
		productId = 0,
		robux = 1000,
		coins = 13000,
		title = "Padrinho do jogo",
		blurb = "Apoio de quem quer ver isso virar coisa grande.",
		bonus = "30% de bônus",
	},
}

function Monetization.IsConfigured(tip)
	return tip ~= nil and (tonumber(tip.productId) or 0) > 0
end

function Monetization.GetTip(key)
	for _, tip in ipairs(Monetization.TIPS) do
		if tip.key == key then return tip end
	end
	return nil
end

-- O recibo traz só o ProductId; é por aqui que o servidor descobre o valor.
function Monetization.GetTipByProductId(productId)
	productId = tonumber(productId)
	if not productId then return nil end

	for _, tip in ipairs(Monetization.TIPS) do
		if (tonumber(tip.productId) or 0) == productId and productId > 0 then
			return tip
		end
	end
	return nil
end

-- 13000 -> "13.000" (ponto de milhar, como se escreve em português)
function Monetization.FormatCoins(amount)
	local digits = tostring(math.max(0, math.floor(tonumber(amount) or 0)))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1."):reverse()
	return (grouped:gsub("^%.", ""))
end

return Monetization
