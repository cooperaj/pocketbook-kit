# Settings every PocketBook app needs, for both the emulator and the device. Include it
# from the app's .pro file:
#     include($$(PB_KIT)/qmake/pocketbook.pri)
# pb.sh sets PB_KIT and the SDK's paths in the build container: PB_SDK_USR is the SDK's usr
# tree (local/ has the desktop Qt and libinkview) and PB_SYSROOT the device's sysroot.

contains(PLATFORM, arm) {
    # Cross-compile for the device (armv7, Qt6 from the SDK sysroot)
    SYSROOT = $$(PB_SYSROOT)
    INCLUDEPATH += $$SYSROOT/usr/include $$SYSROOT/usr/local/include $$SYSROOT/usr/include/freetype2
    message("$$TARGET: building for ARM, sysroot $$SYSROOT")
} else {
    # Desktop build: libinkview's emulator draws the "device screen" in an X11 window
    CONFIG += link_pkgconfig
    PKGCONFIG += freetype2
    DEFINES += EMULATOR=1 PB_LOG_LEVEL=1
    DEFINES += "EMULATOR_SDK_PATH=\\\"$$(PB_SDK_USR)/local\\\""
    LIBS += -L$$(PB_SDK_USR)/lib -L$$(PB_SDK_USR)/local/lib
    INCLUDEPATH += $$(PB_SDK_USR)/local/include $$(PB_SDK_USR)/include
    QMAKE_RPATHDIR += $$(PB_SDK_USR)/local/lib
    message("$$TARGET: building for PC emulator, SDK $$(PB_SDK_DIR)")
    system(echo [Paths] > $$OUT_PWD/qt.conf; echo Prefix = $$(PB_SDK_USR)/local/qt6 >> $$OUT_PWD/qt.conf)
}

LIBS += -ldl -lz -lhwconfig -linkview -lcommon_utilities

# pb_build.h: PB_SDK, the SDK built with (e.g. "B288-6.10"), and PB_APP_VERSION, git describe
# --tags of the app's repo (e.g. "1.2.0", or "1.2.0-3-gabc1234-dirty" between tags; empty
# outside git). Written only when they change, so a new version recompiles only what
# includes it.
PB_BUILD_HEADER = $$OUT_PWD/pb_build.h
PB_BUILD_DEFINES = "$${LITERAL_HASH}define PB_SDK \"$$(PB_SDK)\"$$escape_expand(\\n)$${LITERAL_HASH}define PB_APP_VERSION \"$$(PB_APP_VERSION)\""
!equals(PB_BUILD_DEFINES, $$cat($$PB_BUILD_HEADER, blob)): write_file($$PB_BUILD_HEADER, PB_BUILD_DEFINES)
