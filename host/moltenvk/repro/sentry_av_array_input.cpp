// Configure the two array locations independently, like MoltenVK's vertex descriptions.
#include "spirv_msl.hpp"
#include <fstream>
#include <vector>
#include <cstdlib>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
    auto size = input.tellg();
    if (size <= 0 || size % sizeof(uint32_t)) return 2;
    std::vector<uint32_t> words(static_cast<size_t>(size) / sizeof(uint32_t));
    input.seekg(0);
    if (!input.read(reinterpret_cast<char *>(words.data()), size)) return 2;
    spirv_cross::CompilerMSL compiler(std::move(words));
    auto options = compiler.get_msl_options();
    options.msl_version = 30000;
    options.for_mesh_pipeline = true;
    compiler.set_msl_options(options);
    for (unsigned i = 0; i < 2; i++) {
        spirv_cross::MSLShaderInterfaceVariable attribute;
        attribute.location = 5 + i;
        attribute.binding = 28 + i;
        attribute.offset = i * 4;
        attribute.vecsize = 2;
        attribute.format = i == 0 ? spirv_cross::MSL_SHADER_VARIABLE_FORMAT_HALF :
            static_cast<spirv_cross::MSLShaderVariableFormat>(std::strtoul(argv[3], nullptr, 10));
        attribute.normalized = attribute.format == spirv_cross::MSL_SHADER_VARIABLE_FORMAT_UINT8;
        compiler.add_msl_shader_input(attribute);
    }
    std::ofstream output(argv[2]);
    output << compiler.compile();
    return output ? 0 : 1;
}
