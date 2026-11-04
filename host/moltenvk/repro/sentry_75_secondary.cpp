// STEAMAC-75: inspect original Index decorations, not a potentially masked MSL interface.
#include "spirv_msl.hpp"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <vector>

int main(int argc, char **argv)
{
    if (argc < 4 || (argc - 1) % 3) return 2;
    for (int argument = 1; argument < argc; argument += 3) {
        std::ifstream file(argv[argument], std::ios::binary | std::ios::ate);
        const auto bytes = file.tellg();
        if (bytes <= 0 || bytes % 4) return 2;
        std::vector<uint32_t> words(size_t(bytes) / 4);
        file.seekg(0);
        if (!file.read(reinterpret_cast<char *>(words.data()), bytes)) return 2;
        spirv_cross::CompilerMSL compiler(std::move(words));
        compiler.set_entry_point(argv[argument + 1], spv::ExecutionModelFragment);
        const auto actual = compiler.get_fragment_output_secondary_mask();
        const auto expected = std::strtoul(argv[argument + 2], nullptr, 0);
        if (actual != expected) {
            std::cerr << "FAIL " << argv[argument] << " " << argv[argument + 1]
                      << " original secondary mask=" << actual << " expected=" << expected << '\n';
            return 1;
        }
        std::cout << "PASS " << argv[argument] << " " << argv[argument + 1]
                  << " original secondary mask=" << actual << '\n';
    }
}
