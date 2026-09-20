"""Exact-commit, offline inputs for the Portal navigation generator."""
from __future__ import annotations
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

SOURCE_COMMIT='aca2d4f2a905e97867942a78be75c5daea4fde5e'
RESOURCE_ROOT='src/services/referenceResources'
SOURCE_PATHS=[f'{RESOURCE_ROOT}/reference-resource-manifest.json']+[
    f'{RESOURCE_ROOT}/data/{resource}/{file}'
    for resource in ['isic','cpc','ilcd-flow-categorization','ilcd-locations']
    for file in ['base.json','overlays/zh.json','overlays/de.json','overlays/fr.json']
]
# Administrative parent evidence for China's TW/HK/MO. GeoAtlas states the parent
# adcode inside each feature (`parent.adcode`), so parenthood is read from the
# data rather than inferred from a code shape. The bytes are pinned to the same
# platform commit as the resources above; `lastModifiedCommit` is the commit that
# last touched the path, recorded so a refresh can tell the two apart.
GEOATLAS_PATH='public/maps/china-province-100000-full.geojson'
GEOATLAS_SOURCE={
    'id':'china-province-100000-full',
    'platformPath':GEOATLAS_PATH,
    'lastModifiedCommit':'6c5d02f5cad6a864e290d16b3ce6d3a62c91247b',
    'lastModifiedDate':'2026-05-20',
    'origin':'https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json',
    'upstream':'Aliyun DataV.GeoAtlas province-level boundaries for 100000, vendored into tiangong-lca/platform',
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_live(platform: Path) -> None:
    for path in SOURCE_PATHS+[GEOATLAS_PATH]:
        expected=subprocess.check_output(['git','-C',str(platform),'show',f'{SOURCE_COMMIT}:{path}'])
        if (platform/path).read_bytes()!=expected:
            raise ValueError(f'Input differs from pinned platform commit: {path}')


def vendor(destination: Path, platform: Path, archive: Path) -> None:
    verify_live(platform)
    files=[]
    for path in SOURCE_PATHS:
        data=(platform/path).read_bytes()
        target=f'platform/{path}.gz'
        output=destination/target;output.parent.mkdir(parents=True,exist_ok=True)
        output.write_bytes(gzip.compress(data,mtime=0))
        files.append({'path':target,'sha256':digest(data)})
    geoatlas=(platform/GEOATLAS_PATH).read_bytes()
    target=f'geoatlas/{GEOATLAS_SOURCE["id"]}.geojson.gz'
    output=destination/target;output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(gzip.compress(geoatlas,mtime=0))
    files.append({'path':target,'sha256':digest(geoatlas)})
    archive_root=Path(subprocess.check_output(['git','-C',str(archive.parent),'rev-parse','--show-toplevel'],text=True).strip())
    archive_commit=subprocess.check_output(['git','-C',str(archive_root),'rev-parse','HEAD'],text=True).strip()
    archive_path=str(archive.relative_to(archive_root))
    data=archive.read_bytes()
    expected=subprocess.check_output(['git','-C',str(archive_root),'show',f'{archive_commit}:{archive_path}'])
    if data!=expected: raise ValueError('Archive source has uncommitted changes')
    output=destination/'archive/ILCDLocations.xml.gz';output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(gzip.compress(data,mtime=0));files.append({'path':'archive/ILCDLocations.xml.gz','sha256':digest(data)})
    receipt={'platformCommit':SOURCE_COMMIT,'geoatlas':{**GEOATLAS_SOURCE,'byteLength':len(geoatlas),'sha256':digest(geoatlas)},
             'archiveRepository':'tiangong-lca/data','archiveCommit':archive_commit,'archivePath':archive_path,'files':files}
    (destination/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')


def materialize(source: Path, destination: Path) -> tuple[Path,Path,Path]:
    receipt=json.loads((source/'receipt.json').read_text())
    if receipt['platformCommit']!=SOURCE_COMMIT: raise ValueError('Pinned source commit changed')
    expected={f'platform/{path}.gz' for path in SOURCE_PATHS}|{'archive/ILCDLocations.xml.gz',f'geoatlas/{GEOATLAS_SOURCE["id"]}.geojson.gz'}
    actual={file['path'] for file in receipt['files']}
    if actual!=expected or len(actual)!=len(receipt['files']): raise ValueError('Source inventory differs')
    for file in receipt['files']:
        data=gzip.decompress((source/file['path']).read_bytes())
        if digest(data)!=file['sha256']: raise ValueError(f"Source drift: {file['path']}")
        path=destination/file['path'][:-3];path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    geoatlas_file=destination/f'geoatlas/{GEOATLAS_SOURCE["id"]}.geojson'
    if digest(geoatlas_file.read_bytes())!=receipt['geoatlas']['sha256']:
        raise ValueError('GeoAtlas administrative evidence drifted')
    return destination/'platform',destination/'archive/ILCDLocations.xml',geoatlas_file
