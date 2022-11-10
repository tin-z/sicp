#!/usr/bin/env python3
# Copyright 2022 Mitchell Kember. Subject to the MIT License.

from pathlib import Path
import sys
from html.parser import HTMLParser
from collections import defaultdict
from urllib.parse import urlparse, ParseResult as Url, unquote, urldefrag
import requests
import multiprocessing


class IdParser(HTMLParser):
    @staticmethod
    def parse(html):
        parser = IdParser()
        parser.feed(html)
        return parser.ids

    def __init__(self):
        super().__init__()
        self.ids = set()

    def handle_starttag(self, tag, attrs) -> None:
        if id := next((val for key, val in attrs if key == "id"), None):
            self.ids.add(id)
        # The SICP website uses <a name="..."> anchors.
        if tag == "a":
            if name := next((val for key, val in attrs if key == "name"), None):
                self.ids.add(name)


class HrefParser(HTMLParser):
    @staticmethod
    def parse(html):
        parser = HrefParser()
        parser.feed(html)
        return parser.hrefs

    def __init__(self):
        super().__init__()
        self.hrefs = set()

    def handle_starttag(self, tag, attrs) -> None:
        if tag == "a":
            self.hrefs.add(next(val for key, val in attrs if key == "href"))


# This can't be a lambda because that prevents pickling PageInfo.
def defaultdict_set():
    return defaultdict(set)


class PageInfo:
    def __init__(self):
        # Map from paths to IDs.
        self.internal_ids: dict[Path, set[str]] = {}
        # Map from paths to (relative path, fragment) links.
        self.internal_links: dict[Path, list[tuple[str, str]]] = defaultdict(list)
        # Map from URLs to fragments to paths where they are linked from.
        self.external_urls: dict[str, dict[str, set[Path]]] = defaultdict(
            defaultdict_set
        )

    def update(self, other):
        self.internal_ids.update(other.internal_ids)
        self.internal_links.update(other.internal_links)
        self.external_urls.update(other.external_urls)


def normalize_path(path: Path | str) -> Path:
    return Path(path).resolve().relative_to(Path.cwd())


def parse_page(path):
    info = PageInfo()
    path = normalize_path(path)
    with open(path) as f:
        html = f.read()
    info.internal_ids[path] = IdParser.parse(html)
    for href in HrefParser.parse(html):
        url = urlparse(href)
        if url.scheme in ("http", "https"):
            url_no_frag, fragment = urldefrag(href)
            if url.netloc == "github.com" and fragment:
                # The IDs in GitHub READMEs have "user-content-" prepended.
                fragment = f"user-content-{fragment}"
            elif url.path.endswith(".pdf") and fragment.startswith("page="):
                # This is not HTML, there is no real ID.
                fragment = ""
            info.external_urls[url_no_frag][fragment].add(path)
        else:
            hash = "#" if url.fragment else ""
            assert (
                href == f"{url.path}{hash}{url.fragment}"
            ), f"got unexpected URL in {path}: {href}"
            assert not url.path.startswith("/")
            info.internal_links[path].append((url.path, url.fragment))
    return info


# TODO: Remove this.
def skip_missing_fragment(path: Path, fragment: str) -> bool:
    return (path.parent == Path("docs/exercise/4") and fragment.startswith("ex4.")) or (
        path.parent == Path("docs/exercise/5") and fragment.startswith("ex5.")
    )


def validate_internal(info: PageInfo) -> bool:
    ok = True
    for src_path, links in info.internal_links.items():
        for rel_path, fragment in links:
            if rel_path:
                target = normalize_path(src_path.parent / rel_path)
            else:
                target = src_path
            if not target.exists():
                print(f"{src_path}: {rel_path}: file not found")
                ok = False
            elif (
                fragment
                and fragment not in info.internal_ids[target]
                and not skip_missing_fragment(target, fragment)
            ):
                print(f"{src_path}: {rel_path}#{fragment}: fragment not found in page")
                ok = False
    return ok


def validate_external(item: tuple[str, dict[str, set[Path]]]) -> bool:
    url, fragments = item
    no_fragments = len(fragments) == 1 and "" in fragments
    method = "head" if no_fragments else "get"
    try:
        r = requests.request(method, url)
    except requests.TooManyRedirects:
        print(f"{url}: too many redirects")
        return False
    if r.status_code != 200:
        linked_from = "\n\t" + "\n\t".join(
            f"linked from: {p}" for paths in fragments.values() for p in paths
        )
        print(f"{url}: HTTP {r.status_code}{linked_from}")
        return False
    if no_fragments:
        return True
    ids = IdParser.parse(str(r.content))
    for fragment, paths in fragments.items():
        if fragment == "":
            continue
        if unquote(fragment) not in ids:
            linked_from = "\n\t" + "\n\t".join(f"linked from: {p}" for p in paths)
            print(f"{url}#{fragment}: fragment not found in page{linked_from}")
            return False
    return True


def main():
    info = PageInfo()
    # The HTML parsing is CPU-bound, so use the default (one process per core).
    with multiprocessing.Pool() as pool:
        for i in pool.imap_unordered(parse_page, sys.argv[1:]):
            info.update(i)
    if not validate_internal(info):
        sys.exit(1)
    # The external link validation involves network IO and also HTML parsing.
    # Use a separate process for each URL.
    num_urls = len(info.external_urls)
    assert num_urls < 100, "more URLs than expected, revisit number of process"
    with multiprocessing.Pool(num_urls) as pool:
        ok = all(pool.imap_unordered(validate_external, info.external_urls.items()))
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
