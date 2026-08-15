# Hero Tactics — port Roblox

Jogo de táticas por turnos em grid hexagonal. Port do original em Phaser (`tactics-game/`).

## Como o Rojo está configurado aqui

Este projeto **não** gerencia o mundo inteiro — só os scripts. Tudo que foi construído
à mão dentro do Studio (mapa, lobby, `HexTile`, `Remotes`, `Sounds`, `BotDummyTemplate`,
Lighting, Baseplate) continua vivendo **só no Studio** e é ignorado pelo Rojo.

O `default.project.json` mapeia exatamente estes instances:

| Arquivo no disco | Instance no Studio |
|---|---|
| `src/shared/Modules/` | `ReplicatedStorage.Modules` |
| `src/server/Modules/` | `ServerScriptService.Modules` |
| `src/server/GameStartTrigger.server.luau` | `ServerScriptService.GameStartTrigger` |
| `src/client/*.client.luau` | `StarterPlayer.StarterPlayerScripts.*` |

**Por que isso importa:** o Rojo sobrescreve o Studio com o que está no disco. Se um
`$path` apontar para uma pasta vazia, ele **apaga** os scripts correspondentes no Studio.
Nunca aponte um `$path` novo para uma pasta que ainda não tenha os arquivos.

## Fluxo de trabalho

1. Instale as ferramentas (uma vez): `rokit install`
2. Suba o servidor de sync: `rojo serve`
3. No Studio, abra o plugin Rojo → **Connect**
4. Edite os `.luau` no VS Code — o Studio atualiza sozinho ao salvar

A partir daí o versionamento é git normal: `git add`, `git commit`, `git push`.

### Assets que continuam no Studio

Sons ficam em `ReplicatedStorage.Sounds` (`Hit`, `SwordSwing`, `Heal`, `PoisonHiss`,
`FootstepWood`, `MatchStart`, `HeroSelect`, `HeroSelectBattle`). IDs de imagem
(spritesheet dos heróis, ícone de veneno) ficam como constantes em `HeroData.luau`.
