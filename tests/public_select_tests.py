"""Public and callback execution parity, including actual zone pruning paths."""
from pathlib import Path
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'benchmarks'))
import datasets
from run_c_api_benchmark import run

binary, seed_harness, harness = [Path(p).resolve() for p in sys.argv[1:]]
with tempfile.TemporaryDirectory() as temporary:
    for compressed in (False, True):
        path = Path(temporary) / ('encoded.cdb' if compressed else 'raw.cdb')
        datasets.seed_cyboudb(binary, seed_harness, path, 10000, 'structured', compressed)
        for sql, mode, selected in (
            ('SELECT COUNT(*) FROM events WHERE amount < 0', 0, 0),
            ('SELECT COUNT(*) FROM events WHERE amount >= 15000', 0, 5000),
            ('SELECT COUNT(*) FROM events WHERE score > 90', 0, 900),
            ('SELECT id FROM events WHERE score > 50', 1, 4900),
            ('SELECT id,score,weight FROM events WHERE amount >= 15000', 1, 5000),
            ('SELECT COUNT(*) FROM events WHERE tag IS NOT NULL', 0, 8000),
        ):
            oracle = None
            for off in (0, 1):
                records = [run(harness, path, sql, 2, 0, mode, b, 1, off) for b in (0, 1)]
                assert records[0][3:6] == records[1][3:6], (sql, records)
                assert records[0][10:] == records[1][10:], (sql, records)
                assert records[0][4] == selected * 2, (sql, records[0][4])
                signature = records[0][4:6]
                if oracle is None:
                    oracle = signature
                assert signature == oracle
                if not off and 'amount < 0' in sql:
                    assert records[0][11] > 0 and records[0][14] == 0
                if not off and 'COUNT(*)' in sql and 'amount >= 15000' in sql:
                    assert records[0][11] > 0 and records[0][12] > 0
                    assert records[0][14] <= 14  # only boundary leaf, twice
            print('ok   public/internal ON/OFF parity:', compressed, sql)
