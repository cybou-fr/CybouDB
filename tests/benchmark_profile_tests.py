# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""A compressed capability must not pass the raw fixture cache gate."""
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "benchmarks"))
import datasets as ds

with tempfile.TemporaryDirectory() as temporary:
    paths = ds.db_paths(Path(temporary), "structured", 65)
    for name in ("cyboudb", "sqlite"):
        paths[name].touch()
    meta = ds.metadata("structured", 65)
    paths["meta"].write_text(json.dumps(meta))
    with patch.object(ds, "cyboudb_row_count", return_value=65), \
         patch.object(ds, "sqlite_row_count", return_value=65):
        for mask, expected in ((510, True), (1022, False), (254, False)):
            with patch.object(ds, "cyboudb_feature_mask", return_value=mask):
                assert ds.is_fixture_valid(paths, "structured", 65, Path("cyboudb"), False) == expected
        meta["storage_profile"] = "for-zone-v1"
        paths["meta"].write_text(json.dumps(meta))
        with patch.object(ds, "cyboudb_feature_mask", return_value=510):
            assert not ds.is_fixture_valid(paths, "structured", 65, Path("cyboudb"), False)
print("ok   raw cache rejects compressed masks and mismatched storage profiles")
