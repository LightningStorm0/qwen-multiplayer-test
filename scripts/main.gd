extends Node
## Entry point: builds the world, hosts the server, and manages the network lifecycle.
##
## A minimal first-person shooter: server-authoritative hitscan shooting with
## client-side movement prediction.
##
## Usage:
##   Server (listen, you can also play locally):  godot --path .
##   Headless dedicated server:                   godot --headless --path .
##   Client:                                      godot --path . -- +client [ip]
##   (default ip is 127.0.0.1)
##   Note: user args come after `--` (Godot convention).
##
## Controls: WASD/arrows move, Space jump, mouse aim (captured), LMB shoot,
##   ESC releases the mouse, click to re-capture. 100 HP, 25 damage per shot,
##   3 s respawn.
##
## Note (Godot 4.7 fork specifics): the high-level multiplayer API here is
## ENetMultiplayerPeer + set_multiplayer_peer(), manual multiplayer.poll() every
## frame, and explicit multiplayer.rpc(target, object, "method", args) calls
## (target 0 = broadcast, 1 = server).

const SERVER_PORT := 7050
const PlayerScript := preload("res://scripts/player.gd")

var _players: Dictionary = {}  # peer_id -> CharacterBody3D
var _player_colors: Dictionary = {}  # peer_id -> Color
var _players_node: Node3D
var _status_label: Label
var _crosshair: Label
var _hp_label: Label
var _event_label: Label
var _capture_hint: Label
var _hit_flash: ColorRect
var _death_overlay: ColorRect
var _death_label: Label
var _is_client := false
var _connected_as_client := false
var _target_ip := "127.0.0.1"
var _debugpos := false
var _debug_acc := 0.0
var _local_pid := 1
var _local_dead := false
var _event_time := 0.0
var _flash_alpha := 0.0
# Cached at startup: querying multiplayer.is_server()/get_unique_id() after the
# ENet peer has been deactivated (connection lost) raises engine errors.
var _is_server := false


func _ready() -> void:
	_build_world()
	_build_hud()

	var args := OS.get_cmdline_user_args()
	_debugpos = args.has("+debugpos")
	if args.has("+client"):
		_is_client = true
		var i := args.find("+client")
		if i + 1 < args.size() and not args[i + 1].begins_with("+"):
			_target_ip = args[i + 1]
		print("Connecting to %s:%d..." % [_target_ip, SERVER_PORT])
		_start_client()
	else:
		print("Hosting server on port %d (listen server)" % SERVER_PORT)
		_start_server()
	_is_server = not _is_client

	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_connection_lost)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if _is_server:
		_local_pid = 1
		_spawn_player(1)
		_capture_mouse()
	_update_hud()


func _process(dt: float) -> void:
	# Required in this build: the peer is not polled automatically.
	multiplayer.poll()
	# Optional verification aid: +debugpos prints non-local player positions every 2s.
	_debug_acc += dt
	if _debug_acc >= 2.0:
		_debug_acc = 0.0
		if _debugpos and _is_client and _players.size() > 1:
			var others := {}
			for pid in _players:
				if int(pid) != _local_pid:
					others[pid] = "%s hp=%d dead=%s" % [_players[pid].position, _players[pid].health, _players[pid].dead]
			print("REMOTE POS: ", others)
	# HUD timers.
	if _event_time > 0.0:
		_event_time -= dt
		if _event_time <= 0.0:
			_event_label.text = ""
	if _flash_alpha > 0.0:
		_flash_alpha = maxf(_flash_alpha - dt * 1.5, 0.0)
		_hit_flash.color.a = _flash_alpha
	# Mouse capture: re-capture on click when released (local player alive).
	if _has_local_player() and not _local_dead:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_capture_hint.visible = false
		else:
			_capture_hint.visible = true
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				_capture_mouse()


# --- Network setup ---


func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(SERVER_PORT) != OK:
		push_error("Failed to start the server on port %d" % SERVER_PORT)
	multiplayer.set_multiplayer_peer(peer)


func _start_client() -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(_target_ip, SERVER_PORT) != OK:
		push_error("Failed to start the client (target %s:%d)" % [_target_ip, SERVER_PORT])
	multiplayer.set_multiplayer_peer(peer)


func _has_local_player() -> bool:
	if _is_server:
		return true
	return _local_pid > 1


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_focus_entered() -> void:
	if _has_local_player() and not _local_dead:
		_capture_mouse()


func _on_focus_exited() -> void:
	_release_mouse()


# --- World building (shared by server and clients) ---


func _build_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env_node.environment = env
	add_child(env_node)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	add_child(light)

	var floor := StaticBody3D.new()
	add_child(floor)
	var floor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 1, 60)
	floor_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.56, 0.42)
	floor_mesh.set_surface_override_material(0, mat)
	floor_mesh.position = Vector3(0, -0.5, 0)
	floor.add_child(floor_mesh)
	var floor_col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(60, 1, 60)
	floor_col.shape = shape
	floor_col.position = Vector3(0, -0.5, 0)
	floor.add_child(floor_col)

	# Faint boundary walls keep players inside the 60x60 arena.
	var wall_mat := StandardMaterial3D.new()
	wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_mat.albedo_color = Color(1, 1, 1, 0.07)
	var walls := [
		[Vector3(0, 2, -30), Vector3(60, 4, 1)],
		[Vector3(0, 2, 30), Vector3(60, 4, 1)],
		[Vector3(-30, 2, 0), Vector3(1, 4, 60)],
		[Vector3(30, 2, 0), Vector3(1, 4, 60)],
	]
	for w in walls:
		var wall := StaticBody3D.new()
		wall.position = w[0]
		var mesh := MeshInstance3D.new()
		var wbox := BoxMesh.new()
		wbox.size = w[1]
		mesh.mesh = wbox
		mesh.set_surface_override_material(0, wall_mat)
		var col := CollisionShape3D.new()
		var wshape := BoxShape3D.new()
		wshape.size = w[1]
		col.shape = wshape
		add_child(wall)
		wall.add_child(mesh)
		wall.add_child(col)

	_players_node = Node3D.new()
	add_child(_players_node)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status_label = Label.new()
	_status_label.position = Vector2(12, 8)
	_status_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(_status_label)
	var hint := Label.new()
	hint.position = Vector2(12, 34)
	hint.add_theme_font_size_override("font_size", 14)
	hint.text = "WASD: move | Space: jump | Mouse: aim | LMB: shoot | ESC: release mouse, click to re-capture"
	layer.add_child(hint)
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 22)
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_crosshair)
	_hp_label = Label.new()
	_hp_label.text = "HP 100/100"
	_hp_label.add_theme_font_size_override("font_size", 20)
	_hp_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hp_label.position = Vector2(12, -44)
	layer.add_child(_hp_label)
	_event_label = Label.new()
	_event_label.add_theme_font_size_override("font_size", 18)
	_event_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_event_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_event_label.position = Vector2(-200, 12)
	_event_label.size = Vector2(400, 30)
	layer.add_child(_event_label)
	_capture_hint = Label.new()
	_capture_hint.text = "Mouse released - click to capture"
	_capture_hint.add_theme_font_size_override("font_size", 16)
	_capture_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_capture_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_capture_hint.position = Vector2(0, -34)
	_capture_hint.visible = false
	layer.add_child(_capture_hint)
	_hit_flash = ColorRect.new()
	_hit_flash.color = Color(1, 0.1, 0.1, 0.0)
	_hit_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_hit_flash)
	_death_overlay = ColorRect.new()
	_death_overlay.color = Color(0, 0, 0, 0.65)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.visible = false
	layer.add_child(_death_overlay)
	_death_label = Label.new()
	_death_label.text = "YOU DIED\nrespawning..."
	_death_label.add_theme_font_size_override("font_size", 32)
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_label.visible = false
	layer.add_child(_death_label)
	# Window focus drives mouse capture/release.
	var win := get_window()
	win.focus_entered.connect(_on_focus_entered)
	win.focus_exited.connect(_on_focus_exited)


func _update_hud() -> void:
	if _status_label == null:
		return
	if _is_server:
		_status_label.text = "Server: hosting on port %d | players: %d" % [SERVER_PORT, _players.size()]
	elif _connected_as_client:
		_status_label.text = "Connected to %s:%d | you are player #%d | players: %d" % [
			_target_ip, SERVER_PORT, _local_pid, _players.size(),
		]
	else:
		_status_label.text = "Connecting to %s:%d..." % [_target_ip, SERVER_PORT]


func _show_event(text: String) -> void:
	if _event_label == null:
		return
	_event_label.text = text
	_event_time = 3.0


# --- Player management ---


func _spawn_player(pid: int) -> void:
	var color := Color(float((pid * 37) % 100) / 100.0, 0.65, 0.95)
	_player_colors[pid] = color
	var spawn := Vector3(float(_player_colors.size() - 1) * 3.0, 1.0, 0.0)
	_add_player(pid, spawn, color)
	multiplayer.rpc(0, self, "rpc_player_joined", [pid, spawn, color])
	_update_hud()
	print("Player %d joined" % pid)


func _add_player(pid: int, spawn: Vector3, color: Color) -> void:
	if _players.has(pid):
		return
	var p := CharacterBody3D.new()
	p.set_script(PlayerScript)
	_players[pid] = p
	# Setup (which sets the spawn position) must run before add_child: in this
	# build a body that enters the tree at the origin registers there for one
	# physics frame and de-embeds any player it overlaps (full 0.8 box push).
	p.setup(pid, spawn, color, self)
	_players_node.add_child(p)


func _remove_player(pid: int) -> void:
	var p: Node = _players.get(pid)
	if p == null:
		return
	_players.erase(pid)
	_player_colors.erase(pid)
	p.queue_free()
	_update_hud()


# --- Signals ---


func _on_connected_to_server() -> void:
	_local_pid = multiplayer.get_unique_id()
	print("Connected to server as peer %d" % _local_pid)
	_connected_as_client = true
	multiplayer.rpc(1, self, "rpc_register", [])
	_hp_label.text = "HP 100/100"
	_capture_mouse()
	_update_hud()


func _on_connection_failed() -> void:
	print("Failed to connect to %s:%d" % [_target_ip, SERVER_PORT])
	_connected_as_client = false
	_update_hud()


func _on_peer_connected(pid: int) -> void:
	if _is_server:
		print("Peer %d connected" % pid)
	_update_hud()


func _on_peer_disconnected(pid: int) -> void:
	if _is_server:
		if pid != 1:
			print("Peer %d left" % pid)
			_remove_player(pid)
			multiplayer.rpc(0, self, "rpc_player_left", [pid])
		_update_hud()
	else:
		if pid == 1:
			_on_connection_lost()
		else:
			_remove_player(pid)


func _on_connection_lost() -> void:
	if _connected_as_client or _players.size() > 0:
		print("Connection to the server was lost")
	_connected_as_client = false
	var keys: Array = _players.keys()
	for pid in keys:
		_remove_player(pid)
	_local_pid = -1
	_update_hud()


# --- Combat notifications (server -> clients + own HUD) ---
# Called by the Player script when the server resolves a hit/death/respawn.
# The RPC updates the remote clients; the _apply_* call updates this machine.


func _on_player_hit(target: int, health: int, shooter: int) -> void:
	multiplayer.rpc(0, self, "rpc_hit", [target, health, shooter])
	_apply_hit_state(target, health, shooter)


func _on_player_death(target: int, shooter: int) -> void:
	multiplayer.rpc(0, self, "rpc_death", [target, shooter])
	_apply_death_state(target, shooter)


func _on_player_respawn(target: int, pos: Vector3) -> void:
	multiplayer.rpc(0, self, "rpc_respawn", [target, pos])
	_apply_respawn_state(target, pos)


func _apply_hit_state(target: int, health: int, shooter: int) -> void:
	var p: Node = _players.get(target)
	if p != null:
		p.set_health(health)
	if target == _local_pid:
		_hp_label.text = "HP %d/100" % health
		_flash_alpha = 0.35
		_hit_flash.color.a = _flash_alpha
		_show_event("Player %d hit you (HP %d)" % [shooter, health])
	elif shooter == _local_pid:
		_show_event("You hit player %d (HP %d)" % [target, health])


func _apply_death_state(target: int, shooter: int) -> void:
	var p: Node = _players.get(target)
	if p != null:
		p.set_dead(true)
	if target == _local_pid:
		_local_dead = true
		_hp_label.text = "HP 0/100"
		_death_overlay.visible = true
		_death_label.visible = true
		_release_mouse()
		_show_event("You were eliminated by player %d" % shooter)
	elif shooter == _local_pid:
		_show_event("You eliminated player %d!" % target)
	else:
		_show_event("Player %d eliminated player %d" % [shooter, target])


func _apply_respawn_state(target: int, pos: Vector3) -> void:
	var p: Node = _players.get(target)
	if p != null:
		p.set_alive(pos)
	if target == _local_pid:
		_local_dead = false
		_hp_label.text = "HP 100/100"
		_death_overlay.visible = false
		_death_label.visible = false
		var win := get_window()
		if win != null and win.has_focus():
			_capture_mouse()


# --- RPCs ---
# rpc_register / rpc_send_input are called by clients and run on the server.
# rpc_players_full / rpc_player_joined / rpc_player_left / rpc_snapshot /
# rpc_hit / rpc_death / rpc_respawn run on the clients.


@rpc("any_peer", "call_remote", "reliable")
func rpc_register() -> void:
	if not _is_server:
		return
	var pid: int = multiplayer.get_remote_sender_id()
	if pid <= 1 or _players.has(pid):
		return
	_spawn_player(pid)
	var data := {}
	for p_id in _players:
		var node: Node = _players[p_id]
		data[p_id] = {"pos": node.position, "color": _player_colors[p_id], "health": node.health, "dead": node.dead}
	multiplayer.rpc(0, self, "rpc_players_full", [data])


@rpc("authority", "call_remote", "reliable")
func rpc_players_full(data: Dictionary) -> void:
	if _is_server:
		return
	for pid in data:
		if not _players.has(pid):
			var info: Dictionary = data[pid]
			var p_id: int = int(pid)
			_player_colors[p_id] = info["color"]
			_add_player(p_id, info["pos"], info["color"])
			var p: Node = _players[p_id]
			p.set_health(int(info.get("health", 100)))
			if info.get("dead", false):
				p.set_dead(true)
	_update_hud()


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_player_joined(pid: int, spawn: Vector3, color: Color) -> void:
	if _is_server:
		return
	if _players.has(pid):
		return
	_player_colors[pid] = color
	_add_player(pid, spawn, color)
	_update_hud()


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_player_left(pid: int) -> void:
	if _is_server:
		return
	_remove_player(pid)


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_snapshot(pid: int, pos: Vector3, vel: Vector3, yaw: float, ack_tick: int) -> void:
	if _is_server:
		return
	var p: Node = _players.get(pid)
	if p == null:
		return
	if pid == _local_pid:
		p.reconcile_state(pos, vel, yaw, ack_tick)
	else:
		p.apply_server_state(pos, yaw)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_send_input(dir: Vector2, jump: bool, tick: int, yaw: float, pitch: float, shooting: bool) -> void:
	if not _is_server:
		return
	var pid: int = multiplayer.get_remote_sender_id()
	var p: Node = _players.get(pid)
	if p == null:
		return
	if tick > p.ack_tick:
		p.ack_tick = tick
		p.pending_input_dir = dir
		p.pending_input_jump = jump
		p.pending_input_shooting = shooting
		p.rotation.y = yaw
		p.aim_pitch = pitch


@rpc("authority", "call_remote", "reliable")
func rpc_hit(target: int, health: int, shooter: int) -> void:
	if _is_server:
		return
	_apply_hit_state(target, health, shooter)


@rpc("authority", "call_remote", "reliable")
func rpc_death(target: int, shooter: int) -> void:
	if _is_server:
		return
	_apply_death_state(target, shooter)


@rpc("authority", "call_remote", "reliable")
func rpc_respawn(target: int, pos: Vector3) -> void:
	if _is_server:
		return
	_apply_respawn_state(target, pos)
