cmake_minimum_required(VERSION 3.16)
project(titan-gpu VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(GNUInstallDirs)

set(TITAN_WARNINGS -Wall -Wextra -Wpedantic)

add_library(titan-core STATIC
    src/config.cpp
    src/gpu_detector.cpp
    src/power_manager.cpp
    src/workload_classifier.cpp
    src/gpu_enforcer.cpp
    src/hyprland_ipc_bridge.cpp
    src/state_writer.cpp
    src/workload_analyzer.cpp
    src/cli.cpp
)
target_include_directories(titan-core PUBLIC include)
target_compile_features(titan-core PUBLIC cxx_std_17)
target_compile_options(titan-core PRIVATE ${TITAN_WARNINGS})

add_executable(titan-gpu-switcherd src/main.cpp)
target_link_libraries(titan-gpu-switcherd PRIVATE titan-core)
target_compile_options(titan-gpu-switcherd PRIVATE ${TITAN_WARNINGS})

add_executable(titan-gpu src/cli_main.cpp src/cli.cpp)
target_link_libraries(titan-gpu PRIVATE titan-core)
target_compile_options(titan-gpu PRIVATE ${TITAN_WARNINGS})

install(TARGETS titan-gpu-switcherd titan-gpu DESTINATION ${CMAKE_INSTALL_BINDIR})

# Config::default_path() reads /etc/titan-gpu/config, so keep it absolute.
set(TITAN_SYSCONFDIR "/etc" CACHE PATH "System-wide config directory")
install(FILES configs/titan-gpu.config.default
        DESTINATION ${TITAN_SYSCONFDIR}/titan-gpu RENAME config)
install(FILES systemd/titan-gpu-switcherd.service
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/systemd/user)
install(FILES udev/99-nvidia-power.rules
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/udev/rules.d)
install(PROGRAMS waybar/titan-gpu.sh
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/autogpuswitcher/waybar)
add_executable(titan-gpu-tests
    tests/test_all.cpp
    src/config.cpp
    src/gpu_detector.cpp
    src/power_manager.cpp
    src/workload_classifier.cpp
    src/gpu_enforcer.cpp
    src/hyprland_ipc_bridge.cpp
    src/state_writer.cpp
    src/workload_analyzer.cpp
)

target_include_directories(titan-gpu-tests PRIVATE include)
target_compile_features(titan-gpu-tests PRIVATE cxx_std_17)
target_compile_options(titan-gpu-tests PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(titan-gpu-tests PRIVATE GTest::gtest GTest::gtest_main)

include(CTest)
if(BUILD_TESTING)
    find_package(GTest QUIET)
    if(GTest_FOUND)
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
        target_compile_options(titan-gpu-tests PRIVATE ${TITAN_WARNINGS})
        target_link_libraries(titan-gpu-tests PRIVATE GTest::gtest GTest::gtest_main)
        add_test(NAME TitanGpuTests COMMAND titan-gpu-tests)
    else()
        message(WARNING "GTest not found - unit tests disabled (install gtest to enable)")
    endif()
endif()
