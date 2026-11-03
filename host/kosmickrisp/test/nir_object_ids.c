/*
 * nir_serialize packs the object index of every source into a 20-bit field (packed_src.any.object_idx) and only
 * asserts in debug builds that a shader has fewer than 2^20 objects. A release build truncates larger indices,
 * so nir_deserialize resolves those sources to unrelated objects: the struct deref below then reads a "type" out of
 * an ALU def and faults in glsl_get_struct_field (STEAMAC-6M/6K), and an ALU whose source resolves to a def with
 * another component count reads or skips swizzle words and desynchronizes the stream (read_block faults,
 * STEAMAC-7J/7H/7P). KosmicKrisp serializes every compute stage before compiling it (vk_pipeline precomp).
 *
 * The test builds a compute shader with more than 2^20 objects whose last instructions use objects past the limit,
 * serializes and deserializes it, and compares every source of every instruction (by def index) and every struct
 * deref's field type with the original. Exit 0 on a faithful round trip.
 *
 * Built by build.sh with the flags Mesa used for nir_serialize.c against the build's static libraries.
 */
#include <stdio.h>
#include <stdlib.h>

#include "nir.h"
#include "nir_builder.h"
#include "nir_serialize.h"
#include "util/blob.h"
#include "util/u_dynarray.h"

static bool
collect_src(nir_src *src, void *data)
{
   util_dynarray_append(data, src->ssa->index);
   return true;
}

/* Instruction types, source def indices and struct deref types in program order */
static void
collect(nir_shader *s, struct util_dynarray *out)
{
   nir_function_impl *impl = nir_shader_get_entrypoint(s);
   nir_index_ssa_defs(impl);
   nir_foreach_block(block, impl) {
      nir_foreach_instr(instr, block) {
         util_dynarray_append(out, (unsigned)instr->type);
         nir_foreach_src(instr, collect_src, out);
         if (instr->type == nir_instr_type_deref) {
            nir_deref_instr *d = nir_instr_as_deref(instr);
            util_dynarray_append(out, (unsigned)glsl_get_base_type(d->type));
         }
      }
   }
}

int
main(void)
{
   glsl_type_singleton_init_or_ref();

   static const nir_shader_compiler_options options = { 0 };
   nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_COMPUTE, &options, "object_ids");

   const struct glsl_struct_field fields[2] = {
      { .type = glsl_float_type(), .name = "f" },
      { .type = glsl_uint_type(), .name = "u" },
   };
   const struct glsl_type *st = glsl_struct_type(fields, 2, "s", false);
   nir_variable *var = nir_local_variable_create(b.impl, st, "v");

   /* Each step adds a load_const and an iadd: past 2^20 objects after 2^19 steps */
   nir_def *x = nir_imm_int(&b, 1);
   for (unsigned i = 0; i < (1u << 19) + 1024; i++)
      x = nir_iadd_imm(&b, x, i);

   nir_deref_instr *field = nir_build_deref_struct(&b, nir_build_deref_var(&b, var), 1);
   nir_store_deref(&b, field, x, 0x1);
   nir_store_deref(&b, field, nir_iadd(&b, nir_load_deref(&b, field), x), 0x1);

   struct blob blob;
   blob_init(&blob);
   nir_serialize(&blob, b.shader, false);
   if (blob.out_of_memory) {
      fprintf(stderr, "FAIL: out of memory serializing\n");
      return 1;
   }

   struct blob_reader reader;
   blob_reader_init(&reader, blob.data, blob.size);
   nir_shader *copy = nir_deserialize(NULL, &options, &reader);
   if (copy == NULL || reader.overrun || reader.current != reader.end) {
      fprintf(stderr, "FAIL: deserialization did not consume the blob exactly\n");
      return 1;
   }

   struct util_dynarray want, got;
   util_dynarray_init(&want, NULL);
   util_dynarray_init(&got, NULL);
   collect(b.shader, &want);
   collect(copy, &got);

   unsigned n_want = util_dynarray_num_elements(&want, unsigned);
   unsigned n_got = util_dynarray_num_elements(&got, unsigned);
   unsigned n = MIN2(n_want, n_got);
   for (unsigned i = 0; i < n; i++) {
      if (*util_dynarray_element(&want, unsigned, i) != *util_dynarray_element(&got, unsigned, i)) {
         fprintf(stderr, "FAIL: round trip differs at entry %u of %u: %u, expected %u\n", i, n_want,
                 *util_dynarray_element(&got, unsigned, i), *util_dynarray_element(&want, unsigned, i));
         return 1;
      }
   }
   if (n_want != n_got) {
      fprintf(stderr, "FAIL: round trip has %u entries, expected %u\n", n_got, n_want);
      return 1;
   }

   printf("nir_object_ids: %u objects, %zu-byte blob, round trip identical\n",
          b.impl->ssa_alloc, blob.size);

   util_dynarray_fini(&want);
   util_dynarray_fini(&got);
   ralloc_free(copy);
   ralloc_free(b.shader);
   blob_finish(&blob);
   glsl_type_singleton_decref();
   return 0;
}
