extends Node3D

## Monta o jogo inteiro por código: mundo, tela dividida, dois carros, HUD e a
## lógica da corrida. Construir por script em vez de .tscn evita depender de
## arquivos de cena escritos à mão, que quebram fácil.

## Voltas da corrida. Pode ser mudado na linha de comando com `-- --laps=N`.
var total_laps := 3
const COUNTDOWN_SECONDS := 3.0
const OFF_TRACK_LIMIT := 16.0
## Tempo capotado ou preso antes do resgate automático (segundos).
const STUCK_RESCUE_SECONDS := 3.0

enum State { COUNTDOWN, RACING, FINISHED }

var track: Track
var cars: Array[Car] = []
var cameras: Array[Camera3D] = []
var viewports: Array[SubViewport] = []

var state: State = State.COUNTDOWN
var countdown := COUNTDOWN_SECONDS
var race_time := 0.0
var winner := -1

var _hud: CanvasLayer
var _labels: Array[Label] = []
var _center_label: Label
var _sub_label: Label
var _split: HBoxContainer

func _ready() -> void:
	_build_world()
	_build_split_screen()
	_build_cars()
	_build_hud()
	get_viewport().size_changed.connect(_resize_viewports)
	_resize_viewports()
	_read_cmdline_options()
	_start_race()
	_maybe_start_capture()

func _read_cmdline_options() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--laps="):
			total_laps = maxi(1, int(arg.substr(7)))

func _maybe_start_capture() -> void:
	# só ativa com `godot -- --shot=<pasta>`; no jogo normal nada disso existe
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			var capture := preload("res://scripts/DebugCapture.gd").new()
			add_child(capture)
			capture.setup(self, arg.substr(7))
			capture.straight_test = OS.get_cmdline_user_args().has("--straight")
			return

# ---------------------------------------------------------------- mundo

func _build_world() -> void:
	track = Track.new()
	track.name = "Track"
	add_child(track)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 38, 0)
	sun.light_energy = 1.25
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = true
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_bottom_color = Color(0.28, 0.4, 0.24)
	sky_mat.ground_horizon_color = Color(0.6, 0.7, 0.7)
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.fog_enabled = true
	e.fog_density = 0.0012
	e.fog_light_color = Color(0.72, 0.82, 0.92)
	env.environment = e
	add_child(env)

# ---------------------------------------------------------------- tela dividida

func _build_split_screen() -> void:
	_split = HBoxContainer.new()
	_split.set_anchors_preset(Control.PRESET_FULL_RECT)
	_split.add_theme_constant_override("separation", 4)

	var layer := CanvasLayer.new()
	layer.layer = -1
	layer.add_child(_split)
	add_child(layer)

	for i in 2:
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.size_flags_vertical = Control.SIZE_EXPAND_FILL

		var vp := SubViewport.new()
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.handle_input_locally = false
		vp.msaa_3d = Viewport.MSAA_2X

		var cam := Camera3D.new()
		cam.fov = 68.0
		cam.far = 900.0
		vp.add_child(cam)

		container.add_child(vp)
		_split.add_child(container)

		viewports.append(vp)
		cameras.append(cam)

	# a tela 2 mostra o MESMO mundo da tela 1 — sem isso cada metade
	# renderaria um mundo vazio e separado
	viewports[1].world_3d = viewports[0].world_3d

func _resize_viewports() -> void:
	var size := get_viewport().get_visible_rect().size
	_split.size = size
	var half := Vector2i(int(size.x / 2.0) - 2, int(size.y))
	for vp in viewports:
		vp.size = half

# ---------------------------------------------------------------- carros

func _build_cars() -> void:
	var colors := [Color(0.85, 0.16, 0.15), Color(0.15, 0.42, 0.9)]
	for i in 2:
		var car := Car.new()
		car.player_index = i
		car.car_color = colors[i]
		car.name = "Car%d" % (i + 1)
		# o carro vive dentro do mundo da viewport 1, que a viewport 2 compartilha
		viewports[0].add_child(car)
		car.global_transform = track.grid_transform(i)
		cars.append(car)

	# a pista também precisa estar no mundo compartilhado
	remove_child(track)
	viewports[0].add_child(track)

# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)

	for i in 2:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		label.add_theme_constant_override("outline_size", 6)
		_hud.add_child(label)
		_labels.append(label)

	_center_label = Label.new()
	_center_label.add_theme_font_size_override("font_size", 84)
	_center_label.add_theme_color_override("font_color", Color.WHITE)
	_center_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_center_label.add_theme_constant_override("outline_size", 12)
	_center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_center_label)

	_sub_label = Label.new()
	_sub_label.add_theme_font_size_override("font_size", 24)
	_sub_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_sub_label.add_theme_constant_override("outline_size", 6)
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_sub_label)

func _layout_hud() -> void:
	var size := get_viewport().get_visible_rect().size
	for i in 2:
		_labels[i].position = Vector2(24 + (size.x / 2.0) * float(i), 18)
		_labels[i].size = Vector2(size.x / 2.0 - 40, 140)
	_center_label.position = Vector2(0, size.y * 0.32)
	_center_label.size = Vector2(size.x, 100)
	_sub_label.position = Vector2(0, size.y * 0.32 + 104)
	_sub_label.size = Vector2(size.x, 60)

# ---------------------------------------------------------------- corrida

func _start_race() -> void:
	state = State.COUNTDOWN
	countdown = COUNTDOWN_SECONDS
	race_time = 0.0
	winner = -1
	for i in cars.size():
		var car := cars[i]
		car.reset_to(track.grid_transform(i))
		car.controls_enabled = false
		car.progress = track.progress_at(car.global_position)
		car.last_progress = car.progress
		car.half_lap_done = false

func _process(delta: float) -> void:
	_layout_hud()
	_update_cameras(delta)

	match state:
		State.COUNTDOWN:
			countdown -= delta
			var n := int(ceil(countdown))
			_center_label.text = str(n) if n > 0 else "VALENDO!"
			_sub_label.text = "J1  W A S D          J2  I J K L"
			if countdown <= -0.7:
				state = State.RACING
				_center_label.text = ""
				_sub_label.text = ""
				for car in cars:
					car.controls_enabled = true
		State.RACING:
			race_time += delta
			_update_progress()
			_center_label.text = ""
			_sub_label.text = ""
		State.FINISHED:
			_center_label.text = "JOGADOR %d VENCEU" % (winner + 1)
			_sub_label.text = "R para correr de novo"

	_update_hud()

	if Input.is_physical_key_pressed(KEY_R) and state != State.COUNTDOWN:
		_start_race()

func _update_progress() -> void:
	for car in cars:
		if car.finished:
			continue
		var p := track.progress_at(car.global_position)
		var delta_p := p - car.last_progress
		var half := track.curve_length * 0.5

		if p > half:
			car.half_lap_done = true

		# cruzou a linha de chegada: o progresso salta do fim para o começo
		if delta_p < -half and car.half_lap_done:
			car.lap += 1
			car.half_lap_done = false
			if car.lap >= total_laps:
				car.finished = true
				car.finish_time = race_time
				if winner < 0:
					winner = car.player_index
					state = State.FINISHED
		elif delta_p > half:
			car.lap -= 1  # voltou de ré pela linha

		car.last_progress = p
		car.progress = p

		# Resgate: capotado ou parado contra o muro. Sem isso o jogador fica preso
		# para sempre e a partida acaba ali para ele.
		var upside_down := car.uprightness() < 0.3
		var barely_moving := car.speed_kmh() < 3.0
		if upside_down or barely_moving:
			car.stuck_time += get_process_delta_time()
		else:
			car.stuck_time = 0.0

		var off_track := track.lateral_offset(car.global_position) > OFF_TRACK_LIMIT
		if off_track or car.global_position.y < -5.0 or car.stuck_time > STUCK_RESCUE_SECONDS:
			_respawn(car)

func _respawn(car: Car) -> void:
	var offset := track.progress_at(car.global_position)
	var pos := track.point_at(offset) + Vector3.UP * 1.2
	var fwd := track.forward_at(offset)
	var lap := car.lap
	car.reset_to(Transform3D(Basis.looking_at(fwd, Vector3.UP), pos))
	car.lap = lap
	car.last_progress = offset
	car.stuck_time = 0.0
	car.controls_enabled = (state == State.RACING)

func _position_of(car: Car) -> int:
	var ahead := 1
	for other in cars:
		if other == car:
			continue
		var mine := float(car.lap) * track.curve_length + car.progress
		var theirs := float(other.lap) * track.curve_length + other.progress
		if theirs > mine:
			ahead += 1
	return ahead

func _update_hud() -> void:
	for i in cars.size():
		var car := cars[i]
		var lap_text := "%d/%d" % [mini(car.lap + 1, total_laps), total_laps]
		var status := "CHEGOU" if car.finished else "%dº" % _position_of(car)
		_labels[i].text = "J%d  %s\n%3d km/h\nVolta %s   %s" % [
			i + 1, Input2P.label_for(i), int(car.speed_kmh()), lap_text, status
		]
		_labels[i].add_theme_color_override("font_color", car.car_color.lightened(0.45))

func _update_cameras(delta: float) -> void:
	for i in cars.size():
		var car := cars[i]
		var cam := cameras[i]
		var back := car.global_transform.basis.z.normalized()
		var desired := car.global_position + back * 7.5 + Vector3.UP * 3.0
		var weight: float = clampf(delta * 6.0, 0.0, 1.0)
		cam.global_position = cam.global_position.lerp(desired, weight) if cam.global_position != Vector3.ZERO else desired
		cam.look_at(car.global_position + Vector3.UP * 1.0, Vector3.UP)
		cam.fov = lerpf(cam.fov, 66.0 + clampf(car.speed_kmh() / 200.0, 0.0, 1.0) * 14.0, weight)
