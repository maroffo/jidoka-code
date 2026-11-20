"""Collect bounded source context from a public GitHub pull request."""

import base64
import hashlib
import json
import re
from collections.abc import Set as AbstractSet
from time import monotonic
from typing import TypeGuard
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from .contracts import Snapshot, SourceFile

_REPO = r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/(?!\.{1,2}(?:/|$))[A-Za-z0-9_.-]{1,100}"
_PULL_URL = re.compile(
    rf"https://github\.com/({_REPO})/pull/([1-9][0-9]{{0,9}})/?(?:[?#][^\s]*)?",
    re.IGNORECASE | re.ASCII,
)
_SHA = re.compile(r"[0-9a-f]{40}")
_MAX_REQUESTS = 48
_MAX_DOWNLOAD = 6_000_000
_MAX_RESPONSE = 2_000_000
_PULL_BYTES = 128_000
_SECONDS = 30
_REQUEST_SECONDS = 5
_COMMIT_PAGE = 20
_MAX_COMMIT_PAGES = 3
_MAX_CHANGED = 20
_MAX_CONTEXT = 8
_MAX_BLOB = 24_000
_MAX_PATCH = 16_000
_MAX_SOURCE = 96_000
_MAX_INTENT = 8_000


class _Unavailable(Exception):
    pass


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _GitHub:
    def __init__(self):
        self.client = build_opener(ProxyHandler({}), _NoRedirect())
        self.deadline = monotonic() + _SECONDS
        self.requests = 0
        self.remaining = _MAX_DOWNLOAD
        self.blobs = {}

    def get(self, path, *, cap=_MAX_RESPONSE, final=False):
        # Leave room to recheck the pull request after the immutable reads.
        reserve = 0 if final else 1
        budget = min(cap, self.remaining - reserve * _PULL_BYTES)
        timeout = self.deadline - monotonic() - reserve * _REQUEST_SECONDS
        if self.requests >= _MAX_REQUESTS - reserve or budget <= 0 or timeout <= 0:
            raise _Unavailable
        self.requests += 1
        deadline = monotonic() + min(timeout, _REQUEST_SECONDS)
        request = Request(
            f"https://api.github.com/repos/{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "jidoka-review",
            },
        )
        try:
            with self.client.open(request, timeout=min(timeout, _REQUEST_SECONDS)) as response:
                body = bytearray()
                while monotonic() < deadline:
                    chunk = response.read1(min(65_536, budget + 1 - len(body)))
                    self.remaining -= len(chunk)
                    if not chunk:
                        return _object(json.loads(body))
                    body.extend(chunk)
                    if len(body) > budget:
                        break
        except (OSError, ValueError, RecursionError):
            raise _Unavailable from None
        raise _Unavailable

    def blob(self, repo, sha, size):
        if sha in self.blobs:
            return self.blobs[sha]
        data = self.get(f"{repo}/git/blobs/{sha}", cap=40_000)
        content = data.get("content")
        if data.get("encoding") != "base64" or not isinstance(content, str):
            raise _Unavailable
        try:
            raw = base64.b64decode(content.replace("\n", ""), validate=True)
            digest = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw, usedforsecurity=False)
            if len(raw) != size or digest.hexdigest() != sha or b"\0" in raw:
                raise _Unavailable
            value = raw.decode("utf-8")
        except ValueError:
            raise _Unavailable from None
        self.blobs[sha] = value
        return value


def _object(value):
    if not isinstance(value, dict):
        raise _Unavailable
    return value


def _array(value):
    if not isinstance(value, list):
        raise _Unavailable
    return value


def _sha(value):
    if not isinstance(value, str) or not _SHA.fullmatch(value):
        raise _Unavailable
    return value


def _count(value):
    if type(value) is not int or value < 0:
        raise _Unavailable
    return value


def _revision(pull, side):
    ref = _object(pull.get(side))
    repo = _object(ref.get("repo"))
    name = repo.get("full_name")
    if repo.get("private") is not False or not isinstance(name, str) or not re.fullmatch(_REPO, name):
        raise _Unavailable
    return name.lower(), _sha(ref.get("sha"))


def _pull_state(pull, repo, number):
    base, head = _revision(pull, "base"), _revision(pull, "head")
    if base[0] != repo or pull.get("number") != number:
        raise _Unavailable
    return base, head, _count(pull.get("changed_files"))


def _safe_path(path: object) -> TypeGuard[str]:
    if not isinstance(path, str) or not path.isprintable() or len(path) > 240 or "\\" in path:
        return False
    parts = path.split("/")
    return len(parts) <= 16 and all(part.casefold() not in {"", ".", "..", ".git"} for part in parts)


class _Tree:
    """Look up regular files without following symlinks or submodules."""

    def __init__(self, github, repo, commit):
        self.github = github
        self.repo = repo
        self.commit = commit
        self.directories = {}

    def directory(self, path):
        if path not in self.directories:
            self.directories[path] = None
            if path:
                parent, _, name = path.rpartition("/")
                entry = self.directory(parent).get(name)
                if entry is None or entry.get("mode") != "040000" or entry.get("type") != "tree":
                    empty = {}
                    self.directories[path] = empty
                    return empty
                sha = _sha(entry.get("sha"))
            else:
                commit = self.github.get(f"{self.repo}/git/commits/{self.commit}", cap=64_000)
                if commit.get("sha") != self.commit:
                    raise _Unavailable
                sha = _sha(_object(commit.get("tree")).get("sha"))
            data = self.github.get(f"{self.repo}/git/trees/{sha}")
            if data.get("sha") != sha or data.get("truncated") is not False:
                raise _Unavailable
            entries = {}
            for item in _array(data.get("tree")):
                entry = _object(item)
                name = entry.get("path")
                if not isinstance(name, str) or "/" in name or name in entries:
                    raise _Unavailable
                entries[name] = entry
            self.directories[path] = entries
        result = self.directories[path]
        if result is None:
            raise _Unavailable
        return result

    def entry(self, path):
        directory, _, name = path.rpartition("/")
        return self.directory(directory).get(name)

    def text(self, path):
        entry = self.entry(path)
        if entry is None:
            return None
        if entry.get("mode") not in ("100644", "100755") or entry.get("type") != "blob":
            raise _Unavailable
        size = _count(entry.get("size"))
        if size > _MAX_BLOB:
            raise _Unavailable
        return self.github.blob(self.repo, _sha(entry.get("sha")), size)


def _intent(pull, commits, limits):
    values = [pull.get("title"), pull.get("body")]
    for commit in commits:
        if isinstance(commit, dict) and isinstance(commit.get("commit"), dict):
            values.append(commit["commit"].get("message"))
        else:
            values.append(None)
            limits.append("Some commit messages were unavailable.")
    result = []
    remaining = _MAX_INTENT
    for value in values:
        if value is None or value == "":
            continue
        if not isinstance(value, str):
            limits.append("Some PR intent was unavailable.")
            continue
        raw = value.encode("utf-8", errors="replace")
        if len(raw) > remaining:
            limits.append("PR intent exceeded the text budget.")
        if remaining:
            result.append(raw[:remaining].decode("utf-8", errors="ignore"))
            remaining -= min(remaining, len(raw))
    return result


def _commits(github, route, comparison, limits):
    total = _count(comparison.get("total_commits"))
    commits = _array(comparison.get("commits"))[:_COMMIT_PAGE]
    for page in range(2, _MAX_COMMIT_PAGES + 1):
        if len(commits) >= total:
            break
        try:
            data = github.get(f"{route}?per_page={_COMMIT_PAGE}&page={page}")
            batch = _array(data.get("commits"))[:_COMMIT_PAGE]
        except _Unavailable:
            break
        if not batch:
            break
        commits.extend(batch)
    if len(commits) != total:
        limits.append(f"Commit intent is partial ({min(len(commits), total)} of {total} commits).")
    return commits[:total]


def _patch(item, path, limits):
    patch = item.get("patch")
    if isinstance(patch, str) and patch.startswith("@@ ") and len(patch.encode("utf-8", errors="replace")) <= _MAX_PATCH:
        lines = patch.split("\n")
        if (sum(line.startswith("+") for line in lines) == item.get("additions")
                and sum(line.startswith("-") for line in lines) == item.get("deletions")):
            try:
                patch.encode("utf-8")
            except UnicodeError:
                pass
            else:
                return patch
    if item.get("changes") != 0 or patch is not None:
        limits.append(f"Patch unavailable, incomplete, or too large for {path}.")
    return ""


def _read(tree, path, limits, *, required):
    try:
        value = tree.text(path)
        if value is not None:
            return value
        if not required:
            return ""
    except _Unavailable:
        pass
    limits.append(f"Source unavailable or outside the text budget at {tree.commit[:12]} for {path}.")
    return ""


def _context(head, changed, limits):
    """Prefer project guidance, likely matching tests, and direct Python neighbors."""
    candidates: dict[str, None] = {"AGENTS.md": None, "README.md": None}
    directories = set()
    for path in changed:
        directory, _, name = path.rpartition("/")
        if directory:
            candidates[f"{directory}/AGENTS.md"] = None
        if name.endswith(".py") and not name.startswith("test_"):
            stem = name[:-3]
            for candidate in (f"tests/test_{stem}.py", f"tests/{stem}_test.py"):
                candidates[candidate] = None
            directories.add(directory)
    for directory in sorted(directories):
        try:
            entries = head.directory(directory)
        except _Unavailable:
            limits.append("Some nearby source context could not be listed.")
            continue
        for name in sorted(entries):
            if name.endswith(".py"):
                path = f"{directory}/{name}" if directory else name
                candidates[path] = None

    files = []
    for path in candidates:
        if path in changed or not _safe_path(path):
            continue
        try:
            entry = head.entry(path)
        except _Unavailable:
            limits.append("Some project guidance, nearby code, or tests could not be located.")
            continue
        if entry is not None:
            files.append(path)
            if len(files) > _MAX_CONTEXT:
                limits.append(f"Nearby source context was capped at {_MAX_CONTEXT} files.")
                break
    return files[:_MAX_CONTEXT]


def _files(github, comparison, base, head, count, limits):
    listing = _array(comparison.get("files"))
    if len(listing) != count or len(listing) > _MAX_CHANGED:
        limits.append(f"Changed file list is partial ({min(len(listing), _MAX_CHANGED)} of {count} listed).")
    files = []
    seen = set()
    excluded = set()
    remaining = _MAX_SOURCE
    for entry in listing[:_MAX_CHANGED]:
        item = _object(entry)
        path = item.get("filename")
        status = item.get("status")
        old_path = item.get("previous_filename") if status == "renamed" else path
        if not _safe_path(path) or not _safe_path(old_path) or path in seen:
            limits.append("Skipped a changed file with an invalid or duplicate path.")
            continue
        seen.add(path)
        excluded.update((path, old_path))
        if status not in ("added", "removed", "modified", "renamed", "changed"):
            limits.append(f"Unsupported change status for {path}.")
            continue
        patch = _patch(item, path, limits)
        after = "" if status == "removed" else _read(head, path, limits, required=True)
        before = "" if status == "added" else _read(base, old_path, limits, required=True)
        size = sum(len(text.encode("utf-8")) for text in (patch, before, after))
        if size > remaining:
            limits.append(f"Snapshot text budget omitted {path}.")
            continue
        remaining -= size
        files.append(SourceFile(path=path, patch=patch, before=before, after=after))
    for path in _context(head, sorted(seen), limits):
        if path in excluded:
            continue
        after = _read(head, path, limits, required=True)
        before = _read(base, path, limits, required=False)
        size = len(after.encode("utf-8")) + len(before.encode("utf-8"))
        if size > remaining:
            limits.append(f"Snapshot text budget omitted {path}.")
            continue
        remaining -= size
        if after or before:
            files.append(SourceFile(path=path, patch="", before=before, after=after))
    return files


def collect(url: str, allowed_repos: AbstractSet[str]) -> Snapshot:
    """Pin PR revisions and collect source without cloning or checking out the repository."""
    match = _PULL_URL.fullmatch(url) if len(url) <= 2_048 else None
    if match is None:
        raise ValueError("Expected an HTTPS GitHub pull request URL.")
    repo, number = match[1].lower(), int(match[2])
    if repo not in {name.lower() for name in allowed_repos}:
        raise ValueError("Repository is outside the configured allowlist.")

    github = _GitHub()
    pull_route = f"{repo}/pulls/{number}"
    limits: list[str] = []
    try:
        pull = github.get(pull_route, cap=_PULL_BYTES)
        state = _pull_state(pull, repo, number)
        (_, tip), (head_repo, head), count = state
        head_ref = head if repo == head_repo else f"{head_repo.split('/')[0]}:{head}"
        route = f"{repo}/compare/{tip}...{head_ref}"
        comparison = github.get(f"{route}?per_page={_COMMIT_PAGE}&page=1")
        if _sha(_object(comparison.get("base_commit")).get("sha")) != tip:
            raise _Unavailable
        base = _sha(_object(comparison.get("merge_base_commit")).get("sha"))
        intent = _intent(pull, _commits(github, route, comparison, limits), limits)
        files = _files(github, comparison, _Tree(github, repo, base), _Tree(github, head_repo, head), count, limits)
        final = _pull_state(github.get(pull_route, cap=_PULL_BYTES, final=True), repo, number)
    except _Unavailable:
        raise RuntimeError("Could not establish a bounded public GitHub pull request snapshot.") from None
    if final != state:
        raise RuntimeError("The pull request changed during collection. Submit it again to review the new revision.")
    return Snapshot(
        url=f"https://github.com/{repo}/pull/{number}", repo=repo, number=number, base=base, head=head,
        intent=intent, files=files, limits=list(dict.fromkeys(limits)),
    )
