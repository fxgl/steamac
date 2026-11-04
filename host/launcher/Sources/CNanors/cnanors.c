// nanors (fetch-nanors.sh -> ./nanors, excluded from the target) built as one translation unit,
// the way moonlight-common-c compiles rs.c with oblas_common.c and oblas_lite.c.
#include "nanors/deps/obl/oblas_common.c"
#include "nanors/deps/obl/oblas_lite.c"
#include "nanors/rs.c"

#include "cnanors.h"

uint8_t *cnanors_parity_matrix(reed_solomon *rs) { return rs->p; }
