# RFC 918: Evaluate Sunshine/Moonlight streaming for private Labelle playtests

**Status:** Draft (design only — no experiment has been run yet)
**Issue:** labelle-toolkit/labelle-engine#918
**Scope of this document:** how the feasibility experiment should be run, what it must measure, and how its results map to go/no-go and follow-up work. This RFC does **not** propose engine code changes. It describes the engine seams that the experiment depends on, so any follow-up lands in the right layer.

---

## 1. Problem and context

### 1.1 Problem

Prerelease playtesting today means sending testers a game package: binary and assets. Anyone who receives the package can extract the assets and reverse-engineer or repackage the binary. Issue #918 asks whether **Sunshine** (host capture, encoding and input injection) plus **Moonlight** (an installed client) is a practical way to run *invite-only* remote playtests where the tester never receives the package. The first target is **Flying Platform**, hosted on the existing **Mac** and played on the existing **Android tablet**.

This is a feasibility investigation, not a plan for a cloud-gaming service. The intended result is a reproducible setup guide, measurements and a go/no-go decision. Follow-up issues should be filed only where the experiment shows a need for them.

### 1.2 What the code shows today (existing evidence)

All findings below come from reading this checkout. Nothing in this section has been run or tested.

| Area | What the source shows | Why it matters for streaming |
|------|-----------------------|------------------------------|
| Entry point | The engine is a library with no `main()`. `labelle-assembler` generates the entry point per target (CLAUDE.md). Argv, window creation and the frame loop all live in that generated `main.zig`. | Any launch/window behaviour under Sunshine belongs to the generated main or backend. It does not belong in this repo. |
| Launch channel | The CLI passes runtime options as env vars: `LABELLE_SCENE` (`src/runtime_env.zig`), `LABELLE_SCREENSHOT_PATH` / `LABELLE_SCREENSHOT_AFTER_SEC` (`src/screenshot_request.zig`), `LABELLE_DATA_DIR` (`src/storage/default.zig`) and `LABELLE_PROFILE`. | A Sunshine "application" entry can be a plain command plus env vars. No new engine flag is needed to choose a scene, a save root or a screenshot. |
| Save location | `storage/data_root.zig` resolves `LABELLE_DATA_DIR` first. That path must be absolute. Without it, macOS falls back to `$HOME/Library/Application Support/<app_id>`, with `saves/` appended by `storage/default.zig`. | Per-session save isolation is already possible from the launch environment. Without the variable, a streamed session writes to the host user's real save directory. |
| Input model | `src/game/input_mixin.zig` forwards keyboard, mouse (position, buttons, wheel) and gamepad state from the backend `Input`. `input_types.zig` defines `Touch` (`MAX_TOUCHES = 10`), and `gestures.zig` recognises pinch, pan, swipe and the other gestures from raw touches. | Sunshine injects OS-level mouse, keyboard and gamepad events, and desktop backends read OS input, so the desktop path *should* see streamed input unchanged. Touch on a desktop backend is a different path. The tablet's touch is most likely translated to mouse events by Moonlight, so the engine's `Touch` and `Gestures` path would not be exercised. This must be confirmed (§4.3). |
| Cursor | `lifecycle_mixin.zig` exposes `setCursorVisible` and `isCursorOverWindow` through `core.CursorControls`. Unsupported backends return `false`. | If a game hides the OS cursor and draws its own, the captured stream shows the game-drawn cursor. This needs checking for cursor duplication or lag. |
| Fullscreen | The engine stores the *desired* state (`setFullscreen`, `takeFullscreenRequest`). The generated main applies it and reads the real state back, which is what fixed a stale-flag bug on the web (labelle-bgfx#99). | Fullscreen and resolution switches under capture go through the backend window path. Sunshine may change the display mode when a client connects. |
| Pause | `setPaused` and `isPaused` exist (`scene_runtime_mixin.zig`). The only automatic pause is the opt-in pause on controller loss (`input_events_mixin.zig`, #611). I found **no window-focus-loss or app-suspend hook** in this repo. | A Moonlight disconnect is invisible to the game: the window stays focused on the host. Today nothing pauses the game when a tester drops. |
| Frame stats | `frame_profiler.zig` keeps a 120-frame ring buffer of dt values and computes FPS and min/avg/max frame time (`frameStats()`). | This gives host-side frame pacing data without new code, provided the game build shows or logs it. |
| Editor preview | `preview_mode.zig` / `src/preview/*` connect out to the editor for PIE, using hello/heartbeat/bye frames and SHM/IOSurface capture. | The issue says this must **not** be reused or modified. Streaming uses ordinary OS capture. |

I could not verify these from this checkout, so the experiment must record them: the assembler templates, the CLI's launch/shutdown commands, which backend and renderer Flying Platform uses on macOS, and how that backend handles focus and HiDPI.

### 1.3 Security motivation and its limits

Streaming stops the package from reaching testers through the normal client path. It does **not** prevent recording or imitation, and it does not protect a version distributed some other way. It also creates a new risk: a remote party now controls input on the host. A shared desktop with Sunshine is not a safe multi-user service (§6).

---

## 2. Proposed design

The design is an experiment protocol in five phases. Each phase has entry conditions and records evidence. Phase 0 to Phase 3 use **unchanged** engine, assembler and CLI code.

### 2.1 Topology

```text
Mac host (dedicated macOS user "labelle-playtest")
  └─ labelle CLI launches Flying Platform (normal desktop build, windowed→fullscreen)
       env: LABELLE_DATA_DIR=/Users/labelle-playtest/sessions/<session-id>
            LABELLE_SCENE=<scene under test>   (optional)
  └─ Sunshine: display capture + audio capture + input injection
       app entry = "Flying Platform" (command + env), NOT "Desktop"
       web admin UI bound to localhost only
        │  (LAN first; then WAN via VPN overlay, see Phase 4)
        ▼
Android tablet: Moonlight (paired by PIN), touch→mouse mode, optional BT keyboard/controller
```

### 2.2 Phase 0: Inventory (no installs)

Record the following in a `versions` table in the findings doc: macOS version, host hardware (CPU/GPU, RAM, display), the game's git revision, engine/assembler/CLI revisions, backend and renderer, and the tablet model and Android version. Also capture a local, non-streamed baseline: a frame-stats recording, CPU/GPU/RAM in Activity Monitor or `powermetrics`, and screenshots of the scenes to be tested (moving clouds, a busy colony scene, a small-text UI panel).

### 2.3 Phase 1: Host setup and pairing (LAN)

1. Create a dedicated macOS standard (non-admin) user for streaming, and run Sunshine only in that session. This gives a minimal isolation baseline and keeps the developer's desktop and files out of reach.
2. Install Sunshine and Moonlight. Record the versions and the install method. On macOS, grant Screen Recording and Accessibility (input injection) permissions. Install an audio loopback device if Sunshine requires one on macOS, and record which one and its licence. Record every permission and every piece of software installed so Phase 5 can undo them.
3. Bind Sunshine's web admin UI to localhost and set a strong admin credential. Do not expose it beyond the host.
4. Define one Sunshine **application** whose command runs the Labelle CLI launch (`labelle run …` or the built binary) with the env vars above. Write down the exact command and its prep/undo steps. Sunshine applications can run a command when a session ends. Use that to stop the game, so an abandoned session does not keep running.
5. Pair the tablet over the LAN using a PIN.

### 2.4 Phase 2: Functional compatibility (LAN, unchanged runtime)

Run the checklist in §4.1 to §4.4. Record each item as pass, fail or degraded, with evidence such as a screenshot, clip or note. Classify every failure by layer:

- **Backend/window** (generated main, backend): focus, fullscreen, resolution, HiDPI scale, cursor.
- **Input layer** (engine `input_mixin` or backend input): coordinate mapping, wheel, drag, stuck keys.
- **Launch tooling** (CLI or Sunshine app entry): start, stop, env vars, save root.
- **Host/stream config** (Sunshine/Moonlight settings): bitrate, codec, scaling. Fixing these needs no code.

### 2.5 Phase 3: Quality and resource measurement (LAN)

- **Latency:** film the tablet screen and a host-side reference with a high-frame-rate phone camera, and count frames from tap to visible response. Read Moonlight's on-screen performance overlay for network, decode and render times. Compare against local play measured the same way.
- **Frame pacing:** host side, use `frameStats()` (min/avg/max dt). Client side, use the Moonlight overlay (dropped frames, fps). Use the same scenes as Phase 0.
- **Visual quality:** play each test scene at a matrix of resolutions (tablet native, 1080p, 720p) × bitrates (low, medium, high) × codec (H.264, HEVC if supported). Record screenshots and short clips on the client. Judge pixel-art crispness and small-text readability, and check moving clouds for banding and macroblocking.
- **Host load:** record CPU, GPU, encoder (`powermetrics` or similar), memory and network bandwidth for the *same scene*, streamed and not streamed, idle and busy. Do not estimate capacity from an idle scene.
- **Stability:** run one representative session of at least 30 minutes and log disconnects, audio/video drift and crashes.

### 2.6 Phase 4: Internet test

Give the client a separate connection that is representative of players in Brazil, for example a mobile hotspot or a remote helper. Prefer a VPN overlay (WireGuard or a mesh VPN) to port forwarding, so Sunshine's streaming ports and admin UI are never public. Record round-trip time, jitter, packet loss, the bitrate needed for acceptable quality, and the NAT and firewall requirements. Repeat a subset of Phase 3.

### 2.7 Phase 5: Robustness, escape and teardown

- Disconnect and reconnect mid-drag and mid-keypress. Check for stuck keys or buttons on the host. Check whether the game keeps running and whether saves survive (look at `LABELLE_DATA_DIR`).
- Walk the escape surface: OS shortcuts (Cmd-Tab, Cmd-Q, Mission Control), quitting the game, Sunshine's "Desktop" app, and file dialogs. Record what a tester can reach.
- Teardown: remove the pairing, revoke permissions, uninstall or disable Sunshine and the audio driver, delete the playtest user if it is not kept, and document whatever is intentionally left in place.

### 2.8 Deliverables

1. `docs/playtest-streaming.md` (or the equivalent in the toolkit docs): a setup guide with exact commands, versions and Sunshine app entry.
2. A findings report covering the versions table, a checklist result matrix, measurements, linked screenshots and clips, known failures classified by layer, answers to the six questions in the issue, and a go/no-go decision for invite-only playtests.
3. Narrow follow-up issues, only for failures that were actually observed (see §2.9).

### 2.9 Follow-ups that may be needed (not proposed now)

These are listed only so the right repo and layer are clear in advance. File each one only if the experiment shows the problem:

- **Session-end pause/quit seam.** The engine has `setPaused` but no external trigger. If abandoned sessions are a problem, the cheapest fix is in launch tooling: Sunshine's undo command terminates the game. An engine hook (a quit-requested signal, or a pause on focus loss) would be a separate RFC.
- **Input mapping fixes.** Fix in the backend if coordinates are off under HiDPI or scaled capture. Fix in the engine `input_mixin` only if the engine converts coordinates itself.
- **Launch helper.** A `labelle stream`/`labelle playtest` CLI helper that writes the Sunshine app entry and creates a per-session `LABELLE_DATA_DIR`. Worth building only if the manual steps prove error-prone (question 6 in the issue).

---

## 3. Alternatives considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keep distributing builds** (maybe obfuscated or encrypted assets) | Zero hosting, native latency | Does not address extraction; obfuscation only slows it down | Baseline to compare against |
| **Sunshine + Moonlight** (this RFC) | Free/open source, low latency on LAN, no engine work, Android client exists | Testers must install a client; macOS host support is less mature than Windows/Linux; shared-desktop risk | **Evaluate first** |
| **Parsec / Steam Remote Play / commercial cloud gaming** | Polished clients, some offer browser access | Licensing and cost, account requirements, less control; Steam needs a Steam distribution | Compare only on paper unless Sunshine fails |
| **WebRTC / browser streaming** (e.g. self-hosted Selkies or Neko-style stacks) | No client install | A separate stack to evaluate. Sunshine does **not** provide a browser client. Higher latency | Out of scope; separate evaluation if question 3 shows an installed client is unacceptable |
| **New engine streaming backend** (encode frames in-engine, e.g. extending the preview SHM/IOSurface capture) | Precise control of input and capture | Large effort; the issue forbids changing the preview protocol | Rejected for this phase |
| **Web (WASM) build for testers** | Browser only | Ships the assets and code to the client, which defeats the goal | Rejected for the anti-extraction goal |

---

## 4. Acceptance criteria

The evaluation is complete when every item below has a recorded result with evidence. Pass and fail are both acceptable results, as long as they are evidenced.

### 4.1 Setup and launch
- [ ] Versions table completed (§2.2).
- [ ] Host permissions, pairing, and the Sunshine app entry are documented as reproducible steps, with launch **and** shutdown through the Labelle CLI.
- [ ] Launch, video, audio, window focus, fullscreen toggle (`setFullscreen` path) and resolution change verified.

### 4.2 Desktop input
- [ ] ImGui buttons, mouse position accuracy, click, drag, scroll (`getMouseWheelMove`), camera movement and keyboard input verified.
- [ ] Cursor behaviour recorded, including any game-drawn cursor (`setCursorVisible`).

### 4.3 Tablet input
- [ ] Touch-to-mouse behaviour documented: tap, long-press, drag, two-finger scroll.
- [ ] The result explicitly says whether native multitouch reaches the engine's `Touch`/`Gestures` path. It is expected not to; the result must confirm or refute this.
- [ ] Controller support checked separately, if relevant.

### 4.4 Quality, resources, robustness
- [ ] Local vs streamed comparison: latency (measured), frame pacing, dropped frames, audio sync, and a stability session of at least 30 minutes.
- [ ] Readability matrix (resolution × bitrate × codec) with screenshots and clips for clouds, busy colony and small text.
- [ ] Host CPU/GPU/encoder/memory/bandwidth measured, streamed vs not streamed, in both idle and busy scenes.
- [ ] Disconnect/reconnect, stuck-key release, pause behaviour, save preservation and abandoned-session stop all tested.
- [ ] Internet test done without publicly exposing the admin UI; connection requirements documented.
- [ ] Escape surface assessed, and isolation requirements for untrusted testers written down.
- [ ] Upstream licences, supported host OS versions, and optional driver requirements and costs recorded.

### 4.5 Outcome
- [ ] All six questions from the issue answered, with a per-session cost estimate built from measured load plus one researched hosting option.
- [ ] Go/no-go recommendation for invite-only playtests.
- [ ] Temporary host settings restored; anything intentionally left installed is documented.
- [ ] Follow-ups filed only for observed failures, each tagged with its layer (§2.4).

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| A tester escapes to the host desktop or files (Cmd-Tab, quit to desktop, Sunshine "Desktop" app) | High on a shared desktop | High | Dedicated non-admin user; remove the Desktop app entry; game-only app; invite only trusted testers until isolation is proven; recommend a dedicated host for anything wider |
| Admin UI or stream ports exposed to the internet | Medium | High | Admin UI on localhost only; VPN overlay instead of port forwarding; check exposure with an external port scan during Phase 4 |
| macOS host support is weaker (audio capture needs a third-party driver; permissions are fragile) | Medium | Medium | Record the exact driver and permissions; treat the Mac as a prototype host only; question 2 compares it with a Linux/Windows host |
| Touch maps to mouse in ways the game UI does not expect (hover, right-click, drag threshold) | Medium | Medium | Test explicitly (§4.3); file input-layer follow-ups only if needed |
| Pixel art and small text are degraded by encoder compression and scaling | Medium | Medium | Resolution/bitrate matrix; integer scaling; prefer streaming at a multiple of the game's design resolution |
| Abandoned session keeps running and consumes the host or holds unsaved state | Medium | Low–Medium | Sunshine undo command kills the game; per-session `LABELLE_DATA_DIR`; note that the engine has no disconnect-pause seam today (§1.2) |
| Saves from different testers mix, or the developer's real saves get overwritten | Medium without config | Medium | Always set `LABELLE_DATA_DIR` per session (an absolute path is required, per `data_root.zig`) |
| Results do not generalise (one Mac, one tablet, one network) | High | Medium | State this limit in the findings; the cost estimate must name its assumptions |
| Licensing problems if an integration is packaged later | Low now | Medium | Check upstream licences before any redistribution. This experiment installs software only for local use |
| Scope creep into a streaming backend or cloud service | Medium | Medium | §2.9 lists follow-ups only; anything larger needs a new RFC |

---

## 6. Security notes

- Streaming reduces the risk of extracting the binary and assets through the normal tester path. It does not prevent screen recording, imitation, or extraction from builds distributed some other way.
- A paired Moonlight client gets real OS input on the host. For any tester outside the core team, use at minimum a dedicated host or VM, a dedicated non-admin user, a game-only app entry, no stored developer credentials in that session, and per-session saves.
- Invitations, session expiry, queues and concurrent players (question 4) are **not** provided by Sunshine for this use case. Each concurrent player needs a separate game instance and, in practice, a separate host or VM, display and encoder. The findings should state this as a requirement. It is not something this phase builds.

---

## 7. Validation plan

### 7.1 Existing evidence (already available)
- Source review in §1.2: env-var launch channel, `LABELLE_DATA_DIR` save isolation, desktop input forwarding, fullscreen request and read-back, cursor controls, `frameStats()`, and no focus-loss or disconnect pause seam.
- No streaming experiment has been run. There are no measurements, screenshots or version records yet.

### 7.2 Proposed validation (to be done by the experiment)
1. **Functional:** run checklists §4.1 to §4.3 on the LAN, recording pass, fail or degraded with evidence for each item.
2. **Quantitative:** run each Phase 3 measurement twice, local and streamed, on the same scenes and game revision, in the same order. Record the raw numbers and the method used (camera fps, overlay values, `frameStats()` output, `powermetrics` samples).
3. **WAN:** repeat a subset of Phase 3 over the Brazil-representative connection, with an external port scan to confirm no public admin exposure.
4. **Robustness and security:** run the Phase 5 scripted scenarios (disconnect mid-input, quit paths, escape attempts) and record the outcome of each.
5. **Teardown check:** after restoring the host, confirm that permissions are revoked, the services are stopped or removed, and the pairing is gone. Record what remains on purpose.
6. **Engine regression:** none needed, because Phase 0 to Phase 3 change no engine code. If a follow-up does change the engine, it must add tests under `test/` following the repo's module and test pairing.

### 7.3 Go/no-go rule (proposed)
**Go** for invite-only playtests if all of the following hold:
- Every item in §4.1 and §4.2 passes with no code change, or with config changes only.
- Tablet touch is usable for core interactions.
- Streamed LAN latency is within a perceptibly acceptable margin of local play.
- WAN play from the representative connection is playable.
- Small text is readable at a bitrate the connection sustains.
- Escape risk is mitigated well enough for the trusted tester group.

Otherwise the result is **no-go** or **go with conditions**, and the blocking failures are listed by layer.
