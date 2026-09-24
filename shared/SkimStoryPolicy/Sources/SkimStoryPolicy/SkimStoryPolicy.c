#include "SkimStoryPolicy.h"
#include <math.h>

SkimStoryThresholds skim_story_default_thresholds(void) {
    return (SkimStoryThresholds){0.88, 0.68, 0.58};
}

double skim_story_confidence(double lexical_similarity, double title_similarity) {
    return fmin(1.0, fmax(0.0, lexical_similarity * 0.65 + title_similarity * 0.35));
}

int32_t skim_story_classify(double confidence, double title_similarity,
                           int32_t entity_guard, int32_t is_update,
                           SkimStoryThresholds thresholds) {
    if (!entity_guard) return SKIM_STORY_SEPARATE;
    if (confidence >= thresholds.duplicate && title_similarity >= 0.78)
        return SKIM_STORY_DUPLICATE;
    if (confidence >= thresholds.coverage && title_similarity >= 0.45)
        return is_update ? SKIM_STORY_UPDATE : SKIM_STORY_COVERAGE;
    if (confidence >= thresholds.borderline) return SKIM_STORY_BORDERLINE;
    return SKIM_STORY_SEPARATE;
}

double skim_story_score(int64_t independent_sources, double age_seconds,
                        double recency_window, double preference) {
    const double sources = (double)(independent_sources > 0 ? independent_sources : 0);
    const double age = fmax(0.0, age_seconds);
    const double recency = fmax(0.0, 1.0 - age / fmax(1.0, recency_window)) * 4.0;
    return log(sources + 1.0) * 3.0 + recency + preference;
}

int32_t skim_story_is_unique(int64_t independent_sources) {
    /* Syndicated copies do not remove independent-source protection. */
    return independent_sources == 1;
}

uint64_t skim_story_identity_hash(const uint8_t *bytes, size_t length) {
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    for (size_t i = 0; i < length; ++i) {
        hash ^= bytes[i];
        hash *= UINT64_C(0x100000001b3);
    }
    return hash;
}
