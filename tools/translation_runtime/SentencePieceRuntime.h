#ifndef PROMPT_IMAGE_SENTENCEPIECE_RUNTIME_H
#define PROMPT_IMAGE_SENTENCEPIECE_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct SPProcessor SPProcessor;
typedef struct SPPieces SPPieces;

/* Each caller owns its processor and returned pieces. No process-wide model cache.
 * Errors are optional allocated strings; release them with sp_runtime_free.
 * Encode returns piece strings, NOT SentencePiece's model-local vocabulary IDs. */
SPProcessor *sp_runtime_create(const char *model_path, char **error);
void sp_runtime_destroy(SPProcessor *processor);
SPPieces *sp_runtime_encode(SPProcessor *processor, const uint8_t *input, size_t length, char **error);
SPPieces *sp_runtime_pieces_create(void);
int sp_runtime_pieces_append(SPPieces *pieces, const uint8_t *input, size_t length);
size_t sp_runtime_piece_count(const SPPieces *pieces);
const uint8_t *sp_runtime_piece(const SPPieces *pieces, size_t index, size_t *length);
void sp_runtime_pieces_destroy(SPPieces *pieces);
uint8_t *sp_runtime_decode(SPProcessor *processor, const SPPieces *pieces, size_t *length, char **error);
void sp_runtime_free(void *allocation);

#ifdef __cplusplus
}
#endif
#endif
