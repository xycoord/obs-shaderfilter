cmake_minimum_required(VERSION 3.18)
project(shaderfilter-uishot C CXX)

# OBS_SOURCE_DIR: an obs-studio checkout (for shared/properties-view, the
# widget OBS itself uses to show filter properties). The test libobs from
# tests/setup/build-libobs.sh provides libobs and libobs-frontend-api.
set(OBS_SOURCE_DIR "" CACHE PATH "obs-studio source tree")
find_package(libobs REQUIRED)
find_package(obs-frontend-api REQUIRED)
find_package(Qt6 REQUIRED Core Widgets)
find_package(X11 REQUIRED)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_CXX_STANDARD 17)

set(S ${OBS_SOURCE_DIR}/shared)

# OBS 33 uses two Qt 6.6/6.7 APIs; patch copies so distribution Qt (6.4) works.
file(READ ${S}/properties-view/properties-view.cpp PV)
string(REPLACE "&QCheckBox::checkStateChanged" "&QCheckBox::stateChanged" PV "${PV}")
file(WRITE ${CMAKE_BINARY_DIR}/patched/properties-view.cpp "${PV}")
file(READ ${S}/qt/wrappers/qt-wrappers.cpp QW)
string(REPLACE "mb.setOption(QMessageBox::Option::DontUseNativeDialog, true);" "" QW "${QW}")
file(WRITE ${CMAKE_BINARY_DIR}/patched/qt-wrappers.cpp "${QW}")
file(WRITE ${CMAKE_BINARY_DIR}/check.svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 14 14\"><path d=\"M3 7.5l2.5 2.5L11 4.5\" fill=\"none\" stroke=\"#FEFEFE\" stroke-width=\"2\"/></svg>")
file(WRITE ${CMAKE_BINARY_DIR}/res.qrc "<RCC><qresource prefix=\"/res/images\">
<file alias=\"help.svg\">${OBS_SOURCE_DIR}/frontend/forms/images/help.svg</file>
<file alias=\"check.svg\">${CMAKE_BINARY_DIR}/check.svg</file>
<file alias=\"help_light.svg\">${OBS_SOURCE_DIR}/frontend/forms/images/help_light.svg</file>
</qresource></RCC>")

add_executable(uishot
  uishot.cpp obsenv.c ${CMAKE_BINARY_DIR}/res.qrc
  ${CMAKE_BINARY_DIR}/patched/properties-view.cpp ${S}/properties-view/properties-view.hpp
  ${S}/properties-view/properties-view.moc.hpp
  ${S}/properties-view/double-slider.cpp ${S}/properties-view/double-slider.hpp
  ${S}/properties-view/spinbox-ignorewheel.cpp ${S}/properties-view/spinbox-ignorewheel.hpp
  ${CMAKE_BINARY_DIR}/patched/qt-wrappers.cpp ${S}/qt/wrappers/qt-wrappers.hpp
  ${S}/qt/plain-text-edit/plain-text-edit.cpp ${S}/qt/plain-text-edit/plain-text-edit.hpp
  ${S}/qt/vertical-scroll-area/vertical-scroll-area.cpp ${S}/qt/vertical-scroll-area/vertical-scroll-area.hpp
  ${S}/qt/slider-ignorewheel/slider-ignorewheel.cpp ${S}/qt/slider-ignorewheel/slider-ignorewheel.hpp
  ${S}/qt/icon-label/IconLabel.cpp ${S}/qt/icon-label/IconLabel.hpp
  ${S}/qt/obs-spinbox/AutoSelectLineEdit.cpp ${S}/qt/obs-spinbox/AutoSelectLineEdit.hpp
  ${S}/qt/obs-spinbox/DoubleSpinBox.cpp ${S}/qt/obs-spinbox/DoubleSpinBox.hpp
  ${S}/qt/obs-spinbox/SpinBox.cpp ${S}/qt/obs-spinbox/SpinBox.hpp)
target_include_directories(uishot PRIVATE ${S}/properties-view ${S}/qt/wrappers ${S}/qt/plain-text-edit
  ${S}/qt/vertical-scroll-area ${S}/qt/slider-ignorewheel ${S}/qt/icon-label ${S}/qt/obs-spinbox)
target_link_libraries(uishot OBS::libobs OBS::obs-frontend-api Qt::Core Qt::Widgets X11::X11)
