# Refatoração arquitetural

Refatoração por responsabilidade, sem mudança de comportamento, em quatro etapas.

## Redução

| Arquivo | Original | Etapa 1 | Etapa 2 | Etapa 3 | Etapa 4 | Diferença |
|---|---|---|---|---|---|---|
| `MatchManager.luau` | 3510 | 3063 | 2999 | 2067 | 919 | −2591 (−74%) |
| `HeroView.luau` | 3708 | 3094 | 2471 | 2471 | 1968 | −1740 (−47%) |

Os dois arquivos somavam 7218 linhas e hoje somam 2887. O maior módulo do servidor passou a ser o
`CombatCore`, com 982.

## Estrutura final

`src/server/Modules/` é organizado por domínio, e a pasta é o caminho da instância: um require lê
`ServerScriptService.Modules.<Pasta>.<Modulo>`. Sempre absoluto, nunca `script.Parent`, exceto
entre dois módulos da mesma pasta.

```
Modules/
    MatchManager.luau              o orquestrador, e a porta de entrada de fora

    Match/                         a partida como dado
        MatchRegistry              quais partidas existem neste servidor, slots, achar a do jogador
        MatchQuery                 toda pergunta pura sobre o tabuleiro
        MatchClock                 quantos segundos faltam (turno, reconexão, posicionamento)
        MatchSnapshot              serializar a partida para o cliente, por espectador
        MatchBroadcast             publicar o estado e a arrumação que vem depois
        MatchLog                   log da partida, contadores por herói, recusa de ação
        MatchOutcome               acabou? quem ganhou? mais o registro de Resolvers
        MatchRewards               XP, estrelas, herói da campanha, telemetria

    Combat/                        as regras de agir
        CombatCore                 o anel: dano, morte, cura, status, chama, gatilhos, api das skills
        ActionGuard                este herói pode agir agora?
        MovementService            mover
        AttackService              atacar
        BoardObjectService         regras dos objetos destrutíveis
        PlacementService           o draft
        PromotionService           promoção, ressurreição, postura, troca do Shin
        Skills                     as particularidades de cada habilidade

    AI/
        BotBrain                   decide
        BotTurn                    executa

    View/                          só existe para ser olhado
        HeroView                   o herói na tela
        BoardObjectView            o objeto destrutível na tela
        BoardVfx                   efeito que pertence a uma CASA
        ProjectileVfx              o tiro: bolinha, retícula, tracejante
        VfxLibrary                 achar e preparar o VFX montado à mão no place
        ViewStyle                  vocabulário visual compartilhado
        MatchAudio                 som para os jogadores de uma partida

    Arena/      ArenaBuilder ArenaObjectBuilder BoardSpawner LightingSetup
    Lobby/      LobbyZoneBuilder SeatBuilder LeaderboardBoardView
    Data/       SafeStore e tudo que grava em DataStore, mais DevAccess
    Modes/      ChallengeService SandboxService Objectives
```

## Arquivos criados

| Etapa | Arquivos |
|---|---|
| 1 | `ArenaObjectBuilder` (374), `BoardObjectView` (166), `ViewStyle` (120), `MatchAudio` (39), `MatchClock` (46), `MatchSnapshot` (278), `MatchRewards` (177) |
| 2 | `BoardVfx` (447), `VfxLibrary` (167), `MatchLog` (49), `MatchBroadcast` (50) |
| 3 | `CombatCore` (982) |
| 4 | `MatchRegistry` (60), `MatchOutcome` (129), `PlacementService` (192), `PromotionService` (294), `BoardObjectService` (144), `ActionGuard` (29), `AttackService` (194), `MovementService` (152), `BotTurn` (246), `ProjectileVfx` (452) |

Vinte e dois módulos novos. Nenhum passa de 982 linhas, e só um passa de 500.

## O que cada etapa tirou de onde

**Etapa 1 — objetos do board fora do HeroView.** `ObjectSpec`, `PrepareTemplate`, `ModelFromAsset`,
`ModelFromInstance`, `TemplateVisual`, `ObjectVisual`, `ObjectSize`, `ObjectDust`, `ObjectSound`,
`IsLyingCylinder`, `BarrelCFrame`, `PaintSkin`, `AttachObjectModel` e a montagem da caixa foram
para o `ArenaObjectBuilder`; o crachá, a pancada e a quebra para o `BoardObjectView`. Do
`MatchManager` saíram os cinco relógios, o `Snapshot` e o bloco de recompensas.

**Etapa 2 — VFX de tabuleiro e as transversais.** Chama no chão, brilho de alcance, estouro,
círculo de fogo, arcos da corrente e nevasca foram para o `BoardVfx`; a infraestrutura de VFX do
place para o `VfxLibrary`. `LogEvent`, `Tally`, `Reject` e `Broadcast` saíram do `MatchManager`,
que é o que destravou a etapa 3.

**Etapa 3 — o anel de combate.** Trinta e quatro funções, de `ApplyDamage` a `BuildSkillApi`,
foram para o `CombatCore` como um módulo só. O corpo delas não foi tocado: só o cabeçalho de
requires e a tabela de exportação no fim são código novo.

**Etapa 4 — o resto.** Registro, fim de partida, draft, promoção, objetos, movimento, ataque,
turno do bot e o sistema de projétil saíram cada um para o seu módulo, e tudo foi organizado em
pastas.

## Por que o CombatCore é um módulo só

É um ciclo, não uma árvore: `ApplyDamage` chama `KillHero`, que dispara `TriggerSkills`, que roda
a habilidade, que chama de volta a `api` do `BuildSkillApi`, que chama `ApplyDamage` outra vez.
Separar isso em módulos daria require circular. A regra passou a ser: função que o anel chama, ou
que chama o anel, mora ali.

## Acoplamento

Cinco seams usam dependência injetada em vez de require, todas ligadas uma vez na carga:

| Módulo | Recebe | Por quê |
|---|---|---|
| `MatchSnapshot` | `AllyOptionsFor`, `NextOpenFight` | os dois ainda moram no `MatchManager` |
| `CombatCore` | `CreateHero` | o Estilhaçar do Golem invoca pela `api`, montada antes do `CreateHero` existir |
| `PlacementService` | `CreateHero`, `BeginTurn` | o draft termina começando o primeiro turno |
| `PromotionService` | `CreateHero` | ressuscitar é criar herói |
| `MatchOutcome` | `EndMatch` | o fim da partida é ciclo de vida, que ficou no orquestrador |
| `BotTurn` | `EndTurn` | o bot encerra o próprio turno |

Dependências que sumiram: o `HeroView` não requer mais `InsertService` nem `Arenas`; o
`MatchManager` não requer mais `ProgressionService`, `HeroStatsService`, `HeroUsageService`,
`FightStore`, `Objectives`, `Skills`, `BotBrain`, `BoardVfx`, `BoardObjectView` nem o RemoteEvent
`MatchUpdate`. Trinta e cinco aliases mortos foram removidos do topo dele.

Não há ciclo de require em lugar nenhum. `Skills` requer só o `GameConfig`, e é isso que permite
o `CombatCore` requerê-lo.

## Verificação

Em todas as etapas: `selene` em `src/` com 0 erros e 0 erros de parse, `rojo build` ok, e todos
os módulos carregando no Studio.

Medições em partida de verdade, não em modelo:

- Objeto por caminho `instance` (cacto do Deserto): altura 7.00 como pede o tema, `rotationX = 180`
  no pivô, caixa invisível, 66 soldas, crachá com 2 bolinhas em `StudsOffset.Y = 5.04`
  (= 7.00 × 0.72), `BarrelUid` presente, `Workspace.Cactos` intacto depois do clone.
- Objeto por caminho `asset` (Vulcan), em partida real: quatro objetos de altura 5.60.
- Pancada e quebra: bolinha apaga, poeira criada, `barrel.part` zerado, peça removida pelo Debris.
- Os sete efeitos do `BoardVfx` numa partida ativa: todos sem erro, 28 instâncias criadas.
- Partida contra bot do início ao fim: vencedor correto, estatísticas gravadas, ranking recusando
  partida com bot, console limpo.
- **Etapa 3:** vinte partidas bot contra bot simultâneas pelo caminho do `BalanceSim`, com elencos
  sorteados do catálogo inteiro. Dezenove fecharam antes de eu encerrar a sessão, sem nenhum erro:
  2220 de dano, 92 abates, 137 de cura, 205 turnos, 10/8 vitórias e 1 empate.

Além do lint, duas checagens estruturais que o selene não faz:

1. Todo caminho `ServerScriptService.Modules.X.Y` citado em qualquer arquivo corresponde a um
   arquivo existente no disco.
2. Nenhum módulo usa um alias antes da linha que o define. Esse é o erro que o selene não pega:
   `local X = Modulo.Y` cria um local NOVO, e uma chamada acima dela continua enxergando a
   declaração antecipada, que passou a ser `nil`. Foi exatamente o que aconteceu com
   `TryTriggerPromotion` na etapa 4, achado e corrigido.

**Pendente:** a validação final em partida depois da mudança de pastas. O Studio travou em modo
Play durante o teste (sintoma conhecido do plugin, exige reiniciar), então o que está verificado
da etapa 4 é o estático: lint, build, caminhos e ordem de definição.

## Bug e inconsistências encontrados, não corrigidos

1. **`rotationY` do tema é ignorado.** O Deserto declara `rotation = 0` e `rotationY = 25` em
   `Arenas.luau`. O código lê `spec.rotation` para o eixo Y; `rotationY` não é lido em lugar
   nenhum. Ou o dado sobra, ou a rotação nunca funcionou. Corrigir muda o visual da arena.
2. **`selene` não estava no `rokit.toml`.** O `CLAUDE.md` manda rodar `selene .`, mas o manifesto
   só listava o `rojo` e o shim recusava executar. Acrescentei `selene` e `lune` nas versões já
   instaladas na máquina.
3. **`SideColor`, `AttachTo` e `BuildTeamRing` eram atribuídas a locais declaradas 600 linhas
   antes**, no meio do bloco de chamas. Hoje são funções do `ViewStyle`.
4. **`RefreshWeakPoints` tinha um alias morto** no `MatchManager` desde que o `Broadcast` saiu.

## O que ainda daria para fazer

- **Ciclo de vida da partida** (`StartMatch`, `EndMatch`, `ClearScene`, `Replay`, `LeaveMatch`,
  reconexão, desistência) são ~450 das 919 linhas que sobraram no `MatchManager`. Sairiam como
  `MatchLifecycle`, deixando o orquestrador com o fluxo de turnos e a API pública. É a única
  extração grande que resta, e é a mais entrelaçada com o registro.
- **A lápide, no `HeroView`**, tem crachá, golpes e quebra igual ao barril. Quando o
  `BoardObjectView` for generalizado para "objeto destrutível do tabuleiro" em vez de "barril",
  ela cabe lá e o `HeroView` encolhe mais ~230 linhas.
- **O `BattleClient`**, com 3559 linhas, é hoje o maior arquivo do projeto. Não foi tocado nesta
  refatoração.
