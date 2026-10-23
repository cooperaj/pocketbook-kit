// One-off tool: lists the icons in the device's system themes and saves the active
// theme's icons as PNGs and contact sheets, so they can be looked at on a PC.
//
// Output goes to bookorbit-icons/ at the root of the device's USB storage
// (build/theme-icons/pc/system/mnt/ext1/bookorbit-icons in the emulator):
//   themes.txt    every theme file found, with the icons it lists
//   icons.txt     every icon the active theme returns: name, size, depth (bit 15 set:
//                 has a transparency mask; 24 and 32: colour, byte order guessed)
//   png/          each of those icons as <name>.png
//   sheet-NN.png  the icons on labelled contact sheets

#include <inkview.h>
#include <QDir>
#include <QFile>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QRegularExpression>
#include <QSet>
#include <QTextStream>
#include <QTimer>
#include <cstdlib>

static const QString OUT_DIR = QString::fromUtf8(FLASHDIR "/bookorbit-icons");

// Shown on screen while the tool runs
class Status : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString text READ text NOTIFY textChanged)
public:
    QString text() const { return m_text; }
    void set(const QString &text)
    {
        m_text = text;
        emit textChanged();
        QCoreApplication::processEvents();
    }
signals:
    void textChanged();
private:
    QString m_text;
};

// A .pbt file starts with a 32-byte header ("PocketBookTheme" and some sizes), then an
// index of entries: three 32-bit numbers (sizes and the data offset), then the resource
// name as "name:type\0", padded to 4 bytes. The index ends at the first entry that
// doesn't look like one.
static QStringList themeResourceNames(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    const QByteArray data = file.readAll();
    if (!data.startsWith("PocketBookTheme"))
        return {};

    static const QRegularExpression entry("^[^\\x00-\\x1f:]{1,100}:[^\\x00-\\x1f]{0,20}$");
    QStringList names;
    for (int pos = 32; pos + 12 < data.size();) {
        const int start = pos + 12;
        const int end = data.indexOf('\0', start);
        if (end < 0)
            break;
        const QString name = QString::fromUtf8(data.mid(start, end - start));
        if (!entry.match(name).hasMatch())
            break;
        names << name;
        pos = (end + 1 + 3) & ~3;
    }
    return names;
}

// Some theme resources aren't images (layouts, for one) but GetResource still returns
// them as an ibitmap, with nonsense in the header. Accept only plausible bitmaps.
static bool looksLikeBitmap(const ibitmap *bmp)
{
    const int depth = bmp->depth & 0xff;
    const bool knownDepth = depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 24 || depth == 32;
    const int minScanline = (bmp->width * depth + 7) / 8;
    return knownDepth && bmp->width > 0 && bmp->height > 0 && bmp->width <= 4096 && bmp->height <= 4096
           && bmp->scanline >= minScanline && bmp->scanline <= minScanline + 8;
}

// Converts an inkview bitmap to a QImage. Grey levels (1, 2, 4 or 8 bits, high bits
// first) and the optional 1-bit transparency mask after the pixels follow the SDK's
// qml_test ResourceImageProvider. The byte order of 24 and 32-bit bitmaps is a guess
// (R, G, B[, A]): shapes are right even if colours come out swapped.
static QImage toImage(const ibitmap *bmp)
{
    const int depth = bmp->depth & 0xff;
    const bool hasMask = bmp->depth & 0x8000;
    const int maskScanline = (bmp->width + 7) / 8;
    const unsigned char *mask = bmp->data + bmp->height * bmp->scanline;
    QImage image(bmp->width, bmp->height, QImage::Format_ARGB32);
    for (int y = 0; y < bmp->height; ++y) {
        const unsigned char *row = bmp->data + bmp->scanline * y;
        QRgb *out = reinterpret_cast<QRgb *>(image.scanLine(y));
        for (int x = 0; x < bmp->width; ++x) {
            QRgb pixel;
            if (depth <= 8) {
                const int bit = x * depth;
                const int value = (row[bit / 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1);
                const int grey = value * 255 / ((1 << depth) - 1);
                pixel = qRgb(grey, grey, grey);
            } else if (depth == 24) {
                pixel = qRgb(row[x * 3], row[x * 3 + 1], row[x * 3 + 2]);
            } else {
                pixel = qRgba(row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]);
            }
            if (hasMask && !((mask[maskScanline * y + x / 8] >> (7 - x % 8)) & 1))
                pixel = qRgba(0, 0, 0, 0);
            out[x] = pixel;
        }
    }
    return image;
}

static void writeSheets(const QStringList &names, Status &status)
{
    const int columns = 6, rows = 9, cellWidth = 175, cellHeight = 150, iconBox = 100;
    const int perSheet = columns * rows;
    QFont font;
    font.setPixelSize(13);

    for (int first = 0, sheetNo = 1; first < names.size(); first += perSheet, ++sheetNo) {
        QImage sheet(columns * cellWidth, rows * cellHeight, QImage::Format_RGB32);
        sheet.fill(QColor(230, 230, 230));
        QPainter painter(&sheet);
        painter.setFont(font);
        for (int i = 0; i < perSheet && first + i < names.size(); ++i) {
            const QString &name = names[first + i];
            const QRect cell((i % columns) * cellWidth, (i / columns) * cellHeight, cellWidth, cellHeight);
            QImage icon(OUT_DIR + "/png/" + name + ".png");
            const QString size = icon.isNull() ? "?" : QString("%1x%2").arg(icon.width()).arg(icon.height());
            if (icon.width() > iconBox || icon.height() > iconBox)
                icon = icon.scaled(iconBox, iconBox, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            // White box behind each icon shows its real bounds
            painter.fillRect(cell.x() + 4, cell.y() + 4, cellWidth - 8, iconBox + 8, Qt::white);
            painter.drawImage(cell.x() + (cellWidth - icon.width()) / 2,
                              cell.y() + 8 + (iconBox - icon.height()) / 2, icon);
            painter.setPen(Qt::black);
            painter.drawText(QRect(cell.x() + 2, cell.y() + iconBox + 14, cellWidth - 4, cellHeight - iconBox - 14),
                             Qt::AlignHCenter | Qt::AlignTop | Qt::TextWrapAnywhere, name + " " + size);
        }
        painter.end();
        sheet.save(QString("%1/sheet-%2.png").arg(OUT_DIR).arg(sheetNo, 2, 10, QChar('0')));
        status.set(QString("Contact sheet %1 of %2").arg(sheetNo).arg((names.size() + perSheet - 1) / perSheet));
    }
}

static void run(Status &status)
{
    QDir().mkpath(OUT_DIR + "/png");

    // 1. Theme files and the names in their indexes
    QFile themesFile(OUT_DIR + "/themes.txt");
    themesFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
    QTextStream themes(&themesFile);
    QFile globalCfg(QString::fromUtf8(CONFIGPATH "/global.cfg"));
    if (globalCfg.open(QIODevice::ReadOnly | QIODevice::Text)) {
        themes << "Theme settings in " << globalCfg.fileName() << ":\n";
        for (const QByteArray &line : globalCfg.readAll().split('\n')) {
            if (line.toLower().contains("theme"))
                themes << "  " << line << "\n";
        }
        themes << "\n";
    }
    QStringList allNames;
    for (const char *dir : {SYSTEMTHEMESPATH, USERTHEMESPATH}) {
        const QFileInfoList files = QDir(QString::fromUtf8(dir)).entryInfoList({"*.pbt"}, QDir::Files, QDir::Name);
        themes << "== " << dir << ": " << files.size() << " theme files\n";
        for (const QFileInfo &info : files) {
            status.set("Reading " + info.fileName());
            const QStringList names = themeResourceNames(info.filePath());
            themes << "\n-- " << info.fileName() << " (" << info.size() << " bytes, " << names.size() << " resources)\n";
            for (const QString &name : names)
                themes << name << "\n";
            for (const QString &name : names)
                allNames << name.section(':', 0, 0);
        }
        themes << "\n";
    }
    themesFile.close();
    allNames.removeDuplicates();
    allNames.sort(Qt::CaseInsensitive);

    // 2. Ask the active theme for each name and save what it returns
    QFile iconsFile(OUT_DIR + "/icons.txt");
    iconsFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
    QTextStream icons(&iconsFile);
    icons << "name\twidth\theight\tdepth\n";
    QStringList found;
    for (int i = 0; i < allNames.size(); ++i) {
        const QString &name = allNames[i];
        if (i % 50 == 0)
            status.set(QString("Saving icons: %1 of %2").arg(i).arg(allNames.size()));
        // Written before the lookup, so if a resource crashes the tool, the last line names it
        icons << name << Qt::flush;
        ibitmap *bmp = GetResource(name.toUtf8().constData(), nullptr);
        if (!bmp) {
            icons << "\tnot found\n";
            continue;
        }
        icons << "\t" << bmp->width << "\t" << bmp->height << "\t" << bmp->depth;
        if (!looksLikeBitmap(bmp)) {
            icons << "\tnot an image\n";
            free(bmp);
            continue;
        }
        icons << "\n" << Qt::flush;
        // Not SavePNG(): it crashes on some masked bitmaps
        toImage(bmp).save(OUT_DIR + "/png/" + name + ".png");
        free(bmp);
        found << name;
    }
    iconsFile.close();

    // 3. Contact sheets
    writeSheets(found, status);
    status.set(QString("Done: %1 icons (of %2 names) saved to\n%3\n\nConnect USB to copy the folder.")
                   .arg(found.size()).arg(allNames.size()).arg(OUT_DIR));
}

int main(int argc, char *argv[])
{
    InitInkview(ACTIVETASK);
    setenv("QT_QPA_PLATFORM", "pocketbook2", true);

    QGuiApplication app(argc, argv);
    app.setFont(QFont(QString::fromUtf8(iv_get_default_font(FONT_FAMILY))));

    Status status;
    status.set("Starting…");
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("screenWidth", ScreenWidth());
    engine.rootContext()->setContextProperty("windowHeight", ScreenHeight() - PanelHeight());
    engine.rootContext()->setContextProperty("status", &status);
    engine.load(QUrl("qrc:/main.qml"));
    if (engine.rootObjects().isEmpty())
        return 1;

    QTimer::singleShot(500, [&status] { run(status); });
    return app.exec();
}

#include "main.moc"
