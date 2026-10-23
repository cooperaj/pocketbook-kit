#include <inkview.h>
#include <QFont>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

int main(int argc, char *argv[])
{
    // Connect to the PocketBook system (on PC this opens the emulator window)
    InitInkview(ACTIVETASK);

    // Render Qt through the PocketBook e-ink platform plugin
    setenv("QT_QPA_PLATFORM", "pocketbook2", true);

    QGuiApplication app(argc, argv);
    app.setFont(QFont(QString::fromUtf8(iv_get_default_font(FONT_FAMILY))));

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("screenWidth", ScreenWidth());
    engine.rootContext()->setContextProperty("screenHeight", ScreenHeight());
    engine.load(QUrl("qrc:/main.qml"));
    if (engine.rootObjects().isEmpty())
        return 1;

    return app.exec();
}
