extends CharacterBody3D
## A 3D player whose movement is simulated authoritatively on the server.
##
## - Server: every player is moved from the latest input received from that client.
## - Local client: predicts movement locally every frame, sends the input to the
##   server, and reconciles when the server snapshot arrives (classic
##   client-side prediction with state rewind + input re-simulation).
## - Other clients: interpolate toward the latest server snapshot.

const SPEED := 8.0
const ACCELERATION := 40.0
const GRAVITY := -25.0
const JUMP_SPEED := 9.0
const SNAPSHOT_INTERVAL := 1.0 / 30.0
const RESIM_DT := 1.0 / 60.0
const REMOTE_SMOOTH := 10.0

var my_peer_id: int = 0
var is_local := false
var game: Node = null
var _am_server := false

# Authoritative (server) state: the latest input received from this player's client.
var pending_input_dir := Vector2.ZERO
var pending_input_jump := false
var ack_tick := 0
var _snap_acc := 0.0

# Prediction (local client): inputs applied locally but not yet confirmed by the server.
var input_queue: Array[Dictionary] = []
var client_tick := 0

# Remote interpolation (clients viewing other players).
var target_pos := Vector3.ZERO
var target_yaw := 0.0
var _has_snap := false

var _camera_rig: Node3D = null
var _autotest := false
var _recon_count := 0


func setup(pid: int, spawn: Vector3, color: Color, game_node: Node) -> void:
	my_peer_id = pid
	game = game_node
	position = spawn
	# game.multiplayer (not the bare `multiplayer` accessor): setup() may run
	# while this node is not yet in the tree, where the accessor is null.
	is_local = pid == game.multiplayer.get_unique_id()
	_am_server = game.multiplayer.is_server()
	_autotest = OS.get_cmdline_user_args().has("+autotest")
	_build_body(color)
	if is_local:
		_build_camera()


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

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.8, 1.8, 0.8)
	col.shape = shape
	col.position = Vector3(0, 0.9, 0)
	add_child(col)


func _build_camera() -> void:
	_camera_rig = Node3D.new()
	_camera_rig.position = Vector3(0, 1.7, 0)
	add_child(_camera_rig)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.5, 4.5)
	cam.fov = 75.0
	_camera_rig.add_child(cam)


func _read_input_dir() -> Vector2:
	if _autotest and not _am_server:
		return Vector2(0, -1)
	return Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_up", "ui_down"))


func _read_jump() -> bool:
	return Input.is_key_pressed(KEY_SPACE)


# --- Shared deterministic movement (used on the server and in client prediction) ---


func apply_input(dir: Vector2, jump: bool, dt: float) -> void:
	var wish := transform.basis * Vector3(dir.x, 0.0, dir.y)
	if dir.length_squared() > 0.0001:
		wish = wish.normalized()
		# Godot faces -Z: the yaw whose -Z axis points along `wish`.
		var target_yaw := atan2(-wish.x, -wish.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, 12.0 * dt))

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
		# A listen server moves its own player directly from the keyboard.
		pending_input_dir = _read_input_dir()
		pending_input_jump = _read_jump()
	apply_input(pending_input_dir, pending_input_jump, dt)
	_snap_acc += dt
	if _snap_acc >= SNAPSHOT_INTERVAL:
		_snap_acc = 0.0
		multiplayer.rpc(0, game, "rpc_snapshot", [my_peer_id, position, velocity, rotation.y, ack_tick])


func _local_physics(dt: float) -> void:
	var dir := _read_input_dir()
	var jump := _read_jump()
	client_tick += 1
	input_queue.append({"dir": dir, "jump": jump, "tick": client_tick})
	if input_queue.size() > 300:
		input_queue.pop_front()
	multiplayer.rpc(1, game, "rpc_send_input", [dir, jump, client_tick])
	apply_input(dir, jump, dt)


func _remote_physics(dt: float) -> void:
	if not _has_snap:
		return
	var t := 1.0 - exp(-REMOTE_SMOOTH * dt)
	position = position.lerp(target_pos, t)
	rotation.y = lerp_angle(rotation.y, target_yaw, t)


# --- Network state handling (called from the Main script) ---


# Classic reconciliation: rewind to the acknowledged server state, then
# re-apply the inputs the server has not confirmed yet.
func reconcile_state(pos: Vector3, vel: Vector3, yaw: float, acked_tick: int) -> void:
	var snap_err := position.distance_to(pos)
	while input_queue.size() > 0 and input_queue[0]["tick"] <= acked_tick:
		input_queue.pop_front()
	position = pos
	velocity = vel
	rotation.y = yaw
	for entry in input_queue:
		apply_input(entry["dir"], entry["jump"], RESIM_DT)
	if _autotest:
		_recon_count += 1
		if _recon_count % 30 == 0:
			print("reconcile: ack=%d pending=%d snap_err=%.3f" % [acked_tick, input_queue.size(), snap_err])


func apply_server_state(pos: Vector3, yaw: float) -> void:
	if not _has_snap:
		position = pos
		rotation.y = yaw
		_has_snap = true
	target_pos = pos
	target_yaw = yaw
