# RFC 918: Evaluate Sunshine/Moonlight streaming for private Labelle playtests

**Status:** Draft (design only; no experiment has been run yet)
**Author:** Moca Pipeline (card 6), for the labelle-engine maintainers
**Date:** 2026-11-13
**Issue:** labelle-toolkit/labelle-engine#918
**Scope of this document:** how to run the feasibility experiment, what it must measure, and how its results lead to a go/no-go decision and follow-up work. This RFC does **not** propose engine code changes. It describes the engine seams the experiment depends on, so that any follow-up lands in the right layer.

**Location.** Existing engine RFCs live at the repository root (`RFC-*.md`, e.g. `RFC-CONSTANTS.md`) and in `rfc/`. This one is in `docs/rfcs/` because the pipeline that produced it requires that path and permits only this one file to change. It follows the root RFCs' header fields (Status/Author/Date). If maintainers prefer, it can be moved to `RFC-PLAYTEST-STREAMING.md` when it is accepted. A `docs/rfcs/README.md` index is out of scope for this change; on acceptance, one of the two is filed as a follow-up (move the file, or add the index), so `docs/rfcs/` does not stay a single unindexed document (§2.10).

**What merging this RFC means.** Merging it accepts the *experiment protocol* only. It does **not** complete #918. The issue's completion criteria need a published setup guide and findings: tested versions, measurements, visual evidence, known failures and a go/no-go recommendation. #918 stays open until the experiment has run and those findings are appended to this RFC or linked from it. When they are, this RFC's status changes from *Draft* to *Accepted, protocol* and then to *Concluded* (with the go/no-go result).

---

## 1. Problem and context

### 1.1 Problem

Today, prerelease playtesting means sending testers a game package: the binary and its assets. Anyone who receives the package can extract the assets and reverse-engineer or repackage the binary. Issue #918 asks whether **Sunshine** (host capture, encoding and input injection) plus **Moonlight** (an installed client) is a practical way to run *invite-only* remote playtests in which the tester never receives the package. The first target is **Flying Platform**. It will be hosted on the existing **Mac** and played on the existing **Android tablet**.

This is a feasibility investigation, not a plan for a cloud-gaming service. The intended result is a reproducible setup guide, measurements and a go/no-go decision. Follow-up issues should be filed only where the experiment shows a need for them.

### 1.2 What the code shows today (existing evidence)

All findings in this section come from reading this checkout: PR #932 base commit `6aa8d3a` (`6aa8d3ae732b3d137bd15a35ac4db64537a213b2`). Line numbers refer to that commit and must be re-checked after any rebase. None of them has been run or tested.

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
| OS test coverage | CI runs on `ubuntu-latest` and `windows-latest` (`.github/workflows/ci.yml:17`). On **both**, it builds the library and runs the settings and animation tests (`:46-64`). The full `zig build test` runs on Linux only (`:73-89`); Windows instead compiles and runs the preview tests (`:91-118`). There is **no macOS job**; the comment at `:73-74` calls it out of scope. | The Mac host is outside the engine's tested matrix. A macOS-specific failure in the experiment may be an engine/backend bug, not a streaming one (§5). For Q2, Linux has full-suite coverage, Windows has partial coverage, and macOS has none. |

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

The design is an experiment protocol in phases. Each phase has entry gates and records evidence. **Phases 0 to 4 use unchanged engine, assembler and CLI code.** Wrapper scripts, Sunshine configuration and, at most, a game-side debug log of frame times (§2.6) are allowed. Any CLI or engine addition is a follow-up (§2.10). A **gameplay or save-path change to Flying Platform** (G2 fallback 3) is *not* allowed inside the unchanged-runtime experiment: if it is needed, the experiment records Q1 = "no (game-side save root)", files the follow-up, and resumes Phase 2 only on a rebuilt game revision that is recorded in the versions table.

**Participants.** A *core-team member* is someone who already has repository access to Flying Platform and could already obtain the package. Only core-team members operate the stream through Phase 5. *Prospective invited testers* answer the Phase 0 survey (§2.2); the only non-core tester who connects does so in the supervised Phase 5b session (§2.8b), on the dedicated host. Every participant, their device and their connection are recorded in the findings.

**Effort and priority.** The full matrix is large: 3 scenes × 3 resolutions × 3 bitrates × 2 codecs × 2 chroma is 108 cells before latency, audio and stability. §2.6 defines a **minimum viable matrix** (MVM) that must be completed and an extended matrix that runs only if time allows. Rough effort, to be checked against actual times in the findings: Phase 0 half a day; Phase 1 one day; Phase 2 half a day; Phase 3 MVM two days; Phase 4 one day; Phase 5 half a day; Phase 5b one to two days (host build and lock-down, plus one supervised session); Phase 6 half a day. Priority order if time runs out: G1–G5 gates → functional checklist → stop/save/abandon tests → latency → MVM readability → audio sync → 30-minute stability session → host load → escape and exposure walk (Phase 5) → WAN → Phase 5b (non-core host) → extended matrix. Only the extended matrix is optional. **Any GO threshold or hard-fail check that was not measured is recorded as "insufficient evidence", and the decision for the scope it covers is NO-GO** (§7.3).

### 2.1 Topology

```text
Mac host
  admin account        : installs software, approves admin prompts; reached over SSH during sessions
  "labelle-playtest"   : standard (non-admin) user, the ACTIVE CONSOLE session, runs Sunshine + game
    └─ start-session.sh (Sunshine app "do" command)
         - refuses to start if sessions/current points at a live session (see "Session handoff")
         - mints <session-id>, creates /Users/labelle-playtest/sessions/<session-id>
         - writes sessions/current (atomic rename) = <session-id>
         - sets LABELLE_DATA_DIR=<that dir>  [only effective if gate G2 passes]
                LABELLE_SCENE=<scene>        [only effective if gate G3 passes]
         - starts labelle run … (or the built binary) as a CHILD (no exec),
           records wrapper PID, CLI PID and game PID to sessions/<id>/pids
         - waits for the child, then runs post-exit steps (copy-back if G2 fallback 2)
    └─ stop-session.sh (Sunshine app "undo" command, no arguments): reads sessions/current, see §2.4 step 6
    └─ watchdog (only if needed, §2.4 step 7)
    └─ Sunshine: display + audio capture + input injection
         app entry = "Flying Platform" only; "Desktop" entry removed
         web admin UI bound to localhost; UPnP/NAT-PMP disabled
        │  LAN first (Phases 1–3); then a team-controlled WAN path via VPN overlay (Phase 4)
        ▼
Android tablet: Moonlight (paired by PIN); touch mode recorded; optional BT mouse/keyboard/controller
```

**Session handoff (how `stop-session.sh` finds the session).** Sunshine runs the undo command without a session ID, so the ID is passed through a file, not an argument or environment variable:
- `start-session.sh` writes `sessions/<id>/pids` first (wrapper, CLI and game PIDs, plus each PID's start time from `ps -o lstart`), then writes `sessions/current` containing `<id>`, by writing `sessions/current.tmp` and renaming it. Both files are owned by `labelle-playtest` with mode `0600`.
- `stop-session.sh` takes no arguments. It reads `sessions/current`; if the file is missing, it logs "no session" and exits 0. Otherwise it reads `sessions/<id>/pids`, and treats a PID as **live** only if a process with that PID exists *and* its start time matches the recorded one (this guards against PID reuse). It signals only live PIDs (§2.4 step 6b), runs the idempotent copy-back, and finally removes `sessions/current` only if it still contains `<id>`. A manual call can pass `--session <id>` to stop a specific session.
- **Stale pointer.** If `sessions/current` names a session with no live PIDs (wrapper killed, host rebooted), `start-session.sh` runs `stop-session.sh` first (copy-back, then pointer removal), logs the stale ID, and continues. If the pointer names a session with live PIDs, `start-session.sh` exits non-zero and Sunshine reports the launch as failed: there is **one session per host**, and concurrent sessions are unsupported in this experiment (Q4).
- The watchdog (§2.4 step 7) calls `stop-session.sh` the same way, with no arguments.
- Both scripts append to `sessions/<id>/log` with timestamps; the handoff is tested in §4.1 (normal stop, stale pointer, second launch while one is live).

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

The survey is evidence about *willingness and device mix*. It does not test Moonlight on their devices. If fewer than 3 responses come back, Q3 is answered as "insufficient evidence"; with 3–4 it is "indicative only" (§2.9, Q3). Browser-only access stays out of scope (§3).

**Gates.** These are verified by reading the game's source and doing one local run. A gate that fails blocks the phase that depends on it, until its fallback is in place.

- **G1 (backend):** record the backend and renderer, whether the game draws its own cursor, and the host display's **scale factor** (Retina/scaled resolution as set in System Settings) together with the game's framebuffer size versus window size.
- **G2 (save root):** find Flying Platform's storage initialisation. Record which branch it takes: injected store, `native_directory`, `storage.Default` defaults, or `storage.Files.init` directly. Also record **when** the game writes saves (autosave interval, explicit save action, on quit) and **how**: whether it writes through `storage.Files` (temp file under `.pending`, flushed, then atomically renamed over the destination; the directory is not fsynced, `docs/persistent-blobs.md:70-75`) or through its own writer. If it uses its own writer, record whether that writer is atomic. **Probe:** run locally with `LABELLE_DATA_DIR=/tmp/lp-probe-<n>`, trigger a save, and confirm that the save file appears under `/tmp/lp-probe-<n>/saves/` and not under `~/Library/Application Support/<app_id>`. If the probe fails, use a fallback in this order:
  1. **Per-session `HOME` for the game process only**, if the game's path derives from `HOME` (on macOS, `storage.Default` takes the base from `HOME`, `data_root.zig:77`). The wrapper sets `HOME` only in the environment of the *game* process, not of `labelle run`, so the CLI's own config and cache are unaffected. If the game can only be started through `labelle run` and the CLI passes its environment down, first check that `labelle run` works with the per-session `HOME` (it can find its toolchain/cache) and record the result; otherwise use fallback 2.
  2. **Copy-on-start:** the wrapper copies a clean save directory into the game's fixed location before launch and moves it to `sessions/<id>/` after the game exits, with only one session at a time. This requires the wrapper to stay alive as the game's parent (no `exec`, §2.1). The copy-back is idempotent (it is keyed by session ID and skips if `sessions/<id>/saves` already exists) and is also run by `stop-session.sh` and by Phase 6 teardown, so a killed wrapper does not lose the save.
  3. A narrowly scoped game-side change, filed as a follow-up. This **ends the unchanged-runtime experiment** for saves (§2, Q1 = "no"); Phase 2 resumes only on the rebuilt, recorded game revision.

  The chosen mechanism is recorded. Phase 2 does not start until a save is shown to be **captured into** `sessions/<id>/`: written there directly (probe or fallback 1), or copied there after exit (fallback 2). With fallback 2, the save is written to the game's fixed location during play; that is expected and is not a failure, as long as the copy-back captures it and nothing else is in that location (§7.3).

  **Save atomicity probe (part of G2).** Start a save and send SIGKILL to the game PID while it is writing, 10 times, at different moments (if the save is too fast to hit, repeat in a loop of save actions and kill at random intervals). After each kill, check that the previous completed save still loads and that no partial file is listed. If the game uses `storage.Files`, this confirms the temp-and-rename behaviour; power-loss safety is not tested and is stated as an untested limit (the directory is not fsynced). If the game uses a non-atomic writer and a kill corrupts a save, record it as a game-side defect; it counts against the save hard fail only if it happens on stop path (a) or (b) during the experiment.
- **G3 (scene selection):** confirm that the loading controller calls `requestedScene()` and record the scene names it accepts. If it does not, scenes are reached manually in game and the findings say so.
- **G4 (stop paths):** see §2.4, step 6.
- **G5 (frame-time capture):** decide how raw frame times are collected (§2.6). Record whether it uses an existing debug feature or a temporary game-side hook.

**Host settings freeze, then local baseline.** Start the host settings log (§2.3) before anything is changed. Then, *before* measuring anything, set and freeze the settings that affect measurement: display resolution, scale factor and refresh rate; default audio output device (the loopback/multi-output device that Phase 1 will use, if it is already known; otherwise the baseline is re-measured after Phase 1); game vsync/frame cap; energy and sleep settings. Then measure the local baseline on the same scenes later used for streaming (moving clouds, a busy colony scene, a small-text UI panel), with the methods of §2.6. **Phase 3 starts by comparing the current host settings with the frozen set.** If any differ (for example, Sunshine or the audio driver changed the display mode or output device), the local baseline is re-measured under the Phase 3 settings, and only that re-measured baseline is used for comparisons. The findings state that baseline and Phase 3 used identical host settings, and list them.

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
   - **(b) Signal-based abandonment, for cleanup.** `stop-session.sh` resolves `<id>` from `sessions/current` (§2.1, "Session handoff"), reads `sessions/<id>/pids`, sends SIGTERM to the **game PID**, waits N seconds (start with N = 10), then SIGKILL; it then signals the `labelle run` PID if it is still alive, and runs the idempotent copy-back if G2 fallback 2 is used. The manual equivalent is Ctrl-C/SIGINT to a foreground `labelle run`.

   For each path record: the PID tree before the stop (`ps -o pid,ppid,command -U labelle-playtest`), whether `labelle run` is a parent of the game or execs it, which process received the signal, exit codes, whether the game exited, whether any process was orphaned, and which saves exist afterwards. If neither path leaves a clean process table, record a launch-tooling failure. A CLI stop command would be a follow-up, not part of this experiment.

   **What "save preservation" means.** *Completed saves* are files the game wrote before the stop: by explicit save, by autosave, or (on path a) by its quit handler. *Unsaved progress* is play state since the last write. The criterion (§7.3) is: completed saves are never lost or corrupted on either path, and path (a) preserves whatever the game's own design says it saves on quit. Losing unsaved progress on path (b) is the **expected** result and is recorded, not failed. If the game does not save on quit, path (a) is recorded as "no save-on-quit" and is judged on completed saves only.
7. **Abandoned-session test.** Pair the tablet over the LAN, start the app, then kill Moonlight abruptly (force-stop, or turn Wi-Fi off). Record whether Sunshine runs the undo command, how long that takes, and whether the game exits. The Sunshine version's documentation is cited in the findings, and the behaviour is treated as an assumption until this test is observed. If the undo command does not run on an abrupt drop, add a host-side watchdog: a script, running as `labelle-playtest`, that calls `stop-session.sh` when no Sunshine client has been connected for T minutes (start with T = 3), based on Sunshine's log or API. Retest.
8. **Invitations and setup cost.** A static Sunshine app entry cannot mint a session ID, so the wrapper creates it (timestamp plus random suffix). Retention: session directories are kept until the findings are written and then deleted in Phase 6. An invitation is a PIN pairing done in person or over a trusted channel by a core-team member. Revocation means unpairing the client in the Sunshine admin UI. For every session from here on, record the wall-clock time to get a fresh session ready and the number of manual interventions (any step outside "start app in Moonlight"), to answer question 6 (§2.9). A "fresh session" is a launch from a stopped game with no `sessions/current`. Phases 2–5 are expected to produce well over 5 such launches; if they do not, the operator runs extra fresh launches (start, reach the first scene, graceful stop) until there are 5, and labels them as such.

### 2.5 Phase 2: Functional compatibility (LAN, unchanged runtime)

Run the checklists in §4.1 to §4.3. Record each item as pass, fail or degraded, with evidence (screenshot, clip or note). For tablet input, record Moonlight's touch mode and test both the **touchscreen** (direct) and **trackpad** (relative) modes if this Moonlight version offers them. Also check macOS **Secure Input**: if a system password field appears (for example an admin prompt), record whether injected keystrokes stop working, during the prompt and after it closes. Classify every failure by layer:

- **Backend/window** (generated main, backend): focus, fullscreen, resolution, HiDPI scale, cursor.
- **Input layer** (engine `input_mixin` or backend input): coordinate mapping, wheel, drag, hover, right-click, stuck keys.
- **Launch tooling** (CLI, wrapper scripts or Sunshine app entry): start, stop, environment variables, save root.
- **Host/stream config** (Sunshine/Moonlight settings): bitrate, codec, scaling. These need no code.

### 2.6 Phase 3: Quality and resource measurement (LAN)

**Fixed conditions.** Write down the host refresh rate, game vsync/frame cap, Sunshine frame limit, Moonlight fps and client display refresh rate. Use a fixed, repeatable camera path, either scripted input or a scripted pan-and-zoom route repeated by hand along the same route and timed. Mark a start timestamp for each run so that host samples (powermetrics, `ps`, `nettop`, frame times) can be aligned to the camera path afterwards. Save the exact Sunshine and Moonlight settings next to every screenshot and clip.

- **Latency.**
  - Conditions: *L* local baseline (Mac display, mouse click); *S-touch* streamed (tablet display, tap); *S-mouse* streamed (tablet display, mouse click). *S-touch* records what testers actually feel.
  - **Same input device on both ends.** *L* and *S-mouse* use **the same mouse unit over the same connection class**: one Bluetooth mouse, paired to the Mac for *L* and to the tablet for *S-mouse* (or, if the tablet accepts it, one wired USB mouse via USB-C OTG on the tablet and directly on the Mac). Record model, connection type and polling rate for each end. Even then, the host's and the tablet's Bluetooth/USB stacks differ, so the difference *S-mouse* − *L* is **stream plus client-device latency**, not stream alone. To bound the client-device part, measure a **client-local** condition *C* (tablet display, same mouse, a local Android app that changes colour on click, e.g. a simple input-test app; ~30 trials). Report *C* next to the results; if *C* exceeds the Mac's own local mouse-to-photon time by more than one camera frame, the findings state that the client device, not the stream, accounts for that part.
  - **Display difference.** The Mac panel and the tablet panel differ in refresh rate and response time. Record both refresh rates (and VRR/ProMotion state). The GO threshold is applied to *S-mouse* − *L* as measured, which deliberately includes the tablet panel, because that is what a tester sees; the findings report the panel refresh interval next to the result so a reader can see how much of the budget it can account for.
  - Film each condition with the same high-speed phone camera (target 240 fps; record the actual fps), framing the input action and the screen together. Count frames from input to the first visible response. **Measurement resolution** is one camera frame (≈ 4.2 ms at 240 fps); report it with every number.
  - **≥ 100 trials per condition**, interleaved in blocks of 10 (L, S-mouse, S-touch, repeat) on the same scene so that drift affects all conditions equally.
  - Report per condition: median, p95 and max, each with a 95 % bootstrap confidence interval. For the GO threshold, compute the **added latency** as the per-trial difference between *S-mouse* trial *i* and *L* trial *i* within the same block (paired by scene and block position), and report the p95 of that difference with its CI. Also show the two distributions side by side (histogram or ECDF).
  - Record the network, decode and render times from Moonlight's performance overlay for each block.
- **Subjective responsiveness.** At least two core-team members play a fixed 5-minute task (place and move items, pan the camera, use a menu) locally and then streamed. They rate each run on a 1–5 scale (1 = unplayable, 3 = noticeable but fine for playtesting, 5 = indistinguishable). Raters and scores are recorded.
- **Frame pacing.**
  - *Host:* `frameStats()` gives only min/avg/max over 120 frames, so it cannot produce a session p95 (§1.2). Collect **raw frame times** instead, by the method fixed in gate G5: (1) an existing game debug feature that writes per-frame dt to a file, if Flying Platform has one; otherwise (2) a temporary game-side debug script, in the Flying Platform working copy only and never committed to the engine, that every 120 frames calls `frameHistory()` into a 120-element buffer and appends it to a CSV with a timestamp. Window: from the first frame after the scene finishes loading (`assets.allReady`) to the end of the camera path; scene loads are excluded and reported separately. Compute p95 frame time and the count of frames over 1.5× the target offline, from the CSV. If neither method is possible, report min/avg/max from `frameStats()` screenshots every 30 s and state that no p95 is available. `LABELLE_PROFILE=1` is run separately for the per-script ranking, not during latency runs.
  - *Client:* record dropped frames and fps from the Moonlight overlay.
- **Audio sync.** Use an in-game action with both a sound and a visual cue (or a clap test on a debug scene, if one exists). Film the speaker and screen together (the Mac's speaker and screen locally, the tablet's streamed) and measure the audio-to-visual offset over ≥ 20 trials. Keep the **camera-to-speaker distance** the same in both conditions (target 0.5 m, recorded) and correct for sound propagation (≈ 2.9 ms per metre); with equal distances the correction cancels in the comparison but is still stated. Record the audio loopback driver's reported latency/buffer size (in the settings log) and Moonlight's audio settings. Report median and max with the camera frame interval.
- **Visual quality.**
  - **Reference frames.** For each scene and camera checkpoint, capture a host-side frame with `labelle run --screenshot=<path> --after=<sec>` (which sets `LABELLE_SCREENSHOT_PATH`/`LABELLE_SCREENSHOT_AFTER_SEC`, `src/screenshot_request.zig:5-8`). `--after` is wall-clock time from the first main-loop frame (`src/screenshot_request.zig:102-106`), so scene load time and animated content (moving clouds) make the captured game state vary. To align frames: (1) for **static checkpoints** (small-text panel, paused colony), pause the game (`setPaused`, or the game's pause key) at the checkpoint before capturing both the host reference and the client screenshot; (2) for **moving content** (clouds), record a host-side screen recording and the client video of the same run, and extract both frames at the same on-screen marker (for example the frame in which a chosen cloud crosses a fixed UI edge), not at the same wall-clock time. Pair every client screenshot with the host reference of the same checkpoint, so that compression and scaling loss can be separated from the game's own rendering.
  - **Viewing conditions.** Client screenshots are taken at the tablet's native resolution with Moonlight scaling recorded; legibility is judged on the tablet at a normal hand-held distance (≈ 40 cm, recorded), not only from screenshots on a monitor.
  - **Minimum profile (pre-registered).** The readability threshold (§7.3) is judged at a fixed profile: stream resolution 1080p (or the nearest integer multiple of the game's design resolution, if one exists at or below the tablet's native), 20 Mbps, H.264 4:2:0, client at 1:1 pixel mapping where Moonlight allows it.
  - **Readability rubric (pre-registered in Phase 0, before any streamed capture).** For each of the three scenes, Phase 0 records: the **named text targets** (the smallest HUD/ImGui label in that scene, given as its exact string, font and size, and its height in physical pixels in the host reference frame), the camera checkpoint, and one host reference image. Each rater then scores each cell as:
    - *Text legible* — pass if the rater reads **every** named text target correctly (exact string) on the tablet at the recorded distance without zooming; fail otherwise.
    - *Pixel art crisp* — pass if, compared side by side with the host reference, single-pixel outlines on the named sprite (one per scene, named in Phase 0) remain distinct and no colour bleeds across an outline by more than one source pixel; fail otherwise.
    - *No banding/macroblocking* — pass if no block edges or banding are visible in the named region (the cloud layer, the colony crowd) during the moving-content clip; fail otherwise.
    Phase 0 also stores one example **pass** and one example **fail** image per criterion (the fail example produced deliberately at a very low bitrate) so both raters calibrate on the same images. A cell passes only if both raters pass it (stricter result, §7.3).
  - **Minimum viable matrix (must complete).** 3 scenes (moving clouds, busy colony, small-text panel) × {tablet native, 1080p, 720p} × {10, 20 Mbps} × H.264 4:2:0 = 18 cells, each scored with the rubric above.
  - **Extended matrix (if time allows).** Add 40 Mbps, HEVC, 4:4:4 if the encoder supports it, and the integer-multiple resolution.
  - The bitrate the WAN link sustained (§2.7) is recorded **separately** and compared with the minimum profile; it does not move the threshold.
- **Host load.** Started and stopped by the admin **over SSH** (§2.1): `sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -o <file>`. Also collect, as `labelle-playtest` or over SSH, memory per process (`ps -o rss` for the game and Sunshine, every 10 s) and network bitrate (`nettop -P -L 0` on the host, plus the Moonlight overlay). If GPU encoder occupancy is not exposed, use an Instruments Metal System Trace capture or record "not measurable" with the tool you tried. Units: % CPU, mW, GPU active residency %, MB, Mbps. Compare the same scene streamed and not streamed, idle and busy, on the same camera path, aligned by the run start timestamps. Note that the SSH session itself adds a small load and is present in both conditions.
- **Stability.** Run one representative session of at least 30 minutes. Log disconnects, audio/video drift, crashes and stuck input. For any crash or hang, try to reproduce it **locally without streaming** on the same revision and scene, and record whether it reproduces; a locally reproducible game crash is filed as a game bug and the 30-minute session is rerun (§7.3).

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
  - Save preservation on both stop paths, as defined in §2.4 step 6: every completed save is captured into `sessions/<id>/` by the G2 mechanism (directly or by copy-back), and no other session's save or the playtest user's real save directory is modified.
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

**Scope of the Phase 5 result.** Phase 5 runs on the Mac, with core-team members only. On its own it supports a decision for **core-team sessions only**. It does not show that the non-core requirements above work. That is Phase 5b.

### 2.8b Phase 5b: Non-core host and supervised invited session (required for an invite-only verdict)

The issue asks for a go/no-go for invite-only playtests, in which the testers are not core-team members. That verdict needs a configuration that was actually run, so Phase 5b builds and tests the dedicated host the isolation statement requires.

- **Host.** A dedicated machine or VM that holds no developer credentials, SSH keys, tokens or browser profiles, and no source checkout. It holds only the built game and the wrapper scripts. Use the Mac in a separate, freshly created macOS user only if no other host is available, and label the result accordingly ("same hardware, not dedicated"). If the host is Linux or Windows, record it in the versions table as a second host column. Then repeat Phase 1 steps 1–8 and gate G2 there.
- **Session lock-down, as tested configuration.** Record exactly how each requirement is met:
  - game-only app entry, with no Desktop entry;
  - the game relaunched or the session stopped when the game exits, so the tester never sees a desktop (wrapper behaviour recorded);
  - shell and browser blocked (for example managed-profile/parental-control app restrictions on macOS, AppLocker/Assigned Access on Windows, or a kiosk-mode session on Linux);
  - egress filtered to the VPN/stream path only (host firewall rules, listed);
  - admin UI decision (a) or (b) from §2.8;
  - clipboard and file transfer disabled in Sunshine, if configurable.
- **Repeat the escape and exposure walk** (§2.8) on this host, first by a core-team member, and record every item.
- **Supervised non-core session.** Only if that walk finds no reachable shell, browser, file dialog that can browse outside the save directory, or egress path: one invited non-core tester, paired by PIN over a trusted channel, plays a 20–30 minute session over the WAN path (§2.7) while a core-team member watches the host-side logs over SSH. The tester is told in writing what is recorded. Afterwards, check the host for new files outside `sessions/<id>`, new listeners and outbound connection attempts (firewall log), and unpair the client.
- **If Phase 5b cannot be run** (no dedicated host is available, or no tester can be scheduled), the findings state that **the invite-only question is unanswered**, and the §7.3 decision covers core-team sessions only (§7.3, "Scope of the decision").

### 2.9 Phase 6: Teardown and deliverables

**Teardown:**
- restore every entry in the settings log (§2.3), including Remote Login, Do Not Disturb and any launchd job;
- run the idempotent save copy-back once more, if G2 fallback 2 was used;
- remove the pairings;
- revoke the TCC grants in the account each was granted in;
- uninstall or disable Sunshine and the audio driver;
- delete the session directories and `sessions/current`, and, if it is not kept, the playtest user;
- for the Phase 5b host: unpair, remove firewall rules and app restrictions if the host is not kept, or record that it is intentionally kept as the playtest host;
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
   - **Q2 (host suitability, paper):** compare the Mac with Linux and Windows hosts against named criteria: Sunshine's support tier for that OS, encoder available, audio capture mechanism (driver needed or not), headless/virtual display support, scriptable unattended setup, licence cost, one instance per VM possible, and the engine's CI coverage of that OS (today: Linux full suite; Windows library build, settings, animation and preview tests; macOS none; §1.2). The Mac verdict uses the measured Phase 1–5 results. The Linux/Windows verdict is a **paper** comparison and is labelled as such, except that if Phase 5b ran on Linux or Windows, that OS's verdict uses its measured Phase 5b results and is labelled "measured (Phase 5b)".
   - **Q3 (installed client):** two conditions, reported separately:
     - *Q3a, Moonlight:* the share of respondents who use a device Moonlight supports **and** would install Moonlight from an official store;
     - *Q3b, VPN:* the share who would also install the VPN client or accept a mesh-VPN invitation (only if the WAN design keeps a VPN).
     Rules, by number of responses *n*: with *n* < 3, "insufficient evidence"; with 3 ≤ *n* < 5, report the counts (for example "3 of 4") and label the result **indicative only**, with no acceptable/not-acceptable verdict; with *n* ≥ 5, Q3a is acceptable at ≥ 80 %. If Q3a passes and Q3b fails, the answer is "Moonlight acceptable, VPN not" (which points at a different WAN design, not a browser path). If Q3a fails, the answer is "not acceptable without a browser path", which would justify a separate browser-streaming evaluation. Phase 5b's tester adds one observed data point (did install and connect, time taken), reported next to the survey.
   - **Q4 (controls):** fill in the control matrix below.
   - **Q5 (cost, an estimate):** the price is for a **future Linux or Windows cloud host**, not the Mac prototype; the Mac's measured load is used only as a sizing hint, and the findings say so. Pick one concrete GPU-capable host offering and record its vCPU, RAM, GPU/encoder, region (prefer São Paulo), hourly price, and whether egress is **metered** and at what price. Convert bitrate to volume as GB per hour = Mbps × 3600 / 8 / 1000 = Mbps × 0.45 (for example 20 Mbps ≈ 9 GB/h). Compute the cost per active session-hour as instance-hours (one instance per player, plus an idle-overhead assumption, for example 15 minutes per session) × hourly price + GB/h × egress price + storage. Label the result an estimate and state every assumption, including that the cloud encoder's load was not measured unless Phase 5b ran on that host type.
   - **Q6 (helper vs documentation):** pre-registered rule, using the per-session records from §2.4 step 8 over at least 5 fresh sessions (topped up as described there; with fewer than 5, Q6 is "insufficient evidence" and the default is documentation only): a helper is justified if the median time to ready a fresh session exceeds **15 minutes**, or the median number of manual interventions exceeds **2**, or any session had a setup error that would have broken isolation (wrong save root, Desktop entry exposed). Otherwise documentation is sufficient.

   **Q4 control matrix (to fill in):**

   | Control | What Sunshine/Moonlight provides (to verify) | Manual procedure used in this experiment | Gap for invited tests | Follow-up? |
   |---------|----------------------------------------------|------------------------------------------|----------------------|-----------|
   | Invitation | PIN pairing per client | In-person/trusted-channel PIN by a core member | No self-service, no per-invite identity | Only if invited tests go ahead |
   | Revocation / expiry | Unpair in admin UI; no expiry expected | Unpair after each tester's window | No automatic expiry | Same |
   | Isolated saves | None | Wrapper session directory (G2) | Depends on G2 result | Game-side if G2 fails |
   | Queue | None expected | One session at a time, scheduled by chat | No queue | Only if demand exceeds one host |
   | Concurrent players | One stream per host expected | Not supported | Needs one host/VM, display and encoder per player | Infra, not engine |
   | Session stop | Undo command | Undo + watchdog (§2.4) | Depends on Phase 1 result | CLI if no clean stop |

   **Licensing:** record the licences of Sunshine, Moonlight and the audio driver as stated by each project for the tested version, the host OS versions Sunshine supports, and any paid driver or codec. Then write a short **assessment**, not just the table:
   - *Internal use* (this experiment, and running the unmodified upstream binaries for playtests): expected to need nothing beyond the licence terms of each project, because nothing is distributed. Sunshine and Moonlight are understood to be GPLv3 upstream; that is to be confirmed from the tested versions' licence files.
   - *Redistribution* (a helper that bundles, downloads-and-installs, or patches Sunshine/Moonlight, or ships a modified build): copyleft obligations apply to the distributed component (source availability for that component and its modifications, licence notices). A helper that only writes configuration and invokes an installed upstream binary is a different case from one that ships the binary; the assessment says which one a proposed helper would be.
   - *Audio driver:* its licence and whether redistribution is allowed (some loopback drivers are free for personal use only or are commercial).
   - The assessment is marked "not legal advice; needs review before any redistribution".
4. Narrow follow-up issues, only for failures that were actually observed (§2.10).

### 2.10 Follow-ups that may be needed (not proposed now)

These are listed only so the right repo and layer are clear in advance. File each one only if the experiment shows the problem:

- **Session-end pause/quit seam.** The engine has `setPaused` and `quit()` but no external trigger. If the undo command and the watchdog do not stop an abandoned game within 5 minutes through a save-safe path, a separate RFC would cover an engine or generated-main hook: graceful quit on SIGTERM (in the CLI-filled lifecycle block), or pause on focus loss.
- **CLI stop or `playtest` helper.** `labelle stop`, or a `labelle playtest` helper that writes the Sunshine app entry, mints session directories and passes signals on. This lives in the CLI repo, and is filed only if the Q6 rule (§2.9) says so.
- **Game-side save root.** If gate G2 fails, make a Flying Platform change so it honours `LABELLE_DATA_DIR`. This would be a game-repo issue.
- **Input mapping fixes.** Fix these in the backend if coordinates are off under HiDPI or scaled capture. Fix them in the engine `input_mixin` only if the engine itself converts the coordinates.
- **macOS CI.** If a failure turns out to be a macOS engine/backend bug, file a narrow bug plus a request for a macOS compile/test job (there is no macOS CI job today; Linux runs the full suite and Windows a subset, §1.2).
- **RFC location.** On acceptance, either move this file to `RFC-PLAYTEST-STREAMING.md` at the repository root (the existing convention) or add a `docs/rfcs/README.md` index. This is a documentation follow-up, independent of the experiment.

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
- [ ] The session handoff (§2.1) is tested: `stop-session.sh` with no arguments stops the current session; a stale `sessions/current` (wrapper killed) is cleaned up by the next launch; a second launch while a session is live is refused.
- [ ] Launch, video, audio, window focus and the fullscreen toggle (`setFullscreen` path) are verified.
- [ ] Resolution changes are verified **per layer**, each recorded with the layer that changed and the observed result:
  - *game:* the game's own window/render resolution or design-resolution setting, if it has one;
  - *host display mode:* the macOS display resolution/scale changed by hand, and whether Sunshine changes it when a client connects (and restores it on disconnect);
  - *stream:* Moonlight's stream resolution changed between sessions, with the host mode left alone.

### 4.2 Desktop input

Every item states its **input path**: *host-attached* (mouse/keyboard plugged into the Mac, which bypasses Sunshine) or *streamed* (BT mouse/keyboard paired to the tablet, injected by Sunshine). Host-attached results are a local reference only; **an item passes for streaming only on the streamed path**, and each item needs at least one streamed pass.

- [ ] ImGui buttons, **hover highlight/tooltips**, mouse position accuracy, click, **double-click**, **right-click/context menu**, drag (including the **drag threshold**: a small movement still registers as a click), scroll (`getMouseWheelMove`), camera movement and keyboard input are verified.
- [ ] Cursor behaviour is recorded, including any game-drawn cursor (`setCursorVisible`).
- [ ] **HiDPI coordinate accuracy** at the host's actual scale factor (recorded in G1): on the streamed path, click a set of known targets (the four corners and centre of the window, and the smallest ImGui button) and record the offset between the click and the hit in game pixels. Repeat at a second scale setting (for example the default Retina scale and one "more space" scaled mode) if the host allows it. Pass: every target is hit, and the offset is at most one game pixel.
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
- [ ] Save atomicity probe (G2) done, with the game's save writer recorded.
- [ ] Phase 5b done (dedicated host lock-down recorded, escape walk repeated there, one supervised non-core session), **or** the findings state that the invite-only question is unanswered and the decision is core-team-only.
- [ ] Upstream licences, supported host OS versions, and optional driver requirements and costs recorded.

### 4.5 Outcome
- [ ] All six questions are answered using the §2.9 criteria. Q3 may be "insufficient evidence" (fewer than 3 responses) or "indicative only" (3–4); Q6 may be "insufficient evidence" (fewer than 5 fresh sessions); Q2's Linux/Windows part is labelled paper-only unless Phase 5b measured it; Q5 is labelled an estimate.
- [ ] The decision table in §7.3 has been applied and its result recorded.
- [ ] Every settings-log entry is restored. Anything intentionally left installed is documented.
- [ ] Follow-ups are filed only for observed failures, each tagged with its layer (§2.5).

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Saves go to the real directory because the game bypasses `LABELLE_DATA_DIR` (injected store, `native_directory` or direct `Files.init`) | Medium (unknown until G2) | Medium | Gate G2 probe before Phase 2; fallbacks in §2.2, with `HOME` scoped to the game process; a game-side follow-up if needed |
| Signal-based stop bypasses the game's quit path and loses unsaved progress | High | Low (expected) – High (if completed saves corrupt) | Separate graceful and signal paths (§2.4 step 6); judge save preservation on completed saves; signal the game PID directly |
| A tester escapes to the desktop, a shell, a browser or files, or copies the bundle off the host | High on a shared desktop | High | Core team only through Phase 5, non-core only in the supervised Phase 5b session; Desktop app entry removed; bundle-exposure hard fail judged from a tested escape walk (§7.3); escape walk; a standard user is *not* a boundary, so non-core testers need a dedicated host/VM with egress filtering and no credentials |
| A tester **sees or hears** developer data without escaping (notifications, menu bar, other windows, other apps' audio) | Medium | Medium | Do Not Disturb, no other apps, Dock/menu bar hidden, fullscreen; covered in the exposure walk |
| System-audio capture picks up notifications or other apps, contaminating audio-sync measurements | Medium | Low–Medium | Same mitigations; 5-minute idle listen before audio measurements |
| Local admin UI reachable by an escaped tester on `localhost` | Medium | High | Admin UI decision in §2.8 |
| Admin UI or stream ports exposed to the internet | Medium | High | Admin UI on localhost; UPnP disabled; listener check before Phase 4; VPN overlay; external port scan |
| Capture stops because the playtest session sleeps, locks or is switched away from (including by the admin) | Medium | Medium | Settings log disables sleep and lock; admin works only over SSH or a pre-installed launchd sampler during sessions |
| TCC grants made in the wrong account, so capture or input silently fails | Medium | Medium | Grants made in the playtest user's session; capture/input checked there before pairing (§2.4 step 3) |
| macOS Secure Input (password prompts, some secure text fields) blocks injected keystrokes | Low–Medium | Medium | Tested in Phase 2; no password prompts should appear in a game-only session |
| macOS host support is weaker (third-party audio driver, fragile TCC permissions, admin needed) | Medium | Medium | Separate admin install step; record the driver and permissions; treat the Mac as a prototype only; Q2 paper comparison |
| The Mac is outside the engine's tested matrix (no macOS CI job; Linux full suite, Windows subset) | Medium | Medium | Reproduce any suspected engine/backend failure locally without streaming before blaming the stream; macOS CI follow-up if needed |
| The undo command does not fire on an abrupt client drop | Medium | Low–Medium | Tested in Phase 1; host-side watchdog as a fallback |
| `labelle run` does not pass SIGTERM on to the game, leaving an orphan | Medium | Low–Medium | Record the PID tree; signal the game PID directly; a CLI follow-up if needed |
| Touch maps to mouse in ways the UI does not expect (no hover, awkward right-click, drag threshold) | Medium | Medium | Explicit hover/right-click/double-click/drag-threshold checks in both touch modes (§4.3) |
| Pixel art and small text degraded by compression and scaling | Medium | Medium | Host reference frames; pre-registered minimum profile; integer scaling and chroma in the matrix |
| Measurements confounded by the input or display device, by an unfixed camera path, or too few trials | Medium | Medium | Same mouse unit and connection class for *L* and *S-mouse*; client-local condition *C*; panel refresh rates recorded; paired per-trial differences; ≥ 100 trials with CIs; fixed camera path; fixed frame caps; host settings frozen before the baseline |
| Host and client frames compared at different game states (load-time variation, animated clouds) | Medium | Medium | Pause at static checkpoints; extract moving-content frames at an on-screen marker (§2.6) |
| Raters apply the readability threshold differently | Medium | Medium | Pre-registered rubric with named text targets, pixel heights and pass/fail example images (§2.6) |
| The game's save writer is not atomic, so a kill mid-save corrupts it | Low–Medium | High | G2 atomicity probe; record the writer; power-loss safety stated as untested |
| The session pointer is stale or a PID is reused, so `stop-session.sh` signals the wrong process | Low | Medium | PID start-time check; stale-pointer cleanup on launch; one session per host (§2.1) |
| The invite-only verdict is given from a configuration never tested with non-core testers | Medium | High | Phase 5b required; otherwise the invite-only scope is "unanswered" (§7.3) |
| A redistributed helper triggers copyleft or driver-licence obligations unnoticed | Low–Medium | Medium | Licensing assessment (§2.9) before any packaging |
| WAN result biased by a relayed or unrepresentative path | Medium | Medium | Record direct vs relayed, both lines and capacities; state whether the result is an upper bound |
| Survey responses are few or unrepresentative | Medium | Medium | Minimum of 3 responses, else "insufficient evidence"; state the limit |
| The measurement matrix overruns the time available | High | Medium | Minimum viable matrix and priority order (§2); extended matrix optional |
| Results do not generalise (one Mac, one tablet, one network) | High | Medium | State this limit; the cost estimate names its assumptions |
| Scope creep into a streaming backend or cloud service | Medium | Medium | §2.10 lists follow-ups only; anything larger needs a new RFC |

---

## 6. Security notes

- Streaming reduces the risk of binary and asset extraction through the normal tester path. It does not prevent screen recording, imitation, extraction after a host compromise, or extraction from builds distributed some other way.
- A paired Moonlight client gets real OS input on the host. A standard macOS user limits access but is not an isolation boundary.
- No one outside the core team operates the stream until Phase 5 is complete, and then only in the supervised Phase 5b session, on a dedicated host or VM with all of the following (each one tested in Phase 5b, not only documented):
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
- The source review in §1.2, with file and line references: the generated-main `lifecycle` placeholder, `quit()` only flipping `running` and no signal handler in this repo, environment knobs and who sets them (including the host screenshot variables), the storage precedence that limits `LABELLE_DATA_DIR` and the `HOME` dependency of the macOS default, desktop input forwarding, fullscreen request and read-back, cursor controls, the 120-frame `frameStats()` window with no percentiles, the lack of any focus-loss or disconnect pause seam, and the CI matrix (Linux full suite, Windows subset, no macOS).
- No streaming experiment has been run, and no survey has been sent. There are no measurements, screenshots, version records or verified Sunshine behaviours yet. Upstream behaviours are design assumptions until observed: the undo command on an abrupt drop, macOS install and per-user TCC requirements, Secure Input, the admin UI's configurability, the available touch modes, and the absence of invitation/expiry/queue features.
- No builds or tests were run to write this RFC, or to revise it after review; it is a design-only document. The revision re-checked the cited sources at `6aa8d3a`: `.github/workflows/ci.yml:17,46-64,73-89,91-118`, `docs/persistent-blobs.md:70-75`, `src/screenshot_request.zig:102-106`, `src/game/lifecycle_mixin.zig:234-240`.

### 7.2 Proposed validation (done by the experiment)
1. **Survey and gates:** the Phase 0 survey; G1–G5, including the save-root probe and the abrupt-drop undo test.
2. **Functional:** checklists §4.1 to §4.3 on the LAN, recording pass, fail or degraded with evidence.
3. **Quantitative:** the Phase 3 methods, local and streamed, on the same scenes, revision, camera path and frame caps. Keep the raw numbers (latency trials, frame-time CSVs, powermetrics/ps/nettop logs) and name each tool.
4. **WAN:** the Phase 4 subset on a team-controlled connection, after the pre-exposure checks, with an external port scan and the path characterised.
5. **Robustness, pause, stop and escape:** the Phase 5 scenarios, the §2.4 stop paths, the session-handoff cases (§2.1) and the G2 atomicity probe, with the outcome of each recorded.
5b. **Non-core host:** the Phase 5b lock-down, its escape walk and the supervised non-core session, or an explicit "unanswered" for the invite-only scope.
6. **Teardown:** check every settings-log entry is restored and that no listeners, launchd jobs or pairings remain.
7. **Engine regression:** none needed, because Phases 0 to 4 change no engine code. The temporary frame-time hook (if any) lives only in the game working copy. If a follow-up changes the engine, it must add tests under `test/` following the repo's module and test pairing.

### 7.3 Go/no-go decision table (pre-registered before any measurement)

**Scope of the decision.** The decision is given separately for two scopes:
- **Core-team sessions** (on the Mac): uses Phases 0–5.
- **Invite-only sessions with non-core testers**: needs everything the core-team decision needs, **plus** Phase 5b. If Phase 5b was not run, this scope is recorded as **"unanswered"**, not GO and not GO WITH CONDITIONS. The recommendation then covers core-team sessions only, and the findings say so.

**Hard fail: one of these alone means NO-GO** for the scope it was observed in.
- Any stuck key or button on the host after a disconnect that is not released within 2 s of reconnect or session stop.
- Any loss or corruption of a **completed save** (§2.4 step 6) on either stop path; any completed save that the chosen G2 mechanism fails to capture into `sessions/<id>/` (written there directly, or copied there after exit under fallback 2); or any save that overwrites another session's save or the playtest user's real save. (Loss of unsaved progress on the signal path is recorded but is not a hard fail. Writing to the game's fixed location during play is expected under fallback 2 and is not a fail by itself.)
- The admin UI or stream ports reachable from the public internet at any point.
- A crash or hang of the game or Sunshine during the 30-minute session that is **attributable to streaming or capture, or does not reproduce locally** without streaming on the same revision and scene. A crash that reproduces locally is filed as a game bug, the session is rerun, and the rerun is judged instead; if a rerun is not possible, stability is recorded as "insufficient evidence" (and so NO-GO, see below).
- An abandoned session left running more than 5 minutes after the client dropped, with the undo command and watchdog in place.
- **Bundle exposure** (tested, not documented): during the escape and exposure walk of the tested playtest session, any path that lets the tester read or copy the game bundle or its assets (via a shell, browser, file dialog, clipboard, file transfer or network egress).
  - On the Mac (Phase 5), such a path is a hard fail for the **invite-only** scope always. For the **core-team** scope it is recorded but not a fail, because core-team members can already obtain the package (§2).
  - On the Phase 5b host, any such path is a hard fail for the invite-only scope. No document can substitute for this test: the dedicated-host configuration counts only if its escape walk was run and found no such path.

**Thresholds for GO (all must hold):**

| Criterion | Threshold |
|-----------|-----------|
| §4.1, §4.2 items | All pass with no code change (config/script changes allowed) |
| Tablet core interactions (tap a button, drag an item, pan the camera, scroll, open a context menu if the game uses one) | Pass in at least one Moonlight touch mode |
| LAN added latency (S-mouse minus L, paired per trial, same mouse unit and connection class on both ends, §2.6) | p95 ≤ 50 ms, with the upper 95 % CI bound ≤ 60 ms; client-local condition *C* reported alongside |
| WAN latency (S-mouse) | p95 ≤ 150 ms input-to-photon, with the upper CI bound ≤ 170 ms |
| Dropped frames (Moonlight overlay, 30-min session) | ≤ 1 % on LAN, ≤ 3 % on WAN |
| Audio offset | Median within ±80 ms, max within ±120 ms |
| Readability | At the pre-registered minimum profile (§2.6), all three rubric criteria pass (named text targets read exactly, pixel art crisp, no banding/macroblocking) for both raters on the tablet at the recorded viewing distance, in all three scenes |
| WAN readability | The link sustains the minimum profile's bitrate with loss < 1 %; if not, GO WITH CONDITIONS at the highest sustained profile that still passes readability, or NO-GO if none passes |
| Pause | §2.8 decision rule met (stopped within 5 min with completed saves intact) |
| Subjective responsiveness | Median rating ≥ 3 from at least two raters, LAN and WAN |
| Stability | 30-minute session (or its rerun after a locally reproducible game crash) with ≤ 1 disconnect, which recovers by reconnecting |

**GO WITH CONDITIONS:** no hard fail, every threshold met, but one or more items meet it only with a named mitigation. Examples: only one touch mode works, a BT mouse is required, or the WAN is acceptable only at a lower profile. For the invite-only scope, a condition such as "the dedicated, locked-down host is required" is allowed **only** if that host configuration was the one tested in Phase 5b. The conditions are listed and must hold for every playtest.

**NO-GO:** any hard fail, or any threshold missed. The blocking items are listed by layer, with the follow-ups that would remove them.

**Insufficient evidence:** a threshold or hard-fail check that was not measured (for example because time ran out, §2) is recorded as "insufficient evidence" and counts as **NO-GO** for that scope, with the missing item named. The one exception is Phase 5b as a whole, which makes the invite-only scope "unanswered" as defined above.

**Who judges:** two core-team raters, named in the findings, score the subjective items independently. If they disagree on a pass or fail, the stricter result is used. Numeric thresholds are measured, not judged. Any threshold change has to be made and recorded *before* Phase 3 starts.
