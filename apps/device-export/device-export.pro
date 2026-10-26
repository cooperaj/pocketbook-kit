TARGET = device-export.app
QT += quick
CONFIG += c++17 qtquickcompiler

SOURCES += main.cpp
RESOURCES += qml.qrc

include($$(PB_KIT)/qmake/pocketbook.pri)
