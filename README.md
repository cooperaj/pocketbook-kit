# pocketbook-kit

Build Qt6/QML apps for PocketBook e-readers, and run them on your Linux PC in an
emulator window, using the official PocketBook SDK.

Targets firmware **6.10**, with the **B288** SDK by default. That covers Touch Lux 5, Verse,
Verse Pro, Touch HD 3, Color, Era, InkPad 3/3 Pro/Color/4/Lite and InkPad X. The **B300** SDK
can be selected instead; see [Choosing the SDK](#choosing-the-sdk). The SDK's readme lists it
only for the InkPad Color 2, but the Era Color (PB700K3) is a B300 device too. B288 builds run
on B300 devices, but the B300 SDK matches their firmware's libraries.
To check your firmware, go to Settings → Software → Version on the device.

## Requirements

- Linux with `git` and either `podman` or `docker`. podman is used if both are
  installed; run with `PB_ENGINE=docker` to use docker instead.
- An X11 or XWayland display, to run the emulator
- About 4 GB of disk space per SDK: each is a 600 MB download that unpacks to about 3.3 GB

Nothing else needs to be installed on the host. The compilers and libraries run in a
container.

## Installing

Clone the kit anywhere and put `pb.sh` on your PATH as `pb`:

```sh
git clone --recurse-submodules https://github.com/<you>/pocketbook-kit.git
ln -s "$PWD/pocketbook-kit/pb.sh" ~/.local/bin/pb
pb setup     # one-off: container image and SDK download (verified by SHA-256)
```

SDKs, the selected SDK and your device's files go in `~/.local/share/pocketbook-kit`
(set `PB_HOME` to use another folder). Every app you build shares them.

## Quick start

```sh
pb new my-app          # a new app from the skeleton, with a Makefile
cd my-app
make run               # build it and open it in the emulator
make arm               # cross-compile it -> build/my-app/B288-6.10/arm/my-app.app
```

Run `pb` with no arguments to list all commands. They take the app's folder (any folder
containing one `.pro` file) and default to the current folder. Builds go to `build/` in the
current folder. The kit's own apps and the official examples build the same way:

```sh
pb run ~/pocketbook-kit/apps/hello-pocketbook
pb run ~/pocketbook-kit/Pocketbook-SDK-Examples/orientation
```

### Keeping the kit with your app

Instead of using the `pb` on your PATH, an app can pin a version of the kit as a submodule
in `kit/`. The Makefile from `pb new` uses `kit/pb.sh` when there is one:

```sh
git submodule add https://github.com/<you>/pocketbook-kit.git kit
git submodule update --init --recursive
make setup run
```

`make PB_KIT=/path/to/pocketbook-kit run` builds with another checkout of the kit, for
working on the kit and an app together.

## Layout

| Path | What it is |
|---|---|
| `pb.sh` | The only script you need. It runs every build inside the container. |
| `qmake/pocketbook.pri` | The qmake settings every app needs, for both the emulator and the device |
| `container/Containerfile` | Debian 12 (Bookworm) image with what the SDK needs to run |
| `apps/hello-pocketbook/` | The skeleton app that `pb new` copies |
| `apps/device-export/` | Copies a device's screen config, theme and fonts for the emulator; see below |
| `template/` | The Makefile and `.gitignore` that `pb new` adds |
| `PocketBook-SDK/` | Submodule: official docs and Docker files, plus the `system/` folder (fonts, themes, config) the emulator needs |
| `Pocketbook-SDK-Examples/` | Submodule pinned to the `6.10` branch: example apps |

In `~/.local/share/pocketbook-kit`:

| Path | What it is |
|---|---|
| `SDK-<sdk>/` | Toolchain, Qt6 and PocketBook libraries, e.g. `SDK-B288-6.10/`. Downloaded by `pb setup` from the [PocketBook-SDK releases](https://github.com/Sean-on-Git/PocketBook-SDK/releases/tag/6.10). |
| `downloads/` | The SDK archives. Safe to delete after `setup`. |
| `device/` | Files from your own PocketBook, made by `pb device` |
| `sdk` | The SDK chosen with `pb use` |

## Why a container?

The SDK's prebuilt tools (qmake, the desktop Qt6 and `libinkview`) only work from the path
`/BUILD/SDK-<sdk>`, e.g. `/BUILD/SDK-B288-6.10`. They are also linked against Debian 12
libraries. `pb` mounts the SDK at that path inside a Debian 12 container, with the kit at
`/kit`, the app at `/src` and its build folder at `/out`. That works on any distro, and the
paths compiled into the binaries stay valid.

## How the builds work

- **PC build:** uses the desktop Qt6 in `SDK-<sdk>/usr/local/qt6`. `libinkview` draws a
  simulated device screen in an X11 window. Right-click inside it to choose a different
  device model. The emulator reads and writes settings in `./system`, so each PC build
  gets its own copy of `PocketBook-SDK/system`.
- **ARM build:** uses the ARM Qt6 in the SDK sysroot and the
  `arm-obreey-linux-gnueabi-clang++` cross-compiler.
- **Any app:** `main.cpp` calls `InitInkview()` and selects the `pocketbook2` Qt platform
  plugin. After that it's a normal QML app.

## Writing an app

`pb new <dir>` copies `apps/hello-pocketbook`, names the `.pro` file and target after the
folder, and adds a Makefile. Add C++ files to `SOURCES`/`HEADERS` in the `.pro` file, and QML
files to `qml.qrc`. Keep the line that includes the kit's settings:

```qmake
include($$(PB_KIT)/qmake/pocketbook.pri)
```

To pass a build-time setting to qmake, set `PB_QMAKE_ARGS`, e.g.
`PB_QMAKE_ARGS="SERVER=example.com" pb arm`.

## Making the emulator match your device

The emulator uses the SDK's own theme, fonts and screen size, so it doesn't look exactly like
your device. To copy those from your device:

1. Connect the device over USB and run `pb device export /run/media/$USER/<device>` (where
   its storage is mounted). That builds `device-export.app` and copies it to the device's
   `applications/` folder. Without a path it just builds it, and prints where to find it.
2. On the device, open Applications and run device-export. It copies the hardware config,
   themes, fonts, file associations and language file to `pb-device/` on its storage.
3. Connect USB again and run `pb device import /run/media/$USER/<device>`. That copies the
   files to `~/.local/share/pocketbook-kit/device/`, and saves every icon in the device's
   theme to `device/icons/`, as PNGs and labelled contact sheets, for picking icon names.
4. Run `pb clean` in any app built before, so its next PC build starts fresh. From now on
   every PC build copies the device's files over the emulator's and selects that device, so
   the emulator has the device's screen size, dpi, status bar, icons and fonts.

device-export copies only configuration, themes and fonts, never the firmware's programs.
The files are PocketBook's own, so keep them out of your app's repo. `pb device` shows which
device the files came from, and `pb device remove` goes back to the SDK's emulator.

## Testing without a window

`pb test <app-dir> <script>` builds the app for PC and runs a bash script in the container
on a virtual display, so tests don't take over your screen. The script starts the app
itself, drives it with `xdotool` and takes screenshots with ImageMagick's `import`. The
script's folder is mounted at `/test`, so it can save them there:

```sh
"$PB_APP" &
sleep 5
xdotool mousemove 300 400 click 1
import -window root /test/screenshot.png
```

The emulator ignores SIGTERM. It is stopped with the container when the script ends.

## Installing on the device

Copy the `.app` file from `build/<app>/<sdk>/arm/` into the `applications/` folder on the
device. It then shows up in the apps list.

The official SDK readme also says to copy a `qt6.conf` file into `applications/`. That file
isn't in the examples repo. If an app won't start on the device, check that first.

## Updating

```sh
git pull && git submodule update --init
```

## Choosing the SDK

```sh
pb sdks              # list the SDKs, which are downloaded, and which is selected (*)
pb use B300-6.10     # select one for later commands
pb setup             # download the selected SDK if needed
PB_SDK=B288-6.10 pb arm   # or pick one for a single command
```

Each SDK is unpacked into its own `SDK-<sdk>/` folder, and builds go into
`build/<app>/<sdk>/`, so builds from different SDKs don't overwrite each other. To add another
SDK release, add its name, release tag and SHA-256 (shown on the GitHub release page) to the
tables at the top of `pb.sh`.

## Credits

The SDK, its documentation and the examples are PocketBook's, published by
[Sean-on-Git/PocketBook-SDK](https://github.com/Sean-on-Git/PocketBook-SDK) and
[Sean-on-Git/Pocketbook-SDK-Examples](https://github.com/Sean-on-Git/Pocketbook-SDK-Examples).
This kit doesn't include them: the examples and the emulator's `system/` folder come in as
submodules, and `pb setup` downloads the SDK.
