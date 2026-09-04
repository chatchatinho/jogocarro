class_name Car
extends RigidBody3D

## Carro arcade-sim: suspensão por raycast em cada roda, transferência de peso
## real (a carga vertical de cada roda sai da suspensão) e aderência lateral que
## satura — é a saturação que produz deslizamento e drift, sem "modo drift".

const WHEEL_RADIUS := 0.33
const SUSPENSION_REST := 0.35
const SUSPENSION_STIFFNESS := 48000.0
const SUSPENSION_DAMPING := 4200.0

const MAX_DRIVE_FORCE := 11500.0
const MAX_BRAKE_FORCE := 13000.0
const REVERSE_FORCE := 3400.0
const TOP_SPEED_MS := 62.0

# 26° já é bastante para tecla: com 34° o carro pedia raio de curva de ~4 m
# em qualquer toque, saturava os pneus e raspava toda a velocidade.
const MAX_STEER_DEG := 26.0
const MIN_STEER_DEG := 9.0
const STEER_SPEED := 3.2

const GRIP_FRONT := 1.75
const GRIP_REAR := 1.55
# Rigidez alta = o pneu 'morde' logo; baixa demais deixava o carro deslizando
# de lado o tempo todo, comendo a aderência que faltava para acelerar.
const LATERAL_STIFFNESS := 13000.0
const SLIDE_FALLOFF := 0.86
const DRAG := 2.6
const ROLL_RESIST := 12.0

var player_index := 0
var car_color := Color.RED
var controls_enabled := false

var throttle := 0.0
var brake_input := 0.0
var steer_input := 0.0
var steer_angle := 0.0

var lap := 0
var progress := 0.0
var last_progress := 0.0
var finished := false
var finish_time := 0.0

var _wheels: Array = []
var _wheel_nodes: Array[Node3D] = []
var _grounded_count := 0
var _slip_amount := 0.0
## Só conta volta depois de passar da metade do circuito (evita contar
## volta por causa de tremida do carro em cima da linha).
var half_lap_done := false
## Tempo acumulado capotado ou parado, para o resgate automático.
var stuck_time := 0.0

func _ready() -> void:
	mass = 1200.0
	# Centro de massa abaixo do centro geométrico: um CoM alto capota o carro
	# em qualquer curva forte.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.35, 0)
	continuous_cd = true
	max_contacts_reported = 4
	contact_monitor = true
	angular_damp = 1.2
	linear_damp = 0.0

	_build_body()
	_build_wheels()

func _build_body() -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.75, 0.95, 4.2)
	shape.shape = box
	shape.position.y = 0.15
	add_child(shape)

	var paint := StandardMaterial3D.new()
	paint.albedo_color = car_color
	paint.metallic = 0.55
	paint.roughness = 0.32

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.08, 0.11, 0.16)
	glass.metallic = 0.2
	glass.roughness = 0.08

	# carroceria em duas caixas: corpo + cabine mais estreita, o suficiente para
	# ler como carro e para o jogador enxergar a direção em que está apontado
	var lower := MeshInstance3D.new()
	var lower_mesh := BoxMesh.new()
	lower_mesh.size = Vector3(1.75, 0.62, 4.2)
	lower_mesh.material = paint
	lower.mesh = lower_mesh
	lower.position.y = 0.02
	add_child(lower)

	var cabin := MeshInstance3D.new()
	var cabin_mesh := BoxMesh.new()
	cabin_mesh.size = Vector3(1.5, 0.5, 2.0)
	cabin_mesh.material = glass
	cabin.mesh = cabin_mesh
	cabin.position = Vector3(0, 0.5, -0.15)
	add_child(cabin)

	var nose := MeshInstance3D.new()
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(1.5, 0.16, 0.35)
	nose_mesh.material = paint
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 0.34, 2.0)
	add_child(nose)

	# lanternas: dizem de relance para onde o carro está virado
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.9, 0.1, 0.1)
	tail_mat.emission_enabled = true
	tail_mat.emission = Color(1.0, 0.15, 0.1)
	tail_mat.emission_energy_multiplier = 1.4
	for side: float in [-1.0, 1.0]:
		var lamp := MeshInstance3D.new()
		var lamp_mesh := BoxMesh.new()
		lamp_mesh.size = Vector3(0.4, 0.14, 0.1)
		lamp_mesh.material = tail_mat
		lamp.mesh = lamp_mesh
		lamp.position = Vector3(side * 0.55, 0.28, -2.1)
		add_child(lamp)

func _build_wheels() -> void:
	var half_track := 0.78
	var front_z := 1.35
	var rear_z := -1.35
	var wheel_y := -0.18

	_wheels = [
		{"pos": Vector3(-half_track, wheel_y, front_z), "steer": true, "drive": false, "grip": GRIP_FRONT},
		{"pos": Vector3(half_track, wheel_y, front_z), "steer": true, "drive": false, "grip": GRIP_FRONT},
		{"pos": Vector3(-half_track, wheel_y, rear_z), "steer": false, "drive": true, "grip": GRIP_REAR},
		{"pos": Vector3(half_track, wheel_y, rear_z), "steer": false, "drive": true, "grip": GRIP_REAR},
	]

	var tire := StandardMaterial3D.new()
	tire.albedo_color = Color(0.07, 0.07, 0.08)
	tire.roughness = 0.95

	for wheel: Dictionary in _wheels:
		var node := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = WHEEL_RADIUS
		mesh.bottom_radius = WHEEL_RADIUS
		mesh.height = 0.26
		mesh.material = tire
		node.mesh = mesh
		node.rotation_degrees = Vector3(0, 0, 90)
		add_child(node)
		_wheel_nodes.append(node)

func _physics_process(delta: float) -> void:
	_read_input(delta)
	_update_wheel_visuals()

func _read_input(delta: float) -> void:
	if not controls_enabled or finished:
		throttle = 0.0
		brake_input = 1.0 if finished else 0.0
		steer_input = 0.0
	else:
		var keys := Input2P.keys_for(player_index)
		throttle = 1.0 if Input.is_physical_key_pressed(keys.up) else 0.0
		brake_input = 1.0 if Input.is_physical_key_pressed(keys.down) else 0.0
		var s := 0.0
		if Input.is_physical_key_pressed(keys.left):
			s -= 1.0
		if Input.is_physical_key_pressed(keys.right):
			s += 1.0
		steer_input = s

	# esterço diminui com a velocidade: mantém o carro dirigível em alta
	var speed := linear_velocity.length()
	var speed_factor: float = clampf(speed / TOP_SPEED_MS, 0.0, 1.0)
	var max_angle: float = deg_to_rad(lerpf(MAX_STEER_DEG, MIN_STEER_DEG, speed_factor))
	steer_angle = move_toward(steer_angle, steer_input * max_angle, STEER_SPEED * max_angle * delta)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var space := state.get_space_state()
	var com := global_transform * center_of_mass
	_grounded_count = 0
	var max_slip := 0.0

	for i in _wheels.size():
		var wheel: Dictionary = _wheels[i]
		var attach: Vector3 = global_transform * wheel["pos"]
		var down: Vector3 = -global_transform.basis.y
		var ray_length: float = SUSPENSION_REST + WHEEL_RADIUS

		var query := PhysicsRayQueryParameters3D.create(attach, attach + down * ray_length)
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue

		_grounded_count += 1
		var contact: Vector3 = hit["position"]
		var distance: float = attach.distance_to(contact)
		var compression: float = ray_length - distance

		# --- suspensão -> carga vertical (é daqui que sai a transferência de peso)
		var up: Vector3 = global_transform.basis.y
		var point_vel: Vector3 = state.linear_velocity + state.angular_velocity.cross(contact - com)
		var compress_speed: float = -point_vel.dot(up)
		var load: float = maxf(0.0, compression * SUSPENSION_STIFFNESS + compress_speed * SUSPENSION_DAMPING)
		state.apply_force(up * load, contact - com)

		# --- direções da roda no plano de contato
		var steer := steer_angle if wheel["steer"] else 0.0
		var basis := global_transform.basis.rotated(global_transform.basis.y.normalized(), steer)
		var forward: Vector3 = -basis.z.normalized()
		var right: Vector3 = basis.x.normalized()

		var v_forward: float = point_vel.dot(forward)
		var v_right: float = point_vel.dot(right)

		var grip_limit: float = load * float(wheel["grip"])

		# --- força lateral: linear até saturar; saturada = deslizando
		var lateral: float = -v_right * LATERAL_STIFFNESS * 0.25
		if absf(lateral) > grip_limit:
			lateral = signf(lateral) * grip_limit * SLIDE_FALLOFF
			max_slip = maxf(max_slip, minf(absf(v_right) / 6.0, 1.0))
		lateral = clampf(lateral, -grip_limit, grip_limit)

		# --- força longitudinal: tração nas traseiras, freio em todas
		var longitudinal := 0.0
		if wheel["drive"]:
			var speed_factor: float = clampf(1.0 - absf(v_forward) / TOP_SPEED_MS, 0.0, 1.0)
			longitudinal += throttle * MAX_DRIVE_FORCE * speed_factor * 0.5

		if brake_input > 0.0:
			if v_forward > 0.5:
				longitudinal -= brake_input * MAX_BRAKE_FORCE * 0.25
			else:
				longitudinal -= brake_input * REVERSE_FORCE * 0.5

		# --- círculo de atrito: as duas forças disputam a mesma aderência
		var remaining: float = sqrt(maxf(0.0, grip_limit * grip_limit - lateral * lateral))
		longitudinal = clampf(longitudinal, -remaining, remaining)
		if absf(longitudinal) >= remaining - 1.0 and throttle > 0.0:
			max_slip = maxf(max_slip, 0.5)

		state.apply_force(forward * longitudinal + right * lateral, contact - com)

	_slip_amount = max_slip

	# arrasto e resistência ao rolamento
	var vel := state.linear_velocity
	state.apply_central_force(-vel * DRAG - vel.normalized() * ROLL_RESIST * float(_grounded_count))

func _update_wheel_visuals() -> void:
	for i in _wheel_nodes.size():
		var wheel: Dictionary = _wheels[i]
		var node: Node3D = _wheel_nodes[i]
		node.position = wheel["pos"] + Vector3(0, -SUSPENSION_REST * 0.45, 0)
		var steer := steer_angle if wheel["steer"] else 0.0
		node.rotation = Vector3(0, steer, deg_to_rad(90))

## 1 = de pé, 0 = de lado, -1 = capotado.
func uprightness() -> float:
	return global_transform.basis.y.dot(Vector3.UP)

func speed_kmh() -> float:
	return linear_velocity.length() * 3.6

func slip_amount() -> float:
	return _slip_amount

func is_grounded() -> bool:
	return _grounded_count > 0

func reset_to(xf: Transform3D) -> void:
	# teleporte precisa zerar velocidades, senão o carro "lembra" o tranco anterior
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = xf
	steer_angle = 0.0
	finished = false
	finish_time = 0.0
	lap = 0
	half_lap_done = false
	stuck_time = 0.0
