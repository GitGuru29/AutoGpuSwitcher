#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

#include "heavy_app_db.hpp"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++g_checks;                                                          \
        if (!(cond)) {                                                       \
            std::cerr << "FAIL " << __func__ << ":" << __LINE__ << ": "      \
                      << #cond << "\n";                                      \
            ++g_failures;                                                    \
        }                                                                    \
    } while (0)

static std::string write_fixture(const std::string& content) {
    std::string path = "/tmp/heavy_app_db_test_" + std::to_string(getpid()) + ".list";
    std::ofstream f(path);
    f << content;
    f.close();
    setenv("AUTOGPUSWITCHER_HEAVY_LIST_FILE", path.c_str(), 1);
    return path;
}

static void test_bare_name_record() {
    auto path = write_fixture("blender\n");
    CHECK(is_heavy_app("blender"));
    CHECK(is_heavy_app("/usr/bin/blender"));
    CHECK(!is_heavy_app("/usr/bin/not-blender"));
    unlink(path.c_str());
}

static void test_path_record_exact_match() {
    auto path = write_fixture("arch-linux|blender|/usr/bin/blender\n");
    CHECK(is_heavy_app("/usr/bin/blender"));
    CHECK(!is_heavy_app("/usr/local/bin/blender"));
    CHECK(is_heavy_app("blender"));
    unlink(path.c_str());
}

static void test_generic_basename_does_not_match_other_paths() {
    // Regression: "unknown|launcher|/opt/app/bin/launcher" must not force every
    // binary named "launcher" onto the dGPU.
    auto path = write_fixture("unknown|launcher|/opt/unigine-superposition/bin/launcher\n");
    CHECK(is_heavy_app("/opt/unigine-superposition/bin/launcher"));
    CHECK(!is_heavy_app("/usr/bin/launcher"));
    unlink(path.c_str());
}

static void test_case_insensitive_name_match() {
    auto path = write_fixture("pkg|Hyprland|/usr/bin/Hyprland\n");
    // Invocation by name is case-insensitive...
    CHECK(is_heavy_app("hyprland"));
    CHECK(is_heavy_app("HYPRLAND"));
    // ...but a recorded install path only matches that exact path.
    CHECK(is_heavy_app("/usr/bin/Hyprland"));
    CHECK(!is_heavy_app("/usr/bin/hyprland"));
    unlink(path.c_str());
}

static void test_two_field_record() {
    auto path = write_fixture("mpv|/usr/bin/mpv\n");
    CHECK(is_heavy_app("/usr/bin/mpv"));
    CHECK(is_heavy_app("mpv"));
    CHECK(!is_heavy_app("/usr/bin/other"));
    unlink(path.c_str());
}

static void test_comments_and_blank_lines_ignored() {
    auto path = write_fixture("# comment\n\n   \nsteam\n");
    CHECK(is_heavy_app("/usr/bin/steam"));
    CHECK(!is_heavy_app("comment"));
    unlink(path.c_str());
}

static void test_missing_file_is_not_heavy() {
    setenv("AUTOGPUSWITCHER_HEAVY_LIST_FILE", "/tmp/does_not_exist_heavy_list", 1);
    CHECK(!is_heavy_app("/usr/bin/steam"));
    CHECK(!is_heavy_app(""));
    CHECK(!is_heavy_app(nullptr));
}

int main() {
    test_bare_name_record();
    test_path_record_exact_match();
    test_generic_basename_does_not_match_other_paths();
    test_case_insensitive_name_match();
    test_two_field_record();
    test_comments_and_blank_lines_ignored();
    test_missing_file_is_not_heavy();

    std::cout << g_checks << " checks, " << g_failures << " failure(s)\n";
    return g_failures == 0 ? 0 : 1;
}
