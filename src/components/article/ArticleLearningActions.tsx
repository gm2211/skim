import { useArticleInteraction, useSetPriorityOverride } from "../../hooks/useLearning";

type ArticleLearningActionsProps = {
  articleId: string;
  /** Rendered as a labelled row inside the toolbar's overflow menu. */
  asMenuItem?: boolean;
  onDone?: () => void;
};

/** Reader actions that teach Skim which articles belong in the user's inbox. */
export function ArticleLearningActions({ articleId, asMenuItem = false, onDone }: ArticleLearningActionsProps) {
  const { data: interaction } = useArticleInteraction(articleId);
  const setPriority = useSetPriorityOverride();
  const priority = interaction?.priority_override ?? null;
  const isPinned = priority === 5;
  const errorMessage = setPriority.error
    ? setPriority.error instanceof Error
      ? setPriority.error.message
      : String(setPriority.error)
    : null;

  const setOverride = (next: number) => {
    if (!setPriority.isPending) setPriority.mutate({ articleId, priority: next });
    onDone?.();
  };

  const size = asMenuItem ? 14 : 16;
  const pinIcon = (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={isPinned ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m12 17 5 5" />
      <path d="M9 3h6l-1 6 4 4H6l4-4-1-6Z" />
      <path d="M12 13v4" />
    </svg>
  );

  if (asMenuItem) {
    return (
      <button
        type="button"
        role="menuitem"
        onClick={() => setOverride(isPinned ? 3 : 5)}
        className={`reader-menu-row ${isPinned ? "text-accent" : "text-text-secondary hover:text-text-primary"}`}
        aria-pressed={isPinned}
        disabled={setPriority.isPending}
      >
        {pinIcon}
        {isPinned ? "Unpin" : "Pin to top"}
      </button>
    );
  }

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
        {pinIcon}
      </button>
      {errorMessage && (
        <span role="alert" className="sr-only">Could not update learning preference: {errorMessage}</span>
      )}
    </div>
  );
}
