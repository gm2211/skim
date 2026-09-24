#ifndef SKIM_STORY_POLICY_H
#define SKIM_STORY_POLICY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Plain scalar ABI: no allocation, ownership transfer, or platform runtime. */
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

/* Edition-local semantic plans never rewrite the underlying story index. */
const char *skim_semantic_prompt(void);
size_t skim_semantic_max_candidates(void);
int32_t skim_semantic_group_valid(const double *members, size_t member_count,
                                 size_t candidate_count, const uint8_t *assigned,
                                 size_t assigned_count, double importance,
                                 double confidence);
double skim_semantic_score(double base, double importance, double confidence);

#ifdef __cplusplus
}
#endif
#endif
