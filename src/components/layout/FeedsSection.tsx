import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useFeeds, useRemoveFeed, useRenameFeed } from "../../hooks/useFeeds";
import {
  useAssignFeedToFolder,
  useCreateFolder,
  useDeleteFolder,
  useFolders,
  useRenameFolder,
} from "../../hooks/useFolders";
import {
  aiAutoOrganizeFeeds,
  aiMatchFeedsForTopic,
  applyFolderOrganization,
  countStarredInFeed,
  listDuplicateFeeds,
  mergeDuplicateFeeds,
  type FolderProposal,
} from "../../services/commands";
import type { Feed, Folder, SidebarView } from "../../services/types";
import { feedsForFolder } from "../../lib/smartFolder";

type FeedContextMenu = { feedId: string; x: number; y: number } | null;
type FolderContextMenu = { folderId: string; x: number; y: number } | null;
type MoveSubmenu = { feedId: string; x: number; y: number } | null;

interface Props {
  sidebarView: SidebarView;
  setSidebarView: (view: SidebarView) => void;
  isActive: (view: SidebarView) => boolean;
  setShowAddFeed: (show: boolean) => void;
}

export function FeedsSection({ sidebarView, setSidebarView, isActive, setShowAddFeed }: Props) {
  const { data: feeds } = useFeeds();
  const { data: folders } = useFolders();
  const removeFeedMut = useRemoveFeed();
  const renameFeedMut = useRenameFeed();
  const renameFolderMut = useRenameFolder();
  const deleteFolderMut = useDeleteFolder();
  const assignMut = useAssignFeedToFolder();
  const createFolderMut = useCreateFolder();
  const qc = useQueryClient();

  const [dupeCount, setDupeCount] = useState(0);
  const [merging, setMerging] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const groups = await listDuplicateFeeds();
        if (cancelled) return;
        const dupes = groups.reduce((acc, g) => acc + Math.max(0, g.feeds.length - 1), 0);
        setDupeCount(dupes);
      } catch {
        // ignore
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [feeds?.length]);

  const handleMergeDupes = async () => {
    setMerging(true);
    try {
      await mergeDuplicateFeeds();
      setDupeCount(0);
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["folders"] });
    } finally {
      setMerging(false);
    }
  };

  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [feedMenu, setFeedMenu] = useState<FeedContextMenu>(null);
  const [folderMenu, setFolderMenu] = useState<FolderContextMenu>(null);
  const [moveSubmenu, setMoveSubmenu] = useState<MoveSubmenu>(null);
  const [renamingFeedId, setRenamingFeedId] = useState<string | null>(null);
  const [renamingFolderId, setRenamingFolderId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [removeConfirm, setRemoveConfirm] = useState<{ feed: Feed; starredCount: number } | null>(null);
  const [newFolderMode, setNewFolderMode] = useState<"regular" | "smart" | null>(null);
  const [showAddMenu, setShowAddMenu] = useState<{ x: number; y: number } | null>(null);
  const [autoOrganizeOpen, setAutoOrganizeOpen] = useState(false);

  const feedsByFolder = useMemo(() => {
    const map = new Map<string, Feed[]>();
    const uncategorized: Feed[] = [];
    if (!feeds) return { map, uncategorized };
    for (const f of feeds) {
      if (f.folder_id) {
        const arr = map.get(f.folder_id) ?? [];
        arr.push(f);
        map.set(f.folder_id, arr);
      } else {
        uncategorized.push(f);
      }
    }
    return { map, uncategorized };
  }, [feeds]);

  const closeAllMenus = () => {
    setFeedMenu(null);
    setFolderMenu(null);
    setMoveSubmenu(null);
    setShowAddMenu(null);
  };

  useEffect(() => {
    const hasMenu = feedMenu || folderMenu || moveSubmenu || showAddMenu;
    if (!hasMenu) return;
    const close = () => closeAllMenus();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [feedMenu, folderMenu, moveSubmenu, showAddMenu]);

  const toggle = (folderId: string) =>
    setExpanded((s) => ({ ...s, [folderId]: !(s[folderId] ?? true) }));

  const isExpanded = (folderId: string) => expanded[folderId] ?? true;

  const startRenameFeed = (feed: Feed) => {
    closeAllMenus();
    setRenamingFeedId(feed.id);
    setRenameValue(feed.title);
  };

  const commitRenameFeed = async () => {
    if (!renamingFeedId) return;
    const trimmed = renameValue.trim();
    const original = feeds?.find((f) => f.id === renamingFeedId);
    if (!trimmed || !original || trimmed === original.title) {
      setRenamingFeedId(null);
      return;
    }
    try {
      await renameFeedMut.mutateAsync({ feedId: renamingFeedId, title: trimmed });
    } finally {
      setRenamingFeedId(null);
    }
  };

  const startRenameFolder = (folder: Folder) => {
    closeAllMenus();
    setRenamingFolderId(folder.id);
    setRenameValue(folder.name);
  };

  const commitRenameFolder = async () => {
    if (!renamingFolderId) return;
    const trimmed = renameValue.trim();
    const original = folders?.find((f) => f.id === renamingFolderId);
    if (!trimmed || !original || trimmed === original.name) {
      setRenamingFolderId(null);
      return;
    }
    try {
      await renameFolderMut.mutateAsync({ folderId: renamingFolderId, name: trimmed });
    } finally {
      setRenamingFolderId(null);
    }
  };

  const startRemoveFeed = async (feed: Feed) => {
    closeAllMenus();
    let starredCount = 0;
    try {
      starredCount = await countStarredInFeed(feed.id);
    } catch {
      // ignore
    }
    setRemoveConfirm({ feed, starredCount });
  };

  const confirmRemoveFeed = async () => {
    if (!removeConfirm) return;
    try {
      await removeFeedMut.mutateAsync(removeConfirm.feed.id);
      if (sidebarView.type === "feed" && sidebarView.feedId === removeConfirm.feed.id) {
        setSidebarView({ type: "all" });
      }
    } finally {
      setRemoveConfirm(null);
    }
  };

  const handleMove = async (feedId: string, folderId: string | null) => {
    closeAllMenus();
    await assignMut.mutateAsync({ feedId, folderId });
  };

  const handleDeleteFolder = async (folder: Folder) => {
    closeAllMenus();
    await deleteFolderMut.mutateAsync(folder.id);
  };

  return (
    <div>
      {/* Duplicate banner */}
      {dupeCount > 0 && (
        <div
          className="flex items-center justify-between rounded-lg border border-amber-400/30 bg-amber-400/10"
          style={{ margin: "0 8px 10px", padding: "6px 10px" }}
        >
          <span className="text-amber-200" style={{ fontSize: 12 }}>
            {dupeCount} duplicate feed{dupeCount > 1 ? "s" : ""} found
          </span>
          <button
            onClick={handleMergeDupes}
            disabled={merging}
            className="text-amber-200 hover:text-amber-100 disabled:opacity-40 transition-colors"
            style={{ fontSize: 12, fontWeight: 500 }}
          >
            {merging ? "Merging…" : "Merge"}
          </button>
        </div>
      )}

      {/* Header with + menu */}
      <div className="flex items-center justify-between" style={{ padding: "0 8px", marginBottom: 12 }}>
        <span style={{ fontSize: 17, fontWeight: 600 }} className="text-text-primary">
          Feeds
        </span>
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => {
              e.stopPropagation();
              const rect = e.currentTarget.getBoundingClientRect();
              setShowAddMenu({ x: rect.right - 180, y: rect.bottom + 4 });
            }}
            className="text-text-muted hover:text-text-primary transition-colors"
            title="Add folder or smart folder"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
              <path d="M12 10v6M9 13h6" />
            </svg>
          </button>
        </div>
      </div>

      {/* Folders */}
      {folders?.map((folder) => {
        const folderFeeds = feeds ? feedsForFolder(folder, feeds) : [];
        const unread = folderFeeds.reduce((sum, f) => sum + f.unread_count, 0);
        return (
          <div key={folder.id} style={{ marginBottom: 4 }}>
            <FolderRow
              folder={folder}
              expanded={isExpanded(folder.id)}
              renaming={renamingFolderId === folder.id}
              renameValue={renameValue}
              setRenameValue={setRenameValue}
              onCommitRename={commitRenameFolder}
              onCancelRename={() => setRenamingFolderId(null)}
              unreadCount={unread}
              feedCount={folderFeeds.length}
              onToggle={() => toggle(folder.id)}
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                setFolderMenu({ folderId: folder.id, x: e.clientX, y: e.clientY });
              }}
            />
            {isExpanded(folder.id) &&
              folderFeeds.map((feed) => (
                <div key={feed.id} style={{ paddingLeft: 16 }}>
                  <FeedRow
                    feed={feed}
                    active={isActive({ type: "feed", feedId: feed.id })}
                    renaming={renamingFeedId === feed.id}
                    renameValue={renameValue}
                    setRenameValue={setRenameValue}
                    onCommitRename={commitRenameFeed}
                    onCancelRename={() => setRenamingFeedId(null)}
                    onClick={() => setSidebarView({ type: "feed", feedId: feed.id })}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      setFeedMenu({ feedId: feed.id, x: e.clientX, y: e.clientY });
                    }}
                  />
                </div>
              ))}
          </div>
        );
      })}

      {/* Uncategorized */}
      {feedsByFolder.uncategorized.length > 0 && (
        <div style={{ marginTop: folders && folders.length > 0 ? 8 : 0 }}>
          {folders && folders.length > 0 && (
            <div
              className="text-text-muted"
              style={{ padding: "6px 8px", fontSize: 12, textTransform: "uppercase", letterSpacing: 0.5 }}
            >
              Uncategorized
            </div>
          )}
          {feedsByFolder.uncategorized.map((feed) => (
            <FeedRow
              key={feed.id}
              feed={feed}
              active={isActive({ type: "feed", feedId: feed.id })}
              renaming={renamingFeedId === feed.id}
              renameValue={renameValue}
              setRenameValue={setRenameValue}
              onCommitRename={commitRenameFeed}
              onCancelRename={() => setRenamingFeedId(null)}
              onClick={() => setSidebarView({ type: "feed", feedId: feed.id })}
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                setFeedMenu({ feedId: feed.id, x: e.clientX, y: e.clientY });
              }}
            />
          ))}
        </div>
      )}

      {(!feeds || feeds.length === 0) && (
        <div style={{ padding: "20px 8px" }} className="text-center">
          <p className="text-text-muted" style={{ fontSize: 14, marginBottom: 8 }}>
            No feeds yet
          </p>
          <button
            onClick={() => setShowAddFeed(true)}
            className="text-accent hover:text-accent-hover transition-colors relative z-20"
            style={{ fontSize: 14 }}
          >
            + Add your first feed
          </button>
        </div>
      )}

      {/* Add folder menu */}
      {showAddMenu && (
        <div
          className="fixed z-50 rounded-lg border border-white/10 shadow-xl"
          style={{
            top: showAddMenu.y,
            left: showAddMenu.x,
            background: "rgba(22, 27, 34, 0.98)",
            minWidth: 220,
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <MenuButton
            onClick={() => {
              closeAllMenus();
              setNewFolderMode("regular");
            }}
            label="New folder"
          />
          <MenuButton
            onClick={() => {
              closeAllMenus();
              setNewFolderMode("smart");
            }}
            label="New smart folder..."
          />
          <div className="border-t border-white/5 my-1" />
          <MenuButton
            onClick={() => {
              closeAllMenus();
              setAutoOrganizeOpen(true);
            }}
            label="Auto-organize with AI"
          />
        </div>
      )}

      {/* Feed context menu */}
      {feedMenu && (() => {
        const feed = feeds?.find((f) => f.id === feedMenu.feedId);
        if (!feed) return null;
        return (
          <div
            className="fixed z-50 rounded-lg border border-white/10 shadow-xl"
            style={{
              top: feedMenu.y,
              left: feedMenu.x,
              background: "rgba(22, 27, 34, 0.98)",
              minWidth: 180,
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <MenuButton onClick={() => startRenameFeed(feed)} label="Rename" />
            <MenuButton
              onClick={(e) => {
                e.stopPropagation();
                const rect = (e.currentTarget as HTMLButtonElement).getBoundingClientRect();
                setMoveSubmenu({ feedId: feed.id, x: rect.right + 2, y: rect.top });
                setFeedMenu(null);
              }}
              label="Move to folder ▸"
            />
            <div className="border-t border-white/5 my-1" />
            <MenuButton onClick={() => startRemoveFeed(feed)} label="Remove feed..." danger />
          </div>
        );
      })()}

      {/* Move submenu */}
      {moveSubmenu && (
        <div
          className="fixed z-50 rounded-lg border border-white/10 shadow-xl"
          style={{
            top: moveSubmenu.y,
            left: moveSubmenu.x,
            background: "rgba(22, 27, 34, 0.98)",
            minWidth: 180,
            maxHeight: 280,
            overflowY: "auto",
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <MenuButton
            onClick={() => handleMove(moveSubmenu.feedId, null)}
            label="Uncategorized"
            muted
          />
          <div className="border-t border-white/5 my-1" />
          {folders
            ?.filter((f) => !f.is_smart)
            .map((folder) => (
              <MenuButton
                key={folder.id}
                onClick={() => handleMove(moveSubmenu.feedId, folder.id)}
                label={folder.name}
              />
            ))}
          {folders?.filter((f) => !f.is_smart).length === 0 && (
            <p className="text-text-muted" style={{ padding: "8px 12px", fontSize: 12 }}>
              No folders yet
            </p>
          )}
        </div>
      )}

      {/* Folder context menu */}
      {folderMenu && (() => {
        const folder = folders?.find((f) => f.id === folderMenu.folderId);
        if (!folder) return null;
        return (
          <div
            className="fixed z-50 rounded-lg border border-white/10 shadow-xl"
            style={{
              top: folderMenu.y,
              left: folderMenu.x,
              background: "rgba(22, 27, 34, 0.98)",
              minWidth: 180,
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <MenuButton onClick={() => startRenameFolder(folder)} label="Rename" />
            <div className="border-t border-white/5 my-1" />
            <MenuButton onClick={() => handleDeleteFolder(folder)} label="Delete folder" danger />
          </div>
        );
      })()}

      {/* Remove confirm */}
      {removeConfirm && (
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
          onClick={() => setRemoveConfirm(null)}
        >
          <div
            className="border border-white/10 rounded-2xl shadow-2xl"
            style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 420, width: "100%", margin: "0 20px" }}
            onClick={(e) => e.stopPropagation()}
          >
            <div style={{ padding: "20px 24px 16px" }}>
              <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 8 }}>
                Remove "{removeConfirm.feed.title}"?
              </h3>
              {removeConfirm.starredCount > 0 ? (
                <p className="text-text-secondary" style={{ fontSize: 13 }}>
                  This feed has{" "}
                  <strong className="text-amber-400">
                    {removeConfirm.starredCount} starred article
                    {removeConfirm.starredCount !== 1 ? "s" : ""}
                  </strong>
                  . Removing deletes all its articles including the starred ones. This cannot be undone.
                </p>
              ) : (
                <p className="text-text-muted" style={{ fontSize: 13 }}>
                  All articles from this feed will be deleted. This cannot be undone.
                </p>
              )}
            </div>
            <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
              <button
                onClick={() => setRemoveConfirm(null)}
                className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
                style={{ padding: "8px 16px", fontSize: 13 }}
              >
                Cancel
              </button>
              <button
                onClick={confirmRemoveFeed}
                disabled={removeFeedMut.isPending}
                className="bg-danger text-white rounded-lg hover:bg-red-600 disabled:opacity-40 transition-colors font-medium"
                style={{ padding: "8px 16px", fontSize: 13 }}
              >
                {removeFeedMut.isPending ? "Removing..." : "Remove"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* New folder dialogs */}
      {newFolderMode === "regular" && (
        <NewFolderDialog
          onCancel={() => setNewFolderMode(null)}
          onSave={async (name) => {
            await createFolderMut.mutateAsync(name);
            setNewFolderMode(null);
          }}
        />
      )}
      {newFolderMode === "smart" && (
        <AiSmartFolderDialog
          feeds={feeds ?? []}
          onCancel={() => setNewFolderMode(null)}
          onApply={async (name, feedIds) => {
            await applyFolderOrganization([{ name, feed_ids: feedIds }]);
            qc.invalidateQueries({ queryKey: ["folders"] });
            qc.invalidateQueries({ queryKey: ["feeds"] });
            setNewFolderMode(null);
          }}
        />
      )}
      {autoOrganizeOpen && (
        <AutoOrganizeDialog
          feeds={feeds ?? []}
          onCancel={() => setAutoOrganizeOpen(false)}
          onApply={async (proposals) => {
            await applyFolderOrganization(proposals);
            qc.invalidateQueries({ queryKey: ["folders"] });
            qc.invalidateQueries({ queryKey: ["feeds"] });
            setAutoOrganizeOpen(false);
          }}
        />
      )}
    </div>
  );
}

function MenuButton({
  onClick,
  label,
  danger,
  muted,
}: {
  onClick: (e: React.MouseEvent<HTMLButtonElement>) => void;
  label: string;
  danger?: boolean;
  muted?: boolean;
}) {
  const color = danger ? "text-danger hover:bg-red-500/10" : muted ? "text-text-muted hover:bg-white/10 hover:text-text-primary" : "text-text-primary hover:bg-white/10";
  return (
    <button
      onClick={onClick}
      className={`w-full text-left transition-colors ${color}`}
      style={{ padding: "8px 12px", fontSize: 13 }}
    >
      {label}
    </button>
  );
}

function FolderRow({
  folder,
  expanded,
  renaming,
  renameValue,
  setRenameValue,
  onCommitRename,
  onCancelRename,
  unreadCount,
  feedCount,
  onToggle,
  onContextMenu,
}: {
  folder: Folder;
  expanded: boolean;
  renaming: boolean;
  renameValue: string;
  setRenameValue: (v: string) => void;
  onCommitRename: () => void;
  onCancelRename: () => void;
  unreadCount: number;
  feedCount: number;
  onToggle: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
}) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (renaming) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [renaming]);

  return (
    <div
      onClick={renaming ? undefined : onToggle}
      onContextMenu={onContextMenu}
      className={`flex items-center justify-between rounded-lg transition-colors relative z-20 text-text-secondary hover:bg-white/5 hover:text-text-primary ${
        renaming ? "" : "cursor-pointer"
      }`}
      style={{ padding: "6px 8px" }}
    >
      <div className="flex items-center gap-2 min-w-0 flex-1">
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          className="flex-shrink-0 text-text-muted"
          style={{ transform: expanded ? "rotate(90deg)" : "none", transition: "transform 0.15s" }}
        >
          <polyline points="9 18 15 12 9 6" />
        </svg>
        {folder.is_smart ? (
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="text-accent flex-shrink-0">
            <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
          </svg>
        ) : (
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="text-text-muted flex-shrink-0">
            <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
          </svg>
        )}
        {renaming ? (
          <input
            ref={inputRef}
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onBlur={onCommitRename}
            onKeyDown={(e) => {
              if (e.key === "Enter") onCommitRename();
              if (e.key === "Escape") onCancelRename();
            }}
            className="flex-1 min-w-0 bg-white/10 rounded px-2 py-0.5 text-text-primary outline-none border border-accent/40"
            style={{ fontSize: 14 }}
          />
        ) : (
          <span className="truncate" style={{ fontSize: 14, fontWeight: 500 }}>
            {folder.name}
          </span>
        )}
      </div>
      {!renaming && (
        <span className="text-text-muted tabular-nums ml-2" style={{ fontSize: 12 }}>
          {unreadCount > 0 ? unreadCount.toLocaleString() : feedCount}
        </span>
      )}
    </div>
  );
}

function FeedRow({
  feed,
  active,
  renaming,
  renameValue,
  setRenameValue,
  onCommitRename,
  onCancelRename,
  onClick,
  onContextMenu,
}: {
  feed: Feed;
  active: boolean;
  renaming: boolean;
  renameValue: string;
  setRenameValue: (v: string) => void;
  onCommitRename: () => void;
  onCancelRename: () => void;
  onClick: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
}) {
  const [iconFailed, setIconFailed] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const initial = (feed.title || "?")[0].toUpperCase();

  useEffect(() => {
    if (renaming) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [renaming]);

  return (
    <div
      onClick={renaming ? undefined : onClick}
      onContextMenu={onContextMenu}
      className={`flex items-center justify-between rounded-lg transition-colors relative z-20 ${
        renaming ? "" : "cursor-pointer"
      } ${
        active
          ? "bg-white/10 text-text-primary"
          : "text-text-secondary hover:bg-white/5 hover:text-text-primary"
      }`}
      style={{ padding: "8px" }}
    >
      <div className="flex items-center gap-3 min-w-0 flex-1">
        {feed.icon_url && !iconFailed ? (
          <img
            src={feed.icon_url}
            alt=""
            width={20}
            height={20}
            className="rounded-sm flex-shrink-0 bg-white/5"
            style={{ objectFit: "contain" }}
            onError={() => setIconFailed(true)}
          />
        ) : (
          <div
            className="rounded-md bg-accent/20 text-accent flex items-center justify-center font-bold flex-shrink-0"
            style={{ width: 20, height: 20, fontSize: 11 }}
          >
            {initial}
          </div>
        )}
        {renaming ? (
          <input
            ref={inputRef}
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onBlur={onCommitRename}
            onKeyDown={(e) => {
              if (e.key === "Enter") onCommitRename();
              if (e.key === "Escape") onCancelRename();
            }}
            className="flex-1 min-w-0 bg-white/10 rounded px-2 py-0.5 text-text-primary outline-none border border-accent/40"
            style={{ fontSize: 15 }}
          />
        ) : (
          <span className="truncate" style={{ fontSize: 15 }}>
            {feed.title}
          </span>
        )}
      </div>
      {!renaming && feed.unread_count > 0 && (
        <span className="text-text-muted tabular-nums ml-2" style={{ fontSize: 14 }}>
          {feed.unread_count.toLocaleString()}
        </span>
      )}
    </div>
  );
}

function NewFolderDialog({
  onCancel,
  onSave,
}: {
  onCancel: () => void;
  onSave: (name: string) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSave = async () => {
    if (!name.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await onSave(name.trim());
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      onClick={onCancel}
    >
      <div
        className="border border-white/10 rounded-2xl shadow-2xl"
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 380, width: "100%", margin: "0 20px" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ padding: "20px 24px 16px" }}>
          <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 12 }}>
            New folder
          </h3>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleSave();
              if (e.key === "Escape") onCancel();
            }}
            placeholder="Folder name"
            className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 14px", fontSize: 14 }}
          />
          {error && (
            <p className="text-danger" style={{ fontSize: 12, marginTop: 8 }}>
              {error}
            </p>
          )}
        </div>
        <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
          <button
            onClick={onCancel}
            className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={saving || !name.trim()}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            {saving ? "Creating..." : "Create"}
          </button>
        </div>
      </div>
    </div>
  );
}

function AiSmartFolderDialog({
  feeds,
  onCancel,
  onApply,
}: {
  feeds: Feed[];
  onCancel: () => void;
  onApply: (name: string, feedIds: string[]) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [matchedIds, setMatchedIds] = useState<string[] | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [matching, setMatching] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!matching) return;
    const start = Date.now();
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - start) / 1000)), 1000);
    return () => clearInterval(id);
  }, [matching]);

  const matched = useMemo(
    () => (matchedIds ? feeds.filter((f) => matchedIds.includes(f.id)) : []),
    [matchedIds, feeds],
  );

  const runMatch = async () => {
    if (!description.trim()) {
      setError("Describe what feeds belong in this folder");
      return;
    }
    setMatching(true);
    setError(null);
    try {
      const ids = await aiMatchFeedsForTopic(description.trim());
      setMatchedIds(ids);
      setSelected(new Set(ids));
      if (ids.length === 0) setError("No matching feeds found. Try rephrasing.");
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setMatching(false);
    }
  };

  const toggle = (id: string) => {
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const handleSave = async () => {
    if (!name.trim()) {
      setError("Folder name is required");
      return;
    }
    if (selected.size === 0) {
      setError("Select at least one feed");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await onApply(name.trim(), Array.from(selected));
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      onClick={onCancel}
    >
      <div
        className="border border-white/10 rounded-2xl shadow-2xl"
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 520, width: "100%", margin: "0 20px", maxHeight: "85vh" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="overflow-y-auto" style={{ padding: "20px 24px 16px", maxHeight: "calc(85vh - 60px)" }}>
          <div className="flex items-center gap-2" style={{ marginBottom: 4 }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent">
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
            <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600 }}>
              New smart folder
            </h3>
          </div>
          <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 16 }}>
            Describe the folder. AI picks matching feeds. You can edit the list before saving.
          </p>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Folder name (e.g. AI & ML)"
            className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 14px", fontSize: 14, marginBottom: 10 }}
          />
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="What belongs in this folder? e.g. “sources about machine learning research, LLMs, and AI policy”"
            rows={3}
            className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors resize-none"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 14px", fontSize: 14 }}
          />
          <div className="flex justify-end" style={{ marginTop: 8, marginBottom: 12 }}>
            <button
              onClick={runMatch}
              disabled={matching || !description.trim()}
              className="text-accent hover:text-accent-hover disabled:opacity-40 transition-colors flex items-center gap-1"
              style={{ fontSize: 13 }}
            >
              {matching ? `Matching… ${elapsed}s` : matchedIds ? "Re-match feeds" : "Find matching feeds →"}
            </button>
          </div>

          {matchedIds && (
            <div>
              <div className="text-text-muted" style={{ fontSize: 12, marginBottom: 8 }}>
                {selected.size} of {matched.length} selected
              </div>
              <div className="border border-white/5 rounded-xl overflow-hidden" style={{ maxHeight: 280, overflowY: "auto" }}>
                {matched.map((f) => (
                  <label
                    key={f.id}
                    className="flex items-center gap-3 hover:bg-white/5 cursor-pointer transition-colors"
                    style={{ padding: "8px 12px" }}
                  >
                    <input
                      type="checkbox"
                      checked={selected.has(f.id)}
                      onChange={() => toggle(f.id)}
                      className="accent-accent flex-shrink-0"
                    />
                    <span className="truncate text-text-primary" style={{ fontSize: 13 }}>
                      {f.title}
                    </span>
                  </label>
                ))}
                {matched.length === 0 && (
                  <p className="text-text-muted text-center" style={{ padding: 16, fontSize: 13 }}>
                    No matches.
                  </p>
                )}
              </div>
            </div>
          )}

          {error && (
            <p className="text-danger" style={{ fontSize: 12, marginTop: 10 }}>
              {error}
            </p>
          )}
        </div>
        <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
          <button
            onClick={onCancel}
            className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={saving || !matchedIds || selected.size === 0 || !name.trim()}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            {saving ? "Creating..." : "Create folder"}
          </button>
        </div>
      </div>
    </div>
  );
}

function AutoOrganizeDialog({
  feeds,
  onCancel,
  onApply,
}: {
  feeds: Feed[];
  onCancel: () => void;
  onApply: (proposals: FolderProposal[]) => Promise<void>;
}) {
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [proposals, setProposals] = useState<FolderProposal[]>([]);
  const [selected, setSelected] = useState<Record<number, Set<string>>>({});
  const [names, setNames] = useState<Record<number, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!loading) return;
    const start = Date.now();
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - start) / 1000)), 1000);
    return () => clearInterval(id);
  }, [loading]);

  const feedById = useMemo(() => {
    const m = new Map<string, Feed>();
    for (const f of feeds) m.set(f.id, f);
    return m;
  }, [feeds]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      try {
        const result = await aiAutoOrganizeFeeds();
        if (cancelled) return;
        setProposals(result);
        const initSel: Record<number, Set<string>> = {};
        const initNames: Record<number, string> = {};
        result.forEach((p, i) => {
          initSel[i] = new Set(p.feed_ids);
          initNames[i] = p.name;
        });
        setSelected(initSel);
        setNames(initNames);
      } catch (e) {
        if (!cancelled) setError(String(e instanceof Error ? e.message : e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const toggle = (folderIdx: number, feedId: string) => {
    setSelected((s) => {
      const curr = new Set(s[folderIdx] ?? []);
      if (curr.has(feedId)) curr.delete(feedId);
      else curr.add(feedId);
      return { ...s, [folderIdx]: curr };
    });
  };

  const updateName = (idx: number, v: string) => {
    setNames((n) => ({ ...n, [idx]: v }));
  };

  const dropFolder = (idx: number) => {
    setProposals((ps) => ps.filter((_, i) => i !== idx));
    setSelected((s) => {
      const next = { ...s };
      delete next[idx];
      return next;
    });
    setNames((n) => {
      const next = { ...n };
      delete next[idx];
      return next;
    });
  };

  const handleApply = async () => {
    const filtered: FolderProposal[] = proposals
      .map((_p, idx) => ({
        name: (names[idx] ?? "").trim(),
        feed_ids: Array.from(selected[idx] ?? new Set<string>()),
      }))
      .filter((p) => p.name && p.feed_ids.length > 0);
    if (filtered.length === 0) {
      setError("Nothing to apply");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await onApply(filtered);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setSaving(false);
    }
  };

  const totalSelected = Object.values(selected).reduce((acc, s) => acc + s.size, 0);

  return (
    <div
      className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      onClick={onCancel}
    >
      <div
        className="border border-white/10 rounded-2xl shadow-2xl"
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 560, width: "100%", margin: "0 20px", maxHeight: "85vh" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="overflow-y-auto" style={{ padding: "20px 24px 16px", maxHeight: "calc(85vh - 64px)" }}>
          <div className="flex items-center gap-2" style={{ marginBottom: 4 }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" className="text-accent">
              <path d="M3 7h7M3 12h7M3 17h7" />
              <path d="M14 4h7v7h-7zM14 13h7v7h-7z" />
            </svg>
            <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600 }}>
              Auto-organize with AI
            </h3>
          </div>
          <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 16 }}>
            AI proposes folders based on your feeds. Rename, uncheck, or drop folders before applying.
            Feeds you already have in folders will be moved.
          </p>

          {loading && (
            <div className="text-center" style={{ padding: "40px 0" }}>
              <div className="text-text-muted" style={{ fontSize: 13 }}>
                Analyzing {feeds.length} feeds… <span className="tabular-nums">{elapsed}s</span>
              </div>
              <div className="text-text-muted" style={{ fontSize: 11, marginTop: 6 }}>
                Local models can take 30-90s. Cancel if it's too slow.
              </div>
            </div>
          )}

          {!loading && proposals.length === 0 && !error && (
            <div className="text-center" style={{ padding: "20px 0" }}>
              <p className="text-text-muted" style={{ fontSize: 13 }}>
                AI didn't produce any folders. Try again or add more feeds first.
              </p>
            </div>
          )}

          {!loading &&
            proposals.map((p, idx) => (
              <div
                key={idx}
                className="border border-white/5 rounded-xl"
                style={{ marginBottom: 12, background: "rgba(255,255,255,0.02)" }}
              >
                <div className="flex items-center gap-2" style={{ padding: "10px 12px", borderBottom: "1px solid rgba(255,255,255,0.05)" }}>
                  <input
                    value={names[idx] ?? ""}
                    onChange={(e) => updateName(idx, e.target.value)}
                    className="flex-1 bg-transparent text-text-primary outline-none border-b border-white/0 focus:border-accent/40"
                    style={{ fontSize: 14, fontWeight: 600, padding: "2px 0" }}
                  />
                  <span className="text-text-muted tabular-nums" style={{ fontSize: 12 }}>
                    {selected[idx]?.size ?? 0} / {p.feed_ids.length}
                  </span>
                  <button
                    onClick={() => dropFolder(idx)}
                    className="text-text-muted hover:text-danger transition-colors"
                    title="Skip this folder"
                  >
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <path d="M18 6L6 18M6 6l12 12" />
                    </svg>
                  </button>
                </div>
                <div style={{ padding: "4px 8px" }}>
                  {p.feed_ids.map((fid) => {
                    const feed = feedById.get(fid);
                    if (!feed) return null;
                    const checked = selected[idx]?.has(fid) ?? false;
                    return (
                      <label
                        key={fid}
                        className="flex items-center gap-2 rounded-lg hover:bg-white/5 cursor-pointer transition-colors"
                        style={{ padding: "4px 8px" }}
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggle(idx, fid)}
                          className="accent-accent flex-shrink-0"
                        />
                        <span className="truncate text-text-secondary" style={{ fontSize: 12 }}>
                          {feed.title}
                        </span>
                      </label>
                    );
                  })}
                </div>
              </div>
            ))}

          {error && (
            <p className="text-danger" style={{ fontSize: 12, marginTop: 10 }}>
              {error}
            </p>
          )}
        </div>
        <div className="flex justify-between items-center gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
          <span className="text-text-muted" style={{ fontSize: 12 }}>
            {proposals.length} folders · {totalSelected} feeds
          </span>
          <div className="flex gap-2">
            <button
              onClick={onCancel}
              className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
              style={{ padding: "8px 16px", fontSize: 13 }}
            >
              Cancel
            </button>
            <button
              onClick={handleApply}
              disabled={saving || loading || proposals.length === 0}
              className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
              style={{ padding: "8px 16px", fontSize: 13 }}
            >
              {saving ? "Applying..." : "Apply"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
