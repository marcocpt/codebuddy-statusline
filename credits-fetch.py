#!/usr/bin/env python3
"""Fetch the logged-in WorkBuddy account name and real remaining credits.

Reads the desktop auth file for the access token + uid + domain, then calls the
billing meter API. Outputs a single TSV line:

    <nickname>\t<remaining>\t<total>\t<used>

Fields are empty when unavailable. A file cache with a TTL keeps the statusline
fast and avoids hammering the API on every render (the gateway also rate-limits
with an intermittent 403). On any failure we fall back to the cached value, and
if there is no cache we print empty fields so the caller can show a placeholder.

The WAF requires Origin/Referer headers or it returns 403 code:10085; this is
the one non-obvious detail (the reference repo workbuddy-switch omits them).
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error

AUTH_FILE = os.path.expanduser(
    "~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
)
# wb-switch（CodeBuddy CLI 账号轮换）维护的"CLI 当前账号"。CLI 的 apiKeyHelper
# 每次都从这里取 token，所以这才是 CLI 真正在用的账号；桌面端 auth 文件里是
# WorkBuddy App 的当前账号，两者互相独立——状态栏必须跟 CLI 对齐，否则会
# 出现"切了 CLI 账号但状态栏一直显示 WorkBuddy 当前账号"的错觉。
ROTATE_STATE_FILE = os.path.expanduser("~/.codebuddy-rotate/state.json")
ACCOUNTS_FILE = os.path.expanduser("~/.wb-switch/accounts.json")
CACHE_FILE = "/tmp/statusline-credits.cache"
TTL = 300  # seconds (默认 5 分钟刷新一次)


def resolve_cli_account():
    """Resolve the account the CodeBuddy CLI is actually using.

    Reads wb-switch's rotate state (activeAccountId, with the legacy numeric
    index as fallback) and looks the account up in the shared account store.
    Returns a dict with token/uid/domain/nickname, or None when wb-switch is
    not configured (then the caller falls back to the desktop auth file).
    """
    try:
        with open(ROTATE_STATE_FILE) as f:
            state = json.load(f)
        with open(ACCOUNTS_FILE) as f:
            accounts = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or not isinstance(accounts, list) or not accounts:
        return None

    active_id = state.get("activeAccountId")
    account = None
    if isinstance(active_id, str) and active_id:
        for candidate in accounts:
            if not isinstance(candidate, dict):
                continue
            if candidate.get("id") == active_id or candidate.get("uid") == active_id:
                account = candidate
                break
    if account is None:
        try:
            index = int(state.get("active", 0)) % len(accounts)
        except (TypeError, ValueError):
            index = 0
        candidate = accounts[index]
        if isinstance(candidate, dict):
            account = candidate
    if not isinstance(account, dict):
        return None

    token = str(account.get("access_token") or "").strip()
    if token.startswith("Bearer "):
        token = token[len("Bearer "):].strip()
    if not token:
        return None
    return {
        "token": token,
        "uid": str(account.get("uid") or ""),
        "domain": str(account.get("domain") or "www.workbuddy.cn"),
        "nickname": (
            account.get("nickname") or account.get("email")
            or account.get("uid") or ""
        ),
        # 稳定标识：用于把缓存按账号分开，切账号后立刻取新数据。
        "id": str(account.get("id") or account.get("uid") or "cli"),
    }


def cache_file_for(account_key):
    """Per-account cache so switching CLI accounts never serves stale data."""
    if not account_key:
        return CACHE_FILE
    safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in account_key)[:40]
    return "/tmp/statusline-credits.%s.cache" % safe


def read_cached(cache_file=CACHE_FILE):
    try:
        with open(cache_file) as f:
            line = f.read().strip()
        return line
    except OSError:
        return None


def write_cache(line, cache_file=CACHE_FILE):
    try:
        with open(cache_file, "w") as f:
            f.write(line + "\n")
    except OSError:
        pass


def fetch(cli_account=None):
    """Query the billing meter for the account the CLI is really using.

    `cli_account` comes from resolve_cli_account(); when wb-switch is not
    configured we fall back to the desktop auth file (WorkBuddy's account).
    """
    if cli_account:
        token = cli_account["token"]
        uid = cli_account["uid"]
        domain = cli_account["domain"]
        nickname = cli_account["nickname"]
    else:
        try:
            with open(AUTH_FILE) as f:
                d = json.load(f)
        except (OSError, ValueError):
            return None
        auth = d.get("auth", {})
        account = d.get("account", {})
        token = auth.get("accessToken") or auth.get("access_token")
        uid = account.get("uid", "")
        domain = auth.get("domain") or "www.workbuddy.cn"
        if not token:
            return None
        nickname = account.get("nickname") or account.get("email") or uid or ""

    url = f"https://{domain}/billing/meter/get-user-resource-summary"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-User-Id": uid,
        "X-Client-Platform": "web",
        "X-Domain": domain,
        "Origin": "https://www.workbuddy.cn",
        "Referer": "https://www.workbuddy.cn/",
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        ),
    }
    req = urllib.request.Request(url, data=b"{}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read())
    except (urllib.error.URLError, OSError, ValueError):
        return None

    if body.get("code") not in (0, 200) or "data" not in body:
        return None
    pkgs = body["data"].get("Packages") or body["data"].get("packages") or []
    total = sum(float(p.get("CycleTotalCapacity") or 0) for p in pkgs)
    rem = sum(float(p.get("CycleRemainCapacity") or 0) for p in pkgs)
    used = sum(float(p.get("CycleUsedCapacity") or 0) for p in pkgs)
    # Trim float noise (e.g. 2601.66000001 -> 2601.66).
    total = round(total, 2)
    rem = round(rem, 2)
    used = round(used, 2)
    return f"{nickname}\t{rem}\t{total}\t{used}"


def main():
    # Optional arg: path to the current session transcript. When the
    # transcript changed since we last cached (i.e. a new turn just finished),
    # we bypass the TTL and refresh immediately — this is how "refresh when the
    # conversation stops" works without a CLI hook (CodeBuddy has no Stop hook).
    transcript = sys.argv[1] if len(sys.argv) > 1 else ""

    # CLI 实际在用的账号优先；wb-switch 未接入时退回桌面端 auth 文件。
    cli_account = resolve_cli_account()
    cache_file = cache_file_for(cli_account["id"] if cli_account else "")

    # Serve from cache if fresh AND the transcript hasn't moved.
    cached = read_cached(cache_file)
    cache_mtime = ""
    if cached:
        parts = cached.split("\t")
        # layout: nickname rem total used <cache_ts> <transcript_mtime>
        if len(parts) == 6:
            ts = parts[4]
            cache_mtime = parts[5]
            if time.time() - float(ts) < TTL:
                fresh = True
                if transcript and os.path.isfile(transcript):
                    try:
                        if str(int(os.stat(transcript).st_mtime)) == cache_mtime:
                            fresh = True  # transcript unchanged -> serve cache
                        else:
                            fresh = False  # transcript moved -> force refresh
                    except OSError:
                        fresh = True
                if fresh:
                    print(cached)
                    return

    line = fetch(cli_account)
    if line:
        mtime = ""
        if transcript and os.path.isfile(transcript):
            try:
                mtime = str(int(os.stat(transcript).st_mtime))
            except OSError:
                mtime = ""
        write_cache(line + "\t" + str(int(time.time())) + "\t" + mtime, cache_file)
        print(line)
        return

    # Failure: fall back to stale cache if we have it.
    if cached:
        print(cached)
        return

    # Nothing at all.
    print("\t\t\t")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never crash the statusline; emit empty fields.
        print("\t\t\t")

