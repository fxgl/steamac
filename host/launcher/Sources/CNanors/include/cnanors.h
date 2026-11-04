#pragma once
// Reed-Solomon erasure coding over GF(2^8) from nanors (fetch-nanors.sh -> ../nanors), the codec
// moonlight-common-c recovers lost video/audio shards with. These are nanors' own declarations
// (rs.h), with the codec kept opaque, plus access to its parity matrix.
#include <stdint.h>

typedef struct _reed_solomon reed_solomon;

/// Once, before concurrent use: builds the shared GF tables.
void reed_solomon_init(void);
/// NULL on invalid shard counts (data + parity <= 255) or allocation failure.
reed_solomon *reed_solomon_new(int data_shards, int parity_shards);
void reed_solomon_release(reed_solomon *rs);
/// shards[0..<data] are the input blocks, shards[data..<nr_shards] receive parity; every block is bs bytes.
int reed_solomon_encode(reed_solomon *rs, uint8_t **shards, int nr_shards, int bs);
/// Rebuilds the data shards whose marks[i] != 0 (writable buffers) from the others. 0 on success.
int reed_solomon_decode(reed_solomon *rs, uint8_t **shards, uint8_t *marks, int nr_shards, int bs);

/// The codec's parity rows (parity_shards x data_shards bytes, row-major). GameStream audio FEC
/// replaces them with the fixed matrix GFE uses (moonlight-common-c RtpAudioQueue.c does the same).
uint8_t *cnanors_parity_matrix(reed_solomon *rs);
