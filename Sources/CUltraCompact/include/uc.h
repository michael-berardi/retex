#ifndef UC_H
#define UC_H

/* UltraCompact C ABI — see the ultracompact crate (src/ffi.rs).
 * All strings are NUL-terminated UTF-8. Returned strings are heap-owned by
 * the library and must be released with uc_free_string. NULL return = error.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* JSON text in -> UC1 packet out. tokenizer: "o200k" (NULL default),
 * "cl100k", or "approx". Readable policy (model-readable packets). */
char *uc_encode_json(const char *input, const char *tokenizer);
char *uc_encode_readable_json(const char *input, const char *tokenizer);

/* JSON text in -> dense-mode packet out (storage/transport). */
char *uc_pack_json(const char *input);

/* Any UC packet in -> exact minified JSON out. */
char *uc_unpack_json(const char *input);

/* JSON text in -> UC readable-mode packet (codecs j/r only): output a model
 * can read directly in context, no decode step required. */
char *uc_encode_readable_json(const char *input, const char *tokenizer);

/* UC1 packet (or bare JSON) in -> exact minified JSON out. */
char *uc_decode_json(const char *input);

/* Release a string returned by uc_encode_json / uc_decode_json. */
void uc_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif /* UC_H */
