cmake_minimum_required(VERSION 3.16)
project(AutoGpuSwitcherInterceptor LANGUAGES CXX)

add_executable(autogpuswitcher-launcher
    src/main.cpp
    src/heavy_app_db.cpp
    src/env_policy.cpp
)

target_include_directories(autogpuswitcher-launcher PRIVATE include)
target_compile_features(autogpuswitcher-launcher PRIVATE cxx_std_17)
