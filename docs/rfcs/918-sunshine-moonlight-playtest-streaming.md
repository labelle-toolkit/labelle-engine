# RFC 918: Evaluate Sunshine/Moonlight streaming for private Labelle playtests

**Status:** Draft (design only; no experiment has been run yet)
**Author:** Moca Pipeline (card 6), for the labelle-engine maintainers
**Date:** 2026-11-13
**Issue:** labelle-toolkit/labelle-engine#918
**Scope of this document:** how to run the feasibility experiment, what it must measure, and how its results lead to a go/no-go decision and follow-up work. This RFC does **not** propose engine code changes. It describes the engine seams the experiment depends on, so that any follow-up lands in the right layer.

**Location.** Existing engine RFCs live at the repository root (`RFC-*.md`, e.g. `RFC-CONSTANTS.md`) and in `rfc/`. This one is in `docs/rfcs/` because the pipeline that produced it requires that path and permits only this one file to change. It follows the root RFCs' header fields (Status/Author/Date). If maintainers prefer, it can be moved to `RFC-PLAYTEST-STREAMING.md` when it is accepted. A `docs/rfcs/README.md` index is out of scope for this change.

**What merging this RFC means.** Merging it accepts the *experiment protocol* only. It does **not** complete #918. The issue's completion criteria need a published setup guide and findings: tested versions, measurements, visual evidence, known failures and a go/no-go recommendation. #918 stays open until the experiment has run and those findings are appended to this RFC or linked from it. When they are, this RFC's status changes from *Draft* to *Accepted, protocol* and then to *Concluded* (with the go/no-go result).

---

## 1. Problem and context

### 1.1 Problem

Today, prerelease playtesting means sending testers a game package: the binary and its assets. Anyone who receives the package can extract the assets and reverse-engineer or repackage the binary. Issue #918 asks whether **Sunshine** (host capture, encoding and input injection) plus **Moonlight** (an installed client) is a practical way to run *invite-only* remote playtests in which the tester never receives the package. The first target is **Flying Platform**. It will be hosted on the existing **Mac** and played on the existing **Android tablet**.

This is a feasibility investigation, not a plan for a cloud-gaming service. The intended result is a reproducible setup guide, measurements and a go/no-go decision. Follow-up issues should be filed only where the experiment shows a need for them.

### 1.2 What the code shows today (existing evidence)

All findings in this section come from reading this checkout (HEAD `0999fbd`). None of them has been run or tested.

| Area | What the source shows | Why it matters for streaming |
|------|-----------------------|------------------------------|
| Entry point | The engine is a library with no `main()` (CLAUDE.md). The generated entry point comes from `codegen/main.zig.template`; its frame loop, window setup and shutdown are a single `{{lifecycle}}` placeholder (`codegen/main.zig.template:57`), which the CLI fills with a backend-specific block (`codegen/manifest.zon:32-34`). | Launch, window, quit and signal behaviour under Sunshine belong to the CLI-generated lifecycle block or the backend, not to this repo. This checkout cannot show how that block reacts to SIGTERM/SIGINT. |
| Quit | `Game.quit()` only sets `running = false` (`src/game/lifecycle_mixin.zig:234-236`); `isRunning()` reads it (`:238-240`). I found no signal handler in `src/` or `codegen/`. | A graceful exit goes through the game's own quit path (in-game menu or window close, which the backend turns into a quit). A signal sent to the process may bypass that path, and with it any save-on-exit logic the game has. §2.4 step 6 tests both paths separately. |
| Environment knobs | **Set by the CLI:** `LABELLE_SCENE` (`src/runtime_env.zig:1-21`, written by `labelle run --scene=<name>`, cli#229) and the screenshot variables `LABELLE_SCREENSHOT_PATH` / `LABELLE_SCREENSHOT_AFTER_SEC` (`src/screenshot_request.zig:5-8`, parsed at `:110-125`; the generated main then calls the backend's `takeScreenshot`). **Read by the engine and set by whoever launches the game:** `LABELLE_DATA_DIR` (`src/storage/default.zig:65,70`, only on the default storage path, see the next row) and `LABELLE_PROFILE=1` (per-script tick ranking to the log, `src/root.zig:787`). | A Sunshine application entry can be a command plus environment variables. Caveats: `LABELLE_SCENE` is only a *hint*. The engine does not apply it; the game's loading controller has to call `requestedScene()` after `assets.allReady` and recognise the name (`src/runtime_env.zig:4-9`). `LABELLE_DATA_DIR` is honoured on only one storage path. The screenshot variables give a **host-side reference frame** with no streaming loss, which the visual-quality method uses (§2.6). |
| Save location | `storage.Default(Backend).init` (`src/storage/default.zig:31-80`) picks the save directory in this order: (1) an injected `options.store` returns early, and no path is used (`:34`). (2) `options.native_directory` is used as is (`:42-56`). (3) Otherwise `data_root.resolve` is called with `override = env("LABELLE_DATA_DIR")`, `home = env("HOME")` and the other OS variables (`:57-77`). That override must be absolute (`src/storage/data_root.zig:61-64`). On macOS the fallback base is `HOME` (`data_root.zig:77`), giving `$HOME/Library/Application Support/<app_id>`, with `saves/` appended (`default.zig:77`). `data_root.zig` never reads the environment itself. The engine does not call `storage.Default`; **the game does**. `docs/persistent-blobs.md:36-46` describes the options and `:77-84` lists the resolver precedence. | `LABELLE_DATA_DIR` isolates sessions **only if** Flying Platform uses `storage.Default` without `native_directory` and without an injected store. If the game passes either one, or calls `storage.Files.init` directly, the variable is silently ignored. Saves then land wherever the game decides, possibly the playtest user's real directory. This must be verified (Phase 0, gate G2). |
| Input model | `src/game/input_mixin.zig` forwards backend `Input` state: keyboard (`:15-27`), mouse position, wheel and buttons (`:29-61`), gamepad (`:67-90`) and touch (`:94-117`). `src/input_types.zig:134` sets `MAX_TOUCHES = 10` and `:145` defines `Touch`. `src/gestures.zig` recognises pinch, pan, swipe and similar gestures from raw touches. | Sunshine injects OS-level mouse, keyboard and gamepad events, and desktop backends read OS input. The desktop path *should* therefore see streamed input unchanged. Touch on a desktop backend takes a different path. Moonlight most likely turns the tablet's touches into mouse events, in which case the engine's `Touch`/`Gestures` path is not exercised. The experiment must confirm or refute this (§4.3). |
| Cursor | `setCursorVisible` and `isCursorOverWindow` (`src/game/lifecycle_mixin.zig:255-266`) go through `core.CursorControls`. Unsupported backends return `false`. | If the game hides the OS cursor and draws its own, the stream shows the game-drawn cursor. Check for a duplicated or lagging cursor. |
| Fullscreen | The engine stores the *desired* state (`setFullscreen` `:282`, `takeFullscreenRequest` `:303`, `setFullscreenAvailable` `:343`, all in `lifecycle_mixin.zig`). The generated main applies it and reads the real state back. | Fullscreen and resolution switches under capture go through the backend window path. Sunshine may change the display mode when a client connects. |
| Pause | `setPaused`/`isPaused` (`src/game/scene_runtime_mixin.zig:25,42`). The only automatic pause is opt-in, on controller loss: the setter is at `src/game/input_events_mixin.zig:85-91` and the pause itself at `:252`. #465 is the precedent cited there. I found **no window-focus-loss, app-suspend or client-disconnect hook** in this repo. | A Moonlight disconnect is invisible to the game, because the window stays focused on the host. Today nothing pauses the game when a tester drops. The expected result of the pause test (§2.8) is therefore "keeps running". |
| Frame stats | `src/frame_profiler.zig:22` keeps a **120-frame** ring of dt values (about 2 s at 60 fps). `FrameProfiler.Stats` holds only `min_ms`, `avg_ms`, `max_ms`, `fps` and `samples` (`:70-80`): no percentiles. `game.frameStats()` returns that struct (`src/game/misc_mixin.zig:310-312`), and `frameHistory(dst)` copies the raw window out, oldest first (`:317-319`). Both are accessors only; nothing logs them. | A session-long p95 frame time cannot come from `frameStats()`. It needs raw frame times collected over the whole session (§2.6). |
| Editor preview | `src/preview_mode.zig` and `src/preview/*` connect out to the editor for PIE, using hello/heartbeat/bye frames and SHM/IOSurface frame offers. | The issue says the first experiment "should not require … modifications to the existing editor-preview protocol". **This RFC also decides** not to reuse or extend that protocol for streaming. That is a scope decision, not the issue's wording. Streaming uses ordinary OS capture. |
| macOS test coverage | CI runs the full test suite on Linux only; macOS is noted as out of scope (`.github/workflows/ci.yml:73-74`). | The Mac host is outside the engine's tested matrix. A macOS-specific failure in the experiment may be an engine/backend bug, not a streaming one (§5). |

**Not verifiable from this checkout, so the experiment must record them (Phase 0):**
- the CLI-filled `lifecycle` block, including how it handles signals and window-close;
- the CLI's launch and stop behaviour (the README documents only foreground `labelle run`, `README.md:56-68`), and whether `labelle run` stays as a parent process or execs the game;
- the backend and renderer Flying Platform uses on macOS, and how that backend handles focus and HiDPI;
- how Flying Platform initialises storage, and when it writes saves (autosave, on explicit save, on quit);
- whether its loading controller honours `LABELLE_SCENE`;
- whether the game or its debug tooling can write raw frame times to a file.

### 1.3 Security motivation and its limits

Streaming keeps the package from reaching testers through the normal client path. It does **not** prevent recording or imitation. It does not prevent extraction after a host compromise, and it does not protect a version distributed some other way. It also adds a new risk: a remote party now controls input on the host. A shared desktop with Sunshine is not a safe multi-user service (§6).

---

## 2. Proposed design

The design is an experiment protocol in phases. Each phase has entry gates and records evidence. **Phases 0 to 4 use unchanged engine, assembler and CLI code.** Wrapper scripts, Sunshine configuration and, at most, a game-side debug log of frame times (§2.6) are allowed. Any CLI or engine addition is a follow-up (§2.10).

**Participants.** A *core-team member* is someone who already has repository access to Flying Platform and could already obtain the package. Only core-team members operate the stream before the Phase 5 gate. *Prospective invited testers* answer the Phase 0 survey (§2.2) only; they do not connect. Every participant, their device and their connection are recorded in the findings.

**Effort and priority.** The full matrix is large: 3 scenes × 3 resolutions × 3 bitrates × 2 codecs × 2 chroma is 108 cells before latency, audio and stability. §2.6 defines a **minimum viable matrix** (MVM) that must be completed and an extended matrix that runs only if time allows. Rough effort, to be checked against actual times in the findings: Phase 0 half a day; Phase 1 one day; Phase 2 half a day; Phase 3 MVM two days; Phase 4 one day; Phase 5 half a day; Phase 6 half a day. Priority order if time runs out: G1–G4 gates → functional checklist → stop/save/abandon tests → latency → MVM readability → host load → WAN → extended matrix.

### 2.1 Topology

```text
Mac host
  admin account        : installs software, approves admin prompts; reached over SSH during sessions
  "labelle-playtest"   : standard (non-admin) user, the ACTIVE CONSOLE session, runs Sunshine + game
    └─ start-session.sh (Sunshine app "do" command)
         - mints <session-id>, creates /Users/labelle-playtest/sessions/<session-id>
         - sets LABELLE_DATA_DIR=<that dir>  [only effective if gate G2 passes]
                LABELLE_SCENE=<scene>        [only effective if gate G3 passes]
         - starts labelle run … (or the built binary) as a CHILD (no exec),
           records wrapper PID, CLI PID and game PID to sessions/<id>/pids
         - waits for the child, then runs post-exit steps (copy-back if G2 fallback 2)
    └─ stop-session.sh (Sunshine app "undo" command): see §2.4 step 6
    └─ watchdog (only if needed, §2.4 step 7)
    └─ Sunshine: display + audio capture + input injection
         app entry = "Flying Platform" only; "Desktop" entry removed
         web admin UI bound to localhost; UPnP/NAT-PMP disabled
        │  LAN first (Phases 1–3); then a team-controlled WAN path via VPN overlay (Phase 4)
        ▼
Android tablet: Moonlight (paired by PIN); touch mode recorded; optional BT mouse/keyboard/controller
```

**Admin access without taking the console.** Capture stops if the console switches away from `labelle-playtest` (§2.3). During any session, the admin account is therefore used **only over SSH** from a second machine on the LAN (Remote Login enabled for the admin account only, recorded in the settings log). Privileged samplers such as `powermetrics` are started by the admin over SSH (`sudo powermetrics …` writing to a file) before the session and stopped over SSH after it. No sudoers rule is granted to `labelle-playtest`. If SSH is not available, the fallback is a root `launchd` job installed by the admin before the session that runs `powermetrics` for a fixed duration; it is listed in the settings log and removed in Phase 6. The mechanism used is recorded.

### 2.2 Phase 0: Inventory, survey and gates (no installs)

**Versions table.** The findings doc has exactly one versions table, and §4.1 refers to it. It contains:

| Field | Value to record |
|-------|-----------------|
| macOS build | e.g. `sw_vers` output |
| Host hardware | model, CPU, GPU, RAM |
| Host display | resolution, refresh rate, connection (built-in, HDMI, headless dongle, virtual) |
| Sunshine | version, install method (installer or Homebrew), build source |
| Encoder | hardware or software encoder (e.g. VideoToolbox), codec(s), chroma subsampling, bit depth |
| Audio capture | loopback driver name, version, licence |
| Moonlight | Android app version, install source, configured stream fps |
| Client device | tablet model, Android version, screen resolution, **display refresh rate**, Wi-Fi band |
| Game | Flying Platform git revision, build config |
| Toolchain | engine, assembler and CLI revisions |
| Runtime | backend, renderer, design resolution, vsync/frame cap |
| Measurement tools | camera model and fps, SSH client host, sampler commands |

**Tester-access survey (answers question 3).** Before any setup, ask a small group of prospective invited testers (target: at least 5, or everyone on the current invite list if fewer) a short written survey. Record the answers anonymised:
- device and OS they would play on (Android/iOS tablet or phone, Windows, macOS, Linux, Chromebook, smart TV);
- whether they would install Moonlight from an official store;
- whether they would also install a VPN client (needed by the §2.7 WAN design) or accept a mesh-VPN invitation;
- whether they expect browser-only access, and whether they would decline without it;
- their connection type and approximate up/down speed, and their region.

The survey is evidence about *willingness and device mix*. It does not test Moonlight on their devices. If fewer than 3 responses come back, Q3 is answered as "insufficient evidence" with that limit stated. Browser-only access stays out of scope (§3).

**Gates.** These are verified by reading the game's source and doing one local run. A gate that fails blocks the phase that depends on it, until its fallback is in place.

- **G1 (backend):** record the backend and renderer, and whether the game draws its own cursor.
- **G2 (save root):** find Flying Platform's storage initialisation. Record which branch it takes: injected store, `native_directory`, `storage.Default` defaults, or `storage.Files.init` directly. Also record **when** the game writes saves (autosave interval, explicit save action, on quit). **Probe:** run locally with `LABELLE_DATA_DIR=/tmp/lp-probe-<n>`, trigger a save, and confirm that the save file appears under `/tmp/lp-probe-<n>/saves/` and not under `~/Library/Application Support/<app_id>`. If the probe fails, use a fallback in this order:
  1. **Per-session `HOME` for the game process only**, if the game's path derives from `HOME` (on macOS, `storage.Default` takes the base from `HOME`, `data_root.zig:77`). The wrapper sets `HOME` only in the environment of the *game* process, not of `labelle run`, so the CLI's own config and cache are unaffected. If the game can only be started through `labelle run` and the CLI passes its environment down, first check that `labelle run` works with the per-session `HOME` (it can find its toolchain/cache) and record the result; otherwise use fallback 2.
  2. **Copy-on-start:** the wrapper copies a clean save directory into the game's fixed location before launch and moves it to `sessions/<id>/` after the game exits, with only one session at a time. This requires the wrapper to stay alive as the game's parent (no `exec`, §2.1). The copy-back is idempotent (it is keyed by session ID and skips if `sessions/<id>/saves` already exists) and is also run by `stop-session.sh` and by Phase 6 teardown, so a killed wrapper does not lose the save.
  3. A narrowly scoped game-side change, filed as a follow-up.

  The chosen mechanism is recorded. Phase 2 does not start until a save is shown to land in the session directory.
- **G3 (scene selection):** confirm that the loading controller calls `requestedScene()` and record the scene names it accepts. If it does not, scenes are reached manually in game and the findings say so.
- **G4 (stop paths):** see §2.4, step 6.
- **G5 (frame-time capture):** decide how raw frame times are collected (§2.6). Record whether it uses an existing debug feature or a temporary game-side hook.

**Local baseline.** Measure the same scenes later used for streaming: moving clouds, a busy colony scene and a small-text UI panel. Use the methods of §2.6. Start the host settings log (§2.3) before anything is changed.

### 2.3 Host settings log (started in Phase 0, restored in Phase 6)

Record the original value, the temporary value and the restore step for each of these:
- energy saver, display sleep and system sleep;
- screen lock and screensaver;
- auto-login and fast user switching;
- application firewall;
- Remote Login (SSH, admin account only), Remote Management and Screen Sharing;
- display resolution and refresh rate;
- default audio output device;
- **Focus / Do Not Disturb** for `labelle-playtest` (on, notifications hidden, including when mirroring/sharing the screen);
- login items and apps open in `labelle-playtest` (none except Sunshine; no other audio-producing app);
- Dock auto-hide and menu bar auto-hide for `labelle-playtest`;
- Sunshine UPnP/NAT-PMP (disabled), admin UI bind address, and whether the admin UI is stopped during sessions (§2.8);
- installed software, launchd jobs, and TCC permissions (Screen Recording, Accessibility, Microphone if prompted), with the **user account** each grant was made in.

The `labelle-playtest` user must remain the **active, unlocked console session** for the whole test, otherwise capture stops. Record how this is ensured: auto-login or fast user switching to that user with sleep and lock disabled, or a headless display adapter. The playtest session shows only the game: fullscreen, Dock and menu bar hidden, no other windows open.

### 2.4 Phase 1: Host setup and pairing (LAN)

1. **Install (admin).** On the admin account, install Sunshine and the audio loopback driver if macOS Sunshine needs one. Record which actions needed admin rights: installer authentication, driver/system-extension approval. Install Moonlight on the tablet.
2. **Create the playtest user.** Create the standard (non-admin) `labelle-playtest` user. Copy only the built game or a CLI checkout into it. Store no developer credentials, SSH keys, tokens or browser profiles in it.
3. **TCC grants, made in the playtest user's session.** macOS TCC permissions are stored per user as well as per app. Approving Screen Recording or Accessibility in the admin account does not grant them to Sunshine running as `labelle-playtest`. So: log in to the console as `labelle-playtest`, start Sunshine, and approve each prompt there. Where System Settings asks for an administrator to unlock the pane, type the admin credential at that prompt without switching user. Record, per grant: the app, the user account it was granted in, and whether admin authentication was needed. **Check before pairing:** in that same session, confirm Sunshine's own log shows display capture, audio capture and input injection working (for example, a local Moonlight test client, or Sunshine's log after a first pairing attempt). This is an upstream platform assumption until observed.
4. **Network exposure.** Bind Sunshine's web admin UI to localhost and set a strong admin credential. Disable UPnP/NAT-PMP. **Before any WAN work**, list listeners (`lsof -iTCP -sTCP:LISTEN`, `lsof -iUDP`) and confirm that the router has no port mappings.
5. **App entry.** Remove the Sunshine "Desktop" application entry. Define one "Flying Platform" entry whose *do* command is `start-session.sh` and whose *undo* command is `stop-session.sh`. Store both scripts with the findings.
6. **Stop paths (gate G4).** The CLI documents no stop command (`README.md:56-68`) and the engine's `quit()` only flips `running` (§1.2). There are two distinct stop paths, and both are tested:
   - **(a) Graceful quit, for save flush.** The tester (or an operator on the tablet) quits through the game's own path: the in-game quit/menu action if Flying Platform has one, otherwise Cmd-Q or closing the window, which the backend turns into a quit. This is the only path the save-preservation criterion is judged on.
   - **(b) Signal-based abandonment, for cleanup.** `stop-session.sh` reads `sessions/<id>/pids`, sends SIGTERM to the **game PID**, waits N seconds (start with N = 10), then SIGKILL; it then signals the `labelle run` PID if it is still alive, and runs the idempotent copy-back if G2 fallback 2 is used. The manual equivalent is Ctrl-C/SIGINT to a foreground `labelle run`.

   For each path record: the PID tree before the stop (`ps -o pid,ppid,command -U labelle-playtest`), whether `labelle run` is a parent of the game or execs it, which process received the signal, exit codes, whether the game exited, whether any process was orphaned, and which saves exist afterwards. If neither path leaves a clean process table, record a launch-tooling failure. A CLI stop command would be a follow-up, not part of this experiment.

   **What "save preservation" means.** *Completed saves* are files the game wrote before the stop: by explicit save, by autosave, or (on path a) by its quit handler. *Unsaved progress* is play state since the last write. The criterion (§7.3) is: completed saves are never lost or corrupted on either path, and path (a) preserves whatever the game's own design says it saves on quit. Losing unsaved progress on path (b) is the **expected** result and is recorded, not failed. If the game does not save on quit, path (a) is recorded as "no save-on-quit" and is judged on completed saves only.
7. **Abandoned-session test.** Pair the tablet over the LAN, start the app, then kill Moonlight abruptly (force-stop, or turn Wi-Fi off). Record whether Sunshine runs the undo command, how long that takes, and whether the game exits. The Sunshine version's documentation is cited in the findings, and the behaviour is treated as an assumption until this test is observed. If the undo command does not run on an abrupt drop, add a host-side watchdog: a script, running as `labelle-playtest`, that calls `stop-session.sh` when no Sunshine client has been connected for T minutes (start with T = 3), based on Sunshine's log or API. Retest.
8. **Invitations and setup cost.** A static Sunshine app entry cannot mint a session ID, so the wrapper creates it (timestamp plus random suffix). Retention: session directories are kept until the findings are written and then deleted in Phase 6. An invitation is a PIN pairing done in person or over a trusted channel by a core-team member. Revocation means unpairing the client in the Sunshine admin UI. For every session from here on, record the wall-clock time to get a fresh session ready and the number of manual interventions (any step outside "start app in Moonlight"), to answer question 6 (§2.9).

### 2.5 Phase 2: Functional compatibility (LAN, unchanged runtime)

Run the checklists in §4.1 to §4.3. Record each item as pass, fail or degraded, with evidence (screenshot, clip or note). For tablet input, record Moonlight's touch mode and test both the **touchscreen** (direct) and **trackpad** (relative) modes if this Moonlight version offers them. Also check macOS **Secure Input**: if a system password field appears (for example an admin prompt), record whether injected keystrokes stop working, during the prompt and after it closes. Classify every failure by layer:

- **Backend/window** (generated main, backend): focus, fullscreen, resolution, HiDPI scale, cursor.
- **Input layer** (engine `input_mixin` or backend input): coordinate mapping, wheel, drag, hover, right-click, stuck keys.
- **Launch tooling** (CLI, wrapper scripts or Sunshine app entry): start, stop, environment variables, save root.
- **Host/stream config** (Sunshine/Moonlight settings): bitrate, codec, scaling. These need no code.

### 2.6 Phase 3: Quality and resource measurement (LAN)

**Fixed conditions.** Write down the host refresh rate, game vsync/frame cap, Sunshine frame limit, Moonlight fps and client display refresh rate. Use a fixed, repeatable camera path, either scripted input or a scripted pan-and-zoom route repeated by hand along the same route and timed. Mark a start timestamp for each run so that host samples (powermetrics, `ps`, `nettop`, frame times) can be aligned to the camera path afterwards. Save the exact Sunshine and Moonlight settings next to every screenshot and clip.

- **Latency.**
  - Conditions: *L* local baseline (Mac display, mouse click); *S-touch* streamed (tablet display, tap); *S-mouse* streamed (tablet display, **Bluetooth mouse** paired to the tablet). *S-mouse* vs *L* isolates the stream, because both use a mouse click; *S-touch* records what testers actually feel.
  - Film each condition with the same high-speed phone camera (target 240 fps; record the actual fps), framing the input action and the screen together. Count frames from input to the first visible response. **Measurement resolution** is one camera frame (≈ 4.2 ms at 240 fps); report it with every number.
  - **≥ 100 trials per condition**, interleaved in blocks of 10 (L, S-mouse, S-touch, repeat) on the same scene so that drift affects all conditions equally.
  - Report per condition: median, p95 and max, each with a 95 % bootstrap confidence interval. For the GO threshold, compute the **added latency** as the per-trial difference between *S-mouse* trial *i* and *L* trial *i* within the same block (paired by scene and block position), and report the p95 of that difference with its CI. Also show the two distributions side by side (histogram or ECDF).
  - Record the network, decode and render times from Moonlight's performance overlay for each block.
- **Subjective responsiveness.** At least two core-team members play a fixed 5-minute task (place and move items, pan the camera, use a menu) locally and then streamed. They rate each run on a 1–5 scale (1 = unplayable, 3 = noticeable but fine for playtesting, 5 = indistinguishable). Raters and scores are recorded.
- **Frame pacing.**
  - *Host:* `frameStats()` gives only min/avg/max over 120 frames, so it cannot produce a session p95 (§1.2). Collect **raw frame times** instead, by the method fixed in gate G5: (1) an existing game debug feature that writes per-frame dt to a file, if Flying Platform has one; otherwise (2) a temporary game-side debug script, in the Flying Platform working copy only and never committed to the engine, that every 120 frames calls `frameHistory()` into a 120-element buffer and appends it to a CSV with a timestamp. Window: from the first frame after the scene finishes loading (`assets.allReady`) to the end of the camera path; scene loads are excluded and reported separately. Compute p95 frame time and the count of frames over 1.5× the target offline, from the CSV. If neither method is possible, report min/avg/max from `frameStats()` screenshots every 30 s and state that no p95 is available. `LABELLE_PROFILE=1` is run separately for the per-script ranking, not during latency runs.
  - *Client:* record dropped frames and fps from the Moonlight overlay.
- **Audio sync.** Use an in-game action with both a sound and a visual cue (or a clap test on a debug scene, if one exists). Film the tablet speaker and screen together and measure the audio-to-visual offset over ≥ 20 trials, locally and streamed. Report median and max with the camera frame interval.
- **Visual quality.**
  - **Reference frames.** For each scene and camera checkpoint, capture a host-side frame with `labelle run --screenshot=<path> --after=<sec>` (which sets `LABELLE_SCREENSHOT_PATH`/`LABELLE_SCREENSHOT_AFTER_SEC`, `src/screenshot_request.zig:5-8`). Pair every client screenshot with the host reference of the same checkpoint, so that compression and scaling loss can be separated from the game's own rendering.
  - **Viewing conditions.** Client screenshots are taken at the tablet's native resolution with Moonlight scaling recorded; legibility is judged on the tablet at a normal hand-held distance (≈ 40 cm, recorded), not only from screenshots on a monitor.
  - **Minimum profile (pre-registered).** The readability threshold (§7.3) is judged at a fixed profile: stream resolution 1080p (or the nearest integer multiple of the game's design resolution, if one exists at or below the tablet's native), 20 Mbps, H.264 4:2:0, client at 1:1 pixel mapping where Moonlight allows it.
  - **Minimum viable matrix (must complete).** 3 scenes (moving clouds, busy colony, small-text panel) × {tablet native, 1080p, 720p} × {10, 20 Mbps} × H.264 4:2:0 = 18 cells, each with a pass/fail per scene for "pixel art crisp", "smallest text legible", "no visible banding/macroblocking on clouds".
  - **Extended matrix (if time allows).** Add 40 Mbps, HEVC, 4:4:4 if the encoder supports it, and the integer-multiple resolution.
  - The bitrate the WAN link sustained (§2.7) is recorded **separately** and compared with the minimum profile; it does not move the threshold.
- **Host load.** Started and stopped by the admin **over SSH** (§2.1): `sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -o <file>`. Also collect, as `labelle-playtest` or over SSH, memory per process (`ps -o rss` for the game and Sunshine, every 10 s) and network bitrate (`nettop -P -L 0` on the host, plus the Moonlight overlay). If GPU encoder occupancy is not exposed, use an Instruments Metal System Trace capture or record "not measurable" with the tool you tried. Units: % CPU, mW, GPU active residency %, MB, Mbps. Compare the same scene streamed and not streamed, idle and busy, on the same camera path, aligned by the run start timestamps. Note that the SSH session itself adds a small load and is present in both conditions.
- **Stability.** Run one representative session of at least 30 minutes. Log disconnects, audio/video drift, crashes and stuck input.

### 2.7 Phase 4: Internet test (core team only, team-controlled connection)

**Entry gates:**
- every Phase 1 gate passes;
- UPnP is disabled and the router has no port mappings;
- the listener check from §2.4, step 4 is clean;
- the abandoned-session test from §2.4, step 7 passes.

Only core-team members operate the client, on a connection the team controls and chosen to represent players in Brazil (for example a team member's home line or mobile hotspot in Brazil, or the nearest available equivalent, stated as such). No third party touches the input. Connect through a VPN overlay (WireGuard or a mesh VPN) rather than port forwarding, so the Sunshine ports and admin UI are never public. An external port scan of the host's public IP confirms that nothing is exposed.

Record:
- **Path:** tunnel type and topology (plain WireGuard, or the mesh product and version); whether the session ran **direct or relayed** (from the VPN's status output); encryption/MTU overhead as configured.
- **Underlying lines:** for both ends, ISP, region/city, access technology (fibre, cable, DSL, 4G/5G), Wi-Fi band or wired, and measured up/down capacity (a speed test before and after the session). Also measure the underlying RTT outside the tunnel (ping to the other end's public IP, if reachable) next to the in-tunnel RTT.
- RTT, jitter and packet loss in the tunnel during the session.
- the highest bitrate the link sustained with loss < 1 %, and the readability result at that bitrate compared with the minimum profile;
- the NAT, firewall and VPN requirements a tester would have to meet.

If the session was relayed, state that the WAN latency is likely an **upper bound** for a direct path; if direct, state that testers whose NAT forces relay may see worse. Then repeat the latency (S-mouse and S-touch, ≥ 50 trials each), readability (MVM at the sustained bitrate) and stability subset of Phase 3.

### 2.8 Phase 5: Robustness and escape assessment (before any non-core participant)

- **Robustness.**
  - Disconnect and reconnect mid-drag and mid-keypress (Wi-Fi off on the tablet for ~10 s), then check the host for stuck keys or buttons, and whether they release within 2 s of reconnect or session stop.
  - **Pause behaviour.** Three actions, each with expected and actual behaviour recorded:
    1. *Press the game's own pause (if any) on the tablet, then disconnect.* Expected: the game stays paused while the client is gone; resumes on reconnect.
    2. *Disconnect without pausing.* Expected from the code (§1.2): the game **keeps running** at full CPU/GPU cost until the undo command or watchdog stops it. Record the time until stop and the host load in that interval.
    3. *Switch away inside the stream* (Cmd-Tab, if reachable). Record whether the game pauses on focus loss (not expected from the engine; may come from the backend).
    Decision rule: case 2 is acceptable if the game is stopped through the graceful path or by the watchdog within **5 minutes** of the drop and completed saves survive. Otherwise it is a gap, and a session-end pause/quit seam becomes a follow-up (§2.10).
  - Save preservation on both stop paths, as defined in §2.4 step 6, in the session directory selected by G2.
- **Escape and exposure walk, run from the tablet as the playtest user.** For each item, record what a tester can **reach**, **see** or **hear**:
  - OS shortcuts: Cmd-Tab, Cmd-Q, Cmd-Space (Spotlight), Mission Control, Force Quit (Cmd-Opt-Esc), Cmd-H;
  - quitting the game, and what is then shown (desktop, Finder, Sunshine falling back to the desktop);
  - **visual exposure:** menu bar, Dock, other windows, notification banners, the Sunshine tray/menu item, file names visible in any dialog;
  - **audio exposure:** system sounds and audio from other apps (none should be running): with the game idle, listen on the tablet for 5 minutes and record anything audible other than the game;
  - file open/save dialogs;
  - launching a **Terminal** or shell;
  - launching a **browser**;
  - **local admin UI:** whether the Sunshine web UI on `https://localhost:<port>` is reachable from anything the tester can open, and whether its credential is stored anywhere the playtest user can read;
  - **clipboard** sync between client and host;
  - any Sunshine/Moonlight **file transfer** feature;
  - **network egress** from the playtest user, e.g. whether `curl` to an external host works;
  - whether the **game bundle and assets** can be read and copied off the host (local copy and upload).

  **Admin UI decision.** Binding to localhost protects against the network, not against a tester who escapes to a browser on the host. Record one of: (a) Sunshine's web UI is disabled or stopped during sessions, if the Sunshine version allows running without it; (b) it is bound to a UNIX socket or a port only the admin can reach, if supported; or (c) the risk is accepted, with a strong unique credential not stored in the playtest account, justified by the escape walk showing no browser is reachable. Non-core sessions require (a) or (b), or a host where (c) is backed by a blocked browser.
- **Isolation statement.** A standard user *reduces* access to the developer's files. It is **not a security boundary**: a local user can still read world-readable files and the game install, and with a shell and network access can copy the bundle off the host. Any participant outside the core team therefore requires all of the following:
  - a dedicated host or VM with no developer credentials;
  - a session that shows only the game (fullscreen, Do Not Disturb on, no other apps or audio sources);
  - egress filtered to the VPN/stream path only;
  - no shell, browser or file-transfer reachable from the game-only app;
  - the admin UI not reachable from the playtest session;
  - per-session saves.

  These requirements are written into the findings before any invitation is sent.

### 2.9 Phase 6: Teardown and deliverables

**Teardown:**
- restore every entry in the settings log (§2.3), including Remote Login, Do Not Disturb and any launchd job;
- run the idempotent save copy-back once more, if G2 fallback 2 was used;
- remove the pairings;
- revoke the TCC grants in the account each was granted in;
- uninstall or disable Sunshine and the audio driver;
- delete the session directories and, if it is not kept, the playtest user;
- re-check that no listeners remain;
- document anything that is intentionally left in place.

**Deliverables:**
1. `docs/playtest-streaming.md` (or the equivalent in the toolkit docs): a setup guide with exact commands, the wrapper scripts, versions and the Sunshine app entry.
2. A findings report containing:
   - the versions table;
   - the checklist result matrix and the measurements, with raw data files;
   - linked screenshots and clips, each paired with its host reference frame and its stream settings;
   - known failures classified by layer;
   - the participant log and the survey results;
   - answers to the six questions in the issue, using the criteria below;
   - the decision from the §7.3 table.
3. **Question-specific criteria.**
   - **Q1 (runtime unchanged):** yes if every §4.1–§4.3 item passes with config/script changes only; otherwise list each failure with its layer.
   - **Q2 (host suitability, paper):** compare the Mac with Linux and Windows hosts against named criteria: Sunshine's support tier for that OS, encoder available, audio capture mechanism (driver needed or not), headless/virtual display support, scriptable unattended setup, licence cost, one instance per VM possible, and whether the engine's CI tests that OS (today only Linux, §1.2). The Mac verdict uses the measured Phase 1–5 results; the Linux/Windows verdict is a **paper** comparison and is labelled as such.
   - **Q3 (installed client):** acceptable if at least 80 % of survey respondents use a device Moonlight supports and would install it (and the VPN client, if the WAN design keeps one); otherwise "not acceptable without a browser path", which would justify a separate browser-streaming evaluation. With fewer than 3 responses: "insufficient evidence".
   - **Q4 (controls):** fill in the control matrix below.
   - **Q5 (cost):** pick one concrete GPU-capable host offering and record its vCPU, RAM, GPU/encoder, region (prefer São Paulo), hourly price and egress price. Compute the cost per active session-hour from the measured Phase 3 bitrate × egress price, one instance per player, an idle-overhead assumption (for example 15 minutes per session) and the storage cost. State every assumption.
   - **Q6 (helper vs documentation):** pre-registered rule, using the per-session records from §2.4 step 8 over at least 5 fresh sessions: a helper is justified if the median time to ready a fresh session exceeds **15 minutes**, or the median number of manual interventions exceeds **2**, or any session had a setup error that would have broken isolation (wrong save root, Desktop entry exposed). Otherwise documentation is sufficient.

   **Q4 control matrix (to fill in):**

   | Control | What Sunshine/Moonlight provides (to verify) | Manual procedure used in this experiment | Gap for invited tests | Follow-up? |
   |---------|----------------------------------------------|------------------------------------------|----------------------|-----------|
   | Invitation | PIN pairing per client | In-person/trusted-channel PIN by a core member | No self-service, no per-invite identity | Only if invited tests go ahead |
   | Revocation / expiry | Unpair in admin UI; no expiry expected | Unpair after each tester's window | No automatic expiry | Same |
   | Isolated saves | None | Wrapper session directory (G2) | Depends on G2 result | Game-side if G2 fails |
   | Queue | None expected | One session at a time, scheduled by chat | No queue | Only if demand exceeds one host |
   | Concurrent players | One stream per host expected | Not supported | Needs one host/VM, display and encoder per player | Infra, not engine |
   | Session stop | Undo command | Undo + watchdog (§2.4) | Depends on Phase 1 result | CLI if no clean stop |

   **Licensing:** record the licences of Sunshine, Moonlight and the audio driver, the host OS versions Sunshine supports, and any paid driver or codec. This is required before packaging or redistributing any integration.
4. Narrow follow-up issues, only for failures that were actually observed (§2.10).

### 2.10 Follow-ups that may be needed (not proposed now)

These are listed only so the right repo and layer are clear in advance. File each one only if the experiment shows the problem:

- **Session-end pause/quit seam.** The engine has `setPaused` and `quit()` but no external trigger. If the undo command and the watchdog do not stop an abandoned game within 5 minutes through a save-safe path, a separate RFC would cover an engine or generated-main hook: graceful quit on SIGTERM (in the CLI-filled lifecycle block), or pause on focus loss.
- **CLI stop or `playtest` helper.** `labelle stop`, or a `labelle playtest` helper that writes the Sunshine app entry, mints session directories and passes signals on. This lives in the CLI repo, and is filed only if the Q6 rule (§2.9) says so.
- **Game-side save root.** If gate G2 fails, make a Flying Platform change so it honours `LABELLE_DATA_DIR`. This would be a game-repo issue.
- **Input mapping fixes.** Fix these in the backend if coordinates are off under HiDPI or scaled capture. Fix them in the engine `input_mixin` only if the engine itself converts the coordinates.
- **macOS CI.** If a failure turns out to be a macOS engine/backend bug, file a narrow bug plus a request for a macOS compile/test job (CI is Linux-only today).

---

## 3. Alternatives considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keep distributing builds** (perhaps with obfuscated or encrypted assets) | No hosting, native latency | Does not address extraction; obfuscation only slows it down | Baseline to compare against |
| **Sunshine + Moonlight** (this RFC) | Free and open source, low latency on a LAN, no engine work, an Android client exists | Testers must install a client (and a VPN client for the WAN design); macOS host support is less mature than Windows/Linux; shared-desktop risk | **Evaluate first** |
| **Parsec / Steam Remote Play / commercial cloud gaming** | Polished clients; some offer browser access | Licensing and cost, account requirements, less control; Steam needs a Steam distribution | Compare on paper only, unless Sunshine fails |
| **WebRTC / browser streaming** (e.g. self-hosted Selkies- or Neko-style stacks) | No client install | A separate stack to evaluate. Sunshine does **not** provide a browser client. Higher latency | Out of scope; evaluate separately if the Q3 survey shows an installed client is unacceptable |
| **New engine streaming backend** (encode frames in the engine, e.g. by extending the preview SHM/IOSurface capture) | Precise control of input and capture | Large effort. The issue says the first experiment should not need a new streaming backend or preview-protocol changes, and this RFC chooses not to couple streaming to PIE | Rejected for this phase |
| **Web (WASM) build for testers** | Browser only | Ships the code and assets to the client, which defeats the goal | Rejected for the anti-extraction goal |

---

## 4. Acceptance criteria (for the experiment, not for merging this RFC)

The evaluation is complete when every item below has a recorded result with evidence. Pass and fail are both acceptable outcomes, as long as they are evidenced.

### 4.1 Setup and launch
- [ ] The versions table in §2.2 is complete, including Sunshine, Moonlight, encoder settings, client refresh rate and Moonlight fps.
- [ ] Gates G1–G5 are recorded, including the G2 save-root probe result, the chosen mechanism and the game's save timing.
- [ ] Admin installation, per-user TCC grants (with the account each was made in), pairing, the wrapper scripts and the Sunshine app entry are documented as reproducible steps, noting which steps needed admin.
- [ ] Launch through the Labelle CLI (`labelle run`) is tested. Both stop paths from §2.4 step 6 are tested, with PID tree, signalled process, exit codes, orphans and resulting saves recorded.
- [ ] Launch, video, audio, window focus, the fullscreen toggle (`setFullscreen` path) and resolution changes are verified.

### 4.2 Desktop input
- [ ] ImGui buttons, **hover highlight/tooltips**, mouse position accuracy, click, **double-click**, **right-click/context menu**, drag (including the **drag threshold**: a small movement still registers as a click), scroll (`getMouseWheelMove`), camera movement and keyboard input are verified.
- [ ] Cursor behaviour is recorded, including any game-drawn cursor (`setCursorVisible`).
- [ ] Secure Input behaviour is recorded (whether injected keystrokes stop after a system password prompt).

### 4.3 Tablet input
- [ ] In each available Moonlight touch mode: tap, **double-tap**, long-press, **how right-click is produced** (and whether it opens ImGui context menus), **whether hover can be produced** (tooltips, hover highlight), drag and the drag threshold, and two-finger scroll are documented.
- [ ] The result explicitly says whether native multitouch reaches the engine's `Touch`/`Gestures` path. It is expected not to; the result must confirm or refute this.
- [ ] Controller support is checked separately, if relevant.

### 4.4 Quality, resources, robustness
- [ ] Local vs streamed latency for all three §2.6 conditions (≥ 100 trials each): median, p95 and max with CIs, the paired added-latency p95, and the camera frame interval; subjective ratings; host frame-time p95 from raw frame times (or a stated reason none is available); dropped frames; audio offset; a stability session of at least 30 minutes.
- [ ] Minimum viable readability matrix complete (18 cells, pass/fail per cell), each client capture paired with a host reference frame and its settings; extended matrix done or explicitly skipped.
- [ ] Host CPU/GPU/encoder/memory/bandwidth measured streamed vs not streamed, idle and busy, on a fixed camera path, with the tool, units, sampling account and mechanism (SSH or launchd) named.
- [ ] Disconnect/reconnect and stuck-key release tested; the three pause actions in §2.8 recorded with expected vs actual behaviour and the decision rule applied; save preservation on both stop paths; abandoned-session stop tested in Phase 1.
- [ ] Internet test done by the core team only, with UPnP off, no public listeners (scan evidence), the tunnel topology (direct/relayed), both ends' lines and capacities, and the connection requirements documented.
- [ ] Escape and exposure walk done, including visual and audio exposure, shell, browser, local admin UI, clipboard, file transfer, egress and copying the bundle off the host; the admin UI decision recorded; isolation requirements for non-core testers written down.
- [ ] Upstream licences, supported host OS versions, and optional driver requirements and costs recorded.

### 4.5 Outcome
- [ ] All six questions are answered using the §2.9 criteria. Q3 may be answered "insufficient evidence" if the survey drew fewer than 3 responses; Q2's Linux/Windows part is labelled paper-only.
- [ ] The decision table in §7.3 has been applied and its result recorded.
- [ ] Every settings-log entry is restored. Anything intentionally left installed is documented.
- [ ] Follow-ups are filed only for observed failures, each tagged with its layer (§2.5).

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Saves go to the real directory because the game bypasses `LABELLE_DATA_DIR` (injected store, `native_directory` or direct `Files.init`) | Medium (unknown until G2) | Medium | Gate G2 probe before Phase 2; fallbacks in §2.2, with `HOME` scoped to the game process; a game-side follow-up if needed |
| Signal-based stop bypasses the game's quit path and loses unsaved progress | High | Low (expected) – High (if completed saves corrupt) | Separate graceful and signal paths (§2.4 step 6); judge save preservation on completed saves; signal the game PID directly |
| A tester escapes to the desktop, a shell, a browser or files, or copies the bundle off the host | High on a shared desktop | High | Core team only before Phase 5; Desktop app entry removed; escape walk; a standard user is *not* a boundary, so non-core testers need a dedicated host/VM with egress filtering and no credentials |
| A tester **sees or hears** developer data without escaping (notifications, menu bar, other windows, other apps' audio) | Medium | Medium | Do Not Disturb, no other apps, Dock/menu bar hidden, fullscreen; covered in the exposure walk |
| System-audio capture picks up notifications or other apps, contaminating audio-sync measurements | Medium | Low–Medium | Same mitigations; 5-minute idle listen before audio measurements |
| Local admin UI reachable by an escaped tester on `localhost` | Medium | High | Admin UI decision in §2.8 |
| Admin UI or stream ports exposed to the internet | Medium | High | Admin UI on localhost; UPnP disabled; listener check before Phase 4; VPN overlay; external port scan |
| Capture stops because the playtest session sleeps, locks or is switched away from (including by the admin) | Medium | Medium | Settings log disables sleep and lock; admin works only over SSH or a pre-installed launchd sampler during sessions |
| TCC grants made in the wrong account, so capture or input silently fails | Medium | Medium | Grants made in the playtest user's session; capture/input checked there before pairing (§2.4 step 3) |
| macOS Secure Input (password prompts, some secure text fields) blocks injected keystrokes | Low–Medium | Medium | Tested in Phase 2; no password prompts should appear in a game-only session |
| macOS host support is weaker (third-party audio driver, fragile TCC permissions, admin needed) | Medium | Medium | Separate admin install step; record the driver and permissions; treat the Mac as a prototype only; Q2 paper comparison |
| The Mac is outside the engine's tested matrix (CI runs tests on Linux only) | Medium | Medium | Reproduce any suspected engine/backend failure locally without streaming before blaming the stream; macOS CI follow-up if needed |
| The undo command does not fire on an abrupt client drop | Medium | Low–Medium | Tested in Phase 1; host-side watchdog as a fallback |
| `labelle run` does not pass SIGTERM on to the game, leaving an orphan | Medium | Low–Medium | Record the PID tree; signal the game PID directly; a CLI follow-up if needed |
| Touch maps to mouse in ways the UI does not expect (no hover, awkward right-click, drag threshold) | Medium | Medium | Explicit hover/right-click/double-click/drag-threshold checks in both touch modes (§4.3) |
| Pixel art and small text degraded by compression and scaling | Medium | Medium | Host reference frames; pre-registered minimum profile; integer scaling and chroma in the matrix |
| Measurements confounded by the input or display device, by an unfixed camera path, or too few trials | Medium | Medium | Third latency condition (tablet + BT mouse); paired per-trial differences; ≥ 100 trials with CIs; fixed camera path; fixed frame caps |
| WAN result biased by a relayed or unrepresentative path | Medium | Medium | Record direct vs relayed, both lines and capacities; state whether the result is an upper bound |
| Survey responses are few or unrepresentative | Medium | Medium | Minimum of 3 responses, else "insufficient evidence"; state the limit |
| The measurement matrix overruns the time available | High | Medium | Minimum viable matrix and priority order (§2); extended matrix optional |
| Results do not generalise (one Mac, one tablet, one network) | High | Medium | State this limit; the cost estimate names its assumptions |
| Scope creep into a streaming backend or cloud service | Medium | Medium | §2.10 lists follow-ups only; anything larger needs a new RFC |

---

## 6. Security notes

- Streaming reduces the risk of binary and asset extraction through the normal tester path. It does not prevent screen recording, imitation, extraction after a host compromise, or extraction from builds distributed some other way.
- A paired Moonlight client gets real OS input on the host. A standard macOS user limits access but is not an isolation boundary.
- No one outside the core team operates the stream until Phase 5 is complete, and then only on a dedicated host or VM with all of the following:
  - no developer credentials;
  - a game-only, notification-free session;
  - egress filtered to the stream/VPN path;
  - a game-only app entry, with no reachable shell, browser or file transfer;
  - the admin UI not reachable from the playtest session;
  - per-session saves verified by gate G2;
  - a session stop verified in Phase 1.
- Sunshine is not expected to provide invitations, session expiry, queues or concurrent players for this use case (question 4; to be verified and recorded in the §2.9 control matrix). Each concurrent player needs a separate game instance and, in practice, a separate host or VM, display and encoder. Building any of this is not part of this phase.

---

## 7. Validation plan

### 7.1 Existing evidence (already available)
- The source review in §1.2, with file and line references: the generated-main `lifecycle` placeholder, `quit()` only flipping `running` and no signal handler in this repo, environment knobs and who sets them (including the host screenshot variables), the storage precedence that limits `LABELLE_DATA_DIR` and the `HOME` dependency of the macOS default, desktop input forwarding, fullscreen request and read-back, cursor controls, the 120-frame `frameStats()` window with no percentiles, the lack of any focus-loss or disconnect pause seam, and Linux-only CI.
- No streaming experiment has been run, and no survey has been sent. There are no measurements, screenshots, version records or verified Sunshine behaviours yet. Upstream behaviours are design assumptions until observed: the undo command on an abrupt drop, macOS install and per-user TCC requirements, Secure Input, the admin UI's configurability, the available touch modes, and the absence of invitation/expiry/queue features.
- No builds or tests were run to write this RFC; it is a design-only document.

### 7.2 Proposed validation (done by the experiment)
1. **Survey and gates:** the Phase 0 survey; G1–G5, including the save-root probe and the abrupt-drop undo test.
2. **Functional:** checklists §4.1 to §4.3 on the LAN, recording pass, fail or degraded with evidence.
3. **Quantitative:** the Phase 3 methods, local and streamed, on the same scenes, revision, camera path and frame caps. Keep the raw numbers (latency trials, frame-time CSVs, powermetrics/ps/nettop logs) and name each tool.
4. **WAN:** the Phase 4 subset on a team-controlled connection, after the pre-exposure checks, with an external port scan and the path characterised.
5. **Robustness, pause, stop and escape:** the Phase 5 scenarios and the §2.4 stop paths, with the outcome of each recorded.
6. **Teardown:** check every settings-log entry is restored and that no listeners, launchd jobs or pairings remain.
7. **Engine regression:** none needed, because Phases 0 to 4 change no engine code. The temporary frame-time hook (if any) lives only in the game working copy. If a follow-up changes the engine, it must add tests under `test/` following the repo's module and test pairing.

### 7.3 Go/no-go decision table (pre-registered before any measurement)

**Hard fail: one of these alone means NO-GO.**
- Any stuck key or button on the host after a disconnect that is not released within 2 s of reconnect or session stop.
- Any loss or corruption of a **completed save** (§2.4 step 6) on either stop path, or any save written outside the session directory. (Loss of unsaved progress on the signal path is recorded but is not a hard fail.)
- The admin UI or stream ports reachable from the public internet at any point.
- A crash or hang of the game or Sunshine during the 30-minute session.
- An abandoned session left running more than 5 minutes after the client dropped, with the undo command and watchdog in place.
- The game bundle copied off the host from the game-only app *and* no documented dedicated-host configuration that blocks it.

**Thresholds for GO (all must hold):**

| Criterion | Threshold |
|-----------|-----------|
| §4.1, §4.2 items | All pass with no code change (config/script changes allowed) |
| Tablet core interactions (tap a button, drag an item, pan the camera, scroll, open a context menu if the game uses one) | Pass in at least one Moonlight touch mode |
| LAN added latency (S-mouse minus L, paired per trial) | p95 ≤ 50 ms, with the upper 95 % CI bound ≤ 60 ms |
| WAN latency (S-mouse) | p95 ≤ 150 ms input-to-photon, with the upper CI bound ≤ 170 ms |
| Dropped frames (Moonlight overlay, 30-min session) | ≤ 1 % on LAN, ≤ 3 % on WAN |
| Audio offset | Median within ±80 ms, max within ±120 ms |
| Readability | At the pre-registered minimum profile (§2.6), the smallest UI text is legible to both raters on the tablet at the recorded viewing distance, in all three scenes |
| WAN readability | The link sustains the minimum profile's bitrate with loss < 1 %; if not, GO WITH CONDITIONS at the highest sustained profile that still passes readability, or NO-GO if none passes |
| Pause | §2.8 decision rule met (stopped within 5 min with completed saves intact) |
| Subjective responsiveness | Median rating ≥ 3 from at least two raters, LAN and WAN |
| Stability | 30-minute session with ≤ 1 disconnect, which recovers by reconnecting |

**GO WITH CONDITIONS:** no hard fail, every threshold met, but one or more items meet it only with a named mitigation. Examples: only one touch mode works, a BT mouse is required, the WAN is acceptable only at a lower profile, or non-core testers need the dedicated host. The conditions are listed and must hold for every playtest.

**NO-GO:** any hard fail, or any threshold missed. The blocking items are listed by layer, with the follow-ups that would remove them.

**Who judges:** two core-team raters, named in the findings, score the subjective items independently. If they disagree on a pass or fail, the stricter result is used. Numeric thresholds are measured, not judged. Any threshold change has to be made and recorded *before* Phase 3 starts.
