#!/usr/bin/env bash
# build-local.sh — build the ente Photos release APK on Linux x86_64 or macOS
#
# Prerequisites installed automatically if absent:
#   - Flutter 3.32.8
#   - Android SDK (platform 36, build-tools 35.0.1, NDK 26.1.10909125 + NDK 28.0.13004108)
#   Note: Flutter 3.32.8 defaults all Gradle subprojects to NDK 26.1.10909125, so both
#         NDK versions must be present. NDK 28 is used by the app; NDK 26 by Flutter plugins.
#   - Rust Android targets (if rustup is available)
#   - flutter_rust_bridge_codegen (if Rust bindings are missing)
#
# Java 11+ must already be installed (brew install --cask temurin on macOS).
#
# Output: build/app/outputs/flutter-apk/app-independent-release.apk
#
# Usage:
#   cd mobile/apps/photos
#   bash build-local.sh
#
# Environment variables (optional):
#   FLUTTER_ROOT  — path to existing Flutter SDK (skips download)
#   ANDROID_HOME  — path to existing Android SDK (skips SDK setup)
#   HTTP_PROXY    — proxy URL if required (http://user:pass@host:port)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Linux*)  PLATFORM="linux" ;;
  Darwin*) PLATFORM="macos" ;;
  *)       echo "ERROR: Unsupported OS: $OS" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
FLUTTER_VERSION="3.32.8"
case "$PLATFORM" in
  linux)
    FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
    NDK_ARCHIVE="android-ndk-r28-linux.zip"
    ;;
  macos)
    FLUTTER_ARCHIVE="flutter_macos_${FLUTTER_VERSION}-stable.zip"
    NDK_ARCHIVE="android-ndk-r28-darwin.zip"
    ;;
esac

FLUTTER_BASE_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/${PLATFORM}"
FLUTTER_URL="${FLUTTER_BASE_URL}/${FLUTTER_ARCHIVE}"

ANDROID_COMPILE_SDK="36"
ANDROID_BUILD_TOOLS="35.0.1"
NDK_VERSION="28.0.13004108"       # used by app/build.gradle
NDK_FLUTTER_VERSION="26.1.10909125" # Flutter 3.32.8 default for all subprojects
NDK_URL="https://dl.google.com/android/repository/${NDK_ARCHIVE}"
NDK_FLUTTER_URL="https://dl.google.com/android/repository/android-ndk-r26c-${PLATFORM}.zip"

FLUTTER_ROOT="${FLUTTER_ROOT:-${HOME}/flutter}"
ANDROID_HOME="${ANDROID_HOME:-${HOME}/android-sdk}"

PROXY_ARGS=()
if [[ -n "${HTTP_PROXY:-}" ]]; then
  PROXY_ARGS=(--proxy "$HTTP_PROXY")
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" &>/dev/null || die "'$1' is required but not found. Install it and retry."
}

curl_dl() {
  local url="$1" dest="$2"
  curl -fL --progress-bar "${PROXY_ARGS[@]}" "$url" -o "$dest"
}

extract_archive() {
  local archive="$1" dest_dir="$2"
  mkdir -p "$dest_dir"
  case "$archive" in
    *.tar.xz) tar xf "$archive" -C "$dest_dir" ;;
    *.zip)    unzip -q "$archive" -d "$dest_dir" ;;
    *)        die "Unknown archive format: $archive" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Flutter
# ---------------------------------------------------------------------------
if [[ -x "${FLUTTER_ROOT}/bin/flutter" ]]; then
  info "Flutter found at ${FLUTTER_ROOT}, skipping download."
else
  info "Downloading Flutter ${FLUTTER_VERSION} for ${PLATFORM}…"
  require_cmd curl
  curl_dl "$FLUTTER_URL" "/tmp/${FLUTTER_ARCHIVE}"
  info "Extracting Flutter…"
  mkdir -p "$(dirname "${FLUTTER_ROOT}")"
  extract_archive "/tmp/${FLUTTER_ARCHIVE}" "$(dirname "${FLUTTER_ROOT}")"
  git config --global --add safe.directory "${FLUTTER_ROOT}" 2>/dev/null || true
fi
export PATH="${FLUTTER_ROOT}/bin:${PATH}"
flutter --version

# ---------------------------------------------------------------------------
# 2. Android SDK
# ---------------------------------------------------------------------------
SDK_READY=false
if [[ -d "${ANDROID_HOME}/platforms/android-${ANDROID_COMPILE_SDK}" ]] && \
   [[ -d "${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}" ]]; then
  SDK_READY=true
fi

if $SDK_READY; then
  info "Android SDK found at ${ANDROID_HOME}, skipping SDK setup."
else
  info "Setting up Android SDK at ${ANDROID_HOME}…"
  require_cmd curl
  require_cmd unzip

  mkdir -p "${ANDROID_HOME}"/{cmdline-tools,platform-tools,platforms,build-tools,ndk}

  # Command-line tools
  info "  Downloading command-line tools…"
  case "$PLATFORM" in
    linux)  CMDLT_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" ;;
    macos)  CMDLT_URL="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip" ;;
  esac
  curl_dl "$CMDLT_URL" /tmp/cmdlt.zip
  unzip -q /tmp/cmdlt.zip -d /tmp/cmdlt-ext
  mv /tmp/cmdlt-ext/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"

  # Platform tools
  info "  Downloading platform-tools…"
  case "$PLATFORM" in
    linux)  PT_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip" ;;
    macos)  PT_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" ;;
  esac
  curl_dl "$PT_URL" /tmp/pt.zip
  unzip -q /tmp/pt.zip -d /tmp/pt-ext
  cp -r /tmp/pt-ext/platform-tools/. "${ANDROID_HOME}/platform-tools/"

  # android-36
  info "  Downloading android-${ANDROID_COMPILE_SDK}…"
  curl_dl "https://dl.google.com/android/repository/platform-${ANDROID_COMPILE_SDK}_r01.zip" /tmp/platform.zip
  mkdir -p "${ANDROID_HOME}/platforms/android-${ANDROID_COMPILE_SDK}"
  unzip -q /tmp/platform.zip -d /tmp/platform-ext
  mv /tmp/platform-ext/android-${ANDROID_COMPILE_SDK}/* "${ANDROID_HOME}/platforms/android-${ANDROID_COMPILE_SDK}/"

  # build-tools 35.0.1
  info "  Downloading build-tools ${ANDROID_BUILD_TOOLS}…"
  curl_dl "https://dl.google.com/android/repository/build-tools_r35.0.1_linux.zip" /tmp/bt.zip
  mkdir -p "${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}"
  unzip -q /tmp/bt.zip -d /tmp/bt-ext
  # The zip top-level dir name varies; find it
  BT_INNER=$(find /tmp/bt-ext -maxdepth 1 -mindepth 1 -type d | head -1)
  mv "${BT_INNER}"/* "${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS}/"

  # Accept licenses
  mkdir -p "${ANDROID_HOME}/licenses"
  printf "24333f8a63b6825ea9c5514f83c2829b004d1fee\n8933bad161af4178b1185d1a37fbf41ea5269c55\n" \
    > "${ANDROID_HOME}/licenses/android-sdk-license"
  printf "84831b9409646a918e30573bab4c9c91346d8abd\n" \
    > "${ANDROID_HOME}/licenses/android-sdk-preview-license"
fi

# NDK
NDK_DIR="${ANDROID_HOME}/ndk/${NDK_VERSION}"
if [[ -f "${NDK_DIR}/source.properties" ]]; then
  info "NDK ${NDK_VERSION} already present."
else
  info "Downloading NDK ${NDK_VERSION}…"
  curl_dl "$NDK_URL" /tmp/ndk.zip
  mkdir -p "${NDK_DIR}"
  unzip -q /tmp/ndk.zip -d /tmp/ndk-ext
  NDK_INNER=$(find /tmp/ndk-ext -maxdepth 1 -name "android-ndk-*" -type d | head -1)
  mv "${NDK_INNER}"/* "${NDK_DIR}/"
fi

# NDK 26.1.10909125 (Flutter 3.32.8 default for all Gradle subprojects)
NDK_FLUTTER_DIR="${ANDROID_HOME}/ndk/${NDK_FLUTTER_VERSION}"
if [[ -f "${NDK_FLUTTER_DIR}/source.properties" ]]; then
  info "NDK ${NDK_FLUTTER_VERSION} already present."
else
  info "Downloading NDK ${NDK_FLUTTER_VERSION} (r26c, required by Flutter plugin subprojects)…"
  curl_dl "$NDK_FLUTTER_URL" /tmp/ndk26.zip
  mkdir -p "${NDK_FLUTTER_DIR}"
  unzip -q /tmp/ndk26.zip -d /tmp/ndk26-ext
  NDK26_INNER=$(find /tmp/ndk26-ext -maxdepth 1 -name "android-ndk-*" -type d | head -1)
  mv "${NDK26_INNER}"/* "${NDK_FLUTTER_DIR}/"
fi

export ANDROID_HOME
export ANDROID_NDK_HOME="${NDK_DIR}"
export PATH="${ANDROID_HOME}/platform-tools:${PATH}"

flutter config --android-sdk "${ANDROID_HOME}" --no-analytics

# Write local.properties
# Do NOT set ndk.dir: the app specifies ndkVersion=28, Flutter plugins default to ndkVersion=26.
# With both NDK versions installed under $ANDROID_HOME/ndk/, Gradle resolves each automatically.
cat > "${SCRIPT_DIR}/android/local.properties" <<EOF
sdk.dir=${ANDROID_HOME}
flutter.sdk=${FLUTTER_ROOT}
EOF

# ---------------------------------------------------------------------------
# 3. Rust Android targets (needed for Flutter Rust Bridge)
# ---------------------------------------------------------------------------
if command -v rustup &>/dev/null; then
  info "Adding Rust Android target (arm64 only)…"
  rustup target add aarch64-linux-android
else
  info "rustup not found — install Rust from https://rustup.rs/ if the Rust build fails."
fi

# ---------------------------------------------------------------------------
# 4. Flutter Rust Bridge codegen (lib/src/rust/ is gitignored)
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/lib/src/rust/frb_generated.dart" ]]; then
  info "Generating Rust bindings (flutter_rust_bridge_codegen)…"
  require_cmd cargo
  if ! command -v flutter_rust_bridge_codegen &>/dev/null; then
    cargo install flutter_rust_bridge_codegen
  fi
  (cd "${SCRIPT_DIR}" && flutter_rust_bridge_codegen generate)
fi

# ---------------------------------------------------------------------------
# 5. Gradle proxy (only needed when HTTP_PROXY is set — e.g. in CI containers)
# ---------------------------------------------------------------------------
if [[ -n "${HTTP_PROXY:-}" ]]; then
  info "Writing Gradle proxy settings…"
  python3 - <<'PYEOF'
import re, os
proxy = os.environ.get('HTTP_PROXY', '')
m = re.match(r'https?://([^:@]+):([^@]+)@([^:]+):(\d+)', proxy)
if not m:
    print("  WARNING: Could not parse HTTP_PROXY — skipping Gradle proxy config.")
else:
    user, pw, host, port = m.groups()
    os.makedirs(os.path.expanduser('~/.gradle'), exist_ok=True)
    with open(os.path.expanduser('~/.gradle/gradle.properties'), 'w') as f:
        for proto in ('http', 'https'):
            f.write(f"systemProp.{proto}.proxyHost={host}\n")
            f.write(f"systemProp.{proto}.proxyPort={port}\n")
            f.write(f"systemProp.{proto}.proxyUser={user}\n")
            f.write(f"systemProp.{proto}.proxyPassword={pw}\n")
        f.write("systemProp.http.nonProxyHosts=localhost|127.0.0.1\n")
    print("  ~/.gradle/gradle.properties written.")
PYEOF
fi

# ---------------------------------------------------------------------------
# 6. Pre-download media_kit JARs
#    media_kit_libs_android_video uses `new URL().openStream()` to fetch its
#    native JARs, which bypasses gradle.properties proxy auth on some JVMs.
#    Pre-downloading with curl (which honours $HTTP_PROXY) avoids the issue.
# ---------------------------------------------------------------------------
MEDIA_KIT_VERSION="v1.1.5"
MEDIA_KIT_URL="https://github.com/media-kit/libmpv-android-video-build/releases/download/${MEDIA_KIT_VERSION}"
MEDIA_KIT_CACHE="${SCRIPT_DIR}/build/media_kit_libs_android_video/${MEDIA_KIT_VERSION}"
declare -A MEDIA_KIT_MD5=(
  ["default-arm64-v8a.jar"]="5f521b08692d7fef73c5df9bcc00ca4d"
  ["default-armeabi-v7a.jar"]="08d500ca1116c13e9c1296cc6f2207b0"
  ["default-x86_64.jar"]="0880d5fbc3ff0053409704617f54cb55"
  ["default-x86.jar"]="f6f51aa42b30d747099506cdc3277352"
)
mkdir -p "${MEDIA_KIT_CACHE}"
for jar_name in "${!MEDIA_KIT_MD5[@]}"; do
  dest="${MEDIA_KIT_CACHE}/${jar_name}"
  expected_md5="${MEDIA_KIT_MD5[$jar_name]}"
  if [[ -f "$dest" ]]; then
    actual_md5=$(md5sum "$dest" 2>/dev/null | cut -d' ' -f1 || md5 -q "$dest" 2>/dev/null || echo "")
    [[ "$actual_md5" == "$expected_md5" ]] && continue
    info "  MD5 mismatch for ${jar_name}, re-downloading…"
    rm -f "$dest"
  fi
  info "  Downloading media_kit ${jar_name}…"
  curl_dl "${MEDIA_KIT_URL}/${jar_name}" "$dest"
done

# ---------------------------------------------------------------------------
# 7. Build
# ---------------------------------------------------------------------------
cd "${SCRIPT_DIR}"
info "Running flutter pub get…"
flutter pub get

info "Building release APK (flavor: independent, arm64 only)…"
flutter build apk --release --flavor independent --target-platform android-arm64

APK="${SCRIPT_DIR}/build/app/outputs/flutter-apk/app-independent-release.apk"
if [[ -f "$APK" ]]; then
  SIZE=$(du -h "$APK" | cut -f1)
  info "Done!  APK: ${APK}  (${SIZE})"
else
  die "APK not found after build — check the output above for errors."
fi
