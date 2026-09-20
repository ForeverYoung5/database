#!/usr/bin/env python3
"""Static proof for the versioned Portal navigation revisions.

The bootstrap seed is applied history. These checks fail when a later revision
would rewrite it, when a revision stops touching exactly the reviewed rows, or
when the reviewed GeoAtlas evidence stops stating the parent it was accepted on.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    revisions = read_json(ROOT / "data/portal-navigation-revisions.json")
    administrative = read_json(ROOT / "data/portal-navigation-china-administrative.json")
    revision = revisions["revisions"][-1]

    # 1. Applied history stays byte-identical.
    historical = revisions["historicalSeed"]
    seed_path = ROOT / "supabase/migrations" / Path(historical["file"]).name
    seed_bytes = seed_path.read_bytes()
    if digest(seed_bytes) != historical["sha256"] or len(seed_bytes) != historical["byteLength"]:
        fail("the historical bootstrap seed no longer matches its pinned bytes")

    # 2. The revision touches exactly the reviewed rows and never reseeds.
    migration_path = ROOT / "supabase/migrations" / Path(revision["file"]).name
    if not migration_path.exists():
        fail(f"revision migration is missing: {migration_path}")
    sql = migration_path.read_text(encoding="utf-8")
    bindings = administrative["bindings"]
    expected_ids = sorted(binding["nodeId"] for binding in bindings)
    if len(bindings) != 3:
        fail(f"the administrative evidence must bind exactly 3 locations, found {len(bindings)}")

    update = re.search(r"update private\.portal_navigation_node_v1 as node(.*?);", sql, re.S)
    if update is None:
        fail("revision carries no node update")
    # Read the predicate, not the SET target: the target is the country the rows
    # move under, and only the `where ... in (...)` list says which rows move.
    predicate = re.search(r"where node\.node_id in \(([^)]*)\)", update.group(1))
    if predicate is None:
        fail("revision update carries no explicit row predicate")
    updated = sorted(set(re.findall(r"'(geo:[a-z-]+)'", predicate.group(1))))
    if updated != expected_ids:
        fail(f"revision updates {updated}, expected {expected_ids}")
    if "insert into private.portal_navigation_node_v1" in sql:
        fail("revision must never seed or re-create a vocabulary node")
    for required in (
        "disable trigger portal_navigation_seed_guard_v1",
        "enable trigger portal_navigation_seed_guard_v1",
        "lock table private.portal_navigation_versions_v1 in share row exclusive mode",
        "on conflict (dataset_kind, id, version, dimension, node_id) do nothing",
        "perform private.assert_portal_navigation_contract_v1();",
    ):
        if required not in sql:
            fail(f"revision is missing: {required}")
    if sql.index("lock table") > sql.index("update private.portal_navigation_node_v1"):
        fail("the writer lock must be taken before the hierarchy changes")
    if sql.index("disable trigger") > sql.index("enable trigger"):
        fail("the seed guard must be restored in the same transaction")
    for pinned in (revision["priorAssetSha256"], revision["priorSeedSha256"]):
        if pinned not in sql:
            fail(f"revision does not assert the prior manifest hash {pinned}")

    # 3. The reviewed evidence still states the parent the binding was accepted on.
    source = administrative["source"]
    # The vendored artifact is the compressed input the generator materialises; the
    # receipt pins the decompressed bytes it was accepted on.
    evidence_path = (
        ROOT / "data/portal-navigation-sources/geoatlas" / f"{source['id']}.geojson.gz"
    )
    receipt = read_json(ROOT / "data/portal-navigation-sources/receipt.json")
    geoatlas = receipt["geoatlas"]
    if geoatlas["id"] != source["id"] or geoatlas["sha256"] != source["rawSha256"]:
        fail("the vendored GeoAtlas receipt disagrees with the administrative evidence")
    evidence_bytes = gzip.decompress(evidence_path.read_bytes())
    if digest(evidence_bytes) != source["rawSha256"] or len(evidence_bytes) != source["rawBytes"]:
        fail("the vendored GeoAtlas evidence drifted from its receipt")
    features = {}
    for feature in json.loads(evidence_bytes)["features"]:
        properties = feature.get("properties") or {}
        features.setdefault(properties.get("adcode"), []).append(properties)
    for binding in bindings:
        matches = features.get(binding["adcode"], [])
        if len(matches) != 1:
            fail(f"GeoAtlas evidence must state adcode {binding['adcode']} exactly once")
        feature = matches[0]
        if (
            feature.get("name") != binding["name"]
            or feature.get("level") != binding["level"]
            or (feature.get("parent") or {}).get("adcode") != 100000
        ):
            fail(f"GeoAtlas evidence for {binding['adcode']} no longer states the reviewed parent")

    # 4. The committed vocabulary carries the revision and nothing else moved.
    vocabulary = read_json(ROOT / "contracts/portal/navigation-vocabulary.json")
    nodes = {node["nodeId"]: node for node in vocabulary["nodes"]}
    if vocabulary["counts"]["nodes"] != historical["nodeCount"]:
        fail("the revision must not add or remove vocabulary nodes")
    for binding in bindings:
        node = nodes.get(binding["nodeId"])
        if node is None:
            fail(f"vocabulary is missing {binding['nodeId']}")
        if node["parentNodeId"] != administrative["countryNodeId"]:
            fail(f"{binding['nodeId']} is not a child of {administrative['countryNodeId']}")
        if node["code"] != binding["code"] or node["taxonomy"] != "ilcd-locations":
            fail(f"{binding['nodeId']} changed identity: {node['code']} {node['taxonomy']}")
        if not node["labels"]["en"] or not node["labels"]["zh-CN"]:
            fail(f"{binding['nodeId']} lost a reviewed label")
    bound_codes = [node["code"] for node in vocabulary["nodes"] if node["code"] in {"TW", "HK", "MO"}]
    if sorted(bound_codes) != sorted(binding["code"] for binding in bindings):
        fail("another node claims a TW/HK/MO code")
    country = nodes.get(administrative["countryNodeId"])
    if country is None or country["code"] != administrative["countryCode"]:
        fail("the country node named by the evidence is absent")

    print(
        "portal navigation revisions are consistent: "
        f"seed={historical['sha256'][:12]} revision={revision['id']} bindings={expected_ids}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
