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
    alias_codes: list[str] = field(default_factory=list)

    def to_document(self) -> dict[str, object]:
        return {
            "aliasCodes": list(self.alias_codes),
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
    ilcd_names: dict[str, str] = {}
    ilcd_parents: dict[str, str | None] = {}
    for entry in category_children(base["ILCDLocations"]["location"]):
        code = (entry.get("@value") or "").strip()
        if not code or code.upper() == "NULL":
            # The literal NULL row carries no usable location code.
            continue
        upper = code.upper()
        ilcd_codes.add(upper)
        ilcd_names[upper] = (entry.get("#text") or "").strip()
        parts = upper.split("-")
        parent = "-".join(parts[:-1]) if len(parts) > 1 else None
        ilcd_parents[upper] = parent if parent and parent in ilcd_names else None

    # A code that addresses a lower administrative level than its own row states
    # is only accepted when the deeper row exists and repeats the parent name.
    for code, parent in sorted(ilcd_parents.items()):
        if parent is None or len(code.split("-")) < 3:
            continue
        parent_core = ilcd_names.get(parent, "").replace(",China", "").strip()
        if parent_core and parent_core not in ilcd_names[code]:
            raise SystemExit(
                f"location {code} does not name its parent {parent}: {ilcd_names[code]!r}"
            )

    for code in sorted(ilcd_codes):
        labels = {"en": ilcd_names[code]}
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
                parent_id=(
                    f"geo:{ilcd_parents[code].lower()}"
                    if ilcd_parents[code] is not None
                    else None
                ),
                code=code,
                taxonomy="ilcd-locations",
                dimension="geography",
                labels=labels,
                label_strategy=strategy,
                source_index_path=f"location:{code}",
                source_file="src/services/referenceResources/data/ilcd-locations/base.json",
            )
        )
    by_code = {node.code: node for node in nodes if node.dimension == "geography"}

    def cn_levels(node: Node) -> list[str]:
        """The Chinese name split into administrative levels, deepest last.

        The pinned labels read `China, <province>, <city>`; the archive names the
        same levels in the same order.
        """
        value = node.labels.get("zh-CN") or ""
        return [part.strip() for part in value.split(",") if part.strip()]

    suffix_re = re.compile(
        r"(壮族|回族|苗族|彝族|藏族|蒙古族|土家族|布依族|侗族|白族|傣族|景颇族|傈僳族|哈尼族|"
        r"哈萨克|柯尔克孜|朝鲜族|羌族|纳西族|拉祜族|佤族|畲族|黎族|瑶族|水族|仡佬族|锡伯族|"
        r"自治州|自治县|自治旗|地区|林区|盟|州|市|县|区)+$"
    )

    def core_name(value: str) -> str:
        return suffix_re.sub("", (value or "").strip())

    def pinyin_tokens(code_segment: str) -> list[str]:
        """The archive code's Latin initials, longest first.

        `CXD` addresses `楚雄彝族自治州`; the initials alone cannot decide which
        prefix of the Chinese name they spell, so the longest prefix that the
        Chinese name actually starts with is the candidate, and an ambiguous
        match is refused rather than guessed.
        """
        segment = code_segment.strip().lower()
        return [
            segment[:length] for length in range(len(segment), 0, -1)
        ]

    def local_match_rank(node: Node, local: str, code_segment: str | None) -> int:
        """How strongly one canonical node matches an archive entry, 0 = no match.

        Ranking instead of a boolean is what makes this safe: when two
        prefectures share a short initialism the code alone cannot decide, so the
        caller keeps the strongest and requires it to be unique.
        """
        levels = cn_levels(node)
        current = levels[-1] if levels else ""
        if not current:
            return 0
        if local == current:
            return 100
        core = core_name(current)
        if local == core:
            return 95
        if local in current or current in local:
            return 90
        if core and (core in local or local in core):
            return 85
        if code_segment:
            folded = code_segment.strip().lower()
            # An initialism that the Chinese core name starts with, preferring
            # the longest run of matching initial characters.
            matched = 0
            for index, character in enumerate(core.lower()):
                if index >= len(folded) or character != folded[index]:
                    break
                matched += 1
            if matched >= 2:
                return 70 + matched
        return 0

    # Archive layer. Its codes are the ones the datasets actually author, and the
    # pinned vocabulary carries the same administrative units under its own
    # `CN-XX` spelling, so each archive code becomes an alias on the canonical
    # node instead of a second parallel tree.
    archive_digest, archive_length = sha256_file(archive_locations)
    mapping = read_json(china_mapping_path)
    mapping_sources = [
        source
        for source in mapping.get("sources", [])
        if source.get("sha256") == archive_digest
    ]
    if len(mapping_sources) != 1:
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

    nodes.append(
        virtual_node(
            f"geo:{country_node.lower()}:unmapped",
            "~",
            "database-virtual",
            "geography",
            {
                "en": "Unplaced China codes",
                "zh-CN": "未归位的中国地区编码",
                "de": "Nicht zugeordnete China-Codes",
                "fr": "Codes chinois non placés",
            },
        )
    )
    nodes[-1].parent_id = f"geo:{country_node.lower()}"

    archive_text = archive_locations.read_text(encoding="utf-8")
    archive_entries = dict(
        re.findall(r'<location[^>]*value="([^"]*)"[^>]*>([^<]*)</location>', archive_text)
    )
    canonical_cn = {
        code: node for code, node in by_code.items() if code.startswith("CN-")
    }
    for raw_code, raw_name in sorted(archive_entries.items()):
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
        local = chinese_segments[0].strip()
        # The archive abbreviates provinces differently from the pinned
        # vocabulary (Inner Mongol is `NMG-CN` there and `CN-NM` here) and even
        # reuses letters in a different order (`HB` is Hubei there, Hebei here),
        # so a code segment is never treated as a province. The province is
        # resolved by its Chinese name and the city is then matched inside it.
        province_parent = f"geo:{country_node.lower()}"
        province_target = local if len(segments) == 1 else chinese_segments[1].strip()
        province_ranked = sorted(
            (
                (local_match_rank(node, province_target, None), node)
                for node in canonical_cn.values()
                if node.parent_id == province_parent
            ),
            key=lambda entry: (-entry[0], entry[1].node_id),
        )
        province_ranked = [entry for entry in province_ranked if entry[0] > 0]
        if len(province_ranked) != 1 or province_ranked[0][0] != province_ranked[-1][0]:
            candidates = []
        elif len(segments) == 1:
            candidates = [province_ranked[0][1]]
        else:
            province_node = province_ranked[0][1]
            child_ranked = sorted(
                (
                    (local_match_rank(node, local, segments[0]), node)
                    for node in canonical_cn.values()
                    if node.parent_id == province_node.node_id
                ),
                key=lambda entry: (-entry[0], entry[1].node_id),
            )
            child_ranked = [entry for entry in child_ranked if entry[0] > 0]
            if len(child_ranked) == 1 or (
                len(child_ranked) > 1 and child_ranked[0][0] > child_ranked[1][0]
            ):
                candidates = [child_ranked[0][1]]
            else:
                candidates = []
        import os as _os
        if _os.environ.get("NAV_DEBUG") and code in _os.environ["NAV_DEBUG"].split(","):
            import sys as _sys
            print(f"DEBUG {code}: segs={segments} local={local!r} province_target={province_target!r} "
                  f"province_matches={[n.node_id for n in province_matches]} "
                  f"candidates={[n.node_id for n in candidates]}", file=_sys.stderr)
        if len(candidates) == 1:
            node = candidates[0]
            if code in node.alias_codes:
                continue
            node.alias_codes.append(code)
            node.alias_codes.sort()
            if not node.labels["zh-CN"] and local:
                node.labels["zh-CN"] = local
                node.label_strategy["zh-CN"] = LABEL_STRATEGY_ARCHIVE
            continue
        # No unique canonical counterpart: keep the authored code addressable as
        # its own raw node under the country it belongs to rather than attaching
        # it to a guessed city.
        raw_id = f"geo:~{sha256_bytes(f'geo|{code}'.encode())[:16]}"
        nodes.append(
            Node(
                node_id=raw_id,
                parent_id=f"geo:{country_node.lower()}:unmapped",
                code=code,
                taxonomy="unmapped",
                dimension="geography",
                labels={"en": "", "zh-CN": local, "de": "", "fr": ""},
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


def sql_array(values: list[str]) -> str:
    if not values:
        return "'{}'::text[]"
    return "array[" + ",".join(sql_text(value) for value in values) + "]::text[]"


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
            "source_index_path,source_file,alias_codes,labels,label_strategy"
            ") values ("
            f"{sql_text(node.node_id)},{sql_text(node.parent_id) if node.parent_id else 'null'},"
            f"{sql_text(node.code)},{sql_text(node.taxonomy)},{sql_text(node.dimension)},"
            f"{sql_text(node.source_index_path) if node.source_index_path else 'null'},"
            f"{sql_text(node.source_file) if node.source_file else 'null'},"
            f"{sql_array(node.alias_codes)},"
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
                    ",".join(sorted(node.alias_codes)),
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
