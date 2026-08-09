"""GitHub App auth and the waker's "is there work?" predicate.

Deliberately stdlib-only and free of any AWS import, so the whole decision path
can be exercised off-Lambda against live GitHub with a local PEM.

The predicate here MUST agree with the rule table `ob-poll` evaluates on the
instance (spec §6), because the two together form the loop: this decides
whether to power the instance on, `ob-poll` decides what to do once it is up,
and `ob-idle-stop` powers it back off when `ob-poll` finds nothing.

Rules 1 (a lock is held) and 4 (the attempt budget) are instance-local state
that this code cannot see. Rule 4 is covered anyway: exhausting the budget makes
the instance apply `<prefix>:blocked` — to the PR when one exists, otherwise to
a tracking issue titled `openbuilder blocked: <slug>` — and both are checked
below. Without that check a permanently failing slug would wake the instance
every five minutes forever.
"""

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from rs256 import b64u, sign

API = "https://api.github.com"
_UA = "openbuilder-waker"
_TIMEOUT = 15


class GitHubError(RuntimeError):
    pass


def _request(
    path: str, token: str | None = None, jwt: str | None = None, method: str = "GET"
):
    url = path if path.startswith("http") else f"{API}/{path.lstrip('/')}"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": _UA,
    }
    if jwt:
        headers["Authorization"] = f"Bearer {jwt}"
    elif token:
        headers["Authorization"] = f"token {token}"
    request = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            return json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        detail = (error.read() or b"").decode("utf-8", "replace")[:400]
        raise GitHubError(f"{method} {url} -> HTTP {error.code}: {detail}") from None
    except urllib.error.URLError as error:
        raise GitHubError(f"{method} {url} -> {error.reason}") from None


def app_jwt(app_id: str, pem: str) -> str:
    """A short-lived App JWT. Mirrors runner/bin/ob-token's claim set."""
    now = int(time.time())
    header = b64u(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    # iat is backdated by a minute so a slow clock cannot make GitHub reject the
    # token; exp is well inside GitHub's 10-minute ceiling.
    claims = b64u(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}).encode()
    )
    payload = header + b"." + claims
    return (payload + b"." + b64u(sign(pem, payload))).decode()


def installation_token(app_id: str, installation_id: str, pem: str) -> str:
    body = _request(
        f"app/installations/{installation_id}/access_tokens",
        jwt=app_jwt(app_id, pem),
        method="POST",
    )
    token = (body or {}).get("token")
    if not token:
        raise GitHubError("installation token response carried no token")
    return token


def plan_slugs(token: str, repo: str, branch_prefix: str) -> list[str]:
    """Slugs with a `<prefix>/plan/<slug>` branch, in the order GitHub lists them."""
    prefix = f"refs/heads/{branch_prefix}/plan/"
    refs = _request(
        f"repos/{repo}/git/matching-refs/heads/{branch_prefix}/plan/", token=token
    )
    slugs = []
    for ref in refs or []:
        name = ref.get("ref", "")
        if name.startswith(prefix):
            slug = name[len(prefix) :]
            if slug:
                slugs.append(slug)
    return slugs


def work_pr(token: str, repo: str, branch_prefix: str, slug: str):
    """(number, {labels}) for the PR whose head is `<prefix>/work/<slug>`, else None.

    `state=all` on purpose: a closed PR still means the implement round already
    happened, exactly as rule 5 reads it.
    """
    owner = repo.split("/", 1)[0]
    head = f"{owner}:{branch_prefix}/work/{slug}"
    prs = _request(
        f"repos/{repo}/pulls?state=all&per_page=1&head={urllib.parse.quote(head, safe=':/')}",
        token=token,
    )
    if not prs:
        return None
    pr = prs[0]
    return pr["number"], {label["name"] for label in pr.get("labels", [])}


def blocked_slugs(token: str, repo: str, label_prefix: str) -> set[str]:
    """Slugs whose tracking issue is open and labelled `<prefix>:blocked`."""
    label = urllib.parse.quote(f"{label_prefix}:blocked")
    issues = _request(
        f"repos/{repo}/issues?state=open&per_page=100&labels={label}", token=token
    )
    marker = "openbuilder blocked: "
    slugs = set()
    for issue in issues or []:
        title = (issue.get("title") or "").strip()
        if title.lower().startswith(marker):
            slugs.add(title[len(marker) :].strip())
    return slugs


def decide(token: str, repo: str, branch_prefix: str, label_prefix: str) -> list[dict]:
    """One verdict per plan branch: `actionable` plus the rule that decided it."""
    slugs = plan_slugs(token, repo, branch_prefix)
    if not slugs:
        return []
    blocked = blocked_slugs(token, repo, label_prefix)
    verdicts = []

    def verdict(slug, actionable, rule, reason):
        verdicts.append(
            {
                "repo": repo,
                "slug": slug,
                "actionable": actionable,
                "rule": rule,
                "reason": reason,
            }
        )

    for slug in slugs:
        found = work_pr(token, repo, branch_prefix, slug)
        if found is None:
            if slug in blocked:
                verdict(slug, False, 4, "blocked-issue")
            else:
                verdict(slug, True, 5, "no-pr")
            continue
        number, labels = found
        if f"{label_prefix}:approved" in labels:
            verdict(slug, False, 2, f"approved(pr={number})")
        elif f"{label_prefix}:blocked" in labels:
            verdict(slug, False, 3, f"blocked(pr={number})")
        elif f"{label_prefix}:changes-requested" in labels:
            verdict(slug, True, 6, f"changes-requested(pr={number})")
        else:
            verdict(slug, False, 7, f"awaiting-reviewer(pr={number})")
    return verdicts
