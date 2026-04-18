import { useEffect, useMemo, useRef, useState } from "react";
import { useFeeds, useRemoveFeed, useRenameFeed } from "../../hooks/useFeeds";
import {
  useAssignFeedToFolder,
  useCreateFolder,
  useCreateSmartFolder,
  useDeleteFolder,
  useFolders,
  useRenameFolder,
  useUpdateSmartFolderRules,
} from "../../hooks/useFolders";
import { countStarredInFeed } from "../../services/commands";
import type { Feed, Folder, SidebarView, SmartRule, SmartRules } from "../../services/types";
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
  const createSmartFolderMut = useCreateSmartFolder();
  const updateRulesMut = useUpdateSmartFolderRules();

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
  const [smartEditing, setSmartEditing] = useState<Folder | null>(null);

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
            minWidth: 180,
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
            label="New smart folder"
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
            {folder.is_smart && (
              <MenuButton
                onClick={() => {
                  closeAllMenus();
                  setSmartEditing(folder);
                }}
                label="Edit rules"
              />
            )}
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
        <SmartFolderDialog
          title="New smart folder"
          initialName=""
          initialRules={{ mode: "any", rules: [{ type: "regex_title", pattern: "" }] }}
          onCancel={() => setNewFolderMode(null)}
          onSave={async (name, rules) => {
            await createSmartFolderMut.mutateAsync({ name, rules });
            setNewFolderMode(null);
          }}
        />
      )}
      {smartEditing && (
        <SmartFolderDialog
          title={`Edit "${smartEditing.name}"`}
          initialName={smartEditing.name}
          initialRules={
            smartEditing.rules_json
              ? (JSON.parse(smartEditing.rules_json) as SmartRules)
              : { mode: "any", rules: [] }
          }
          onCancel={() => setSmartEditing(null)}
          onSave={async (name, rules) => {
            await updateRulesMut.mutateAsync({ folderId: smartEditing.id, rules });
            if (name.trim() !== smartEditing.name) {
              await renameFolderMut.mutateAsync({ folderId: smartEditing.id, name: name.trim() });
            }
            setSmartEditing(null);
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

function SmartFolderDialog({
  title,
  initialName,
  initialRules,
  onCancel,
  onSave,
}: {
  title: string;
  initialName: string;
  initialRules: SmartRules;
  onCancel: () => void;
  onSave: (name: string, rules: SmartRules) => Promise<void>;
}) {
  const [name, setName] = useState(initialName);
  const [mode, setMode] = useState<"any" | "all">(initialRules.mode);
  const [rules, setRules] = useState<SmartRule[]>(
    initialRules.rules.length > 0 ? initialRules.rules : [{ type: "regex_title", pattern: "" }],
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const updateRule = (idx: number, rule: SmartRule) => {
    setRules((rs) => rs.map((r, i) => (i === idx ? rule : r)));
  };

  const removeRule = (idx: number) => {
    setRules((rs) => rs.filter((_, i) => i !== idx));
  };

  const addRule = () => {
    setRules((rs) => [...rs, { type: "regex_title", pattern: "" }]);
  };

  const handleSave = async () => {
    if (!name.trim()) {
      setError("Name is required");
      return;
    }
    const cleaned = rules.filter((r) =>
      r.type === "opml_category" ? r.value.trim() !== "" : r.pattern.trim() !== "",
    );
    if (cleaned.length === 0) {
      setError("Add at least one rule");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await onSave(name.trim(), { mode, rules: cleaned });
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
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 480, width: "100%", margin: "0 20px", maxHeight: "80vh" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="overflow-y-auto" style={{ padding: "20px 24px 16px", maxHeight: "calc(80vh - 60px)" }}>
          <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 12 }}>
            {title}
          </h3>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Folder name"
            className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 14px", fontSize: 14, marginBottom: 16 }}
          />
          <div className="flex items-center gap-2" style={{ marginBottom: 12 }}>
            <span className="text-text-muted" style={{ fontSize: 13 }}>
              Match
            </span>
            <select
              value={mode}
              onChange={(e) => setMode(e.target.value as "any" | "all")}
              className="border border-white/10 rounded-lg text-text-primary bg-transparent"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "6px 10px", fontSize: 13 }}
            >
              <option value="any">any</option>
              <option value="all">all</option>
            </select>
            <span className="text-text-muted" style={{ fontSize: 13 }}>
              of the following:
            </span>
          </div>

          <div className="space-y-2" style={{ marginBottom: 12 }}>
            {rules.map((rule, idx) => (
              <div key={idx} className="flex items-center gap-2">
                <select
                  value={rule.type}
                  onChange={(e) => {
                    const t = e.target.value;
                    if (t === "opml_category") updateRule(idx, { type: "opml_category", value: "" });
                    else if (t === "regex_url") updateRule(idx, { type: "regex_url", pattern: "" });
                    else updateRule(idx, { type: "regex_title", pattern: "" });
                  }}
                  className="border border-white/10 rounded-lg text-text-primary flex-shrink-0"
                  style={{ background: "rgba(255, 255, 255, 0.05)", padding: "8px 10px", fontSize: 13 }}
                >
                  <option value="regex_title">Title regex</option>
                  <option value="regex_url">URL regex</option>
                  <option value="opml_category">OPML category</option>
                </select>
                <input
                  value={rule.type === "opml_category" ? rule.value : rule.pattern}
                  onChange={(e) =>
                    rule.type === "opml_category"
                      ? updateRule(idx, { type: "opml_category", value: e.target.value })
                      : updateRule(idx, { type: rule.type, pattern: e.target.value })
                  }
                  placeholder={rule.type === "opml_category" ? "e.g. tech" : "regex pattern"}
                  className="flex-1 border border-white/10 rounded-lg text-text-primary outline-none focus:border-accent/40"
                  style={{ background: "rgba(255, 255, 255, 0.05)", padding: "8px 12px", fontSize: 13 }}
                />
                <button
                  onClick={() => removeRule(idx)}
                  className="text-text-muted hover:text-danger transition-colors flex-shrink-0"
                  title="Remove rule"
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M18 6L6 18M6 6l12 12" />
                  </svg>
                </button>
              </div>
            ))}
          </div>

          <button
            onClick={addRule}
            className="text-accent hover:text-accent-hover transition-colors"
            style={{ fontSize: 13 }}
          >
            + Add rule
          </button>

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
            disabled={saving}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
