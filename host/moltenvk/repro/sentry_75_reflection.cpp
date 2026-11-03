// STEAMAC-75: MoltenVK failure reflection must distinguish both blend-source indices.
// Link against SPIRV-Cross reflect/glsl/core; include the private MoltenVK converter headers.
#include "SPIRVReflection.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <cstring>

int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    for (int argument = 1; argument < argc; argument++) {
        std::ifstream file(argv[argument], std::ios::binary);
        std::vector<char> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        if (bytes.empty() || bytes.size() % 4) return 2;
        std::vector<uint32_t> words(bytes.size() / 4);
        std::memcpy(words.data(), bytes.data(), bytes.size());
        std::vector<mvk::SPIRVShaderOutput> outputs;
        std::string error;
        if (!mvk::getShaderOutputs(words, spv::ExecutionModelFragment, "main", outputs, error)) {
            std::cerr << error << '\n';
            return 1;
        }
        unsigned sources[2] = {};
        for (const auto &output : outputs) {
            if (output.location != 0 || output.index > 1) return 1;
            sources[output.index]++;
            std::cout << "location=" << output.location << " component=" << output.component
                      << " index=" << output.index << " width=" << output.vecWidth << '\n';
        }
        if (!sources[0] || !sources[1]) return 1;
        std::cout << "PASS: " << argv[argument] << " primary=" << sources[0]
                  << " secondary=" << sources[1] << '\n';
    }
    return 0;
}
