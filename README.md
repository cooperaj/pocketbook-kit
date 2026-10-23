# PocketBook app development kit

Build Qt6/QML apps for PocketBook e-readers, and run them on your Linux PC in an
emulator window, using the official PocketBook SDK.

Targets the **B288** platform with firmware **6.10**. That covers Touch Lux 5, Verse,
Verse Pro, Touch HD 3, Color, Era, InkPad 3/3 Pro/Color/4/Lite and InkPad X. To check
your firmware, go to Settings → Software → Version on the device.

## Requirements

- Linux with `git` and either `podman` or `docker`. podman is used if both are
  installed; run with `PB_ENGINE=docker` to use docker instead.
- An X11 or XWayland display, to run the emulator
- About 5 GB of disk space: the SDK is a 640 MB download that unpacks to 3.3 GB

Nothing else needs to be installed on the host. The compilers and libraries run in a
container.

## Quick start

```sh
git clone --recurse-submodules <this repo> PocketBook
cd PocketBook
./pb.sh setup     # one-off: submodules, container image, SDK download (verified by SHA-256)
./pb.sh run       # build apps/hello-pocketbook and open it in the emulator
./pb.sh arm       # cross-compile it -> build/hello-pocketbook/arm/hello-pocketbook.app
```

Run `./pb.sh` with no arguments to list all commands. Any folder containing a single `.pro`
file can be passed as the app, including the official examples:

```sh
./pb.sh run Pocketbook-SDK-Examples/orientation
./pb.sh run Pocketbook-SDK-Examples/drawing-demo
./pb.sh arm Pocketbook-SDK-Examples           # builds all five examples
```

## Layout

| Path | What it is |
|---|---|
| `pb.sh` | The only script you need. It runs every build inside the container. |
| `container/Containerfile` | Debian 12 (Bookworm) image with what the SDK needs to run |
| `apps/hello-pocketbook/` | Skeleton app: copy this folder to start your own |
| `apps/bookorbit/` | Client for a [BookOrbit](https://github.com/bookorbit/bookorbit) server (see its README) |
| `PocketBook-SDK/` | Submodule: official docs and Docker files, plus the `system/` folder (fonts, themes, config) the emulator needs |
| `Pocketbook-SDK-Examples/` | Submodule pinned to the `6.10` branch: example apps |
| `SDK-B288-6.10/` | Toolchain, Qt6 and PocketBook libraries. Downloaded by `setup` from the [PocketBook-SDK releases](https://github.com/Sean-on-Git/PocketBook-SDK/releases/tag/6.10). Not committed. |
| `build/` | Build output. Not committed. |
| `downloads/` | The SDK archive. Safe to delete after `setup`. |

## Why a container?

The SDK's prebuilt tools (qmake, the desktop Qt6 and `libinkview`) only work from the path
`/BUILD/SDK-B288-6.10`. They are also linked against Debian 12 libraries. `pb.sh` mounts this
repo at `/BUILD` inside a Debian 12 container. That works on any distro, and the paths
compiled into the binaries stay valid.

## How the builds work

- **PC build:** uses the desktop Qt6 in `SDK-B288-6.10/usr/local/qt6`. `libinkview` draws a
  simulated device screen in an X11 window. Right-click inside it to choose a different
  device model. The emulator reads and writes settings in `./system`, so each PC build
  gets its own copy of `PocketBook-SDK/system`.
- **ARM build:** uses the ARM Qt6 in the SDK sysroot and the
  `arm-obreey-linux-gnueabi-clang++` cross-compiler.
- **Any app:** `main.cpp` calls `InitInkview()` and selects the `pocketbook2` Qt platform
  plugin. After that it's a normal QML app.

## Starting your own app

1. Copy `apps/hello-pocketbook` to `apps/my-app`.
2. Rename the `.pro` file to `my-app.pro` and set `TARGET = my-app.app` inside it.
3. Add C++ files to `SOURCES`/`HEADERS` in the `.pro` file, and QML files to `qml.qrc`.
4. Run `./pb.sh run apps/my-app`.

## Making the emulator match your device

The emulator uses the SDK's own theme, fonts and screen size, so it doesn't look exactly like
your device. To copy those from your device:

1. Build `./pb.sh arm apps/device-export`, copy `build/device-export/arm/device-export.app`
   to the device's `applications/` folder and run it there.
2. Connect USB and copy the `pb-device` folder from the root of the device's storage into this
   repo as `device/`.
3. Build and run any app with `./pb.sh run`. Every PC build copies `device/system` (the
   device's hardware config, themes and fonts) over the emulator's, and selects that device.
4. Optional: `./pb.sh run apps/device-export` on the PC saves every icon in the device's theme
   to `device/icons/`, as PNGs and labelled contact sheets, for picking icon names. It takes a
   few seconds and closes by itself.

`device/` holds PocketBook's own files, so it is in `.gitignore`. To go back to the SDK's
emulator, delete `device/` and run `./pb.sh clean <app>`.

## Installing on the device

Copy the `.app` file from `build/<app>/arm/` into the `applications/` folder on the
device. It then shows up in the apps list.

The official SDK readme also says to copy a `qt6.conf` file into `applications/`. That file
isn't in the examples repo. If an app won't start on the device, check that first.

## Updating

```sh
git pull && git submodule update --init
```

To use a different SDK release, change `SDK_NAME`, `SDK_URL` and `SDK_SHA256` at the top of
`pb.sh`. The SHA-256 is shown on the GitHub release page.
