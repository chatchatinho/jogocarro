class_name Input2P
extends RefCounted

## Teclas dos dois jogadores.
##
## Lidas direto por código físico da tecla, sem passar pelo mapa de entrada do
## projeto: assim as teclas são as mesmas em qualquer layout de teclado
## (ABNT2, QWERTY, AZERTY) e não há como o mapa sair do lugar.

## Jogador 1: W A S D — Jogador 2: I J K L
static func keys_for(player_index: int) -> Dictionary:
	if player_index == 0:
		return {"up": KEY_W, "down": KEY_S, "left": KEY_A, "right": KEY_D}
	return {"up": KEY_I, "down": KEY_K, "left": KEY_J, "right": KEY_L}

static func label_for(player_index: int) -> String:
	return "W A S D" if player_index == 0 else "I J K L"
