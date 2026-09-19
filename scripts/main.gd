extends Node
## Entry point: builds the world, hosts the server, and manages the network lifecycle.
##
## Usage:
##   Server (listen, you can also play locally):  godot --path .
##   Headless dedicated server:                   godot --headless --path .
##   Client:                                      godot --path . -- +client [ip]
##   (default ip is 127.0.0.1)
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
var _is_client := false
var _connected_as_client := false
var _target_ip := "127.0.0.1"
var _debugpos := false
var _debug_acc := 0.0
# Cached at startup: querying multiplayer.is_server()/get_unique_id() after the
# ENet peer has been deactivated (connection lost) raises engine errors.
var _is_server := false
var _local_pid := -1


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
		_spawn_player(1)
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
					others[pid] = _players[pid].position
			if not others.is_empty():
				print("REMOTE POS: ", others)


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
	hint.text = "WASD / arrow keys: move | Space: jump | You are the colored block the camera follows"
	layer.add_child(hint)


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
	_update_hud()


# --- RPCs ---
# rpc_register is called by clients and runs on the server.
# rpc_players_full / rpc_player_joined / rpc_player_left / rpc_snapshot / rpc_pong run on the clients.


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
		data[p_id] = {"pos": node.position, "color": _player_colors[p_id]}
	multiplayer.rpc(0, self, "rpc_players_full", [data])


@rpc("authority", "call_remote", "reliable")
func rpc_players_full(data: Dictionary) -> void:
	if _is_server:
		return
	for pid in data:
		if not _players.has(pid):
			var info: Dictionary = data[pid]
			_player_colors[pid] = info["color"]
			_add_player(int(pid), info["pos"], info["color"])
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
func rpc_send_input(dir: Vector2, jump: bool, tick: int) -> void:
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
