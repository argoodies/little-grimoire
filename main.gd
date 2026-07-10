extends Node3D
## 小魔典 — 3D 拼图。9 片带微厚度的拼图片在空中轻轻晃动；
## 点击一片让它沿随机轴翻转 180°。可缩放/旋转视角，保留日/夜灯光切换。
## 拼图形状与贴图由 gen_puzzle.py 预生成（puzzle.json + textures/piece_N.png）。
## iOS 与 Web（GitHub Pages）同一套代码，场景全部脚本生成。

const SCALE := 0.82                     # 拼图世界缩放（单元格 1.0 → 3D）
const THICK := 0.05                     # 拼图厚度
const ROT_SENS := 0.006                 # 拖拽旋转灵敏度（弧度/像素）
const MIN_ZOOM := 2.4
const MAX_ZOOM := 9.0
const CREAM := Color(0.97, 0.955, 0.925)
const BLUE := Color(0.11, 0.41, 0.75)

var _camera: Camera3D
var _world: Node3D                      # 所有拼图片的枢轴，拖拽旋转
var _pieces: Array[Node3D] = []
var _touches := {}
var _pinching := false
var _pinch_dist := 0.0

var _manual_rot := Vector3.ZERO
var _rotating := false
var _press_screen := Vector2.ZERO
var _press_moved := false
var _pressed_piece: Node3D = null
var _t := 0.0

var _sfx_flip: AudioStreamPlayer
var _dir: DirectionalLight3D
var _spot: SpotLight3D
var _env: Environment
var _night := false
var _toggle_btn: Button

func _ready() -> void:
	randomize()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_world = Node3D.new()
	add_child(_world)
	_build_pieces()
	_build_toggle()

# ---------- 基础环境 ----------

func _build_audio() -> void:
	_sfx_flip = AudioStreamPlayer.new()
	_sfx_flip.stream = load("res://sounds/shroud.wav")   # 翻片的“呼”声
	_sfx_flip.volume_db = 0.0
	add_child(_sfx_flip)

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.05, 0.03, 0.09)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.42, 0.36, 0.52)
	_env.ambient_light_energy = 0.5
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)
	_camera.position = Vector3(0.0, 0.5, 5.2)   # 基本正对拼图平面，略俯视
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true

func _build_lights() -> void:
	_dir = DirectionalLight3D.new()
	_dir.rotation_degrees = Vector3(-34.0, -22.0, 0.0)
	_dir.light_color = Color(1.0, 0.94, 0.85)
	_dir.light_energy = 1.0
	_dir.shadow_enabled = false
	add_child(_dir)
	_spot = SpotLight3D.new()
	add_child(_spot)
	_spot.position = Vector3(0.0, 1.4, 4.2)
	_spot.look_at(Vector3.ZERO, Vector3.UP)
	_spot.light_color = Color(1.0, 0.88, 0.66)
	_spot.light_energy = 5.0
	_spot.spot_range = 12.0
	_spot.spot_angle = 46.0
	_spot.spot_attenuation = 1.1
	_spot.shadow_enabled = false

# ---------- 日/夜切换按钮 ----------

func _build_toggle() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_toggle_btn = Button.new()
	_toggle_btn.flat = true
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	_toggle_btn.anchor_left = 0.0
	_toggle_btn.anchor_right = 0.0
	var emoji_font := load("res://fonts/NotoEmoji-toggle.ttf")
	_toggle_btn.add_theme_font_override("font", emoji_font)
	_toggle_btn.add_theme_font_size_override("font_size", 108)
	_toggle_btn.text = "☀️"
	_toggle_btn.pressed.connect(_on_toggle)
	layer.add_child(_toggle_btn)
	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)

# 把日/夜按钮放进系统安全区（刘海/灵动岛/圆角）内。
func _apply_safe_area() -> void:
	var btn := 144.0
	var m := 40.0
	var vis := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	var top := m
	var left := m
	if win.x > 1.0 and win.y > 1.0:
		var sc := Vector2(vis.x / win.x, vis.y / win.y)
		var safe := DisplayServer.get_display_safe_area()
		top = safe.position.y * sc.y + m
		left = safe.position.x * sc.x + m
	_toggle_btn.offset_left = left
	_toggle_btn.offset_right = left + btn
	_toggle_btn.offset_top = top
	_toggle_btn.offset_bottom = top + btn

func _on_toggle() -> void:
	_night = not _night
	_apply_lighting(true)

func _apply_lighting(animate: bool) -> void:
	var dir_c := Color(0.62, 0.74, 1.0) if _night else Color(1.0, 0.94, 0.85)
	var spot_c := Color(0.5, 0.68, 1.0) if _night else Color(1.0, 0.88, 0.66)
	var bg_c := Color(0.02, 0.03, 0.09) if _night else Color(0.05, 0.03, 0.09)
	var amb_c := Color(0.30, 0.40, 0.60) if _night else Color(0.42, 0.36, 0.52)
	_toggle_btn.text = "🌙" if _night else "☀️"
	if animate:
		var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
		tw.tween_property(_dir, "light_color", dir_c, 0.5)
		tw.tween_property(_spot, "light_color", spot_c, 0.5)
		tw.tween_property(_env, "background_color", bg_c, 0.5)
		tw.tween_property(_env, "ambient_light_color", amb_c, 0.5)
	else:
		_dir.light_color = dir_c
		_spot.light_color = spot_c
		_env.background_color = bg_c
		_env.ambient_light_color = amb_c

# ---------- 拼图片 ----------

func _build_pieces() -> void:
	var f := FileAccess.open("res://puzzle.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	for pc in data.pieces:
		var verts: Array = pc.verts
		var uvs: Array = pc.uvs
		var body := StaticBody3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = _piece_mesh(verts, uvs, load(pc.tex))
		body.add_child(mi)
		# 碰撞盒（点击检测用），按包围盒近似。
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(float(pc.size[0]) * SCALE, float(pc.size[1]) * SCALE, THICK * 1.5)
		col.shape = box
		body.add_child(col)
		# 位置：拼图平面 + 每片一点随机深度，制造“悬浮”层次。
		var base_pos := Vector3(float(pc.pos[0]) * SCALE, float(pc.pos[1]) * SCALE, randf_range(-0.18, 0.18))
		body.position = base_pos
		body.set_meta("base_pos", base_pos)
		body.set_meta("base_quat", Quaternion.IDENTITY)
		body.set_meta("ph", Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
		body.set_meta("sp", Vector3(randf_range(0.5, 0.9), randf_range(0.4, 0.7), randf_range(0.5, 0.8)))
		body.set_meta("token", true)
		_world.add_child(body)
		_pieces.append(body)

# 由 2D 多边形轮廓生成带厚度的拼图网格：面 0=正反面（贴图），面 1=侧壁（蓝）。
func _piece_mesh(verts: Array, uvs: Array, tex: Texture2D) -> ArrayMesh:
	var poly := PackedVector2Array()
	for v in verts:
		poly.append(Vector2(float(v[0]) * SCALE, float(v[1]) * SCALE))
	var tri := Geometry2D.triangulate_polygon(poly)
	var hz := THICK * 0.5

	# --- 面 0：正反面 ---
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	for k in range(0, tri.size(), 3):
		var a: int = tri[k]
		var b: int = tri[k + 1]
		var c: int = tri[k + 2]
		# 正面（+Z，朝相机）
		for idx in [a, b, c]:
			st.set_normal(Vector3(0, 0, 1))
			st.set_uv(Vector2(uvs[idx][0], uvs[idx][1]))
			st.add_vertex(Vector3(poly[idx].x, poly[idx].y, hz))
		# 背面（-Z，反向缠绕）
		for idx in [c, b, a]:
			st.set_normal(Vector3(0, 0, -1))
			st.set_uv(Vector2(uvs[idx][0], uvs[idx][1]))
			st.add_vertex(Vector3(poly[idx].x, poly[idx].y, -hz))
	var face_mat := StandardMaterial3D.new()
	face_mat.albedo_texture = tex
	face_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	face_mat.alpha_scissor_threshold = 0.4
	face_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	face_mat.roughness = 0.9
	face_mat.metallic = 0.0
	face_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	st.set_material(face_mat)
	var mesh: ArrayMesh = st.commit()

	# --- 面 1：侧壁 ---
	var sw := SurfaceTool.new()
	sw.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n:
		var pa := poly[i]
		var pb := poly[(i + 1) % n]
		var edge := (pb - pa)
		if edge.length() < 0.0001:
			continue
		var dir := edge.normalized()
		var nrm := Vector3(dir.y, -dir.x, 0.0)   # CCW 多边形外法线
		var ta := Vector3(pa.x, pa.y, hz)
		var tb := Vector3(pb.x, pb.y, hz)
		var ba := Vector3(pa.x, pa.y, -hz)
		var bb := Vector3(pb.x, pb.y, -hz)
		for vtx in [ta, tb, bb, ta, bb, ba]:
			sw.set_normal(nrm)
			sw.set_uv(Vector2.ZERO)
			sw.add_vertex(vtx)
	var side_mat := StandardMaterial3D.new()
	side_mat.albedo_color = BLUE
	side_mat.roughness = 0.55
	side_mat.metallic = 0.25
	side_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sw.set_material(side_mat)
	mesh = sw.commit(mesh)
	return mesh

# 点击：让拼图沿随机轴翻转 180°（在其当前朝向基础上叠加，绕世界轴）。
func _flip(piece: Node3D) -> void:
	_sfx_flip.play()
	Input.vibrate_handheld(20)
	var axis := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	if axis.length() < 0.01:
		axis = Vector3.RIGHT
	axis = axis.normalized()
	var flip := Quaternion(axis, PI)
	var from_q: Quaternion = piece.get_meta("base_quat")
	var to_q := (flip * from_q).normalized()
	var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(
		func(w: float): piece.set_meta("base_quat", from_q.slerp(to_q, w)),
		0.0, 1.0, 0.55)

# ---------- 每帧：视角旋转 + 每片悬浮轻晃 ----------

func _process(delta: float) -> void:
	_t += delta
	var target := Vector3(_manual_rot.x, _manual_rot.y, 0.0)
	var weight := 1.0 - pow(0.002, delta)
	_world.rotation = _world.rotation.lerp(target, weight)
	for p in _pieces:
		var base_pos: Vector3 = p.get_meta("base_pos")
		var base_q: Quaternion = p.get_meta("base_quat")
		var ph: Vector3 = p.get_meta("ph")
		var sp: Vector3 = p.get_meta("sp")
		var bob := Vector3(
			sin(_t * sp.x + ph.x) * 0.03,
			sin(_t * sp.y + ph.y) * 0.05,
			sin(_t * sp.z + ph.z) * 0.03)
		var sway := Basis.from_euler(Vector3(
			sin(_t * sp.y + ph.y) * 0.12,
			sin(_t * sp.z + ph.z) * 0.10,
			sin(_t * sp.x + ph.z) * 0.12))
		p.transform = Transform3D(Basis(base_q) * sway, base_pos + bob)

# ---------- 输入：缩放 / 旋转视角 / 点击翻片 ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() >= 2:
			_pinching = true
			_pressed_piece = null
			_rotating = false
			_pinch_dist = _two_touch_dist()
			return
		else:
			_pinching = false
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _pinching and _touches.size() >= 2:
			var d := _two_touch_dist()
			if _pinch_dist > 1.0 and d > 1.0:
				_zoom_by(_pinch_dist / d)
			_pinch_dist = d
			return
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)
		return
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(0.9)
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 0.9)
			return

	if _pinching:
		return

	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			_pressed_piece = _pick(event.position)   # 命中的拼图（可能为 null）
			_press_screen = event.position
			_press_moved = false
			_rotating = true                         # 任意拖拽都旋转视角
		else:
			if not _press_moved and _pressed_piece != null:
				_flip(_pressed_piece)                # 干净单击拼图 → 翻转
			_pressed_piece = null
			_rotating = false
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		if _rotating:
			if not _press_moved and event.position.distance_to(_press_screen) > 14.0:
				_press_moved = true
			_rotate_by(event.relative)

func _pick(screen_pos: Vector2) -> Node3D:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 100.0)
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.collider.has_meta("token"):
		return hit.collider
	return null

func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

func _two_touch_dist() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _zoom_by(ratio: float) -> void:
	var d := clampf(_camera.position.length() * ratio, MIN_ZOOM, MAX_ZOOM)
	_camera.position = _camera.position.normalized() * d
	_camera.look_at(Vector3.ZERO, Vector3.UP)
