#!/usr/bin/env python3
"""Build the compact M2OS Russian item dictionary from Minecraft/mod jars."""

from __future__ import annotations

import argparse
import json
import re
import zipfile
from pathlib import Path


LANG_RE = re.compile(r"^assets/([^/]+)/lang/(en_us|ru_ru)\.json$", re.I)
MOD_BLOCK_RE = re.compile(r"\[\[mods\]\](.*?)(?=\n\[\[|\Z)", re.S)
DEFAULT_ITEM_NAMESPACES = ("minecraft", "create", "advancedperipherals")


def read_json(raw: bytes):
    try:
        value = json.loads(raw.decode("utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}


def load_jar(path: Path, languages: dict, mod_names: dict):
    try:
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                match = LANG_RE.match(name)
                if match:
                    namespace, locale = match.groups()
                    target = languages.setdefault(namespace.lower(), {}).setdefault(
                        locale.lower(), {})
                    target.update(read_json(archive.read(name)))

            if "META-INF/neoforge.mods.toml" in archive.namelist():
                text = archive.read("META-INF/neoforge.mods.toml").decode(
                    "utf-8", "replace")
                for block in MOD_BLOCK_RE.findall(text):
                    mod_id = re.search(r'^\s*modId\s*=\s*"([^"]+)"', block, re.M)
                    title = re.search(
                        r'^\s*displayName\s*=\s*"([^"]+)"', block, re.M)
                    if mod_id and title:
                        mod_names.setdefault(mod_id.group(1), title.group(1))
            if "fabric.mod.json" in archive.namelist():
                metadata = read_json(archive.read("fabric.mod.json"))
                if metadata.get("id") and metadata.get("name"):
                    mod_names.setdefault(str(metadata["id"]), str(metadata["name"]))
    except (OSError, zipfile.BadZipFile):
        pass


def add_language_json(languages: dict, namespace: str, locale: str, path: Path):
    target = languages.setdefault(namespace, {}).setdefault(locale, {})
    target.update(read_json(path.read_bytes()))


def lua_string(value: str) -> str:
    return '"' + (value.replace("\\", "\\\\").replace('"', '\\"')
        .replace("\r", "\\r").replace("\n", "\\n")) + '"'


def collect(languages: dict, item_namespaces: set[str]):
    items, enchantments = {}, {}
    for namespace, locales in languages.items():
        russian = locales.get("ru_ru", {})
        english = locales.get("en_us", {})
        for key, ru_value in russian.items():
            if not isinstance(ru_value, str):
                continue
            parts = key.split(".", 2)
            if len(parts) != 3 or parts[1] != namespace:
                continue
            category, _, path = parts
            # Tooltip/ponder keys often start with item./block. too, but they
            # are not registry IDs and only waste memory on the CC computer.
            if "." in path:
                continue
            registry_name = f"{namespace}:{path}"
            en_value = english.get(key)
            pair = (ru_value, en_value if isinstance(en_value, str) else None)
            if category in ("block", "item"):
                if namespace not in item_namespaces:
                    continue
                # Explicit item translations take priority over the block item.
                if category == "item" or registry_name not in items:
                    items[registry_name] = pair
            elif category == "enchantment":
                enchantments[registry_name] = pair
    return items, enchantments


def write_table(handle, name: str, entries: dict):
    handle.write(f"  {name} = {{\n")
    for key in sorted(entries):
        russian, english = entries[key]
        values = lua_string(russian)
        if english and english != russian:
            values += ", " + lua_string(english)
        handle.write(f"    [{lua_string(key)}] = {{ {values} }},\n")
    handle.write("  },\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mods", type=Path, required=True)
    parser.add_argument("--minecraft-jar", type=Path, required=True)
    parser.add_argument("--vanilla-ru", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--item-namespaces", nargs="*", default=DEFAULT_ITEM_NAMESPACES,
        help="item namespaces embedded as an offline fallback")
    args = parser.parse_args()

    languages, mod_names = {}, {"minecraft": "Minecraft"}
    load_jar(args.minecraft_jar, languages, mod_names)
    add_language_json(languages, "minecraft", "ru_ru", args.vanilla_ru)
    for jar in sorted(args.mods.glob("*.jar")):
        load_jar(jar, languages, mod_names)

    items, enchantments = collect(
        languages, {value.lower() for value in args.item_namespaces})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("-- Generated by tools/build_lang.py; do not edit manually.\n")
        handle.write("return {\n")
        write_table(handle, "items", items)
        write_table(handle, "enchantments", enchantments)
        handle.write("  mods = {\n")
        for mod_id in sorted(mod_names):
            handle.write(
                f"    [{lua_string(mod_id)}] = {lua_string(mod_names[mod_id])},\n")
        handle.write("  }\n}\n")
    print(f"wrote {len(items)} items/blocks, {len(enchantments)} enchantments, "
          f"{len(mod_names)} mod names to {args.output}")


if __name__ == "__main__":
    main()
