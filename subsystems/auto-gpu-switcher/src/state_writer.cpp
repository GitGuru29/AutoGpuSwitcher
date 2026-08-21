#include "state_writer.hpp"

#include <fstream>
#include <iostream>
#include <sstream>

namespace titan {

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\t': out += "\\t"; break;
            default:   out += c; break;
        }
    }
    return out;
}

std::filesystem::path StateWriter::state_path() {
    const char* env = std::getenv("TITAN_STATE_PATH");
    return env ? std::filesystem::path(env) : std::filesystem::path("/tmp/titan_gpu_state");
}

const char* StateWriter::power_source_str(PowerSource ps) {
    switch (ps) {
        case PowerSource::AC:      return "ac";
        case PowerSource::Battery: return "battery";
        default:                   return "unknown";
    }
}

void StateWriter::write(const GpuDetector& detector,
                        const PowerManager& power,
                        GpuTarget current_target,
                        const std::string& active_app) {
    auto path = state_path();

    auto igpu = detector.find_igpu();
    auto dgpu = detector.find_dgpu();

    std::ostringstream json;
    json << "{\n";
    json << "  \"igpu\": \"" << (igpu ? igpu->vendor_name : "none") << "\",\n";
    json << "  \"dgpu\": \"" << (dgpu ? dgpu->vendor_name : "none") << "\",\n";
    json << "  \"target\": \"" << Classifier::target_to_string(current_target) << "\",\n";
    json << "  \"power\": \"" << power_source_str(power.current_source()) << "\",\n";
    json << "  \"active_app\": \"" << json_escape(active_app) << "\",\n";

    if (dgpu) {
        auto ps = power.get_pci_power(dgpu->pci_addr);
        json << "  \"dgpu_power\": \"" << (ps == PowerState::On ? "on" : ps == PowerState::Off ? "off" : "auto") << "\"\n";
    } else {
        json << "  \"dgpu_power\": \"n/a\"\n";
    }

    json << "}\n";

    std::ofstream f(path);
    if (f.is_open()) {
        f << json.str();
    } else {
        std::cerr << "[state_writer] cannot write " << path << "\n";
    }
}

}  // namespace titan
