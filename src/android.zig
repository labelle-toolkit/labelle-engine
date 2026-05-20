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
//! from sokol_app's `sapp_android_get_native_activity()` (bound here as
//! an `extern "c"` symbol), which exposes a `JavaVM*`, a main-thread
//! `JNIEnv*`, and the activity `jobject`.
//!
//! We use the **legacy `View.setSystemUiVisibility`** API with the
//! `IMMERSIVE_STICKY | HIDE_NAVIGATION | FULLSCREEN | LAYOUT_*` flag
//! set. Rationale:
//!   - It works unchanged on API 19..34. It is deprecated at API 30+
//!     but still fully functional at target SDK 34 (the device under
//!     test). The newer `WindowInsetsController` needs many more JNI
//!     object hops (`getInsetsController` → `WindowInsets.Type` static
//!     → two method calls) for no on-device behaviour difference here.
//!   - Immersive-*sticky* is exactly the requested behaviour: the bars
//!     slide away, a swipe from the edge brings them back transiently,
//!     and they auto-hide again.
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
//! JNI — painful with no Java code), we **chain the
//! `ANativeActivityCallbacks.onWindowFocusChanged` callback**. The
//! framework invokes that callback *on the UI thread*, and the
//! `ANativeActivity.env` field is the valid UI-thread `JNIEnv*` while
//! it runs. We save sokol's original callback pointer, install our own
//! that calls the original and then applies the immersive flags. No
//! thread attach, no `Runnable`, no wrong-thread exception.
//!
//! `onWindowFocusChanged(hasFocus=true)` also fires every time the app
//! regains focus (returning from the notification shade, the recents
//! switcher, etc.), which is precisely when immersive-sticky flags can
//! get cleared — so the same hook doubles as the re-apply hook for
//! free. The first invocation at startup performs the initial apply.

const std = @import("std");
const builtin = @import("builtin");

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
/// ordering matches `struct JNINativeInterface` in `jni.h`; unused
/// slots are typed `*const anyopaque` so we never depend on their
/// signatures. `JNIEnv` is a pointer to a pointer to this table.
const JNINativeInterface = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    reserved3: ?*anyopaque,
    GetVersion: *const anyopaque,
    DefineClass: *const anyopaque,
    FindClass: *const fn (*JNIEnv, [*:0]const u8) callconv(.c) jclass,
    FromReflectedMethod: *const anyopaque,
    FromReflectedField: *const anyopaque,
    ToReflectedMethod: *const anyopaque,
    GetSuperclass: *const anyopaque,
    IsAssignableFrom: *const anyopaque,
    ToReflectedField: *const anyopaque,
    Throw: *const anyopaque,
    ThrowNew: *const anyopaque,
    ExceptionOccurred: *const fn (*JNIEnv) callconv(.c) jobject,
    ExceptionDescribe: *const fn (*JNIEnv) callconv(.c) void,
    ExceptionClear: *const fn (*JNIEnv) callconv(.c) void,
    FatalError: *const anyopaque,
    PushLocalFrame: *const anyopaque,
    PopLocalFrame: *const anyopaque,
    NewGlobalRef: *const anyopaque,
    DeleteGlobalRef: *const anyopaque,
    DeleteLocalRef: *const fn (*JNIEnv, jobject) callconv(.c) void,
    IsSameObject: *const anyopaque,
    NewLocalRef: *const anyopaque,
    EnsureLocalCapacity: *const anyopaque,
    AllocObject: *const anyopaque,
    NewObject: *const anyopaque,
    NewObjectV: *const anyopaque,
    NewObjectA: *const anyopaque,
    GetObjectClass: *const fn (*JNIEnv, jobject) callconv(.c) jclass,
    IsInstanceOf: *const anyopaque,
    GetMethodID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    // The `Call*Method` slots are C-variadic (`...`) in jni.h. Calling
    // a C-variadic function from Zig on AArch64 has a fragile ABI (the
    // JVM mis-reads the vararg registers/stack), which crashes the
    // process. We therefore use ONLY the `...A` variants, which take a
    // `const jvalue*` argument array — a fixed, non-variadic signature
    // with a rock-solid ABI. The plain variadic slots stay opaque so
    // we can never accidentally call them.
    CallObjectMethod: *const anyopaque,
    CallObjectMethodV: *const anyopaque,
    CallObjectMethodA: *const fn (*JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jobject,
    CallBooleanMethod: *const anyopaque,
    CallBooleanMethodV: *const anyopaque,
    CallBooleanMethodA: *const anyopaque,
    CallByteMethod: *const anyopaque,
    CallByteMethodV: *const anyopaque,
    CallByteMethodA: *const anyopaque,
    CallCharMethod: *const anyopaque,
    CallCharMethodV: *const anyopaque,
    CallCharMethodA: *const anyopaque,
    CallShortMethod: *const anyopaque,
    CallShortMethodV: *const anyopaque,
    CallShortMethodA: *const anyopaque,
    CallIntMethod: *const anyopaque,
    CallIntMethodV: *const anyopaque,
    CallIntMethodA: *const anyopaque,
    CallLongMethod: *const anyopaque,
    CallLongMethodV: *const anyopaque,
    CallLongMethodA: *const anyopaque,
    CallFloatMethod: *const anyopaque,
    CallFloatMethodV: *const anyopaque,
    CallFloatMethodA: *const anyopaque,
    CallDoubleMethod: *const anyopaque,
    CallDoubleMethodV: *const anyopaque,
    CallDoubleMethodA: *const anyopaque,
    CallVoidMethod: *const anyopaque,
    CallVoidMethodV: *const anyopaque,
    CallVoidMethodA: *const fn (*JNIEnv, jobject, jmethodID, ?[*]const jvalue) callconv(.c) void,
    // Remaining ~160 slots are unused. Represent the tail as an opaque
    // blob so the struct size is irrelevant (we only ever index slots
    // at or before `CallVoidMethodA` and reach the table by pointer).
    _tail: [200]?*anyopaque,
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
    onContentRectChanged: ?*const anyopaque,
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

// `View.setSystemUiVisibility` flag bits (from `android.view.View`).
// Combined they give immersive-STICKY: bars hidden, a swipe brings
// them back transiently, then they auto-hide again.
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

// ── sokol_app native-activity accessor ────────────────────────────
//
// sokol_app's Android backend exposes the `ANativeActivity*` via this
// C entry point (`SOKOL_API_IMPL`, i.e. an exported symbol). We bind
// it as an `extern "c"` function so the engine never has to
// `@import("sokol")` — the symbol resolves at link time against the
// `sokol_clib` static library every sokol-Android build links anyway.
extern "c" fn sapp_android_get_native_activity() ?*anyopaque;

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

/// Install guard. `swap(true)` makes the install an atomic
/// test-and-set so a double `enableImmersiveMode()` can't double-chain.
var installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

/// Perform the JNI calls that hide the system bars. MUST be called on
/// the Android UI thread (the `onWindowFocusChanged` callback is).
fn applyImmersive(activity: *ANativeActivity) void {
    const env_ptr = activity.env orelse {
        logWarn("immersive: ANativeActivity.env is null, skipping");
        return;
    };
    // `env_ptr` is the `JNIEnv*` (a `*JNIEnv`). JNI functions take that
    // pointer as their first argument. `env_ptr.*` is the `JNIEnv`
    // (the table pointer); dereferencing again yields the interface
    // table struct whose slots we call.
    const env: *JNIEnv = env_ptr;
    const jni = env_ptr.*.*;

    // Equivalent Java:
    //   activity.getWindow().getDecorView().setSystemUiVisibility(FLAGS)
    //
    // JNI hops (all method invocations use the `...A` jvalue-array
    // variants — no C-variadic calls; see the JNINativeInterface decl):
    //   1. GetObjectClass(activity)               -> Activity class
    //   2. GetMethodID(Activity, "getWindow", "()Landroid/view/Window;")
    //   3. CallObjectMethodA(.., null)            -> Window object
    //   4. GetObjectClass(window)                 -> Window class
    //   5. GetMethodID(Window, "getDecorView", "()Landroid/view/View;")
    //   6. CallObjectMethodA(.., null)            -> decorView object
    //   7. GetObjectClass(decorView)              -> View class
    //   8. GetMethodID(View, "setSystemUiVisibility", "(I)V")
    //   9. CallVoidMethodA(decorView, .., &[FLAGS])

    const activity_class = jni.GetObjectClass(env, activity.clazz) orelse {
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
    const window = jni.CallObjectMethodA(env, activity.clazz, get_window, null) orelse {
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

    const get_decor = jni.GetMethodID(env, window_class, "getDecorView", "()Landroid/view/View;") orelse {
        _ = clearException(env);
        logWarn("immersive: getDecorView methodID lookup failed");
        return;
    };
    const decor = jni.CallObjectMethodA(env, window, get_decor, null) orelse {
        _ = clearException(env);
        logWarn("immersive: getDecorView() returned null");
        return;
    };
    defer jni.DeleteLocalRef(env, decor);

    const view_class = jni.GetObjectClass(env, decor) orelse {
        _ = clearException(env);
        logWarn("immersive: GetObjectClass(decorView) failed");
        return;
    };
    defer jni.DeleteLocalRef(env, view_class);

    const set_visibility = jni.GetMethodID(env, view_class, "setSystemUiVisibility", "(I)V") orelse {
        _ = clearException(env);
        logWarn("immersive: setSystemUiVisibility methodID lookup failed");
        return;
    };

    const args = [_]jvalue{.{ .i = IMMERSIVE_FLAGS }};
    jni.CallVoidMethodA(env, decor, set_visibility, &args);
    if (clearException(env)) {
        logWarn("immersive: setSystemUiVisibility() threw");
        return;
    }

    logInfo("immersive: system bars hidden (immersive-sticky)");
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
/// Obtains the `ANativeActivity*` itself from sokol_app via
/// `sapp_android_get_native_activity()`, so the caller (the assembler-
/// generated `main.zig`) only needs a single argument-free call.
///
/// Call this once from the generated `main.zig`'s `init` callback when
/// the project's `immersive_mode` flag is set. It is safe to call from
/// the sokol render thread: this function does NOT touch the decor
/// view itself — it only installs a UI-thread callback hook. The
/// actual bar-hiding runs later inside `onWindowFocusChanged` on the
/// UI thread, which also re-applies the flags on every focus regain.
///
/// On non-Android targets this is a no-op (the whole body is gated on
/// `is_android`), so the generated `main.zig` can call it
/// unconditionally for the `android` platform without `comptime`
/// branching of its own.
pub fn enableImmersiveMode() void {
    if (comptime !is_android) return;

    const na: *ANativeActivity = @ptrCast(@alignCast(sapp_android_get_native_activity() orelse {
        logWarn("immersive: sapp_android_get_native_activity() returned null");
        return;
    }));

    // Atomic test-and-set install guard: if it was already `true`,
    // another caller (or an earlier call) already installed the hook.
    if (installed.swap(true, .seq_cst)) return;

    // Chain the focus callback. Saving the original keeps sokol's own
    // RESUMED/SUSPENDED lifecycle handling intact.
    //
    // Ordering is load-bearing: publish `saved_focus_cb` *before*
    // writing `focusChangedHook` into the callbacks struct. The hook
    // can only fire once the framework sees the new callback pointer,
    // so storing the original first guarantees `focusChangedHook`
    // never reads a `saved_focus_cb` that hasn't been written yet.
    const orig_bits: usize = if (na.callbacks.onWindowFocusChanged) |cb|
        @intFromPtr(cb)
    else
        0;
    saved_focus_cb.store(orig_bits, .seq_cst);
    na.callbacks.onWindowFocusChanged = &focusChangedHook;

    logInfo("immersive: focus-callback hook installed");
}
