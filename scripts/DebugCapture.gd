extends Node

## Teste automatizado de desenvolvimento: um piloto simples dirige os DOIS carros
## usando as teclas reais do jogo (W A S D e I J K L), para validar a corrida
## inteira — largada, voltas, colisão com muro, posição e vencedor.
##
## Só é criado quando o jogo roda com `-- --shot=<pasta>`. No jogo normal não existe.

var out_dir := "user://"
var _t := 0.0
var _main: Node3D
var _held := {}
var _stuck := {}
var _reported_finish := false
var _top_speed := {}
var straight_test := false

func setup(main: Node3D, dir: String) -> void:
	_main = main
	out_dir = dir

func _hold(keycode: Key, pressed: bool) -> void:
	if _held.get(keycode, false) == pressed:
		return
	_held[keycode] = pressed
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	ev.keycode = keycode
	ev.pressed = pressed
	Input.parse_input_event(ev)

func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [out_dir, shot_name])
	print("[shot] %s %s" % [shot_name, "ok" if err == OK else "ERRO"])

func _report(tag: String) -> void:
	var line := "[%s] t=%5.1f" % [tag, _t]
	for car: Car in _main.cars:
		line += " | J%d %3dkm/h volta %d/%d prog %4.0f %s" % [
			car.player_index + 1, int(car.speed_kmh()),
			mini(car.lap + 1, _main.total_laps), _main.total_laps,
			car.progress,
			"CHEGOU" if car.finished else "max %d derrapagem %.2f" % [
				int(_top_speed.get(car.player_index, 0.0)), car.slip_amount()]
		]
	print(line)

## Teste de reta: leva um carro para uma área plana longe da pista e segura o
## acelerador, sem esterço nem muros. Mede aceleração e velocidade final puras.
func _straight_line(before: float) -> void:
	var car: Car = _main.cars[0]
	if before < 0.1 and _t >= 0.02:
		car.reset_to(Transform3D(Basis.IDENTITY, Vector3(400, 1.0, -300)))
		# estado FINISHED: o jogo para de checar progresso/limite de pista, senão
		# o resgate automático teleporta o carro de volta e arruína a medição
		_main.state = 2
		car.controls_enabled = true
		print("[reta] iniciando teste de linha reta")
	if before < 0.5 and _t >= 0.5:
		_hold(KEY_W, true)
	car.controls_enabled = true
	for mark: float in [2.0, 4.0, 6.0, 9.0, 12.0, 16.0, 20.0, 25.0]:
		if before < mark and _t >= mark:
			print("[reta] t=%4.1fs  %6.1f km/h" % [_t, car.speed_kmh()])
	if _t > 26.0:
		print("[reta] velocidade final = %.1f km/h" % car.speed_kmh())
		get_tree().quit()

## Piloto simples: mira um ponto adiante na pista e esterça pelo ângulo até ele.
func _drive(car: Car) -> void:
	var keys := Input2P.keys_for(car.player_index)

	if car.finished or _main.state != 1:  # 1 = RACING
		for k: Key in [keys.up, keys.down, keys.left, keys.right]:
			_hold(k, false)
		return

	# preso no muro: dá ré por um instante em vez de acelerar contra ele para sempre
	var stuck: float = _stuck.get(car.player_index, 0.0)
	stuck = stuck + get_process_delta_time() if car.speed_kmh() < 4.0 else 0.0
	_stuck[car.player_index] = stuck

	if stuck > 1.5:
		_hold(keys.up, false)
		_hold(keys.down, true)
		_hold(keys.left, false)
		_hold(keys.right, true)
		if stuck > 3.2:
			_stuck[car.player_index] = 0.0
		return

	var track: Track = _main.track
	var lookahead: float = 16.0 + car.speed_kmh() * 0.34
	var target := track.point_at(car.progress + lookahead)
	var local := car.global_transform.affine_inverse() * target

	# Esterça pelo ÂNGULO até o alvo, com zona morta. Com limiar em metros o
	# piloto zigue-zagueava e raspava toda a velocidade nas curvas.
	var angle := atan2(local.x, maxf(absf(local.z), 1.0))
	_hold(keys.right, angle > 0.05)
	_hold(keys.left, angle < -0.05)

	# solta o acelerador quando a curva à frente é forte e a velocidade é alta
	var ahead := track.point_at(car.progress + 26.0)
	var ahead_local := car.global_transform.affine_inverse() * ahead
	var corner: float = absf(ahead_local.x)
	var limit: float = 125.0 if car.player_index == 0 else 108.0
	var too_fast: bool = car.speed_kmh() > limit - corner * 3.0

	_hold(keys.up, not too_fast)
	_hold(keys.down, too_fast and corner > 9.0)

## Câmera de cima, só para depuração: mostra a pista inteira de uma vez.
func _overhead() -> void:
	var cam: Camera3D = _main.cameras[0]
	var saved := cam.global_transform
	var saved_fov := cam.fov
	cam.global_position = Vector3(0, 260, 0)
	cam.look_at(Vector3(0, 0, 0.001), Vector3.FORWARD)
	cam.fov = 70.0
	await _shot("00-de-cima.png")
	cam.global_transform = saved
	cam.fov = saved_fov

func _process(delta: float) -> void:
	var before := _t
	_t += delta

	if straight_test:
		_straight_line(before)
		return

	for car: Car in _main.cars:
		_drive(car)
		_top_speed[car.player_index] = maxf(_top_speed.get(car.player_index, 0.0), car.speed_kmh())

	if before < 0.9 and _t >= 0.9:
		_overhead()

	if before < 1.2 and _t >= 1.2:
		_shot("01-largada.png")
		_report("largada")

	for mark: float in [8.0, 20.0, 40.0, 70.0, 110.0, 150.0]:
		if before < mark and _t >= mark:
			_report("corrida")

	if before < 12.0 and _t >= 12.0:
		_shot("02-correndo.png")

	if before < 45.0 and _t >= 45.0:
		_shot("03-pista.png")

	if _main.state == 2 and not _reported_finish:  # 2 = FINISHED
		_reported_finish = true
		_report("fim")
		print("[resultado] vencedor = Jogador %d" % (_main.winner + 1))
		# espera o HUD desenhar o aviso de vencedor antes de capturar
		await get_tree().create_timer(0.8).timeout
		await _shot("04-vencedor.png")
		get_tree().quit()

	if _t > 190.0:
		_report("tempo esgotado")
		print("[resultado] NINGUEM terminou a tempo")
		get_tree().quit()
