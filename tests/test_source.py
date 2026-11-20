import base64
import hashlib
import io
import json
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

from jidoka import source

REPO = "owner/project"
FORK = "contributor/project"
URL = f"https://github.com/{REPO}/pull/3"
PULL = f"/repos/{REPO}/pulls/3"
BASE, TIP, HEAD, MOVED = ("a" * 40, "b" * 40, "c" * 40, "d" * 40)
DIFF = "@@ -1 +1 @@\n-old\n+new"


def digest(raw):
    return hashlib.sha1(raw, usedforsecurity=False).hexdigest()


def pull(head=HEAD, head_repo=FORK, count=1, private=False):
    return {
        "number": 3, "title": "Synthetic change", "body": "Describe the change.",
        "base": {"sha": TIP, "repo": {"full_name": REPO, "private": False}},
        "head": {"sha": head, "repo": {"full_name": head_repo, "private": private}},
        "changed_files": count,
    }


def change(path, status="modified", **options):
    return {
        "filename": path, "status": status, "patch": DIFF,
        "additions": 1, "deletions": 1, "changes": 2, **options,
    }


def compare_path(page=1, head_ref=f"contributor:{HEAD}"):
    return f"/repos/{REPO}/compare/{TIP}...{head_ref}?per_page={source._COMMIT_PAGE}&page={page}"


class GitHubFixture:
    def __init__(self):
        self.responses = {}
        self.requests = []
        self.pulls = iter([pull(), pull()])
        self.opener = Mock()
        self.opener.open.side_effect = self.open

    def open(self, request, timeout):
        url = urlsplit(request.full_url)
        if url.scheme != "https" or url.netloc != "api.github.com" or request.get_method() != "GET":
            raise AssertionError("Unexpected GitHub request")
        if request.has_header("Authorization") or not 0 < timeout <= source._REQUEST_SECONDS:
            raise AssertionError("Unexpected GitHub request options")
        route = url.path + ("?" + url.query if url.query else "")
        self.requests.append(route)
        if route == PULL:
            return io.BytesIO(json.dumps(next(self.pulls)).encode())
        if route not in self.responses:
            raise OSError("Fixture has no such object")
        return io.BytesIO(json.dumps(self.responses[route]).encode())

    def comparison(self, files, messages=("Update the fixture.",), *, total=None, page=1, **kwargs):
        self.responses[compare_path(page, **kwargs)] = {
            "base_commit": {"sha": TIP}, "merge_base_commit": {"sha": BASE},
            "files": files, "total_commits": len(messages) if total is None else total,
            "commits": [{"commit": {"message": message}} for message in messages],
        }

    def revision(self, repo, commit, files):
        prefix = f"/repos/{repo}/git"
        root = {}
        for path, text in files.items():
            *folders, name = path.split("/")
            current = root
            for folder in folders:
                current = current.setdefault(folder, {})
            current[name] = text

        def tree(directory, path=""):
            sha = digest(f"{repo}:{commit}:{path}".encode())
            entries = []
            for name, value in directory.items():
                if isinstance(value, dict):
                    entry = {"mode": "040000", "type": "tree", "sha": tree(value, path + "/" + name)}
                elif isinstance(value, tuple):
                    mode, kind = value
                    entry = {"mode": mode, "type": kind, "sha": MOVED, "size": 1}
                else:
                    raw = value.encode() if isinstance(value, str) else value
                    blob = digest(f"blob {len(raw)}\0".encode() + raw)
                    self.responses[f"{prefix}/blobs/{blob}"] = {
                        "content": base64.b64encode(raw).decode(), "encoding": "base64",
                    }
                    entry = {"mode": "100644", "type": "blob", "sha": blob, "size": len(raw)}
                entries.append({"path": name, **entry})
            self.responses[f"{prefix}/trees/{sha}"] = {"sha": sha, "truncated": False, "tree": entries}
            return sha

        root_sha = tree(root)
        self.responses[f"{prefix}/commits/{commit}"] = {"sha": commit, "tree": {"sha": root_sha}}
        return self.responses[f"{prefix}/trees/{root_sha}"]


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.github = GitHubFixture()
        mock = patch.object(source, "build_opener", return_value=self.github.opener)
        self.build = mock.start()
        self.addCleanup(mock.stop)

    def collect(self, url=URL):
        return source.collect(url, {REPO.upper()})

    def test_rejects_bad_urls_before_network(self):
        for url in (
            "http://github.com/owner/project/pull/3",
            "https://github.com.evil.test/owner/project/pull/3",
            "https://github.com@evil.test/owner/project/pull/3",
            "https://github.com/owner/%2e%2e/pull/3",
            "https://github.com/owner/../pull/3",
            "https://github.com:443/owner/project/pull/3",
            URL + "/files",
            "https://github.com/other/project/pull/3",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.collect(url)
        self.build.assert_not_called()

    def test_rejects_private_or_missing_fork_and_mismatched_base(self):
        wrong_base = pull()
        wrong_base["base"]["repo"]["full_name"] = "other/project"
        missing_fork = pull()
        missing_fork["head"]["repo"] = None
        for metadata in (pull(private=True), wrong_base, missing_fork):
            with self.subTest(metadata=metadata), self.assertRaises(RuntimeError):
                self.github.pulls = iter([metadata])
                self.collect()
        self.assertEqual(self.github.requests, [PULL] * 3)

    def test_pins_fork_and_merge_base_and_collects_nearby_context(self):
        self.github.comparison([change("pkg/task.py")])
        self.github.revision(REPO, BASE, {"pkg/task.py": "old\n", "pkg/caller.py": "call_task()\n"})
        self.github.revision(FORK, HEAD, {
            "pkg/task.py": "new\n", "pkg/caller.py": "call_task()\n",
            "README.md": "Task contract.\n", "tests/test_task.py": "test_task()\n",
        })

        snapshot = self.collect("https://GitHub.com/OWNER/Project/pull/3/#discussion")
        self.assertEqual((snapshot["url"], snapshot["repo"], snapshot["number"]), (URL, REPO, 3))
        self.assertEqual((snapshot["base"], snapshot["head"]), (BASE, HEAD))
        self.assertEqual(snapshot["intent"], ["Synthetic change", "Describe the change.", "Update the fixture."])
        files = {file["path"]: file for file in snapshot["files"]}
        self.assertEqual(files["pkg/task.py"], {"path": "pkg/task.py", "patch": DIFF, "before": "old\n", "after": "new\n"})
        self.assertEqual(files["pkg/caller.py"]["before"], "call_task()\n")
        self.assertEqual(files["tests/test_task.py"]["after"], "test_task()\n")
        self.assertEqual(files["README.md"]["patch"], "")
        self.assertEqual(snapshot["limits"], [])
        self.assertEqual(self.github.requests[-1], PULL)
        self.assertIn(f"/repos/{REPO}/git/commits/{BASE}", self.github.requests)
        self.assertIn(f"/repos/{FORK}/git/commits/{HEAD}", self.github.requests)
        self.assertNotIn(f"/repos/{REPO}/git/commits/{TIP}", self.github.requests)

    def test_rejects_pr_movement_even_after_source_reads(self):
        self.github.pulls = iter([pull(), pull(head=MOVED)])
        self.github.comparison([change("task.py")])
        self.github.revision(REPO, BASE, {"task.py": "old\n"})
        self.github.revision(FORK, HEAD, {"task.py": "new\n"})
        with self.assertRaisesRegex(RuntimeError, "changed during collection"):
            self.collect()
        self.assertEqual(self.github.requests[-1], PULL)
        self.assertTrue(any("/blobs/" in route for route in self.github.requests))
        self.assertTrue(all(MOVED not in route for route in self.github.requests))

    def test_rename_add_remove_and_anomalous_paths(self):
        entries = [
            change("renamed.py", "renamed", previous_filename="old.py", patch=None, changes=0),
            change("gone.py", "removed", patch="@@ -1 +0,0 @@\n-old", additions=0, changes=1),
            change("added.py", "added", patch="@@ -0,0 +1 @@\n+new", deletions=0, changes=1),
            change("../escape.py"), change("/absolute.py"), change(r"pkg\escape.py"),
            change("pkg/.GiT/stuff.py"), change("wrong.py", "renamed", previous_filename="../x.py"),
            change("added.py"), change("link.py", patch=None, changes=0),
            change("binary.py", patch=None, changes=2),
        ]
        self.github.pulls = iter([pull(count=len(entries))] * 2)
        self.github.comparison(entries)
        self.github.revision(REPO, BASE, {"old.py": "same\n", "gone.py": "old\n", "binary.py": b"\xff"})
        self.github.revision(FORK, HEAD, {
            "renamed.py": "same\n", "added.py": "new\n", "link.py": ("120000", "blob"), "binary.py": b"\0",
        })
        snapshot = self.collect()
        files = {file["path"]: file for file in snapshot["files"]}
        self.assertEqual(set(files), {"renamed.py", "gone.py", "added.py", "link.py", "binary.py"})
        self.assertEqual(files["renamed.py"]["before"], "same\n")
        self.assertEqual(files["gone.py"]["after"], "")
        self.assertEqual(files["added.py"]["before"], "")
        self.assertEqual(files["link.py"]["after"], "")
        self.assertEqual(files["binary.py"]["after"], "")
        self.assertTrue(any("invalid or duplicate path" in limit for limit in snapshot["limits"]))
        self.assertTrue(any("Source unavailable" in limit and "link.py" in limit for limit in snapshot["limits"]))
        self.assertTrue(all("/blobs/" + MOVED not in path for path in self.github.requests))

    def test_commit_pagination_and_truncation(self):
        with patch.multiple(source, _COMMIT_PAGE=2, _MAX_COMMIT_PAGES=2, _MAX_CHANGED=1):
            self.github.pulls = iter([pull(head_repo=REPO, count=301)] * 2)
            self.github.comparison([change("file.py"), change("omitted.py")], ("a", "b"), total=5, head_ref=HEAD)
            self.github.comparison([], ("c", "d"), total=5, page=2, head_ref=HEAD)
            self.github.revision(REPO, BASE, {"file.py": "old\n"})
            self.github.revision(REPO, HEAD, {"file.py": "new\n"})
            snapshot = self.collect()
            self.assertIn(compare_path(page=2, head_ref=HEAD), self.github.requests)
            self.assertNotIn(compare_path(page=3, head_ref=HEAD), self.github.requests)
        self.assertEqual(snapshot["intent"][-4:], ["a", "b", "c", "d"])
        self.assertTrue(any("4 of 5 commits" in limit for limit in snapshot["limits"]))
        self.assertTrue(any("1 of 301" in limit for limit in snapshot["limits"]))

    def test_truncated_tree_or_patch_cannot_silently_look_complete(self):
        self.github.comparison([change("file.py", additions=2)])
        self.github.revision(REPO, BASE, {"file.py": "old\n"})
        head_tree = self.github.revision(FORK, HEAD, {"file.py": "new\n"})
        head_tree["truncated"] = True
        snapshot = self.collect()
        self.assertEqual(snapshot["files"][0]["after"], "")
        self.assertEqual(snapshot["files"][0]["patch"], "")
        self.assertTrue(any("Patch unavailable" in limit for limit in snapshot["limits"]))
        self.assertTrue(any("Source unavailable" in limit for limit in snapshot["limits"]))

    def test_absent_context_directory_is_not_a_fetch_failure(self):
        self.github.comparison([change("file.py")])
        self.github.revision(REPO, BASE, {"file.py": "old\n"})
        self.github.revision(FORK, HEAD, {"file.py": "new\n"})
        self.assertEqual(self.collect()["limits"], [])

    def test_request_budget_reserves_a_final_pr_check(self):
        self.github.comparison([change("file.py")])
        self.github.revision(REPO, BASE, {"file.py": "old\n"})
        self.github.revision(FORK, HEAD, {"file.py": "new\n"})
        with patch.object(source, "_MAX_REQUESTS", 4):
            snapshot = self.collect()
        self.assertEqual(len(self.github.requests), 4)
        self.assertEqual(self.github.requests[-1], PULL)
        self.assertTrue(snapshot["limits"])

    def test_blob_id_must_match_the_pinned_tree(self):
        self.github.comparison([change("file.py")])
        self.github.revision(REPO, BASE, {"file.py": "old\n"})
        self.github.revision(FORK, HEAD, {"file.py": "new\n"})
        path = next(path for path in self.github.responses if path.startswith(f"/repos/{FORK}/git/blobs"))
        self.github.responses[path]["content"] = base64.b64encode(b"bad\n").decode()
        snapshot = self.collect()
        self.assertEqual(snapshot["files"][0]["after"], "")
        self.assertTrue(any("Source unavailable" in limit for limit in snapshot["limits"]))
