#!/usr/bin/env python3
"""Deterministically generate the Portal navigation vocabulary from pinned sources.

Sources (all read-only, all outside this repository, all receipted in the output):

1. `platform` static taxonomy assets pinned at
   `aca2d4f2a905e97867942a78be75c5daea4fde5e`
   (`src/services/referenceResources/reference-resource-manifest.json` plus the
   `base.json` / `overlays/{zh,de,fr}.json` files it receipts):
   `isic`, `cpc`, `ilcd-flow-categorization`, `ilcd-locations`.
2. The frozen TianGong LCA Database snapshot
   (`data/tiangong_lca_data/ILCDLocations.xml`), used **only** for the Chinese
   province/city codes the pinned platform vocabulary does not carry.

Outputs:

* `contracts/portal/navigation-vocabulary.json` - Portal-consumable asset with
  the source receipt, per-dimension counts and every node (id, parent, code,
  taxonomy, dimension, four-locale labels, label strategy).
* `contracts/portal/navigation-vocabulary.receipt.json` - small summary that
  records the receipt and the sha256/byte length of the asset.
* `supabase/migrations/<stamp>_portal_navigation_vocabulary_seed_*.sql` - the
  seeded SQL rows, split into bounded files.

Run:  python3 scripts/generate_portal_navigation_vocabulary.py \
          --platform-root ../platform \
          --archive-locations ../data/tiangong_lca_data/ILCDLocations.xml \
          --china-mapping data/portal-navigation-china-mapping.json

The script is offline and deterministic: identical inputs produce byte-identical
outputs. It never reads or writes a database.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

PLATFORM_COMMIT = "aca2d4f2a905e97867942a78be75c5daea4fde5e"
ARCHIVE_NOTE = (
    "tiangong-lca/database-era TianGong LCA snapshot, retained as a historical "
    "unmaintained public snapshot since 2026-06-21"
)

CLASSIFICATION_TAXONOMIES = ("isic", "cpc", "elementary")
CLASSIFICATION_ROOT = {
    "isic": "class:isic",
    "cpc": "class:cpc",
    "elementary": "class:elementary",
}
# Which dataset kind a taxonomy may be resolved against. A taxonomy is never
# applied to the other kind, so ISIC (process) and CPC (flow) codes that share a
# spelling cannot collide.
TAXONOMY_KINDS = {
    "isic": ("process",),
    "cpc": ("flow",),
    "elementary": ("flow",),
}
PLATFORM_RESOURCE = {
    "isic": "isic",
    "cpc": "cpc",
    "elementary": "ilcd-flow-categorization",
    "ilcd-locations": "ilcd-locations",
}
OUTPUT_LOCALES = ("en", "zh-CN", "de", "fr")
# The pinned overlays are keyed by upstream locale names.
OVERLAY_LOCALE = {"zh-CN": "zh", "de": "de", "fr": "fr"}
LABEL_STRATEGY_OFFICIAL = "official-source"
LABEL_STRATEGY_OVERLAY = "project-reviewed-overlay"
LABEL_STRATEGY_ARCHIVE = "archived-snapshot-parenthesised-name"
LABEL_STRATEGY_VIRTUAL = "database-virtual-container"
LABEL_STRATEGY_UNAVAILABLE = "unavailable"
TAXONOMY_ARCHIVE_LOCATIONS = "tiangong-lca-archive-locations-v1"

# Virtual containers. They own no source node, and their code is a fixed marker
# that can never collide with a real source code.
VIRTUAL_CLASSIFICATION_ROOTS = {
    "isic": {"en": "ISIC", "zh-CN": "ISIC 行业分类", "de": "ISIC", "fr": "CITI"},
    "cpc": {
        "en": "CPC",
        "zh-CN": "CPC 产品分类",
        "de": "CPC",
        "fr": "CPC",
    },
    "elementary": {
        "en": "Elementary flows",
        "zh-CN": "基本流分类",
        "de": "Elementarflüsse",
        "fr": "Flux élémentaires",
    },
}
VIRTUAL_GEOGRAPHY_ROOT = {
    "nodeId": "geo:unmapped",
    "code": "~",
    "labels": {
        "en": "Unmapped locations",
        "zh-CN": "未映射地区",
        "de": "Nicht zugeordnete Standorte",
        "fr": "Localisations non mappées",
    },
}


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> tuple[str, int]:
    payload = path.read_bytes()
    return sha256_bytes(payload), len(payload)


def stable_json(document: object) -> str:
    """Deterministic JSON: sorted keys, compact separators, no trailing newline."""
    return json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


@dataclass
class Node:
    node_id: str
    parent_id: str | None
    code: str
    taxonomy: str
    dimension: str
    labels: dict[str, str] = field(default_factory=dict)
    label_strategy: dict[str, str] = field(default_factory=dict)
    source_index_path: str | None = None
    source_file: str | None = None
    has_children: bool = False

    def to_document(self) -> dict[str, object]:
        return {
            "code": self.code,
            "dimension": self.dimension,
            "hasChildren": self.has_children,
            "labelStrategy": {locale: self.label_strategy[locale] for locale in OUTPUT_LOCALES},
            "labels": {locale: self.labels[locale] for locale in OUTPUT_LOCALES},
            "nodeId": self.node_id,
            "parentNodeId": self.parent_id,
            "sourceIndexPath": self.source_index_path,
            "taxonomy": self.taxonomy,
        }


def index_path_key(path: tuple[int, ...]) -> str:
    """The pinned overlays address nodes as `category[0]/category[1]/...`."""
    return "/".join(f"category[{index}]" for index in path)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_manifest(platform_root: Path) -> dict:
    return read_json(
        platform_root / "src/services/referenceResources/reference-resource-manifest.json"
    )


def manifest_resource(manifest: dict, resource_id: str) -> dict:
    for resource in manifest["resources"]:
        if resource["resourceId"] == resource_id:
            return resource
    raise SystemExit(f"resource {resource_id!r} is absent from the platform manifest")


def category_children(value: object) -> list[dict]:
    if value is None:
        return []
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        return [entry for entry in value if isinstance(entry, dict)]
    raise SystemExit("unexpected category node shape in the pinned taxonomy")


def flatten_classification_tree(base: dict) -> list[tuple[tuple[int, ...], str, str, str]]:
    """Return (index path, code, base name, dataType) for every node.

    Flattening is depth-first and positional: a node's index path is its index
    among its siblings at each level, which is exactly the `tree-index-path`
    identity strategy the pinned manifest declares.
    """
    system = base["CategorySystem"]
    blocks = category_children(system["categories"])
    if len(blocks) != 1:
        raise SystemExit("pinned taxonomies carry exactly one data-type block")
    data_type = blocks[0].get("@dataType") or ""
    rows: list[tuple[tuple[int, ...], str, str, str]] = []

    def walk(path: tuple[int, ...], node: dict, depth: int) -> None:
        if depth > 16:
            raise SystemExit("taxonomy nesting is unexpectedly deep")
        code = (node.get("@id") or "").strip()
        name = (node.get("@name") or "").strip()
        if not code or not name:
            raise SystemExit(f"taxonomy node {path} lacks @id or @name")
        rows.append((path, code, name, data_type))
        for index, child in enumerate(category_children(node.get("category"))):
            walk(path + (index,), child, depth + 1)

    for index, child in enumerate(category_children(blocks[0].get("category"))):
        walk((index,), child, 0)
    return rows


def load_overlay_labels(asset_dir: Path, resource_id: str) -> dict[str, dict[str, str]]:
    """locale -> index-path key -> label (plus the expected @id assertion)."""
    labels: dict[str, dict[str, str]] = {}
    for locale in ("zh", "de", "fr"):
        document = read_json(asset_dir / resource_id / "overlays" / f"{locale}.json")
        entries: dict[str, str] = {}
        for entry in document["labels"]:
            entries[entry["key"]] = entry["label"]
        labels[locale] = entries
    return labels


def virtual_node(
    node_id: str, code: str, taxonomy: str, dimension: str, labels: dict[str, str]
) -> Node:
    return Node(
        node_id=node_id,
        parent_id=None,
        code=code,
        taxonomy=taxonomy,
        dimension=dimension,
        labels=dict(labels),
        label_strategy={locale: LABEL_STRATEGY_VIRTUAL for locale in OUTPUT_LOCALES},
        source_index_path=None,
        source_file=None,
    )


def build_classification_nodes(
    platform_root: Path, manifest: dict
) -> tuple[list[Node], list[dict]]:
    asset_root = platform_root / "src/services/referenceResources/data"
    nodes: list[Node] = [
        virtual_node(
            CLASSIFICATION_ROOT[taxonomy], "ALL", taxonomy, "classification", labels
        )
        for taxonomy, labels in VIRTUAL_CLASSIFICATION_ROOTS.items()
    ]
    receipts: list[dict] = []
    for taxonomy in CLASSIFICATION_TAXONOMIES:
        resource_id = PLATFORM_RESOURCE[taxonomy]
        resource = manifest_resource(manifest, resource_id)
        base_path = asset_root / resource_id / "base.json"
        base = read_json(base_path)
        rows = flatten_classification_tree(base)
        overlay = load_overlay_labels(asset_root, resource_id)
        digest, byte_length = sha256_file(base_path)
        overlays_receipt = []
        for locale in ("zh", "de", "fr"):
            overlay_path = asset_root / resource_id / "overlays" / f"{locale}.json"
            overlay_digest, overlay_length = sha256_file(overlay_path)
            overlays_receipt.append(
                {
                    "byteLength": overlay_length,
                    "locale": locale,
                    "path": str(overlay_path.relative_to(platform_root)),
                    "sha256": overlay_digest,
                }
            )
        receipts.append(
            {
                "byteLength": byte_length,
                "overlays": overlays_receipt,
                "path": str(base_path.relative_to(platform_root)),
                "resourceId": resource_id,
                "runtimeAssets": {
                    locale: {
                        "byteLength": asset["byteLength"],
                        "fileName": asset["fileName"],
                        "jsonDigest": asset["jsonDigest"]["value"],
                    }
                    for locale, asset in sorted(resource["runtime"]["assets"].items())
                },
                "scope": resource["scope"],
                "sha256": digest,
            }
        )
        root_id = CLASSIFICATION_ROOT[taxonomy]
        seen_ids: set[str] = set()
        for path, code, base_name, data_type in rows:
            path_key = index_path_key(path)
            node_id = f"{root_id}:{'.'.join(str(part) for part in path)}"
            if node_id in seen_ids:
                raise SystemExit(f"duplicate taxonomy node id {node_id}")
            seen_ids.add(node_id)
            parent_id = root_id if len(path) == 1 else f"{root_id}:{'.'.join(str(p) for p in path[:-1])}"
            labels = {"en": base_name}
            strategy = {"en": LABEL_STRATEGY_OFFICIAL}
            for locale in ("zh-CN", "de", "fr"):
                value = overlay[OVERLAY_LOCALE[locale]].get(path_key)
                if value is None:
                    raise SystemExit(
                        f"{resource_id} overlay {locale} is missing {path_key} ({code})"
                    )
                labels[locale] = value
                strategy[locale] = LABEL_STRATEGY_OVERLAY
            nodes.append(
                Node(
                    node_id=node_id,
                    parent_id=parent_id,
                    code=code,
                    taxonomy=taxonomy,
                    dimension="classification",
                    labels=labels,
                    label_strategy=strategy,
                    source_index_path=path_key,
                    source_file=str((Path("src/services/referenceResources/data") / resource_id / "base.json")),
                )
            )
    return nodes, receipts


def build_geography_nodes(
    platform_root: Path,
    manifest: dict,
    archive_locations: Path,
    china_mapping_path: Path,
) -> tuple[list[Node], list[dict], list[str]]:
    asset_root = platform_root / "src/services/referenceResources/data"
    nodes: list[Node] = [
        virtual_node(
            VIRTUAL_GEOGRAPHY_ROOT["nodeId"],
            VIRTUAL_GEOGRAPHY_ROOT["code"],
            "database-virtual",
            "geography",
            VIRTUAL_GEOGRAPHY_ROOT["labels"],
        )
    ]
    receipts: list[dict] = []

    resource = manifest_resource(manifest, "ilcd-locations")
    base_path = asset_root / "ilcd-locations" / "base.json"
    base = read_json(base_path)
    overlay = load_overlay_labels(asset_root, "ilcd-locations")
    digest, byte_length = sha256_file(base_path)
    overlays_receipt = []
    for locale in ("zh", "de", "fr"):
        overlay_path = asset_root / "ilcd-locations" / "overlays" / f"{locale}.json"
        overlay_digest, overlay_length = sha256_file(overlay_path)
        overlays_receipt.append(
            {
                "byteLength": overlay_length,
                "locale": locale,
                "path": str(overlay_path.relative_to(platform_root)),
                "sha256": overlay_digest,
            }
        )
    receipts.append(
        {
            "byteLength": byte_length,
            "overlays": overlays_receipt,
            "path": str(base_path.relative_to(platform_root)),
            "resourceId": "ilcd-locations",
            "runtimeAssets": {
                locale: {
                    "byteLength": asset["byteLength"],
                    "fileName": asset["fileName"],
                    "jsonDigest": asset["jsonDigest"]["value"],
                }
                for locale, asset in sorted(resource["runtime"]["assets"].items())
            },
            "scope": resource["scope"],
            "sha256": digest,
        }
    )

    ilcd_codes: set[str] = set()
    for entry in category_children(base["ILCDLocations"]["location"]):
        code = (entry.get("@value") or "").strip()
        if not code or code.upper() == "NULL":
            # The literal NULL row carries no usable location code.
            continue
        ilcd_codes.add(code.upper())
        labels = {"en": (entry.get("#text") or "").strip()}
        strategy = {"en": LABEL_STRATEGY_OFFICIAL}
        for locale in ("zh-CN", "de", "fr"):
            value = overlay[OVERLAY_LOCALE[locale]].get(f"location:{code}")
            labels[locale] = value if value is not None else labels["en"]
            strategy[locale] = (
                LABEL_STRATEGY_OVERLAY if value is not None else LABEL_STRATEGY_OFFICIAL
            )
        nodes.append(
            Node(
                node_id=f"geo:{code.lower()}",
                parent_id=None,
                code=code,
                taxonomy="ilcd-locations",
                dimension="geography",
                labels=labels,
                label_strategy=strategy,
                source_index_path=f"location:{code}",
                source_file="src/services/referenceResources/data/ilcd-locations/base.json",
            )
        )

    # Project Chinese administrative layer, sourced only from the frozen archive
    # and gated by the checked-in controlled mapping.
    archive_digest, archive_length = sha256_file(archive_locations)
    mapping = read_json(china_mapping_path)
    mapping_sources = [
        source
        for source in mapping.get("sources", [])
        if source.get("path") == "data/tiangong_lca_data/ILCDLocations.xml"
    ]
    if len(mapping_sources) != 1 or mapping_sources[0].get("sha256") != archive_digest:
        raise SystemExit(
            "the China mapping does not receipt the archive file being read; "
            f"expected sha256 {archive_digest}"
        )
    country_node = mapping["countryNode"]
    province_codes = set(mapping["provinceToCountry"])
    receipts.append(
        {
            "byteLength": archive_length,
            "note": ARCHIVE_NOTE,
            "path": "data/tiangong_lca_data/ILCDLocations.xml",
            "resourceId": TAXONOMY_ARCHIVE_LOCATIONS,
            "scope": "location",
            "sha256": archive_digest,
        }
    )
    receipts.append(
        {
            "byteLength": china_mapping_path.stat().st_size,
            "path": str(china_mapping_path.relative_to(china_mapping_path.parents[1])),
            "resourceId": "portal-navigation-china-mapping-v1",
            "sha256": sha256_file(china_mapping_path)[0],
            "scope": "location",
        }
    )

    archive_text = archive_locations.read_text(encoding="utf-8")
    archive_entries = dict(
        re.findall(r'<location[^>]*value="([^"]*)"[^>]*>([^<]*)</location>', archive_text)
    )
    chinese: dict[str, dict[str, str | None]] = {}
    for raw_code, raw_name in archive_entries.items():
        code = raw_code.strip().upper()
        if not code.endswith("-CN") or code in ilcd_codes:
            continue
        segments = code[:-3].split("-")
        if len(segments) not in (1, 2):
            raise SystemExit(f"unexpected Chinese administrative code shape: {code}")
        chinese_segments = re.findall(r"[（(]([^（()）]+)[)）]", raw_name)
        if len(chinese_segments) != len(segments) + 1:
            raise SystemExit(
                f"archived location {code} does not name every level: {raw_name!r}"
            )
        if len(segments) == 1:
            if code not in province_codes:
                raise SystemExit(
                    f"province {code} is absent from the controlled mapping"
                )
            parent_code = country_node
            parent_label = None
        else:
            parent_code = f"{segments[1]}-CN"
            parent_label = chinese_segments[1].strip()
        chinese[code] = {
            "code": code,
            "label": chinese_segments[0].strip(),
            "parent": parent_code,
            "parentLabel": parent_label,
        }
    for code, entry in sorted(chinese.items()):
        parent_code = entry["parent"]
        if parent_code is None or parent_code in chinese or parent_code == country_node:
            continue
        if parent_code not in province_codes:
            raise SystemExit(
                f"Chinese administrative parent {parent_code} of {code} is not a "
                "mapped province"
            )
        # The archive may omit the province row itself; label it from the child.
        chinese[parent_code] = {
            "code": parent_code,
            "label": entry["parentLabel"],
            "parent": country_node,
            "parentLabel": None,
        }
    for code, entry in sorted(chinese.items()):
        if not entry["label"]:
            raise SystemExit(f"Chinese administrative code {code} has no derivable label")
        parent_code = entry["parent"]
        if parent_code is not None and parent_code not in chinese and parent_code != country_node:
            raise SystemExit(f"Chinese administrative code {code} lacks parent {parent_code}")
        # Only zh-CN is a real name. Recording the same string under en/de/fr
        # would present a Chinese name as a translation, so the other locales are
        # explicitly empty and marked unavailable.
        nodes.append(
            Node(
                node_id=f"geo:{code.lower()}",
                parent_id=f"geo:{parent_code.lower()}" if parent_code else "geo:cn",
                code=code,
                taxonomy=TAXONOMY_ARCHIVE_LOCATIONS,
                dimension="geography",
                labels={"en": "", "zh-CN": entry["label"], "de": "", "fr": ""},
                label_strategy={
                    "en": LABEL_STRATEGY_UNAVAILABLE,
                    "zh-CN": LABEL_STRATEGY_ARCHIVE,
                    "de": LABEL_STRATEGY_UNAVAILABLE,
                    "fr": LABEL_STRATEGY_UNAVAILABLE,
                },
                source_index_path=f"location:{code}",
                source_file="data/tiangong_lca_data/ILCDLocations.xml",
            )
        )
    return nodes, receipts, sorted(ilcd_codes)


def mark_parents(nodes: list[Node]) -> None:
    known = {node.node_id for node in nodes}
    for node in nodes:
        if node.parent_id is not None and node.parent_id not in known:
            raise SystemExit(f"node {node.node_id} names absent parent {node.parent_id}")
    parents = {node.parent_id for node in nodes if node.parent_id is not None}
    for node in nodes:
        node.has_children = node.node_id in parents


def raw_geography_id(code: str) -> str:
    folded = code.strip().upper()
    return f"geo:~{sha256_bytes(f'geo|{folded}'.encode())[:16]}"


def sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def sql_jsonb(document: object) -> str:
    return sql_text(stable_json(document)) + "::jsonb"


def chunked(rows: list[str], size: int) -> list[list[str]]:
    return [rows[index : index + size] for index in range(0, len(rows), size)]


def order_parents_first(nodes: list[Node]) -> list[Node]:
    """Order seeded rows so every parent row exists before its children.

    The vocabulary asset stays sorted by node id; only the SQL row order changes,
    because the self-referencing foreign key is checked per statement.
    """
    by_id = {node.node_id: node for node in nodes}
    children: dict[str | None, list[str]] = {}
    for node in nodes:
        children.setdefault(node.parent_id, []).append(node.node_id)
    for bucket in children.values():
        bucket.sort()
    ordered: list[Node] = []
    seen: set[str] = set()

    def visit(node_id: str) -> None:
        if node_id in seen:
            return
        seen.add(node_id)
        ordered.append(by_id[node_id])
        for child_id in children.get(node_id, ()):  # type: ignore[arg-type]
            visit(child_id)

    for root_id in sorted(children.get(None, ())):
        visit(root_id)
    if len(ordered) != len(nodes):
        missing = sorted(set(by_id) - seen)
        raise SystemExit(f"nodes are not reachable from a root: {missing[:5]}")
    return ordered


def emit_seed_migration(
    *,
    seed_dir: Path,
    stamp: str,
    nodes: list[Node],
    asset_digest: str,
    seed_digest: str,
    node_count: int,
) -> Path:
    """Write the seeded vocabulary rows as one bounded, replayable migration.

    A single migration keeps one migration version and one transaction: the
    manifest row and every seeded node either all appear or none do, so a
    partially seeded vocabulary can never be observed.
    """
    if not re.fullmatch(r"\d{14}", stamp):
        raise SystemExit("--seed-stamp must be a 14-digit migration timestamp")

    statements: list[str] = []
    for node in order_parents_first(nodes):
        statements.append(
            "insert into private.portal_navigation_node_v1 ("
            "node_id,parent_node_id,code,taxonomy,dimension,"
            "source_index_path,source_file,labels,label_strategy"
            ") values ("
            f"{sql_text(node.node_id)},{sql_text(node.parent_id) if node.parent_id else 'null'},"
            f"{sql_text(node.code)},{sql_text(node.taxonomy)},{sql_text(node.dimension)},"
            f"{sql_text(node.source_index_path) if node.source_index_path else 'null'},"
            f"{sql_text(node.source_file) if node.source_file else 'null'},"
            f"{sql_jsonb(node.labels)},{sql_jsonb(node.label_strategy)}"
            ");"
        )
    statements.append(
        "insert into private.portal_navigation_contract_v1 ("
        "contract_version,manifest_schema,asset_sha256,seed_sha256,"
        "node_count,created_by_migration"
        ") values (1,'portal.navigation-vocabulary-manifest.v1',"
        f"'{asset_digest}','{seed_digest}',{node_count},'{stamp}');"
    )
    # `perform` is PL/pgSQL; a `do` block keeps the whole seed in one migration.
    statements.append(
        "do $portal_navigation_seed_check$\n"
        "begin\n"
        "  perform private.assert_portal_navigation_contract_v1();\n"
        "end\n"
        "$portal_navigation_seed_check$;"
    )

    header = "\n".join(
        [
            "-- Portal navigation vocabulary seed (generated).",
            "--",
            "-- Source of truth: contracts/portal/navigation-vocabulary.json",
            f"--   asset sha256 {asset_digest}",
            f"--   seed  sha256 {seed_digest}",
            f"--   nodes {node_count}",
            "-- Regenerate with:",
            "--   python3 scripts/generate_portal_navigation_vocabulary.py \\",
            "--     --platform-root ../platform \\",
            "--     --archive-locations ../data/tiangong_lca_data/ILCDLocations.xml \\",
            "--     --china-mapping data/portal-navigation-china-mapping.json",
            "-- Never edit these rows by hand.",
            "",
            "begin;",
            "",
            "set local lock_timeout = '5s';",
            "set local statement_timeout = '600s';",
            "",
        ]
    )
    seed_dir.mkdir(parents=True, exist_ok=True)
    path = seed_dir / f"{stamp}_portal_navigation_vocabulary_seed.sql"
    path.write_text(
        header + "\n".join(statements) + "\n\n" + "commit;\n", encoding="utf-8"
    )
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-root", required=True, type=Path)
    parser.add_argument("--archive-locations", required=True, type=Path)
    parser.add_argument(
        "--china-mapping",
        required=True,
        type=Path,
        help="controlled parent mapping for the Chinese province/city layer",
    )
    parser.add_argument("--contracts-dir", default="contracts/portal", type=Path)
    parser.add_argument(
        "--seed-dir",
        type=Path,
        default=None,
        help="emit the SQL seed migrations here (default: <repo>/supabase/migrations)",
    )
    parser.add_argument(
        "--seed-stamp",
        default=None,
        help="timestamp prefix for the emitted seed migrations",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed outputs instead of writing them",
    )
    parser.add_argument("--pretty", action="store_true", help="pretty-print the asset (larger)")
    arguments = parser.parse_args()

    platform_root: Path = arguments.platform_root.resolve()
    archive_locations: Path = arguments.archive_locations.resolve()
    if not platform_root.is_dir():
        raise SystemExit(f"platform root {platform_root} is not a directory")
    if not archive_locations.is_file():
        raise SystemExit(f"archive locations {archive_locations} is not a file")

    manifest = load_manifest(platform_root)
    classification_nodes, classification_receipts = build_classification_nodes(
        platform_root, manifest
    )
    geography_nodes, geography_receipts, ilcd_codes = build_geography_nodes(
        platform_root, manifest, archive_locations, arguments.china_mapping.resolve()
    )
    nodes = classification_nodes + geography_nodes
    mark_parents(nodes)

    document = {
        "schemaVersion": "portal.navigation-vocabulary.v1",
        "sourceReceipt": {
            "archiveSnapshotNote": ARCHIVE_NOTE,
            "generator": "scripts/generate_portal_navigation_vocabulary.py",
            "platformCommit": PLATFORM_COMMIT,
            "platformRepository": "tiangong-lca/platform",
            "sources": classification_receipts + geography_receipts,
        },
        "counts": {
            "classification": sum(1 for node in nodes if node.dimension == "classification"),
            "geography": sum(1 for node in nodes if node.dimension == "geography"),
            "ilcdLocationCodes": len(ilcd_codes),
            "nodes": len(nodes),
        },
        "nodes": [node.to_document() for node in sorted(nodes, key=lambda item: item.node_id)],
    }
    serialized = stable_json(document)
    asset_digest = sha256_bytes(serialized.encode("utf-8"))

    contracts_dir: Path = arguments.contracts_dir
    contracts_dir.mkdir(parents=True, exist_ok=True)
    asset_path = contracts_dir / "navigation-vocabulary.json"
    receipt_path = contracts_dir / "navigation-vocabulary.receipt.json"
    if arguments.pretty:
        asset_path.write_text(
            json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    else:
        asset_path.write_text(serialized + "\n", encoding="utf-8")
    receipt = {
        "asset": {
            "byteLength": len(serialized.encode("utf-8")),
            "path": asset_path.name,
            "sha256": asset_digest,
        },
        "counts": document["counts"],
        "schemaVersion": document["schemaVersion"],
        "sourceReceipt": document["sourceReceipt"],
    }

    if arguments.check:
        committed = asset_path.read_text(encoding="utf-8").rstrip("\n")
        if committed != serialized:
            print(
                "committed navigation-vocabulary.json is stale; re-run the generator",
                file=sys.stderr,
            )
            return 1
        committed_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if committed_receipt != receipt:
            print(
                "committed navigation-vocabulary.receipt.json is stale; re-run the generator",
                file=sys.stderr,
            )
            return 1
        print(f"navigation vocabulary is current: sha256={asset_digest}")
        return 0

    asset_path.write_text(serialized + "\n", encoding="utf-8")
    receipt_path.write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    seed_digest = sha256_bytes(
        "\n".join(
            "|".join(
                [
                    node.node_id,
                    node.parent_id or "",
                    node.code,
                    node.taxonomy,
                    node.dimension,
                    "1" if node.has_children else "0",
                    node.source_index_path or "",
                    node.source_file or "",
                    *(node.labels[locale] for locale in OUTPUT_LOCALES),
                    *(node.label_strategy[locale] for locale in OUTPUT_LOCALES),
                ]
            )
            for node in sorted(nodes, key=lambda item: item.node_id)
        ).encode("utf-8")
    )
    if arguments.seed_dir is not None:
        emit_seed_migration(
            seed_dir=arguments.seed_dir,
            stamp=arguments.seed_stamp or "20260919121000",
            nodes=sorted(nodes, key=lambda item: item.node_id),
            asset_digest=asset_digest,
            seed_digest=seed_digest,
            node_count=document["counts"]["nodes"],
        )

    print(
        f"nodes={document['counts']['nodes']} "
        f"classification={document['counts']['classification']} "
        f"geography={document['counts']['geography']} "
        f"ilcdLocations={len(ilcd_codes)} "
        f"asset_sha256={asset_digest} bytes={receipt['asset']['byteLength']} "
        f"seed_sha256={seed_digest}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
