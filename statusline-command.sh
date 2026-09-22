#!/usr/bin/env bash
#
# CodeBuddy Code status line:
#
#   project  branch*  model  effort  ctx: N%  @账号  积分：用量 / 总额
#
# Kept short, in the spirit of the Codex bottom bar. A segment is dropped when
# it cannot be determined rather than guessed.
#
#   project  basename of workspace.project_dir (falls back to the git root,
#            then to the cwd), bold, in a colour hashed from its name
#   branch   branch of the ACTIVE worktree (not of the launch dir), green;
#            suffixed with "*" when THAT worktree is dirty
#   model    model.display_name, dim
#   effort   value set by /effort, dim
#   ctx      share of the context window in use, dim, then yellow at 75% and
#            red at 90%
#   @账号     nickname of the account the CLI (via wb-switch) is logged in as,
#            magenta; the whole segment is omitted when unknown
#   积分：    本会话累计消耗 / 套餐剩余 (credits), khaki
#
# Where the account and 积分 segments come from
#   Both are produced by one helper, credits-fetch.py, which
#     1. resolves the account the CLI is *actually* using -- wb-switch's
#        ~/.codebuddy-rotate/state.json (activeAccountId) looked up in
#        ~/.wb-switch/accounts.json -- so the bar follows account switches
#        instead of showing WorkBuddy's desktop account (the two are
#        independent);
#     2. calls the billing meter API with that account's token;
#     3. caches to /tmp/statusline-credits.<account>.cache with a 5-min TTL,
#        bypassing the TTL when the transcript changed (i.e. a turn just
#        finished), and falling back to stale cache when the API fails.
#   Output is one TSV line: <nickname> <remaining> <total> <used>.
#
#   积分 shows 本会话消耗 (left) / 剩余 (right). 剩余 is what the product UI
#   shows and what is actually still spendable, so it is the number worth
#   watching. An earlier revision rendered 总额 instead, reasoning that a
#   stable number cannot degrade -- but 总额 is the sum of EVERY package's
#   CycleTotalCapacity, including packages already fully spent (measured on
#   this account: 3525 + 500 = 4025 shown, while only 3193.38 was left), so it
#   overstated the denominator and did not match the UI. The number on the
#   left is the CUMULATIVE cost of this conversation, summed from every real
#   JSON "credit" field in the session transcript plus its subagent
#   transcripts -- see the python block below for why grep could not do this.
#
# How the active worktree is picked
#   current_dir is the directory the CLI was launched in and never changes, so
#   the branch segment used to keep showing the launch dir's branch while the
#   agent worked inside a worktree it had created mid-session. Two signals from
#   the transcript are raced by their own timestamps and the more recent one
#   wins (see the python block above the branch section):
#     1. file-history-snapshot.trackedFileBackups -- the files this session
#        actually WROTE, each with a backupTime. The newest one that maps into a
#        worktree reported by "git worktree list" wins. Being a record of real
#        writes, chat text cannot fake it; it also realpaths what it is handed,
#        so a symlink alias such as /tmp vs /private/tmp still resolves.
#     2. the newest mention of a worktree path in the transcript tail. This is
#        what covers the gap between "worktree created" and "first file written
#        into it", where signal 1 has nothing new to say yet.
#   Only paths git itself reports are ever matched, so a stray path in tool
#   output cannot be picked up by accident. If neither signal fires, the segment
#   falls back to the launch dir's branch -- i.e. exactly the old behaviour.
#
# And effort, in order:
#   1. "effort" in the status line payload
#   2. the last "/effort <value>" command in this session's transcript --
#      /effort is session only, so settings.json goes stale the moment it is
#      changed (it still says "max" while the session runs "ultracode")
#   3. reasoningEffort in ~/.codebuddy/settings.json, as a last resort
#
# No jq: parses the payload with grep/sed so it works with whatever PATH the
# app spawns with. Never blocks on, or writes to, the git index.

export GIT_OPTIONAL_LOCKS=0

# Locate a working python3 up front. The statusline is spawned by the GUI app
# with a minimal PATH (often /usr/bin:/bin), so a Homebrew python3 earlier in
# an interactive PATH is NOT necessarily visible here; without this fallback
# the account and 积分 segments silently render as "--" while the script
# works perfectly when run by hand from a login shell.
# A python3 only counts as usable when its CA trust store is non-empty. A
# Homebrew python whose "Install Certificates" step was never run reports 0
# CAs and fails EVERY HTTPS call with CERTIFICATE_VERIFY_FAILED; the account
# and 积分 segments then blank out while the rest of the bar looks fine, which
# reads as a statusline bug rather than a python one. Validating matters
# because PATH order cannot be trusted: /usr/local/bin/python3 IS that broken
# 3.14 on this machine and it sits ahead of /usr/bin (128 CAs, works) in the
# PATH the app spawns with.
python3_usable() {
  [ -x "$1" ] || return 1
  local n
  n=$("$1" -c 'import ssl;c=ssl.create_default_context();c.load_default_certs();print(len(c.get_ca_certs()))' 2>/dev/null)
  case $n in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$n" -gt 0 ]
}

find_python3() {
  local cand first='' seen=' '
  for cand in "$(command -v python3 2>/dev/null)" \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /opt/homebrew/opt/python/libexec/bin/python3 \
    /usr/bin/python3; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    # The PATH hit is usually one of the fixed paths below as well, and each
    # probe costs a whole python startup, so never probe the same one twice.
    case $seen in *" $cand "*) continue ;; esac
    seen="$seen$cand "
    [ -n "$first" ] || first=$cand
    if python3_usable "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  # No interpreter validated: fall back to the first that merely exists, so the
  # transcript sum still works on a machine with no usable CA store.
  [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
  return 1
}

input=$(cat)

# Pull a string field out of the JSON payload (any depth).
json_str() {
  printf '%s' "${2-$input}" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n 1 \
    | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# Pull a numeric field out of the JSON payload; empty when it is null/absent.
json_num() {
  printf '%s' "${2-$input}" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9.]*" \
    | head -n 1 \
    | sed 's/.*:[[:space:]]*//'
}

# Render a figure compactly: 0.0421 / 12.35 / 10433
fmt_num() {
  awk -v v="$1" 'BEGIN{
    if (v + 0 == 0) { print "0"; exit }
    if (v < 1)        s = sprintf("%.4f", v)
    else if (v < 100) s = sprintf("%.2f", v)
    else              s = sprintf("%.0f", v)
    if (index(s, ".")) { sub(/0+$/, "", s); sub(/\.$/, "", s) }
    print s
  }'
}

dir=$(json_str current_dir)
[ -n "$dir" ] || dir=$(json_str cwd)
[ -n "$dir" ] || dir=$PWD
model=$(json_str display_name)
transcript=$(json_str transcript_path)

# Resolved once, here: both the branch and the 账号/积分 sections need it, and the
# probe behind find_python3 (a CA-store check per candidate) is not free.
python3_bin=$(find_python3)

# ------------------------------------------------------------------- project
project=$(json_str project_dir)
[ -n "$project" ] || project=$(git --no-optional-locks -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$project" ] || project=$dir
project=${project%/}
project=${project##*/}
[ -n "$project" ] || project='?'

# -------------------------------------------------------------------- branch
# Both the branch and the tree the "*" is measured on belong to the ACTIVE
# worktree (see "How the active worktree is picked" in the header). current_dir
# is the CLI's launch directory and never moves, so without this the segment
# kept showing the launch dir's branch while the agent worked inside a worktree
# it had created mid-session.
branch=''
dirty=''
branch_dir=$dir
if command -v git >/dev/null 2>&1; then
  if [ -n "$python3_bin" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
    wt=$("$python3_bin" - "$dir" "$transcript" <<'PYWT' 2>/dev/null
import json, os, re, subprocess, sys

# Transcript tail scanned, in bytes. Read backwards with early exit, so a
# generous window costs only as much as the answer is far away.
WINDOW = 2097152  # 2 MiB


def safe_gitdir(path):
    """The private gitdir this worktree is registered under, via its .git file.

    For a linked worktree <path>/.git is a file holding "gitdir: <path>" (for
    the main worktree it is a real directory, so this returns None). That is
    the only reliable join to .git/worktrees/*: Git derives the private
    gitdir's NAME from the worktree's basename but appends a counter on
    collision (foo, foo1), so matching by name silently misses.
    """
    try:
        with open(os.path.join(path, ".git"), encoding="utf-8", errors="replace") as f:
            head = f.readline().strip()
    except OSError:
        return None
    if not head.startswith("gitdir:"):
        return None
    return os.path.realpath(head[len("gitdir:"):].strip())


def candidates(repo):
    """Every alive, usable worktree -- main one included.

    "git worktree list" reports every worktree ever registered, including ones
    whose directory is gone (that is what the prunable flag means), so both the
    flag and an isdir check have to filter.

    The main worktree must stay in: it is not just the fallback. Once a session
    has written a file in a linked worktree, dropping the main one means its
    newer writes can never claim the branch back, so the bar would keep showing
    the linked worktree long after the session moved home.

    -z: NUL-terminated fields, so a path holding a newline cannot split a block
    (a plain newline-separated parse would). The block separator is an empty
    field either way.
    """
    try:
        out = subprocess.run(
            ["git", "--no-optional-locks", "-C", repo, "worktree", "list", "--porcelain", "-z"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    blocks, cur = [], None
    for line in out.decode("utf-8", "replace").split("\0"):
        if not line.strip():
            if cur is not None:
                blocks.append(cur)
                cur = None
            continue
        if cur is None:
            cur = {"flags": []}
        key, _, val = line.partition(" ")
        if key in ("worktree", "HEAD", "branch", "detached"):
            cur[key] = val
        else:
            cur["flags"].append(key)
    if cur is not None:
        blocks.append(cur)

    found = []
    for b in blocks:
        path = b.get("worktree", "")
        if not path or "prunable" in b["flags"] or not os.path.isdir(path):
            continue
        name = b.get("branch", "")
        if name.startswith("refs/heads/"):
            name = name[len("refs/heads/"):]
        if not name and "detached" in b:
            name = "@" + b.get("HEAD", "")[:8]
        if name:
            # Matching runs on realpath: git reports the resolved path while the
            # transcript quotes whatever the session typed, so /tmp vs
            # /private/tmp (a macOS symlink) would otherwise never match.
            found.append((os.path.realpath(path), path, name, safe_gitdir(path)))
    return found


def owner(cands, path):
    """Longest prefix wins, so a nested worktree cannot claim its parent's files."""
    path = os.path.realpath(path)
    best = None
    for real, orig, br, _ in cands:
        if path == real or path.startswith(real + "/"):
            if best is None or len(real) > len(best[0]):
                best = (real, orig, br)
    return best


def owner_by_gitdir(cands, path):
    """Map <repo>/.git/worktrees/<id>/... back to its worktree.

    Per-worktree state files (the feature-development workflow keeps one) live
    there, so this is how they identify their tree. The join uses the gitdir
    that safe_gitdir() read off each worktree, not the basename -- see there.
    """
    path = os.path.realpath(path)
    best = None
    for real, orig, br, gitdir in cands:
        if not gitdir:
            continue
        if path == gitdir or path.startswith(gitdir + "/"):
            if best is None or len(gitdir) > len(best[0]):
                best = (gitdir, orig, br)
    return best


def parse_ts(value):
    """Milliseconds since epoch, or None when absent/unusable.

    Deliberately not 0: a timestamp that failed to parse is not evidence of
    being old, and collapsing it to 0 would let it silently lose (or win) the
    race below. The caller decides what a missing timestamp means.
    """
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def meta_ts(meta):
    return parse_ts(meta.get("backupTime")) if isinstance(meta, dict) else None


def from_snapshot(cands, lines):
    """Newest file this session actually WROTE that lands in a candidate.

    file-history-snapshot entries carry the tracked set, which only grows, so
    the newest snapshot found scanning backwards is already the complete set.
    Being a record of real writes, this signal cannot be faked by chat text.
    """
    for line in reversed(lines):
        if "file-history-snapshot" not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        snap = obj.get("snapshot")
        if not isinstance(snap, dict) or not isinstance(snap.get("trackedFileBackups"), dict):
            continue
        cwd = obj.get("cwd") or ""
        tracked = snap["trackedFileBackups"]
        for path, meta in sorted(tracked.items(), key=lambda kv: meta_ts(kv[1]) or 0, reverse=True):
            if not path:
                continue
            full = path if os.path.isabs(path) else os.path.normpath(os.path.join(cwd, path))
            # gitdir first: <repo>/.git/worktrees/<id>/... sits UNDER the main
            # worktree's path, so a plain prefix match would hand it to main.
            hit = owner_by_gitdir(cands, full) or owner(cands, full)
            if hit:
                return (meta_ts(meta), hit[1], hit[2])
        # The set only grows: if nothing in the newest snapshot maps, no older
        # one can either.
        return None
    return None


# Characters that end a path token when the text signal widens a match. Kept
# permissive (anything but these) so non-ASCII names such as docs/F3.3-审核 stay
# in one token; a wrong extension only fails to resolve, which just falls back.
# The quote and backtick are hex escapes on purpose: a literal backtick inside
# a $( ) heredoc body can pair up with another one and break bash's parse of
# the whole script (worth knowing when editing these blocks).
PATH_STOP = set(" \t\r\n\"\x27\x60()[]{}<>,;:=|")


def from_text(cands, lines, pattern):
    """Newest mention of a candidate path, read back to front.

    Covers the gap between "worktree created" and "first file written into it",
    where the snapshot signal has nothing yet. The lookahead is what stops
    .../F3.3-accuracy-reco from matching .../F3.3-accuracy-recognition.

    The match is widened to the whole path token before resolving, for the same
    reason the snapshot signal resolves gitdir first: <repo>/.git/worktrees/<id>
    /... starts with the main worktree's own path, so a bare prefix match would
    hand a linked worktree's state file to main.
    """
    for line in reversed(lines):
        matches = list(pattern.finditer(line))
        if not matches:
            continue
        m = matches[-1]
        end = m.end()
        while end < len(line) and line[end] not in PATH_STOP:
            end += 1
        token = line[m.start():end]
        hit = owner_by_gitdir(cands, token) or owner(cands, m.group(1))
        if not hit:
            continue
        ts = None
        if '"timestamp"' in line:
            try:
                ts = parse_ts(json.loads(line).get("timestamp"))
            except ValueError:
                ts = None
        return (ts, hit[1], hit[2])
    return None


def main():
    repo = sys.argv[1]
    transcript = sys.argv[2] if len(sys.argv) > 2 else ""
    cands = candidates(repo)
    if not cands or not transcript or not os.path.isfile(transcript):
        return
    with open(transcript, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - WINDOW))
        text = f.read().decode("utf-8", "replace")
    lines = text.splitlines()
    # Both spellings of each worktree go into the pattern: the transcript quotes
    # the path as it was typed, while git reports it resolved, and on macOS
    # those can differ (/tmp vs /private/tmp). owner() realpaths whatever
    # matched, so either spelling maps back to the same candidate.
    #
    # The main worktree is deliberately NOT in this set. Signal A carries it
    # (that is what lets a session come home after working in a linked tree),
    # and the launch-dir fallback covers it too; what signal A cannot see, this
    # one only needs to cover for linked worktrees. Including main instead let
    # any prose mention of a path inside the repo outrank real writes -- the
    # closing report of a turn does that constantly. Measured: the newest
    # assistant message beat a genuine write by ~2 minutes and flipped
    # feature/F3.3-accuracy-recovery to develop. A symlinked alias git never
    # reports is likewise missed here; signal A has no such blind spot.
    forms = []
    for real, orig, _, gitdir in cands:
        if not gitdir:
            continue  # main worktree (or an unreadable .git): signal A's job
        for f in (orig, real):
            if f not in forms:
                forms.append(f)
    # No linked worktree means no cold-start signal at all -- and an empty
    # alternation would compile to a pattern matching every line.
    pattern = None
    if forms:
        pattern = re.compile("(" + "|".join(re.escape(f) for f in forms) + ")(?![A-Za-z0-9._-])")

    # The two signals are raced by their own timestamps: whichever activity is
    # more recent is the better evidence of where the session is working. A
    # missing timestamp (None) never outranks a present one -- it means the
    # field was absent or unparseable, which says nothing about recency, so the
    # snapshot signal keeps its precedence instead of losing to a 0.
    best = from_snapshot(cands, lines)
    other = from_text(cands, lines, pattern) if pattern else None
    if other is not None:
        if best is None:
            best = other
        elif other[0] is not None and (best[0] is None or other[0] > best[0]):
            best = other
    if best is not None:
        sys.stdout.write("%s\t%s\n" % (best[1], best[2]))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never break the statusline: no output means "fall back to current_dir".
        pass
PYWT
)
    if [ -n "$wt" ]; then
      IFS=$'\t' read -r wt_path branch <<<"$wt"
      if [ -n "$branch" ]; then
        branch_dir=$wt_path
      else
        branch=''
      fi
    fi
  fi

  if [ -z "$branch" ]; then
    if ! branch=$(git --no-optional-locks -C "$dir" symbolic-ref --short HEAD 2>/dev/null); then
      # Detached HEAD: show the short hash instead of a branch name.
      sha=$(git --no-optional-locks -C "$dir" rev-parse --short=8 HEAD 2>/dev/null)
      [ -n "$sha" ] && branch="@$sha" || branch=''
    fi
  fi

  if [ -n "$branch" ]; then
    [ -n "$(git --no-optional-locks -C "$branch_dir" status --porcelain 2>/dev/null | head -n 1)" ] && dirty='*'
  fi
fi

# -------------------------------------------------------------------- effort
effort=$(json_str effort)
if [ -z "$effort" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
  # The value class is restricted to word characters: the transcript also holds
  # the text of shell commands run in the session, which may quote this very
  # pattern and would otherwise be picked up as the newest match.
  effort=$(grep -o '<command-name>/effort</command-name><command-args>[A-Za-z0-9_-][A-Za-z0-9_-]*' "$transcript" 2>/dev/null \
    | tail -n 1 | sed 's/.*<command-args>//')
  case $effort in
    ''|*[!A-Za-z0-9_-]*) effort='' ;;
  esac
fi
if [ -z "$effort" ] && [ -r "$HOME/.codebuddy/settings.json" ]; then
  effort=$(sed -n 's/.*"reasoningEffort"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$HOME/.codebuddy/settings.json" 2>/dev/null | head -n 1)
fi

# ------------------------------------------------------------------ context
pct=$(json_num used_percentage)
if [ -n "$pct" ]; then
  # The payload carries decimals (e.g. 17.94); show whole percents, and "<1"
  # rather than a misleading 0 when there is a little usage.
  pct=$(awk -v p="$pct" 'BEGIN{
    if (p + 0 > 0 && p + 0 < 1) { print "<1"; exit }
    printf "%d", p + 0.5
  }')
fi
size=$(json_num context_window_size)
if [ -z "$pct" ]; then
  # Only look at the current_usage object, so no other token counter in the
  # payload can be picked up by accident.
  cu=${input#*current_usage}
  if [ -n "$size" ] && [ "$size" != 0 ] && [ "$cu" != "$input" ]; then
    used=$(printf '%s\n' \
      "$(json_num input_tokens "$cu")" \
      "$(json_num output_tokens "$cu")" \
      "$(json_num cache_creation_input_tokens "$cu")" \
      "$(json_num cache_read_input_tokens "$cu")" \
      | awk '{s+=$1} END {print s+0}')
    [ "$used" -gt 0 ] && pct=$(awk -v u="$used" -v s="$size" 'BEGIN{printf "%.0f", u * 100 / s}')
  fi
fi
if [ -z "$pct" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
  # Fall back to the newest usage block in the transcript. tail seeks to the
  # end, so this stays cheap on multi-megabyte transcripts.
  usage_line=$(tail -n 4000 "$transcript" 2>/dev/null \
    | grep -E '"(input_tokens|inputTokens|prompt_tokens|promptTokens)"' \
    | tail -n 1)
  if [ -n "$usage_line" ]; then
    used=$(printf '%s' "$usage_line" \
      | grep -oE '"(input_tokens|inputTokens|prompt_tokens|promptTokens|cache_read_input_tokens|cacheReadInputTokens|cache_creation_input_tokens|cacheCreationInputTokens|output_tokens|outputTokens)"[[:space:]]*:[[:space:]]*[0-9]+' \
      | sed -E 's/.*:[[:space:]]*//' \
      | awk '{ s += $1 } END { print s + 0 }')
    [ -n "$size" ] || size=${CODEBUDDY_CONTEXT_WINDOW:-200000}
    pct=$(awk -v u="$used" -v w="$size" 'BEGIN{
      if (u + 0 <= 0 || w + 0 <= 0) { print ""; exit }
      p = u * 100 / w
      if (p > 0 && p < 1) print "<1"
      else printf "%d", p + 0.5
    }')
  fi
fi

# --------------------------------------------------------------- 账号 / 积分
# Live data, read through credits-fetch.py:
#   - 账号名 (nickname) of the account the CLI is logged in as
#   - 真实套餐额度 (remaining / total / used) from the billing meter API
# Output is TSV: <nickname> <remaining> <total> <used>; every field is empty
# when python3, the account store, or the API is unavailable.
# (python3_bin was already resolved near the top.)
credits_nick=''
credits_rem=''
credits_total=''
credits_api_used=''
if [ -n "$python3_bin" ]; then
  fetched=$("$python3_bin" "$HOME/.codebuddy/credits-fetch.py" "${transcript:-}" 2>/dev/null)
  if [ -n "$fetched" ]; then
    credits_nick=$(printf '%s' "$fetched"    | awk -F'\t' '{print $1}')
    credits_rem=$(printf '%s' "$fetched"     | awk -F'\t' '{print $2}')
    credits_total=$(printf '%s' "$fetched"   | awk -F'\t' '{print $3}')
    credits_api_used=$(printf '%s' "$fetched" | awk -F'\t' '{print $4}')
  fi
fi

# 累计消耗：主 transcript + 其 subagents/*.jsonl 里所有 "credit" 的总和。
# 逐行 json.loads 后只认真正的 JSON 键 "credit"（数值或数字字符串）；工具
# 输出/命令文本里的 '"credit":123' 字样只是字符串值，永远不会混进总和——
# grep -oE 会把这类文本当成字段抓走，正是 effort 解析在上方防御过的自我
# 污染。子代理 transcript 位于「主 transcript 去 .jsonl 扩展名/subagents/」
# （实证布局），目录不存在时安静跳过。总和按「所有参与求和文件的
# 路径+size+mtime_ns」哈希成缓存键存于 /tmp/statusline-credits-sum.cache：
# 子代理文件在会话中持续追加且会中途新增，任何一个变化都必须使缓存失效，
# 否则新消耗永远不上屏。
credits_used=''
if [ -n "$python3_bin" ]; then
  credits_used=$("$python3_bin" - "${transcript:-}" <<'PYCRED'
import hashlib, json, os, sys

CACHE = "/tmp/statusline-credits-sum.cache"

def collect_files():
    # Main transcript plus every subagent transcript. Verified layout
    # (2026-09-04):
    #   main:  <dir>/<session-id>.jsonl
    #   subs:  <dir>/<session-id>/subagents/agent-*.jsonl
    # i.e. "<main transcript without .jsonl>/subagents/*.jsonl". A missing
    # subagents dir (most sessions have none) is skipped quietly: main-only.
    main_path = sys.argv[1] if len(sys.argv) > 1 else ""
    if not main_path or not os.path.isfile(main_path):
        return []
    files = [main_path]
    base = main_path[:-6] if main_path.endswith(".jsonl") else main_path
    sub_dir = os.path.join(base, "subagents")
    try:
        names = sorted(os.listdir(sub_dir))
    except OSError:
        return files
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(sub_dir, name)
        try:
            if os.path.isfile(path):
                files.append(path)
        except OSError:
            pass
    return files

def cache_key(files):
    # Every summed file's path+size+mtime_ns is hashed into one key. Subagent
    # files are appended to, and new ones created, throughout a session, so
    # ANY change must invalidate the cached sum or new burn never shows up.
    # Returns "" (this round never cached) if a file vanishes mid-scan.
    parts = []
    try:
        for path in files:
            st = os.stat(path)
            parts.append("%s|%d|%d" % (path, st.st_size, st.st_mtime_ns))
    except OSError:
        return ""
    if not parts:
        return ""
    # encode with "replace": os.listdir can hand back surrogate-escaped names
    # that plain utf-8 encoding would raise on.
    return hashlib.md5("\n".join(parts).encode("utf-8", "replace")).hexdigest()

def read_cache(key):
    if not key:
        return None
    try:
        with open(CACHE) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t", 1)
                if len(parts) == 2 and parts[0] == key:
                    return float(parts[1])
    except (OSError, ValueError):
        pass
    return None

def write_cache(key, total):
    if not key:
        return
    # Write to a temp file and os.replace() it into place: concurrent renders
    # (several sessions) could otherwise truncate each other's cache line. A
    # clobbered cache only costs one re-scan, but atomicity is cheap.
    tmp = "%s.%d.tmp" % (CACHE, os.getpid())
    try:
        with open(tmp, "w") as f:
            f.write("%s\t%.6f\n" % (key, total))
        os.replace(tmp, CACHE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass

def walk(root, out):
    # Only real JSON keys named "credit" count. Credit-like text inside
    # strings (tool output, command text, this script's own source when it is
    # cat'ed into context) is invisible here -- exactly the pollution the old
    # grep -oE could not avoid. bool is excluded explicitly because in Python
    # it is an int subclass. Explicit stack instead of recursion, so a
    # pathologically deep line can never hit the interpreter recursion limit
    # and zero out the whole sum.
    stack = [root]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "credit" and not isinstance(v, bool):
                    if isinstance(v, (int, float)):
                        out.append(float(v))
                    elif isinstance(v, str):
                        try:
                            out.append(float(v.strip()))
                        except ValueError:
                            pass
                stack.append(v)
        elif isinstance(node, list):
            stack.extend(node)

def collect_vals(path, out):
    # Sum one transcript file into "out": JSONL line by line, and only when
    # no line parsed, one guarded attempt at the whole file as a single JSON
    # document (first non-space byte must be '{' or '['). A file that cannot
    # be opened or parsed contributes nothing instead of failing the bar.
    parsed = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                parsed += 1
                walk(obj, out)
        if parsed == 0:
            with open(path, encoding="utf-8", errors="replace") as f:
                if f.read(64).lstrip()[:1] in ("{", "["):
                    with open(path, encoding="utf-8", errors="replace") as f:
                        walk(json.load(f), out)
    except (OSError, ValueError):
        pass

def main():
    files = collect_files()
    key = cache_key(files)
    cached = read_cache(key)
    if cached is not None:
        return cached
    vals = []
    for path in files:
        collect_vals(path, vals)
    total = sum(vals)
    write_cache(key, total)
    return total

try:
    total = main()
except Exception:
    # Never break the statusline; degrade to 0 rather than guessing.
    total = 0.0
print("%.6f" % total)
PYCRED
)
  credits_used=$(printf '%s' "$credits_used" | tr -d '[:space:]')
  if [ -n "$credits_used" ]; then
    credits_used=$(fmt_num "$credits_used")
  fi
fi

# 消耗的取值顺序：本会话累计（真·每轮消耗）优先；transcript 缺失或没有
# credit 字段（部分 CLI 版本本地不落 credit，累计恒为 0）时退回 billing API
# 的周期用量 used，这样右边不会因为左边取不到就整个塌掉。
[ -n "$credits_used" ] || credits_used=$(fmt_num "${credits_api_used:-0}")
[ -n "$credits_used" ] || credits_used='--'
[ -z "$credits_rem" ] && credits_rem='--'
[ -z "$credits_nick" ]  && credits_nick=''

# --------------------------------------------------------------------- debug
# Write "on" to /tmp/statusline-debug.on to capture the raw payload and
# everything parsed out of it; the dump lands in /tmp/statusline-debug.out on
# the next render. Write "off" there (or delete the file) to stop dumping.
if [ "$(cat /tmp/statusline-debug.on 2>/dev/null)" = on ]; then
  # One compact line per render, appended, so every session can be compared.
  # Fields that could not be determined show as "-".
  printf '%s\t%s\tproject=%s\tpct=%s\traw=%s\tsize=%s\tcredits=%s\tmodel=%s\teffort=%s\tbranch=%s\n' \
    "$(date '+%F %T')" "$(json_str session_id)" "$project" \
    "${pct:--}" "$(json_num used_percentage)" "${size:--}" "used=${credits_used:--} rem=${credits_rem:--}" \
    "${model:--}" "${effort:--}" "${branch:--}" \
    >> /tmp/statusline-render.log 2>/dev/null

  # Full payload dump for the newest render only.
  {
    echo "=== $(date '+%F %T') ==="
    echo "--- payload ---"
    printf '%s\n' "$input"
    echo "--- transcript ---"
    echo "$transcript  ($(wc -c <"$transcript" 2>/dev/null | tr -d ' ') bytes)"
    echo "--- first 1200 bytes of transcript ---"
    head -c 1200 "$transcript" 2>/dev/null
    echo
    echo "--- newest usage line ---"
    printf '%.1500s\n' "$usage_line"
    echo "--- used=${used:-none} size=${size:-none} pct=${pct:-none} ---"
    echo "--- credits cumulative sum ---"
    echo "used=${credits_used:-none} cache=$(tail -n 1 /tmp/statusline-credits-sum.cache 2>/dev/null)"
    echo "--- nickname=${credits_nick:-none} used=${credits_used:-none} rem=${credits_rem:-none} total=${credits_total:-none} ---"
    echo "--- python3=${python3_bin:-none} ---"
    echo "--- credits-fetch raw: ${fetched:-none} ---"
    echo "--- every credit/cost/token-ish key in the transcript ---"
    grep -oE '"[A-Za-z_]*(redit|redit_|cost|Cost|token|Token|ontext|ontext_)[A-Za-z_]*"' \
      "$transcript" 2>/dev/null | sort | uniq -c | sort -rn | head -n 40
    echo "--- subagents dir ---"
    ls -la "${transcript%.jsonl}/subagents" 2>/dev/null | head -n 20
    echo "--- sessions dir ---"
    ls -la "$(dirname "$transcript")" 2>/dev/null | head -n 20
  } > /tmp/statusline-debug.out 2>&1
fi

# -------------------------------------------------------------------- render
c_branch=$'\033[38;5;76m'
c_dirty=$'\033[38;5;178m'
c_dim=$'\033[38;5;244m'
c_warn=$'\033[38;5;178m'
c_crit=$'\033[38;5;196m'
# ctx and 积分 used to share the dim grey, which made both new segments look
# like dead text at normal usage. They now carry their own hue; none of these
# appear in the project palette, so a project can never look like a counter.
c_ctx=$'\033[38;5;73m'      # teal, under 75%
c_credits=$'\033[38;5;179m' # khaki (积分)
c_nick=$'\033[38;5;207m'    # magenta (账号名)，与 teal ctx / khaki 积分都区分
off=$'\033[0m'

# The project gets a colour of its own, hashed from its name so that the same
# project always looks the same and neighbouring projects rarely collide.
# Mid to bright hues only: dark ones disappear on a black terminal.
project_palette=(39 208 141 77 215 111 183 228 84 203)
if command -v md5 >/dev/null 2>&1; then
  # md5 spreads real project names far more evenly than cksum, which bunched
  # five of eleven onto the same colour.
  project_hash=$(printf '%s' "$project" | md5 -q | cut -c1-8)
  project_hash=$((0x$project_hash))
else
  project_hash=$(printf '%s' "$project" | cksum | awk '{print $1}')
fi
c_project=$'\033[1;38;5;'"${project_palette[$((project_hash % ${#project_palette[@]}))]}"m

printf '%s%s%s' "$c_project" "$project" "$off"
if [ -n "$branch" ]; then
  if [ -n "$dirty" ]; then
    printf '  %s%s%s' "$c_dirty" "$branch$dirty" "$off"
  else
    printf '  %s%s%s' "$c_branch" "$branch" "$off"
  fi
fi
[ -n "$model" ]  && printf '  %s%s%s' "$c_dim" "$model" "$off"
[ -n "$effort" ] && printf '  %s%s%s' "$c_dim" "$effort" "$off"

if [ -n "$pct" ]; then
  # Starts at teal and only escalates, so a healthy ctx is still readable
  # rather than dimmed into the background.
  c_ctx_now=$c_ctx
  case $pct in
    '<1') ;;
    *)  if [ "$pct" -ge 90 ] 2>/dev/null; then c_ctx_now=$c_crit
        elif [ "$pct" -ge 75 ] 2>/dev/null; then c_ctx_now=$c_warn
        fi ;;
  esac
  printf '  %sctx: %s%%%s' "$c_ctx_now" "$pct" "$off"
fi

# 账号名（CLI 当前登录昵称；拿不到时整段省略），独立洋红色与积分区分。
if [ -n "$credits_nick" ]; then
  printf '  %s@%s%s' "$c_nick" "$credits_nick" "$off"
fi
# 积分：本会话累计消耗 / 剩余，用 khaki。右侧用「剩余」而不是「总额」——总额会把
# 已经用尽的套餐一起算进分母（本账号实测显示 4025，实际可用只有 3193.38），和产品
# 界面显示的数对不上；剩余值直接取 API 的 CycleRemainCapacity，界面显示多少就是多少。
printf '  %s积分：%s / %s%s' "$c_credits" "$credits_used" "$credits_rem" "$off"
printf '\n'

exit 0
