cmake_minimum_required(VERSION 3.16)
project(titan-gpu VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(titan-gpu-switcherd
    src/main.cpp
    src/config.cpp
    src/gpu_detector.cpp
    src/power_manager.cpp
    src/workload_classifier.cpp
    src/gpu_enforcer.cpp
    src/hyprland_ipc_bridge.cpp
    src/state_writer.cpp
    src/cli.cpp
)

target_include_directories(titan-gpu-switcherd PRIVATE include)
target_compile_features(titan-gpu-switcherd PRIVATE cxx_std_17)
target_compile_options(titan-gpu-switcherd PRIVATE -Wall -Wextra -Wpedantic)

add_executable(titan-gpu
    src/cli_main.cpp
    src/cli.cpp
    src/config.cpp
    src/gpu_detector.cpp
    src/power_manager.cpp
)

target_include_directories(titan-gpu PRIVATE include)
target_compile_features(titan-gpu PRIVATE cxx_std_17)
target_compile_options(titan-gpu PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS titan-gpu-switcherd titan-gpu DESTINATION bin)

enable_testing()
find_package(GTest REQUIRED)

add_executable(titan-gpu-tests
    tests/test_all.cpp
    src/config.cpp
    src/gpu_detector.cpp
    src/power_manager.cpp
    src/workload_classifier.cpp
    src/gpu_enforcer.cpp
    src/hyprland_ipc_bridge.cpp
    src/state_writer.cpp
)

target_include_directories(titan-gpu-tests PRIVATE include)
target_compile_features(titan-gpu-tests PRIVATE cxx_std_17)
target_link_libraries(titan-gpu-tests PRIVATE GTest::gtest GTest::gtest_main)

add_test(NAME TitanGpuTests COMMAND titan-gpu-tests)
