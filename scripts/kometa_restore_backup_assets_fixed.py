#!/usr/bin/env python3
"""Safely copy Kometa clean overlay backups to properly named asset folders.

Dry-run by default. Reads local Plex URL/token from Kometa YAML without
third-party dependencies. No Plex metadata is changed by this program.
"""
from __future__ import annotations

import argparse
import collections
import csv
import os
from pathlib import Path, PureWindowsPath, PurePosixPath
import re
import shutil
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_CONFIG = Path('/opt/kometa-quickstart/config/kryptonian.yml')
DEFAULT_ASSETS = Path('/media/kometa-assets')
DEFAULT_OVERLAYS = Path('/opt/kometa-quickstart/config/overlays')
LIBRARIES = ('Movies', 'TV Shows', 'Anime')
EXTS = ('jpg', 'jpeg', 'png', 'webp', 'tbn')
SEASON_RE = re.compile(r'^(?:season\s*[0-9]+|series\s*[0-9]+|s[0-9]+|specials)$', re.I)


def parse_plex_config(filename: Path):
    """Read only top-level plex url, token and verify_ssl from Kometa config."""
    props = {}
    in_plex = False
    for raw in filename.read_text(encoding='utf-8').splitlines():
        if re.match(r'^plex:\s*(?:#.*)?$', raw):
            in_plex = True
            continue
        if in_plex and raw.strip() and not raw[0].isspace() and not raw.lstrip().startswith('#'):
            break
        if not in_plex or not raw.strip() or raw.lstrip().startswith('#'):
            continue
        match = re.match(r'^\s+(url|token|verify_ssl):\s*(.*?)\s*$', raw)
        if match:
            k, v = match.groups()
            props[k] = v.split(' #', 1)[0].strip().strip('"\'')
    url = os.environ.get('PLEX_URL') or props.get('url', '')
    token = os.environ.get('PLEX_TOKEN') or props.get('token', '')
    if not url or not token:
        raise ValueError('Plex url or token not found in config; set PLEX_URL and PLEX_TOKEN.')
    return url.rstrip('/'), token, props.get('verify_ssl', 'true').lower() != 'false'


class PlexClient:
    def __init__(self, url, token, verify_ssl):
        self.url = url
        self.token = token
        self.context = None if verify_ssl else ssl._create_unverified_context()

    def get(self, path, params=None):
        endpoint = self.url + '/' + path.lstrip('/')
        if params:
            endpoint += '?' + urllib.parse.urlencode(params)
        req = urllib.request.Request(endpoint, headers={
            'X-Plex-Token': self.token,
            'Accept': 'application/xml',
            'X-Plex-Client-Identifier': 'kometa-backup-asset-import',
            'X-Plex-Product': 'Kometa Backup Asset Import',
        })
        with urllib.request.urlopen(req, context=self.context, timeout=90) as r:
            return ET.fromstring(r.read())

    def sections(self):
        out = {}
        for e in self.get('/library/sections').findall('./Directory'):
            out[e.get('title')] = (e.get('key'), e.get('type'))
        return out

    def items(self, section_key, plex_type, leaves=False):
        """Stream all Plex items, accepting its native XML element names.

        Plex XML uses <Video> for movies/episodes and <Directory> for
        shows/seasons; <Metadata> is used by other API representations.
        """
        offset = 0
        pagesize = 500
        previous_page_first_key = None
        endpoint = (f'/library/sections/{section_key}/allLeaves' if leaves
                    else f'/library/sections/{section_key}/all')
        while True:
            params = {
                'includeMedia': 1,
                'X-Plex-Container-Start': offset,
                'X-Plex-Container-Size': pagesize,
            }
            if not leaves:
                params['type'] = plex_type
            root = self.get(endpoint, params)
            if root.tag != 'MediaContainer':
                raise RuntimeError(f'Unexpected Plex response root: {root.tag}')
            items = [el for el in root if el.tag in ('Video', 'Directory', 'Metadata')]
            if not items:
                if offset == 0:
                    print(f'  Plex returned no media entries from {endpoint} '
                          f'(XML tags: {[el.tag for el in root][:6]})')
                break
            if offset and items[0].get('ratingKey') == previous_page_first_key:
                raise RuntimeError('Plex ignored pagination; stopping to avoid an incomplete map')
            previous_page_first_key = items[0].get('ratingKey')
            for item in items:
                yield item
            offset += len(items)
            total = root.get('totalSize')
            if total is not None and offset >= int(total):
                break
            if len(items) < pagesize:
                break


def item_path(item):
    file_paths = {
        p.get('file')
        for p in item.findall('.//Media/Part')
        if p.get('file')
    }
    if not file_paths:
        return None
    # If one item has multiple media files in different folders, don't guess.
    if len({str(media_file_parent(p)) for p in file_paths}) > 1:
        return None
    return next(iter(file_paths))


def pure_path(filepath):
    return PureWindowsPath(filepath) if '\\' in filepath else PurePosixPath(filepath)


def media_file_parent(filepath):
    return pure_path(filepath).parent


def movie_asset_name(filepath):
    folder = media_file_parent(filepath).name
    return safe_name(folder)


def show_asset_name(filepath):
    folder = media_file_parent(filepath)
    if SEASON_RE.fullmatch(folder.name):
        folder = folder.parent
    return safe_name(folder.name)


def safe_name(name):
    if not name or name in ('.', '..') or '/' in name or '\\' in name:
        return None
    return name


def int_attr(element, attribute):
    value = element.get(attribute)
    try:
        result = int(value)
        return result if result >= 0 else None
    except (ValueError, TypeError):
        return None


def movie_map(client, section):
    mapping = {}
    for item in client.items(section, 1):
        key = int_attr(item, 'ratingKey')
        filepath = item_path(item)
        folder = movie_asset_name(filepath) if filepath else None
        if key is not None and folder:
            mapping[key] = (folder, 'poster')
    return mapping


def show_map(client, section):
    """Use episode media paths to resolve the true show folder name."""
    def build_from(episodes):
        episode_rows = []
        folders_by_show = collections.defaultdict(set)
        for item in episodes:
            filepath = item_path(item)
            show_key = int_attr(item, 'grandparentRatingKey')
            show_folder = show_asset_name(filepath) if filepath else None
            if show_key is not None and show_folder:
                folders_by_show[show_key].add(show_folder)
            episode_rows.append((item, show_key))
        return episode_rows, folders_by_show

    episode_rows, folders_by_show = build_from(client.items(section, 4))
    if not folders_by_show:
        print('  No episode file paths found using type=4; trying Plex allLeaves...')
        episode_rows, folders_by_show = build_from(client.items(section, 4, leaves=True))

    # Different folders for the same Plex show are ambiguous: skip safely.
    unique_show_folder = {
        show_key: next(iter(folders))
        for show_key, folders in folders_by_show.items()
        if len(folders) == 1
    }
    mapping = {k: (folder, 'poster') for k, folder in unique_show_folder.items()}
    for episode, show_key in episode_rows:
        if show_key not in unique_show_folder:
            continue
        folder = unique_show_folder[show_key]
        season_key = int_attr(episode, 'parentRatingKey')
        season = int_attr(episode, 'parentIndex')
        episode_key = int_attr(episode, 'ratingKey')
        number = int_attr(episode, 'index')
        if season is None:
            continue
        if season_key is not None:
            mapping[season_key] = (folder, f'Season{season:02d}')
        if episode_key is not None and number is not None:
            mapping[episode_key] = (folder, f'S{season:02d}E{number:02d}')
    return mapping


def has_existing_asset(destination):
    names = [destination.stem]
    if destination.stem == 'poster':
        names += ['cover', 'default', 'folder', 'movie']
    for name in names:
        for ext in EXTS:
            if (destination.parent / f'{name}.{ext}').exists():
                return True
    return False


def valid_jpeg(path, allow_small, pillow):
    try:
        if path.stat().st_size < 10 * 1024 and not allow_small:
            return 'small_source'
        with path.open('rb') as f:
            if not f.read(3).startswith(b'\xff\xd8\xff'):
                return 'non_jpeg_source'
        if pillow:
            with pillow.open(path) as img:
                if img.format != 'JPEG':
                    return 'non_jpeg_source'
                img.verify()
    except Exception:
        return 'corrupt_source'
    return None


def exclusive_copy(source, target):
    """Copy only if target absent; no overwrites even if another process races."""
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, 'wb') as out, source.open('rb') as inp:
            shutil.copyfileobj(inp, out, 1024 * 1024)
        shutil.copystat(source, target)
    except BaseException:
        target.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--assets', type=Path, default=DEFAULT_ASSETS)
    parser.add_argument('--overlays', type=Path, default=DEFAULT_OVERLAYS)
    parser.add_argument('--library', choices=LIBRARIES, action='append',
                        help='One or more libraries; omit for all three')
    parser.add_argument('--apply', action='store_true',
                        help='Actually copy files (otherwise dry-run)')
    parser.add_argument('--include-small', action='store_true',
                        help='Also copy images smaller than 10 KiB')
    parser.add_argument('--report', type=Path,
                        help='Optional CSV report with per-item results')
    args = parser.parse_args()

    try:
        plex_url, token, verify_ssl = parse_plex_config(args.config)
        plex = PlexClient(plex_url, token, verify_ssl)
        sections = plex.sections()
    except Exception as e:
        sys.exit(f'Unable to access Plex: {e}')

    chosen = args.library or list(LIBRARIES)
    jobs = []
    skipped = collections.Counter()
    try:
        for library in chosen:
            source_dir = args.overlays / f'{library} Original Posters'
            if not source_dir.is_dir():
                print(f'WARNING: Missing directory {source_dir}; skipping')
                continue
            if library not in sections:
                print(f'WARNING: Plex library "{library}" not found; skipping')
                continue
            section, library_type = sections[library]
            print(f'Reading Plex metadata for {library}...', flush=True)
            if library_type == 'movie':
                mapping = movie_map(plex, section)
            elif library_type == 'show':
                mapping = show_map(plex, section)
            else:
                print(f'WARNING: Unsupported Plex type {library_type}; skipping')
                continue
            print(f'  Indexed {len(mapping)} poster/season/episode assets')
            if not mapping:
                sys.exit(
                    f'ERROR: Plex library "{library}" indexed zero usable entries. '
                    'No backups have been copied. Check the Plex response and '
                    'whether media file paths are present in the API output.'
                )
            for source in source_dir.glob('*.jpg'):
                try:
                    key = int(source.stem)
                except ValueError:
                    skipped[(library, 'invalid_rating_key')] += 1
                    continue
                dest_info = mapping.get(key)
                if dest_info is None:
                    skipped[(library, 'not_mapped')] += 1
                    continue
                folder, name = dest_info
                dest = args.assets / folder / f'{name}.jpg'
                jobs.append((library, source, dest))
    except Exception as e:
        sys.exit(f'Could not finish Plex metadata mapping: {e}')

    # A shared asset root must not silently mix two different items targeting
    # the same asset, even across library boundaries.
    by_destination = collections.defaultdict(set)
    for library, source, target in jobs:
        by_destination[str(target)].add(str(source))
    conflicting_destinations = {
        dest for dest, srcs in by_destination.items() if len(srcs) > 1
    }

    try:
        from PIL import Image
    except ImportError:
        Image = None
        print('NOTE: Pillow not installed; checking JPEG file signatures only.')

    rows = []
    copy_jobs = []
    for library, source, target in jobs:
        if str(target) in conflicting_destinations:
            status = 'ambiguous_destination'
        elif has_existing_asset(target):
            status = 'existing_asset'
        else:
            status = valid_jpeg(source, args.include_small, Image)
        if status:
            skipped[(library, status)] += 1
            rows.append((library, source, target, status))
        else:
            copy_jobs.append((library, source, target))

    bytes_needed = sum(source.stat().st_size for _, source, _ in copy_jobs)
    print(f'\nMode: {"APPLY" if args.apply else "DRY RUN"}')
    print(f'Eligible images: {len(copy_jobs)}')
    print(f'Additional storage needed: {bytes_needed / 1024**3:.2f} GiB')
    if skipped:
        print('Skipped:')
        for (library, reason), count in sorted(skipped.items()):
            print(f'  {library}: {reason}: {count}')
    print('First eligible destinations:')
    for library, src, dest in copy_jobs[:12]:
        print(f'  [{library}] {src.name} -> {dest}')

    if args.apply:
        # Never create the asset root implicitly: a missing network mount
        # would otherwise cause writes onto the host filesystem instead.
        if not args.assets.is_dir():
            sys.exit(f'Asset directory {args.assets} does not exist. Check that the storage is mounted before --apply.')
        available = shutil.disk_usage(args.assets).free
        if bytes_needed > available:
            sys.exit('Insufficient free disk space; no changes made. Copy one library at a time or free space.')

    copied = 0
    errors = 0
    for library, source, target in copy_jobs:
        if not args.apply:
            rows.append((library, source, target, 'would_copy'))
            continue
        try:
            if has_existing_asset(target):
                rows.append((library, source, target, 'existing_asset'))
                continue
            exclusive_copy(source, target)
            rows.append((library, source, target, 'copied'))
            copied += 1
        except FileExistsError:
            rows.append((library, source, target, 'existing_asset'))
        except Exception as e:
            rows.append((library, source, target, 'error'))
            errors += 1
            print(f'ERROR copying {source}: {e}', file=sys.stderr)

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open('w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['library', 'source', 'destination', 'status'])
            writer.writerows(rows)
        print(f'Report written to {args.report}')
    print(f'Done. Copied: {copied}, errors: {errors}. Original backups left unchanged.')
    if not args.apply:
        print('This was a dry run. Add --apply to perform the copies.')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
