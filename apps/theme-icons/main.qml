import QtQuick
import QtQuick.Window

Window {
    visible: true
    width: screenWidth
    height: windowHeight
    color: "white"

    Column {
        anchors.centerIn: parent
        width: parent.width - 80
        spacing: 40

        Text {
            width: parent.width
            text: "Theme icon export"
            font.pointSize: 12
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            width: parent.width
            text: status.text
            font.pointSize: 9
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 360; height: 100
            radius: 12
            border.width: 3
            color: mouse.pressed ? "black" : "white"
            Text {
                anchors.centerIn: parent
                text: "Exit"
                color: mouse.pressed ? "white" : "black"
                font.pointSize: 10
            }
            MouseArea { id: mouse; anchors.fill: parent; onClicked: Qt.quit() }
        }
    }
}
