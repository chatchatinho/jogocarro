class_name Track
extends Node3D

## Circuito fechado gerado a partir de uma curva. Constrói:
##  - malha de asfalto com linhas e zebras (cores por vértice, uma malha só)
##  - muros dos dois lados, como caixas de colisão sob um único StaticBody3D
##  - grama e a grade de largada
## Também expõe a curva, que é usada para medir progresso, voltas e posição
## na corrida — mais confiável do que gatilhos de checkpoint, e impede atalhos.

const ROAD_HALF_WIDTH := 8.0
const KERB_WIDTH := 1.2
const WALL_HEIGHT := 1.6
const WALL_THICKNESS := 0.8
const SEGMENTS := 260

var curve := Curve3D.new()
var curve_length := 0.0

var _samples: PackedVector3Array = []
var _sample_offsets: PackedFloat32Array = []

func _ready() -> void:
	_build_curve()
	curve_length = curve.get_baked_length()
	_cache_samples()
	_build_ground()
	_build_road()
	_build_walls()

# ---------------------------------------------------------------- curva

func _build_curve() -> void:
	# Raio modulado: gera retas longas e curvas de raios diferentes,
	# em vez de um círculo constante que ficaria monótono de correr.
	var base_radius := 95.0
	var count := 12
	for i in count:
		var angle := TAU * float(i) / float(count)
		var radius: float = base_radius * (1.0 + 0.22 * sin(angle * 2.0) + 0.10 * cos(angle * 3.0))
		curve.add_point(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	# fecha o circuito
	curve.add_point(curve.get_point_position(0))
	curve.bake_interval = 1.0

func _cache_samples() -> void:
	_samples = PackedVector3Array()
	_sample_offsets = PackedFloat32Array()
	for i in SEGMENTS:
		var offset: float = curve_length * float(i) / float(SEGMENTS)
		_samples.append(curve.sample_baked(offset))
		_sample_offsets.append(offset)

## Distância percorrida ao longo da pista para uma posição no mundo.
## É com isso que a corrida sabe quem está na frente e quando a volta virou.
func progress_at(world_pos: Vector3) -> float:
	var best_offset := 0.0
	var best_dist := INF
	for i in _samples.size():
		var d: float = _samples[i].distance_squared_to(world_pos)
		if d < best_dist:
			best_dist = d
			best_offset = _sample_offsets[i]
	return best_offset

## Distância lateral até o eixo da pista (usado para detectar carro fora da pista).
func lateral_offset(world_pos: Vector3) -> float:
	var offset := progress_at(world_pos)
	var center := curve.sample_baked(offset)
	return Vector2(world_pos.x - center.x, world_pos.z - center.z).length()

func point_at(offset: float) -> Vector3:
	return curve.sample_baked(fposmod(offset, curve_length))

func forward_at(offset: float) -> Vector3:
	var a := point_at(offset)
	var b := point_at(offset + 2.0)
	return (b - a).normalized()

func right_at(offset: float) -> Vector3:
	return Vector3.UP.cross(forward_at(offset)).normalized()

# ---------------------------------------------------------------- geometria

func _build_ground() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200, 1200)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.62, 0.22)
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	plane.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position.y = -0.05
	add_child(mi)

	# chão sólido: garante que nunca exista "vazio" sob os carros
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1200, 1.0, 1200)
	shape.shape = box
	shape.position.y = -0.55
	body.add_child(shape)
	add_child(body)

func _build_road() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var asphalt := Color(0.26, 0.26, 0.30)
	var asphalt_alt := Color(0.22, 0.22, 0.26)
	var line := Color(0.92, 0.92, 0.85)
	var kerb_a := Color(0.85, 0.14, 0.1)
	var kerb_b := Color(0.95, 0.95, 0.95)
	var start := Color(0.97, 0.97, 0.97)

	var hw := ROAD_HALF_WIDTH
	var lw := 0.25

	# Cada faixa tem vértices próprios. Vértices compartilhados fariam a cor
	# interpolar por toda a largura e a linha viraria um degradê branco.
	var strips := [
		{"from": -hw - KERB_WIDTH, "to": -hw, "y": 0.05, "kerb": true},
		{"from": -hw, "to": -hw + lw, "y": 0.011, "color": line},
		{"from": -hw + lw, "to": -0.12, "y": 0.01, "road": true},
		{"from": -0.12, "to": 0.12, "y": 0.011, "dash": true},
		{"from": 0.12, "to": hw - lw, "y": 0.01, "road": true},
		{"from": hw - lw, "to": hw, "y": 0.011, "color": line},
		{"from": hw, "to": hw + KERB_WIDTH, "y": 0.05, "kerb": true},
	]

	for strip: Dictionary in strips:
		for i in SEGMENTS:
			var o0: float = curve_length * float(i) / float(SEGMENTS)
			var o1: float = curve_length * float(i + 1) / float(SEGMENTS)

			var color: Color = asphalt
			if strip.has("kerb"):
				color = kerb_a if (i / 4) % 2 == 0 else kerb_b
			elif strip.has("color"):
				color = strip["color"]
			elif strip.has("dash"):
				color = line if (i / 5) % 2 == 0 else asphalt
			elif strip.has("road"):
				color = asphalt if i % 2 == 0 else asphalt_alt
			if i < 3 and not strip.has("kerb"):
				color = start

			var y := float(strip["y"])
			var a := _edge_point(o0, float(strip["from"]), y)
			var b := _edge_point(o0, float(strip["to"]), y)
			var c := _edge_point(o1, float(strip["from"]), y)
			var d := _edge_point(o1, float(strip["to"]), y)

			# Ordem no sentido horário: o Godot trata como face frontal o winding
			# horário, ao contrário da convenção do OpenGL. Com a ordem invertida
			# a pista inteira era descartada pelo culling e ficava invisível.
			for v: Vector3 in [a, b, c, b, d, c]:
				st.set_color(color)
				st.set_normal(Vector3.UP)
				st.add_vertex(v)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	st.set_material(mat)

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	add_child(mi)
	mi.create_trimesh_collision()

func _edge_point(offset: float, side: float, height: float) -> Vector3:
	var center := point_at(offset)
	var right := right_at(offset)
	return center + right * side + Vector3.UP * height

func _build_walls() -> void:
	# Um único StaticBody3D com muitas caixas: colisão sólida (nada de parede
	# fina que o carro atravessa em velocidade) sem encher a cena de nós.
	var body := StaticBody3D.new()
	add_child(body)

	var mesh := BoxMesh.new()
	mesh.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, 1.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.88, 0.88, 0.9)
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.material = mat

	var wall_offset := ROAD_HALF_WIDTH + KERB_WIDTH + 0.5
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = SEGMENTS * 2

	var index := 0
	for side: float in [-1.0, 1.0]:
		for i in SEGMENTS:
			var o0: float = curve_length * float(i) / float(SEGMENTS)
			var o1: float = curve_length * float(i + 1) / float(SEGMENTS)
			var p0 := point_at(o0) + right_at(o0) * (wall_offset * side)
			var p1 := point_at(o1) + right_at(o1) * (wall_offset * side)

			var mid := (p0 + p1) * 0.5 + Vector3.UP * (WALL_HEIGHT * 0.5)
			var length: float = maxf(p0.distance_to(p1), 0.5) * 1.08
			var dir := (p1 - p0).normalized()
			if dir.length() < 0.5:
				dir = Vector3.FORWARD

			var basis := Basis.looking_at(dir, Vector3.UP)

			# Basis.scaled() escala nos eixos GLOBAIS; para esticar o muro no
			# comprimento dele é preciso multiplicar pela direita (eixo local),
			# senão os segmentos saem com tamanho errado e ficam com vãos.
			var stretched := basis * Basis.from_scale(Vector3(1, 1, length))
			multi.set_instance_transform(index, Transform3D(stretched, mid))
			index += 1

			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, length)
			shape.shape = box
			shape.transform = Transform3D(basis, mid)
			body.add_child(shape)

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multi
	add_child(mmi)

## Posição da grade de largada para o carro `index` (0 ou 1).
func grid_transform(index: int) -> Transform3D:
	# Depois da linha de largada (offset 0), senão a primeira volta duraria
	# poucos metros: o carro cruzaria a linha logo na saída.
	var offset: float = 10.0 + float(index) * 7.0
	var pos := point_at(offset)
	var fwd := forward_at(offset)
	var side := right_at(offset) * (3.0 if index == 0 else -3.0)
	var origin := pos + side + Vector3.UP * 0.9
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), origin)
