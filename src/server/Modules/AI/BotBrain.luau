--[[
  BotBrain.lua
  ModuleScript — ServerScriptService/Modules/BotBrain
  O CÉREBRO do bot: dado um tabuleiro, qual é a melhor jogada. Nada aqui
  executa nada — não move herói, não aplica dano, não transmite estado, não
  cede. Só lê a partida e devolve um plano.
  QUEM EXECUTA É O MatchManager. A divisão é essa, e ela é a razão de este
  arquivo existir separado: `BotPlayTurn` (lá) chama `PlanFor` (aqui), recebe
  "o herói X vai pra casa Y e bate no Z", e aí sim gasta as chamadas que mexem
  no jogo e esperam animação. Decidir é puro e testável; executar cede e tem
  efeito colateral. Misturar os dois foi o que fez o MatchManager passar de
  3000 linhas.
  Toda consulta ao tabuleiro passa pelo MatchQuery, que também é só leitura.
  Se um dia uma função daqui precisar ESCREVER em `match`, ela está no arquivo
  errado.
  === A ARQUITETURA DA DECISÃO (herdada do MatchManager) ===
  Pontua cada combinação (herói, casa de destino, alvo) e executa a melhor,
  recalculando TUDO após cada ação. Não existe sequência fixa de if/else: as
  prioridades — abater, proteger o carry, perseguir o Nash, andar em grupo,
  buscar a Casa de Promoção — são parcelas de uma nota só, e a maior ganha. É
  por isso que a mesma peça joga diferente conforme o tabuleiro, sem ninguém
  escrever "se A e B então C".
  TRÊS CAMADAS, e cada regra nova entra em uma delas:
    BuildBoardContext  lê a partida agora (quem é o carry, que ameaças estão
                       em campo, se a promoção virou objetivo)
    ScorePosition      quanto vale ESTAR numa casa (proteção, formação, sombra)
    ScoreAttack        quanto vale BATER dali (dano, abate, efeitos, revide)
  Habilidade nova não precisa de sistema novo: é uma linha de `HasSkill` na
  camada certa. Hoje o Noctin caça alvo isolado, o Blade busca alinhamento, a
  Elaria cola em ferido, o Karo procura a casa que pega três, o Nash guarda a
  sombra, os Taunt se metem na frente do carry, os ranged mantêm distância — e
  ninguém tenta bater através de um Taunt.
  JOGADA COMBINADA. As três camadas pontuam um herói de cada vez, e por muito
  tempo foi só isso: cada peça buscava o melhor pra si e o time era a soma. Duas
  parcelas quebram esse isolamento sem inventar planejador de turno nenhum —
  elas medem o que uma peça faz PELAS OUTRAS, na moeda das camadas existentes:
    BuildLineBlocks (posição) o aliado atravessado na linha do Blade perde
                              pontos por ficar; sair da frente vira jogada
    PushValue       (ataque)  o empurrão do Bramm vale o dano extra que ele
                              monta pro Noctin, não só o próprio golpe
  Como o valor do combo entra no plano de QUEM MONTA, a ordem certa (montar
  antes de colher) sai sozinha do desempate por nota — o loop refaz tudo a cada
  ação e o beneficiado já encontra o tabuleiro pronto.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
-- Apelidos locais: o corpo abaixo veio do MatchManager, onde estas eram funções
-- locais do arquivo. Alias em vez de reescrever 200 chamadas pra
-- `MatchQuery.X(...)` — o código que decide continua lendo igual, e a busca de
-- upvalue local ainda é mais rápida que a indexação de tabela, o que conta num
-- laço que roda milhares de vezes por jogada do bot.
local AlliesAdjacentTo = MatchQuery.AlliesAdjacentTo
local FindStatusEffect = MatchQuery.FindStatusEffect
local FreeChecker = MatchQuery.FreeChecker
local GetHeroAt = MatchQuery.GetHeroAt
local HasSkill = MatchQuery.HasSkill
local IsFree = MatchQuery.IsFree
local LivingHeroesOf = MatchQuery.LivingHeroesOf
local MoveRangeOf = MatchQuery.MoveRangeOf
local SideOf = MatchQuery.SideOf
local TauntBlocks = MatchQuery.TauntBlocks
local AttackRangeOf = MatchQuery.AttackRangeOf
local BotBrain = {}
local TAUNT = GameConfig.ABILITIES.TAUNT
local FLAME_NEAR_RANGE = 2
local FLAME_NEAR_VALUE = 3
local FLAME_PATH_MAX = 30
-- O quanto vale a pena derrubar este inimigo.
--
-- É por HABILIDADE, não por nome de herói: um personagem novo entra na conta da
-- IA no dia em que ganhar uma skill conhecida, e a peculiaridade dele vira uma
-- linha aqui em vez de um caso especial espalhado pelo código. Vale pro resto
-- desta seção inteira.
local function ThreatScore(hero)
  if hero.summoner then return 1 end
  local threat = hero.attack * 3
  if GameConfig.IsRangedAttack(hero.attackRange) then threat += 2 end
  if HasSkill(hero, "longShot") then threat += GameConfig.WREN_RANGE * 2 end
  if HasSkill(hero, "raiseSkulls") then threat += 12 end
  if HasSkill(hero, "estopim") then threat += 3 end
  if HasSkill(hero, "gustPush") then threat += 6 end
  if HasSkill(hero, "tailwind") then threat += 4 end
  if HasSkill(hero, "emberShield") then threat += 7 end
  -- Elaria acima de todos: enquanto ela estiver de pé, o dano que a IA gasta
  -- no time inimigo volta como cura. Ela vale mais que o inimigo com menos HP.
  if HasSkill(hero, "health") then threat += 14 end
  if HasSkill(hero, "clean") then threat += 4 end
  -- Nash À VISTA é oportunidade com prazo: ele bate por AMBUSH_BONUS_DAMAGE a
  -- mais saindo da sombra, e some de novo assim que ninguém estiver perto.
  -- Quem chega aqui já está visível (o invisível nem entra na lista de alvos).
  if HasSkill(hero, "ambush") then threat += 12 end
  if HasSkill(hero, "weakPoint") then threat += 8 end
  if HasSkill(hero, "poisonAttack") then threat += 4 end
  if HasSkill(hero, "poisonFlask") then threat += 3 end
  if HasSkill(hero, "beyondFront") then threat += 3 end
  if HasSkill(hero, "aloneIsBetter") then threat += 3 end
  if HasSkill(hero, "iceEffect") then threat += 5 end -- controle: rouba turno inteiro
  return threat
end
-- ===== QUEM É O CARRY =====
-- O carry é quem CONVERTE turno em dano — e, de quebra, quem menos aguenta
-- apanhar. Vida alta desconta de propósito: um Ceos de 33 não precisa de babá,
-- e um Taunt nunca é carry (a função dele é o contrário).
local function CarryValue(hero)
  local value = hero.attack * 4
  if GameConfig.IsRangedAttack(hero.attackRange) then value += 3 end
  if HasSkill(hero, "beyondFront") then value += 4 end
  if HasSkill(hero, "aloneIsBetter") then value += 4 end
  if HasSkill(hero, "ambush") then value += 5 end
  if HasSkill(hero, "weakPoint") then value += 4 end
  if HasSkill(hero, "flameStrike") then value += 3 end
  if HasSkill(hero, "health") then value += 6 end -- cura é dano que não se perde
  if HasSkill(hero, "longShot") then value += GameConfig.WREN_RANGE end
  if HasSkill(hero, "raiseSkulls") then value += 5 end
  if hero.ability == TAUNT then value -= 8 end
  if hero.summoner then value -= 30 end
  return value - math.floor(hero.maxHp / 6)
end
-- Este inimigo alcança aquele herói AGORA ou no próximo passo dele? É a
-- pergunta que separa "carry exposto" de "carry longe do perigo", e a mesma que
-- diz se vale a pena um Taunt se meter no caminho.
local function Threatens(match, enemy, hero)
  return HexGrid.Distance(enemy.position, hero.position)
    <= MoveRangeOf(match, enemy) + AttackRangeOf(match, enemy)
end
-- ===================== LEITURA DO TABULEIRO =====================
-- Tudo que a IA precisa saber sobre a partida AGORA, resolvido uma vez por
-- decisão e passado pronto pras funções de pontuação. Existe por dois motivos:
-- as mesmas perguntas (quem é o carry? tem Noctin do outro lado? a Casa de
-- Promoção vale alguma coisa?) seriam refeitas pra cada casa candidata de cada
-- herói, e — mais importante — é isto que dá CONTEXTO à pontuação, em vez de
-- cada regra olhar só o próprio herói.
--
-- É reconstruído a cada ação do bot (ver BotPlayTurn): matou alguém, andou,
-- perdeu um aliado — o tabuleiro é outro, e a leitura também.
local function BuildBoardContext(match, botId, enemies)
  local allies = LivingHeroesOf(match, botId)
  local side = SideOf(match, botId)
  local ctx = {
    enemies = enemies,
    allies = allies,
    turn = match.turn and match.turn.number or 0,
    ownFlame = function(hexId)
      local flame = match.flames[hexId]
      return flame ~= nil and flame.ownerId == botId
    end,
    flameBias = function(hexId)
      local flame = match.flames[hexId]
      if not flame then return 0 end
      return flame.ownerId == botId and 4 or -4
    end,
  }
  -- O carry do PRÓPRIO time: quem os Taunt vão cobrir e quem não pode ficar
  -- sozinho perto de um Noctin.
  local bestCarry = -math.huge
  for _, ally in ipairs(allies) do
    local value = CarryValue(ally)
    if value > bestCarry then
      ctx.carry, bestCarry = ally, value
    end
  end
  -- Ameaças do outro lado que mudam o POSICIONAMENTO (as que só mudam a
  -- escolha de alvo já vivem no ThreatScore).
  for _, enemy in ipairs(enemies) do
    -- Nash à vista: colar nele nega a sombra (ele só some sem inimigo a
    -- STEALTH_RANGE), então perseguir é uma jogada de verdade, não teimosia.
    if HasSkill(enemy, "ambush") then ctx.stalker = enemy end
    -- Noctin: enquanto ele estiver vivo, aliado sozinho é dano dobrado
    if HasSkill(enemy, "aloneIsBetter") then ctx.hunter = enemy end
  end
  -- ===== CASA DE PROMOÇÃO =====
  -- Só vira objetivo se a jogada existir de verdade: o lado ainda não gastou o
  -- uso, a cota da partida ainda está aberta (o adversário pode ter fechado a
  -- casa pros dois), tem lápide de pé pra trazer alguém de volta, e o turno já
  -- está perto da liberação (começa a andar pra lá ANTES, senão chega tarde).
  local hexId = side and GameConfig.PROMOTION_HEX_FOR_SLOT[side.index]
  if hexId and side and not side.promotionUsed
    and MatchQuery.PromotionOpen(match)
    and ctx.turn >= GameConfig.PROMOTION_UNLOCK_TURN - 2 then
    local hasGrave = false
    for _, other in pairs(match.heroes) do
      if other.ownerId == botId and not other.isAlive and not other.graveDestroyed then
        hasGrave = true
        break
      end
    end
    if hasGrave then
      -- UM herói vai buscar, e é o mais perto. Sem esta escolha o bônus
      -- valeria pra todo mundo e o time inteiro largaria a briga pra
      -- caminhar até o mesmo canto do mapa.
      local bestDistance = math.huge
      for _, ally in ipairs(allies) do
        local distance = HexGrid.Distance(ally.position, hexId)
        if distance < bestDistance then
          ctx.promotionRunner, bestDistance = ally, distance
        end
      end
      ctx.promotionHex = hexId
    end
  end
  -- ===== O MAPA DE AMEAÇA =====
  -- Uma passada só, aqui, em vez de cada camada refazendo a mesma pergunta.
  -- Guarda por CASA quanto dano chega nela no próximo turno inimigo e quantas
  -- cabeças conseguem alcançá-la.
  --
  -- Alcance REAL: `MoveRangeOf` já desconta gelo e `AttackRangeOf` já lê a
  -- postura atual (o Shin em Melee ameaça menos casas que em Ranged). Somar os
  -- dois é a mesma conta que o `Threatens` sempre fez — o que muda é ela ser
  -- resolvida uma vez e não por candidato.
  --
  -- Distância e não caminho: o inimigo vai poder ANDAR até lá, e obstáculo que
  -- existe agora pode não existir depois que o tabuleiro mexer. Superestimar
  -- ameaça é o erro barato; subestimar é o que mata o suporte.
  ctx.threat = {}
  ctx.threatHeads = {}
  -- Quais abates o freio do estopim recusou nesta decisão. Só um recado: quem
  -- grava telemetria é o MatchManager, porque este arquivo não escreve em
  -- `match` (ver o cabeçalho).
  ctx.unsafeKill = {}
  for _, enemy in ipairs(enemies) do
    local reach = MoveRangeOf(match, enemy) + AttackRangeOf(match, enemy)
    for _, hex in ipairs(HexGrid.GetAllHexes()) do
      local id = type(hex) == "table" and hex.id or hex
      if HexGrid.Distance(enemy.position, id) <= reach then
        ctx.threat[id] = (ctx.threat[id] or 0) + enemy.attack
        ctx.threatHeads[id] = (ctx.threatHeads[id] or 0) + 1
      end
    end
  end
  -- Quem do outro lado castiga aglomeração. Serve pro time inteiro decidir se
  -- vale terminar o turno colado: sem ninguém assim em campo, andar junto é de
  -- graça, e o bot não deve inventar medo que não existe.
  ctx.enemyAoe = 0
  for _, enemy in ipairs(enemies) do
    if HasSkill(enemy, "estopim") then
      ctx.enemyAoe = math.max(ctx.enemyAoe, GameConfig.ESTOPIM_DAMAGE)
    elseif HasSkill(enemy, "flameStrike") or HasSkill(enemy, "iceStorm") then
      ctx.enemyAoe = math.max(ctx.enemyAoe, enemy.attack)
    elseif HasSkill(enemy, "voltChain") then
      ctx.enemyAoe = math.max(ctx.enemyAoe, GameConfig.VOLT_CHAIN_DAMAGE)
    end
  end
  return ctx
end
-- Quanto dano chega nesta casa, e de quantas cabeças. Zero quando ninguém
-- alcança — a tabela é esparsa de propósito, pra casa segura não custar memória.
local function ThreatAt(ctx, hexId)
  return ctx.threat and ctx.threat[hexId] or 0,
    ctx.threatHeads and ctx.threatHeads[hexId] or 0
end
-- Alcance a partir de uma casa hipotética, já contando que o herói saiu da atual
local function ReachFrom(match, hero, fromPos, range)
  local isFree = function(hexId)
    if hexId == hero.position or hexId == fromPos then return true end
    return IsFree(match, hexId)
  end
  return HexGrid.ComputeReach(fromPos, range, isFree)
end
local function HitsWeakPoint(target, fromPos)
  return target.weakPoint ~= nil
    and HexGrid.DirectionBetween(target.position, fromPos) == target.weakPoint
end
-- Um Taunt inimigo adjacente trava o ataque em qualquer outro alvo
local function EstimateDamage(match, attacker, target, fromPos)
  if HasSkill(attacker, "longShot") then
    return math.clamp(HexGrid.Distance(fromPos, target.position), 1, GameConfig.WREN_RANGE)
  end
  local damage = attacker.attack
  if HasSkill(attacker, "weakPoint") and HitsWeakPoint(target, fromPos) then
    damage += GameConfig.WEAK_POINT_BONUS_DAMAGE
  end
  -- trustInTeam recalcula no onMove: prevê o ataque já pós-movimento. Lê a
  -- marca da própria skill, não `attack > baseAttack`: o herói pode estar com
  -- ataque acima da ficha por outro motivo (bônus do barril).
  if HasSkill(attacker, "trustInTeam") then
    local buffed = attacker.trustInTeamApplied == true
    local willHaveAlly = #AlliesAdjacentTo(match, attacker, fromPos) > 0
    if willHaveAlly and not buffed then
      damage += 1
    elseif not willHaveAlly and buffed then
      damage -= 1
    end
  end
  if HasSkill(attacker, "aloneIsBetter") and #AlliesAdjacentTo(match, target, target.position) == 0 then
    damage *= 2
  end
  if HasSkill(attacker, "brokenDefense") and target.ability == TAUNT then
    damage += 1
  end
  if HasSkill(attacker, "poisonAttack") and FindStatusEffect(target, "poison") then
    damage += 2
  end
  if HasSkill(attacker, "iceEffect") and FindStatusEffect(target, "freeze") then
    damage *= GameConfig.FREEZE_DAMAGE_MULTIPLIER
  end
  if HasSkill(attacker, "rage") then
    local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
    if not (behind and IsFree(match, behind)) then
      damage += GameConfig.RAGE_BLOCKED_BONUS
    end
  end
  if HasSkill(attacker, "gustPush") then
    local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
    if not (behind and IsFree(match, behind)) then
      damage += GameConfig.ZEFF_PUSH_BLOCKED_BONUS
    end
  end
  -- Emboscada: o golpe que SAI da sombra leva o bônus. Sem isto a IA achava
  -- que o Nash bate por 2 e nunca via o bote — ele vale 6 justamente no
  -- turno em que está invisível, e só naquele.
  if HasSkill(attacker, "ambush") and attacker.stealth then
    damage += GameConfig.AMBUSH_BONUS_DAMAGE
  end
  if HasSkill(attacker, "momentum") then
    damage += HexGrid.Distance(attacker.position, fromPos) * GameConfig.MOMENTUM_PER_HEX
  end
  -- IMPULSO: o +1 nasce do PASSO, então ele só existe no golpe que sai de uma
  -- casa DIFERENTE da atual. É o que faz o PlanFor comparar sozinho as duas
  -- ordens do Ryder — ficar e atirar por 2, ou andar e atirar por 3 — sem
  -- ninguém escrever a comparação: as duas já são casas candidatas do mesmo
  -- laço, e a nota decide. Carregado, não soma de novo: o bônus não acumula, e
  -- prometer o dobro faria a IA andar atrás de um ponto que não vem.
  if HasSkill(attacker, "gunCharge") and fromPos ~= attacker.position
    and not FindStatusEffect(attacker, "gunCharge") then
    damage += GameConfig.RYDER_IMPULSE_ATTACK
  end
  if HasSkill(attacker, "voltChain") and FindStatusEffect(target, "charge") then
    damage += GameConfig.VOLT_CHAIN_DAMAGE
  end
  return damage
end
-- ===================== INTELIGÊNCIA COLETIVA =====================
--
-- As heurísticas abaixo corrigem um problema estrutural da avaliação antiga:
-- uma casa podia ser individualmente segura, mas destruir a formação do time.
-- A ideia NÃO é obrigar peças a ficarem coladas. O objetivo é manter cada herói
-- dentro da mesma zona de combate, preservar uma frontline/backline coerente e
-- valorizar casas que ainda geram dano e follow-up no próximo turno.
local function IsCarryHero(hero, ctx)
  return ctx.carry ~= nil and hero.uid ~= nil and ctx.carry.uid == hero.uid
end
local function IsBacklineHero(hero, ctx)
  return GameConfig.IsRangedAttack(hero.attackRange)
    or IsCarryHero(hero, ctx)
    or HasSkill(hero, "health")
    or HasSkill(hero, "clean")
    or HasSkill(hero, "raiseSkulls")
end
local function FormationWeight(hero, ctx)
  if hero.summoner then return 0 end
  local weight = 1
  -- O corredor de promoção recebeu uma missão estratégica que pode exigir
  -- abandonar a luta por alguns turnos.
  if ctx.promotionRunner and hero.uid and ctx.promotionRunner.uid == hero.uid then
    weight = math.min(weight, 0.15)
  end
  -- Nash/emboscadores precisam poder sair do bloco para recuperar a sombra.
  if HasSkill(hero, "stealth") or HasSkill(hero, "ambush") then
    weight = math.min(weight, 0.25)
  end
  -- Morn joga atrás das caveiras e não deve ser puxado artificialmente até a
  -- frontline. Ainda preservamos alguma coesão para ele não abandonar a luta.
  if HasSkill(hero, "raiseSkulls") then
    weight = math.min(weight, 0.55)
  end
  return weight
end
-- Quanto esta casa preserva uma formação jogável.
-- Distância 2 é especialmente boa para backline: perto o suficiente para dar
-- follow-up, mas sem transformar o time numa bola vulnerável a AoE.
local function FormationValue(match, hero, fromPos, ctx)
  local weight = FormationWeight(hero, ctx)
  if weight <= 0 then return 0 end
  local nearestAlly = math.huge
  local within2, within3 = 0, 0
  local validAllies = 0
  for _, ally in ipairs(ctx.allies) do
    if ally.isAlive and not ally.summoner and ally.uid ~= hero.uid then
      local distance = HexGrid.Distance(fromPos, ally.position)
      validAllies += 1
      nearestAlly = math.min(nearestAlly, distance)
      if distance <= 2 then within2 += 1 end
      if distance <= 3 then within3 += 1 end
    end
  end
  if validAllies == 0 or nearestAlly == math.huge then return 0 end
  local backline = IsBacklineHero(hero, ctx)
  local aoeRisk = (ctx.enemyAoe or 0) > 0
  local score = 0
  if nearestAlly <= 1 then
    -- Adjacência é boa normalmente, mas perde valor contra composição com AoE.
    if aoeRisk then
      score += backline and 1 or 3
    else
      score += backline and 10 or 12
    end
  elseif nearestAlly == 2 then
    score += backline and 16 or 11
  elseif nearestAlly == 3 then
    score += backline and 8 or 7
  elseif nearestAlly == 4 then
    score -= backline and 12 or 10
  else
    -- Isolamento real. Para um carry isto precisa custar mais que economizar
    -- alguns pontos de dano hipotético do próximo turno.
    local base = backline and 24 or 18
    local step = backline and 7 or 5
    score -= base + math.max(0, nearestAlly - 5) * step
  end
  -- Ter mais de um aliado na mesma zona de combate torna o follow-up mais
  -- confiável. Não exige adjacência e, portanto, não força aglomeração.
  if within3 >= 2 then
    score += math.min(within3 - 1, 2) * (backline and 4 or 3)
  elseif within2 == 0 and backline and nearestAlly >= 4 then
    score -= 4
  end
  -- Backline deve preferir uma casa com algum corpo entre ela e o inimigo.
  -- Não é pathfinding de bloqueio: é uma leitura simples de profundidade da
  -- formação. Tanks valem mais como tela.
  if backline and #ctx.enemies > 0 then
    local bestScreen = 0
    for _, enemy in ipairs(ctx.enemies) do
      local heroDistance = HexGrid.Distance(fromPos, enemy.position)
      local screen = 0
      for _, ally in ipairs(ctx.allies) do
        if ally.isAlive and not ally.summoner and ally.uid ~= hero.uid then
          local allyToHero = HexGrid.Distance(fromPos, ally.position)
          local allyToEnemy = HexGrid.Distance(ally.position, enemy.position)
          if allyToHero <= 3 and allyToEnemy < heroDistance then
            screen += (ally.ability == TAUNT) and 2 or 1
          end
        end
      end
      bestScreen = math.max(bestScreen, screen)
    end
    score += math.min(bestScreen, 3) * 4
    local incoming = ThreatAt(ctx, fromPos)
    if bestScreen == 0 and incoming > 0 then
      score -= 8
    end
  end
  return score * weight
end
local function ProjectedDamage(match, hero, target, fromPos)
  local distance = HexGrid.Distance(fromPos, target.position)
  local damage = math.max(0, hero.attack or 0)
  -- Long Shot escala com distância. Para projeção, usamos a distância atual da
  -- casa candidata e limitamos pelo alcance máximo conhecido da habilidade.
  if HasSkill(hero, "longShot") then
    damage = math.clamp(distance, 1, GameConfig.WREN_RANGE)
  end
  if HasSkill(hero, "ambush") and hero.stealth then
    damage += GameConfig.AMBUSH_BONUS_DAMAGE
  end
  if HasSkill(hero, "poisonAttack") and FindStatusEffect(target, "poison") then
    damage += 2
  end
  if HasSkill(hero, "iceEffect") and FindStatusEffect(target, "freeze") then
    damage *= GameConfig.FREEZE_DAMAGE_MULTIPLIER
  end
  return math.max(0, damage)
end
-- Valor ofensivo que esta casa deixa preparado para o PRÓXIMO turno.
-- É um look-ahead barato de 1 ply: não simula todas as jogadas, apenas pergunta
-- quais inimigos o herói ainda consegue alcançar depois de mover e quantos
-- aliados conseguem pressionar o mesmo alvo.
local function ProjectedOffenseValue(match, hero, fromPos, ctx)
  if #ctx.enemies == 0 then return 0 end
  local attackRange = AttackRangeOf(match, hero)
  local moveRange = MoveRangeOf(match, hero)
  local futureReach = attackRange + moveRange
  local best = 0
  for _, enemy in ipairs(ctx.enemies) do
    if enemy.isAlive then
      local distance = HexGrid.Distance(fromPos, enemy.position)
      if distance <= futureReach then
        local projectedDamage = ProjectedDamage(match, hero, enemy, fromPos)
        local travelNeeded = math.max(0, distance - attackRange)
        local partners = 0
        local combinedDamage = projectedDamage
        for _, ally in ipairs(ctx.allies) do
          if ally.isAlive and not ally.summoner and ally.uid ~= hero.uid then
            local allyReach = MoveRangeOf(match, ally) + AttackRangeOf(match, ally)
            if HexGrid.Distance(ally.position, enemy.position) <= allyReach then
              partners += 1
              combinedDamage += math.max(0, ally.attack or 0)
            end
          end
        end
        local value = math.min(projectedDamage, enemy.currentHp) * 3
        value += math.min(partners, 3) * 5
        value += math.min(ThreatScore(enemy), 20) * 0.45
        value -= travelNeeded * 1.5
        -- Casa que prepara focus fire e um provável abate vale mais do que uma
        -- casa igualmente segura sem continuação ofensiva.
        if combinedDamage >= enemy.currentHp then
          value += 10
        end
        best = math.max(best, value)
      end
    end
  end
  -- Follow-up não pode valer mais que um grande ataque/abate do turno atual.
  return math.min(best, 42)
end
-- Inimigos extras que o Blade acerta na mesma linha.
--
-- Copia a regra do Skills.beyondFront de perto: SÓ ALIADO VIVO interrompe o
-- corte. Casa vazia, túmulo e barril deixam o golpe passar. Antes esta conta
-- parava na primeira casa que não tivesse inimigo — então um buraco no meio da
-- fila escondia da IA o segundo alvo, e o Blade escolhia a linha errada por não
-- enxergar o que a própria skill acerta.
local function LineHits(match, attacker, target, fromPos)
  if not HasSkill(attacker, "beyondFront") then return 0 end
  local hits = 0
  for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, target.position, 2)) do
    local other = GetHeroAt(match, hexId)
    if other and other.isAlive then
      if other.ownerId == attacker.ownerId then break end
      hits += 1
    end
  end
  return hits
end
-- ===== SAIR DA FRENTE DO CORTE =====
-- O beyondFront para no primeiro ALIADO vivo da linha. Quando é o próprio time
-- que está atravessado, o golpe que pegaria três pega um — e a IA nunca via
-- isso, porque cada herói pontuava só a própria casa e ninguém tinha motivo pra
-- sair da frente de outro.
--
-- Este mapa é a ponte: casa -> quanto o TIME perde se alguém estiver parado
-- nela. Entra como penalidade no ScorePosition, então o aliado atravessado
-- passa a QUERER sair dali sozinho — sem plano de turno, sem coordenação
-- explícita. Ele anda primeiro (o passo dele vale mais), o Blade corta depois:
-- o loop do bot refaz o plano a cada ação e já encontra a linha limpa.
--
-- Vale pra qualquer portador de beyondFront e só enquanto ele ainda puder
-- atacar neste turno — gasto o golpe, ninguém mais precisa se mexer por ele.
local function BuildLineBlocks(match, ctx)
  local blocks = nil
  for _, cutter in ipairs(ctx.allies) do
    if HasSkill(cutter, "beyondFront") and not match.turn.attacked[cutter.uid] then
      -- de onde ele pode bater neste turno: a casa atual mais as que alcança
      local positions = { [cutter.position] = true }
      if not match.turn.moved[cutter.uid] then
        for hexId in pairs(HexGrid.ComputeReach(cutter.position, MoveRangeOf(match, cutter), FreeChecker(match))) do
          if IsFree(match, hexId) then positions[hexId] = true end
        end
      end
      for fromPos in pairs(positions) do
        for _, enemy in ipairs(ctx.enemies) do
          if HexGrid.Distance(fromPos, enemy.position) <= AttackRangeOf(match, cutter) then
            -- procura UM aliado atravessado; o que vier DEPOIS dele é
            -- exatamente o que se ganha tirando-o dali
            local blockerHex, gain = nil, 0
            for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, enemy.position, 2)) do
              local other = GetHeroAt(match, hexId)
              -- o próprio cortador não conta: se ele vai bater de
              -- `fromPos`, a casa velha dele já está vazia
              if other and other.isAlive and other ~= cutter then
                if other.ownerId == cutter.ownerId then
                  if blockerHex then break end -- dois aliados na fila: sem jeito
                  -- só vale pedir a casa a quem ainda pode andar
                  if match.turn.moved[other.uid] or match.turn.attacked[other.uid] then break end
                  blockerHex = hexId
                elseif blockerHex then
                  gain += 1
                end
              end
            end
            if blockerHex and gain > 0 then
              blocks = blocks or {}
              -- mesmo peso do acerto extra no ScoreAttack: sair da
              -- frente vale exatamente o que o corte ganha
              blocks[blockerHex] = math.max(blocks[blockerHex] or 0, gain * 30)
            end
          end
        end
      end
    end
  end
  return blocks
end
-- ===== O EMPURRÃO DO BRAMM É JOGADA DE EQUIPE =====
-- A Fúria empurra o alvo uma casa pra trás. Pro Bramm isso não muda quase nada:
-- o dano sai igual. Quem ganha é o TIME — inimigo empurrado pra longe dos
-- companheiros fica ISOLADO, e isolado é o dobro de dano pro Noctin.
--
-- Sem esta conta a IA só via o número do golpe e o arremesso era acidente. Com
-- ela o empurrão vale o que o ALIADO ganha depois, então o Bramm joga primeiro
-- — não porque alguém escreveu "Bramm antes de Noctin", mas porque o plano dele
-- passou a pontuar mais.
--
-- Genérico de propósito: quem colhe é qualquer herói com `aloneIsBetter`, e a
-- conta continua valendo se o elenco crescer. O que ele NÃO faz é segurar o
-- Noctin quando o Noctin já tem um abate na mão neste turno — e está certo:
-- abate agora vale mais que combo depois.
local function PushValue(match, attacker, target, fromPos, ctx, damage)
  if not HasSkill(attacker, "rage") then return 0 end
  if damage >= target.currentHp then return 0 end -- morre no golpe: não há empurrão
  local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
  -- bloqueado não empurra: vira RAGE_BLOCKED_BONUS de dano extra, que o
  -- EstimateDamage já contou — aqui só interessa o caso em que ele EMPURRA
  if not (behind and IsFree(match, behind)) then return 0 end
  -- isolar é o ponto: já sozinho, o empurrão não muda a conta de ninguém
  if #AlliesAdjacentTo(match, target, target.position) == 0 then return 0 end
  if #AlliesAdjacentTo(match, target, behind) > 0 then return 0 end
  local score = 0
  local remaining = target.currentHp - damage
  for _, ally in ipairs(ctx.allies) do
    local reach = match.turn.moved[ally.uid] and 0 or MoveRangeOf(match, ally)
    if ally ~= attacker and HasSkill(ally, "aloneIsBetter")
      and not match.turn.attacked[ally.uid]
      and HexGrid.Distance(ally.position, behind) <= reach + AttackRangeOf(match, ally) then
      -- na mesma moeda do ScoreAttack (dano * 10): o combo vale o dano
      -- EXTRA que o dobro rende, não o golpe inteiro
      score += ally.attack * 10
      if ally.attack * 2 >= remaining then
        score += 110 -- e o arremesso virou abate
      end
    end
  end
  -- Dante e afins perdem o bônus de aliado adjacente ao ficar sozinhos
  if HasSkill(target, "trustInTeam") and target.trustInTeamApplied then
    score += 10
  end
  return score
end
-- Dano que voltaria em contra-ataque (0 se o alvo morre ou não alcança)
local function CounterDamage(match, attacker, target, fromPos, damage)
  if damage >= target.currentHp then return 0 end
  if HexGrid.Distance(target.position, fromPos) > AttackRangeOf(match, target) then return 0 end
  -- golpe vindo da sombra não dá tempo de revidar (Skills.ambush marca
  -- suppressCounter): pro Nash invisível, bater é de graça
  if HasSkill(attacker, "ambush") and attacker.stealth then return 0 end
  local incoming = target.attack
  if HasSkill(attacker, "autoDefense") then incoming = math.max(0, incoming - 1) end
  return incoming
end
local WEAK_POINT_ATTACK_VALUE = 55
local WEAK_POINT_CHAIN_VALUE = 18
local WEAK_POINT_POSITION_VALUE = 30
local function AlreadyChained(match, attacker, target)
  local hits = match.turn and match.turn.weakChain and match.turn.weakChain[attacker.uid]
  return hits ~= nil and hits[target.uid] == true
end
local function ChainPotential(match, attacker, target, ctx)
  local reach = MoveRangeOf(match, attacker) + AttackRangeOf(match, attacker)
  local count = 0
  for _, enemy in ipairs(ctx.enemies) do
    if enemy ~= target and enemy.isAlive
      and not AlreadyChained(match, attacker, enemy)
      and HexGrid.Distance(target.position, enemy.position) <= reach then
      count += 1
    end
  end
  return count
end
-- ===== O QUE CUSTA MATAR QUEM EXPLODE =====
-- Só olha quem morre DE VERDADE ao cair: hoje é o estopim do Dr. Maluco, e a
-- pergunta é feita pela skill e não pelo nome, então qualquer herói futuro com
-- morte explosiva entra sozinho.
--
-- Conta cabeça a cabeça porque o preço não é linear. Vizinho que sobra em pé
-- custa o dano; vizinho que MORRE custa muito mais, porque é uma peça inteira
-- trocada por outra. O próprio atacante entra na conta quando o golpe sai de
-- uma casa colada — ele também está no raio.
-- CALIBRADO CONTRA A NOTA DO ABATE, que gira em torno de 166 pro Dr. Maluco.
-- Com ESTOPIM_DAMAGE em 10, cada vizinho inteiro custa 80: um vizinho ainda
-- deixa o golpe valer a pena (+86), dois ficam no fio (+6) e três seguram a mão
-- (-74). Vizinho que MORRE no estouro custa uma peça, e por isso pesa como um
-- abate inteiro — aí a conta vira negativa com um só.
--
-- Mexer nestes dois números é mexer no quão medroso o bot fica perto dele.
local BLAST_PER_DAMAGE = 8
local BLAST_PER_DEATH = 150
local function BlastCost(match, attacker, target, fromPos)
  if not HasSkill(target, "estopim") then return 0 end
  -- ÚLTIMO INIMIGO DE PÉ: o estouro acontece, mas a partida acaba junto. Levar
  -- dano numa vitória não é preço, é troco. Sem esta saída o bot ficava
  -- rodeando o último herói inimigo sem conseguir fechar o jogo.
  local remaining = 0
  for _, hero in pairs(match.heroes) do
    if hero.isAlive and hero.ownerId == target.ownerId and not hero.summoner then
      remaining += 1
    end
  end
  if remaining <= 1 then return 0 end
  local damage = GameConfig.ESTOPIM_DAMAGE
  local cost = 0
  for _, hero in pairs(match.heroes) do
    if hero.isAlive and hero.ownerId == attacker.ownerId then
      -- o atacante é medido pela casa DE ONDE vai bater, não pela atual
      local at = (hero == attacker) and fromPos or hero.position
      if HexGrid.Distance(at, target.position) <= 1 then
        cost += damage * BLAST_PER_DAMAGE
        if hero.currentHp <= damage then cost += BLAST_PER_DEATH end
      end
    end
  end
  return cost
end
local function ScoreAttack(match, attacker, target, fromPos, ctx)
  if TauntBlocks(match, attacker, target, fromPos) then return nil end
  if HasSkill(target, "dodge") and MatchQuery.DodgeHexFor(match, target, attacker, fromPos) then return nil end
  -- GOLPE JÁ GASTO NESTE ALVO. O Ponto Fraco devolve a ação ao acertar, e o
  -- servidor recusa o segundo golpe do MESMO Zaro no MESMO inimigo no mesmo
  -- turno (ver ChainHits, em MatchManager.AttackHero) — a corrente é pra
  -- ENCADEAR em outro, não pra moer o mesmo. Sem esta linha o bot continuava
  -- pontuando o alvo já atingido como o melhor golpe do turno: a ação voltava,
  -- o plano saía igual, o servidor recusava calado e nada no tabuleiro mudava,
  -- então o laço refazia o mesmo plano até o limite de iterações — o "JÁ
  -- ATINGIDO" repetido em cima do mesmo inimigo.
  --
  -- `nil` e não nota baixa: é a mesma resposta do Taunt e do desvio logo acima,
  -- e é o que faz o PlanFor descartar a jogada em vez de escolher a menos ruim.
  if AlreadyChained(match, attacker, target) then return nil end
  local damage = EstimateDamage(match, attacker, target, fromPos)
  local score = math.min(damage, target.currentHp) * 10
  -- o que este golpe deixa MONTADO pro resto do time (ver PushValue)
  score += PushValue(match, attacker, target, fromPos, ctx, damage)
  if damage >= target.currentHp then
    score += (target.summoner and 20 or 120) + ThreatScore(target) * 4
    -- ===== O ESTOPIM DO DR. MALUCO =====
    -- Matar ele DETONA ele: todo mundo colado leva ESTOPIM_DAMAGE e sai
    -- envenenado. O bot vinha correndo pro abate porque o ThreatScore só
    -- dizia que ele era um alvo valioso, e ninguém contava a conta do outro
    -- lado — daí o time inteiro se agrupar em volta e explodir junto.
    --
    -- Não é proibição, é preço. Um vizinho cheio de vida que leva o estouro
    -- é troca aceitável; três vizinhos, ou um que morre com ele, não é. A
    -- nota do abate continua na mesa (+120 e o valor da ameaça), então o
    -- golpe SAI quando o resto da conta justifica — vencer a partida agora,
    -- ou o dano aliado ser pequeno.
    local blast = BlastCost(match, attacker, target, fromPos)
    score -= blast
    -- Marca pro MatchManager contar quantas vezes o freio funcionou. Aqui
    -- não se escreve em `match` (ver o cabeçalho): só se avisa.
    if blast > 0 and ctx.unsafeKill then
      ctx.unsafeKill[target.uid] = math.max(ctx.unsafeKill[target.uid] or 0, blast)
    end
  else
    score += (target.maxHp - target.currentHp) * 2 -- concentra fogo no ferido
    score += ThreatScore(target) * 2
  end
  score += LineHits(match, attacker, target, fromPos) * 30
  -- Karo: o soco gira. Cada inimigo EXTRA colado na casa de onde ele vai bater
  -- leva o ataque cheio, então "de onde eu bato" importa tanto quanto "em
  -- quem". Como o PlanFor pontua cada casa candidata, é isto que faz ele
  -- escolher a posição que pega três em vez do golpe fácil que pega um.
  if HasSkill(attacker, "flameStrike") then
    local extra = 0
    for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
      local other = GetHeroAt(match, neighbor.id)
      if other and other.isAlive and other ~= target
        and other.ownerId ~= attacker.ownerId then
        extra += 1
        -- inimigo extra que MORRE no giro vale como abate
        if attacker.attack >= other.currentHp then
          score += 90 + ThreatScore(other) * 3
        end
      end
    end
    score += extra * attacker.attack * 9
  end
  -- veneno novo rende dano ao longo dos turnos seguintes
  if (HasSkill(attacker, "poisonAttack") or HasSkill(attacker, "poisonFlask"))
    and not FindStatusEffect(target, "poison") then
    score += 15
  end
  -- gelo do Kor: congelar quem ainda não está congelado rende o dobro de dano
  -- no golpe seguinte (o bônus em si já entrou pelo EstimateDamage)
  if HasSkill(attacker, "iceEffect") and not FindStatusEffect(target, "freeze") then
    score += 16
  end
  -- Ceos se cura batendo
  if HasSkill(attacker, "absorbRoots") and attacker.currentHp < attacker.maxHp then
    score += math.min(attacker.attack, attacker.maxHp - attacker.currentHp) * 5
  end
  -- Elaria limpa veneno dos vizinhos ao atacar
  if HasSkill(attacker, "clean") then
    for _, ally in ipairs(AlliesAdjacentTo(match, attacker, fromPos)) do
      if #ally.statusEffects > 0 then score += 25 end
    end
  end
  if HasSkill(attacker, "weakPoint") and HitsWeakPoint(target, fromPos) then
    score += WEAK_POINT_ATTACK_VALUE
    score += ChainPotential(match, attacker, target, ctx) * WEAK_POINT_CHAIN_VALUE
  end
  score -= CounterDamage(match, attacker, target, fromPos, damage) * 7
  return score
end
-- Valor de ocupar uma casa, mesmo sem atacar neste turno
local function ScorePosition(match, hero, fromPos, ctx)
  local enemies = ctx.enemies
  local score = 0
  local isTank = hero.ability == TAUNT
  local isRanged = GameConfig.IsRangedAttack(hero.attackRange)
  local nearest = math.huge
  for _, enemy in ipairs(enemies) do
    nearest = math.min(nearest, HexGrid.Distance(fromPos, enemy.position))
  end
  if nearest < math.huge then
    if isRanged then
      -- fica exatamente no alcance: bate sem ser contra-atacado
      score -= math.abs(nearest - AttackRangeOf(match, hero)) * 8
    else
      score -= nearest * 5
    end
    if isTank then
      score -= math.abs(nearest - 1) * 8 -- tanque segura a linha de frente
    end
  end
  -- ===== O QUE ME ESPERA NO PRÓXIMO TURNO =====
  -- Duas casas que rendem o mesmo golpe não valem o mesmo se uma delas deixa
  -- três inimigos com alcance em cima. Esta parcela é a diferença, e vale pro
  -- elenco inteiro: era a conta que só o Spyke fazia, dentro da própria regra.
  --
  -- O PESO É A FRAGILIDADE, não um número fixo. Tanque na linha de frente é o
  -- trabalho dele, e o `isTank` acima já paga por chegar lá; suporte no mesmo
  -- lugar é peça perdida. Por isso a conta é sobre a vida DELE: dano que não
  -- ameaça matar custa pouco, dano que mata custa caro.
  local incoming, heads = ThreatAt(ctx, fromPos)
  if incoming > 0 then
    local lethal = incoming >= hero.currentHp
    -- Segurança continua importante, mas não pode transformar a IA em covarde.
    -- Dano não-letal agora compete com formação + follow-up. Letalidade continua
    -- sendo muito cara, especialmente fora da frontline.
    local weight
    if isTank then
      weight = lethal and 4.5 or 0.9
    elseif lethal then
      weight = 7
    elseif IsCarryHero(hero, ctx) or isRanged then
      weight = 2.1
    else
      weight = 2.3
    end
    score -= incoming * weight
    if lethal and not isTank then score -= 14 end
    -- Cercado é pior que ameaçado: contra várias cabeças não dá pra recuar
    -- de todas, e o Taunt de um trava o revide no outro.
    if heads > 1 and not isTank then score -= (heads - 1) * 4 end
  end
  -- ===== FORMAÇÃO + FOLLOW-UP =====
  -- A casa não é avaliada só pela sobrevivência do próprio herói. Ela também
  -- precisa manter o time na mesma zona de combate e preservar dano futuro.
  score += FormationValue(match, hero, fromPos, ctx)
  score += ProjectedOffenseValue(match, hero, fromPos, ctx)
  -- ===== NÃO TERMINE O TURNO AMONTOADO =====
  -- Só pesa quando existe alguém do outro lado que castiga aglomeração
  -- (`ctx.enemyAoe`). Sem estopim, giro do Karo, corrente do Volt ou nevasca do
  -- Kor em campo, andar junto não custa nada e o bot não deve inventar medo.
  --
  -- Fica FORA do trustInTeam e da aura do Spyke de propósito: os dois pagam por
  -- encostar em aliado, e é justo que a conta do risco discorde deles. Quem
  -- decide é a soma.
  if ctx.enemyAoe > 0 then
    local packed = #AlliesAdjacentTo(match, hero, fromPos)
    if packed > 0 then
      score -= packed * ctx.enemyAoe
    end
  end
  if HasSkill(hero, "trustInTeam") then
    score += #AlliesAdjacentTo(match, hero, fromPos) * 10
  end
  -- ===== AS DUAS FASES DO SPYKE =====
  -- `turn.attacked` é o divisor: antes do golpe ele ainda precisa chegar em
  -- alguém (e o resto do ScorePosition já puxa por isso); depois do golpe o
  -- passo que sobrou não serve mais pra atacar, e a única coisa que ele ainda
  -- rende é encostar em quem vai bater no próximo turno. É por isso que a
  -- aura vale MAIS na segunda fase — na primeira ela compete com aproximar-se
  -- do alvo, na segunda ela é o objetivo inteiro.
  if HasSkill(hero, "rallyAura") then
    local repositioning = match.turn.attacked[hero.uid] == true
    local adjacent = AlliesAdjacentTo(match, hero, fromPos)
    -- por CABEÇA, e não "tem alguém do lado?": duas casas empatadas em tudo
    -- o mais são desempatadas pela que buffa dois aliados em vez de um
    for _, ally in ipairs(adjacent) do
      if ally.rallyAuraFrom == nil or ally.rallyAuraFrom == hero.uid then
        score += (repositioning and 20 or 12)
          + (match.turn.attacked[ally.uid] and 0 or 6)
      end
    end
    -- SUPORTE VIVO VALE MAIS QUE SUPORTE BEM POSICIONADO. Ele tem 1 de
    -- ataque: trocar a vida dele por um +1 emprestado é sempre péssimo
    -- negócio, e sem esta parcela o bot enfiava o Spyke no meio da linha
    -- inimiga atrás da casa que buffava mais gente. A conta é de DANO que
    -- chega, não de inimigos perto — e pesa o triplo quando esse dano
    -- somado já é a vida dele.
    local exposure = 0
    for _, enemy in ipairs(enemies) do
      if HexGrid.Distance(fromPos, enemy.position)
        <= MoveRangeOf(match, enemy) + AttackRangeOf(match, enemy) then
        exposure += enemy.attack
      end
    end
    score -= exposure * (hero.currentHp <= exposure and 14 or 6)
    -- Sangue Fervendo aberto: cada vizinho ameaçado é ataque que ele PODE
    -- ganhar — não custa vida nenhuma, então colar em quem está na mira é o
    -- jogo certo, não um risco. A parcela de exposição acima continua sendo
    -- o freio: vale ficar ao lado de quem vai apanhar, não no lugar dele.
    --
    -- Vale menos que a aura de propósito. A aura é certa (o +1 sai no ato),
    -- esta depende de o inimigo escolher aquele alvo — é aposta, e aposta
    -- não desempata contra ganho garantido.
    if FindStatusEffect(hero, "vengeance") then
      for _, ally in ipairs(adjacent) do
        for _, enemy in ipairs(enemies) do
          if Threatens(match, enemy, ally) then
            score += 7
            break
          end
        end
      end
    end
  end
  if HasSkill(hero, "tailwind") then
    for _, ally in ipairs(AlliesAdjacentTo(match, hero, fromPos)) do
      if not match.turn.moved[ally.uid] then score += 12 end
    end
  end
  -- O Morn NÃO segue as caveiras. Elas é que avançam: colar nelas puxava o
  -- invocador junto pra linha de frente, que é exatamente o que a fantasia
  -- dele não quer. O que sobra é ficar longe de quem bate.
  if HasSkill(hero, "raiseSkulls") then
    for _, enemy in ipairs(enemies) do
      local gap = HexGrid.Distance(fromPos, enemy.position)
      if gap <= 1 then
        score -= 14
      elseif gap <= AttackRangeOf(match, enemy) then
        score -= 10
      end
    end
  end
  if HasSkill(hero, "flamePath") then
    local path = nil
    if fromPos ~= hero.position then
      path = HexGrid.FindPath(hero.position, fromPos,
        MoveRangeOf(match, hero), FreeChecker(match), ctx.flameBias)
    end
    local crossed, flamePathValue = 0, 0
    for _, hexId in ipairs(path or {}) do
      if ctx.ownFlame(hexId) then
        crossed += 1
      else
        for _, enemy in ipairs(enemies) do
          local distance = HexGrid.Distance(hexId, enemy.position)
          if distance <= FLAME_NEAR_RANGE then
            flamePathValue += (FLAME_NEAR_RANGE + 1 - distance) * FLAME_NEAR_VALUE
          end
        end
      end
    end
    score += math.min(flamePathValue, FLAME_PATH_MAX)
    for _, enemy in ipairs(enemies) do
      local distance = HexGrid.Distance(fromPos, enemy.position)
      if distance <= FLAME_NEAR_RANGE then
        score += (FLAME_NEAR_RANGE + 1 - distance) * 6
      end
    end
    if HasSkill(hero, "flameFury") and hero.attack < GameConfig.FLAME_FURY_MAX_ATTACK then
      score += crossed * 22
    end
    if HasSkill(hero, "flameHeal") and hero.currentHp < hero.maxHp then
      score += crossed * 20
    end
  end
  -- Elaria cura e limpa vizinhos: cola em quem precisa
  if HasSkill(hero, "health") or HasSkill(hero, "clean") then
    for _, ally in ipairs(AlliesAdjacentTo(match, hero, fromPos)) do
      local missing = ally.maxHp - ally.currentHp
      local dirty = 0
      for _, effect in ipairs(ally.statusEffects) do
        if GameConfig.IsNegativeEffect(effect.type) then dirty += 1 end
      end
      if missing > 0 then
        score += 18
        if ally.currentHp <= GameConfig.ELARIA_ALLY_HEAL * 2 then score += 20 end
      end
      score += dirty * 14
      if missing > 0 and dirty > 0 then score += 12 end
    end
  end
  if isRanged then
    for _, enemy in ipairs(enemies) do
      if HexGrid.Distance(fromPos, enemy.position) <= 1 then score -= 22 end
    end
  end
  -- Noctin caça quem está sozinho (dano dobrado)
  if HasSkill(hero, "aloneIsBetter") then
    for _, enemy in ipairs(enemies) do
      if #AlliesAdjacentTo(match, enemy, enemy.position) == 0
        and HexGrid.Distance(fromPos, enemy.position) <= AttackRangeOf(match, hero) then
        score += 20
      end
    end
  end
  -- ===== TAUNT PROTEGE MAIS DO QUE ATACA =====
  -- Vale pra QUALQUER portador de Taunt, não só o Golem. A regra do jogo é que
  -- um Taunt inimigo adjacente trava o ataque em qualquer outro alvo — então
  -- "proteger" aqui é literalmente colar no inimigo que ameaça o carry: ele
  -- passa a só poder bater no tanque. Trabalho PREVENTIVO: a conta usa quem
  -- ALCANÇA o carry no próximo passo, não quem já está batendo nele.
  if isTank and ctx.carry and ctx.carry ~= hero then
    local carryPos = ctx.carry.position
    for _, enemy in ipairs(enemies) do
      if Threatens(match, enemy, ctx.carry) then
        if HexGrid.Distance(fromPos, enemy.position) <= 1 then
          score += 34 -- Taunt ligado: este inimigo não alcança mais o carry
        end
        -- corpo no caminho: na contagem de casas do hexágono, estar "em
        -- cima da linha" entre os dois é a soma das distâncias bater com
        -- a distância direta
        if HexGrid.Distance(enemy.position, fromPos) + HexGrid.Distance(fromPos, carryPos)
          == HexGrid.Distance(enemy.position, carryPos) then
          score += 12
        end
      end
    end
    -- guarda-costas: não adianta travar um inimigo e deixar o carry sozinho
    -- do outro lado do mapa
    score += math.max(0, 3 - HexGrid.Distance(fromPos, carryPos)) * 6
  end
  -- ===== EU SOU O NASH =====
  -- A sombra é a ficha dele: invisível ele bate por muito mais e não pode ser
  -- alvo. Terminar o passo longe de todo mundo VALE, mesmo sem bater neste
  -- turno — e quando houver um bote bom, o ScoreAttack (que já conta o bônus
  -- e a ausência de contra-ataque) passa por cima deste bônus sozinho.
  if HasSkill(hero, "stealth") and nearest > GameConfig.STEALTH_RANGE then
    score += 26
  end
  if HasSkill(hero, "weakPoint") then
    for _, enemy in ipairs(enemies) do
      if HitsWeakPoint(enemy, fromPos) and not AlreadyChained(match, hero, enemy) then
        score += WEAK_POINT_POSITION_VALUE
      end
    end
  end
  -- ===== ENFRENTANDO O NASH =====
  -- Ele só volta pra sombra se ninguém estiver a STEALTH_RANGE. Ficar colado é
  -- o contra-jogo: nega a invisibilidade sem precisar acertar um golpe. Só que
  -- o tanque é quem faz isso de bom grado — mandar o carry perseguir seria
  -- entregar exatamente o alvo que o Nash quer.
  if ctx.stalker and ctx.stalker.isAlive then
    local distance = HexGrid.Distance(fromPos, ctx.stalker.position)
    if distance <= GameConfig.STEALTH_RANGE then
      score += (hero == ctx.carry) and 10 or 24
    end
  end
  -- ===== ENFRENTANDO O NOCTIN =====
  -- Aliado sozinho é dano dobrado pra ele. Andar em grupo é a resposta, e o
  -- carry é quem mais paga por passear sozinho.
  if ctx.hunter and ctx.hunter.isAlive and #AlliesAdjacentTo(match, hero, fromPos) == 0 then
    score -= (hero == ctx.carry) and 22 or 10
  end
  -- ===== NÃO FIQUE NA FRENTE DO CORTE =====
  -- Ver BuildLineBlocks: parado nesta casa, este herói é o que impede o
  -- beyondFront aliado de pegar a fila inteira. Sair vale o que o corte ganha.
  if ctx.lineBlock then
    score -= ctx.lineBlock[fromPos] or 0
  end
  -- ===== CASA DE PROMOÇÃO =====
  -- Só o corredor escolhido no BuildBoardContext puxa por isto, e o valor
  -- cresce conforme ele chega perto: é objetivo estratégico, não corrida cega
  -- — qualquer abate ou proteção urgente continua pontuando mais alto.
  if ctx.promotionHex and hero == ctx.promotionRunner then
    if fromPos == ctx.promotionHex then
      score += 85
    else
      score += math.max(0, 24 - HexGrid.Distance(fromPos, ctx.promotionHex) * 4)
    end
  end
  return score
end
-- O barril mais perto de quebrar dentro do alcance. O bot só consulta isto
-- quando não tem inimigo pra bater: o prêmio é bom, mas trocar um golpe em herói
-- por um golpe em caixote seria péssimo negócio.
local function BarrelInReach(match, hero)
  if match.turn.attacked[hero.uid] then return nil end
  local reach = MatchQuery.AttackReachFrom(match, hero)
  local best = nil
  for _, barrel in pairs(match.barrels) do
    if reach[barrel.position] and (not best or barrel.hitsLeft < best.hitsLeft) then
      best = barrel
    end
  end
  return best
end
-- A lápide inimiga mais perto de quebrar dentro do alcance.
--
-- Quebrar lápide é a ÚNICA forma de negar a Casa de Promoção do outro lado: sem
-- lápide de pé não existe quem ressuscitar. Sem isto o bot ficava parado ao lado
-- do túmulo do herói que ele mesmo matou, e o jogador trazia o morto de volta
-- inteiro — a jogada mais forte da partida, de graça.
--
-- Consultado no mesmo lugar do barril (só quando não tem inimigo pra bater),
-- pela mesma razão: trocar um golpe em herói vivo por um golpe em pedra é
-- péssimo negócio.
local function GraveInReach(match, hero, botId)
  if match.turn.attacked[hero.uid] then return nil end
  local reach = MatchQuery.AttackReachFrom(match, hero)
  local best = nil
  for _, other in pairs(match.heroes) do
    if other.ownerId ~= botId and not other.isAlive and not other.graveDestroyed
      and reach[other.position]
    then
      -- O golpe que QUEBRA a lápide devolve GRAVE_CURSE_DAMAGE em quem
      -- bateu. Trocar um herói do próprio time por uma lápide não é
      -- negação, é suicídio: quem não sobrevive à maldição não dá o
      -- último golpe (nos anteriores não há maldição, então pode bater).
      local wouldBreak = (other.graveHitsLeft or 0) <= 1
      local diesToCurse = hero.currentHp <= GameConfig.GRAVE_CURSE_DAMAGE
      if not (wouldBreak and diesToCurse)
        and (not best or (other.graveHitsLeft or 0) < (best.graveHitsLeft or 0))
      then
        best = other
      end
    end
  end
  return best
end
-- Melhor jogada de um herói: para onde ir e quem bater
local function PlanFor(match, hero, ctx)
  if FindStatusEffect(hero, "paralysis") then return nil end
  -- MESMA função que o MoveHero usa pra aceitar ou recusar o passo, e que o
  -- snapshot usa pra pintar as casas. Com a conta duplicada aqui, o bot não
  -- enxergava o passo pós-ataque da Agility e encerrava o Spyke cedo demais.
  local canMove = MatchQuery.CanMove(match, hero)
  local canAttack = not match.turn.attacked[hero.uid]
  if not canMove and not canAttack then return nil end
  local positions = { [hero.position] = true }
  if canMove then
    for hexId in pairs(HexGrid.ComputeReach(hero.position, MoveRangeOf(match, hero), FreeChecker(match))) do
      if IsFree(match, hexId) then positions[hexId] = true end
    end
  end
  local best = nil
  for fromPos in pairs(positions) do
    -- Ficar parado só desempata de leve. Antes o +2 ajudava ranged/carry a
    -- congelar no fundo quando segurança e ataque ficavam próximos.
    local stayBonus = (fromPos == hero.position) and 0.25 or 0
    local positional = ScorePosition(match, hero, fromPos, ctx) + stayBonus
    local bestTarget, bestAttackScore = nil, nil
    if canAttack then
      local reach = ReachFrom(match, hero, fromPos, AttackRangeOf(match, hero))
      for _, enemy in ipairs(ctx.enemies) do
        if reach[enemy.position] then
          local attackScore = ScoreAttack(match, hero, enemy, fromPos, ctx)
          if attackScore and (not bestAttackScore or attackScore > bestAttackScore) then
            bestTarget, bestAttackScore = enemy, attackScore
          end
        end
      end
    end
    local total = positional + (bestAttackScore or 0)
    -- QUEM ABRE A TROCA É QUEM AGUENTA APANHAR. Entre dois ataques de valor
    -- parecido, o de mais vida sai primeiro: ele absorve o contra-ataque, e
    -- o frágil bate depois, num inimigo já gasto (ou já morto). Peso
    -- pequeno de propósito — é preferência de ORDEM, não regra: um abate ou
    -- uma proteção urgente continua ganhando de qualquer diferença de HP.
    if bestTarget then
      total += hero.currentHp * 0.4
    end
    if not best or total > best.score then
      best = {
        hero = hero,
        position = fromPos,
        target = bestTarget,
        score = total,
      }
    end
  end
  -- O freio funcionou? Só conta quando havia um abate explosivo na mesa E o
  -- plano escolhido não é ele. Escolher outro alvo, recuar ou reposicionar
  -- valem igual: o que importa é que o time não explodiu junto.
  if best and next(ctx.unsafeKill) ~= nil then
    local chosen = best.target and best.target.uid
    for uid in pairs(ctx.unsafeKill) do
      if uid ~= chosen then
        best.avoidedUnsafeKill = true
        break
      end
    end
  end
  return best
end

-- Quem o bot blinda com a Égide da Kira. A pergunta não é "quem é o melhor
-- herói?", é "quem morre se este turno correr mal?" — por isso o peso maior é a
-- ameaça que JÁ alcança o aliado, e não a ficha dele.
--
-- As opções chegam prontas do servidor (AllyOptionsFor), então quem já tem
-- escudo nem aparece aqui: o "nunca escolher quem já está protegido" é do filtro,
-- não desta conta.
function BotBrain.PickShieldTarget(match, ownerId, options)
  local enemies = LivingHeroesOf(match, MatchQuery.OpponentSide(match, ownerId).id)
  local best, bestScore = options[1], -math.huge
  for _, uid in ipairs(options) do
    local hero = match.heroes[uid]
    if hero and hero.isAlive then
      -- QUANTO DANO ESTÁ MIRANDO NELE. Um escudo é um golpe anulado, então
      -- ele vale o tamanho do golpe que vem — e vale muito mais em quem não
      -- sobrevive a ele, que é o caso em que o escudo compra um herói
      -- inteiro em vez de alguns pontos de vida.
      local incoming, reach = 0, 0
      for _, enemy in ipairs(enemies) do
        if Threatens(match, enemy, hero) then
          reach += 1
          incoming = math.max(incoming, enemy.attack)
        end
      end
      local score = incoming * 10 + reach * 6
      if incoming >= hero.currentHp then score += 60 end
      score += math.max(0, 20 - hero.currentHp) * 2
      score += CarryValue(hero)
      if hero.ability == TAUNT then score += 8 end
      if hero.summoner then score -= 40 end
      if score > bestScore then
        best, bestScore = uid, score
      end
    end
  end
  return best
end
-- ===== A TROCA DO SHIN =====
-- Duas peças mudam de casa de uma vez e o Shin ainda vira de postura, então a
-- pergunta não é "essa casa é boa?", é "as DUAS ficam melhores do que estão, com
-- a ficha que o Shin vai ter depois?".
--
-- A conta é a diferença entre o depois e o agora nas MESMAS camadas que o resto
-- do bot usa — ScorePosition pro valor de estar na casa, ScoreAttack pro golpe
-- que a casa nova abre. Nada de peso inventado pra esta habilidade: se a Troca
-- coloca o Shin no alcance de um abate, quem diz isso é o mesmo ScoreAttack que
-- decide todos os outros golpes do time.
--
-- A POSTURA ENTRA PELA FICHA, não por bônus. O `depois` é o próprio Shin com
-- ataque e alcance da postura seguinte por cima (o __index devolve o resto),
-- então o ScorePosition já sabe sozinho que um Shin que vai virar Melee quer
-- casa colada e um que vai virar Ranged quer distância — é a mesma linha
-- `IsRangedAttack(hero.attackRange)` que sempre existiu.
local SWAP_MIN_GAIN = 6
local function StanceAfterSwap(shin)
  local current = GameConfig.SHIN_STANCES[shin.stance]
  if not current then return nil end
  local following = GameConfig.SHIN_STANCES[current.next]
  return setmetatable({
    ability = following.ability,
    attackRange = following.attackRange,
    baseAttack = following.attack,
    attack = shin.attack + (following.attack - shin.baseAttack),
  }, { __index = shin })
end
local function BestAttackFrom(match, hero, fromPos, ctx)
  local best = 0
  local reach = ReachFrom(match, hero, fromPos, AttackRangeOf(match, hero))
  for _, enemy in ipairs(ctx.enemies) do
    if reach[enemy.position] then
      best = math.max(best, ScoreAttack(match, hero, enemy, fromPos, ctx) or 0)
    end
  end
  return best
end
function BotBrain.PickSwapTarget(match, shin, options)
  local depois = StanceAfterSwap(shin)
  if not depois then return nil end
  local enemies = {}
  for _, enemy in ipairs(LivingHeroesOf(match, MatchQuery.OpponentSide(match, shin.ownerId).id)) do
    if not enemy.stealth then table.insert(enemies, enemy) end
  end
  local ctx = BuildBoardContext(match, shin.ownerId, enemies)
  local agora = ScorePosition(match, shin, shin.position, ctx)
    + BestAttackFrom(match, shin, shin.position, ctx)
  local best, bestGain = nil, SWAP_MIN_GAIN
  for _, uid in ipairs(options) do
    local ally = match.heroes[uid]
    if ally and ally.isAlive then
      local gain = ScorePosition(match, depois, ally.position, ctx)
        + BestAttackFrom(match, depois, ally.position, ctx)
        + ScorePosition(match, ally, shin.position, ctx)
        - agora
        - ScorePosition(match, ally, ally.position, ctx)
      if gain > bestGain then
        best, bestGain = uid, gain
      end
    end
  end
  return best
end
local SEARCH_MEMORY = 4
local SEARCH_GOAL_WEIGHT = 12
local SEARCH_SPREAD_WEIGHT = 5
local SEARCH_REVISIT_PENALTY = 9
local SEARCH_STAY_PENALTY = 14
local function RememberSearchTile(hero, hexId)
  hero.searchMemory = hero.searchMemory or {}
  table.insert(hero.searchMemory, hexId)
  while #hero.searchMemory > SEARCH_MEMORY do
    table.remove(hero.searchMemory, 1)
  end
end
local function VisitedRecently(hero, hexId)
  for _, seen in ipairs(hero.searchMemory or {}) do
    if seen == hexId then return true end
  end
  return false
end
function BotBrain.SearchGoals(match, ctx, lastSeen)
  local goals = {}
  if lastSeen and HexGrid.Exists(lastSeen) then
    table.insert(goals, lastSeen)
  end
  if ctx.promotionHex then
    table.insert(goals, ctx.promotionHex)
  end
  -- Sem pista nenhuma, os alvos viram as casas mais LONGE do time: é o que
  -- transforma "andar por andar" em cobertura de tabuleiro.
  local far, bestScore = nil, -1
  for _, hex in ipairs(HexGrid.GetAllHexes()) do
    local id = hex.id or hex
    local nearest = math.huge
    for _, ally in ipairs(ctx.allies) do
      nearest = math.min(nearest, HexGrid.Distance(id, ally.position))
    end
    if nearest > bestScore then
      far, bestScore = id, nearest
    end
  end
  if far then table.insert(goals, far) end
  return goals
end
-- Uma ação de BUSCA, não de combate: sem inimigo visível não há o que pontuar
-- em ScoreAttack nem em ScorePosition (que lê ctx.enemies e devolveria zero pra
-- toda casa, deixando o bot parado). Aqui a nota vem de três coisas: encostar no
-- objetivo, abrir distância dos aliados e não repisar o que acabou de ser visto.
function BotBrain.SearchPlanFor(match, hero, ctx, goal)
  if not goal then return nil end
  if FindStatusEffect(hero, "paralysis") then return nil end
  if match.turn.moved[hero.uid] or match.turn.attacked[hero.uid] then return nil end
  local positions = { [hero.position] = true }
  for hexId in pairs(HexGrid.ComputeReach(hero.position, MoveRangeOf(match, hero), FreeChecker(match))) do
    if IsFree(match, hexId) then positions[hexId] = true end
  end
  local best = nil
  for hexId in pairs(positions) do
    local score = -HexGrid.Distance(hexId, goal) * SEARCH_GOAL_WEIGHT
    local nearest = math.huge
    for _, ally in ipairs(ctx.allies) do
      if ally ~= hero then
        nearest = math.min(nearest, HexGrid.Distance(hexId, ally.position))
      end
    end
    if nearest ~= math.huge then
      score += math.min(nearest, 4) * SEARCH_SPREAD_WEIGHT
    end
    if VisitedRecently(hero, hexId) then score -= SEARCH_REVISIT_PENALTY end
    if hexId == hero.position then score -= SEARCH_STAY_PENALTY end
    if not best or score > best.score then
      best = { hero = hero, position = hexId, score = score }
    end
  end
  return best
end
BotBrain.RememberSearchTile = RememberSearchTile
-- ===================== API =====================
-- O que o MatchManager chama, mais o que o CoreChecks precisa medir. O resto —
-- as heurísticas por habilidade, os ajudantes de linha e empurrão — fica
-- privado: é detalhe de COMO se decide, e mexer neles não deve exigir tocar em
-- quem executa.
BotBrain.ThreatScore = ThreatScore
BotBrain.BuildBoardContext = BuildBoardContext
BotBrain.ScorePosition = ScorePosition
BotBrain.FormationValue = FormationValue
BotBrain.ProjectedOffenseValue = ProjectedOffenseValue
BotBrain.BuildLineBlocks = BuildLineBlocks
BotBrain.PlanFor = PlanFor
BotBrain.BarrelInReach = BarrelInReach
BotBrain.GraveInReach = GraveInReach

return BotBrain
