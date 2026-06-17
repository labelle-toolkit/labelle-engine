//! Android-specific runtime helpers for the labelle engine.
//!
//! The headline feature here is **immersive mode** — hiding the status
//! bar and the navigation bar on a running game so it owns the whole
//! screen.
//!
//! ## Why a runtime call (the manifest theme is not enough)
//!
//! `labelle-cli` emits `android:theme="@android:style/Theme.NoTitleBar.Fullscreen"`
//! into `AndroidManifest.xml` when `immersive_mode = true`. That legacy
//! theme stopped hiding the system bars on modern Android — verified
//! on-device on Android 14 / API 34. Google moved system-bar control to
//! a *runtime* API; a manifest theme can no longer reach it. So the
//! actual bar-hiding has to be a runtime JNI call from the game process.
//!
//! ## The JNI approach
//!
//! The game is a pure `NativeActivity` (`android:hasCode="false"`), so
//! there is no Java code to call into directly — every framework call
//! has to go through JNI from C/Zig. We obtain the `ANativeActivity*`
//! from labelle-core's backend-agnostic Android seam
//! (`core.android_backend`, labelle-core#310): the active backend
//! registers an `AndroidBackendContext` whose `get_native_activity`
//! returns the activity, which exposes a `JavaVM*`, a main-thread
//! `JNIEnv*`, and the activity `jobject`. The engine therefore links no
//! backend-specific (`sapp_*`/sokol) symbol of its own.
//!
//! We use **two paths**, picked at runtime by API level:
//!
//!   - **API 30+ (primary):** `WindowInsetsController`.
//!     - The legacy `View.setSystemUiVisibility` is deprecated since
//!       API 30 and on API 34 it NO LONGER reliably hides the
//!       navigation bar — verified on-device on Android 14:
//!       `setSystemUiVisibility` with the immersive-sticky flag set hid
//!       only the status bar (and that was really the manifest
//!       `Theme.NoTitleBar.Fullscreen` doing it), leaving the nav bar's
//!       72px strip reserved. Google's replacement,
//!       `WindowInsetsController`, is the only API that still hides the
//!       nav bar at target SDK 34.
//!     - `WindowInsetsController.hide(WindowInsets.Type.systemBars())`
//!       hides BOTH the status and navigation bars in one call.
//!     - `setSystemBarsBehavior(BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE)`
//!       reproduces immersive-*sticky*: the bars slide away, a swipe
//!       from the edge brings them back transiently, then auto-hide.
//!
//!   - **API 28/29 (fallback):** legacy `View.setSystemUiVisibility`
//!     with the `IMMERSIVE_STICKY | HIDE_NAVIGATION | FULLSCREEN |
//!     LAYOUT_*` flag set. `WindowInsetsController` is API 30+, but the
//!     project's `min_sdk` is 28, so Android 9/10 has no
//!     `getInsetsController`. Rather than no-op there, `applyImmersive`
//!     detects the missing method and falls back to the legacy call,
//!     which still works on API 28/29.
//!
//! ## The UI-thread problem
//!
//! sokol_app's Android backend runs the engine's `init` / `frame` /
//! `event` callbacks on a **dedicated render thread** it spawns in
//! `ANativeActivity_onCreate` (`_sapp_android_loop`). Calling
//! `View.setSystemUiVisibility` from that thread throws
//! `CalledFromWrongThreadException` — decor-view mutation must happen
//! on the Android UI/main thread.
//!
//! Rather than attach the render thread to the JVM and post a Java
//! `Runnable` (which would mean fabricating a `Runnable` subclass from
//! JNI — painful with no Java code, and impossible on Android where
//! `DefineClass` needs dex, not JVM `.class` bytecode), we **chain
//! `ANativeActivityCallbacks` entries**. The framework invokes those
//! callbacks *on the UI thread*, and the `ANativeActivity.env` field is
//! a valid UI-thread `JNIEnv*` while one runs. No thread attach, no
//! `Runnable`, no wrong-thread exception.
//!
//! ## Hiding the bars *at launch* — why two chained callbacks
//!
//! `enableImmersiveMode()` is emitted by the assembler into the
//! generated `main.zig`'s `sokol_main()`. sokol's
//! `ANativeActivity_onCreate` calls `sokol_main()` **on the UI thread**
//! *before* it registers its own `ANativeActivityCallbacks` entries —
//! so `enableImmersiveMode()` runs UI-thread-side, early, with the
//! `ANativeActivity*` already available.
//!
//! It would be tempting to chain `onWindowFocusChanged` right there,
//! but sokol *overwrites* that slot moments later in `onCreate` — our
//! pointer would not survive. The Android launch sequence then delivers
//! the window's **first** `onWindowFocusChanged(true)` to sokol's
//! handler, and a hook installed only from the render-thread `init`
//! callback (which runs *after* that first focus event) misses it: the
//! bars stay visible until the player happens to background+foreground
//! the app. "Hidden at launch" is the behaviour that actually matters.
//!
//! The fix uses a slot sokol leaves **unset**: `onContentRectChanged`
//! (its registration line in `ANativeActivity_onCreate` is commented
//! out). We install `contentRectHook` there from `sokol_main()`; sokol
//! never clobbers it. The framework fires `onContentRectChanged` on the
//! UI thread once the activity's content rect is established at launch
//! — late enough that `getWindow()/getInsetsController()` resolve, so
//! the very first invocation hides the bars at launch.
//!
//! `contentRectHook`, on its first run, also chains
//! `onWindowFocusChanged` — by then sokol *has* registered its own
//! handler, so our chain forwards to sokol's and survives.
//! `onWindowFocusChanged(hasFocus=true)` fires every time the app
//! regains focus (returning from the notification shade, the recents
//! switcher, etc.), which is precisely when immersive-sticky flags can
//! get cleared — so it serves as the ongoing re-apply hook.

const std = @import("std");
const builtin = @import("builtin");

/// labelle-core, consumed for its backend-agnostic Android JNI seam
/// (`core.android_backend`, labelle-core#310). We read the active
/// backend's registered `AndroidBackendContext` to obtain the
/// `ANativeActivity*` instead of linking a backend-specific symbol.
const core = @import("labelle-core");

/// True when compiling for an Android target (covers arm64/x86_64 via
/// `.android` and arm/x86 via `.androideabi`). All the JNI machinery
/// below is gated on this so non-Android builds compile to nothing.
pub const is_android = builtin.abi == .android or builtin.abi == .androideabi;

// ── JNI / NDK type declarations ───────────────────────────────────
//
// Declared by hand rather than `@cImport`-ing `<jni.h>` so the engine
// module stays header-free on non-Android targets. The layouts mirror
// the NDK's `jni.h` and `android/native_activity.h` exactly.

const jobject = ?*anyopaque;
const jclass = ?*anyopaque;
const jmethodID = ?*anyopaque;
const jint = i32;

/// JNI `jvalue` — the 8-byte union used to pass method arguments to
/// the `Call*MethodA` family. We only ever store an `int`, so a plain
/// `extern union` with the `i` member (low 4 bytes) plus a padding
/// slot to force the 8-byte size is enough. Using the `A` variants
/// (jvalue array) instead of the C-variadic `Call*Method` functions
/// sidesteps the AArch64 variadic-ABI mismatch that crashes when a
/// non-C caller invokes the `...`-style JNI entry points.
const jvalue = extern union {
    i: jint,
    j: i64, // forces 8-byte size/alignment, matching the C union
};

/// JNI function table — only the entries we actually call. The slot
/// ordering matches `struct JNINativeInterface_` in the NDK `jni.h`;
/// unused slots are typed `*const anyopaque` so we never depend on
/// their signatures. `JNIEnv` is a pointer to a pointer to this table.
///
/// Zero-based slot indices (per `jni.h`) are cited inline at every
/// named field so the layout is auditable against the header. The
/// table has 232 entries total: slot 0 = `reserved0`, slot 231 =
/// `GetObjectRefType` (the last). We only ever index slots at or
/// before `CallStaticIntMethodA` (slot 131); the rest is an opaque
/// `_tail` and is reached only by pointer, never read.
const JNINativeInterface = extern struct {
    reserved0: ?*anyopaque, // slot 0
    reserved1: ?*anyopaque, // slot 1
    reserved2: ?*anyopaque, // slot 2
    reserved3: ?*anyopaque, // slot 3
    GetVersion: *const anyopaque, // slot 4
    DefineClass: *const anyopaque, // slot 5
    FindClass: *const fn (*JNIEnv, [*:0]const u8) callconv(.c) jclass, // slot 6
    FromReflectedMethod: *const anyopaque, // slot 7
    FromReflectedField: *const anyopaque, // slot 8
    ToReflectedMethod: *const anyopaque, // slot 9
    GetSuperclass: *const anyopaque, // slot 10
    IsAssignableFrom: *const anyopaque, // slot 11
    ToReflectedField: *const anyopaque, // slot 12
    Throw: *const anyopaque, // slot 13
    ThrowNew: *const anyopaque, // slot 14
    ExceptionOccurred: *const fn (*JNIEnv) callconv(.c) jobject, // slot 15
    ExceptionDescribe: *const fn (*JNIEnv) callconv(.c) void, // slot 16
    ExceptionClear: *const fn (*JNIEnv) callconv(.c) void, // slot 17
    FatalError: *const anyopaque, // slot 18
    PushLocalFrame: *const anyopaque, // slot 19
    PopLocalFrame: *const anyopaque, // slot 20
    NewGlobalRef: *const anyopaque, // slot 21
    DeleteGlobalRef: *const anyopaque, // slot 22
    DeleteLocalRef: *const fn (*JNIEnv, jobject) callconv(.c) void, // slot 23
    IsSameObject: *const anyopaque, // slot 24
    NewLocalRef: *const anyopaque, // slot 25
    EnsureLocalCapacity: *const anyopaque, // slot 26
    AllocObject: *const anyopaque, // slot 27
    NewObject: *const anyopaque, // slot 28
    NewObjectV: *const anyopaque, // slot 29
    NewObjectA: *const anyopaque, // slot 30
    GetObjectClass: *const fn (*JNIEnv, jobject) callconv(.c) jclass, // slot 31
    IsInstanceOf: *const anyopaque, // slot 32
    GetMethodID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID, // slot 33
    // The `Call*Method` slots are C-variadic (`...`) in jni.h. Calling
    // a C-variadic function from Zig on AArch64 has a fragile ABI (the
    // JVM mis-reads the vararg registers/stack), which crashes the
    // process. We therefore use ONLY the `...A` variants, which take a
    // `const jvalue*` argument array — a fixed, non-variadic signature
    // with a rock-solid ABI. The plain variadic slots stay opaque so
    // we can never accidentally call them.
    // `Call<Type>Method{,V,A}` for the 10 return types (Object, Boolean,
    // Byte, Char, Short, Int, Long, Float, Double, Void) — 30 slots,
    // indices 34..63. `CallObjectMethodA` = slot 36, `CallVoidMethodA`
    // = slot 63.
    CallObjectMethod: *const anyopaque, // slot 34
    CallObjectMethodV: *const anyopaque, // slot 35
    CallObjectMethodA: *const fn (*JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jobject, // slot 36
    CallBooleanMethod: *const anyopaque, // slot 37
    CallBooleanMethodV: *const anyopaque, // slot 38
    CallBooleanMethodA: *const anyopaque, // slot 39
    CallByteMethod: *const anyopaque, // slot 40
    CallByteMethodV: *const anyopaque, // slot 41
    CallByteMethodA: *const anyopaque, // slot 42
    CallCharMethod: *const anyopaque, // slot 43
    CallCharMethodV: *const anyopaque, // slot 44
    CallCharMethodA: *const anyopaque, // slot 45
    CallShortMethod: *const anyopaque, // slot 46
    CallShortMethodV: *const anyopaque, // slot 47
    CallShortMethodA: *const anyopaque, // slot 48
    CallIntMethod: *const anyopaque, // slot 49
    CallIntMethodV: *const anyopaque, // slot 50
    CallIntMethodA: *const anyopaque, // slot 51
    CallLongMethod: *const anyopaque, // slot 52
    CallLongMethodV: *const anyopaque, // slot 53
    CallLongMethodA: *const anyopaque, // slot 54
    CallFloatMethod: *const anyopaque, // slot 55
    CallFloatMethodV: *const anyopaque, // slot 56
    CallFloatMethodA: *const anyopaque, // slot 57
    CallDoubleMethod: *const anyopaque, // slot 58
    CallDoubleMethodV: *const anyopaque, // slot 59
    CallDoubleMethodA: *const anyopaque, // slot 60
    CallVoidMethod: *const anyopaque, // slot 61
    CallVoidMethodV: *const anyopaque, // slot 62
    CallVoidMethodA: *const fn (*JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) void, // slot 63
    // Between `CallVoidMethodA` (slot 63) and `GetStaticMethodID` (slot
    // 113) jni.h has 49 unused slots, indices 64..112: 30
    // `CallNonvirtual*Method{,V,A}` (64..93), then `GetFieldID` (94),
    // then 9 `Get*Field` (95..103) + 9 `Set*Field` (104..112). Kept
    // opaque — slot ORDER is ABI-load-bearing, so the count must be exact.
    _nonvirtual_and_fields: [49]?*anyopaque, // slots 64..112
    GetStaticMethodID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID, // slot 113
    // `CallStatic*Method` family — same variadic hazard as the instance
    // calls, so only the `...A` (jvalue-array) variants are typed; the
    // variadic / `va_list` slots stay opaque.
    CallStaticObjectMethod: *const anyopaque, // slot 114
    CallStaticObjectMethodV: *const anyopaque, // slot 115
    CallStaticObjectMethodA: *const anyopaque, // slot 116
    // `CallStatic{Boolean,Byte,Char,Short}Method{,V,A}` — 4 types ×
    // 3 = 12 slots, indices 117..128.
    _call_static_b_to_s: [12]?*anyopaque, // slots 117..128
    CallStaticIntMethod: *const anyopaque, // slot 129
    CallStaticIntMethodV: *const anyopaque, // slot 130
    CallStaticIntMethodA: *const fn (*JNIEnv, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jint, // slot 131
    // Slots 132..231 (100 entries) are unused: the rest of
    // `CallStatic*Method` (Long/Float/Double/Void), all `GetStatic*Field`
    // / `SetStatic*Field`, the string/array/ref/monitor families, and
    // `GetObjectRefType` (slot 231, the last). Kept opaque — we only
    // index slots at or before `CallStaticIntMethodA` and reach the
    // table by pointer, so the tail is never read.
    _tail: [100]?*anyopaque, // slots 132..231
};

/// `JNIEnv` — in C this is a typedef for `const struct JNINativeInterface*`
/// (a pointer to the function table). Every JNI function takes a
/// `JNIEnv*` (i.e. `JNIEnv` is itself one pointer; the function's first
/// parameter is a *pointer to* `JNIEnv`, hence `*JNIEnv` below — a
/// double pointer to the table). `ANativeActivity.env` is likewise a
/// `JNIEnv*`, so that field is typed `?*JNIEnv`.
const JNIEnv = *const JNINativeInterface;

/// `android/native_activity.h` — `ANativeActivityCallbacks`. Every
/// entry is invoked by the framework on the UI/main thread. Field
/// order is ABI-load-bearing: it must match the NDK header exactly so
/// our chained `onWindowFocusChanged` lands in the right slot.
const ANativeActivityCallbacks = extern struct {
    onStart: ?*const fn (*ANativeActivity) callconv(.c) void,
    onResume: ?*const fn (*ANativeActivity) callconv(.c) void,
    onSaveInstanceState: ?*const anyopaque,
    onPause: ?*const fn (*ANativeActivity) callconv(.c) void,
    onStop: ?*const fn (*ANativeActivity) callconv(.c) void,
    onDestroy: ?*const fn (*ANativeActivity) callconv(.c) void,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void,
    onNativeWindowCreated: ?*const anyopaque,
    onNativeWindowResized: ?*const anyopaque,
    onNativeWindowRedrawNeeded: ?*const anyopaque,
    onNativeWindowDestroyed: ?*const anyopaque,
    onInputQueueCreated: ?*const anyopaque,
    onInputQueueDestroyed: ?*const anyopaque,
    // `void (*)(ANativeActivity*, const ARect*)`. The `ARect*` is opaque
    // here — `contentRectHook` never reads it. sokol leaves this slot
    // UNSET (its `ANativeActivity_onCreate` has the registration line
    // commented out), which is exactly why we install our launch hook
    // here: sokol never overwrites it.
    onContentRectChanged: ?*const fn (*ANativeActivity, ?*const anyopaque) callconv(.c) void,
    onConfigurationChanged: ?*const fn (*ANativeActivity) callconv(.c) void,
    onLowMemory: ?*const fn (*ANativeActivity) callconv(.c) void,
};

/// `android/native_activity.h` — `ANativeActivity`. Only the leading
/// fields we touch are typed; the trailing path/asset-manager fields
/// are an opaque tail.
const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    vm: ?*anyopaque,
    // C type is `JNIEnv*` — a pointer to the `JNIEnv` table pointer,
    // i.e. a double pointer to `JNINativeInterface`.
    env: ?*JNIEnv,
    clazz: jobject,
    _tail: [8]?*anyopaque,
};

// `WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` — the
// immersive-sticky behaviour: hidden bars slide back transiently on an
// edge swipe, then auto-hide again. It is a `public static final int`
// on `android.view.WindowInsetsController` with the stable value `2`
// (API 30+). Using the literal avoids one more static-field JNI hop;
// the value is part of the public API contract and will not change.
const BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE: jint = 2;

// `View.setSystemUiVisibility` flag bits (from `android.view.View`).
// Combined they give immersive-STICKY: bars hidden, a swipe brings
// them back transiently, then they auto-hide again. This is the
// API 28/29 fallback path — `WindowInsetsController` is API 30+, but
// the project's `min_sdk` is 28, so Android 9/10 devices have no
// `getInsetsController` and must use this legacy call instead.
// Deprecated at API 30+ but still functional on API 28/29.
const SYSTEM_UI_FLAG_FULLSCREEN: jint = 0x00000004; // hide status bar
const SYSTEM_UI_FLAG_HIDE_NAVIGATION: jint = 0x00000002; // hide nav bar
const SYSTEM_UI_FLAG_IMMERSIVE_STICKY: jint = 0x00001000; // sticky behaviour
const SYSTEM_UI_FLAG_LAYOUT_STABLE: jint = 0x00000100;
const SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION: jint = 0x00000200;
const SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN: jint = 0x00000400;

const IMMERSIVE_FLAGS: jint =
    SYSTEM_UI_FLAG_FULLSCREEN |
    SYSTEM_UI_FLAG_HIDE_NAVIGATION |
    SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
    SYSTEM_UI_FLAG_LAYOUT_STABLE |
    SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
    SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;

// ── Android logging (so failures are visible in logcat) ───────────

const ANDROID_LOG_INFO: c_int = 4;
const ANDROID_LOG_WARN: c_int = 5;
extern "c" fn __android_log_write(prio: c_int, tag: [*:0]const u8, msg: [*:0]const u8) c_int;

fn logInfo(comptime msg: [:0]const u8) void {
    if (comptime is_android) _ = __android_log_write(ANDROID_LOG_INFO, "labelle", msg);
}
fn logWarn(comptime msg: [:0]const u8) void {
    if (comptime is_android) _ = __android_log_write(ANDROID_LOG_WARN, "labelle", msg);
}

// ── native-activity accessor ──────────────────────────────────────
//
// The `ANativeActivity*` is obtained through labelle-core's
// backend-agnostic seam (`core.android_backend`, labelle-core#310):
// the active backend adapter registers an `AndroidBackendContext` at
// startup, and we read its `get_native_activity` pointer. This keeps
// the engine free of any backend-specific (`sapp_*`/sokol) symbol — if
// no backend registered a context, immersive mode is a graceful no-op.

// ── Module state ──────────────────────────────────────────────────
//
// Both globals are written on the sokol render thread (in
// `enableImmersiveMode`) and read on the Android UI thread (in
// `focusChangedHook`), so they MUST be atomic — a plain `var` is a
// data race. Single globals are fine: there is exactly one
// `NativeActivity` per process.
//
// `FocusCb` is the callback function-pointer type; we store the
// original pointer as a `usize` in an `std.atomic.Value` (an optional
// function pointer is not a valid atomic payload type, but its raw
// address bits are). `0` means "no original callback".
const FocusCb = *const fn (*ANativeActivity, c_int) callconv(.c) void;

/// The original `onWindowFocusChanged` pointer sokol installed, saved
/// so our chained callback can still forward to it. Raw address bits;
/// `0` == none.
var saved_focus_cb: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Install guard for the `onContentRectChanged` chain. `swap(true)`
/// makes the install an atomic test-and-set so a double
/// `enableImmersiveMode()` can't double-chain.
var installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Install guard for the `onWindowFocusChanged` chain, set the first
/// time `contentRectHook` runs (it deferred-installs the focus chain).
/// Plain `bool`, not atomic: `installFocusChain` is only ever reached
/// from `contentRectHook`, which the framework invokes exclusively on
/// the one UI thread — no cross-thread access, so no atomic needed.
var focus_chain_installed: bool = false;

/// Our replacement `onWindowFocusChanged`. Runs on the UI thread, so
/// `activity.env` is a valid `JNIEnv*` for decor-view mutation.
fn focusChangedHook(activity: *ANativeActivity, has_focus: c_int) callconv(.c) void {
    // Forward to sokol's original handler first so its lifecycle
    // bookkeeping (RESUMED/SUSPENDED, frame-callback gating) is intact.
    // `enableImmersiveMode` publishes `saved_focus_cb` *before* it
    // installs `focusChangedHook` into the callbacks struct, so by the
    // time this hook can fire the load below always sees the real bits.
    const saved_bits = saved_focus_cb.load(.seq_cst);
    if (saved_bits != 0) {
        const orig: FocusCb = @ptrFromInt(saved_bits);
        orig(activity, has_focus);
    }

    // Only (re)apply when the window has focus. On focus loss the
    // system shows the bars anyway; re-applying on the next focus gain
    // is the correct immersive-sticky lifecycle.
    if (has_focus != 0) applyImmersive(activity);
}

/// Chain sokol's `onWindowFocusChanged` so immersive is re-applied on
/// every focus regain (notification shade, recents switcher, …).
///
/// Called from `contentRectHook` — i.e. on the UI thread, *after*
/// sokol's `ANativeActivity_onCreate` has registered its own
/// `onWindowFocusChanged` handler — so the saved pointer is sokol's
/// real handler and our chain survives. (`enableImmersiveMode()` runs
/// too early to do this itself: sokol overwrites the slot right after
/// `sokol_main()` returns.)
///
/// Ordering is load-bearing: publish `saved_focus_cb` *before* writing
/// `focusChangedHook` into the callbacks struct, so the hook never
/// reads a `saved_focus_cb` that has not been written yet.
fn installFocusChain(activity: *ANativeActivity) void {
    if (focus_chain_installed) return;
    focus_chain_installed = true;
    const orig_bits: usize = if (activity.callbacks.onWindowFocusChanged) |cb|
        @intFromPtr(cb)
    else
        0;
    saved_focus_cb.store(orig_bits, .seq_cst);
    activity.callbacks.onWindowFocusChanged = &focusChangedHook;
    logInfo("immersive: focus-callback hook installed");
}

/// Our chained `onContentRectChanged`. The framework fires this on the
/// UI thread once the activity's content rect is established at launch
/// (and on later content-rect changes), so `activity.env` is a valid
/// UI-thread `JNIEnv*` and the decor-view / `WindowInsetsController`
/// JNI calls are thread-legal here.
///
/// This is the hook that hides the bars **at launch**: its first
/// invocation runs early enough that a normal launch never shows the
/// system bars to the player. On that first run it also installs the
/// `onWindowFocusChanged` chain for the ongoing focus-regain re-apply.
fn contentRectHook(activity: *ANativeActivity, rect: ?*const anyopaque) callconv(.c) void {
    _ = rect; // unused — we re-apply immersive regardless of the rect
    // Install the focus-regain re-apply chain on the first run. Done
    // here (not in `enableImmersiveMode`) because by now sokol has
    // registered its own `onWindowFocusChanged`, so the chain forwards
    // correctly instead of being overwritten.
    installFocusChain(activity);
    applyImmersive(activity);
}

/// Perform the JNI calls that hide the system bars, using the
/// `ANativeActivity`'s own `env`. MUST be called on the Android UI/main
/// thread — the only thread where `activity.env` is the valid `JNIEnv*`
/// AND where `WindowInsetsController.hide()` is legal. Both immersive
/// entry points satisfy that:
///   * sokol's `onWindowFocusChanged` / `onContentRectChanged` hooks (the
///     framework invokes them on the UI thread), and
///   * `applyImmersiveUiThread`, which the bgfx shell calls from its
///     chained `onWindowFocusChanged` (also a UI-thread framework callback).
fn applyImmersive(activity: *ANativeActivity) void {
    const env_ptr = activity.env orelse {
        logWarn("immersive: ANativeActivity.env is null, skipping");
        return;
    };
    applyImmersiveWithEnv(env_ptr, activity.clazz);
}

/// Perform the JNI calls that hide the system bars with an **explicit**
/// `JNIEnv*` and the activity `jobject`. Split out from `applyImmersive`
/// to keep the env/object plumbing in one place; both callers pass the
/// UI-thread `activity.env`. `env_ptr` MUST be valid for the calling
/// (UI) thread; `activity_obj` is the activity instance
/// (`ANativeActivity.clazz`).
fn applyImmersiveWithEnv(env_ptr: *JNIEnv, activity_obj: jobject) void {
    // `env_ptr` is the `JNIEnv*` (a `*JNIEnv`). JNI functions take that
    // pointer as their first argument. `env_ptr.*` is the `JNIEnv`
    // (the table pointer); dereferencing again yields the interface
    // table struct whose slots we call.
    const env: *JNIEnv = env_ptr;
    const jni = env_ptr.*.*;

    // Two paths, picked at runtime by API level:
    //
    //   API 30+ (primary, verified on API 34) — Equivalent Java:
    //     WindowInsetsController c = activity.getWindow().getInsetsController();
    //     c.hide(WindowInsets.Type.systemBars());
    //     c.setSystemBarsBehavior(BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    //
    //   API 28/29 (fallback — `WindowInsetsController` does not exist
    //   there, project `min_sdk` is 28) — Equivalent Java:
    //     activity.getWindow().getDecorView()
    //             .setSystemUiVisibility(IMMERSIVE_FLAGS);
    //
    // The branch point is the `getInsetsController` method lookup: when
    // it succeeds we are on API 30+; when it is absent we are on API
    // 28/29 and fall through to `applyLegacyImmersive`.
    //
    // All method invocations use the `...A` jvalue-array variants — no
    // C-variadic calls; see the JNINativeInterface decl.
    //
    // JNI hops (API 30+ path):
    //   1. GetObjectClass(activity)               -> Activity class
    //   2. GetMethodID(Activity, "getWindow", "()Landroid/view/Window;")
    //   3. CallObjectMethodA(.., null)            -> Window object
    //   4. GetObjectClass(window)                 -> Window class
    //   5. GetMethodID(Window, "getInsetsController",
    //                  "()Landroid/view/WindowInsetsController;")
    //      -- null on API <30: fall back to the legacy path.
    //   6. CallObjectMethodA(.., null)            -> WindowInsetsController
    //   7. FindClass("android/view/WindowInsets$Type")
    //   8. GetStaticMethodID(.., "systemBars", "()I")
    //   9. CallStaticIntMethodA(..)               -> systemBars type mask
    //  10. GetObjectClass(controller)             -> controller class
    //  11. GetMethodID(.., "hide", "(I)V"); CallVoidMethodA(.., mask)
    //  12. GetMethodID(.., "setSystemBarsBehavior", "(I)V");
    //      CallVoidMethodA(.., BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE)

    const activity_class = jni.GetObjectClass(env, activity_obj) orelse {
        _ = clearException(env);
        logWarn("immersive: GetObjectClass(activity) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, activity_class);

    const get_window = jni.GetMethodID(env, activity_class, "getWindow", "()Landroid/view/Window;") orelse {
        _ = clearException(env);
        logWarn("immersive: getWindow methodID lookup failed");
        return;
    };
    const window = jni.CallObjectMethodA(env, activity_obj, get_window, null) orelse {
        _ = clearException(env);
        logWarn("immersive: getWindow() returned null");
        return;
    };
    defer jni.DeleteLocalRef(env, window);

    const window_class = jni.GetObjectClass(env, window) orelse {
        _ = clearException(env);
        logWarn("immersive: GetObjectClass(window) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, window_class);

    // `Window.getInsetsController()` exists only on API 30+. On API
    // 28/29 the lookup fails: clear the pending `NoSuchMethodError` and
    // fall back to the legacy `View.setSystemUiVisibility` path so those
    // devices still get immersive mode. (The supported device is API
    // 34, which takes the `WindowInsetsController` branch below.)
    const get_controller = jni.GetMethodID(env, window_class, "getInsetsController", "()Landroid/view/WindowInsetsController;") orelse {
        _ = clearException(env);
        logInfo("immersive: getInsetsController unavailable (API <30) — using legacy setSystemUiVisibility");
        applyLegacyImmersive(env, window, window_class);
        return;
    };
    const controller = jni.CallObjectMethodA(env, window, get_controller, null) orelse {
        _ = clearException(env);
        logWarn("immersive: getInsetsController() returned null");
        return;
    };
    defer jni.DeleteLocalRef(env, controller);

    // `WindowInsets.Type.systemBars()` — a static method on the nested
    // class `android.view.WindowInsets$Type` returning the int mask
    // that covers BOTH the status and the navigation bars.
    const type_class = jni.FindClass(env, "android/view/WindowInsets$Type") orelse {
        _ = clearException(env);
        logWarn("immersive: FindClass(WindowInsets$Type) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, type_class);

    const system_bars_mid = jni.GetStaticMethodID(env, type_class, "systemBars", "()I") orelse {
        _ = clearException(env);
        logWarn("immersive: systemBars() static methodID lookup failed");
        return;
    };
    const system_bars: jint = jni.CallStaticIntMethodA(env, type_class, system_bars_mid, null);
    if (clearException(env)) {
        logWarn("immersive: systemBars() threw");
        return;
    }

    const controller_class = jni.GetObjectClass(env, controller) orelse {
        _ = clearException(env);
        logWarn("immersive: GetObjectClass(controller) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, controller_class);

    // controller.hide(systemBars) — hides status + navigation bars.
    const hide_mid = jni.GetMethodID(env, controller_class, "hide", "(I)V") orelse {
        _ = clearException(env);
        logWarn("immersive: hide(I)V methodID lookup failed");
        return;
    };
    const hide_args = [_]jvalue{.{ .i = system_bars }};
    jni.CallVoidMethodA(env, controller, hide_mid, &hide_args);
    if (clearException(env)) {
        logWarn("immersive: WindowInsetsController.hide() threw");
        return;
    }

    // controller.setSystemBarsBehavior(BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE)
    // — immersive-sticky: bars reappear transiently on an edge swipe.
    const set_behavior_mid = jni.GetMethodID(env, controller_class, "setSystemBarsBehavior", "(I)V") orelse {
        _ = clearException(env);
        logWarn("immersive: setSystemBarsBehavior(I)V methodID lookup failed");
        return;
    };
    const behavior_args = [_]jvalue{.{ .i = BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE }};
    jni.CallVoidMethodA(env, controller, set_behavior_mid, &behavior_args);
    if (clearException(env)) {
        logWarn("immersive: setSystemBarsBehavior() threw");
        return;
    }

    logInfo("immersive: system bars hidden (WindowInsetsController, sticky)");
}

/// API 28/29 fallback: hide the system bars via the legacy
/// `View.setSystemUiVisibility(IMMERSIVE_FLAGS)`. Called by
/// `applyImmersive` only when `Window.getInsetsController` is absent
/// (i.e. the device is below API 30, where `WindowInsetsController`
/// does not exist). `WindowInsetsController` is preferred on API 30+;
/// this keeps Android 9/10 (the project's `min_sdk` floor of 28)
/// working instead of silently no-opping.
///
/// `window` / `window_class` are passed in already resolved by
/// `applyImmersive` so this path reuses the first four JNI hops.
/// Like the caller, runs on the UI thread and uses only the `...A`
/// jvalue-array call variants.
///
/// Equivalent Java:
///   activity.getWindow().getDecorView()
///           .setSystemUiVisibility(IMMERSIVE_FLAGS);
fn applyLegacyImmersive(env: *JNIEnv, window: jobject, window_class: jclass) void {
    const jni = env.*.*;

    const get_decor = jni.GetMethodID(env, window_class, "getDecorView", "()Landroid/view/View;") orelse {
        _ = clearException(env);
        logWarn("immersive(legacy): getDecorView methodID lookup failed");
        return;
    };
    const decor = jni.CallObjectMethodA(env, window, get_decor, null) orelse {
        _ = clearException(env);
        logWarn("immersive(legacy): getDecorView() returned null");
        return;
    };
    defer jni.DeleteLocalRef(env, decor);

    const view_class = jni.GetObjectClass(env, decor) orelse {
        _ = clearException(env);
        logWarn("immersive(legacy): GetObjectClass(decorView) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, view_class);

    const set_visibility = jni.GetMethodID(env, view_class, "setSystemUiVisibility", "(I)V") orelse {
        _ = clearException(env);
        logWarn("immersive(legacy): setSystemUiVisibility methodID lookup failed");
        return;
    };

    const args = [_]jvalue{.{ .i = IMMERSIVE_FLAGS }};
    jni.CallVoidMethodA(env, decor, set_visibility, &args);
    if (clearException(env)) {
        logWarn("immersive(legacy): setSystemUiVisibility() threw");
        return;
    }

    logInfo("immersive: system bars hidden (legacy setSystemUiVisibility, sticky)");
}

/// If a JNI exception is pending, describe + clear it. Returns true
/// when an exception was found. Leaving an exception pending poisons
/// every subsequent JNI call on the thread.
fn clearException(env: *JNIEnv) bool {
    const jni = env.*.*;
    const exc = jni.ExceptionOccurred(env);
    if (exc == null) return false;
    jni.ExceptionDescribe(env);
    jni.ExceptionClear(env);
    return true;
}

/// Enable Android immersive mode for the running game: hide the status
/// bar and the navigation bar in immersive-sticky mode.
///
/// Obtains the `ANativeActivity*` itself from labelle-core's
/// backend-agnostic Android seam (`core.android_backend.get()`), so the
/// caller (the assembler-generated `main.zig`) only needs a single
/// argument-free call. If no backend has registered an
/// `AndroidBackendContext`, this is a graceful no-op.
///
/// **Call site:** the assembler emits this in the generated
/// `main.zig`'s `sokol_main()`. sokol's `ANativeActivity_onCreate`
/// invokes `sokol_main()` **on the UI thread**, *before* it registers
/// its own `ANativeActivityCallbacks` — so this runs UI-thread-side and
/// early, with the `ANativeActivity*` already populated.
///
/// It does NOT touch the decor view itself (that would need the window
/// to exist and is deferred). It only installs `contentRectHook` into
/// the `onContentRectChanged` slot — a slot sokol leaves unset, so it
/// is not clobbered. The framework fires `onContentRectChanged` on the
/// UI thread once the content rect is established at launch; that first
/// invocation hides the bars **at launch**, and also chains
/// `onWindowFocusChanged` for the ongoing focus-regain re-apply.
///
/// On non-Android targets this is a no-op (the whole body is gated on
/// `is_android`), so the generated `main.zig` can call it
/// unconditionally for the `android` platform without `comptime`
/// branching of its own.
pub fn enableImmersiveMode() void {
    if (comptime !is_android) return;

    // Reach the running `ANativeActivity*` through core's backend seam.
    // No context registered → no backend ships Android JNI glue → there
    // is nothing to enable, so immersive mode is a graceful no-op.
    const ctx = core.android_backend.get() orelse {
        logWarn("immersive: no AndroidBackendContext registered");
        return;
    };
    const na: *ANativeActivity = @ptrCast(@alignCast(ctx.get_native_activity() orelse {
        logWarn("immersive: get_native_activity() returned null");
        return;
    }));

    // Atomic test-and-set install guard: if it was already `true`,
    // another caller (or an earlier call) already installed the hook.
    if (installed.swap(true, .seq_cst)) return;

    // Install our hook into `onContentRectChanged`. sokol's
    // `ANativeActivity_onCreate` leaves this slot unset (its
    // registration line is commented out), so — unlike
    // `onWindowFocusChanged`, which sokol overwrites moments after
    // `sokol_main()` returns — our pointer survives. The framework
    // fires it on the UI thread at launch; `contentRectHook` performs
    // the launch apply and chains the focus callback from there.
    na.callbacks.onContentRectChanged = &contentRectHook;

    logInfo("immersive: content-rect hook installed");
}

/// Hide the system bars from a **UI-thread** caller — the immersive entry
/// point for backends whose app shell owns the `ANativeActivityCallbacks`
/// (the bgfx backend, built on `native_app_glue`).
///
/// **Why a UI-thread entry, and why the hook-based `enableImmersiveMode()`
/// can't be used here.** native_app_glue OWNS `onContentRectChanged` (it
/// posts `APP_CMD_CONTENT_RECT_CHANGED`), so the engine's launch hook in
/// `enableImmersiveMode()` installs too late / clobbers the glue and never
/// fires. And the bars cannot be hidden from the glue's app thread (where
/// the game's frame loop runs): `WindowInsetsController.hide()` MUST run on
/// the Android UI/main thread — Android throws `CalledFromWrongThread`-style
/// exceptions otherwise, even from a thread freshly attached to the JVM
/// (verified on-device: a frame-loop call attached the thread fine but the
/// `hide()` JNI call still threw).
///
/// So the bgfx shell instead chains `onWindowFocusChanged` — a framework
/// callback the OS invokes ON THE UI THREAD, at launch (first focus gain)
/// and on every focus regain — and calls THIS function from there (via the
/// shell's `setImmersiveCallback`). Running on the UI thread, the activity's
/// own `ANativeActivity.env` is the correct `JNIEnv*`, so `applyImmersive`
/// works exactly as it does on the sokol callback path.
///
/// `callconv(.c)` so the shell can store it as a bare C function pointer
/// without importing the engine (the shell must not depend on the engine;
/// the generated `main.zig`, which owns both, wires them together).
///
/// Idempotent — safe to call on every focus gain. The activity is resolved
/// through the same backend-agnostic seam (`core.android_backend.get()`) as
/// `enableImmersiveMode`, so the engine still links no backend symbol. A
/// graceful no-op on non-Android targets, when no `AndroidBackendContext`
/// is registered, or before the activity exists.
pub fn applyImmersiveUiThread() callconv(.c) void {
    if (comptime !is_android) return;

    // Same backend-agnostic activity lookup as `enableImmersiveMode`.
    const ctx = core.android_backend.get() orelse {
        logWarn("immersive: no AndroidBackendContext registered");
        return;
    };
    const na: *ANativeActivity = @ptrCast(@alignCast(ctx.get_native_activity() orelse {
        logWarn("immersive: get_native_activity() returned null");
        return;
    }));

    // Called on the UI thread (from the shell's chained
    // `onWindowFocusChanged`), so `na.env` is the correct `JNIEnv*` and the
    // decor-view / WindowInsetsController JNI calls are thread-legal.
    applyImmersive(na);
}
