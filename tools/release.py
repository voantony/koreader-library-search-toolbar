#!/usr/bin/env python3
"""Build and publish a Library GUI release.

Dry-run (no tag, no GitHub release):

    python3 tools/release.py

Publish (GitHub Actions, on main):

    python3 tools/release.py --publish

The version is the latest vX.Y.Z tag, with the patch number bumped. A merged
pull request that changed library.koplugin/ can override that with a label:
release:minor, release:major, or release:skip. Skip wins, then major, then
minor. Notes are plain-English bullets from those pull requests. The spec
suite is run by the workflow before this script, and this script refuses to
publish when library.koplugin/ is unchanged since that tag or the release
already exists.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

SEMVER = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
PLUGIN = "library.koplugin"
SKIP_LABEL = "release:skip"
BUMP_LABELS = ("release:major", "release:minor")

INSTALL = (
    "Download `library-gui-{version}.zip`, unzip it, and copy the "
    "`library.koplugin` folder into `koreader/plugins/` on your device, "
    "then restart KOReader."
)

PINNED_DOWNLOAD = re.compile(
    r"releases/download/v\d+\.\d+\.\d+/library-gui-\d+\.\d+\.\d+\.zip"
    r"|releases/latest/download/library-gui-\d+\.\d+\.\d+\.zip"
)

SKIP_HEADING = re.compile(
    r"(tests?|specs?|emulator|screenshot|how to run|manual fix|"
    r"cause|problem|\bbefore\b|judgement|^\s*how\b|numbers|measuring|"
    r"\bmethod\b|benchmark)",
    re.I,
)
META = re.compile(
    r"(don'?t merge|do not merge|\bnot merged\b|"
    r"\bdraft\b|screenshot|these shots|probe log|"
    r"\bcloses #\d|\bfixes #\d|\bresolves #\d|"
    r"cursor\.com|open in cursor|open in web|show artifacts|"
    r"co-authored-by:)",
    re.I,
)
IMPL = re.compile(
    r"(\.lua\b|\bMakefile\b|staging script|\bluajit\b|\bspec/|\btools/|"
    r"\.sh\b|pure logic|pure module|no code copied|BatchedUpdate\b|"
    r"added to the Makefile|\bpassed,|\b\d+ specs?\b|"
    r"\bsetDirty\b|canEchoDirect|InputText|forceRePaint|\b\d+\s*ms\b)",
    re.I,
)
HTML_TAG = re.compile(
    r"</?(?:sub|div|picture|source|img|a|br|p|span|table|thead|tbody|tfoot|"
    r"tr|td|th|ul|ol|li|em|strong|code|pre|blockquote|hr|sup|small|h[1-6])\b[^>]*>",
    re.I,
)
EMOJI = re.compile(
    "["
    "\U0001F1E6-\U0001F1FF"
    "\U0001F300-\U0001FAFF"
    "\U00002700-\U000027BF"
    "\U0000FE00-\U0000FE0F"
    "\U0000200D"
    "\U00002B50"
    "]+"
)
PR_MERGE = re.compile(r"Merge pull request #(\d+)\b")
PR_SQUASH = re.compile(r"\(#(\d+)\)\s*$")


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def git_out(args: list[str]) -> str:
    return run(["git", *args]).stdout


def repo_root() -> Path:
    return Path(git_out(["rev-parse", "--show-toplevel"]).strip())


def rev_parse(obj: str) -> str:
    return git_out(["rev-parse", f"{obj}^{{commit}}"]).strip()


def semver_key(tag: str) -> tuple[int, int, int]:
    match = SEMVER.match(tag)
    if not match:
        raise ValueError(tag)
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def latest_tag(head: str) -> str | None:
    raw = git_out(["tag", "--merged", head, "--list", "v*"])
    best: str | None = None
    best_key: tuple[int, int, int] | None = None
    for line in raw.splitlines():
        tag = line.strip()
        if not SEMVER.match(tag):
            continue
        key = semver_key(tag)
        if best_key is None or key > best_key:
            best, best_key = tag, key
    return best


def tag_points_at(tag: str, rev: str) -> bool:
    try:
        return rev_parse(tag) == rev
    except subprocess.CalledProcessError:
        return False


def plugin_changed(tag: str, rev: str) -> bool:
    proc = run(["git", "diff", "--quiet", tag, rev, "--", PLUGIN], check=False)
    if proc.returncode == 0:
        return False
    if proc.returncode == 1:
        return True
    raise SystemExit(proc.stderr.strip() or f"git diff failed ({proc.returncode})")


def touches_plugin(paths: list[str]) -> bool:
    prefix = PLUGIN + "/"
    return any(path == PLUGIN or path.startswith(prefix) for path in paths)


def commit_files(sha: str) -> list[str]:
    return git_out(["diff", "--name-only", f"{sha}^", sha]).splitlines()


def pr_number(subject: str) -> int | None:
    match = PR_MERGE.search(subject) or PR_SQUASH.search(subject)
    return int(match.group(1)) if match else None


def fetch_pr(number: int) -> tuple[str, str, set[str]]:
    proc = run(
        ["gh", "pr", "view", str(number), "--json", "title,body,labels"],
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(f"gh pr view {number} failed:\n{proc.stderr.strip()}")
    data = json.loads(proc.stdout)
    labels = {item["name"].lower() for item in data.get("labels") or []}
    return (data.get("title") or "").strip(), data.get("body") or "", labels


def strip_pr_suffix(title: str) -> str:
    return PR_SQUASH.sub("", title).strip()


def strip_trailers(body: str) -> str:
    kept: list[str] = []
    for line in body.splitlines():
        if line.strip() == "---------":
            break
        if line.lower().startswith("co-authored-by:"):
            continue
        kept.append(line)
    return "\n".join(kept).strip()


def choose_bump(labels: set[str]) -> str:
    if SKIP_LABEL in labels:
        return "skip"
    if "release:major" in labels:
        return "major"
    if "release:minor" in labels:
        return "minor"
    return "patch"


def bump_version(version: str, kind: str) -> str:
    major, minor, patch = (int(part) for part in version.split("."))
    if kind == "major":
        return f"{major + 1}.0.0"
    if kind == "minor":
        return f"{major}.{minor + 1}.0"
    if kind == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError(kind)


def plan(plugin_diff: bool, head_is_release: bool, labels: set[str]) -> str:
    """What to do for this commit.

    already: this commit is already the latest release.
    unchanged: later commits did not touch the plugin.
    skip: a merged pull request asked not to publish.
    release: publish the next version.
    """
    if head_is_release and not plugin_diff:
        return "already"
    if not plugin_diff:
        return "unchanged"
    if choose_bump(labels) == "skip":
        return "skip"
    return "release"


def clean_body(body: str) -> str:
    match = re.search(
        r"<!--\s*CURSOR_AGENT_PR_BODY_BEGIN\s*-->(.*)<!--\s*CURSOR_AGENT_PR_BODY_END\s*-->",
        body,
        re.S,
    )
    if match:
        body = match.group(1)
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    body = html.unescape(body)
    body = re.sub(
        r"`<koreader dir>/library_timing\.log`",
        "`library_timing.log` in the KOReader folder",
        body,
        flags=re.I,
    )
    body = re.sub(r"<koreader dir>", "the KOReader folder", body, flags=re.I)
    body = re.sub(r"<sub>.*?</sub>", "", body, flags=re.S | re.I)
    body = re.sub(r"<picture\b.*?</picture>", "", body, flags=re.S | re.I)
    body = re.sub(r"<img\b[^>]*>", "", body, flags=re.I)
    body = re.sub(r"<a\b[^>]*>(.*?)</a>", r"\1", body, flags=re.S | re.I)
    body = HTML_TAG.sub("", body)
    body = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", body)
    body = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", body)
    body = EMOJI.sub("", body)
    body = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"\1", body)
    return body.replace("\r\n", "\n")


def parse_sections(text: str) -> list[tuple[str, list[str]]]:
    sections: list[tuple[str, list[str]]] = [("", [])]
    for line in text.splitlines():
        heading = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if heading:
            sections.append((heading.group(1).strip("* ").strip(), []))
            continue
        bold = re.match(r"^\*\*([^*]{1,60})\*\*\s*(.*)$", line)
        if bold:
            rest = bold.group(2).lstrip(":").strip()
            sections.append((bold.group(1).strip().rstrip(":").strip(), []))
            if rest:
                sections[-1][1].append(rest)
            continue
        sections[-1][1].append(line)
    return sections


def tidy(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"^Item \d+:\s*", "", text, flags=re.I)
    text = re.sub(r"^\((.*)\)$", r"\1", text)
    return text.strip(" -")


def sentences(text: str) -> list[str]:
    text = tidy(text)
    if not text:
        return []
    parts = re.split(r"(?<=[.!])\s+(?=[A-Z\"“*`])", text)
    return [part.strip() for part in parts if part.strip()]


def cap_first(text: str) -> str:
    index = 0
    while index < len(text) and text[index] in "*_`":
        index += 1
    if index < len(text) and text[index].islower():
        text = text[:index] + text[index].upper() + text[index + 1 :]
    return text


def finish(text: str) -> str:
    text = cap_first(tidy(text))
    if not text:
        return ""
    if text.endswith("**"):
        return text[:-2].rstrip() + ".**"
    if text[-1] not in ".!?":
        return text + "."
    return text


def word_set(text: str) -> set[str]:
    plain = re.sub(r"[^a-z0-9\s]", " ", text.lower())
    return {word for word in plain.split() if len(word) > 3}


def overlaps_title(sentence: str, title: str) -> bool:
    words = word_set(sentence)
    title_words = word_set(title)
    if not words or not title_words:
        return False
    return len(words & title_words) / len(words) >= 0.7


def noisy(text: str) -> bool:
    return bool(META.search(text) or IMPL.search(text) or re.search(r"https?://", text))


def blocks(lines: list[str]) -> list[tuple[str, str]]:
    items: list[tuple[str, str]] = []
    buf: list[str] = []
    mode: str | None = None

    def flush() -> None:
        nonlocal buf, mode
        if buf and mode:
            items.append((mode, " ".join(buf)))
        buf = []
        mode = None

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("|") or stripped in {"---", "***"}:
            flush()
            continue
        marker = re.match(r"^\s*(?:[-*]|\d+\.)\s+(.*)$", line)
        if marker:
            flush()
            mode = "li"
            buf = [marker.group(1).strip()]
            continue
        if mode == "li" and (line.startswith("  ") or line.startswith("\t")):
            buf.append(stripped)
            continue
        if mode == "li":
            flush()
        mode = "p"
        buf.append(stripped)
    flush()
    return items


def clean_aside(text: str) -> str:
    """Turn a heading leftover like '(a floor: it never ...):' into a sentence."""
    text = text.strip().rstrip(":").strip()
    wrapped = re.match(r"^\((.*)\)\s*$", text)
    if wrapped:
        text = wrapped.group(1).strip()
    short = re.match(r"^[a-z][^:]{0,40}:\s+(.+)$", text)
    if short and len(short.group(1)) > 20:
        text = short.group(1).strip()
    return text


def split_lead(text: str) -> tuple[str, str, str]:
    """Bold label, parenthetical aside, and the rest of a list item."""
    text = tidy(text)
    lead = ""
    match = re.match(r"^\*\*([^*]+)\*\*\s*(.*)$", text)
    if match:
        lead = match.group(1).strip().rstrip(":").strip()
        text = match.group(2).strip()
    aside = ""
    wrapped = re.match(r"^\(([^)]*)\)\s*:?\s*(.*)$", text)
    if wrapped:
        aside, text = wrapped.group(1).strip(), wrapped.group(2).strip()
    return lead, aside, text


def default_note(aside: str) -> str:
    if re.search(r"\boff by default\b", aside, re.I):
        return "off by default"
    if re.search(r"\bon by default\b", aside, re.I):
        return "on by default"
    return ""


def pick_detail(text: str) -> str:
    clean = [sentence for sentence in sentences(text) if not noisy(sentence) and len(tidy(sentence)) >= 8]
    for sentence in clean:
        if re.search(r"\bnow\b", sentence, re.I):
            return sentence
    return clean[0] if clean else ""


def list_item(text: str) -> str:
    lead, aside, rest = split_lead(text)
    lead = re.sub(r"\s*\(for testing\)", "", lead, flags=re.I).strip()
    # A bold lead that is already a sentence is the note. The rest is often
    # the implementation, and a later leftover sentence reads like a contradiction.
    if lead.endswith((".", "!", "?")):
        return finish(lead)
    detail = pick_detail(rest)
    note = default_note(re.sub(r"\*+", "", aside))
    if lead and detail:
        if detail[0].isupper() and not detail.startswith("**") and (len(detail) == 1 or detail[1].islower()):
            detail = detail[0].lower() + detail[1:]
        if note and note not in lead.lower():
            return finish(f"{lead} ({note}): {detail}")
        return finish(f"{lead}: {detail}")
    if detail and not lead:
        return finish(detail)
    if lead:
        if note and note not in lead.lower():
            return finish(f"{lead} ({note})")
        return finish(lead)
    return ""


def summarize(title: str, body: str) -> tuple[str, list[str]]:
    prose: list[str] = []
    bullets: list[str] = []
    paragraph_index = 0
    for heading, lines in parse_sections(clean_body(body)):
        if heading and SKIP_HEADING.search(heading):
            continue
        for kind, text in blocks(lines):
            if kind == "p":
                text = clean_aside(text)
                useful = [
                    sentence
                    for sentence in sentences(text)
                    if len(sentence) >= 15 and not noisy(sentence) and not overlaps_title(sentence, title)
                ]
                take = useful[:3] if paragraph_index == 0 else useful[:1]
                for sentence in take:
                    if len(prose) >= 4:
                        break
                    done = finish(sentence)
                    if done:
                        prose.append(done)
                if useful:
                    paragraph_index += 1
                continue
            item = list_item(text)
            if item and not noisy(item) and len(bullets) < 6:
                bullets.append(item)
    return " ".join(prose), bullets


def format_note(title: str, prose: str, bullets: list[str], number: int | None) -> str:
    title = strip_pr_suffix(title).rstrip(".").strip()
    ref = f" (#{number})" if number else ""
    head = f"- **{title}.**"
    if prose:
        head += " " + prose
    lines = [head if bullets else head + ref]
    for index, bullet in enumerate(bullets):
        suffix = ref if index == len(bullets) - 1 else ""
        lines.append(f"  - {bullet}{suffix}")
    if not prose and not bullets:
        lines = [f"- **{title}.**{ref}"]
    return "\n".join(lines)


def render_notes(version: str, notes: list[str]) -> str:
    if not VERSION.match(version):
        raise SystemExit(f"refusing version {version!r}")
    body = "\n".join(notes) if notes else "- Updates to the Library plugin."
    return f"## What's new\n\n{body}\n\n## Install\n\n{INSTALL.format(version=version)}\n"


class Change:
    def __init__(self, title: str, body: str, number: int | None, labels: set[str]):
        self.title = title
        self.body = body
        self.number = number
        self.labels = labels


def changes_since(tag: str, rev: str) -> list[Change]:
    hashes = git_out(
        ["log", "--first-parent", "--reverse", f"{tag}..{rev}", "--pretty=format:%H"]
    ).split()
    found: list[Change] = []
    seen: set[int] = set()
    for sha in hashes:
        subject = git_out(["log", "-1", "--pretty=format:%s", sha]).strip()
        if not touches_plugin(commit_files(sha)):
            print(f"skip {sha[:7]} {subject}", file=sys.stderr)
            continue
        number = pr_number(subject)
        if number is not None:
            if number in seen:
                continue
            seen.add(number)
            title, body, labels = fetch_pr(number)
            title = title or strip_pr_suffix(subject)
            print(f"include #{number} {title}", file=sys.stderr)
            found.append(Change(title, body, number, labels))
            continue
        body = strip_trailers(git_out(["log", "-1", "--pretty=format:%b", sha]))
        print(f"include {sha[:7]} {subject}", file=sys.stderr)
        found.append(Change(subject, body, None, set()))
    return found


def notes_for(changes: list[Change]) -> list[str]:
    rendered: list[str] = []
    for change in changes:
        prose, bullets = summarize(change.title, change.body)
        if not prose and not bullets:
            commit_prose, commit_bullets = summarize(change.title, "")
            prose, bullets = commit_prose, commit_bullets
        rendered.append(format_note(change.title, prose, bullets, change.number))
    return rendered


def makefile_files() -> list[str]:
    text = (repo_root() / "Makefile").read_text(encoding="utf-8")
    captured: list[str] = []
    collecting = False
    for line in text.splitlines():
        if not collecting:
            if not re.match(r"^FILES\s*:=", line):
                continue
            collecting = True
            line = re.sub(r"^FILES\s*:=", "", line)
        continued = line.rstrip().endswith("\\")
        captured.append(line.rstrip("\\"))
        if not continued:
            break
    files = " ".join(captured).split()
    if not files:
        raise SystemExit("Makefile has no FILES list")
    return files


def check_plugin_files() -> list[str]:
    listed = makefile_files()
    root = repo_root() / PLUGIN
    on_disk = sorted(
        path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()
    )
    if set(on_disk) != set(listed):
        missing = sorted(set(on_disk) - set(listed))
        extra = sorted(set(listed) - set(on_disk))
        raise SystemExit(
            "Makefile FILES does not match library.koplugin/.\n"
            f"on disk only: {missing or '-'}\n"
            f"Makefile only: {extra or '-'}"
        )
    return listed


def check_readme() -> None:
    readme = (repo_root() / "README.md").read_text(encoding="utf-8")
    if PINNED_DOWNLOAD.search(readme):
        raise SystemExit(
            "README pins a versioned library-gui download URL. "
            "Link to the latest release instead, so a release does not need another commit."
        )
    if "releases/latest" not in readme:
        raise SystemExit("README should link to the latest release.")


def build_zip(version: str, listed: list[str]) -> tuple[Path, Path]:
    root = repo_root()
    proc = subprocess.run(
        ["make", "zip", f"VERSION={version}"],
        cwd=root,
        check=False,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"make zip failed ({proc.returncode})\n{proc.stdout}\n{proc.stderr}")
    zip_path = root / "dist" / f"library-gui-{version}.zip"
    if not zip_path.is_file():
        raise SystemExit(f"missing {zip_path}")
    allowed = {f"{PLUGIN}/{name}" for name in listed}
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
    bad = []
    seen: set[str] = set()
    for name in names:
        if name.endswith("/"):
            if name.rstrip("/") != PLUGIN:
                bad.append(name)
            continue
        seen.add(name)
        if name not in allowed:
            bad.append(name)
    missing = sorted(allowed - seen)
    if bad or missing:
        raise SystemExit(f"zip contents are wrong.\nbad: {bad}\nmissing: {missing}")
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    sha_path = zip_path.with_name(zip_path.name + ".sha256")
    sha_path.write_text(f"{digest}  {zip_path.name}\n", encoding="utf-8")
    return zip_path, sha_path


def release_view(tag: str) -> dict | None:
    proc = run(["gh", "release", "view", tag, "--json", "assets,isDraft,body,name"], check=False)
    if proc.returncode != 0:
        return None
    return json.loads(proc.stdout)


def publish(tag: str, rev: str, notes_path: Path, assets: list[Path]) -> None:
    ref = os.environ.get("GITHUB_REF", "")
    if ref and ref != "refs/heads/main":
        raise SystemExit(f"refusing to publish from {ref}")
    existing = tag_points_at(tag, rev)
    other = None
    if not existing:
        proc = run(["git", "rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}"], check=False)
        if proc.returncode == 0:
            other = proc.stdout.strip()
    if other and other != rev:
        raise SystemExit(f"{tag} already points at {other}, not {rev}")
    view = release_view(tag)
    if view is None:
        proc = subprocess.run(
            [
                "gh", "release", "create", tag,
                *[str(path) for path in assets],
                "--title", tag,
                "--notes-file", str(notes_path),
                "--latest",
                "--target", rev,
            ],
            check=False,
        )
        if proc.returncode != 0:
            raise SystemExit(f"gh release create failed ({proc.returncode})")
        print(f"published {tag}", file=sys.stderr)
        return
    have = {asset["name"] for asset in view.get("assets") or []}
    missing = [str(path) for path in assets if path.name not in have]
    if missing:
        proc = subprocess.run(["gh", "release", "upload", tag, *missing, "--clobber"], check=False)
        if proc.returncode != 0:
            raise SystemExit(f"gh release upload failed ({proc.returncode})")
    body = view.get("body") or ""
    edit = ["gh", "release", "edit", tag, "--latest", "--title", tag]
    changed = False
    if view.get("isDraft"):
        edit.append("--draft=false")
        changed = True
    if "## What's new" not in body:
        edit.extend(["--notes-file", str(notes_path)])
        changed = True
    if changed:
        proc = subprocess.run(edit, check=False)
        if proc.returncode != 0:
            raise SystemExit(f"gh release edit failed ({proc.returncode})")
    if not missing and not changed:
        print(f"{tag} already published", file=sys.stderr)
    else:
        print(f"completed {tag}", file=sys.stderr)


def ensure_tags() -> None:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        run(["git", "fetch", "origin", "--tags", "--force", "--quiet"])


def write_notes(version: str, rendered: list[str]) -> Path:
    path = repo_root() / "dist" / "RELEASE_NOTES.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_notes(version, rendered), encoding="utf-8")
    return path


def previous_release(head: str, current: str) -> str | None:
    raw = git_out(["tag", "--merged", head, "--list", "v*"])
    best: str | None = None
    best_key: tuple[int, int, int] | None = None
    for line in raw.splitlines():
        tag = line.strip()
        if tag == current or not SEMVER.match(tag):
            continue
        key = semver_key(tag)
        if best_key is None or key > best_key:
            best, best_key = tag, key
    return best


def self_check() -> None:
    assert bump_version("0.3.8", "patch") == "0.3.9"
    assert bump_version("0.3.8", "minor") == "0.4.0"
    assert bump_version("0.3.8", "major") == "1.0.0"
    assert bump_version("0.3.10", "patch") == "0.3.11"
    assert semver_key("v0.3.10") > semver_key("v0.3.9")
    assert choose_bump(set()) == "patch"
    assert choose_bump({"release:minor"}) == "minor"
    assert choose_bump({"release:minor", "release:major"}) == "major"
    assert choose_bump({"release:major", "release:skip"}) == "skip"
    assert plan(False, False, set()) == "unchanged"
    assert plan(False, True, set()) == "already"
    assert plan(True, False, {"release:skip"}) == "skip"
    assert plan(True, False, {"release:minor"}) == "release"
    assert touches_plugin(["README.md", "tools/emulator/shoot.sh"]) is False
    assert touches_plugin(["library.koplugin/main.lua"]) is True
    assert pr_number("Merge pull request #28 from voantony/feature/keyboard-speed") == 28
    assert pr_number("Long-press the page arrows (#30)") == 30
    assert pr_number("README: point download link to v0.3.8") is None
    prose, bullets = summarize(
        "Long-press the page arrows",
        """
<!-- CURSOR_AGENT_PR_BODY_BEGIN -->
In the Library footer, a tap on the previous or next arrow still moves one page. Hold the next arrow to jump to the last page.

Tapping the page number opens KOReader's number box, titled "Go to page". Type a page and press Go.

These shots are from the emulator. https://example.com/shot.png
Closes #29
<!-- CURSOR_AGENT_PR_BODY_END -->
<div>emoji 🎉</div>
""",
    )
    joined = prose + " ".join(bullets)
    assert "Go to page" in joined
    assert "🎉" not in joined
    assert "http" not in joined
    assert "CURSOR" not in joined
    assert "Closes" not in joined
    note = format_note("Long-press the page arrows", prose, bullets, 30)
    assert "(#30)" in note
    typing = list_item(
        "**Typing repaints only the text box.** In every other case it takes KOReader's normal path."
    )
    assert typing == "Typing repaints only the text box."
    assert "every other case" not in typing
    rendered = render_notes("0.3.9", [note])
    assert rendered.startswith("## What's new\n")
    assert "## Install\n" in rendered
    assert INSTALL.format(version="0.3.9") in rendered
    assert "🎉" not in rendered
    check_plugin_files()
    print("self-check ok", file=sys.stderr)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Build or publish a Library GUI release.")
    parser.add_argument("--publish", action="store_true", help="create the GitHub release")
    parser.add_argument("--rev", help="commit to describe (dry-run only)")
    parser.add_argument("--self-check", action="store_true", help="check bump, notes, and file list")
    args = parser.parse_args(argv)
    os.chdir(repo_root())
    if args.self_check:
        self_check()
        return 0
    if args.publish and args.rev:
        raise SystemExit("--publish cannot be combined with --rev")
    self_check()
    check_readme()
    ensure_tags()
    head = rev_parse("HEAD")
    rev = rev_parse(args.rev) if args.rev else head
    tag = latest_tag(rev)
    if not tag:
        raise SystemExit("no vX.Y.Z tag reachable from this commit; refusing to guess a version")
    changed = plugin_changed(tag, rev)
    on_release = tag_points_at(tag, rev)
    if not changed:
        if on_release:
            print(f"{tag} already tags {rev[:7]}; not publishing another release")
            if args.publish:
                repair_existing(tag, rev)
            return 0
        print(f"no changes under {PLUGIN}/ since {tag}; skipping release")
        return 0
    found = changes_since(tag, rev)
    if not found:
        raise SystemExit(f"{PLUGIN}/ differs from {tag} but no commit on main explains it")
    labels = set().union(*(change.labels for change in found))
    decision = plan(True, False, labels)
    if decision == "skip":
        print(f"{SKIP_LABEL} is set; skipping release")
        return 0
    kind = choose_bump(labels)
    version = bump_version(tag[1:], kind)
    new_tag = f"v{version}"
    print(f"version: {version}", file=sys.stderr)
    print(f"tag: {new_tag}", file=sys.stderr)
    print(f"bump: {kind} from {tag}", file=sys.stderr)
    existing = tag_points_at(new_tag, rev)
    pointed = None
    proc = run(["git", "rev-parse", "--verify", "--quiet", f"{new_tag}^{{commit}}"], check=False)
    if proc.returncode == 0:
        pointed = proc.stdout.strip()
    if pointed and pointed != rev:
        raise SystemExit(f"{new_tag} already points at {pointed}, not {rev}")
    if rev != head:
        rendered = notes_for(found)
        sys.stdout.write(render_notes(version, rendered))
        print(f"(not building a zip: --rev is not HEAD)", file=sys.stderr)
        return 0
    listed = check_plugin_files()
    zip_path, sha_path = build_zip(version, listed)
    notes_path = write_notes(version, notes_for(found))
    sys.stdout.write(notes_path.read_text(encoding="utf-8"))
    print(f"zip: {zip_path}")
    print(f"sha256: {sha_path.read_text(encoding='utf-8').split()[0]}")
    with zipfile.ZipFile(zip_path) as archive:
        print("zip files:")
        for name in archive.namelist():
            print(name)
    if not args.publish:
        print(f"dry-run: would publish {new_tag}", file=sys.stderr)
        return 0
    if existing or pointed == rev:
        repair_existing(new_tag, rev)
        return 0
    publish(new_tag, rev, notes_path, [zip_path, sha_path])
    return 0


def repair_existing(tag: str, rev: str) -> None:
    """Upload anything missing from a release that already tags this commit."""
    view = release_view(tag)
    version = tag[1:]
    if not VERSION.match(version):
        raise SystemExit(f"refusing to repair {tag}")
    previous = previous_release(rev, tag)
    if previous is None:
        raise SystemExit(f"no previous tag before {tag}")
    listed = check_plugin_files()
    zip_path, sha_path = build_zip(version, listed)
    notes_path = write_notes(version, notes_for(changes_since(previous, rev)))
    if view is None:
        publish(tag, rev, notes_path, [zip_path, sha_path])
        return
    have = {asset["name"] for asset in view.get("assets") or []}
    if zip_path.name in have and sha_path.name in have and not view.get("isDraft"):
        print(f"{tag} already has its zip and checksum")
        return
    publish(tag, rev, notes_path, [zip_path, sha_path])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise SystemExit(detail or f"command failed: {exc.cmd}")
