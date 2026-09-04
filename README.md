# Racha — corrida local para 2 jogadores

Jogo de corrida em tela dividida para duas pessoas no mesmo teclado, feito em
**Godot 4.3**, com visual pixelado estilo 16-bit. Três voltas num circuito fechado;
quem cruzar a linha primeiro vence.

## Controles

| Ação | Jogador 1 | Jogador 2 |
|---|---|---|
| Acelerar | **W** | **I** |
| Frear / ré | **S** | **K** |
| Virar à esquerda | **A** | **J** |
| Virar à direita | **D** | **L** |

**R** reinicia a corrida a qualquer momento (depois da largada).

As teclas são lidas pela posição física no teclado, então funcionam igual em
qualquer layout (ABNT2, QWERTY, AZERTY).

## Como rodar

1. Baixe o [Godot 4.3](https://godotengine.org/download) — é um executável único,
   não precisa instalar nada.
2. Abra o Godot, clique em **Importar**, escolha o arquivo `project.godot` desta pasta.
3. Aperte **F5** (ou o botão ▶ no canto superior direito).

Para gerar um executável que roda sem o Godot: menu **Projeto → Exportar**.

## Como funciona

O jogo inteiro é montado por código (`scripts/Main.gd`), sem depender de arquivos de
cena `.tscn` — só existe um `.tscn` mínimo apontando para o script.

| Arquivo | O que faz |
|---|---|
| `scripts/Main.gd` | Monta o mundo, a tela dividida, os carros, o HUD e a lógica da corrida |
| `scripts/Car.gd` | Física do carro: suspensão por raycast, aderência e transferência de peso |
| `scripts/Track.gd` | Gera o circuito: asfalto, faixas, zebras e muros de colisão |
| `scripts/Input2P.gd` | Teclas dos dois jogadores |
| `scripts/DebugCapture.gd` | Teste automatizado (só roda com `--shot=`, ver abaixo) |
| `shaders/retro_palette.gdshader` | Posteriza e dithera as cores — a paleta limitada do visual 16-bit |
| `assets/fonts/` | Fonte pixelada do HUD (ver `docs/asset-licenses.md`) |

### Física

Cada roda faz um raycast para o chão. A compressão da suspensão define a carga
vertical daquela roda — é daí que sai a transferência de peso ao frear e ao curvar.
A força lateral do pneu cresce com o deslizamento até **saturar**: passou do limite,
o pneu escorrega. Não existe "modo derrapagem" ligado por fora; o deslizamento
aparece sozinho quando você pede mais do que o pneu aguenta.

As forças longitudinal e lateral dividem o mesmo orçamento de aderência (círculo de
atrito), então acelerar no meio da curva tira aderência lateral — como num carro real.

### Posição e voltas

A posição na corrida e a contagem de voltas usam a distância percorrida ao longo da
curva do circuito, não gatilhos espalhados pela pista. Isso é mais confiável e evita
que alguém corte caminho.

Se um carro capota, cai ou fica preso no muro por alguns segundos, ele é recolocado
na pista automaticamente, sem perder a volta.

### Visual 16-bit

A física e a lógica de jogo continuam rodando em resolução total — só a
**apresentação** é retrô, em três camadas:

1. **Resolução interna baixa.** Cada metade da tela dividida renderiza numa
   imagem pequena (`Main.PIXEL_RENDER_HEIGHT`, hoje 216 px de altura) que
   depois é ampliada com filtro **nearest** — cada pixel vira um quadrado
   sólido em vez de borrar, que é a pixelização propriamente dita.
2. **Paleta limitada.** Um shader (`shaders/retro_palette.gdshader`) posteriza
   as cores em faixas e aplica dithering ordenado 4×4, imitando o número
   pequeno de cores simultâneas de um console 16-bit.
3. **Materiais chapados.** Sem metálico, sem brilho especular, céu em cor
   sólida em vez de gradiente — o oposto de um render PBR moderno.

Fonte pixelada (Press Start 2P, licença OFL) no HUD e nos textos de tela — ver
`docs/asset-licenses.md`.

## Testes

O jogo tem um teste automatizado que **dirige os dois carros** com as teclas reais e
valida a corrida inteira (largada, voltas, colisão, vencedor), tirando prints:

```bash
godot --path . -- --shot=/tmp/prints          # corrida completa de 3 voltas
godot --path . -- --shot=/tmp/prints --laps=1 # corrida de 1 volta (mais rápido)
godot --path . -- --shot=/tmp/prints --straight  # mede aceleração em linha reta
```

Em máquina sem placa de vídeo, acrescente `--rendering-driver opengl3`.

`--laps=N` também funciona no jogo normal, para partidas mais curtas ou mais longas.

## O que ainda não tem

- Som (nenhum).
- Menu inicial: a corrida começa direto.
- Um carro só, sem escolha nem customização.
- Um circuito só.
- Sem tempo de volta nem recordes.
