#include <gtest/gtest.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>

#include "config.hpp"
#include "gpu_detector.hpp"
#include "gpu_enforcer.hpp"
#include "hyprland_ipc_bridge.hpp"
#include "power_manager.hpp"
#include "state_writer.hpp"
#include "workload_classifier.hpp"

namespace fs = std::filesystem;

// ─────────────────────────────────────────────
// Helper: write a temp config and load it
// ─────────────────────────────────────────────
static fs::path write_temp_config(const std::string& content) {
    auto p = fs::path("/tmp") / ("titan_test_config_" + std::to_string(getpid()) + ".conf");
    std::ofstream f(p);
    f << content;
    f.close();
    return p;
}

static void cleanup_config(const fs::path& p) {
    fs::remove(p);
}

// ═════════════════════════════════════════════
// CONFIG PARSING TESTS
// ═════════════════════════════════════════════
class ConfigTest : public ::testing::Test {
protected:
    void SetUp() override {
        cfg_ = &titan::Config::instance();
    }
    titan::Config* cfg_;
};

TEST_F(ConfigTest, LoadValidConfig) {
    auto p = write_temp_config(R"(
[power]
default_profile = balanced
battery_profile = saver
dgpu_idle_timeout_sec = 60
power_transition_timeout_ms = 2000

[detector]
nvidia_driver = auto
render_node_igpu = /dev/dri/renderD128
render_node_dgpu = /dev/dri/renderD129

[apps]
steam = dgpu
blender = dgpu
kitty = igpu
code = igpu

[patterns]
*game* = dgpu
*browser* = igpu
*editor* = igpu
)");
    ASSERT_TRUE(cfg_->load(p));

    EXPECT_EQ(cfg_->power().default_profile, "balanced");
    EXPECT_EQ(cfg_->power().battery_profile, "saver");
    EXPECT_EQ(cfg_->power().dgpu_idle_timeout_sec, 60u);
    EXPECT_EQ(cfg_->power().power_transition_timeout_ms, 2000u);

    EXPECT_EQ(cfg_->detector().nvidia_driver, "auto");
    EXPECT_EQ(cfg_->detector().render_node_igpu, "/dev/dri/renderD128");
    EXPECT_EQ(cfg_->detector().render_node_dgpu, "/dev/dri/renderD129");

    EXPECT_EQ(cfg_->apps().at("steam").gpu_target, "dgpu");
    EXPECT_EQ(cfg_->apps().at("blender").gpu_target, "dgpu");
    EXPECT_EQ(cfg_->apps().at("kitty").gpu_target, "igpu");
    EXPECT_EQ(cfg_->apps().at("code").gpu_target, "igpu");

    cleanup_config(p);
}

TEST_F(ConfigTest, MissingFileReturnsFalse) {
    EXPECT_FALSE(cfg_->load("/tmp/nonexistent_titan_config.conf"));
}

TEST_F(ConfigTest, InvalidNumberDoesNotCrash) {
    auto p = write_temp_config(R"(
[power]
dgpu_idle_timeout_sec = not_a_number
power_transition_timeout_ms = abc
)");
    ASSERT_TRUE(cfg_->load(p));
    EXPECT_EQ(cfg_->power().dgpu_idle_timeout_sec, 30u);
    EXPECT_EQ(cfg_->power().power_transition_timeout_ms, 1000u);
    cleanup_config(p);
}

TEST_F(ConfigTest, CommentsAndBlankLinesIgnored) {
    auto p = write_temp_config(R"(
# this is a comment
   # indented comment

[apps]
# comment inside section
steam = dgpu

)");
    ASSERT_TRUE(cfg_->load(p));
    EXPECT_EQ(cfg_->apps().at("steam").gpu_target, "dgpu");
    cleanup_config(p);
}

TEST_F(ConfigTest, CaseInsensitiveKeys) {
    auto p = write_temp_config(R"(
[power]
DEFAULT_PROFILE = performance
Battery_Profile = saver
)");
    ASSERT_TRUE(cfg_->load(p));
    EXPECT_EQ(cfg_->power().default_profile, "performance");
    EXPECT_EQ(cfg_->power().battery_profile, "saver");
    cleanup_config(p);
}

TEST_F(ConfigTest, UnknownSectionsIgnored) {
    auto p = write_temp_config(R"(
[unknown_section]
key = value

[apps]
steam = dgpu
)");
    ASSERT_TRUE(cfg_->load(p));
    EXPECT_EQ(cfg_->apps().at("steam").gpu_target, "dgpu");
    cleanup_config(p);
}

TEST_F(ConfigTest, EmptyConfig) {
    auto p = write_temp_config("");
    ASSERT_TRUE(cfg_->load(p));
    EXPECT_EQ(cfg_->power().dgpu_idle_timeout_sec, 30u);
    EXPECT_TRUE(cfg_->apps().empty());
    EXPECT_TRUE(cfg_->patterns().empty());
    cleanup_config(p);
}

// ═════════════════════════════════════════════
// GLOB PATTERN MATCHING TESTS
// ═════════════════════════════════════════════
class GlobMatchTest : public ::testing::Test {
protected:
    void SetUp() override {
        auto p = write_temp_config(R"(
[power]
default_profile = auto

[patterns]
*game* = dgpu
*browser* = igpu
*editor* = igpu
*terminal* = igpu
steam* = dgpu
*firefox = igpu
)");
        titan::Config::instance().load(p);
        cleanup_config(p);
    }
};

TEST_F(GlobMatchTest, StarPrefixAndSuffix) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("mygame"), "dgpu");
    EXPECT_EQ(cfg.classify_app("game"), "dgpu");
    EXPECT_EQ(cfg.classify_app("super_game_launcher"), "dgpu");
}

TEST_F(GlobMatchTest, StarPrefixOnly) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("myfirefox"), "igpu");
    EXPECT_EQ(cfg.classify_app("firefox"), "igpu");
}

TEST_F(GlobMatchTest, StarSuffixOnly) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("steam"), "dgpu");
    EXPECT_EQ(cfg.classify_app("steamnative"), "dgpu");
}

TEST_F(GlobMatchTest, NoMatchFallsBack) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("randomapp"), "auto");
}

TEST_F(GlobMatchTest, EmptyInput) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app(""), "auto");
}

// ═════════════════════════════════════════════
// APP CLASSIFICATION TESTS
// ═════════════════════════════════════════════
class ClassifyAppTest : public ::testing::Test {
protected:
    void SetUp() override {
        auto p = write_temp_config(R"(
[power]
default_profile = auto

[apps]
steam = dgpu
lutris = dgpu
blender = dgpu
kitty = igpu
code = igpu

[patterns]
*game* = dgpu
*browser* = igpu
)");
        titan::Config::instance().load(p);
        cleanup_config(p);
    }
};

TEST_F(ClassifyAppTest, ExactAppMatch) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("steam"), "dgpu");
    EXPECT_EQ(cfg.classify_app("kitty"), "igpu");
}

TEST_F(ClassifyAppTest, ExactAppMatchCaseInsensitive) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("Steam"), "dgpu");
    EXPECT_EQ(cfg.classify_app("STEAM"), "dgpu");
    EXPECT_EQ(cfg.classify_app("KITTY"), "igpu");
}

TEST_F(ClassifyAppTest, PatternMatch) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("coolgame"), "dgpu");
    EXPECT_EQ(cfg.classify_app("chromebrowser"), "igpu");
}

TEST_F(ClassifyAppTest, AppMatchTakesPriorityOverPattern) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("steam"), "dgpu");
}

TEST_F(ClassifyAppTest, UnknownAppReturnsAuto) {
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("unknown_app_xyz"), "auto");
}

// ═════════════════════════════════════════════
// CLASSIFIER UNIT TESTS
// ═════════════════════════════════════════════
class ClassifierTest : public ::testing::Test {};

TEST_F(ClassifierTest, StringToTarget) {
    EXPECT_EQ(titan::Classifier::string_to_target("igpu"), titan::GpuTarget::IGPU);
    EXPECT_EQ(titan::Classifier::string_to_target("dgpu"), titan::GpuTarget::DGPU);
    EXPECT_EQ(titan::Classifier::string_to_target("auto"), titan::GpuTarget::Auto);
}

TEST_F(ClassifierTest, StringToTargetCaseInsensitive) {
    EXPECT_EQ(titan::Classifier::string_to_target("IGPU"), titan::GpuTarget::IGPU);
    EXPECT_EQ(titan::Classifier::string_to_target("DGPU"), titan::GpuTarget::DGPU);
    EXPECT_EQ(titan::Classifier::string_to_target("Auto"), titan::GpuTarget::Auto);
}

TEST_F(ClassifierTest, StringToTargetUnknown) {
    EXPECT_EQ(titan::Classifier::string_to_target(""), titan::GpuTarget::Auto);
    EXPECT_EQ(titan::Classifier::string_to_target("balanced"), titan::GpuTarget::Auto);
    EXPECT_EQ(titan::Classifier::string_to_target("garbage"), titan::GpuTarget::Auto);
}

TEST_F(ClassifierTest, TargetToString) {
    EXPECT_STREQ(titan::Classifier::target_to_string(titan::GpuTarget::IGPU), "igpu");
    EXPECT_STREQ(titan::Classifier::target_to_string(titan::GpuTarget::DGPU), "dgpu");
    EXPECT_STREQ(titan::Classifier::target_to_string(titan::GpuTarget::Auto), "auto");
}

TEST_F(ClassifierTest, ClassifyWithPowerBatteryPrefersIGPU) {
    titan::Classifier c;
    EXPECT_EQ(c.classify_with_power(titan::GpuTarget::Auto, true), titan::GpuTarget::IGPU);
}

TEST_F(ClassifierTest, ClassifyWithPowerACAllowsDGPU) {
    titan::Classifier c;
    EXPECT_EQ(c.classify_with_power(titan::GpuTarget::Auto, false), titan::GpuTarget::DGPU);
}

TEST_F(ClassifierTest, ClassifyWithPowerExplicitIGPUStaysIGPU) {
    titan::Classifier c;
    EXPECT_EQ(c.classify_with_power(titan::GpuTarget::IGPU, false), titan::GpuTarget::IGPU);
}

TEST_F(ClassifierTest, ClassifyWithPowerExplicitDGPUStaysDGPU) {
    titan::Classifier c;
    EXPECT_EQ(c.classify_with_power(titan::GpuTarget::DGPU, true), titan::GpuTarget::DGPU);
}

// ═════════════════════════════════════════════
// HYPRLAND IPC EVENT PARSING TESTS
// ═════════════════════════════════════════════
class IpcParseTest : public ::testing::Test {
protected:
    titan::HyprlandIpcBridge ipc_;
    titan::WindowEvent last_event_;
    bool event_received_ = false;

    void SetUp() override {
        ipc_.set_callback([this](const titan::WindowEvent& ev) {
            last_event_ = ev;
            event_received_ = true;
        });
    }
};

TEST_F(IpcParseTest, Activewindowv2Event) {
    ASSERT_TRUE(ipc_.parse_event("activewindowv2>>0x12345678,1234,firefox,Google"));
    EXPECT_EQ(last_event_.addr, "0x12345678");
    EXPECT_EQ(last_event_.pid, "1234");
    EXPECT_EQ(last_event_.wm_class, "firefox");
    EXPECT_EQ(last_event_.title, "Google");
    EXPECT_TRUE(event_received_);
}

TEST_F(IpcParseTest, Activewindowv2WithCommasInTitle) {
    ASSERT_TRUE(ipc_.parse_event("activewindowv2>>0x1,100,code,File: test.cpp, line 5"));
    EXPECT_EQ(last_event_.wm_class, "code");
    EXPECT_EQ(last_event_.title, "File: test.cpp, line 5");
}

TEST_F(IpcParseTest, NonActivewindowEventIgnored) {
    EXPECT_FALSE(ipc_.parse_event("workspace>>1"));
    EXPECT_FALSE(event_received_);
}

TEST_F(IpcParseTest, MonitorAddedEventIgnored) {
    EXPECT_FALSE(ipc_.parse_event("monitoradded>>DP-1"));
    EXPECT_FALSE(event_received_);
}

TEST_F(IpcParseTest, EmptyEventIgnored) {
    EXPECT_FALSE(ipc_.parse_event(""));
    EXPECT_FALSE(event_received_);
}

TEST_F(IpcParseTest, EmptyWmClassNotForwarded) {
    ipc_.parse_event("activewindowv2>>0x1,100,,Some Title");
    EXPECT_FALSE(event_received_);
}

TEST_F(IpcParseTest, PartialEventFields) {
    ASSERT_TRUE(ipc_.parse_event("activewindowv2>>0xabc,99,steam"));
    EXPECT_EQ(last_event_.addr, "0xabc");
    EXPECT_EQ(last_event_.pid, "99");
    EXPECT_EQ(last_event_.wm_class, "steam");
    EXPECT_TRUE(last_event_.title.empty());
}

// ═════════════════════════════════════════════
// GPU DETECTOR TESTS (real sysfs)
// ═════════════════════════════════════════════
class GpuDetectorTest : public ::testing::Test {
protected:
    titan::GpuDetector det_;
};

TEST_F(GpuDetectorTest, ScanFindsGPUs) {
    EXPECT_TRUE(det_.scan());
    EXPECT_GT(det_.gpus().size(), 0u);
}

TEST_F(GpuDetectorTest, DetectsIntelIGPU) {
    det_.scan();
    auto igpu = det_.find_igpu();
    ASSERT_NE(igpu, nullptr);
    EXPECT_EQ(igpu->vendor, titan::GpuVendor::Intel);
    EXPECT_EQ(igpu->vendor_name, "Intel");
    EXPECT_FALSE(igpu->render_node.empty());
}

TEST_F(GpuDetectorTest, DetectsNvidiaDGPU) {
    det_.scan();
    auto dgpu = det_.find_dgpu();
    ASSERT_NE(dgpu, nullptr);
    EXPECT_EQ(dgpu->vendor, titan::GpuVendor::NVIDIA);
    EXPECT_EQ(dgpu->vendor_name, "NVIDIA");
    EXPECT_FALSE(dgpu->pci_addr.empty());
}

TEST_F(GpuDetectorTest, RenderNodesExist) {
    det_.scan();
    for (const auto& g : det_.gpus()) {
        struct stat st;
        EXPECT_EQ(stat(g.render_node.c_str(), &st), 0)
            << "render node " << g.render_node << " does not exist";
    }
}

TEST_F(GpuDetectorTest, RenderNodeForVendor) {
    det_.scan();
    auto node = det_.render_node_for_vendor(titan::GpuVendor::Intel);
    EXPECT_FALSE(node.empty());
    auto node2 = det_.render_node_for_vendor(titan::GpuVendor::NVIDIA);
    EXPECT_FALSE(node2.empty());
}

TEST_F(GpuDetectorTest, RenderNodeForUnknownVendor) {
    det_.scan();
    auto node = det_.render_node_for_vendor(titan::GpuVendor::AMD);
    EXPECT_TRUE(node.empty());
}

// ═════════════════════════════════════════════
// POWER MANAGER TESTS (real sysfs)
// ═════════════════════════════════════════════
class PowerManagerTest : public ::testing::Test {
protected:
    titan::PowerManager pm_;
};

TEST_F(PowerManagerTest, InitSucceeds) {
    EXPECT_TRUE(pm_.init());
}

TEST_F(PowerManagerTest, CurrentSourceValid) {
    pm_.init();
    auto src = pm_.current_source();
    EXPECT_TRUE(src == titan::PowerSource::AC ||
                src == titan::PowerSource::Battery ||
                src == titan::PowerSource::Unknown);
}

TEST_F(PowerManagerTest, IsOnBatteryConsistent) {
    pm_.init();
    bool on_batt = pm_.is_on_battery();
    auto src = pm_.current_source();
    EXPECT_EQ(on_batt, (src == titan::PowerSource::Battery));
}

TEST_F(PowerManagerTest, GetPciPowerOnRealDevice) {
    pm_.init();
    titan::GpuDetector det;
    det.scan();
    auto dgpu = det.find_dgpu();
    if (dgpu) {
        auto ps = pm_.get_pci_power(dgpu->pci_addr);
        EXPECT_TRUE(ps == titan::PowerState::On ||
                    ps == titan::PowerState::Off ||
                    ps == titan::PowerState::Auto);
    }
}

TEST_F(PowerManagerTest, SetPciPowerInvalidPath) {
    pm_.init();
    EXPECT_FALSE(pm_.set_pci_power("99:99.9", titan::PowerState::On));
}

// ═════════════════════════════════════════════
// STATE WRITER TESTS
// ═════════════════════════════════════════════
class StateWriterTest : public ::testing::Test {};

TEST_F(StateWriterTest, WriteAndReadBack) {
    titan::GpuDetector det;
    det.scan();
    titan::PowerManager pm;
    pm.init();

    titan::StateWriter sw;
    sw.write(det, pm, titan::GpuTarget::Auto, "steam");

    auto path = titan::StateWriter::state_path();
    ASSERT_TRUE(fs::exists(path));

    std::ifstream f(path);
    std::string content((std::istreambuf_iterator<char>(f)),
                        std::istreambuf_iterator<char>());

    EXPECT_NE(content.find("\"target\""), std::string::npos);
    EXPECT_NE(content.find("\"power\""), std::string::npos);
    EXPECT_NE(content.find("\"dgpu\""), std::string::npos);
    EXPECT_NE(content.find("\"igpu\""), std::string::npos);
    EXPECT_NE(content.find("steam"), std::string::npos);
}

TEST_F(StateWriterTest, JsonEscapesActiveApp) {
    titan::GpuDetector det;
    det.scan();
    titan::PowerManager pm;
    pm.init();

    titan::StateWriter sw;
    sw.write(det, pm, titan::GpuTarget::Auto, "app\"with\\quotes\nand\nnewlines");

    auto path = titan::StateWriter::state_path();
    std::ifstream f(path);
    std::string content((std::istreambuf_iterator<char>(f)),
                        std::istreambuf_iterator<char>());

    EXPECT_NE(content.find("\\\""), std::string::npos);
    EXPECT_NE(content.find("\\\\"), std::string::npos);
    EXPECT_NE(content.find("\\n"), std::string::npos);
}

// ═════════════════════════════════════════════
// GPU ENFORCER TESTS
// ═════════════════════════════════════════════
class EnforcerTest : public ::testing::Test {
protected:
    void SetUp() override {
        auto p = write_temp_config(R"(
[power]
default_profile = auto
dgpu_idle_timeout_sec = 5

[apps]
steam = dgpu
kitty = igpu
)");
        titan::Config::instance().load(p);
        cleanup_config(p);

        det_.scan();
        pm_.init();
        enforcer_ = std::make_unique<titan::GpuEnforcer>(det_, pm_);
    }

    titan::GpuDetector det_;
    titan::PowerManager pm_;
    std::unique_ptr<titan::GpuEnforcer> enforcer_;
};

TEST_F(EnforcerTest, EnforceForSteamTargetsDGPU) {
    auto result = enforcer_->enforce_for_app("steam");
    EXPECT_EQ(result.target, titan::GpuTarget::DGPU);
}

TEST_F(EnforcerTest, EnforceForKittyTargetsIGPU) {
    auto result = enforcer_->enforce_for_app("kitty");
    EXPECT_EQ(result.target, titan::GpuTarget::IGPU);
}

TEST_F(EnforcerTest, DGPUClientCounting) {
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
    enforcer_->enforce_for_app("steam");
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
    enforcer_->enforce_for_app("kitty");
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, MultipleDGPUClients) {
    enforcer_->enforce_for_app("steam");
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
    enforcer_->enforce_for_app("steam");
    enforcer_->enforce_for_app("kitty");
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
    enforcer_->enforce_for_app("kitty");
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, ManualOverrideIGPU) {
    auto result = enforcer_->enforce_target(titan::GpuTarget::IGPU);
    EXPECT_EQ(result.target, titan::GpuTarget::IGPU);
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, ManualOverrideDGPU) {
    auto result = enforcer_->enforce_target(titan::GpuTarget::DGPU);
    EXPECT_EQ(result.target, titan::GpuTarget::DGPU);
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, ResetDGPUClients) {
    enforcer_->enforce_for_app("steam");
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
    enforcer_->reset_dgpu_clients();
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, WindowSetTrackingPreventsInflation) {
    // Repeated focus on the same window address must not inflate client count beyond 1
    for (int i = 0; i < 10; ++i) {
        enforcer_->enforce_for_app_window("steam", "0x100");
    }
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());
    EXPECT_EQ(enforcer_->active_dgpu_client_count(), 1u);

    // Remove window 0x100
    enforcer_->remove_dgpu_window("0x100");
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

TEST_F(EnforcerTest, WindowSwitchingBetweenGPUs) {
    // Focus Steam on dGPU (0x101)
    auto res1 = enforcer_->enforce_for_app_window("steam", "0x101");
    EXPECT_EQ(res1.target, titan::GpuTarget::DGPU);
    EXPECT_EQ(enforcer_->active_dgpu_client_count(), 1u);

    // Focus Kitty on iGPU (0x102) -> Steam (0x101) remains open in background
    auto res2 = enforcer_->enforce_for_app_window("kitty", "0x102");
    EXPECT_EQ(res2.target, titan::GpuTarget::IGPU);
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());

    // Focus Blender on dGPU (0x103) -> 2 dGPU windows open
    auto res3 = enforcer_->enforce_for_app_window("blender", "0x103");
    EXPECT_EQ(res3.target, titan::GpuTarget::DGPU);
    EXPECT_EQ(enforcer_->active_dgpu_client_count(), 2u);

    // Close Steam (0x101) -> 1 dGPU window remaining
    enforcer_->remove_dgpu_window("0x101");
    EXPECT_EQ(enforcer_->active_dgpu_client_count(), 1u);

    // Close Blender (0x103) -> 0 dGPU windows remaining
    enforcer_->remove_dgpu_window("0x103");
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}

// ═════════════════════════════════════════════
// EDGE CASE TESTS
// ═════════════════════════════════════════════
class EdgeCaseTest : public ::testing::Test {};

TEST_F(EdgeCaseTest, VeryLongAppName) {
    auto p = write_temp_config("[apps]\n");
    titan::Config::instance().load(p);
    cleanup_config(p);

    std::string long_name(1000, 'a');
    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app(long_name), "auto");
}

TEST_F(EdgeCaseTest, UnicodeAppName) {
    auto p = write_temp_config("[apps]\n");
    titan::Config::instance().load(p);
    cleanup_config(p);

    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("日本語アプリ"), "auto");
    EXPECT_EQ(cfg.classify_app("🎮game🎮"), "auto");
}

TEST_F(EdgeCaseTest, PathAsAppName) {
    auto p = write_temp_config("[apps]\n/usr/bin/steam = dgpu\n");
    titan::Config::instance().load(p);
    cleanup_config(p);

    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("/usr/bin/steam"), "dgpu");
}

TEST_F(EdgeCaseTest, EmptyWmClass) {
    auto p = write_temp_config("[apps]\nsteam = dgpu\n");
    titan::Config::instance().load(p);
    cleanup_config(p);

    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app(""), "auto");
}

TEST_F(EdgeCaseTest, DoubleStarPattern) {
    auto p = write_temp_config(R"(
[patterns]
** = dgpu
)");
    titan::Config::instance().load(p);
    cleanup_config(p);

    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("anything"), "dgpu");
}

TEST_F(EdgeCaseTest, StarOnlyPattern) {
    auto p = write_temp_config(R"(
[patterns]
* = igpu
)");
    titan::Config::instance().load(p);
    cleanup_config(p);

    auto& cfg = titan::Config::instance();
    EXPECT_EQ(cfg.classify_app("anything"), "igpu");
}

TEST_F(EdgeCaseTest, ClassifierRoundTrip) {
    EXPECT_STREQ(
        titan::Classifier::target_to_string(
            titan::Classifier::string_to_target("dgpu")),
        "dgpu");
    EXPECT_STREQ(
        titan::Classifier::target_to_string(
            titan::Classifier::string_to_target("igpu")),
        "igpu");
    EXPECT_STREQ(
        titan::Classifier::target_to_string(
            titan::Classifier::string_to_target("auto")),
        "auto");
}

TEST_F(EdgeCaseTest, GpuVendorEnumValues) {
    EXPECT_EQ(static_cast<uint16_t>(titan::GpuVendor::Intel), 0x8086);
    EXPECT_EQ(static_cast<uint16_t>(titan::GpuVendor::NVIDIA), 0x10de);
    EXPECT_EQ(static_cast<uint16_t>(titan::GpuVendor::AMD), 0x1002);
    EXPECT_EQ(static_cast<uint16_t>(titan::GpuVendor::Unknown), 0);
}

// ═════════════════════════════════════════════
// INTEGRATION: Full Classification Pipeline
// ═════════════════════════════════════════════
class IntegrationTest : public ::testing::Test {
protected:
    void SetUp() override {
        auto p = write_temp_config(R"(
[power]
default_profile = auto
battery_profile = saver
dgpu_idle_timeout_sec = 30

[apps]
steam = dgpu
lutris = dgpu
blender = dgpu
obs-studio = dgpu
mpv = dgpu
kitty = igpu
falkon = igpu
code = igpu

[patterns]
*game* = dgpu
*browser* = igpu
*editor* = igpu
*terminal* = igpu
)");
        titan::Config::instance().load(p);
        cleanup_config(p);
        det_.scan();
        pm_.init();
        enforcer_ = std::make_unique<titan::GpuEnforcer>(det_, pm_);
    }

    titan::GpuDetector det_;
    titan::PowerManager pm_;
    std::unique_ptr<titan::GpuEnforcer> enforcer_;
};

TEST_F(IntegrationTest, SteamLaunchesOnDGPU) {
    auto result = enforcer_->enforce_for_app("steam");
    EXPECT_EQ(result.target, titan::GpuTarget::DGPU);
}

TEST_F(IntegrationTest, KittyLaunchesOnIGPU) {
    auto result = enforcer_->enforce_for_app("kitty");
    EXPECT_EQ(result.target, titan::GpuTarget::IGPU);
}

TEST_F(IntegrationTest, GamePatternOnDGPU) {
    auto result = enforcer_->enforce_for_app("cyberpunk2077");
    EXPECT_EQ(result.target, titan::GpuTarget::DGPU);
}

TEST_F(IntegrationTest, BrowserPatternOnIGPU) {
    auto result = enforcer_->enforce_for_app("chromebrowser");
    EXPECT_EQ(result.target, titan::GpuTarget::IGPU);
}

TEST_F(IntegrationTest, UnknownAppFollowsPowerHeuristic) {
    titan::Classifier c;
    auto battery_target = c.classify_with_power(titan::GpuTarget::Auto, true);
    EXPECT_EQ(battery_target, titan::GpuTarget::IGPU);

    auto ac_target = c.classify_with_power(titan::GpuTarget::Auto, false);
    EXPECT_EQ(ac_target, titan::GpuTarget::DGPU);
}

TEST_F(IntegrationTest, ManualOverrideIgnoresRules) {
    enforcer_->enforce_for_app("steam");
    EXPECT_TRUE(enforcer_->has_active_dgpu_clients());

    auto result = enforcer_->enforce_target(titan::GpuTarget::IGPU);
    EXPECT_EQ(result.target, titan::GpuTarget::IGPU);
    EXPECT_FALSE(enforcer_->has_active_dgpu_clients());
}
