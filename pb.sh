#!/usr/bin/env bash
# Build/run helper for PocketBook (B288, firmware 6.10) Qt apps.
#
#   ./pb.sh setup              fetch submodules, download the SDK, build the container image
#   ./pb.sh run   [app-dir]    build for PC and open it in the emulator window
#   ./pb.sh pc    [app-dir]    build for PC            -> build/<app>/pc/<app>.app
#   ./pb.sh arm   [app-dir]    cross-compile for device -> build/<app>/arm/<app>.app
#   ./pb.sh shell              shell inside the build container (SDK env vars set)
#   ./pb.sh clean [app-dir]    remove build/<app> (or all of build/)
#
# Uses podman if installed, otherwise docker; set PB_ENGINE=docker to force docker.
#
# app-dir defaults to apps/hello-pocketbook and must contain one .pro file,
# e.g. ./pb.sh run Pocketbook-SDK-Examples/orientation
#
# The SDK's tools are hardcoded to /BUILD/SDK-B288-6.10 and need Debian Bookworm
# libraries, so everything runs in a container with this repo mounted at /BUILD.
set -euo pipefail

SDK_NAME=SDK-B288-6.10
SDK_URL=https://github.com/Sean-on-Git/PocketBook-SDK/releases/download/6.10/$SDK_NAME.7z
SDK_SHA256=18405fb276535d53a4b70d2bbf4033313cded58da5002d563ccf7e1838440c0b
IMAGE=pocketbook-sdk:6.10
DEFAULT_APP=apps/hello-pocketbook

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
SDK=/BUILD/$SDK_NAME

die() { echo "error: $*" >&2; exit 1; }

# Sets ENGINE (podman or docker; override with PB_ENGINE=...) and USER_ARGS, the
# run options that make files written to the mounted repo belong to the host user
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
    $ENGINE image inspect "$IMAGE" >/dev/null 2>&1 ||
        $ENGINE build -t "$IMAGE" -f "$ROOT_DIR/container/Containerfile" "$ROOT_DIR/container"
}

# in_container <workdir> <command...>
in_container() {
    local workdir=$1; shift
    local tty=(-i); [[ -t 0 && -t 1 ]] && tty=(-it)
    local x11=()
    if [[ -n "${DISPLAY:-}" ]]; then
        x11=(-e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
        if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
            x11+=(-e XAUTHORITY=/tmp/.Xauthority -v "$XAUTHORITY:/tmp/.Xauthority:ro")
        fi
    fi
    ensure_image
    $ENGINE run --rm "${tty[@]}" "${USER_ARGS[@]}" --security-opt label=disable \
        -v "$ROOT_DIR:/BUILD" -w "$workdir" "${x11[@]}" \
        -e PB_SDK_DIR=$SDK \
        -e PB_SDK_CFG=$SDK/config.cmake \
        -e FRSCSDK_DIR=$SDK/usr \
        -e PB_SYSROOT=$SDK/usr/arm-obreey-linux-gnueabi/sysroot \
        -e PB_SYSTEM_PATH=/BUILD/PocketBook-SDK/system \
        -e PB_DEVICE_DIR=/BUILD/device \
        "$IMAGE" "$@"
}

require_sdk() {
    [[ -d "$ROOT_DIR/$SDK_NAME/usr" && -d "$ROOT_DIR/PocketBook-SDK/system" ]] ||
        die "SDK not set up; run ./pb.sh setup first"
}

setup() {
    git -C "$ROOT_DIR" submodule update --init
    ensure_image
    if [[ -d "$ROOT_DIR/$SDK_NAME/usr" ]]; then
        echo "$SDK_NAME already present"
        return
    fi
    # Download, verify and extract inside the container so the host needs only git + podman/docker
    in_container /BUILD bash -ec "
        mkdir -p downloads
        f=downloads/$SDK_NAME.7z
        if ! echo '$SDK_SHA256  '\$f | sha256sum -c --status 2>/dev/null; then
            curl -fL --retry 3 -o \$f.part $SDK_URL
            mv \$f.part \$f
        fi
        echo '$SDK_SHA256  '\$f | sha256sum -c
        rm -rf $SDK_NAME.tmp && mkdir $SDK_NAME.tmp
        bsdtar -xf \$f -C $SDK_NAME.tmp
        mv $SDK_NAME.tmp/$SDK_NAME $SDK_NAME && rmdir $SDK_NAME.tmp"
    echo "SDK ready in $SDK_NAME/ (you can delete downloads/ to save 640 MB)"
}

# Sets APP_DIR (relative to repo root), APP (target name) and BUILD_DIR
resolve_app() {
    local dir=${1:-$DEFAULT_APP}
    dir=$(realpath --relative-to="$ROOT_DIR" "$dir")
    [[ $dir != ..* ]] || die "app dir must be inside $ROOT_DIR"
    local pros=("$ROOT_DIR/$dir"/*.pro)
    [[ ${#pros[@]} -eq 1 && -f ${pros[0]} ]] || die "$dir must contain exactly one .pro file"
    APP_DIR=$dir
    APP=$(basename "${pros[0]}" .pro)
    BUILD_DIR=build/$APP
}

build_pc() {
    require_sdk
    mkdir -p "$ROOT_DIR/$BUILD_DIR/pc"
    in_container "/BUILD/$BUILD_DIR/pc" bash -ec "
        $SDK/usr/local/qt6/bin/qmake PLATFORM=linux /BUILD/$APP_DIR/$APP.pro
        make -j\$(nproc)
        # The emulator reads (and writes) config, fonts and themes in ./system;
        # use a copy so the PocketBook-SDK submodule stays clean
        [ -d system ] || cp -r \$PB_SYSTEM_PATH system
        # Files exported from a real device by apps/device-export (hardware config,
        # theme, fonts) make the emulator look like that device
        if [ -d /BUILD/device/system ]; then
            cp -r /BUILD/device/system/. system/
            ln -sf hwconfig_device system/config/hwconfig
            sed -i 's/^emu_device=.*/emu_device=device/' system/config/global.cfg
        fi"
}

build_arm() {
    require_sdk
    mkdir -p "$ROOT_DIR/$BUILD_DIR/arm"
    in_container "/BUILD/$BUILD_DIR/arm" bash -ec "
        $SDK/usr/arm-obreey-linux-gnueabi/sysroot/usr/local/qt6/bin/qmake PLATFORM=arm /BUILD/$APP_DIR/$APP.pro
        make -j\$(nproc)"
}

case "${1:-}" in
    setup) setup ;;
    pc)    resolve_app "${2:-}"; build_pc ;;
    # LD_LIBRARY_PATH covers .pro files with a wrong rpath (e.g. the browser-minimal example)
    run)   resolve_app "${2:-}"; build_pc
           in_container "/BUILD/$BUILD_DIR/pc" env LD_LIBRARY_PATH=$SDK/usr/local/lib ./$APP.app ;;
    arm)   resolve_app "${2:-}"; build_arm ;;
    shell) in_container /BUILD bash ;;
    clean) if [[ -n "${2:-}" ]]; then resolve_app "$2"; rm -rf "${ROOT_DIR:?}/$BUILD_DIR"
           else rm -rf "${ROOT_DIR:?}/build"; fi ;;
    *)     sed -n '2,17p' "$0"; exit 1 ;;
esac
