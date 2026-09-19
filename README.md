# qwen-multiplayer-test

A minimal Godot 4.7 3D game demonstrating **server-authoritative multiplayer with
client-side prediction**. No shooting — players just move around a shared 3D arena
(WASD/arrows to move, Space to jump).

## How it works

- The server is the single source of truth for all player positions
  (Godot's high-level multiplayer over ENet/UDP, port 7050).
- Each client sends its input (direction + jump) plus a sequence `tick` to the
  server every physics frame (unreliable-ordered RPC).
- The server simulates every player with the shared deterministic movement code
  and broadcasts each player's position snapshot ~30 times per second.
- The local client **predicts** its own movement locally every frame and keeps a
  queue of the inputs it has sent. When a server snapshot arrives it performs
  classic reconciliation:
  1. drops inputs the server has already acknowledged,
  2. snaps to the authoritative position/velocity,
  3. re-simulates the unacknowledged inputs.
- Remote players on a client are smoothly interpolated toward the latest snapshot.
- Late joiners receive a full player-list sync; the `server_disconnected` signal
  detects a lost server connection.

### Godot 4.7.2 build specifics

This project targets the 4.7.2 build whose multiplayer API differs from classic
4.x documentation:

- The transport is created explicitly: `ENetMultiplayerPeer` +
  `peer.create_server(port)` / `peer.create_client(host, port)` +
  `multiplayer.set_multiplayer_peer(peer)` (there is no `listen_to` /
  `connect_to_server`).
- `multiplayer.poll()` must be called every frame or nothing connects.
- RPCs are sent with `multiplayer.rpc(target, object, "method", args)`
  (`target` 0 = broadcast, 1 = server); the receiving functions still carry
  `@rpc` annotations.
- The caller's id inside an RPC is `multiplayer.get_remote_sender_id()`.
- User command-line args (after `--`) are read with
  `OS.get_cmdline_user_args()`.

Key files:

| File | Purpose |
| --- | --- |
| `scripts/main.gd` | World setup, server hosting, player spawn/join/leave, RPCs, connection handling |
| `scripts/player.gd` | Movement physics, client prediction + reconciliation, camera |
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

### Verification flags (client side)

```sh
# Auto-walk forward (for headless smoke tests):
godot --headless --path . --quit-after 720 -- +client 127.0.0.1 +autotest

# +debugpos: print non-local player positions every 2s:
godot --headless --path . --quit-after 720 -- +client 127.0.0.1 +autotest +debugpos
```

A healthy client log shows `Connected to server as peer N`, periodic
`reconcile: ack=N pending=1 snap_err=X` lines (X well below 1), and with
`+debugpos` `REMOTE POS:` lines whose coordinates change over time.

## Known limitations (this Godot build)

- In this 4.7.2 build, clients may be disconnected automatically by the
  transport after ~25–56 s of a perfectly healthy session (ENet client-side
  timeout quirk). The game detects it via `server_disconnected`, prints
  "Connection to the server was lost" and clears the world. Re-launch the
  client to join again.
- Only one process can bind port 7050 — kill any previous server before
  starting a new one.
- Verification here is headless; the 3D rendering path (camera, colors, sky)
  is untested in this environment.
