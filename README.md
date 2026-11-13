# Claude Code Statusline

A dense, width-aware status line for [Claude Code](https://code.claude.com/docs/en/statusline) in a single Bash
script. Model and effort, context, prompt cache, usage limits, git state and the pipeline of your MR or PR, all in
one line that shows only what matters right now.

![Status line](assets/statusline.svg)

Here in a terminal 100 columns wide, so the line breaks in two; a wider terminal gets it on one line. During a rebase
with a conflict:

![Status line during a rebase](assets/statusline-rebase.svg)

## 🚀 Installation

### Ask Claude Code

Paste this into Claude Code:

```text
Install the status line from https://github.com/OzzyCzech/claude-code-statusline:

1. Download https://raw.githubusercontent.com/OzzyCzech/claude-code-statusline/main/statusline.sh
   to ~/.claude/statusline.sh.
2. In ~/.claude/settings.json set "statusLine" to
   {"type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 30}.
   Keep all my other settings. If a different statusLine is already there, show it to me and ask before replacing it.
3. Check that jq and git are installed and tell me how to install whatever is missing.
   If I use GitLab or GitHub, tell me that a logged-in glab or gh adds the MR/PR pipeline status.
4. Run the script once with a sample session JSON on stdin, e.g.
   {"model":{"display_name":"Opus"},"context_window":{"used_percentage":42},"cwd":"<current directory>"},
   and show me what it prints.
```

The same prompt updates an existing installation to the latest version.

### Manually

Download the script:

```shell
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/OzzyCzech/claude-code-statusline/main/statusline.sh
```

Add it to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 30
  }
}
```

`refreshInterval` keeps the countdowns and the pipeline status moving while Claude is idle. Without it the line only
updates on Claude Code events, such as a new message.

### Requirements

- Bash 3.2+ (the one macOS ships works) on macOS or Linux
- [jq](https://jqlang.org) and git (2.35+ for the stash count)
- Optional: [glab](https://gitlab.com/gitlab-org/cli) for GitLab MRs, [gh](https://cli.github.com) for GitHub PRs,
  both logged in
- Optional: a terminal with OSC 8 hyperlinks (iTerm2, Kitty, WezTerm, Ghostty) to make the [links](#-links)
  clickable

## 🔍 What it shows

| Part                               | Meaning                                                                                                                                                          |
|------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Opus 5.5 xhigh fast`              | Model, its effort level, `fast` when fast mode is on                                                                                                             |
| `Context: 64%`                     | Context window used: green below 50 %, yellow below 80 %, then red                                                                                               |
| `⧗ 4 min` / `⧗ cold`               | Prompt cache about to expire (last quarter of its TTL, 15 min of an hour, red in the last 5) or already cold, only when re-caching would cost 20k+ tokens        |
| `Usage: 78%↑ 1h 20m`               | Usage limits; first the 5-hour one and the time to its reset, `↑` means usage runs ahead of the time elapsed in the window                                       |
| `34% 3d 4h`                        | Then the weekly one, its time always in days (`0d 5h` on the last day), so it cannot pass for the 5-hour one                                                     |
| `scratch`                          | Link to the scratchpad of the session, once Claude has put something in it                                                                                       |
| `acme/webapp`                      | Project, the last two path components                                                                                                                            |
| `acme/webapp/src`                  | Claude has moved into a subdirectory                                                                                                                             |
| `acme/webapp → other/repo`         | Claude works outside the project; the git status that follows belongs to that directory                                                                          |
| `git:(feature/login)`              | Branch, the worktree name in a worktree, the short hash on a detached HEAD                                                                                       |
| `git:(feature/login\|REBASE 3/7)`  | Operation in progress with its step: `REBASE`, `AM`, `MERGE`, `CHERRY-PICK`, `REVERT`, `BISECT`                                                                  |
| `✗`                                | Uncommitted changes                                                                                                                                              |
| `⚠1`                               | Files with conflicts                                                                                                                                             |
| `↑2`                               | Commits not on the branch `git push` updates (a fork too), or not on the default branch before the first push                                                    |
| `↓3`                               | Commits on the default branch of `origin` the branch does not have yet, which a fast-forward merge needs                                                         |
| `●1`                               | Stashes                                                                                                                                                          |
| `+48 -12`                          | Lines added and removed against `HEAD`                                                                                                                           |
| `!128` / `#42`                     | GitLab MR or GitHub PR of the branch: green when approved, red when changes are requested, dim as a draft                                                        |
| `✓` `✗` `●` `⊘` `▶`                | Pipeline or checks: passed, failed, running, canceled or skipped, waiting for a manual job                                                                       |
| `conflict` `rebase` `threads`      | What still blocks the merge: conflicts, the branch must catch up with the target, unresolved blocking threads (GitLab only)                                     |

## 🔗 Links

In a terminal with OSC 8 hyperlinks, these parts open with Cmd+click on macOS, Ctrl+click on Windows and Linux:

| Part                                  | Opens                                                                                         |
|---------------------------------------|-----------------------------------------------------------------------------------------------|
| `acme/webapp`, `/src`, `→ other/repo` | The directory in Finder or your file manager                                                  |
| `scratch`                             | The scratchpad of the session                                                                 |
| `git`                                 | The repository on the web, from the `origin` remote                                           |
| `feature/login`                       | The page of the branch on the remote `git push` updates, a fork too, once the branch is there |
| `b332a660`                            | The commit, on a detached HEAD                                                                |
| `↓3`                                  | The commits on the default branch the branch does not have yet                                |
| `!128` / `#42`                        | The MR or PR                                                                                  |
| `✓` `✗` `●` `⊘` `▶`                   | The pipeline on GitLab, the checks on GitHub                                                  |
| `conflict`                            | The page that resolves the conflicts                                                          |

The addresses come from the URLs of the git remotes, HTTPS or SSH, so they cost no network request. The repository
opens on any forge. The branch, the commit and `↓` need GitHub or GitLab, recognised by `github` or `gitlab` in the
host name; add a self-hosted GitLab with another name to `GITLAB_HOSTS`. The repository is the one on `origin`, or on
the first remote with a web address when `origin` has none. A host alias from `~/.ssh/config` does not say which host
it stands for: without a dot (`github-work`) it gives no link, with one (`github.com-work`) a link that leads nowhere.

## 📐 Narrow terminals

The script reads the terminal width Claude Code passes in `COLUMNS` and fits the line into it. First it drops `scratch`.
When that is not enough, it breaks the line in two, with the project and git on the second line, and only then drops
the weekly limit and the line counts, in this order, so a wider terminal never hides them while a narrower one shows
them. A limit at 80 % or more always stays.

`DROP_BEFORE_BREAK` sets how many of these parts go before the line breaks: `0` breaks it right away and keeps them
all, `3` keeps one line for as long as it can.

## ⚙️ Configuration

The constants at the top of the script:

| Constant             | Default | Meaning                                                                  |
|----------------------|---------|--------------------------------------------------------------------------|
| `CACHE_MIN_TOKENS`   | `20000` | A cold cache that would re-cache fewer tokens than this stays hidden     |
| `CACHE_WARN_PERCENT` | `25`    | The last part of the cache lifetime with the countdown, in percent       |
| `REVIEW_TTL_SECONDS` | `60`    | How often glab or gh is asked about the MR or PR                         |
| `WIDTH_RESERVE`      | `4`     | Columns Claude Code takes beside the status line                         |
| `DROP_BEFORE_BREAK`  | `1`     | How many of the least important parts go before the line breaks in two   |
| `GITLAB_HOSTS`       | `""`    | Self-hosted GitLab hosts without gitlab in the name, space-separated     |

## 🧩 How it works

Claude Code pipes [session JSON](https://code.claude.com/docs/en/statusline) to the script on every update. Everything
except git and the MR or PR comes from that JSON, so it costs nothing.

Git runs a handful of quick commands per update: one `git status --porcelain=v2` gives the branch, its upstream, the
stashes, the changes and the conflicts. Every call uses `--no-optional-locks`, so it never fights with Claude or you
over the index.

The MR or PR status never slows the line down. glab or gh runs in the background at most once a minute per MR or PR,
and the line shows the result cached in `$TMPDIR/claude-statusline`.

Try it without Claude Code:

```shell
echo '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":42},"cwd":"'"$PWD"'"}' | bash statusline.sh
```

## 📄 License

[MIT](LICENSE)
