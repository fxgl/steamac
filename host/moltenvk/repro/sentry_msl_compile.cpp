// API-only options and specialization reflection used by sentry-msl.sh.
#include "spirv_msl.hpp"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <vector>

int main(int argc, char **argv)
{
    if (argc < 3 || argc > 5) return 2;
    std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
    const auto size = input.tellg();
    if (size <= 0 || size % sizeof(uint32_t)) return 2;
    std::vector<uint32_t> words(static_cast<size_t>(size) / sizeof(uint32_t));
    input.seekg(0);
    if (!input.read(reinterpret_cast<char *>(words.data()), size)) return 2;
    spirv_cross::CompilerMSL compiler(std::move(words));
    auto options = compiler.get_msl_options();
    options.msl_version = argc > 3 ? static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 10)) : 30000;
    if (argc > 4) {
        if (!std::strcmp(argv[4], "null")) options.null_descriptor = true;
        else if (!std::strcmp(argv[4], "sample-offset")) options.sample_rate_interpolation_as_offset = true;
        else return 2;
    }
    compiler.set_msl_options(options);
    std::ofstream output(argv[2]);
    output << compiler.compile();
    if (!output) return 2;
    for (const auto &entry : compiler.get_msl_function_constant_ids())
        std::cout << "map " << entry.first << " " << entry.second << '\n';
}
