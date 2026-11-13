# RFC 918: Evaluate Sunshine/Moonlight streaming for private Labelle playtests

**Status:** Draft (design only; no experiment has been run yet)
**Issue:** labelle-toolkit/labelle-engine#918
**Scope of this document:** how to run the feasibility experiment, what it must measure, and how its results lead to a go/no-go decision and follow-up work. This RFC does **not** propose engine code changes. It describes the engine seams the experiment depends on, so that any follow-up lands in the right layer.

**What merging this RFC means.** Merging it accepts the *experiment protocol* only. It does **not** complete #918. The issue's completion criteria need a published setup guide and findings: tested versions, measurements, visual evidence, known failures and a go/no-go recommendation. #918 stays open until the experiment has run and those findings are appended to this RFC or linked from it. When they are, this RFC's status changes from *Draft* to *Accepted, protocol* and then to *Concluded* (with the go/no-go result).

---

## 1. Problem and context

### 1.1 Problem

Today, prerelease playtesting means sending testers a game package: the binary and its assets. Anyone who receives the package can extract the assets and reverse-engineer or repackage the binary. Issue #918 asks whether **Sunshine** (host capture, encoding and input injection) plus **Moonlight** (an installed client) is a practical way to run *invite-only* remote playtests in which the tester never receives the package. The first target is **Flying Platform**. It will be hosted on the existing **Mac** and played on the existing **Android tablet**.

This is a feasibility investigation, not a plan for a cloud-gaming service. The intended result is a reproducible setup guide, measurements and a go/no-go decision. Follow-up issues should be filed only where the experiment shows a need for them.

### 1.2 What the code shows today (existing evidence)

All findings in this section come from reading this checkout. None of them has been run or tested.

| Area | What the source shows | Why it matters for streaming |
|------|-----------------------|------------------------------|
| Entry point | The engine is a library with no `main()`. `labelle-assembler` generates the entry point for each target (CLAUDE.md). Argv, window creation and the frame loop all live in that generated `main.zig`. | Launch and window behaviour under Sunshine belongs to the generated main or the backend, not to this repo. |
| Environment knobs | **Set by the CLI:** `LABELLE_SCENE` (`src/runtime_env.zig:1-21`, written by `labelle run --scene=<name>`, cli#229) and the screenshot variables `LABELLE_SCREENSHOT_PATH` / `LABELLE_SCREENSHOT_AFTER_SEC` (`src/screenshot_request.zig`). **Read by the engine and set by whoever launches the game:** `LABELLE_DATA_DIR` (`src/storage/default.zig:70`, only on the default storage path, see the next row) and `LABELLE_PROFILE=1` (per-script tick ranking to the log, `src/root.zig:787`). | A Sunshine application entry can be a command plus environment variables. Two caveats apply. `LABELLE_SCENE` is only a *hint*: the engine does not apply it itself. The game's loading controller has to call `requestedScene()` after `assets.allReady` and recognise the name (`src/runtime_env.zig:4-9`). `LABELLE_DATA_DIR` is only honoured on one storage path. |
| Save location | `storage.Default(Backend).init` (`src/storage/default.zig:31-80`) picks the save directory in this order: (1) an injected `options.store` returns early, and no path is used (`:34`). (2) `options.native_directory` is used as is (`:42-56`). (3) Otherwise `data_root.resolve` is called with `override = env("LABELLE_DATA_DIR")` (`:57-77`). That override must be absolute (`src/storage/data_root.zig:61-63`). The macOS fallback is `$HOME/Library/Application Support/<app_id>`, with `saves/` appended. `data_root.zig` never reads the environment itself. The engine does not call `storage.Default` itself; **the game does**. `docs/persistent-blobs.md:36,43` documents this precedence. | `LABELLE_DATA_DIR` isolates sessions **only if** Flying Platform uses `storage.Default` without `native_directory` and without an injected store. If the game passes either one, or calls `storage.Files.init` directly, the variable is silently ignored. Saves then land wherever the game decides, possibly the playtest user's real directory. This must be verified (Phase 0, gate G2). |
| Input model | `src/game/input_mixin.zig:15-43` forwards keyboard, mouse (position, buttons, wheel) and gamepad state from the backend `Input`. `input_types.zig:134` defines `Touch` (`MAX_TOUCHES = 10`), and `gestures.zig` recognises pinch, pan, swipe and other gestures from raw touches. | Sunshine injects OS-level mouse, keyboard and gamepad events, and desktop backends read OS input. The desktop path *should* therefore see streamed input unchanged. Touch on a desktop backend takes a different path. Moonlight most likely translates the tablet's touches into mouse events, in which case the engine's `Touch`/`Gestures` path is not exercised. The experiment must confirm or refute this (§4.3). |
| Cursor | `lifecycle_mixin.zig:255-266` exposes `setCursorVisible` and `isCursorOverWindow` through `core.CursorControls`. Unsupported backends return `false`. | If the game hides the OS cursor and draws its own, the captured stream shows the game-drawn cursor. Check for a duplicated or lagging cursor. |
| Fullscreen | The engine stores the *desired* state (`setFullscreen`, `takeFullscreenRequest`, `lifecycle_mixin.zig:282-335`). The generated main applies it and reads the real state back. | Fullscreen and resolution switches under capture go through the backend window path. Sunshine may change the display mode when a client connects. |
| Pause | `setPaused` and `isPaused` exist. The only automatic pause is the opt-in pause on controller loss (`input_events_mixin.zig:85-91`, #611). I found **no window-focus-loss or app-suspend hook** in this repo. | A Moonlight disconnect is invisible to the game, because the window stays focused on the host. Today nothing pauses the game when a tester drops. |
| Frame stats | `frame_profiler.zig:22` keeps a **120-frame** ring of dt values (about 2 s at 60 fps). `game.frameStats()` (`misc_mixin.zig:310`) returns min/avg/max frame time and FPS, and `frameHistory()` copies the window out. Both are accessors only; nothing logs them. | They are usable for host-side frame pacing only if something samples them periodically. A 30-minute session needs a sampling method (§2.6). |
| Editor preview | `preview_mode.zig:29-31` and `src/preview/*` connect out to the editor for PIE, using hello/heartbeat/bye frames and SHM/IOSurface capture. | The issue says the first experiment "should not require … modifications to the existing editor-preview protocol". **This RFC also decides** not to reuse or extend that protocol for streaming. That is a scope decision, not the issue's wording. Streaming uses ordinary OS capture. |

**Not verifiable from this checkout, so the experiment must record them (Phase 0):**
- the assembler templates;
- the CLI's launch and stop behaviour (the README documents only foreground `labelle run`, `README.md:56-68`);
- the backend and renderer Flying Platform uses on macOS, and how that backend handles focus and HiDPI;
- how Flying Platform initialises storage;
- whether its loading controller honours `LABELLE_SCENE`.

### 1.3 Security motivation and its limits

Streaming keeps the package from reaching testers through the normal client path. It does **not** prevent recording or imitation. It does not prevent extraction after a host compromise, and it does not protect a version distributed some other way. It also adds a new risk: a remote party now controls input on the host. A shared desktop with Sunshine is not a safe multi-user service (§6).

---

## 2. Proposed design

The design is an experiment protocol in phases. Each phase has entry gates and records evidence. **Phases 0 to 4 use unchanged engine, assembler and CLI code.** Stopping the game uses OS signals and the Sunshine undo command, not a new CLI command (§2.4, step 6). Any CLI or engine addition is a follow-up (§2.10).

**Participants.** A *core-team member* is someone who already has repository access to Flying Platform and could already obtain the package. Only core-team members take part before the Phase 5 gate. Every participant, their device and their connection are recorded in the findings.

### 2.1 Topology

```text
Mac host
  admin account        : installs software, grants TCC permissions, runs powermetrics (sudo)
  "labelle-playtest"   : standard (non-admin) user, the active console session, runs Sunshine + game
    └─ wrapper script start-session.sh (Sunshine app "do" command)
         - mints <session-id>, creates /Users/labelle-playtest/sessions/<session-id>
         - exports LABELLE_DATA_DIR=<that dir>  [only effective if gate G2 passes]
                   LABELLE_SCENE=<scene>        [only effective if gate G3 passes]
         - exec labelle run … (or the built binary), records the PID
    └─ stop-session.sh (Sunshine app "undo" command): SIGTERM → wait → SIGKILL, log exit path
    └─ Sunshine: display + audio capture + input injection
         app entry = "Flying Platform" only; "Desktop" entry removed
         web admin UI bound to localhost; UPnP/NAT-PMP disabled
        │  LAN first (Phases 1–3); then a team-controlled WAN path via VPN overlay (Phase 4)
        ▼
Android tablet: Moonlight (paired by PIN); touch mode recorded; optional BT keyboard/controller
```

### 2.2 Phase 0: Inventory and gates (no installs)

**Versions table.** The findings doc has exactly one versions table, and §4.1 refers to it. It contains:

| Field | Value to record |
|-------|-----------------|
| macOS build | e.g. `sw_vers` output |
| Host hardware | model, CPU, GPU, RAM |
| Host display | resolution, refresh rate, connection (built-in, HDMI, headless dongle, virtual) |
| Sunshine | version, install method (installer or Homebrew), build source |
| Encoder | hardware or software encoder (e.g. VideoToolbox), codec(s), chroma subsampling, bit depth |
| Audio capture | loopback driver name, version, licence |
| Moonlight | Android app version, install source |
| Client device | tablet model, Android version, screen resolution, Wi-Fi band |
| Game | Flying Platform git revision, build config |
| Toolchain | engine, assembler and CLI revisions |
| Runtime | backend, renderer, design resolution, vsync/frame cap |

**Gates.** These are verified by reading the game's source and doing one local run. A gate that fails blocks the phase that depends on it, until its fallback is in place.

- **G1 (backend):** record the backend and renderer, and whether the game draws its own cursor.
- **G2 (save root):** find Flying Platform's storage initialisation. Record which branch it takes: injected store, `native_directory`, `storage.Default` defaults, or `storage.Files.init` directly. **Probe:** run locally with `LABELLE_DATA_DIR=/tmp/lp-probe-<n>`, trigger a save, and confirm that the save file appears under `/tmp/lp-probe-<n>/saves/` and not under `~/Library/Application Support/<app_id>`. If the probe fails, use a fallback in this order:
  1. a per-session `HOME` exported by the wrapper, if the game's path derives from `HOME`;
  2. copy-on-start: the wrapper copies a clean save directory into the game's fixed location before launch and moves it to `sessions/<id>/` after exit, with only one session at a time;
  3. a narrowly scoped game-side change, filed as a follow-up.

  The chosen mechanism is recorded. Phase 2 does not start until a save is shown to land in the session directory.
- **G3 (scene selection):** confirm that the loading controller calls `requestedScene()` and record the scene names it accepts. If it does not, scenes are reached manually in game and the findings say so.
- **G4 (stop path):** see §2.4, step 6.

**Local baseline.** Measure the same scenes later used for streaming: moving clouds, a busy colony scene and a small-text UI panel. Use the methods of §2.6. Record a host settings log (§2.3) before anything is changed.

### 2.3 Host settings log (started in Phase 0, restored in Phase 6)

Record the original value, the temporary value and the restore step for each of these:
- energy saver, display sleep and system sleep;
- screen lock and screensaver;
- auto-login and fast user switching;
- application firewall;
- Remote Management and Screen Sharing;
- display resolution and refresh rate;
- default audio output device;
- Sunshine UPnP/NAT-PMP (disabled);
- installed software and TCC permissions (Screen Recording, Accessibility, Microphone if prompted).

The `labelle-playtest` user must remain the **active, unlocked console session** for the whole test, otherwise capture stops. Record how this is ensured: fast user switching to that user with sleep and lock disabled, or a headless display adapter.

### 2.4 Phase 1: Host setup and pairing (LAN)

1. **Admin step, done on the admin account.** Install Sunshine and the audio loopback driver if macOS Sunshine needs one. Record which actions needed admin rights: installer authentication, driver approval, TCC prompts. Grant Screen Recording and Accessibility to Sunshine. These grants are per app, but approving them may need admin. Record exactly which account approved each grant. Install Moonlight on the tablet.
2. Create the standard (non-admin) `labelle-playtest` user. Copy only the built game or a CLI checkout into it. Store no developer credentials, SSH keys, tokens or browser profiles in it.
3. Bind Sunshine's web admin UI to localhost and set a strong admin credential. Disable UPnP/NAT-PMP. **Before any WAN work**, list listeners (`lsof -iTCP -sTCP:LISTEN`, `lsof -iUDP`) and confirm that the router has no port mappings.
4. Remove the Sunshine "Desktop" application entry. Define one "Flying Platform" entry whose *do* command is `start-session.sh` and whose *undo* command is `stop-session.sh`. Store both scripts with the findings.
5. **Per-session directory and invitations.** A static Sunshine app entry cannot mint a session ID, so the wrapper creates it (timestamp plus random suffix). Retention: session directories are kept until the findings are written and then deleted in Phase 6. An invitation is a PIN pairing done in person or over a trusted channel by a core-team member. Revocation means unpairing the client in the Sunshine admin UI. Record the time each setup step takes and every manual error, to answer question 6.
6. **Stop path (gate G4).** The CLI exposes no documented stop command (`README.md:56-68`). The shutdown procedure is therefore: (a) the Sunshine undo command sends SIGTERM to the recorded PID (the `labelle run` process or the game binary), waits N seconds, then sends SIGKILL; (b) the manual equivalent is Ctrl-C/SIGINT to a foreground `labelle run`. For each one, record whether `labelle run` passes the signal on to the game and whether the game exits cleanly (exit code, saves flushed, no orphan process in `ps`). If neither path is clean, record that as a launch-tooling failure. A CLI stop command would be a follow-up, not part of this experiment.
7. **Abandoned-session test (moved here from robustness).** Pair the tablet over the LAN, start the app, then kill Moonlight abruptly (force-stop, or turn Wi-Fi off). Record whether Sunshine runs the undo command, how long that takes, and whether the game exits. The Sunshine version's documentation is cited in the findings, and the behaviour is treated as an assumption until this test is observed. If the undo command does not run on an abrupt drop, add a host-side watchdog: a script that stops the game when no Sunshine client has been connected for T minutes, based on Sunshine's log or API. Retest.

### 2.5 Phase 2: Functional compatibility (LAN, unchanged runtime)

Run the checklists in §4.1 to §4.3. Record each item as pass, fail or degraded, with evidence (screenshot, clip or note). For tablet input, record Moonlight's touch mode and test both the **touchscreen** (direct) and **trackpad** (relative) modes if this Moonlight version offers them. Classify every failure by layer:

- **Backend/window** (generated main, backend): focus, fullscreen, resolution, HiDPI scale, cursor.
- **Input layer** (engine `input_mixin` or backend input): coordinate mapping, wheel, drag, stuck keys.
- **Launch tooling** (CLI, wrapper scripts or Sunshine app entry): start, stop, environment variables, save root.
- **Host/stream config** (Sunshine/Moonlight settings): bitrate, codec, scaling. These need no code.

### 2.6 Phase 3: Quality and resource measurement (LAN)

**Fixed conditions.** Write down the host refresh rate, game vsync/frame cap, Sunshine frame limit and Moonlight fps. Use a fixed, repeatable camera path, either scripted input or a scripted pan-and-zoom route repeated by hand along the same route and timed. Save the exact Sunshine and Moonlight settings next to every screenshot and clip.

- **Latency.**
  - *Local baseline:* Mac display with a mouse click.
  - *Streamed:* tablet display with a tap.

  That pairing mixes up two things: the input device and the display. So add a third run that changes only the stream: tablet display with a **Bluetooth mouse** paired to the tablet. Record each condition's input and display. Film each condition with the same 240 fps phone camera, framing the input action and the screen together. Count frames from input to the first visible response, for ≥ 20 trials per condition, and report p50/p95 in ms. Also record the network, decode and render times from Moonlight's performance overlay.
- **Subjective responsiveness.** At least two core-team members play a fixed 5-minute task (place and move items, pan the camera, use a menu) locally and then streamed. They rate each run on a 1–5 scale (1 = unplayable, 3 = noticeable but fine for playtesting, 5 = indistinguishable). Raters and scores are recorded.
- **Frame pacing.**
  - *Host:* run with `LABELLE_PROFILE=1` for the per-script ranking. For frame times, either use an existing in-game inspector that shows `frameStats()` and screenshot it every 30 s, or, if the game has a debug log hook, sample `frameStats()` once per 120-frame window. Report a p95 frame time and the count of frames over 1.5× the target.
  - *Client:* record dropped frames and fps from the Moonlight overlay.
- **Audio sync.** Use an in-game action with both a sound and a visual cue (or a clap test on a debug scene, if one exists). Film the tablet speaker and screen together and measure the audio-to-visual offset over ≥ 10 trials, locally and streamed.
- **Visual quality.** Play each test scene across a matrix of:
  - stream resolution: tablet native, 1080p, 720p;
  - **integer multiple of the game's design resolution**, where one exists;
  - bitrate: 10, 20 or 40 Mbps, adjusted to the encoder;
  - codec: H.264, and HEVC if supported;
  - chroma: 4:2:0, and 4:4:4 if supported.

  Record screenshots and clips on the client. Judge pixel-art crispness, small-text readability (§7.3 threshold), and banding or macroblocking on the moving clouds.
- **Host load.** Collect `sudo powermetrics --samplers cpu_power,gpu_power -i 1000` from the **admin account** while the playtest session runs. Also collect memory per process (`ps -o rss` for the game and Sunshine, sampled every 10 s) and network bitrate (Moonlight overlay plus `nettop` on the host). If GPU encoder occupancy is not exposed, use an Instruments Metal System Trace capture or record "not measurable" with the tool you tried. Units: % CPU, mW, GPU active residency %, MB, Mbps. Compare the same scene streamed and not streamed, idle and busy, on the same camera path.
- **Stability.** Run one representative session of at least 30 minutes. Log disconnects, audio/video drift, crashes and stuck input.

### 2.7 Phase 4: Internet test (core team only, team-controlled connection)

**Entry gates:**
- every Phase 1 gate passes;
- UPnP is disabled and the router has no port mappings;
- the listener check from §2.4, step 3 is clean;
- the abandoned-session test from §2.4, step 7 passes.

Only core-team members operate the client, on a connection the team controls (for example a team member's mobile hotspot or home line, chosen to represent players in Brazil). No third party touches the input. Connect through a VPN overlay (WireGuard or a mesh VPN) rather than port forwarding, so the Sunshine ports and admin UI are never public. An external port scan of the host's public IP confirms that nothing is exposed. Record:
- RTT, jitter and packet loss;
- the lowest bitrate that meets the §7.3 readability threshold;
- the NAT, firewall and VPN requirements.

Then repeat the latency, readability and stability subset of Phase 3.

### 2.8 Phase 5: Robustness and escape assessment (before any non-core participant)

- **Robustness:** disconnect and reconnect mid-drag and mid-keypress, then check the host for stuck keys or buttons. Check whether the game keeps running and whether saves survive in the session directory selected by G2.
- **Escape walk, run from the tablet as the playtest user.** For each item, record what a tester can reach:
  - OS shortcuts: Cmd-Tab, Cmd-Q, Cmd-Space (Spotlight), Mission Control, Force Quit;
  - quitting the game;
  - file open/save dialogs;
  - launching a **Terminal** or shell;
  - launching a **browser**;
  - **clipboard** sync between client and host;
  - any Sunshine/Moonlight **file transfer** feature;
  - **network egress** from the playtest user, e.g. whether `curl` to an external host works;
  - whether the **game bundle and assets** can be read and copied off the host (local copy and upload).
- **Isolation statement.** A standard user *reduces* access to the developer's files. It is **not a security boundary**: a local user can still read world-readable files and the game install, and with a shell and network access can copy the bundle off the host. Any participant outside the core team therefore requires all of the following:
  - a dedicated host or VM with no developer credentials;
  - egress filtered to the VPN/stream path only;
  - no shell, browser or file-transfer reachable from the game-only app;
  - per-session saves.

  These requirements are written into the findings before any invitation is sent.

### 2.9 Phase 6: Teardown and deliverables

**Teardown:**
- restore every entry in the settings log (§2.3);
- remove the pairings;
- revoke the TCC grants;
- uninstall or disable Sunshine and the audio driver;
- delete the session directories and, if it is not kept, the playtest user;
- re-check that no listeners remain;
- document anything that is intentionally left in place.

**Deliverables:**
1. `docs/playtest-streaming.md` (or the equivalent in the toolkit docs): a setup guide with exact commands, the wrapper scripts, versions and the Sunshine app entry.
2. A findings report containing:
   - the versions table;
   - the checklist result matrix and the measurements;
   - linked screenshots and clips, each with its stream settings;
   - known failures classified by layer;
   - the participant log;
   - answers to the six questions in the issue;
   - the decision from the §7.3 table.
3. **Cost and host-suitability research (desk work, done alongside Phase 3).**
   - **Q5 cost:** pick one concrete GPU-capable host offering and record its vCPU, RAM, GPU/encoder, region (prefer São Paulo), hourly price and egress price. Compute the cost per active session-hour. Use the measured Phase 3 bitrate × egress price, one instance per player, an idle-overhead assumption (for example 15 minutes per session) and the storage cost. State every assumption.
   - **Q2 host suitability:** compare the Mac with Linux and Windows hosts *on paper* against named criteria: Sunshine's support tier for that OS, the encoder available, the audio capture mechanism (driver needed or not), headless/virtual display support, scriptable unattended setup, licence cost, and whether one instance per VM is possible. This is a paper comparison, not a tested result.
   - **Licensing:** record the licences of Sunshine, Moonlight and the audio driver, the host OS versions Sunshine supports, and any paid driver or codec. This is required before packaging or redistributing any integration.
4. Narrow follow-up issues, only for failures that were actually observed (§2.10).

### 2.10 Follow-ups that may be needed (not proposed now)

These are listed only so the right repo and layer are clear in advance. File each one only if the experiment shows the problem:

- **Session-end pause/quit seam.** The engine has `setPaused` but no external trigger. If the undo command and the watchdog are not enough, a separate RFC would cover an engine hook: a quit-requested signal, or pause on focus loss.
- **CLI stop or `playtest` helper.** Write a `labelle stop`, or a `labelle playtest` helper that writes the Sunshine app entry, mints session directories and passes signals on. This lives in the CLI repo, and is worth building only if the manual steps prove error-prone (question 6).
- **Game-side save root.** If gate G2 fails, make a Flying Platform change so it honours `LABELLE_DATA_DIR`. This would be a game-repo issue.
- **Input mapping fixes.** Fix these in the backend if coordinates are off under HiDPI or scaled capture. Fix them in the engine `input_mixin` only if the engine itself converts the coordinates.

---

## 3. Alternatives considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keep distributing builds** (perhaps with obfuscated or encrypted assets) | No hosting, native latency | Does not address extraction; obfuscation only slows it down | Baseline to compare against |
| **Sunshine + Moonlight** (this RFC) | Free and open source, low latency on a LAN, no engine work, an Android client exists | Testers must install a client; macOS host support is less mature than Windows/Linux; shared-desktop risk | **Evaluate first** |
| **Parsec / Steam Remote Play / commercial cloud gaming** | Polished clients; some offer browser access | Licensing and cost, account requirements, less control; Steam needs a Steam distribution | Compare on paper only, unless Sunshine fails |
| **WebRTC / browser streaming** (e.g. self-hosted Selkies- or Neko-style stacks) | No client install | A separate stack to evaluate. Sunshine does **not** provide a browser client. Higher latency | Out of scope; evaluate separately if question 3 shows an installed client is unacceptable |
| **New engine streaming backend** (encode frames in the engine, e.g. by extending the preview SHM/IOSurface capture) | Precise control of input and capture | Large effort. The issue says the first experiment should not need a new streaming backend or preview-protocol changes, and this RFC chooses not to couple streaming to PIE | Rejected for this phase |
| **Web (WASM) build for testers** | Browser only | Ships the code and assets to the client, which defeats the goal | Rejected for the anti-extraction goal |

---

## 4. Acceptance criteria (for the experiment, not for merging this RFC)

The evaluation is complete when every item below has a recorded result with evidence. Pass and fail are both acceptable outcomes, as long as they are evidenced.

### 4.1 Setup and launch
- [ ] The versions table in §2.2 is complete, including Sunshine, Moonlight, the encoder and its settings.
- [ ] Gates G1–G4 are recorded, including the G2 save-root probe result and the chosen mechanism.
- [ ] Admin installation, TCC permissions, pairing, the wrapper scripts and the Sunshine app entry are documented as reproducible steps, noting which steps needed admin.
- [ ] Launch through the Labelle CLI (`labelle run`) and the stop path from §2.4, step 6 (SIGTERM via the undo command; SIGINT by hand) are tested, with the exit path and code recorded.
- [ ] Launch, video, audio, window focus, the fullscreen toggle (`setFullscreen` path) and resolution changes are verified.

### 4.2 Desktop input
- [ ] ImGui buttons, mouse position accuracy, click, drag, scroll (`getMouseWheelMove`), camera movement and keyboard input are verified.
- [ ] Cursor behaviour is recorded, including any game-drawn cursor (`setCursorVisible`).

### 4.3 Tablet input
- [ ] Touch-to-mouse behaviour is documented in each available Moonlight touch mode: tap, long-press, drag and two-finger scroll.
- [ ] The result explicitly says whether native multitouch reaches the engine's `Touch`/`Gestures` path. It is expected not to; the result must confirm or refute this.
- [ ] Controller support is checked separately, if relevant.

### 4.4 Quality, resources, robustness
- [ ] Local vs streamed: latency p50/p95 for all three §2.6 conditions, subjective ratings, frame-pacing p95, dropped frames, audio offset, and a stability session of at least 30 minutes.
- [ ] Readability matrix (resolution, including integer scaling × bitrate × codec × chroma) with screenshots and clips of the clouds, busy colony and small text, each with its settings.
- [ ] Host CPU/GPU/encoder/memory/bandwidth measured streamed vs not streamed, idle and busy, on a fixed camera path, with the tool and units named.
- [ ] Disconnect/reconnect, stuck-key release, pause behaviour and save preservation tested; abandoned-session stop tested in Phase 1.
- [ ] Internet test done by the core team only, with UPnP off, no public listeners (scan evidence) and the connection requirements documented.
- [ ] Escape walk done, including shell, browser, clipboard, file transfer, egress and copying the bundle off the host; isolation requirements for non-core testers written down.
- [ ] Upstream licences, supported host OS versions, and optional driver requirements and costs recorded.

### 4.5 Outcome
- [ ] All six questions from the issue are answered. Q5 uses measured load plus the researched hosting option, with stated assumptions. Q2 includes the paper comparison. Q6 uses the recorded setup time and manual errors.
- [ ] The decision table in §7.3 has been applied and its result recorded.
- [ ] Every settings-log entry is restored. Anything intentionally left installed is documented.
- [ ] Follow-ups are filed only for observed failures, each tagged with its layer (§2.5).

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Saves go to the real directory because the game bypasses `LABELLE_DATA_DIR` (injected store, `native_directory` or direct `Files.init`) | Medium (unknown until G2) | Medium | Gate G2 probe before Phase 2; fallbacks in §2.2; a game-side follow-up if needed |
| A tester escapes to the desktop, a shell, a browser or files, or copies the bundle off the host | High on a shared desktop | High | Core team only before Phase 5; Desktop app entry removed; escape walk covers shell, browser, clipboard and egress; a standard user is *not* a boundary, so non-core testers need a dedicated host/VM with egress filtering and no credentials |
| Admin UI or stream ports exposed to the internet | Medium | High | Admin UI on localhost; UPnP disabled; listener check before Phase 4; VPN overlay; external port scan |
| Capture stops because the playtest session sleeps, locks or is switched away from | Medium | Medium | Settings log disables sleep and lock; keep the user as the active console session, or use a headless display adapter |
| macOS host support is weaker (third-party audio driver, fragile TCC permissions, admin needed) | Medium | Medium | Separate admin install step; record the driver and permissions; treat the Mac as a prototype only; Q2 paper comparison |
| The undo command does not fire on an abrupt client drop | Medium | Low–Medium | Tested in Phase 1; host-side watchdog as a fallback |
| `labelle run` does not pass SIGTERM on to the game, leaving an orphan | Medium | Low–Medium | Signal the game PID directly; record it; a CLI follow-up if needed |
| Touch maps to mouse in ways the UI does not expect (hover, right-click, drag threshold) | Medium | Medium | Test both Moonlight touch modes (§4.3) |
| Pixel art and small text degraded by compression and scaling | Medium | Medium | Matrix includes integer scaling and chroma; numeric readability threshold |
| Measurements confounded by the input or display device, or by an unfixed camera path | Medium | Medium | Third latency condition (tablet + BT mouse); fixed camera path; fixed frame caps |
| Results do not generalise (one Mac, one tablet, one network) | High | Medium | State this limit; the cost estimate names its assumptions |
| Scope creep into a streaming backend or cloud service | Medium | Medium | §2.10 lists follow-ups only; anything larger needs a new RFC |

---

## 6. Security notes

- Streaming reduces the risk of binary and asset extraction through the normal tester path. It does not prevent screen recording, imitation, extraction after a host compromise, or extraction from builds distributed some other way.
- A paired Moonlight client gets real OS input on the host. A standard macOS user limits access but is not an isolation boundary.
- No one outside the core team takes part until Phase 5 is complete, and then only on a dedicated host or VM with all of the following:
  - no developer credentials;
  - egress filtered to the stream/VPN path;
  - a game-only app entry, with no reachable shell, browser or file transfer;
  - per-session saves verified by gate G2;
  - a session stop verified in Phase 1.
- Sunshine does not provide invitations, session expiry, queues or concurrent players (question 4) for this use case. Each concurrent player needs a separate game instance and, in practice, a separate host or VM, display and encoder. The findings should state this as a requirement. Building it is not part of this phase.

---

## 7. Validation plan

### 7.1 Existing evidence (already available)
- The source review in §1.2, with file and line references: environment knobs and who sets them, the storage precedence that limits `LABELLE_DATA_DIR`, desktop input forwarding, fullscreen request and read-back, cursor controls, the 120-frame `frameStats()` window, and the lack of any focus-loss or disconnect pause seam.
- No streaming experiment has been run. There are no measurements, screenshots, version records or verified Sunshine behaviours yet. Upstream behaviours are design assumptions until observed: the undo command on an abrupt drop, macOS install and TCC requirements, `powermetrics` privileges, and the available touch modes.

### 7.2 Proposed validation (done by the experiment)
1. **Gates:** G1–G4 in Phase 0/1, including the save-root probe and the abrupt-drop undo test.
2. **Functional:** checklists §4.1 to §4.3 on the LAN, recording pass, fail or degraded with evidence.
3. **Quantitative:** the Phase 3 methods, local and streamed, on the same scenes, revision, camera path and frame caps. Keep the raw numbers and name each tool.
4. **WAN:** the Phase 4 subset on a team-controlled connection, after the pre-exposure checks, with an external port scan.
5. **Robustness and escape:** the Phase 5 scenarios, with the outcome of each recorded.
6. **Teardown:** check every settings-log entry is restored and that no listeners or pairings remain.
7. **Engine regression:** none needed, because Phases 0 to 4 change no engine code. If a follow-up changes the engine, it must add tests under `test/` following the repo's module and test pairing.

### 7.3 Go/no-go decision table (pre-registered before any measurement)

**Hard fail: one of these alone means NO-GO.**
- Any stuck key or button on the host after a disconnect that is not released within 2 s of reconnect or session stop.
- Any save loss or corruption, or any save written outside the session directory.
- The admin UI or stream ports reachable from the public internet at any point.
- A crash or hang of the game or Sunshine during the 30-minute session.
- An abandoned session left running more than 5 minutes after the client dropped, with the undo command and watchdog in place.
- The game bundle copied off the host from the game-only app *and* no documented dedicated-host configuration that blocks it.

**Thresholds for GO (all must hold):**

| Criterion | Threshold |
|-----------|-----------|
| §4.1, §4.2 items | All pass with no code change (config/script changes allowed) |
| Tablet core interactions (tap a button, drag an item, pan the camera, scroll) | Pass in at least one Moonlight touch mode |
| LAN latency (tablet + BT mouse vs local) | Streamed p95 − local p95 ≤ 50 ms |
| WAN latency (same condition) | Streamed p95 ≤ 150 ms input-to-photon |
| Dropped frames (Moonlight overlay, 30-min session) | ≤ 1 % on LAN, ≤ 3 % on WAN |
| Audio offset | Within ±80 ms |
| Readability | The smallest UI text in the game is legible to both raters in a client screenshot at a bitrate the WAN connection sustained with loss < 1 % |
| Subjective responsiveness | Median rating ≥ 3 from at least two raters, LAN and WAN |
| Stability | 30-minute session with ≤ 1 disconnect, which recovers by reconnecting |

**GO WITH CONDITIONS:** no hard fail, every threshold met, but one or more items meet it only with a named mitigation. Examples: only one touch mode works, a BT mouse is required, the WAN is acceptable only at one specific resolution, or non-core testers need the dedicated host. The conditions are listed and must hold for every playtest.

**NO-GO:** any hard fail, or any threshold missed. The blocking items are listed by layer, with the follow-ups that would remove them.

**Who judges:** two core-team raters, named in the findings, score the subjective items independently. If they disagree on a pass or fail, the stricter result is used. Numeric thresholds are measured, not judged. Any threshold change has to be made and recorded *before* Phase 3 starts.
