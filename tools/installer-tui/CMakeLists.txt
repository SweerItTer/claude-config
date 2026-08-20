cmake_minimum_required(VERSION 3.16)
project(claude_installer_tui LANGUAGES CXX)

# 只支持 Linux x86_64
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "installer-tui only supports Linux")
endif()
if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64)$")
  message(FATAL_ERROR "installer-tui only supports Linux x86_64")
endif()

find_package(ftxui CONFIG REQUIRED)
find_package(Threads REQUIRED)

add_executable(installer-tui
  src/main.cpp
  src/engine.cpp
  src/ui.cpp
)

target_include_directories(installer-tui PRIVATE src)

target_compile_features(installer-tui PRIVATE cxx_std_17)

target_link_libraries(installer-tui PRIVATE
  ftxui::component
  ftxui::dom
  ftxui::screen
  Threads::Threads
)
