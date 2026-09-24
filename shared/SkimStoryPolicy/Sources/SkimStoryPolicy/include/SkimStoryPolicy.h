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

#ifdef __cplusplus
}
#endif
#endif
