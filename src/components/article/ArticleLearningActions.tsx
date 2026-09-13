import { useArticleInteraction, useSetPriorityOverride } from "../../hooks/useLearning";

type ArticleLearningActionsProps = {
  articleId: string;
};

/** Reader actions that teach Skim which articles belong in the user's inbox. */
export function ArticleLearningActions({ articleId }: ArticleLearningActionsProps) {
  const { data: interaction } = useArticleInteraction(articleId);
  const setPriority = useSetPriorityOverride();
  const priority = interaction?.priority_override ?? null;
  const isPinned = priority === 5;
  const isHidden = priority === 1;
  const errorMessage = setPriority.error
    ? setPriority.error instanceof Error
      ? setPriority.error.message
      : String(setPriority.error)
    : null;

  const setOverride = (next: number) => {
    if (!setPriority.isPending) setPriority.mutate({ articleId, priority: next });
  };

  return (
    <div className="flex items-center gap-1" role="group" aria-label="Learning actions">
      <button
        type="button"
        onClick={() => setOverride(isPinned ? 3 : 5)}
        className={`tap-target rounded-lg hover:bg-white/10 transition-colors ${isPinned ? "text-accent" : "text-text-muted hover:text-text-primary"}`}
        title={isPinned ? "Unpin" : "Pin to top"}
        aria-label={isPinned ? "Unpin" : "Pin to top"}
        aria-pressed={isPinned}
        disabled={setPriority.isPending}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill={isPinned ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="m12 17 5 5" />
          <path d="M9 3h6l-1 6 4 4H6l4-4-1-6Z" />
          <path d="M12 13v4" />
        </svg>
      </button>
      <button
        type="button"
        onClick={() => setOverride(isHidden ? 3 : 1)}
        className={`tap-target rounded-lg hover:bg-white/10 transition-colors ${isHidden ? "text-accent" : "text-text-muted hover:text-text-primary"}`}
        title={isHidden ? "Unhide from inbox" : "Hide from inbox"}
        aria-label={isHidden ? "Unhide from inbox" : "Hide from inbox"}
        aria-pressed={isHidden}
        disabled={setPriority.isPending}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          {isHidden ? <><path d="M2 2l20 20" /><path d="M6.7 6.7C4.1 8.4 2.5 10.5 2 12c1.7 4.1 5.4 7 10 7 1.6 0 3.1-.4 4.4-1" /><path d="M9.9 4.5A10.8 10.8 0 0 1 12 4c4.6 0 8.3 2.9 10 8-.4 1.1-1 2.1-1.7 3" /></> : <><path d="M2 12s3.7-8 10-8 10 8 10 8-3.7 8-10 8S2 12 2 12Z" /><circle cx="12" cy="12" r="3" /></>}
        </svg>
      </button>
      {errorMessage && (
        <span role="alert" className="sr-only">Could not update learning preference: {errorMessage}</span>
      )}
    </div>
  );
}
