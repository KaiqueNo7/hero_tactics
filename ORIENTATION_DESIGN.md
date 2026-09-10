# Landscape e Portrait — análise e proposta

Leitura do código em disco, sem alterações. 2026-09-10.

---

## Resumo

A parte que você mais detalhou, a lógica de orientação, é a **menor** parte do
trabalho e não tem nenhum obstáculo: dá para escrever em um módulo pequeno e
ligar em dois lugares.

O peso real está em três coisas que o pedido assume existirem e que **não
existem no projeto**: não há tela de Settings, não há detecção de dispositivo, e
não há persistência de preferência do cliente. Além disso a UI inteira é
desenhada em pixels fixos, sem camada responsiva.

E encontrei um problema nos números de câmera que você mediu à mão. Eles
provavelmente mostram o vazio fora da arena. Detalhe no fim.

---

## 1. Como câmera e UI funcionam hoje

### Câmera

`CameraController.client.luau` guarda o enquadramento em quatro locais de
módulo, lidos do `GameConfig` **no momento do require**:

```lua
local FIELD_OF_VIEW = GameConfig.CAMERA_FOV        -- 38
local ELEVATION     = GameConfig.CAMERA_ELEVATION  -- 44
local AZIMUTH       = GameConfig.CAMERA_AZIMUTH    -- 91
local DEFAULT_DISTANCE = GameConfig.CAMERA_DISTANCE -- 75
```

Como são `local` fixos, hoje não existe como trocar de perfil em tempo de
execução. Quem os lê: `orbitCFrame`, `applyCamera`, a câmera de finalização
(`playFinishCam`), o zoom e o voo livre de calibração.

O zoom trabalha por fator sobre um raio base (`ZOOM_MIN_FACTOR` 0.45,
`ZOOM_MAX_FACTOR` 1.5), e há um comentário longo explicando que o teto de 1.5
existe para a câmera não sair de dentro do diorama.

### UI

Não existe camada responsiva. O que existe é pontual:

- `PlacementClient` reage a `ViewportSize` para limitar a altura de uma coluna.
- `BattleClient` lê `ViewportSize` só para a matemática dos olhos do Merlin.
- `SafeArea` (shared) resolve a faixa do topo do Roblox e tem um observador
  (`SafeArea.OnChange`) com Heartbeat represado em 0,25s.

Fora isso, tudo é offset fixo. O painel do lobby usa escala no contêiner
(`0.88, 0.86`) mas offsets em tudo lá dentro. O HUD de batalha é offset puro.

### Telas que existem hoje

Lobby (abas Regras, Campanha, Heróis, mais desafios e recompensas), placement,
HUD de batalha, painel de resultado, log da partida, desafios, tutorial.

Cada uma precisaria de tratamento em Portrait. É aqui que mora o custo.

---

## 2. Settings hoje

**Não existe.** Procurei no cliente inteiro e não há tela de configurações, nem
botão, nem módulo. O item 8 não é "adicionar uma opção", é construir a tela.

Também não existe persistência de preferência do jogador no cliente.

---

## 3. Como identificar o dispositivo

O Roblox não tem uma propriedade "é celular". A classificação segura combina
quatro sinais, e é isso que o item 44 pede ao dizer que `TouchEnabled` sozinho
não basta:

| Sinal | Serviço |
|---|---|
| `TouchEnabled` | UserInputService |
| `KeyboardEnabled` / `MouseEnabled` | UserInputService |
| `GamepadEnabled` | UserInputService |
| `IsTenFootInterface()` | GuiService |
| Diagonal do `ViewportSize` | Camera |

Regra proposta, em ordem:

1. `GuiService:IsTenFootInterface()` → **Console**. É o sinal mais confiável.
2. `TouchEnabled` e não `KeyboardEnabled` → **Mobile** ou **Tablet**.
3. Qualquer outro caso → **Desktop**. Cobre o PC com tela de toque, que tem
   `TouchEnabled` **e** teclado.

Separar Mobile de Tablet não tem API. A diagonal do viewport em pixels é a
aproximação usada pela comunidade: acima de um limiar é tablet. Como o item 5
avisa, isso é instável, e por isso **essa distinção não deve decidir nada
sozinha**. Na prática Mobile e Tablet seguem a mesma regra (orientação atual), e
o único uso real do rótulo é a tela de Settings mostrar as opções certas.

---

## 4. Regras do Automatic

```
Console  → Landscape sempre
Desktop  → Landscape sempre (não segue o redimensionamento da janela)
Mobile   → segue o viewport
Tablet   → segue o viewport
Desconhecido → Landscape
```

Seguir o viewport, com a histerese do item 17:

```
Portrait quando  altura / largura >= 1.05
Landscape quando largura / altura >= 1.05
entre os dois: mantém o perfil anterior
```

A faixa morta de 5% resolve a tela quase quadrada e a transição de rotação, que
passa por proporções intermediárias durante a animação do sistema.

---

## 5. Arquitetura proposta

Quatro peças, nenhuma delas grande:

| Peça | Responsabilidade |
|---|---|
| `Device` (shared) | classifica o aparelho. Sem estado, sem eventos. |
| `Orientation` (client) | junta preferência + dispositivo + viewport e publica `EffectiveOrientation`. Um sinal quando muda. |
| `CameraProfiles` (shared) | os números por contexto e orientação. |
| `Settings` (client + store) | a tela e a preferência salva. |

`CameraController` deixa de decidir e passa a **receber**: `SetProfile("Match",
"Portrait")`. Ele nem precisa saber que celular existe, que é o item 25.

O ponto de escuta é `camera:GetPropertyChangedSignal("ViewportSize")`, que é
evento e não loop por quadro. Atende o item 47 e já é o padrão usado no
`PlacementClient`.

---

## 6. Perfis de câmera

```lua
CameraProfiles.Match = {
    Landscape = { elevation = 44, distance = 75,  fov = 38, azimuth = 91 },
    Portrait  = { elevation = 30, distance = 126, fov = 28, azimuth = 171 },
}
```

Os valores de Landscape são exatamente os de hoje, movidos do `GameConfig` sem
alteração. Os de Portrait são os seus, e é sobre eles que está a ressalva do fim
deste documento.

Trocar de perfil interpola os quatro valores. Como `applyCamera` recalcula o
`CFrame` a partir deles, basta animar os números e chamar a função a cada passo.

O lobby precisa dos próprios perfis, mas os números de Portrait do lobby ainda
não existem: eles precisam ser medidos no voo livre, como você fez com os da
partida.

---

## 7. UI responsiva

O princípio do item 28 é caro e está certo. Comprimir o layout horizontal não
resolve.

A abordagem que evita duplicar telas: cada painel ganha uma função de layout que
recebe a orientação e reposiciona o que já existe, mudando `AnchorPoint`,
`Position`, `FillDirection` do `UIListLayout` e `CellSize` do `UIGridLayout`. Os
elementos são os mesmos, o arranjo muda.

Em Portrait, o eixo vertical passa a ser o recurso abundante e o horizontal o
escasso — o inverso de hoje. Na prática:

- Coluna de heróis do HUD vira faixa horizontal no rodapé.
- Painel de turno e cronômetro sobem para o topo, dentro do `SafeArea`.
- Botão de encerrar turno vai para o canto inferior, na altura do polegar.
- Grade da campanha passa de várias colunas para uma ou duas.
- Painel de resultado empilha em vez de espalhar.

**Um aviso de implementação:** o `BattleClient` está com 197 locais de módulo,
três abaixo do teto de 200 do Luau. Qualquer trabalho responsivo ali tem que
entrar agrupado em tabela, ou o arquivo para de carregar.

---

## 8. Arquivos alterados

| Arquivo | Mudança |
|---|---|
| `src/client/CameraController.client.luau` | perfis em vez de constantes; `SetProfile` |
| `src/shared/Modules/GameConfig.luau` | as quatro constantes de câmera saem para `CameraProfiles` |
| `src/client/LobbyMenu.client.luau` | layout por orientação; botão e aba de Settings |
| `src/client/BattleClient.client.luau` | layout do HUD e do resultado por orientação |
| `src/client/PlacementClient.client.luau` | coluna de draft por orientação |
| `src/server/GameStartTrigger.server.luau` | ação para ler e gravar a preferência |

## 9. Arquivos novos

| Arquivo | Papel |
|---|---|
| `src/shared/Modules/Device.luau` | classificação do aparelho |
| `src/shared/Modules/CameraProfiles.luau` | números por contexto e orientação |
| `src/client/OrientationClient.client.luau` | resolve e publica a orientação efetiva |
| `src/server/Modules/SettingsStore.luau` | preferência por jogador |

---

## 10. Possíveis regressões

- **Câmera de finalização.** `playFinishCam` lê `ELEVATION`/`AZIMUTH` e guarda
  `wide = camera.CFrame` para voltar. Trocar de perfil no meio de uma cinemática
  quebra o retorno. O item 38 já prevê isso: a cinemática tem prioridade e a
  troca fica pendente até ela acabar.
- **Zoom.** O raio é fator sobre a distância base. Com base 126 em vez de 75, o
  mesmo fator 1.5 leva a câmera a 189. Os limites de zoom precisam ser por perfil.
- **Voo livre de calibração.** Escreve direto no `CFrame` e ignora perfil. Só
  precisa não ser reativado pela troca.
- **Olhos do Merlin.** Fazem projeção manual usando FOV e `ViewportSize`. Mudar
  o FOV de 38 para 28 muda a escala; vale conferir visualmente.
- **Lobby em Portrait.** O jogador anda pelo trilho com o personagem. Câmera
  mais alta ou mais fechada muda a sensação de andar, e isso não é ajuste de UI.

---

## 11. Casos de borda

- Rotação durante a animação do sistema passa por proporções quase quadradas.
  Resolvido pela histerese.
- Preferência manual **não** segue rotação (item 16), mas a UI ainda precisa
  reagir ao `ViewportSize`, porque a área útil muda mesmo sem trocar de perfil.
- Split screen e janela redimensionada no Desktop não devem virar Portrait.
- Roblox no Windows com tela de toque: tem `TouchEnabled` e teclado, cai em
  Desktop pela regra 3.
- Preferência salva antes de o DataStore responder: assumir Automatic e aplicar
  a salva quando chegar, sem piscar duas vezes se forem iguais.

---

## 12. Plano de implementação

Em etapas, porque isto não cabe numa entrega só.

**Etapa 1, o núcleo.** `Device`, `Orientation`, `CameraProfiles`, `SetProfile` no
`CameraController`, e o Automatic ligado. Sem Settings e sem UI responsiva: em
Portrait a câmera já muda e a UI continua a atual. É pequena, testável e já
entrega a câmera que você mediu.

**Etapa 2, Settings.** A tela, a opção Screen Orientation, a persistência e as
restrições por dispositivo.

**Etapa 3, HUD de batalha em Portrait.** É a tela que mais importa para jogar com
uma mão.

**Etapa 4, lobby e placement em Portrait.**

**Etapa 5, ferramentas de debug** do item 43.

---

# O problema nos números de Portrait

Medi o afastamento da câmera nos dois perfis, no plano do chão:

| Perfil | Afasta do centro | Altura | Além da borda do tabuleiro |
|---|---|---|---|
| Landscape (44°, 75) | 54,0 | 52,1 | 17,6 |
| **Portrait (30°, 126)** | **109,1** | **63,0** | **72,7** |
| Caso ruim documentado (44°, 135) | 97,1 | 93,8 | 60,7 |

O raio do tabuleiro é 36,4 studs.

O `CameraController` tem um comentário explicando que o zoom foi limitado a 1.5
justamente porque, em raio 135, a câmera saía cerca de 73 studs além da borda,
ficava fora do diorama e mostrava o vazio preto por baixo e pelas laterais.

**Os seus valores de Portrait afastam mais do que esse caso ruim**, e com
elevação mais baixa (30° contra 44°), o que deixa a câmera mais rasante e
aumenta a chance de enxergar além do piso da arena.

Isso não quer dizer que o enquadramento está errado. Você viu funcionando, e
enquadramento é decisão sua. Mas provavelmente funcionou na arena em que você
testou, e as arenas têm tamanhos de piso diferentes.

Três saídas, e preciso da sua:

1. **Aumentar a margem do piso da arena em Portrait.** Preserva o seu
   enquadramento. Custa geometria a mais em cena.
2. **Fechar o enquadramento.** Manter FOV 28 e azimute 171, subir a elevação e
   reduzir a distância até caber na margem atual. Muda o que você viu.
3. **Testar como está** e tratar o vazio quando aparecer.

Recomendo a 1, porque o enquadramento você já validou e a margem é um número só
no `ArenaBuilder`. Mas quero sua confirmação antes de assar esses valores no
perfil, senão eu entrego um bug visual embrulhado como recurso.

Confirmada essa decisão, começo pela Etapa 1.
