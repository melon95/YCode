#!/usr/bin/env python3
"""Fail closed before publishing a stable GitHub release."""
import json
import re
import subprocess
import sys


def version(tag):
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag):
        raise ValueError('Expected stable vX.Y.Z tag')
    return tuple(map(int, tag[1:].split('.')))


def check(tag, releases):
    candidate = version(tag)
    for release in releases:
        if release['tag_name'] == tag and not release['draft']:
            raise ValueError('This tag already has a public release; use a new version')
        if release['draft'] or release['prerelease']:
            continue
        try:
            previous = version(release['tag_name'])
        except ValueError:
            continue
        if candidate <= previous:
            raise ValueError(f'New version must exceed {release["tag_name"]}')


if __name__ == '__main__':
    tag, repository = sys.argv[1:]
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository')
    # gh failure is fatal; an outage/auth error is never treated as "no releases".
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp', f'repos/{repository}/releases?per_page=100']))
    check(tag, [release for page in pages for release in page])
    print(f'{tag}: stable release version is available')
