# Android Bouncing Ball Demo

A colorful bouncing ball demo for Android using labelle-engine with sokol GLES3 backend.

## Prerequisites

1. **Android SDK** with:
   - SDK Platform 34
   - Build Tools 34.0.0
   - NDK 26.1.10909125

2. **Environment Variables**:
   ```bash
   export ANDROID_HOME=$HOME/Library/Android/sdk  # macOS
   # or
   export ANDROID_HOME=$HOME/Android/Sdk          # Linux
   ```

## Building

### Build the Native Library

```bash
# Build for arm64-v8a (aarch64)
zig build android

# Output: zig-out/lib/libBouncingBall.so
```

### Create APK

#### Option 1: Using Android Studio (Recommended)

1. Create a new Android Studio project with "Native C++" template
2. Replace the default native library with our built `.so`:
   ```
   app/src/main/jniLibs/arm64-v8a/libBouncingBall.so
   ```
3. Update `AndroidManifest.xml` to use `NativeActivity`:
   ```xml
   <activity
       android:name="android.app.NativeActivity"
       android:label="Bouncing Ball"
       android:configChanges="orientation|screenSize|screenLayout|keyboardHidden"
       android:exported="true">
       <meta-data
           android:name="android.app.lib_name"
           android:value="BouncingBall" />
       <intent-filter>
           <action android:name="android.intent.action.MAIN" />
           <category android:name="android.intent.category.LAUNCHER" />
       </intent-filter>
   </activity>
   ```
4. Build APK from Android Studio

#### Option 2: Using Command Line Tools

1. Create the APK structure:
   ```bash
   mkdir -p apk/lib/arm64-v8a
   cp zig-out/lib/libBouncingBall.so apk/lib/arm64-v8a/
   ```

2. Generate a debug keystore (if you don't have one):
   ```bash
   keytool -genkeypair -keystore debug.keystore -alias androiddebugkey \
       -keyalg RSA -keysize 2048 -validity 10000 \
       -storepass android -keypass android -dname "CN=Debug,O=Debug,C=US"
   ```

3. Compile resources and create APK:
   ```bash
   # Using aapt2 (from SDK build-tools)
   $ANDROID_HOME/build-tools/34.0.0/aapt2 link \
       --proto-format \
       -o app.apk \
       -I $ANDROID_HOME/platforms/android-34/android.jar \
       --manifest AndroidManifest.xml \
       --auto-add-overlay

   # Add native library
   zip -r app.apk lib/

   # Align
   $ANDROID_HOME/build-tools/34.0.0/zipalign -v 4 app.apk app-aligned.apk

   # Sign
   $ANDROID_HOME/build-tools/34.0.0/apksigner sign \
       --ks debug.keystore \
       --ks-pass pass:android \
       app-aligned.apk
   ```

## Installing

```bash
# Install on connected device/emulator
adb install app-aligned.apk

# Or push directly to device
adb push zig-out/lib/libBouncingBall.so /data/local/tmp/
```

## Debug Build vs Release

For release builds, optimize and strip:
```bash
zig build android -Doptimize=ReleaseSmall

# Strip debug symbols (optional, reduces size significantly)
$ANDROID_HOME/ndk/26.1.10909125/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip \
    zig-out/lib/libBouncingBall.so
```

## Architecture Support

Currently builds for:
- `arm64-v8a` (aarch64) - Modern Android devices

To add support for other architectures, modify `build.zig` to include additional targets.

## Troubleshooting

### App crashes on start
- Ensure your device supports OpenGL ES 3.0
- Check logcat for detailed error messages: `adb logcat -s BouncingBall`

### Library not found
- Verify the library is in `jniLibs/arm64-v8a/`
- Check that `android:value` in manifest matches library name (without `lib` prefix and `.so` suffix)

### Touch not working
- Touch events are handled in `event()` callback - verify sokol_app is receiving events
