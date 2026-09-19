extends CharacterBody3D
## A first-person player whose state is simulated authoritatively on the server.
##
## - Server: every player is moved from the latest input received from that client,
##   and its shots are resolved here (hitscan raycasts, damage, death, respawn).
## - Local client: predicts movement locally every frame, sends input + view
##   (yaw/pitch/shooting) to the server, and reconciles when a snapshot arrives.
##   The local camera (yaw/pitch) is locally authoritative and never overwritten.
## - Other clients: interpolate toward the latest server snapshot.

const SPEED := 8.0
const ACCELERATION := 40.0
const GRAVITY := -25.0
const JUMP_SPEED := 9.0
const SNAPSHOT_INTERVAL := 1.0 / 30.0
const RESIM_DT := 1.0 / 60.0
const REMOTE_SMOOTH := 10.0

const MAX_HEALTH := 100
const DAMAGE_PER_SHOT := 25
const SHOT_COOLDOWN := 0.15
const MAX_RANGE := 100.0
const RESPAWN_DELAY_MS := 3000
const EYE_HEIGHT := 1.6
const MOUSE_SENS := 0.0022

var my_peer_id: int = 0
var is_local := false
var game: Node = null
var _am_server := false

# Authoritative (server) state: the latest input received from this player's client.
var pending_input_dir := Vector2.ZERO
var pending_input_jump := false
var pending_input_shooting := false
var ack_tick := 0
var aim_pitch := 0.0
var _snap_acc := 0.0

# Prediction (local client): inputs applied locally but not yet confirmed by the server.
var input_queue: Array[Dictionary] = []
var client_tick := 0

# Remote interpolation (clients viewing other players).
var target_pos := Vector3.ZERO
var target_yaw := 0.0
var _has_snap := false

# Combat state (authoritative on the server, mirrored on clients via RPCs).
var health: int = MAX_HEALTH
var dead := false
var respawn_at := 0
var _spawn_pos := Vector3.ZERO
var _shoot_cd := 0.0

# Local first-person view state.
var _yaw := 0.0
var _pitch := 0.0
var _camera_rig: Node3D = null
var _viewmodel: Node3D = null
var _body_mesh: MeshInstance3D = null
var _hb_billboard: Node3D = null
var _hb_fg: MeshInstance3D = null
var _autotest := false
var _recon_count := 0


func setup(pid: int, spawn: Vector3, color: Color, game_node: Node) -> void:
	my_peer_id = pid
	game = game_node
	_spawn_pos = spawn
	position = spawn
	# game.multiplayer (not the bare `multiplayer` accessor): setup() may run
	# while this node is not yet in the tree, where the accessor is null.
	is_local = pid == game.multiplayer.get_unique_id()
	_am_server = game.multiplayer.is_server()
	_autotest = OS.get_cmdline_user_args().has("+autotest")
	if is_local:
		_build_camera()
		# First person: no visible body for yourself (collision only).
	else:
		_build_body(color)
		_build_health_bar()
	# Every player (local included) needs the collision shape: for movement on
	# server/local and so the player can be hit by hitscan shots on the server.
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.8, 1.8, 0.8)
	col.shape = shape
	col.position = Vector3(0, 0.9, 0)
	add_child(col)


func _build_body(color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 1.8, 0.8)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.set_surface_override_material(0, mat)
	mesh.position = Vector3(0, 0.9, 0)
	add_child(mesh)
	_body_mesh = mesh


func _build_camera() -> void:
	_camera_rig = Node3D.new()
	_camera_rig.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(_camera_rig)
	var cam := Camera3D.new()
	cam.fov = 75.0
	_camera_rig.add_child(cam)
	# Simple view-model gun (cosmetic, no collision).
	_viewmodel = Node3D.new()
	_viewmodel.position = Vector3(0.28, -0.26, -0.55)
	cam.add_child(_viewmodel)
	var vm_mat := StandardMaterial3D.new()
	vm_mat.albedo_color = Color(0.22, 0.22, 0.26)
	var vm_body := _make_box(Vector3(0.09, 0.14, 0.42), vm_mat)
	_viewmodel.add_child(vm_body)
	var vm_barrel := _make_box(Vector3(0.05, 0.05, 0.30), vm_mat)
	vm_barrel.position = Vector3(0, 0.02, -0.34)
	_viewmodel.add_child(vm_barrel)


func _build_health_bar() -> void:
	_hb_billboard = Node3D.new()
	_hb_billboard.position = Vector3(0, 2.2, 0)
	add_child(_hb_billboard)
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.35, 0.1, 0.1)
	var bg := _make_box(Vector3(0.95, 0.06, 0.06), bg_mat)
	_hb_billboard.add_child(bg)
	var fg_mat := StandardMaterial3D.new()
	fg_mat.albedo_color = Color(0.2, 0.9, 0.2)
	_hb_fg = _make_box(Vector3(0.9, 0.04, 0.04), fg_mat)
	_hb_fg.position = Vector3(0, 0, 0.01)
	_hb_billboard.add_child(_hb_fg)
	_hb_billboard.visible = false


func _make_box(size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.set_surface_override_material(0, mat)
	return mesh


# --- Input ---


func _read_input_dir() -> Vector2:
	if _autotest and not _am_server:
		return Vector2(0, -1)
	# Direct key checks: this project ships no [input] map in project.godot,
	# so the default ui_left/up/... actions are not available.
	var ix := 0.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		ix -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		ix += 1.0
	var iz := 0.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		iz -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		iz += 1.0
	return Vector2(ix, iz)


func _read_jump() -> bool:
	return Input.is_key_pressed(KEY_SPACE)


func _read_shooting() -> bool:
	if _autotest and not _am_server:
		return true
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


# --- First-person view (local player only) ---
# Mouse look is event-driven: this Godot build's Input singleton exposes no
# per-frame mouse motion getter, so the motion is read from InputEventMouseMotion.


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or dead or game == null or not is_inside_tree():
		return
	if _autotest and not _am_server:
		return
	var m := event as InputEventMouseMotion
	if m != null:
		_yaw -= m.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - m.relative.y * MOUSE_SENS, -1.45, 1.45)
		rotation.y = _yaw
		if _camera_rig != null:
			_camera_rig.rotation.x = _pitch


func _process(_dt: float) -> void:
	if not is_local or dead or game == null or not is_inside_tree():
		return
	if _autotest and not _am_server:
		_autotest_aim()


# +autotest: aim at and keep shooting the nearest other player (headless check
# of the full damage/death/respawn loop, since headless has no real mouse).
func _autotest_aim() -> void:
	var best: Node = null
	var best_d := 1e9
	for pid in game._players:
		if int(pid) == my_peer_id:
			continue
		var n: Node = game._players[pid]
		if n.dead:
			continue
		var d: Vector3 = (n.position + Vector3(0, EYE_HEIGHT, 0)) - (position + Vector3(0, EYE_HEIGHT, 0))
		var dl := d.length()
		if dl < best_d:
			best_d = dl
			best = n
	if best == null:
		return
	var d: Vector3 = (best.position + Vector3(0, EYE_HEIGHT, 0)) - (position + Vector3(0, EYE_HEIGHT, 0))
	var dist := maxf(d.length(), 0.001)
	_yaw = atan2(-d.x, -d.z)
	_pitch = asin(clampf(d.y / dist, -1.0, 1.0))
	rotation.y = _yaw
	if _camera_rig != null:
		_camera_rig.rotation.x = _pitch


# --- Shared deterministic movement (used on the server and in client prediction) ---
# The body yaw is the view yaw (set from the mouse locally / from the input RPC on
# the server), so no auto-facing is done here.


func apply_input(dir: Vector2, jump: bool, dt: float) -> void:
	var wish := transform.basis * Vector3(dir.x, 0.0, dir.y)
	if dir.length_squared() > 0.0001:
		wish = wish.normalized()

	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var target_flat := Vector3(wish.x * SPEED, 0.0, wish.z * SPEED)
	flat = flat.move_toward(target_flat, ACCELERATION * dt)
	velocity = Vector3(flat.x, velocity.y, flat.z)

	if is_on_floor():
		velocity.y = 0.0
		if jump:
			velocity.y = JUMP_SPEED
	else:
		velocity.y += GRAVITY * dt

	move_and_slide()


# --- Per-frame behavior by role ---


func _physics_process(dt: float) -> void:
	if game == null or not is_inside_tree():
		return
	if _am_server:
		_server_physics(dt)
	elif is_local:
		_local_physics(dt)
	else:
		_remote_physics(dt)


func _server_physics(dt: float) -> void:
	if is_local:
		# A listen server moves/aims its own player directly from the keyboard+mouse.
		pending_input_dir = _read_input_dir()
		pending_input_jump = _read_jump()
		pending_input_shooting = _read_shooting()
		aim_pitch = _pitch
	if dead:
		velocity = Vector3(0.0, velocity.y, 0.0)
		if Time.get_ticks_msec() >= respawn_at:
			position = _spawn_pos
			velocity = Vector3.ZERO
			health = MAX_HEALTH
			dead = false
			_shoot_cd = 0.0
			_refresh_visuals()
			game._on_player_respawn(my_peer_id, position)
		_send_snapshot()
		return
	apply_input(pending_input_dir, pending_input_jump, dt)
	_shoot_cd = maxf(_shoot_cd - dt, 0.0)
	if pending_input_shooting and _shoot_cd <= 0.0:
		_do_shoot()
		_shoot_cd = SHOT_COOLDOWN
	_send_snapshot()


func _send_snapshot() -> void:
	multiplayer.rpc(0, game, "rpc_snapshot", [my_peer_id, position, velocity, rotation.y, ack_tick])


func _local_physics(dt: float) -> void:
	if dead:
		return
	client_tick += 1
	var dir := _read_input_dir()
	var jump := _read_jump()
	var shooting := _read_shooting()
	input_queue.append({"dir": dir, "jump": jump, "tick": client_tick, "yaw": _yaw})
	if input_queue.size() > 300:
		input_queue.pop_front()
	multiplayer.rpc(1, game, "rpc_send_input", [dir, jump, client_tick, _yaw, _pitch, shooting])
	apply_input(dir, jump, dt)


func _remote_physics(dt: float) -> void:
	if not _has_snap:
		return
	var t := 1.0 - exp(-REMOTE_SMOOTH * dt)
	position = position.lerp(target_pos, t)
	rotation.y = lerp_angle(rotation.y, target_yaw, t)


# --- Network state handling (called from the Main script) ---


# Classic reconciliation: rewind to the acknowledged server state, then
# re-apply the inputs the server has not confirmed yet (using each input's own
# view yaw). The current view yaw/pitch is locally authoritative, so it is not
# overwritten with the (slightly stale) snapshot yaw.
func reconcile_state(pos: Vector3, vel: Vector3, _yaw: float, acked_tick: int) -> void:
	var snap_err := position.distance_to(pos)
	while input_queue.size() > 0 and input_queue[0]["tick"] <= acked_tick:
		input_queue.pop_front()
	position = pos
	velocity = vel
	for entry in input_queue:
		rotation.y = entry["yaw"]
		apply_input(entry["dir"], entry["jump"], RESIM_DT)
	if _autotest:
		_recon_count += 1
		if _recon_count % 30 == 0:
			print("reconcile: ack=%d pending=%d snap_err=%.3f hp=%d dead=%s" % [acked_tick, input_queue.size(), snap_err, health, dead])


func apply_server_state(pos: Vector3, yaw: float) -> void:
	if not _has_snap:
		position = pos
		rotation.y = yaw
		_has_snap = true
	target_pos = pos
	target_yaw = yaw


# --- Combat (server-authoritative) ---


func _aim_dir() -> Vector3:
	var d := Vector3(0, 0, -1)
	d = d.rotated(Vector3.UP, rotation.y)
	d = d.rotated(Vector3.RIGHT, aim_pitch)
	return d


func _do_shoot() -> void:
	var origin := position + Vector3(0, EYE_HEIGHT - 0.05, 0)
	var end := origin + _aim_dir() * MAX_RANGE
	# This build's PhysicsDirectSpaceState3D takes a query-parameters object
	# (Godot 3 style), not (from, to, except) args.
	var query := PhysicsRayQueryParameters3D.new()
	query.set_from(origin)
	query.set_to(end)
	query.set_collision_mask(-1)
	query.set_exclude([get_rid()])
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var col: Node = hit.get("collider")
	if col == null:
		return
	var t: Node = col
	if not ("my_peer_id" in t):
		var par := t.get_parent()
		if par != null and "my_peer_id" in par:
			t = par
		else:
			return  # Hit a wall/floor, not a player.
	if t.my_peer_id == my_peer_id or t.dead:
		return
	t.take_damage(DAMAGE_PER_SHOT, my_peer_id)


func take_damage(amount: int, from_pid: int) -> void:
	if dead:
		return
	health = maxi(health - amount, 0)
	game._on_player_hit(my_peer_id, health, from_pid)
	if health <= 0:
		dead = true
		velocity = Vector3.ZERO
		_shoot_cd = 0.0
		respawn_at = Time.get_ticks_msec() + RESPAWN_DELAY_MS
		_refresh_visuals()
		game._on_player_death(my_peer_id, from_pid)


# --- Client-side state mirrors (called from the Main script's RPCs) ---


func set_health(h: int) -> void:
	health = h
	_refresh_visuals()


func set_dead(is_dead: bool) -> void:
	dead = is_dead
	if is_dead:
		velocity = Vector3.ZERO
	_refresh_visuals()


func set_alive(pos: Vector3) -> void:
	dead = false
	health = MAX_HEALTH
	if is_local:
		position = pos
		velocity = Vector3.ZERO
	_refresh_visuals()


func _refresh_visuals() -> void:
	if _body_mesh != null:
		_body_mesh.visible = not dead
	if _viewmodel != null:
		_viewmodel.visible = not dead
	if _hb_billboard != null:
		if dead:
			_hb_billboard.visible = false
		else:
			_hb_billboard.visible = health < MAX_HEALTH
			if health < MAX_HEALTH:
				var f := float(health) / float(MAX_HEALTH)
				_hb_fg.scale.x = maxf(f, 0.001)
				_hb_fg.position.x = -0.45 * (1.0 - f)
