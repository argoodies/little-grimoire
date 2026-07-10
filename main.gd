extends Node3D
## 小魔典 — 水晶原石粉碎。原石是一块蓝水晶（由 GLB 体素化而来，crystal.json）。
## 触击并保持长按 → 持续粉碎接触处；按住拖动可挪动接触点，沿途一直粉碎。发出磨削“嗡嗡”声。
## 单指=粉碎；双指=缩放+旋转视角。保留日/夜灯光切换。iOS 与 Web 同一套代码。

const TARGET_W := 1.7                    # 水晶最长边的世界尺寸
const ROT_SENS := 0.006
const MIN_ZOOM := 2.0
const MAX_ZOOM := 8.0
const BR_WORLD := 0.06                   # 粉碎笔刷半径（世界单位）
const CRYSTAL := Color(0.16, 0.46, 0.92)

var _camera: Camera3D
var _world: Node3D
var _touches := {}
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO

var _manual_rot := Vector3.ZERO
var _rotating := false                    # 鼠标右键旋转
var _crushing := false
var _crush_screen := Vector2.ZERO

# 体素网格（模型索引：ix∈nx, iy∈ny=厚度, iz∈nz）
var _nx := 0
var _ny := 0
var _nz := 0
var _cell := 0.04
var _occ: PackedByteArray                 # 该体素是否还在
var _inst: PackedInt32Array               # 体素 → MultiMesh 实例号（-1=无）
var _mm: MultiMesh
var _brv := 2                             # 笔刷半径（体素）

var _sfx_buzz: AudioStreamPlayer
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
	_build_crystal()
	_build_toggle()

# ---------- 基础环境 ----------

func _build_audio() -> void:
	_sfx_buzz = AudioStreamPlayer.new()
	_sfx_buzz.stream = load("res://sounds/buzz.wav")
	_sfx_buzz.volume_db = 0.0
	add_child(_sfx_buzz)                            # 长按时在 _process 里循环续播成持续磨削声

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.05, 0.03, 0.09)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.42, 0.36, 0.52)
	_env.ambient_light_energy = 0.55
	_env.glow_enabled = true
	_env.glow_intensity = 1.1
	_env.glow_strength = 1.1
	_env.glow_bloom = 0.3
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	_env.glow_hdr_threshold = 0.85
	_env.set_glow_level(3, 1.0)
	_env.set_glow_level(4, 1.0)
	_env.set_glow_level(5, 0.6)
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)
	_camera.position = Vector3(0.0, 0.25, 3.6)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true

func _build_lights() -> void:
	_dir = DirectionalLight3D.new()
	_dir.rotation_degrees = Vector3(-34.0, -22.0, 0.0)
	_dir.light_color = Color(1.0, 0.94, 0.85)
	_dir.light_energy = 1.0
	add_child(_dir)
	_spot = SpotLight3D.new()
	add_child(_spot)
	_spot.position = Vector3(0.0, 1.3, 3.2)
	_spot.look_at(Vector3.ZERO, Vector3.UP)
	_spot.light_color = Color(1.0, 0.9, 0.72)
	_spot.light_energy = 7.0
	_spot.spot_range = 12.0
	_spot.spot_angle = 46.0
	_spot.spot_attenuation = 1.1

# ---------- 日/夜切换按钮 ----------

func _build_toggle() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_toggle_btn = Button.new()
	_toggle_btn.flat = true
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	var emoji_font := load("res://fonts/NotoEmoji-toggle.ttf")
	_toggle_btn.add_theme_font_override("font", emoji_font)
	_toggle_btn.add_theme_font_size_override("font_size", 108)
	_toggle_btn.text = "☀️"
	_toggle_btn.pressed.connect(_on_toggle)
	layer.add_child(_toggle_btn)
	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)

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
	var spot_c := Color(0.5, 0.68, 1.0) if _night else Color(1.0, 0.9, 0.72)
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

# ---------- 水晶原石（3D 体素） ----------

func _build_crystal() -> void:
	var f := FileAccess.open("res://crystal.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	_nx = int(data.nx)
	_ny = int(data.ny)
	_nz = int(data.nz)
	_cell = TARGET_W / float(max(_nx, _nz))
	_brv = int(ceil(BR_WORLD / _cell))

	var total := _nx * _ny * _nz
	_occ = PackedByteArray()
	_occ.resize(total)
	_inst = PackedInt32Array()
	_inst.resize(total)
	for i in total:
		_inst[i] = -1
	var voxels: Array = data.voxels

	var box := BoxMesh.new()
	box.size = Vector3(_cell, _cell, _cell)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(CRYSTAL.r, CRYSTAL.g, CRYSTAL.b, 0.72)   # 半透蓝水晶
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.metallic = 0.1
	mat.roughness = 0.08
	mat.metallic_specular = 0.95
	mat.rim_enabled = true
	mat.rim = 0.6
	mat.refraction_enabled = true
	mat.refraction_scale = 0.08
	mat.emission_enabled = true
	mat.emission = Color(0.08, 0.26, 0.6)
	mat.emission_energy_multiplier = 0.5
	box.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = box
	_mm.instance_count = voxels.size()

	for n in voxels.size():
		var flat := int(voxels[n])
		_occ[flat] = 1
		_inst[flat] = n
		_mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, _vox_world(flat)))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	_world.add_child(mmi)

# 模型体素 flat → 世界坐标（把模型薄轴 Y 映射为世界 Z 深度，大面朝相机）。
func _vox_world(flat: int) -> Vector3:
	var ix := flat % _nx
	var iy := (flat / _nx) % _ny
	var iz := flat / (_nx * _ny)
	return Vector3(
		(ix - _nx * 0.5 + 0.5) * _cell,
		(iz - _nz * 0.5 + 0.5) * _cell,
		(iy - _ny * 0.5 + 0.5) * _cell)

func _flat(ix: int, iy: int, iz: int) -> int:
	return iz * (_nx * _ny) + iy * _nx + ix

# ---------- 粉碎 ----------

# 沿相机射线找到接触到的第一个体素，然后按 3D 笔刷粉碎周围。
func _crush(screen_pos: Vector2) -> void:
	var wo := _camera.project_ray_origin(screen_pos)
	var wd := _camera.project_ray_normal(screen_pos)
	var lo := _world.to_local(wo)
	var ld := (_world.to_local(wo + wd) - lo).normalized()
	# 与网格 AABB 求交
	var hx := _nx * _cell * 0.5
	var hy := _nz * _cell * 0.5
	var hz := _ny * _cell * 0.5
	var t := _aabb_enter(lo, ld, Vector3(hx, hy, hz))
	if t.x > t.y:
		return
	var tt: float = maxf(t.x, 0.0)
	var step := _cell * 0.5
	while tt <= t.y:
		var p := lo + ld * tt
		var ix := int(floor(p.x / _cell + _nx * 0.5))
		var iy := int(floor(p.z / _cell + _ny * 0.5))     # 世界 Z ↔ 模型 Y
		var iz := int(floor(p.y / _cell + _nz * 0.5))     # 世界 Y ↔ 模型 Z
		if ix >= 0 and ix < _nx and iy >= 0 and iy < _ny and iz >= 0 and iz < _nz:
			if _occ[_flat(ix, iy, iz)] == 1:
				_crush_brush(ix, iy, iz)
				return
		tt += step

func _crush_brush(cx: int, cy: int, cz: int) -> void:
	var removed := false
	var r := _brv
	for dz in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dy * dy + dz * dz > r * r:
					continue
				var ix := cx + dx
				var iy := cy + dy
				var iz := cz + dz
				if ix < 0 or ix >= _nx or iy < 0 or iy >= _ny or iz < 0 or iz >= _nz:
					continue
				var fl := _flat(ix, iy, iz)
				if _occ[fl] == 0:
					continue
				_occ[fl] = 0
				var inst := _inst[fl]
				if inst >= 0:
					_mm.set_instance_transform(inst, Transform3D(Basis().scaled(Vector3.ZERO), _vox_world(fl)))
				removed = true
	if removed:
		Input.vibrate_handheld(12)

# 射线与中心在原点、半尺寸 h 的 AABB 求交，返回 (t_enter, t_exit)。
func _aabb_enter(o: Vector3, d: Vector3, h: Vector3) -> Vector2:
	var t0 := -INF
	var t1 := INF
	for i in 3:
		var oi := o[i]
		var di := d[i]
		var lo := -h[i]
		var hi := h[i]
		if absf(di) < 1e-9:
			if oi < lo or oi > hi:
				return Vector2(1.0, -1.0)
		else:
			var ta := (lo - oi) / di
			var tb := (hi - oi) / di
			if ta > tb:
				var tmp := ta; ta = tb; tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
	return Vector2(t0, t1)

# ---------- 每帧：持续粉碎 + 视角平滑 ----------

func _process(delta: float) -> void:
	if _crushing:
		_crush(_crush_screen)
		if not _sfx_buzz.playing:
			_sfx_buzz.play()                    # 续播，长按期间持续“嗡嗡”
	var target := Vector3(_manual_rot.x, _manual_rot.y, 0.0)
	var weight := 1.0 - pow(0.002, delta)
	_world.rotation = _world.rotation.lerp(target, weight)

# ---------- 输入 ----------

func _set_crushing(on: bool, pos: Vector2) -> void:
	if on and not _crushing:
		_crushing = true
		_crush_screen = pos
	elif not on and _crushing:
		_crushing = false
		_sfx_buzz.stop()

func _unhandled_input(event: InputEvent) -> void:
	# --- 触屏 ---
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() == 1:
			_set_crushing(true, _touches.values()[0])       # 单指 → 粉碎
		else:
			_set_crushing(false, Vector2.ZERO)              # 0 或 2 指 → 停止粉碎
			if _touches.size() == 2:
				_pinch_dist = _two_touch_dist()
				_pinch_mid = _two_touch_mid()
		return
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _touches.size() == 1:
			_crush_screen = event.position                  # 拖动 → 挪动接触点
		elif _touches.size() == 2:
			var d := _two_touch_dist()
			if _pinch_dist > 1.0 and d > 1.0:
				_zoom_by(_pinch_dist / d)
			_pinch_dist = d
			var mid := _two_touch_mid()
			_rotate_by(mid - _pinch_mid)                    # 双指平移 → 旋转视角
			_pinch_mid = mid
		return
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)
		return

	# --- 鼠标（桌面/Web） ---
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.pressed: _zoom_by(0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed: _zoom_by(1.0 / 0.9)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_set_crushing(event.pressed, event.position)    # 左键按住 → 粉碎
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = event.pressed                       # 右键拖 → 旋转视角
	elif event is InputEventMouseMotion:
		if _crushing:
			_crush_screen = event.position
		elif _rotating:
			_rotate_by(event.relative)

func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

func _two_touch_dist() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _two_touch_mid() -> Vector2:
	var pts := _touches.values()
	if pts.size() < 2:
		return Vector2.ZERO
	return ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5

func _zoom_by(ratio: float) -> void:
	var d := clampf(_camera.position.length() * ratio, MIN_ZOOM, MAX_ZOOM)
	_camera.position = _camera.position.normalized() * d
	_camera.look_at(Vector3.ZERO, Vector3.UP)
