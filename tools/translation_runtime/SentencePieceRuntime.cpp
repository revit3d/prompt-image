#include "SentencePieceRuntime.h"
#include "sentencepiece_processor.h"
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct SPProcessor { sentencepiece::SentencePieceProcessor value; };
struct SPPieces { std::vector<std::string> values; };

namespace {
constexpr size_t kMaximumInputBytes = 16384;
constexpr size_t kMaximumPieces = 16384;
void failure(char **error, const char *message) noexcept {
  if (!error) return;
  const size_t size = std::strlen(message) + 1;
  *error = static_cast<char *>(std::malloc(size));
  if (*error) std::memcpy(*error, message, size);
}
}

extern "C" {
SPProcessor *sp_runtime_create(const char *model_path, char **error) {
  if (error) *error = nullptr;
  try {
    if (!model_path) { failure(error, "Missing model path"); return nullptr; }
    auto result = std::make_unique<SPProcessor>();
    if (!result->value.Load(model_path).ok()) {
      failure(error, "Invalid SentencePiece model"); return nullptr;
    }
    return result.release();
  } catch (...) { failure(error, "Cannot load SentencePiece model"); return nullptr; }
}

void sp_runtime_destroy(SPProcessor *processor) { delete processor; }

SPPieces *sp_runtime_encode(SPProcessor *processor, const uint8_t *input, size_t length, char **error) {
  if (error) *error = nullptr;
  try {
    if (!processor || (!input && length) || length > kMaximumInputBytes) {
      failure(error, "Invalid encode input"); return nullptr;
    }
    auto result = std::make_unique<SPPieces>();
    const auto text = std::string_view(input ? reinterpret_cast<const char *>(input) : "", length);
    if (!processor->value.Encode(text, &result->values).ok() || result->values.size() > kMaximumPieces) {
      failure(error, "SentencePiece encoding failed"); return nullptr;
    }
    return result.release();
  } catch (...) { failure(error, "SentencePiece encoding failed"); return nullptr; }
}

SPPieces *sp_runtime_pieces_create(void) {
  try { return new SPPieces(); } catch (...) { return nullptr; }
}

int sp_runtime_pieces_append(SPPieces *pieces, const uint8_t *input, size_t length) {
  try {
    if (!pieces || (!input && length) || length > kMaximumInputBytes || pieces->values.size() >= kMaximumPieces) return 0;
    pieces->values.emplace_back(input ? reinterpret_cast<const char *>(input) : "", length);
    return 1;
  } catch (...) { return 0; }
}

size_t sp_runtime_piece_count(const SPPieces *pieces) { return pieces ? pieces->values.size() : 0; }

const uint8_t *sp_runtime_piece(const SPPieces *pieces, size_t index, size_t *length) {
  if (length) *length = 0;
  if (!pieces || !length || index >= pieces->values.size()) return nullptr;
  const auto &piece = pieces->values[index];
  *length = piece.size();
  return reinterpret_cast<const uint8_t *>(piece.data());
}

void sp_runtime_pieces_destroy(SPPieces *pieces) { delete pieces; }

uint8_t *sp_runtime_decode(SPProcessor *processor, const SPPieces *pieces, size_t *length, char **error) {
  if (error) *error = nullptr;
  if (length) *length = 0;
  try {
    if (!processor || !pieces || !length) { failure(error, "Invalid decode input"); return nullptr; }
    std::string text;
    if (!processor->value.Decode(pieces->values, &text).ok() || text.size() > kMaximumInputBytes) {
      failure(error, "SentencePiece decoding failed"); return nullptr;
    }
    auto result = static_cast<uint8_t *>(std::malloc(text.size() + 1));
    if (!result) { failure(error, "Cannot allocate decoded text"); return nullptr; }
    std::memcpy(result, text.data(), text.size());
    result[text.size()] = 0;
    *length = text.size();
    return result;
  } catch (...) { failure(error, "SentencePiece decoding failed"); return nullptr; }
}

void sp_runtime_free(void *allocation) { std::free(allocation); }
}
