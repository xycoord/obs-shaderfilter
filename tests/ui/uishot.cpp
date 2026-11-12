/*
 * Capture the plugin's real properties UI offscreen, laid out like OBS's
 * Filters dialog (preview, filter list, properties of the selected filter),
 * so the UI can be reviewed and compared between builds.
 *
 *   uishot --obs-prefix DIR --obs-plugin SO --data DIR --spec JSON --out DIR
 *
 * Run with QT_QPA_PLATFORM=offscreen and an X display for libobs (Xvfb).
 *
 * Spec:
 * { "image": "test.png",
 *   "shots": [ { "name": "five",
 *                "source": "Graphics",            source name in the title
 *                "filters": [ { "settings": {...}, "name": "...", "enabled": true } ],
 *                "ui": [ { "filter": 0, "property": "x", "value": ... } ],
 *                     values set as if through the UI (fires the property's
 *                     modified callback, then updates the filter)
 *                "select": 2,                       filter shown in the panel
 *                "size": [1100, 860],
 *                "panel": true,                     also <name>_panel.png, full height
 *                "open_combo": 0                    also <name>_list.png: that (nth) dropdown's entries
 *              } ] }
 */
#include <QApplication>
#include <QTranslator>
#include <QTextStream>
#include <map>
#include <QComboBox>
#include <QKeyEvent>
#include <QFile>
#include <QFont>
#include <QHBoxLayout>
#include <QImage>
#include <QLabel>
#include <QListView>
#include <QListWidget>
#include <QPainter>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>
#include <obs.hpp>
#include <unistd.h>
#include <util/platform.h>

#include "obsenv.h"
#include "properties-view.hpp"
#include <QThread>

static const char *style = R"(
QWidget { background: transparent; color: #FEFEFE; font-size: 10pt; }
QWidget#root { background: #1D1F26; }
QListView, QAbstractItemView { background: #272A33; }
QLabel { background: transparent; }
QListWidget, QComboBox, QLineEdit, QPlainTextEdit, QTextEdit, QSpinBox, QDoubleSpinBox, QAbstractSpinBox {
  background: #3C404D; border: 1px solid #3C404D; border-radius: 4px; padding: 3px 5px; }
QComboBox QAbstractItemView { background: #272A33; selection-background-color: #284CB8; }
QListWidget::item:selected { background: #284CB8; }
QPushButton { background: #3C404D; border: 1px solid #3C404D; border-radius: 4px; padding: 5px 12px; }
QGroupBox { border: 1px solid #3C404D; border-radius: 4px; margin-top: 18px; padding-top: 6px; }
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
QScrollArea, QScrollArea > QWidget > QWidget { background: #272A33; border: none; }
QSlider::groove:horizontal { height: 4px; background: #3C404D; }
QSlider::handle:horizontal { background: #FEFEFE; width: 12px; margin: -5px 0; border-radius: 6px; }
QCheckBox { background: transparent; }
QCheckBox::indicator { width: 14px; height: 14px; border: 1px solid #8F96A6; border-radius: 3px; background: #3C404D; }
QCheckBox::indicator:checked { background: #476BD7; border-color: #476BD7; image: url(:/res/images/check.svg); }
QLabel[class="text-danger"] { color: #F25858; }
QLabel[class="text-warning"] { color: #FFCC4C; }
)";

/* OBS's frontend translates its widgets' strings through Qt; use its en-US.ini. */
class IniTranslator : public QTranslator {
	std::map<QString, QString> map;

public:
	explicit IniTranslator(const QString &path)
	{
		QFile f(path);
		if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
			return;
		QTextStream in(&f);
		while (!in.atEnd()) {
			QString line = in.readLine();
			int eq = line.indexOf('=');
			if (eq <= 0)
				continue;
			QString v = line.mid(eq + 1).trimmed();
			if (v.startsWith('"') && v.endsWith('"') && v.size() >= 2)
				v = v.mid(1, v.size() - 2);
			map[line.left(eq).trimmed()] = v;
		}
	}
	bool isEmpty() const override { return map.empty(); }
	QString translate(const char *, const char *source, const char *, int) const override
	{
		auto it = map.find(QString::fromUtf8(source));
		return it == map.end() ? QString() : it->second;
	}
};

static void update_cb(void *obj, obs_data_t *, obs_data_t *settings)
{
	obs_source_update((obs_source_t *)obj, settings);
}

static void apply_ui_value(obs_source_t *filter, obs_data_t *item)
{
	const char *prop_name = obs_data_get_string(item, "property");
	/* As in OBS: the panel is built first, then the person changes a control. */
	obs_properties_t *props = obs_source_properties(filter);
	obs_data_t *settings = obs_source_get_settings(filter);
	obs_data_item_t *v = obs_data_item_byname(item, "value");
	switch (obs_data_item_gettype(v)) {
	case OBS_DATA_STRING:
		obs_data_set_string(settings, prop_name, obs_data_item_get_string(v));
		break;
	case OBS_DATA_NUMBER:
		if (obs_data_item_numtype(v) == OBS_DATA_NUM_INT)
			obs_data_set_int(settings, prop_name, obs_data_item_get_int(v));
		else
			obs_data_set_double(settings, prop_name, obs_data_item_get_double(v));
		break;
	case OBS_DATA_BOOLEAN:
		obs_data_set_bool(settings, prop_name, obs_data_item_get_bool(v));
		break;
	default:
		break;
	}
	obs_data_item_release(&v);
	obs_property_t *p = obs_properties_get(props, prop_name);
	if (p)
		obs_property_modified(p, settings);
	else
		fprintf(stderr, "no property '%s'\n", prop_name);
	obs_source_update(filter, settings);
	obs_properties_destroy(props);
	obs_data_release(settings);
}

static QImage source_preview(obs_source_t *source)
{
	uint8_t *rgba = nullptr;
	uint32_t w, h;
	if (!env_render(source, &rgba, &w, &h))
		return QImage();
	QImage img(rgba, (int)w, (int)h, (int)w * 4, QImage::Format_RGBA8888_Premultiplied);
	QImage copy = img.copy();
	bfree(rgba);
	/* Composite over a checkerboard, as transparent areas would look. */
	QImage out((int)w, (int)h, QImage::Format_RGB32);
	QPainter p(&out);
	for (int y = 0; y < (int)h; y += 16)
		for (int x = 0; x < (int)w; x += 16)
			p.fillRect(x, y, 16, 16, ((x + y) / 16) % 2 ? QColor(70, 70, 70) : QColor(45, 45, 45));
	p.drawImage(0, 0, copy);
	return out;
}

int main(int argc, char **argv)
{
	const char *prefix = nullptr, *plugin = nullptr, *data = nullptr, *spec_path = nullptr, *out = nullptr,
		   *locale = nullptr;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--obs-prefix"))
			prefix = argv[i + 1];
		else if (!strcmp(argv[i], "--obs-plugin"))
			plugin = argv[i + 1];
		else if (!strcmp(argv[i], "--data"))
			data = argv[i + 1];
		else if (!strcmp(argv[i], "--spec"))
			spec_path = argv[i + 1];
		else if (!strcmp(argv[i], "--out"))
			out = argv[i + 1];
		else if (!strcmp(argv[i], "--locale"))
			locale = argv[i + 1];
	}
	if (!prefix || !plugin || !data || !spec_path || !out) {
		fprintf(stderr, "usage: uishot --obs-prefix DIR --obs-plugin SO --data DIR --spec JSON --out DIR\n");
		return 2;
	}
	QApplication app(argc, argv);
	QFont font("Noto Sans");
	font.setPointSize(10);
	app.setFont(font);
	app.setStyle("Fusion");
	app.setStyleSheet(style);
	QPalette pal = app.palette();
	pal.setColor(QPalette::Link, QColor("#7BA6F5"));
	app.setPalette(pal);
	IniTranslator *tr = locale ? new IniTranslator(locale) : nullptr;
	if (tr)
		app.installTranslator(tr);

	if (!env_start(prefix, plugin, data, 1280, 720))
		return 1;
	os_mkdirs(out);

	OBSDataAutoRelease spec = obs_data_create_from_json_file(spec_path);
	OBSDataArrayAutoRelease shots = obs_data_get_array(spec, "shots");
	for (size_t si = 0; si < obs_data_array_count(shots); si++) {
		OBSDataAutoRelease shot = obs_data_array_item(shots, si);
		const char *shot_name = obs_data_get_string(shot, "name");

		OBSDataAutoRelease img_settings = obs_data_create();
		obs_data_set_string(img_settings, "file", obs_data_get_string(spec, "image"));
		const char *src_name = obs_data_has_user_value(shot, "source") ? obs_data_get_string(shot, "source")
										: "Graphics";
		OBSSourceAutoRelease source = obs_source_create("image_source", src_name, img_settings, nullptr);

		std::vector<OBSSource> filters;
		OBSDataArrayAutoRelease fa = obs_data_get_array(shot, "filters");
		const char *default_name = nullptr;
		for (size_t fi = 0; fi < obs_data_array_count(fa); fi++) {
			OBSDataAutoRelease f = obs_data_array_item(fa, fi);
			OBSDataAutoRelease fs = obs_data_get_obj(f, "settings");
			if (!default_name)
				default_name = obs_source_get_display_name("shader_filter");
			/* Name new filters as OBS does: the type's name, then " 2", " 3"... */
			std::string name = obs_data_has_user_value(f, "name") ? obs_data_get_string(f, "name")
										 : std::string(default_name);
			if (!obs_data_has_user_value(f, "name")) {
				for (int k = 2;; k++) {
					OBSSourceAutoRelease existing = obs_source_get_filter_by_name(source, name.c_str());
					if (!existing)
						break;
					name = std::string(default_name) + " " + std::to_string(k);
				}
			}
			OBSSourceAutoRelease filter = obs_source_create("shader_filter", name.c_str(), fs, nullptr);
			obs_source_filter_add(source, filter);
			if (obs_data_has_user_value(f, "enabled"))
				obs_source_set_enabled(filter, obs_data_get_bool(f, "enabled"));
			filters.push_back(OBSSource(filter.Get()));
		}
		for (int t = 0; t < 3; t++)
			env_tick(0.05f);

		OBSDataArrayAutoRelease ui = obs_data_get_array(shot, "ui");
		for (size_t k = 0; k < obs_data_array_count(ui); k++) {
			OBSDataAutoRelease item = obs_data_array_item(ui, k);
			size_t idx = (size_t)obs_data_get_int(item, "filter");
			if (obs_data_has_user_value(item, "wait_ms")) {
				/* time passing, e.g. closing the window and coming back */
				QThread::msleep((unsigned long)obs_data_get_int(item, "wait_ms"));
				env_tick(0.05f);
				continue;
			}
			if (idx < filters.size()) {
				apply_ui_value(filters[idx], item);
				for (int t = 0; t < 3; t++)
					env_tick(0.05f);
			}
		}

		/* A few seconds pass before the screenshot, as between setting a
		 * filter up and coming back to it, with the source on screen (so
		 * the filters' GPU time has been measured). */
		for (int t = 0; t < 125; t++) {
			env_tick(1.0f / 60.0f);
			if (t % 4 == 0) {
				uint8_t *px = nullptr;
				uint32_t pw, ph;
				if (env_render(source, &px, &pw, &ph))
					bfree(px);
			}
			QThread::msleep(20);
		}

		size_t sel = (size_t)obs_data_get_int(shot, "select");
		if (sel >= filters.size())
			sel = filters.empty() ? 0 : filters.size() - 1;

		/* --- the window --- */
		QWidget window;
		window.setObjectName("root");
		int ww = 1100, wh = 860;
		OBSDataArrayAutoRelease size = obs_data_get_array(shot, "size");
		if (obs_data_array_count(size) == 2) {
			OBSDataAutoRelease a = obs_data_array_item(size, 0), b = obs_data_array_item(size, 1);
			ww = (int)obs_data_get_int(a, "value");
			wh = (int)obs_data_get_int(b, "value");
		}
		window.resize(ww, wh);
		auto *root = new QVBoxLayout(&window);
		auto *title = new QLabel(QString("Filters for '%1'").arg(src_name));
		title->setStyleSheet("font-weight: bold; padding: 2px;");
		root->addWidget(title);

		auto *preview = new QLabel();
		preview->setAlignment(Qt::AlignCenter);
		preview->setMinimumHeight(wh * 36 / 100);
		preview->setMaximumHeight(wh * 36 / 100);
		preview->setStyleSheet("background: #13141A;");
		QImage pimg = source_preview(source);
		if (!pimg.isNull())
			preview->setPixmap(QPixmap::fromImage(
				pimg.scaled(ww - 40, wh * 36 / 100 - 8, Qt::KeepAspectRatio, Qt::SmoothTransformation)));
		root->addWidget(preview);

		auto *body = new QHBoxLayout();
		auto *left = new QVBoxLayout();
		left->addWidget(new QLabel("Effect Filters"));
		auto *list = new QListWidget();
		/* OBS lists the filter applied last at the bottom. */
		for (size_t fi = 0; fi < filters.size(); fi++) {
			auto *it = new QListWidgetItem(QString::fromUtf8(obs_source_get_name(filters[fi])));
			it->setFlags(it->flags() | Qt::ItemIsUserCheckable);
			it->setCheckState(obs_source_enabled(filters[fi]) ? Qt::Checked : Qt::Unchecked);
			list->addItem(it);
		}
		if (!filters.empty())
			list->setCurrentRow((int)sel);
		list->setFixedWidth(250);
		left->addWidget(list);
		auto *btns = new QHBoxLayout();
		for (const char *b : {"+", "-", "↑", "↓"}) {
			auto *pb = new QPushButton(b);
			pb->setFixedWidth(40);
			btns->addWidget(pb);
		}
		btns->addStretch();
		left->addLayout(btns);
		body->addLayout(left);

		OBSPropertiesView *view = nullptr;
		if (!filters.empty()) {
			obs_source_t *f = filters[sel];
			OBSDataAutoRelease fs = obs_source_get_settings(f);
			view = new OBSPropertiesView(fs.Get(), f, (PropertiesReloadCallback)obs_source_properties,
						     (PropertiesUpdateCallback)update_cb);
			body->addWidget(view, 1);
		}
		root->addLayout(body, 1);
		auto *bottom = new QHBoxLayout();
		bottom->addWidget(new QPushButton("Defaults"));
		bottom->addStretch();
		bottom->addWidget(new QPushButton("Close"));
		root->addLayout(bottom);

		window.show();
		for (int k = 0; k < 5; k++)
			app.processEvents();
		if (getenv("UISHOT_RELAYOUT")) {
			window.resize(window.width() + 1, window.height());
			app.processEvents();
			window.resize(window.width() - 1, window.height());
			for (int k = 0; k < 5; k++)
				app.processEvents();
		}
		if (getenv("UISHOT_DEBUG") && view)
			for (QLabel *l : view->findChildren<QLabel *>())
				if (l->isVisible())
					fprintf(stderr, "LABEL y=%d h=%d w=%d hfw=%d wrap=%d align=%x '%s'\n", l->mapTo(view, QPoint(0, 0)).y(),
						l->height(), l->width(), l->heightForWidth(l->width()), l->wordWrap(),
						(unsigned)l->alignment(), l->text().left(40).toUtf8().constData());
		window.grab().save(QString("%1/%2.png").arg(out, shot_name));

		if (view && obs_data_get_bool(shot, "panel")) {
			/* The whole panel, as if the window were tall enough not to scroll. */
			QWidget *content = static_cast<QScrollArea *>(view)->widget();
			content->resize(view->viewport()->width(), content->sizeHint().height());
			app.processEvents();
			content->grab().save(QString("%1/%2_panel.png").arg(out, shot_name));
		}
		if (getenv("UISHOT_KEYTEST") && view && !filters.empty()) {
			/* Press Down on the Shader list a few times, as a person would. */
			QList<QComboBox *> cs = view->findChildren<QComboBox *>();
			if (!cs.isEmpty()) {
				window.activateWindow();
				cs[0]->setFocus();
				app.processEvents();
				for (int k = 0; k < 4; k++) {
					QWidget *fw = QApplication::focusWidget();
					auto *cb = qobject_cast<QComboBox *>(fw);
					fprintf(stderr, "KEY %d focus=%s combo=%s\n", k, fw ? fw->metaObject()->className() : "none",
						cb ? cb->currentText().toUtf8().constData() : "-");
					if (!fw)
						break;
					QKeyEvent down(QEvent::KeyPress, k == 3 ? Qt::Key_Up : Qt::Key_Down, Qt::NoModifier);
					QApplication::sendEvent(fw, &down);
					for (int t = 0; t < 10; t++) {
						app.processEvents();
						env_tick(0.05f);
						QThread::msleep(30);
					}
					OBSDataAutoRelease st = obs_source_get_settings(filters[sel]);
					fprintf(stderr, "    -> file=%s name=%s\n", obs_data_get_string(st, "shader_file_name"),
						obs_source_get_name(filters[sel]));
				}
				QWidget *fw = QApplication::focusWidget();
				auto *cb = qobject_cast<QComboBox *>(fw);
				fprintf(stderr, "KEY end focus=%s combo=%s\n", fw ? fw->metaObject()->className() : "none",
					cb ? cb->currentText().toUtf8().constData() : "-");
			}
		}
		int combo_index = obs_data_has_user_value(shot, "open_combo") ? (int)obs_data_get_int(shot, "open_combo") : -1;
		QList<QComboBox *> combos = view ? view->findChildren<QComboBox *>() : QList<QComboBox *>();
		if (combo_index >= 0 && combo_index < combos.size()) {
			/* Render every entry of that dropdown as one tall list. */
			QComboBox *combo = combos[combo_index];
			QListView lv;
			lv.setModel(combo->model());
			lv.setStyleSheet("QListView { background: #272A33; } QListView::item { padding: 3px; } "
					 "QListView::item:disabled { color: #8F96A6; }");
			lv.setCurrentIndex(combo->model()->index(combo->currentIndex(), 0));
			int rowh = lv.sizeHintForRow(0) > 0 ? lv.sizeHintForRow(0) : 22;
			lv.resize(std::max(combo->width(), 420), std::min(combo->count() * rowh + 8, 4800));
			lv.show();
			app.processEvents();
			lv.grab().save(QString("%1/%2_list.png").arg(out, shot_name));
		}
		window.hide();
		for (auto &f : filters)
			obs_source_filter_remove(source, f);
		filters.clear();
		obs_source_remove(source);
	}
	fflush(stderr);
	_exit(0);
}
