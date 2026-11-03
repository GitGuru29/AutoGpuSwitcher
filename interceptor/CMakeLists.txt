cmake_minimum_required(VERSION 3.16)
project(AutoGpuSwitcherInterceptor VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(autogpuswitcher-launcher
    src/main.cpp
    src/heavy_app_db.cpp
    src/env_policy.cpp
)

target_include_directories(autogpuswitcher-launcher PRIVATE include)
target_compile_features(autogpuswitcher-launcher PRIVATE cxx_std_17)
target_compile_options(autogpuswitcher-launcher PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS autogpuswitcher-launcher DESTINATION bin)

enable_testing()
add_executable(heavy-app-db-tests
    tests/test_heavy_app_db.cpp
    src/heavy_app_db.cpp
)
target_include_directories(heavy-app-db-tests PRIVATE include)
target_compile_features(heavy-app-db-tests PRIVATE cxx_std_17)
target_compile_options(heavy-app-db-tests PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME HeavyAppDbTests COMMAND heavy-app-db-tests)
