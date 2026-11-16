#!/usr/bin/env bash
# Build/run helper for PocketBook Qt apps (firmware 6.10 with the B288 or B300 SDK, or
# 6.11 with the RK3566 SDK).
#
#   pb setup                 download the selected SDK and build the container image
#   pb new   <dir>           start a new app in <dir>, from the hello-pocketbook skeleton
#   pb run   [app-dir]       build for PC and open it in the emulator window
#   pb pc    [app-dir]       build for PC             -> build/<app>/<sdk>/pc/<app>.app
#   pb arm   [app-dir]       cross-compile for device -> build/<app>/<sdk>/arm/<app>.app
#   pb test  [app-dir]       build for PC, then build the app's tests/tests.pro and run its
#                            tests (make check) on Qt's offscreen platform
#   pb drive <app-dir> <script> [args]
#                            build for PC, then run a bash script beside the emulator on a
#                            virtual display (Xvfb): the script starts "$PB_APP" itself and
#                            can drive it with xdotool and take screenshots with import;
#                            the script's folder is /test, for saving them
#   pb shell [app-dir]       shell inside the build container (SDK env vars set)
#   pb clean [app-dir]       remove build/<app>
#   pb sdks                  list the SDKs, which are downloaded and which is selected
#   pb use   <sdk>           select an SDK for later commands, e.g. pb use B300-6.10
#   pb device                make the emulator look like your PocketBook (see the README):
#   pb device export [mount]   build the export tool, copy it to the device if mounted
#   pb device import <mount>   take in what it exported and save the theme's icons
#   pb device remove           go back to the SDK's own emulator
#
# app-dir is any folder containing one .pro file, and defaults to the current folder.
# Builds go to build/ in the current folder; PB_BUILD_DIR=<dir> puts them elsewhere.
#
# PB_QMAKE_ARGS adds arguments to qmake, e.g. for a build with an app's build-time
# setting: PB_QMAKE_ARGS="SUGGESTED_SERVER=books.example.com" pb arm
#
# PB_APP_VERSION sets the app's version (pb_build.h's PB_APP_VERSION) instead of git
# describe, e.g. to try an app's updates with a build that seems older: PB_APP_VERSION=0.9.0
#
# PB_ENV sets environment variables for the app in pb run, pb test and pb drive, as NAME=value
# pairs separated by spaces (values can't contain spaces): PB_ENV="MYAPP_DEBUG=1" pb run
#
# SDKs, the selected SDK and the device files are kept in PB_HOME, by default
# ~/.local/share/pocketbook-kit, and shared by every app. The SDK is B288-6.10 unless
# pb use picked another; PB_SDK=<sdk> overrides it for one command. Uses podman if
# installed, otherwise docker; set PB_ENGINE=docker to force docker.
#
# The SDK's tools are hardcoded to a folder in /BUILD (/BUILD/SDK-<sdk> for 6.10) and need
# the libraries of one Debian release (Bookworm for 6.10, Trixie for 6.11), so everything
# runs in a container of that release with the SDK mounted there.
set -euo pipefail

# SDKs from https://github.com/Sean-on-Git/PocketBook-SDK/releases: release tag and
# SHA-256 of the archive (shown on the release page). B288 covers most devices from
# Touch Lux 5 to InkPad X. B300 is listed for the InkPad Color 2, but the Era Color
# (PB700K3) is also a B300 device: its hwconfig reports PLATFORM_B300. RK3566 is the only
# 6.11 SDK published so far, for the 1030. Firmware 6.11 also reached B288 devices (Era,
# Verse Pro, InkPad 4 and others, October 2026), but there is no B288 or B300 6.11 SDK.
declare -A SDK_RELEASE=([B288-6.10]=6.10 [B300-6.10]=6.10 [RK3566-6.11]=6.11)
declare -A SDK_SHA256=(
    [B288-6.10]=18405fb276535d53a4b70d2bbf4033313cded58da5002d563ccf7e1838440c0b
    [B300-6.10]=a201544dd7baa9aeef4d1afa420c2120bf250ff1da5c8dfdc47cd247ccb143b5
    [RK3566-6.11]=a92deed99dc3a09df48970467626b19467661795615ecd9307b3aac1382b4307
)
# How each SDK is laid out: the folder at the top of its archive, which is also where in
# /BUILD its tools expect to be; where in that folder its usr tree is (local/ with the
# desktop Qt and libinkview, and the toolchain); and the toolchain's name, for its sysroot.
# The 6.11 SDK is a Buildroot SDK, with no usr/ folder of its own.
declare -A SDK_TOP=(
    [B288-6.10]=SDK-B288-6.10 [B300-6.10]=SDK-B300-6.10
    [RK3566-6.11]=arm-buildroot-linux-gnueabihf_sdk-buildroot
)
declare -A SDK_USR=([B288-6.10]=/usr [B300-6.10]=/usr [RK3566-6.11]=)
declare -A SDK_TRIPLET=(
    [B288-6.10]=arm-obreey-linux-gnueabi [B300-6.10]=arm-obreey-linux-gnueabi
    [RK3566-6.11]=arm-buildroot-linux-gnueabihf
)
DEFAULT_SDK=B288-6.10

# The kit: the folder this script is in, also when it's run through a symlink on PATH
KIT_DIR=$(dirname "$(realpath "$0")")
PB_HOME=${PB_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pocketbook-kit}
SDK_CHOICE_FILE=$PB_HOME/sdk
DEVICE_DIR=$PB_HOME/device
BUILD_ROOT=$(realpath -m "${PB_BUILD_DIR:-$PWD/build}")

# The selected SDK: PB_SDK, else the one saved by pb use, else the default
PB_SDK=${PB_SDK:-$(cat "$SDK_CHOICE_FILE" 2>/dev/null || echo $DEFAULT_SDK)}

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${SDK_RELEASE[$PB_SDK]:-}" ]] ||
    die "unknown SDK '$PB_SDK'; known: ${!SDK_RELEASE[*]}"
SDK_NAME=SDK-$PB_SDK
SDK_URL=https://github.com/Sean-on-Git/PocketBook-SDK/releases/download/${SDK_RELEASE[$PB_SDK]}/$SDK_NAME.7z
# In the container: the SDK, its usr tree and its sysroot. On the host the SDK is in
# $PB_HOME/$SDK_NAME, whatever its archive called it.
SDK=/BUILD/${SDK_TOP[$PB_SDK]}
SDK_USR_DIR=$SDK${SDK_USR[$PB_SDK]}
SYSROOT=$SDK_USR_DIR/${SDK_TRIPLET[$PB_SDK]}/sysroot
# One image per Debian release the SDKs need, built from container/Containerfile.<release>
CONTAINERFILE=$KIT_DIR/container/Containerfile.${SDK_RELEASE[$PB_SDK]}
IMAGE=pocketbook-sdk:${SDK_RELEASE[$PB_SDK]}

# Container paths: the kit at /kit, the SDK at /BUILD/SDK-<sdk>, the device files at
# /device, and for app commands the app at /src and its build folder at /out
MOUNTS=()

# Sets ENGINE (podman or docker; override with PB_ENGINE=...) and USER_ARGS, the
# run options that make files written to the mounted folders belong to the host user
select_engine() {
    [[ -n "${ENGINE:-}" ]] && return
    ENGINE=${PB_ENGINE:-}
    if [[ -z $ENGINE ]]; then
        if command -v podman >/dev/null; then ENGINE=podman
        elif command -v docker >/dev/null; then ENGINE=docker
        else die "neither podman nor docker found"; fi
    fi
    command -v "$ENGINE" >/dev/null || die "$ENGINE not found"
    if [[ $ENGINE == podman ]]; then
        USER_ARGS=(--userns=keep-id)
    elif $ENGINE info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        USER_ARGS=()    # rootless docker: container root already maps to the host user
    else
        USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
    fi
}

ensure_image() {
    select_engine
    # Labelled with the Containerfile's hash, so a changed Containerfile rebuilds it
    local hash
    hash=$(sha256sum "$CONTAINERFILE" | cut -c1-16)
    [[ $($ENGINE image inspect -f '{{index .Config.Labels "pb.containerfile"}}' "$IMAGE" 2>/dev/null) == "$hash" ]] ||
        $ENGINE build --label "pb.containerfile=$hash" -t "$IMAGE" \
            -f "$CONTAINERFILE" "$KIT_DIR/container"
}

# in_container <workdir> <command...>, on the host's display if it has one. With
# HEADLESS=1 the command gets a virtual display of its own instead.
in_container() {
    local workdir=$1; shift
    local tty=(-i); [[ -t 0 && -t 1 ]] && tty=(-it)
    local x11=()
    if [[ -n "${HEADLESS:-}" ]]; then
        set -- bash -c 'Xvfb :99 -screen 0 2560x1600x24 -nolisten tcp 2>/dev/null &
            export DISPLAY=:99
            for _ in $(seq 50); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
            exec "$@"' headless "$@"
    elif [[ -n "${DISPLAY:-}" ]]; then
        x11=(-e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
        if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
            x11+=(-e XAUTHORITY=/tmp/.Xauthority -v "$XAUTHORITY:/tmp/.Xauthority:ro")
        fi
    fi
    ensure_image
    mkdir -p "$DEVICE_DIR"
    local sdk_mount=()
    [[ -d "$PB_HOME/$SDK_NAME" ]] && sdk_mount=(-v "$PB_HOME/$SDK_NAME:$SDK")
    $ENGINE run --rm "${tty[@]}" "${USER_ARGS[@]}" --security-opt label=disable \
        -v "$KIT_DIR:/kit" -v "$DEVICE_DIR:/device" "${sdk_mount[@]}" "${MOUNTS[@]}" \
        -w "$workdir" "${x11[@]}" \
        -e PB_KIT=/kit \
        -e PB_SDK=$PB_SDK \
        -e PB_APP_VERSION="${APP_VERSION:-}" \
        -e PB_SDK_DIR=$SDK \
        -e PB_SDK_USR=$SDK_USR_DIR \
        -e PB_SDK_CFG=$SDK/config.cmake \
        -e FRSCSDK_DIR=$SDK_USR_DIR \
        -e PB_SYSROOT=$SYSROOT \
        -e PB_SYSTEM_PATH=/kit/PocketBook-SDK/system \
        -e PB_DEVICE_DIR=/device \
        "$IMAGE" "$@"
}

require_sdk() {
    [[ -d "$PB_HOME/$SDK_NAME${SDK_USR[$PB_SDK]}/local" ]] || die "$SDK_NAME not set up; run pb setup first"
    [[ -d "$KIT_DIR/PocketBook-SDK/system" ]] ||
        die "the kit's submodules are missing; run git submodule update --init in $KIT_DIR"
}

setup() {
    [[ -d "$KIT_DIR/PocketBook-SDK/system" ]] || git -C "$KIT_DIR" submodule update --init
    ensure_image
    mkdir -p "$PB_HOME"
    if [[ -d "$PB_HOME/$SDK_NAME${SDK_USR[$PB_SDK]}/local" ]]; then
        echo "$SDK_NAME already present in $PB_HOME"
    else
        # Download, verify and extract inside the container so the host needs only git + podman/docker
        MOUNTS=(-v "$PB_HOME:/data")
        in_container /data bash -ec "
            mkdir -p downloads
            f=downloads/$SDK_NAME.7z
            if ! echo '${SDK_SHA256[$PB_SDK]}  '\$f | sha256sum -c --status 2>/dev/null; then
                curl -fL --retry 3 -o \$f.part $SDK_URL
                mv \$f.part \$f
            fi
            echo '${SDK_SHA256[$PB_SDK]}  '\$f | sha256sum -c
            rm -rf $SDK_NAME.tmp && mkdir $SDK_NAME.tmp
            bsdtar -xf \$f -C $SDK_NAME.tmp
            mv $SDK_NAME.tmp/${SDK_TOP[$PB_SDK]} $SDK_NAME && rmdir $SDK_NAME.tmp"
        echo "SDK ready in $PB_HOME/$SDK_NAME (you can delete $PB_HOME/downloads to save about 600 MB)"
    fi
    if [[ ! -d "$DEVICE_DIR/system" ]]; then
        cat <<EOF

Next, to make the emulator look like your PocketBook (screen size, theme, fonts):
connect it over USB and run
    pb device export <where its storage is mounted>
then follow what it says. See "Making the emulator match your device" in the README.
EOF
    fi
}

list_sdks() {
    local sdk
    for sdk in $(printf '%s\n' "${!SDK_RELEASE[@]}" | sort); do
        printf '%s %-12s %s\n' "$([[ $sdk == "$PB_SDK" ]] && echo '*' || echo ' ')" "$sdk" \
            "$([[ -d "$PB_HOME/SDK-$sdk${SDK_USR[$sdk]}/local" ]] && echo downloaded || echo 'not downloaded')"
    done
}

use_sdk() {
    local sdk=${1:-}
    [[ -n $sdk && -n "${SDK_RELEASE[$sdk]:-}" ]] || die "usage: pb use <sdk>; known: ${!SDK_RELEASE[*]}"
    mkdir -p "$PB_HOME"
    echo "$sdk" > "$SDK_CHOICE_FILE"
    echo "Using $sdk$([[ -d "$PB_HOME/SDK-$sdk${SDK_USR[$sdk]}/local" ]] || echo '; run pb setup to download it')"
}

# Sets APP_DIR (absolute), APP (target name), APP_VERSION and OUT_DIR (build/<app>/<sdk>), and
# mounts them at /src and /out
resolve_app() {
    local dir
    dir=$(realpath "${1:-.}") || die "no folder ${1:-.}"
    local pros=("$dir"/*.pro)
    [[ ${#pros[@]} -eq 1 && -f ${pros[0]} ]] || die "$dir must contain exactly one .pro file"
    APP_DIR=$dir
    APP=$(basename "${pros[0]}" .pro)
    # The container has no git, so the version comes from here
    APP_VERSION=${PB_APP_VERSION:-$(git -C "$dir" describe --tags --always --dirty 2>/dev/null || true)}
    OUT_DIR=$BUILD_ROOT/$APP/$PB_SDK
    MOUNTS=(-v "$APP_DIR:/src" -v "$OUT_DIR:/out")
}

build_pc() {
    require_sdk
    mkdir -p "$OUT_DIR/pc"
    in_container /out/pc bash -ec "
        $SDK_USR_DIR/local/qt6/bin/qmake PLATFORM=linux ${PB_QMAKE_ARGS:-} /src/$APP.pro
        make -j\$(nproc)
        # The emulator reads (and writes) config, fonts and themes in ./system;
        # use a copy so the PocketBook-SDK submodule stays clean
        [ -d system ] || cp -r \$PB_SYSTEM_PATH system
        # Files exported from a real device by pb device (hardware config, theme, fonts)
        # make the emulator look like that device
        if [ -d /device/system ]; then
            cp -r /device/system/. system/
            ln -sf hwconfig_device system/config/hwconfig
            # emu_resmode=-1: the device's own screen size, not a fixed emulator one
            sed -i -e 's/^emu_device=.*/emu_device=device/' -e 's/^emu_resmode=.*/emu_resmode=-1/' \
                system/config/global.cfg
        fi
        # Qt finds fonts through fontconfig, which doesn't know the emulator's
        # system/fonts; on the device the firmware's fonts are set up for it
        cat > system/fonts.conf <<FONTS
<?xml version=\"1.0\"?>
<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">
<fontconfig>
  <dir>/out/pc/system/fonts</dir>
  <include ignore_missing=\"yes\">/etc/fonts/fonts.conf</include>
  <cachedir>/tmp/fontconfig</cachedir>
</fontconfig>
FONTS"
}

build_arm() {
    require_sdk
    mkdir -p "$OUT_DIR/arm"
    in_container /out/arm bash -ec "
        $SYSROOT/usr/local/qt6/bin/qmake PLATFORM=arm ${PB_QMAKE_ARGS:-} /src/$APP.pro
        make -j\$(nproc)"
}

# The environment the PC build runs in. LD_LIBRARY_PATH covers .pro files with a wrong
# rpath (e.g. the browser-minimal example). The 6.11 desktop Qt is built with OpenGL ES,
# which the emulator's platform plugin can't give it, so Qt Quick would draw nothing:
# QT_QUICK_BACKEND=software draws as the 6.10 one does, which has no OpenGL.
APP_ENV=(env LD_LIBRARY_PATH=$SDK_USR_DIR/local/lib FONTCONFIG_FILE=/out/pc/system/fonts.conf
    QT_QUICK_BACKEND=software)
# The app's own, from PB_ENV
read -ra USER_ENV <<< "${PB_ENV:-}"
APP_ENV+=("${USER_ENV[@]}")

run_pc() {
    in_container /out/pc "${APP_ENV[@]}" "./$APP.app"
}

# Builds tests/tests.pro in /out/tests and runs make check there. -k runs every test program
# even after one fails, and the exit code says whether any did. Offscreen, so no test opens
# a window; the virtual display is there in case one tries anyway.
run_tests() {
    [[ -f $APP_DIR/tests/tests.pro ]] || die "no tests/tests.pro in $APP_DIR (see Tests in the kit's README)"
    mkdir -p "$OUT_DIR/tests"
    HEADLESS=1 in_container /out/tests "${APP_ENV[@]}" QT_QPA_PLATFORM=offscreen bash -ec "
        $SDK_USR_DIR/local/qt6/bin/qmake PLATFORM=linux ${PB_QMAKE_ARGS:-} /src/tests/tests.pro
        make -j\$(nproc)
        make -k check"
}

# drive_pc <script> [args...]: runs the script in /out/pc with $PB_APP set
drive_pc() {
    local script
    script=$(realpath "${1:-}") && [[ -f $script ]] || die "usage: pb drive <app-dir> <script> [args]"
    shift
    MOUNTS+=(-v "$(dirname "$script"):/test")
    HEADLESS=1 in_container /out/pc "${APP_ENV[@]}" PB_APP="./$APP.app" \
        bash "/test/$(basename "$script")" "$@"
}

new_app() {
    local dir=${1:-}
    [[ -n $dir ]] || die "usage: pb new <dir>"
    [[ ! -e $dir ]] || die "$dir already exists"
    local name
    name=$(basename "$dir")
    [[ $name =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "the app's name ($name) may only have letters, digits, - and _"
    local skeleton=$KIT_DIR/apps/hello-pocketbook
    mkdir -p "$dir"
    cp "$skeleton"/{main.cpp,main.qml,qml.qrc} "$dir/"
    sed "s/^TARGET = .*/TARGET = $name.app/" "$skeleton/hello-pocketbook.pro" > "$dir/$name.pro"
    cp "$KIT_DIR/template/Makefile" "$dir/Makefile"
    cp "$KIT_DIR/template/gitignore" "$dir/.gitignore"
    echo "Created $dir. To try it:"
    echo "    cd $dir && make run"
}

device() {
    case "${1:-}" in
        export) device_export "${2:-}" ;;
        import) device_import "${2:-}" ;;
        remove) rm -rf "$DEVICE_DIR"
                echo "Removed $DEVICE_DIR. Run pb clean <app> so its next PC build starts from the SDK's emulator files." ;;
        "")     if [[ -f $DEVICE_DIR/system/config/device.cfg ]]; then
                    echo "The emulator uses the files from a $(sed -n 's/^description=//p' "$DEVICE_DIR/system/config/device.cfg")"
                    echo "($DEVICE_DIR)"
                else
                    echo "No device files yet; the emulator uses the SDK's. To add them: pb device export"
                fi ;;
        *)      die "usage: pb device [export [mount] | import <mount> | remove]" ;;
    esac
}

# The kit's own tools build into PB_HOME, not into the current folder
device_tool() {
    BUILD_ROOT=$PB_HOME/build
    resolve_app "$KIT_DIR/apps/device-export"
}

device_export() {
    local mount=$1
    device_tool
    build_arm
    local app=$OUT_DIR/arm/device-export.app
    if [[ -n $mount ]]; then
        [[ -d $mount/applications ]] || die "$mount doesn't look like a PocketBook's storage (no applications/ folder)"
        cp "$app" "$mount/applications/"
        echo "Copied device-export.app to $mount/applications/."
    else
        echo "Built $app. Copy it to the applications/ folder on the device."
    fi
    cat <<EOF

On the device, open Applications and run device-export. When it says Done, connect USB
again and run
    pb device import ${mount:-<where its storage is mounted>}
EOF
}

device_import() {
    local from=${1:-}
    [[ -n $from ]] || die "usage: pb device import <mount>, or the pb-device folder itself"
    [[ -d $from/pb-device ]] && from=$from/pb-device
    [[ -d $from/system/config ]] || die "no pb-device folder with system/config in $1; run device-export on the device first"
    [[ $(realpath "$from") != "$(realpath -m "$DEVICE_DIR")" ]] || die "$from is already the kit's device folder"
    rm -rf "$DEVICE_DIR"
    mkdir -p "$DEVICE_DIR"
    cp -r "$from"/. "$DEVICE_DIR/"
    echo "Copied $from to $DEVICE_DIR"
    # On the PC, device-export saves every icon in the device's theme, for picking names
    device_tool
    build_pc
    echo "Saving the theme's icons to $DEVICE_DIR/icons..."
    HEADLESS=1 in_container /out/pc "${APP_ENV[@]}" ./device-export.app
    echo "Done. Every PC build now copies these files into the emulator's system/ folder;"
    echo "run pb clean <app> first if an app was built before."
}

case "${1:-}" in
    setup)  setup ;;
    new)    new_app "${2:-}" ;;
    pc)     resolve_app "${2:-}"; build_pc ;;
    run)    resolve_app "${2:-}"; build_pc; run_pc ;;
    arm)    resolve_app "${2:-}"; build_arm ;;
    test)   resolve_app "${2:-}"; build_pc; run_tests ;;
    drive)  resolve_app "${2:-}"; build_pc; drive_pc "${@:3}" ;;
    shell)  if [[ -n "${2:-}" ]]; then resolve_app "$2"; mkdir -p "$OUT_DIR"; in_container /src bash
            else in_container /kit bash; fi ;;
    clean)  resolve_app "${2:-}"; rm -rf "${BUILD_ROOT:?}/${APP:?}" ;;
    sdks)   list_sdks ;;
    use)    use_sdk "${2:-}" ;;
    device) device "${@:2}" ;;
    *)      sed -n '2,/^set /{/^#/p}' "$0"; exit 1 ;;
esac
