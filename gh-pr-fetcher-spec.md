# gh-pr-fetcher

A zsh script that fetches GitHub PR details using `gh` CLI for offline review and AI-assisted analysis.

## Purpose

Fetch and store PR data locally (diffs, comments, metadata) so that:
- PRs can be reviewed without internet access
- Data can be fed to AI tools (e.g., Agent SDK) for automated review
- Team activity across worktrees can be tracked from a single location

## Project Structure

```
/project-folder/
├── tools/
│   ├── fetch-pr.zsh          # Main script
│   └── fetch-pr.conf         # Configuration file
├── prs/                      # Output directory (auto-created)
│   └── PR-123/
│       ├── metadata.json     # PR metadata, description, base branch
│       ├── comments.json     # All comments (PR-level + inline)
│       └── files/
│           ├── _index.json   # List of changed files with stats
│           ├── src__main__App.java.diff      # Per-file diff (path encoded)
│           └── src__test__AppTest.java.diff
├── my-repo/                  # Main repo checkout
├── worktree-feature-a/       # Git worktree
└── worktree-feature-b/       # Git worktree
```

## Configuration

### fetch-pr.conf

```bash
# Required: path to the repository (relative to config file or absolute)
REPO_PATH="../my-repo"

# Required: output directory for PR data (relative to config file or absolute)
OUTPUT_DIR="../prs"

# Optional: GitHub remote name (default: origin)
REMOTE_NAME="origin"
```

The script looks for `fetch-pr.conf` in the same directory as the script.

## Usage

```bash
# Fetch single PR
./fetch-pr.zsh 123

# Fetch all open PRs
./fetch-pr.zsh

# Fetch all PRs including closed/merged
./fetch-pr.zsh --all

# Fetch closed/merged PRs only
./fetch-pr.zsh --closed
```

## Output Format

### metadata.json

```json
{
  "pr_number": 123,
  "title": "Add user authentication",
  "state": "open",
  "draft": false,
  "url": "https://github.com/owner/repo/pull/123",
  "author": {
    "login": "johndoe",
    "name": "John Doe"
  },
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-16T14:20:00Z",
  "base": {
    "ref": "main",
    "sha": "abc123"
  },
  "head": {
    "ref": "feature/auth",
    "sha": "def456"
  },
  "description": "## Summary\n\nThis PR adds...",
  "labels": ["enhancement", "auth"],
  "reviewers": ["reviewer1", "reviewer2"],
  "review_status": "CHANGES_REQUESTED",
  "additions": 150,
  "deletions": 30,
  "changed_files_count": 5,
  "fetched_at": "2024-01-16T15:00:00Z"
}
```

### comments.json

```json
{
  "pr_number": 123,
  "total_count": 8,
  "pr_comments": [
    {
      "id": 1001,
      "author": "reviewer1",
      "body": "Looks good overall, but...",
      "created_at": "2024-01-15T12:00:00Z",
      "updated_at": "2024-01-15T12:00:00Z",
      "url": "https://github.com/..."
    }
  ],
  "review_comments": [
    {
      "id": 2001,
      "review_id": 5001,
      "author": "reviewer1",
      "body": "Consider using Optional here",
      "path": "src/main/App.java",
      "line": 42,
      "side": "RIGHT",
      "created_at": "2024-01-15T12:05:00Z",
      "in_reply_to_id": null,
      "thread_id": "2001",
      "resolved": false
    },
    {
      "id": 2002,
      "review_id": 5001,
      "author": "johndoe",
      "body": "Good point, fixed in def789",
      "path": "src/main/App.java",
      "line": 42,
      "side": "RIGHT",
      "created_at": "2024-01-15T13:00:00Z",
      "in_reply_to_id": 2001,
      "thread_id": "2001",
      "resolved": false
    }
  ],
  "reviews": [
    {
      "id": 5001,
      "author": "reviewer1",
      "state": "CHANGES_REQUESTED",
      "body": "A few changes needed before merging.",
      "submitted_at": "2024-01-15T12:10:00Z"
    }
  ]
}
```

**Threading logic**: Comments with the same `thread_id` belong to the same conversation. The root comment has `in_reply_to_id: null`, replies reference their parent.

### files/_index.json

```json
{
  "pr_number": 123,
  "base_ref": "main",
  "head_ref": "feature/auth",
  "files": [
    {
      "path": "src/main/App.java",
      "status": "modified",
      "additions": 50,
      "deletions": 10,
      "diff_file": "src__main__App.java.diff"
    },
    {
      "path": "src/main/NewFile.java",
      "status": "added",
      "additions": 100,
      "deletions": 0,
      "diff_file": "src__main__NewFile.java.diff"
    }
  ]
}
```

### Per-file diff (e.g., `src__main__App.java.diff`)

Standard unified diff format:

```diff
diff --git a/src/main/App.java b/src/main/App.java
index abc123..def456 100644
--- a/src/main/App.java
+++ b/src/main/App.java
@@ -40,6 +40,10 @@ public class App {
     private final UserService userService;
 
+    public Optional<User> authenticate(String token) {
+        return userService.findByToken(token);
+    }
+
     public void run() {
```

**Path encoding**: Forward slashes (`/`) are replaced with double underscores (`__`) to create valid filenames.

## Design Decisions

### Why separate files instead of single JSON?

1. **Context management for AI**: Large PRs can have massive diffs. Separate files allow AI to process file-by-file without exceeding context limits.
2. **Selective loading**: Review tools can load only relevant files (e.g., only `.java` files).
3. **Diff format preservation**: Keeping diffs as `.diff` files preserves syntax highlighting in editors and allows standard diff tools to work with them.
4. **Incremental updates** (future): Could update only changed files without rewriting everything.

### Why per-file diffs?

1. **Focused AI analysis**: AI can analyze one file at a time with full context.
2. **Correlation with comments**: Inline comments reference specific files; grouping makes this connection clear.
3. **Manageable size**: A 50-file PR with one combined diff is unwieldy; 50 small diffs are navigable.

### Why include both comment types?

PR-level comments often contain important context (design decisions, links, approval notes). Inline comments are critical for understanding specific code concerns. Both are needed for complete review context.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| PR does not exist | Exit with error, log message to stderr |
| No access to repo | Exit with error, log authentication hint |
| gh CLI not installed | Exit with error, log installation instructions |
| Config file missing | Exit with error, log expected config path |
| Network error mid-fetch | Exit with error, partial data may remain (user should re-run) |
| Output dir not writable | Exit with error, log permission issue |

## Dependencies

- `zsh` (script shell)
- `gh` CLI (authenticated with access to target repo)
- `jq` (JSON processing)

## Future Considerations (Out of Scope for v1)

- [ ] Incremental sync (only fetch new comments since last fetch)
- [ ] Multiple repos in single config
- [ ] Local annotations/notes that persist across syncs
- [ ] Export to markdown for human reading
- [ ] CI status and checks data
- [ ] Linked issues data
