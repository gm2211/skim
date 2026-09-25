#ifndef SKIM_STORY_POLICY_H
#define SKIM_STORY_POLICY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Plain scalar ABI: no allocation or ownership transfer crosses the ABI. */
/* Each bit represents one of at most 32 distinct query terms. Coverage of
 * another term outweighs every possible secondary field-weight difference. */
int32_t skim_chat_rank(uint32_t title_terms, uint32_t url_terms,
                       uint32_t source_terms, uint32_t body_terms);

/* A selected evidence passage is an exact span of the original UTF-8 source.
 * Offsets and lengths are bytes; scalar_count is the Unicode-scalar length. */
typedef struct {
    size_t byte_offset;
    size_t byte_length;
    size_t scalar_count;
} SkimEvidenceSpan;
/* Selects at most four original source passages, in source order. Source and
 * query are length-delimited UTF-8. Invalid UTF-8, null required pointers, or a zero
 * budget yield no spans. The scalar budget includes three scalars per gap for
 * the exact adapter join "\n…\n". No allocation or ownership transfer crosses
 * the ABI. Full source is scanned without a byte cutoff; at most 32 distinct
 * query terms participate in selection. */
size_t skim_chat_evidence_spans(const uint8_t *source, size_t source_len,
                                const uint8_t *query, size_t query_len,
                                size_t max_scalars, SkimEvidenceSpan *out,
                                size_t capacity);

typedef struct {
    double duplicate;
    double coverage;
    double borderline;
} SkimStoryThresholds;

enum {
    SKIM_STORY_SEPARATE = 0,
    SKIM_STORY_DUPLICATE = 1,
    SKIM_STORY_COVERAGE = 2,
    SKIM_STORY_UPDATE = 3,
    SKIM_STORY_BORDERLINE = 4
};

SkimStoryThresholds skim_story_default_thresholds(void);
double skim_story_confidence(double lexical_similarity, double title_similarity);
int32_t skim_story_classify(double confidence, double title_similarity,
                           int32_t entity_guard, int32_t is_update,
                           SkimStoryThresholds thresholds);
double skim_story_score(int64_t independent_sources, double age_seconds,
                        double recency_window, double preference);
int32_t skim_story_is_unique(int64_t independent_sources);
uint64_t skim_story_identity_hash(const uint8_t *bytes, size_t length);

typedef struct {
    int32_t word_count;
    int32_t bullet_min;
    int32_t bullet_max;
    int32_t bullet_max_tokens;
    int32_t full_max_tokens;
} SkimSummaryPlan;
int32_t skim_summary_min_words(void);
int32_t skim_summary_max_words(void);
int32_t skim_summary_custom_words_valid(int64_t words);
/* NULL/unknown length or invalid custom count resolves the complete short plan.
 * Missing custom count is encoded as zero. Presets ignore stale custom counts. */
SkimSummaryPlan skim_summary_plan(const char *length, int64_t custom_words);

/* Shared summary style and fidelity instructions. tone is NULL or a valid
 * NUL-terminated UTF-8 string. Unknown/empty tones use concise; descriptive
 * aliases detailed. Returns immutable static storage; caller must not free. */
const char *skim_summary_style_prompt(const char *tone);

/* Evidence and editorial policy for a newspaper story's lede. Output encoding
   and source loading remain platform adapters. */
const char *skim_today_lede_prompt(void);
const char *skim_today_lede_retry_prompt(void);
/* Source is raw UTF-8 and whitespace is normalized internally; blank-line
 * paragraph starts are retained as valid passage starts. Excerpt must be
 * valid UTF-8 with Unicode whitespace collapsed to single ASCII spaces and
 * trimmed. Accept only an exact contiguous source passage bounded by sentence
 * punctuation or a blank-line paragraph start. Raw source is capped at 65,536
 * bytes; excerpt is capped at three sentences / 60 words / 600
 * Unicode scalars. This proves textual provenance only, not relevance,
 * context, or source truth. Square-bracket markup is conservatively rejected;
 * sentence-boundary handling is conservative.
 *
 */
int32_t skim_today_lede_excerpt_valid(const uint8_t *source, size_t source_len,
                                    const uint8_t *excerpt, size_t excerpt_len);
int32_t skim_today_lede_evidence_version(void);
/* offsets has source_count+1 monotonic offsets into sources. First strict match, or -1. */
int32_t skim_today_lede_source_index(const uint8_t *sources, size_t sources_len, const size_t *offsets, size_t source_count, const uint8_t *excerpt, size_t excerpt_len);

size_t skim_today_lede_max_articles(void);
size_t skim_today_lede_text_characters(void);

/* Edition-local semantic plans never rewrite the underlying story index. */
const char *skim_semantic_prompt(void);
size_t skim_semantic_max_candidates(void);
int32_t skim_semantic_group_valid(const double *members, size_t member_count,
                                 size_t candidate_count, const uint8_t *assigned,
                                 size_t assigned_count, double importance,
                                 double confidence);
double skim_semantic_score(double base, double importance, double confidence);
/* Reassess verified fragments without inheriting a rejected combined rating. */
const char *skim_semantic_rating_prompt(void);
int32_t skim_semantic_rating_valid(double importance, double confidence);

/* Verify proposed merges before hiding reports behind a shared story card. */
const char *skim_semantic_pair_prompt(void);
size_t skim_semantic_max_pairs(void);
/* Original report evidence is bounded by Unicode scalar count in both adapters. */
size_t skim_semantic_evidence_characters(void);
size_t skim_semantic_pair_output_tokens(void);
/* Strict bounded JSON verdict: same=1, different=0, uncertain=2, invalid=-1.
   Accepts an object or singleton array, JSON whitespace and literal enum values.
   Duplicate/extra fields, escapes, embedded NULs and trailing content are invalid.
   Report identities never come from model output. At most 4096 response bytes. */
int32_t skim_semantic_pair_verdict(const uint8_t *text, size_t length);
/* Per-request verification budget. A large proposal is processed in full by
   advancing offset by the returned length; zero means no pairs remain. */
size_t skim_semantic_pair_batch_length(size_t pair_count, size_t offset);
/* verified is a candidate_count squared row-major matrix. Only mutual 1s
   support a pair. labels align with members, not the global candidate indexes.
   Returns subgroup count, or zero on invalid buffers/handles. No allocation. */
int32_t skim_semantic_partition(const double *members, size_t member_count,
                                size_t candidate_count, const uint8_t *verified,
                                size_t verified_count, int32_t *labels,
                                size_t labels_count);

/* Resumable preparation policy. Storage and provider transport are adapters.
   Window completion proves input co-presence, never pairwise judgment/recall. */
uint32_t skim_preparation_version(void);
size_t skim_preparation_block_size(void);
size_t skim_preparation_assessment_output_tokens(void);
size_t skim_preparation_proposal_output_tokens(void);
const char *skim_preparation_assessment_prompt(void);
/* Exact {"importance":0..5}, optionally inside a singleton array; -1 invalid.
   At most 4096 bytes. No identities or generated text are accepted. */
int32_t skim_preparation_assessment_verdict(const uint8_t *response, size_t length);
const char *skim_preparation_proposal_prompt(void);
/* Exact {"groups":[[0,1],[2]]}, optionally inside a singleton array.
   Every local index occurs exactly once. count is 1..64; response <=16384 bytes.
   Returns group count, or zero without changing labels on invalid input. */
int32_t skim_preparation_proposal_labels(const uint8_t *response, size_t length,
                                        size_t count, int32_t *labels, size_t labels_count);
/* Within each block first, then every unordered pair of blocks. Stable slots
   may contain tombstones; adapters remove them only from request inputs.
   UINT64_MAX marks an unrepresentable window count. */
uint64_t skim_preparation_window_count(size_t slot_count);
int32_t skim_preparation_window_at(size_t slot_count, uint64_t ordinal,
                                   size_t *first_start, size_t *first_count,
                                   size_t *second_start, size_t *second_count);
/* Sparse undirected positive edges, lexicographically sorted and unique,
   with left < right. Stable first-fit cliques require every internal edge.
   Uses checked O(candidate_count) temporary storage, freed before returning;
   no dense matrix. Supports up to INT32_MAX candidates.
   Returns group count, or zero without changing labels on invalid input. */
int32_t skim_preparation_partition(size_t candidate_count, const size_t *left,
                                    const size_t *right, size_t edge_count,
                                    int32_t *labels, size_t labels_count);
/* Maximum supported member importance, no report-count multiplier.
   Missing (-1) ratings retain neutral three. Invalid input/missing group: -1. */
int32_t skim_preparation_group_importance(const int32_t *ratings, const int32_t *labels,
                                         size_t count, int32_t group);

#ifdef __cplusplus
}
#endif
#endif
