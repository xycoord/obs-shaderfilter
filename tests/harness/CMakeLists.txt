cmake_minimum_required(VERSION 3.18)
project(shaderfilter-harness C)

find_package(libobs REQUIRED)
find_package(PNG REQUIRED)
find_package(X11 REQUIRED)

add_executable(harness harness.c)
target_link_libraries(harness OBS::libobs PNG::PNG X11::X11 ${CMAKE_DL_LIBS})

add_library(detshim SHARED detshim.c)
target_link_libraries(detshim ${CMAKE_DL_LIBS})
