# qwen-multiplayer-test

A minimal Godot 4.7 **first-person shooter** demonstrating **server-authoritative
multiplayer with client-side prediction**. All movement and all combat (hitscan
shooting, damage, death, respawn) are resolved on the server; clients predict their
own movement locally and reconcile to server snapshots.

- 100 HP, 25 damage per shot (4 shots to kill), auto-fire on a 0.15 s cooldown,
  100 m hitscan range, 3 s respawn.
- Controls: **WASD / arrows** move, **Space** jump, **mouse** aim (captured),
  **left mouse** shoot, **Esc** releases the mouse (click to re-capture).

## How it works

- The server is the single source of truth for all player positions and for all
  combat state (health, dead, respawn timing) (Godot's high-level multiplayer over
  ENet/UDP, port 7050).
- Each client sends its input (direction + jump + view yaw/pitch + shooting) plus a
  sequence `tick` to the server every physics frame (unreliable-ordered RPC).
- The server simulates every player with the shared deterministic movement code and
  broadcasts each player's position snapshot ~30 times per second.
- Shooting is **server-authoritative**: when a client's `shooting` flag is set, the
  server raycasts from that player's eye along its aim vector, resolves the first
  player collider hit, applies damage, and (on a kill) schedules a 3 s respawn.
  Hit/death/respawn events are broadcast with reliable RPCs so every client's HUD,
  health bar, and view-model stay in sync.
- The local client **predicts** its own movement locally every frame and keeps a
  queue of the inputs it has sent. When a server snapshot arrives it performs
  classic reconciliation:
  1. drops inputs the server has already acknowledged,
  2. snaps to the authoritative position/velocity,
  3. re-simulates the unacknowledged inputs.
  The local view yaw/pitch (mouse look) is locally authoritative and is never
  overwritten by the (slightly stale) snapshot.
- Remote players on a client are smoothly interpolated toward the latest snapshot.
- Late joiners receive a full player-list sync (including health/dead state); the
  `server_disconnected` signal detects a lost server connection.

### Godot 4.7.2 build specifics

This project targets the 4.7.2 build whose API differs from classic 4.x docs:

- The transport is created explicitly: `ENetMultiplayerPeer` +
  `peer.create_server(port)` / `peer.create_client(host, port)` +
  `multiplayer.set_multiplayer_peer(peer)` (there is no `listen_to` /
  `connect_to_server`).
- `multiplayer.poll()` must be called every frame or nothing connects.
- RPCs are sent with `multiplayer.rpc(target, object, "method", args)`
  (`target` 0 = broadcast, 1 = server); the receiving functions still carry
  `@rpc` annotations.
- The caller's id inside an RPC is `multiplayer.get_remote_sender_id()`.
- User command-line args (after `--`) are read with `OS.get_cmdline_user_args()`.
- The physics raycast uses a query-parameters object
  (`PhysicsRayQueryParameters3D` + `space_state.intersect_ray(query)`), the
  `Input` singleton has no per-frame mouse-motion getter (mouse look reads
  `InputEventMouseMotion.relative` in `_unhandled_input`), and there is no
  `Billboard` node (the health bar is a plain mesh).
- This project ships **no `[input]` map** in `project.godot`, so movement keys are
  read with direct `Input.is_key_pressed()` checks rather than the default
  `ui_left`/`ui_right`/... actions.

Key files:

| File | Purpose |
| --- | --- |
| `scripts/main.gd` | World setup, server hosting, player spawn/join/leave, HUD, mouse capture, RPCs, connection handling |
| `scripts/player.gd` | Movement physics, client prediction + reconciliation, first-person view, server-authoritative hitscan combat, health/death/respawn |
| `scenes/main.tscn` | Main scene (attaches `scripts/main.gd`) |

## Running

A Godot 4.7.2 binary is at `/tmp/opencode/godot/Godot_v4.7.2-stable_linux.x86_64`
(replace with `godot` if you have it on your PATH).

```sh
cd qwen-multiplayer-test

# Terminal 1 — host a server (listen server, you can also play locally):
godot --path .

# Headless dedicated server (no window):
godot --headless --path .

# Terminal 2 — connect a client (default host 127.0.0.1):
godot --path . -- +client

# Client on another machine:
godot --path . -- +client <server-ip>
```

Prebuilt binaries (Linux / Windows) are in `build/` and attached to the GitHub
release. To connect from a second machine, run the client binary with:

```sh
multiplayer-movement-test -- +client <server-ip>
# (Windows: multiplayer-movement-test.exe -- +client <server-ip>)
```

Note the `--` separator — Godot only treats args after it as user args; without it
the game defaults to hosting.

### Verification flags (client side)

```sh
# Auto-walk forward + auto-aim + auto-shoot at the nearest player (headless test of
# the full damage/death/respawn loop, since headless has no real mouse):
godot --headless --path . --quit-after 720 -- +client 127.0.0.1 +autotest

# +debugpos: print non-local player positions (with hp/dead) every 2s:
godot --headless --path . --quit-after 720 -- +client 127.0.0.1 +autotest +debugpos
```

A healthy client log shows `Connected to server as peer N`, periodic
`reconcile: ack=N pending=1 snap_err=X` lines (X well below 1, and `hp`/`dead`
changing as the bots fight), and with `+debugpos` `REMOTE POS:` lines whose
coordinates and `hp=`/`dead=` values change over time.

## Known limitations (this Godot build)

- In this 4.7.2 build, clients may be disconnected automatically by the
  transport after ~25–56 s of a perfectly healthy session (ENet client-side
  timeout quirk). The game detects it via `server_disconnected`, prints
  "Connection to the server was lost" and clears the world. Re-launch the
  client to join again.
- Only one process can bind port 7050 — kill any previous server before
  starting a new one.
- Verification here is headless; the 3D rendering path (camera, view-model,
  sky) and the real mouse-capture path are untested in this environment.
