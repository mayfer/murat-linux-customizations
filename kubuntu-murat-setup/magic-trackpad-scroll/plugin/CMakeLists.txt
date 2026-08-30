cmake_minimum_required(VERSION 3.22)

project(murat_magic_trackpad_scroll VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(ECM REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH "${ECM_MODULE_PATH}")

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Widgets)
find_package(KF6 REQUIRED COMPONENTS Config)
find_package(KWin 6.6 REQUIRED COMPONENTS kwineffects)

add_library(murat_magic_trackpad_scroll MODULE
    main.cpp
    magictrackpadscroll.cpp
    magictrackpadscroll.h
    scrollphysics.cpp
    scrollphysics.h
)

target_link_libraries(murat_magic_trackpad_scroll PRIVATE
    KWin::kwin
    KF6::ConfigCore
    Qt6::Core
)

target_compile_options(murat_magic_trackpad_scroll PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror=return-type
)

set_target_properties(murat_magic_trackpad_scroll PROPERTIES
    PREFIX ""
)

include(CTest)
if(BUILD_TESTING)
    add_executable(scrollphysics_test
        tests/scrollphysics_test.cpp
        scrollphysics.cpp
    )
    target_include_directories(scrollphysics_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(scrollphysics_test PRIVATE Qt6::Core)
    add_test(NAME scrollphysics_test COMMAND scrollphysics_test)
endif()
