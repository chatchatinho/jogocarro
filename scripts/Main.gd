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

## Altura interna do render de cada metade da tela, em pixels. Quanto menor,
## mais grosso o pixel — é isso, junto do filtro nearest, que dá o visual
## 16-bit; a física e a lógica de jogo continuam rodando em resolução total.
const PIXEL_RENDER_HEIGHT := 216
var _pixel_font: FontFile
var _retro_shader: Shader

enum State { COUNTDOWN, RACING, FINISHED }

var track: Track
var cars: Array[Car] = []
var cameras: Array[Camera3D] = []
var viewports: Array[SubViewport] = []
var viewport_containers: Array[SubViewportContainer] = []

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
	_pixel_font = load("res://assets/fonts/PressStart2P-Regular.ttf")
	_pixel_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	_pixel_font.hinting = TextServer.HINTING_NONE
	_pixel_font.oversampling = 1.0
	_retro_shader = load("res://shaders/retro_palette.gdshader")

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
	sun.light_energy = 1.35
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = true
	add_child(sun)

	# Céu chapado em vez de gradiente suave: consoles 16-bit desenhavam o
	# fundo em faixas de cor sólida, não em degradê contínuo. Só duas cores
	# (céu e "montanhas" no horizonte) já lê como retrô.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.34, 0.62, 0.93)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.68, 0.75)
	e.ambient_light_energy = 1.1
	e.fog_enabled = true
	e.fog_density = 0.0022
	e.fog_light_color = Color(0.34, 0.62, 0.93)
	e.fog_sun_scatter = 0.0
	# posterizar o brilho geral tambem ajuda a achatar a iluminacao em faixas,
	# em vez do gradiente continuo que um motor 3D moderno produz por padrao
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.35
	e.adjustment_contrast = 1.12
	env.environment = e
	add_child(env)

	var horizon := MeshInstance3D.new()
	var horizon_mesh := CylinderMesh.new()
	horizon_mesh.top_radius = 480.0
	horizon_mesh.bottom_radius = 480.0
	horizon_mesh.height = 90.0
	horizon_mesh.cap_top = false
	horizon_mesh.cap_bottom = false
	var horizon_mat := StandardMaterial3D.new()
	horizon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	horizon_mat.albedo_color = Color(0.45, 0.7, 0.95)
	horizon_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	horizon_mesh.material = horizon_mat
	horizon.mesh = horizon_mesh
	horizon.position.y = 20.0
	add_child(horizon)

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
		# MSAA suaviza bordas — o oposto do que queremos: pixel de verdade,
		# não um triângulo por trás de anti-serrilhado.
		vp.msaa_3d = Viewport.MSAA_DISABLED

		var cam := Camera3D.new()
		cam.fov = 68.0
		cam.far = 900.0
		vp.add_child(cam)

		# Filtro nearest: ao ampliar o render de baixa resolução pro tamanho
		# da tela, cada pixel vira um quadrado sólido em vez de borrar.
		container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var palette := ShaderMaterial.new()
		palette.shader = _retro_shader
		container.material = palette

		container.add_child(vp)
		_split.add_child(container)

		viewports.append(vp)
		cameras.append(cam)
		viewport_containers.append(container)

	# a tela 2 mostra o MESMO mundo da tela 1 — sem isso cada metade
	# renderaria um mundo vazio e separado
	viewports[1].world_3d = viewports[0].world_3d

func _resize_viewports() -> void:
	var size := get_viewport().get_visible_rect().size
	_split.size = size

	# O CONTAINER acompanha o tamanho real da tela (senão o layout quebra);
	# o VIEWPORT interno é que renderiza baixo, e o filtro nearest amplia
	# sem suavizar — isso é a pixelização em si.
	var half_screen := Vector2i(int(size.x / 2.0) - 2, int(size.y))
	var aspect: float = float(half_screen.x) / float(maxi(half_screen.y, 1))
	var low_res := Vector2i(int(PIXEL_RENDER_HEIGHT * aspect), PIXEL_RENDER_HEIGHT)

	for i in viewports.size():
		viewport_containers[i].custom_minimum_size = Vector2(half_screen)
		viewports[i].size = low_res

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
		label.add_theme_font_override("font", _pixel_font)
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_constant_override("line_spacing", 10)
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		label.add_theme_constant_override("outline_size", 4)
		_hud.add_child(label)
		_labels.append(label)

	_center_label = Label.new()
	_center_label.add_theme_font_override("font", _pixel_font)
	_center_label.add_theme_font_size_override("font_size", 36)
	_center_label.add_theme_color_override("font_color", Color(1, 0.92, 0.25))
	_center_label.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.02, 1))
	_center_label.add_theme_constant_override("outline_size", 8)
	_center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_center_label)

	_sub_label = Label.new()
	_sub_label.add_theme_font_override("font", _pixel_font)
	_sub_label.add_theme_font_size_override("font_size", 13)
	_sub_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_sub_label.add_theme_constant_override("outline_size", 4)
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
