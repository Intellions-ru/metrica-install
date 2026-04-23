#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path


def strip_comments(line: str) -> str:
    return line.split("#", 1)[0]


def parse_server_blocks(text: str):
    lines = text.splitlines(keepends=True)
    blocks = []
    in_server = False
    pending_server = False
    pending_start = 0
    start = 0
    depth = 0

    for idx, line in enumerate(lines):
        clean = strip_comments(line)

        if not in_server:
            if re.match(r"^\s*server\s*\{", clean):
                in_server = True
                start = idx
                depth = clean.count("{") - clean.count("}")
                if depth == 0:
                    blocks.append((start, idx))
                    in_server = False
                continue

            if re.match(r"^\s*server\s*$", clean):
                pending_server = True
                pending_start = idx
                continue

            if pending_server:
                if "{" in clean:
                    in_server = True
                    start = pending_start
                    depth = clean.count("{") - clean.count("}")
                    pending_server = False
                    if depth == 0:
                        blocks.append((start, idx))
                        in_server = False
                    continue
                if clean.strip():
                    pending_server = False
            continue

        depth += clean.count("{") - clean.count("}")
        if depth == 0:
            blocks.append((start, idx))
            in_server = False

    return lines, blocks


def block_text(lines, block):
    start, end = block
    return "".join(lines[start : end + 1])


def block_server_names(block: str):
    names = []
    for match in re.finditer(r"^\s*server_name\s+([^;]+);", block, flags=re.MULTILINE):
        names.extend(part for part in re.split(r"\s+", match.group(1).strip()) if part)
    return names


def block_is_https(block: str) -> bool:
    return bool(
        re.search(r"^\s*listen\s+[^;]*\b443\b", block, flags=re.MULTILINE)
        or re.search(r"^\s*ssl_certificate\s+", block, flags=re.MULTILINE)
    )


def choose_block(lines, blocks, host: str):
    matches = []
    for block in blocks:
        text = block_text(lines, block)
        if host in block_server_names(text):
            matches.append((block, text))

    if not matches:
        raise RuntimeError(f"no matching server block for host {host}")

    https_matches = [item for item in matches if block_is_https(item[1])]
    if len(https_matches) == 1:
        return https_matches[0][0]
    if len(matches) == 1:
        return matches[0][0]

    raise RuntimeError(f"ambiguous matching server blocks for host {host}")


def candidate_files(search_roots):
    seen = set()
    results = []
    for root in search_roots:
        root_path = Path(root)
        if not root_path.exists():
            continue
        if root_path.is_file():
            real_path = root_path.resolve()
            if real_path not in seen:
                seen.add(real_path)
                results.append(real_path)
            continue
        for path in sorted(root_path.iterdir()):
            if path.name.startswith("."):
                continue
            real_path = path.resolve()
            if not real_path.is_file():
                continue
            if real_path in seen:
                continue
            seen.add(real_path)
            results.append(real_path)
    return results


def find_target(search_roots, host: str):
    matches = []
    for path in candidate_files(search_roots):
        text = path.read_text(encoding="utf-8")
        lines, blocks = parse_server_blocks(text)
        try:
            chosen = choose_block(lines, blocks, host)
        except RuntimeError:
            continue
        chosen_text = block_text(lines, chosen)
        matches.append((path, block_is_https(chosen_text)))

    if not matches:
        raise RuntimeError(f"no nginx config for host {host}")

    https_matches = [path for path, is_https in matches if is_https]
    unique_https = sorted({path for path in https_matches})
    unique_matches = sorted({path for path, _ in matches})

    if len(unique_https) == 1:
        return unique_https[0]
    if len(unique_matches) == 1:
        return unique_matches[0]

    raise RuntimeError(f"multiple nginx configs match host {host}")


def insert_include(config_file: Path, host: str, include_path: str):
    text = config_file.read_text(encoding="utf-8")
    lines, blocks = parse_server_blocks(text)
    chosen = choose_block(lines, blocks, host)
    start, end = chosen
    include_line = f"include {include_path};"
    chosen_lines = lines[start : end + 1]

    for line in chosen_lines:
        if line.strip() == include_line:
            return "already-present"

    closing_indent = re.match(r"^(\s*)", lines[end]).group(1)
    include_indent = closing_indent + "  "
    lines.insert(end, f"{include_indent}{include_line}\n")
    config_file.write_text("".join(lines), encoding="utf-8")
    return "inserted"


def remove_include(config_file: Path, include_path: str):
    include_line = f"include {include_path};"
    lines = config_file.read_text(encoding="utf-8").splitlines(keepends=True)
    filtered = [line for line in lines if line.strip() != include_line]
    if filtered == lines:
        return "not-found"
    config_file.write_text("".join(filtered), encoding="utf-8")
    return "removed"


def render_managed_block(block_text: str, indent: str, begin_marker: str, end_marker: str):
    rendered = [f"{indent}{begin_marker}\n"]
    for line in block_text.splitlines():
        if line.strip():
            rendered.append(f"{indent}{line}\n")
        else:
            rendered.append("\n")
    rendered.append(f"{indent}{end_marker}\n")
    return rendered


def insert_managed_block(
    config_file: Path, host: str, block_file: Path, begin_marker: str, end_marker: str
):
    text = config_file.read_text(encoding="utf-8")
    lines, blocks = parse_server_blocks(text)
    chosen = choose_block(lines, blocks, host)
    start, end = chosen
    chosen_lines = lines[start : end + 1]

    for line in chosen_lines:
        stripped = line.strip()
        if stripped == begin_marker or stripped == end_marker:
            return "already-present"

    closing_indent = re.match(r"^(\s*)", lines[end]).group(1)
    block_indent = closing_indent + "  "
    block_text = block_file.read_text(encoding="utf-8")
    lines[end:end] = render_managed_block(block_text, block_indent, begin_marker, end_marker)
    config_file.write_text("".join(lines), encoding="utf-8")
    return "inserted"


def remove_managed_block(config_file: Path, begin_marker: str, end_marker: str):
    lines = config_file.read_text(encoding="utf-8").splitlines(keepends=True)
    begin_index = None
    end_index = None

    for index, line in enumerate(lines):
        stripped = line.strip()
        if begin_index is None and stripped == begin_marker:
            begin_index = index
            continue
        if begin_index is not None and stripped == end_marker:
            end_index = index
            break

    if begin_index is None:
        return "not-found"
    if end_index is None:
        raise RuntimeError(f"managed block start marker found without end marker: {begin_marker}")

    del lines[begin_index : end_index + 1]
    config_file.write_text("".join(lines), encoding="utf-8")
    return "removed"


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    find_parser = subparsers.add_parser("find-target")
    find_parser.add_argument("--host", required=True)
    find_parser.add_argument("--search-root", action="append", required=True)

    insert_parser = subparsers.add_parser("insert-include")
    insert_parser.add_argument("--host", required=True)
    insert_parser.add_argument("--file", required=True)
    insert_parser.add_argument("--include-path", required=True)

    remove_parser = subparsers.add_parser("remove-include")
    remove_parser.add_argument("--file", required=True)
    remove_parser.add_argument("--include-path", required=True)

    insert_block_parser = subparsers.add_parser("insert-block")
    insert_block_parser.add_argument("--host", required=True)
    insert_block_parser.add_argument("--file", required=True)
    insert_block_parser.add_argument("--block-file", required=True)
    insert_block_parser.add_argument("--begin-marker", required=True)
    insert_block_parser.add_argument("--end-marker", required=True)

    remove_block_parser = subparsers.add_parser("remove-block")
    remove_block_parser.add_argument("--file", required=True)
    remove_block_parser.add_argument("--begin-marker", required=True)
    remove_block_parser.add_argument("--end-marker", required=True)

    args = parser.parse_args()

    try:
        if args.command == "find-target":
            print(find_target(args.search_root, args.host))
            return
        if args.command == "insert-include":
            print(insert_include(Path(args.file), args.host, args.include_path))
            return
        if args.command == "remove-include":
            print(remove_include(Path(args.file), args.include_path))
            return
        if args.command == "insert-block":
            print(
                insert_managed_block(
                    Path(args.file),
                    args.host,
                    Path(args.block_file),
                    args.begin_marker,
                    args.end_marker,
                )
            )
            return
        if args.command == "remove-block":
            print(remove_managed_block(Path(args.file), args.begin_marker, args.end_marker))
            return
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
