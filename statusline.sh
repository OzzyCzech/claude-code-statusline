#!/bin/bash
# Claude Code status line:
# model effort | context + prompt cache | session and weekly limit | scratchpad
# | project + working dir git:(branch|operation) changes | MR or PR + pipeline + merge blockers
# It fits the width of the terminal: the least important part goes first, then the line breaks in two,
# and only then go the other parts it can do without.

input=$(cat)

# A cold cache that would re-cache fewer tokens than this is cheap, so its state stays hidden.
CACHE_MIN_TOKENS=20000
# The countdown appears in this last part of the cache lifetime, in percent: the last 15 minutes of a 1-hour cache,
# the last 75 seconds of a 5-minute one. It turns red in the last third of that.
CACHE_WARN_PERCENT=25
# How old the cached pipeline and merge status of an MR or PR may get before glab or gh is asked again.
REVIEW_TTL_SECONDS=60
# Columns Claude Code takes beside the status line.
WIDTH_RESERVE=4
# How many of the least important parts go before the line breaks in two: 1 the scratchpad,
# 2 also the weekly limit, 3 also the line counts. 0 breaks the line before anything goes.
DROP_BEFORE_BREAK=1
# Hosts of a self-hosted GitLab without gitlab in the name, separated by spaces, for the links to branches and commits.
GITLAB_HOSTS=""

E=$'\033'
RESET="$E[0m" BOLD="$E[1m" DIM="$E[2m" RED="$E[31m" GREEN="$E[32m" YELLOW="$E[33m" BLUE="$E[34m" MAGENTA="$E[35m" CYAN="$E[36m"
SEP=" ${DIM}|$RESET "
now=$(date +%s)

level_color() {
	if (($1 < 50)); then printf '%s' "$GREEN"; elif (($1 < 80)); then printf '%s' "$YELLOW"; else printf '%s' "$RED"; fi
}

# A text that opens the address when clicked (OSC 8), the plain text when there is no address.
link() {
	if [[ -n $1 ]]; then printf '%s]8;;%s%s\\%s%s]8;;%s\\' "$E" "$1" "$E" "$2" "$E" "$E"; else printf '%s' "$2"; fi
}

# Time left as 2d 5h, 3h 28m or 28m, without a zero hour or minute: 2d, 3h. In days whenever the second argument
# is set, 0d 5h on the last day.
duration() {
	local d=$(($1 / 86400)) h=$(($1 % 86400 / 3600)) m=$(($1 % 3600 / 60))
	if ((d > 0)) || [[ -n $2 ]]; then
		printf '%dd' "$d"
		((h > 0 || d == 0)) && printf ' %dh' "$h"
	elif ((h > 0)); then
		printf '%dh' "$h"
		((m > 0)) && printf ' %dm' "$m"
	else
		printf '%dm' "$m"
	fi
	return 0
}

# Modification time of a file in epoch seconds, with GNU or BSD stat.
mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

IFS=$'\x1f' read -r model effort fast ctx_pct cache_warm cache_expires cache_ttl cache_tokens project cwd scratchpad worktree worktree_path h5_pct h5_reset d7_pct d7_reset pr_number pr_url pr_state pr_kind <<<"$(jq -r '
	def limit: [
		(if .used_percentage == null then "" else .used_percentage | floor end),
		(.resets_at // "" | if type == "number" then floor else . end)
	];
	(.context_window // {}) as $c
	| (($c.current_usage // {}) | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) as $tokens
	| (.prompt_cache // {}) as $p
	| [
		(.model.display_name // .model.id // "Claude"),
		(.effort.level // ""),
		(.fast_mode // false),
		($c.used_percentage // (if ($c.context_window_size // 0) > 0 then $tokens * 100 / $c.context_window_size else 0 end) | floor),
		($p.warm // ""),
		($p.expires_at // ""),
		($p.ttl // ""),
		($p.recache_tokens_if_cold // $tokens),
		(.workspace.project_dir // .workspace.current_dir // .cwd // ""),
		(.workspace.current_dir // .cwd // ""),
		(.scratchpad_dir // ""),
		(.worktree.name // .workspace.git_worktree // ""),
		(.worktree.path // ""),
		((.rate_limits.five_hour // {}) | limit)[],
		((.rate_limits.seven_day // {}) | limit)[],
		(.pr.number // ""),
		(.pr.url // ""),
		(.pr.review_state // ""),
		(.pr.kind // "")
	] | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f")
' <<<"$input" 2>/dev/null)"

# The parts of the line, each with the separator before it and the rank in which it goes when the line is too wide
# (0 stays). break_at is the part the second line starts with when dropping parts is not enough.
parts=() joins=() ranks=() break_at=""
add() {
	parts+=("$1")
	joins+=("${2-$SEP}")
	ranks+=("${3:-0}")
}

# Model with its effort level, fast mode spelled out.
segment=${model:-Claude}
[[ -n $effort ]] && segment+=" $DIM$effort$RESET"
[[ $fast == true ]] && segment+=" ${YELLOW}fast$RESET"
add "$segment"

# Context: green up to 50 %, yellow up to 80 %, then red.
ctx_pct=${ctx_pct:-0}
segment="Context: $(level_color "$ctx_pct")$ctx_pct%$RESET"

# Prompt cache, only when going cold would be expensive: a countdown shortly before it expires, then cold.
# The clock decides rather than the warm flag, which can lag right at the moment of expiry.
# How shortly depends on the lifetime of the cache, an hour when Claude Code does not say.
if [[ $cache_expires =~ ^[0-9]+$ ]] && ((${cache_tokens%.*} >= CACHE_MIN_TOKENS)); then
	left=$((cache_expires - now))
	ttl=3600
	if [[ $cache_ttl =~ ^([1-9][0-9]*)([smh])$ ]]; then
		case ${BASH_REMATCH[2]} in
			s) ttl=${BASH_REMATCH[1]} ;;
			m) ttl=$((BASH_REMATCH[1] * 60)) ;;
			h) ttl=$((BASH_REMATCH[1] * 3600)) ;;
		esac
	fi
	warn=$((ttl * CACHE_WARN_PERCENT / 100))
	if [[ $cache_warm == true ]] && ((left > 0)); then
		if ((left <= warn)); then
			ccolor=$YELLOW
			((left * 3 < warn)) && ccolor=$RED
			segment+=" ${ccolor}⧗ $(((left + 59) / 60))m$RESET"
		fi
	else
		segment+=" ${BLUE}⧗ cold$RESET"
	fi
fi
add "$segment"

# Usage limits, the session one and then the weekly one, each with the time left until the reset:
# Usage: 12% 3h 28m 45% 2d. The weekly time is always in days, so it is not taken for the session one even alone.
# The arrow means usage runs ahead of time. A limit at 80 % or more stays however narrow the terminal is.
usage_shown=""
limit() {
	local pct=$1 reset=$2 window=$3 rank=${4:-0} days=$5 left="" ahead="" text
	[[ -n $pct ]] || return 0
	if [[ $reset =~ ^[0-9]+$ ]]; then
		left=$((reset - now))
		((left < 0)) && left=0
		((pct > (window - left) * 100 / window)) && ahead="↑"
	fi
	((pct >= 80)) && rank=0
	text="$(level_color "$pct")$pct%$ahead$RESET${left:+ $(duration "$left" "$days")}"
	if [[ -n $usage_shown ]]; then
		add "$text" " " "$rank"
	else
		add "Usage: $text" "$SEP" "$rank"
	fi
	usage_shown=1
}
limit "$h5_pct" "$h5_reset" 18000
limit "$d7_pct" "$d7_reset" 604800 2 days

# Claude's scratchpad of this session: only when something is in it, clickable.
if [[ -n $scratchpad && -d $scratchpad && -n $(ls -A "$scratchpad" 2>/dev/null) ]]; then
	add "$DIM$(link "file://$scratchpad" scratch)$RESET" "$SEP" 1
fi

# Git in the working directory, with messages in English whatever the locale.
git_in() {
	LC_ALL=C git -C "$cwd" --no-optional-locks "$@" 2>/dev/null
}

# The first line of a file, empty when it is missing.
file_line() {
	local line=""
	[[ -r $1 ]] && read -r line <"$1"
	printf '%s' "$line"
}

# The last two components of a path, the whole path right under the root.
short_path() {
	local parent=${1%/*}
	if [[ -z $parent || $parent == "$1" ]]; then printf '%s' "${1:-/}"; else printf '%s/%s' "${parent##*/}" "${1##*/}"; fi
}

# The web address of a git remote into REPLY: https://host/path from an HTTPS, SSH or scp-like URL, without credentials,
# the SSH port and .git. Empty for a local path, and for an SSH host without a dot, most likely an alias
# from ~/.ssh/config, which does not say what host it stands for.
web_url() {
	REPLY=""
	if [[ $1 =~ ^(https?)://([^@/]+@)?([^/]+)/(.+)$ ]]; then
		REPLY="${BASH_REMATCH[1]}://${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
	elif [[ $1 =~ ^ssh://([^@/]+@)?([^/:]+\.[^/:]+)(:[0-9]+)?/(.+)$ ]]; then
		REPLY="https://${BASH_REMATCH[2]}/${BASH_REMATCH[4]}"
	elif [[ $1 =~ ^([^@/:]+@)?([^/:]+\.[^/:]+):([^/].*)$ ]]; then
		REPLY="https://${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
	fi
	REPLY=${REPLY%/}
	REPLY=${REPLY%.git}
}

# The web address of the remote of that name into REPLY, empty when it has none.
remote_web() {
	local i
	REPLY=""
	for ((i = 0; i < ${#remote_names[@]}; i++)); do
		[[ ${remote_names[i]} == "$1" ]] && REPLY=${remote_webs[i]} && return
	done
}

# What the pages of a repository at the web address start with into REPLY: the address on GitHub, the address
# and /- on GitLab. Empty on any other forge, whose pages of branches and commits look different.
forge_routes() {
	local host=${1#*://}
	host=${host%%/*}
	host=${host%%:*}
	REPLY=""
	if [[ -z $host ]]; then
		return
	elif [[ $host == *github* ]]; then
		REPLY=$1
	elif [[ $host == *gitlab* || " $GITLAB_HOSTS " == *" $host "* ]]; then
		REPLY=$1/-
	fi
}

# A branch name for an address into REPLY, with % and #, which git allows in it, percent-encoded.
url_path() {
	REPLY=${1//[%]/%25}
	REPLY=${REPLY//[#]/%23}
}

# The page of a remote-tracking branch such as refs/remotes/fork/feature into REPLY, on the web of its remote.
branch_page() {
	local ref=${1#refs/remotes/} routes
	remote_web "${ref%%/*}"
	forge_routes "$REPLY"
	routes=$REPLY
	url_path "${ref#*/}"
	REPLY=${routes:+$routes/tree/$REPLY}
}

# Project: the last two path components, clickable, bold cyan like the directory in the shell prompt.
# When Claude has moved elsewhere, the working directory follows, since the git status after it is its own:
# a subdirectory as a path relative to the project (or to the worktree of the session), a directory outside after an arrow.
break_at=${#parts[@]}
outside=""
if [[ -n $project ]]; then
	segment="${BOLD}${CYAN}$(link "file://$project" "$(short_path "$project")")$RESET"
	root=$project
	[[ -n $worktree_path && ($cwd == "$worktree_path" || $cwd == "$worktree_path"/*) ]] && root=$worktree_path
	if [[ -n $cwd && $cwd != "$root" ]]; then
		if [[ $cwd == "$root"/* ]]; then
			sub=${cwd#"$root"/}
			((${#sub} > 32)) && sub="…/${cwd##*/}"
			segment+="${CYAN}$(link "file://$cwd" "/$sub")$RESET"
		else
			outside=1
			segment+=" ${YELLOW}→$RESET ${BOLD}${CYAN}$(link "file://$cwd" "$(short_path "$cwd")")$RESET"
		fi
	fi
	add "$segment"
fi

# Git the way the shell prompt shows it: git:(branch), the worktree name inside a linked worktree,
# the short hash on a detached HEAD, the branch being rebased during a rebase. After a bar the operation
# in progress, with its step where git keeps one: REBASE 3/7, AM 1/2, MERGE, CHERRY-PICK, REVERT, BISECT.
# ✗ anything uncommitted, ⚠ files with conflicts, ↑ commits not pushed yet,
# ↓ commits behind the default branch of origin (a fast-forward merge needs a rebase), ● stashes,
# then lines added and removed against HEAD.
# Clickable on GitHub and GitLab: git opens the repository (on any forge), the branch its page once it is pushed,
# the hash the commit, ↓ the commits the branch does not have yet.
name=""
if [[ -n $cwd ]] && gitdir=$(git_in rev-parse --absolute-git-dir); then
	op="" step="" head=""
	if [[ -d $gitdir/rebase-merge ]]; then
		op=REBASE
		step="$(file_line "$gitdir/rebase-merge/msgnum")/$(file_line "$gitdir/rebase-merge/end")"
		head=$(file_line "$gitdir/rebase-merge/head-name")
	elif [[ -d $gitdir/rebase-apply ]]; then
		op=AM
		step="$(file_line "$gitdir/rebase-apply/next")/$(file_line "$gitdir/rebase-apply/last")"
		if [[ -f $gitdir/rebase-apply/rebasing ]]; then
			op=REBASE
			head=$(file_line "$gitdir/rebase-apply/head-name")
		fi
	elif [[ -f $gitdir/MERGE_HEAD ]]; then
		op=MERGE
	elif [[ -f $gitdir/CHERRY_PICK_HEAD ]]; then
		op=CHERRY-PICK
	elif [[ -f $gitdir/REVERT_HEAD ]]; then
		op=REVERT
	elif [[ -f $gitdir/BISECT_LOG ]]; then
		op=BISECT
	fi
	[[ $step =~ ^[0-9]+/[0-9]+$ ]] || step=""
	[[ $head == refs/heads/* ]] || head=""

	# One status for the branch, its upstream, the stashes, the changes and the conflicts.
	oid="" branch="" upstream="" ab="" stashes=0 changes="" conflicts=0
	while IFS= read -r line; do
		case $line in
			"# branch.oid "*) oid=${line#"# branch.oid "} ;;
			"# branch.head "*) branch=${line#"# branch.head "} ;;
			"# branch.upstream "*) upstream=${line#"# branch.upstream "} ;;
			"# branch.ab "*) ab=${line#"# branch.ab "} ;;
			"# stash "*) stashes=${line#"# stash "} ;;
			"#"*) ;;
			"u "*) changes=1 conflicts=$((conflicts + 1)) ;;
			?*) changes=1 ;;
		esac
	done < <(git_in status --porcelain=v2 --branch --show-stash --untracked-files=normal)
	[[ $branch == "(detached)" ]] && branch=""
	[[ $oid == "(initial)" ]] && oid=""

	name=${branch:-${head#refs/heads/}}
	[[ -z $name ]] && name=${oid:0:8}
	((${#name} > 32)) && name="${name:0:31}…"
	[[ -n $worktree && -n $name && -z $outside ]] && name=$worktree

	# Web addresses of the remotes for the links (Bash 3.2 has no associative arrays). The repository is the one
	# on origin, or on the first remote with a web address.
	remote_names=() remote_webs=() repo_url=""
	while read -r key url; do
		key=${key#remote.}
		web_url "$url"
		remote_names+=("${key%.url}") remote_webs+=("$REPLY")
		[[ -z $repo_url ]] && repo_url=$REPLY
	done < <(git_in config --get-regexp '^remote\..*\.url$')
	remote_web origin
	[[ -n $REPLY ]] && repo_url=$REPLY
	forge_routes "$repo_url"
	routes=$REPLY

	name_url="" unpushed="" behind="" behind_url=""
	if [[ -n $branch ]]; then
		base=$(git_in symbolic-ref -q --short refs/remotes/origin/HEAD)
		if [[ -z $base ]]; then
			base=origin/main
			git_in rev-parse -q --verify "$base" >/dev/null || base=origin/master
		fi
		# Not pushed means not on the branch git push updates, which @{push} names even on a fork or another pushRemote,
		# otherwise not on origin/<branch>, or not on the default branch before the first push.
		# pushed is that branch, the one the link opens.
		if [[ $upstream == "origin/$branch" && $ab =~ ^\+([0-9]+) ]]; then
			unpushed=${BASH_REMATCH[1]} pushed=refs/remotes/origin/$branch
		elif pushed=$(git_in rev-parse --symbolic-full-name '@{push}') && [[ $pushed == refs/remotes/?*/?* ]]; then
			unpushed=$(git_in rev-list --count "$pushed..HEAD")
		elif unpushed=$(git_in rev-list --count "origin/$branch..HEAD"); then
			pushed=refs/remotes/origin/$branch
		else
			pushed="" unpushed=$(git_in rev-list --count "$base..HEAD")
		fi
		if [[ -n $pushed ]]; then
			branch_page "$pushed"
			name_url=$REPLY
		fi
		behind=$(git_in rev-list --count "HEAD..$base")
		# The commits the branch does not have yet: the default branch compared with where the branch left it.
		if ((${behind:-0} > 0)) && [[ -n $routes ]] && fork_point=$(git_in merge-base HEAD "$base"); then
			url_path "${base#origin/}"
			behind_url="$routes/compare/$fork_point...$REPLY"
		fi
	elif [[ -n $head ]]; then
		# The branch being rebased, when it is on origin.
		if git_in rev-parse -q --verify "refs/remotes/origin/${head#refs/heads/}" >/dev/null; then
			branch_page "refs/remotes/origin/${head#refs/heads/}"
			name_url=$REPLY
		fi
	elif [[ -n $oid && -n $routes ]]; then
		name_url="$routes/commit/$oid"
	fi
fi
if [[ -n $name ]]; then
	segment="${BOLD}${BLUE}$(link "$repo_url" git):(${RED}$(link "$name_url" "$name")"
	[[ -n $op ]] && segment+="${BLUE}|${YELLOW}$op${step:+ $step}"
	segment+="${BLUE})"
	[[ -n $changes ]] && segment+=" ${YELLOW}✗"
	((conflicts > 0)) && segment+=" ${RED}⚠$conflicts"
	((${unpushed:-0} > 0)) && segment+=" ${CYAN}↑$unpushed"
	((${behind:-0} > 0)) && segment+=" ${CYAN}$(link "$behind_url" "↓$behind")"
	((stashes > 0)) && segment+=" ${MAGENTA}●$stashes"
	add "$segment$RESET" " "

	stat=$(git_in diff HEAD --shortstat) diffstat=""
	[[ $stat =~ ([0-9]+)\ insertion ]] && diffstat+="${GREEN}+${BASH_REMATCH[1]}$RESET"
	[[ $stat =~ ([0-9]+)\ deletion ]] && diffstat+="${diffstat:+ }${RED}-${BASH_REMATCH[1]}$RESET"
	[[ -n $diffstat ]] && add "$diffstat" " " 3
fi

# Pipeline and merge status of the MR or PR at the URL in GitLab terms, separated by \x1f: the pipeline status,
# need_rebase when the branch must catch up with the target first, whether it has conflicts, whether its blocking
# threads are resolved and the address of the pipeline (both GitLab only). glab or gh runs in the background at most
# once a minute, the line shows the cached result.
review_status() {
	local url=$1 dir="${TMPDIR:-/tmp}/claude-statusline" file fetch filter
	if [[ $url =~ ^https?://([^/]+)/(.+)/-/merge_requests/([0-9]+) ]]; then
		fetch=(glab api --hostname "${BASH_REMATCH[1]}" "projects/${BASH_REMATCH[2]//\//%2F}/merge_requests/${BASH_REMATCH[3]}")
		filter='select(.iid)
			| [.head_pipeline.status // "", .detailed_merge_status // "", .has_conflicts, .blocking_discussions_resolved,
				.head_pipeline.web_url // ""]'
	elif [[ $url =~ ^https?://[^/]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then
		fetch=(gh pr view "$url" --json number,statusCheckRollup,mergeStateStatus,mergeable)
		filter='select(.number)
			| [.statusCheckRollup[]?
				| if .__typename == "StatusContext" then {SUCCESS: "success", FAILURE: "failed", ERROR: "failed"}[.state] // "running"
				elif .status != "COMPLETED" then "running"
				else {SUCCESS: "success", NEUTRAL: "success", SKIPPED: "skipped", STALE: "skipped", CANCELLED: "canceled"}[.conclusion] // "failed"
				end] as $checks
			| [
				(if any($checks[]; . == "failed") then "failed"
				elif any($checks[]; . == "running") then "running"
				elif any($checks[]; . == "success") then "success"
				else $checks[0] // "" end),
				(if .mergeStateStatus == "BEHIND" then "need_rebase" else "" end),
				.mergeable == "CONFLICTING",
				""
			]'
	else
		return
	fi
	mkdir -p "$dir"
	file="$dir/review-${url//[^A-Za-z0-9]/_}"
	[[ -d $file.lock && $((now - $(mtime "$file.lock"))) -gt 120 ]] && rmdir "$file.lock" 2>/dev/null
	if [[ ! -f $file || $((now - $(mtime "$file"))) -ge REVIEW_TTL_SECONDS ]] && mkdir "$file.lock" 2>/dev/null; then
		(
			if status=$("${fetch[@]}" | jq -er "$filter"' | map(tostring) | join("\u001f")'); then
				printf '%s' "$status" >"$file.tmp" && mv "$file.tmp" "$file"
			else
				touch "$file"
			fi
			rmdir "$file.lock"
		) &>/dev/null &
		disown
	fi
	[[ -f $file ]] && printf '%s' "$(<"$file")"
}

# Open MR or PR of the branch, clickable, coloured by its review state, with the pipeline status
# and what still blocks the merge: conflicts, a rebase, unresolved blocking threads.
# The pipeline status opens the pipeline (the checks on GitHub), conflict the page that resolves them.
if [[ -n $pr_number ]]; then
	case $pr_state in
		approved) pcolor=$GREEN ;;
		changes_requested) pcolor=$RED ;;
		draft) pcolor=$DIM ;;
		*) pcolor="" ;;
	esac
	label="#$pr_number"
	[[ $pr_kind == mr ]] && label="!$pr_number"
	[[ -n $pr_url ]] && label=$(link "$pr_url" "$label")
	segment="$pcolor$label$RESET"
	if [[ -n $pr_url ]]; then
		IFS=$'\x1f' read -r pipeline merge_status conflicting resolved pipeline_url <<<"$(review_status "$pr_url")"
		if [[ -z $pipeline_url ]]; then
			pipeline_url=$pr_url/checks
			[[ $pr_url == */-/merge_requests/* ]] && pipeline_url=$pr_url/pipelines
		fi
		case $pipeline in
			success) icon=✓ icolor=$GREEN ;;
			failed) icon=✗ icolor=$RED ;;
			running | pending | created | preparing | waiting_for_resource | scheduled) icon=● icolor=$YELLOW ;;
			canceled | skipped) icon=⊘ icolor=$DIM ;;
			manual) icon=▶ icolor=$DIM ;;
			*) icon="" ;;
		esac
		[[ -n $icon ]] && segment+=" $icolor$(link "$pipeline_url" "$icon")$RESET"
		[[ $conflicting == true ]] && segment+=" ${RED}$(link "$pr_url/conflicts" conflict)$RESET"
		[[ $merge_status == need_rebase ]] && segment+=" ${YELLOW}rebase$RESET"
		[[ $resolved == false ]] && segment+=" ${YELLOW}threads$RESET"
	fi
	add "$segment"
fi

# Visible width of a text in characters: without colours and links, UTF-8 continuation bytes not counted.
visible_width() {
	local LC_ALL=C s=$1 re=$'\e(\\[[0-9;]*m|]8;;[^\e]*\e\\\\)'
	while [[ $s =~ $re ]]; do s=${s//"${BASH_REMATCH[0]}"/}; done
	s=${s//[$'\x80'-$'\xbf']/}
	REPLY=${#s}
}

# Whether the text fits the width of the terminal, always when the width is unknown.
fits() {
	((width == 0)) && return 0
	visible_width "$1"
	((REPLY <= width))
}

# The parts from $1 up to $2 joined into REPLY, without those of rank 1 to $3.
render() {
	local i line=""
	for ((i = $1; i < $2; i++)); do
		((ranks[i] > 0 && ranks[i] <= $3)) && continue
		line+="${line:+${joins[i]}}${parts[i]}"
	done
	REPLY=$line
}

# One line with as few parts dropped as it takes, up to rank DROP_BEFORE_BREAK, otherwise two lines the same way
# up to the last rank, the second from the project on.
width=0
[[ $COLUMNS =~ ^[0-9]+$ ]] && ((COLUMNS > 20)) && width=$((COLUMNS - WIDTH_RESERVE))
count=${#parts[@]}
for ((drop = 0; drop <= DROP_BEFORE_BREAK && drop <= 3; drop++)); do
	render 0 "$count" "$drop"
	line=$REPLY
	fits "$line" && printf '%s' "$line" && exit 0
done
for drop in 0 1 2 3; do
	render 0 "$break_at" "$drop"
	first=$REPLY
	render "$break_at" "$count" "$drop"
	second=$REPLY
	if { fits "$first" && fits "$second"; } || ((drop == 3)); then
		printf '%s%s%s' "$first" "${first:+${second:+$'\n'}}" "$second"
		exit 0
	fi
done
