import QtQuick
import QtQuick.Window

Window {
    visible: true
    width: screenWidth
    height: screenHeight
    color: "white"

    property int taps: 0

    Column {
        anchors.centerIn: parent
        spacing: 40

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Hello, PocketBook!"
            font.pointSize: 14
            font.bold: true
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 400; height: 120
            radius: 12
            border.width: 3
            color: mouse.pressed ? "black" : "white"

            Text {
                anchors.centerIn: parent
                text: "Tapped " + taps + " times"
                color: mouse.pressed ? "white" : "black"
                font.pointSize: 10
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                onClicked: taps++
            }
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 400; height: 120
            radius: 12
            border.width: 3

            Text { anchors.centerIn: parent; text: "Exit"; font.pointSize: 10 }
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
        }
    }
}
