"""Paired internal/public SELECT measurements using the identical C consumer."""
import argparse
import json
from pathlib import Path
import statistics
import struct
import subprocess


def run(harness, db, sql, iterations, warmup, mode, backend, trace=0, off=0):
    p = subprocess.run([str(harness), str(db), sql, str(iterations), str(warmup),
                        str(mode), str(backend), str(trace), str(off)],
                       capture_output=True, check=True)
    assert len(p.stdout) == 128, p.stderr
    record = struct.unpack('<16Q', p.stdout)
    assert record[0] == 0, record
    return record


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('database', type=Path)
    p.add_argument('--harness', type=Path, required=True)
    p.add_argument('--rows', type=int, default=10_000_000)
    p.add_argument('--iterations', type=int, default=50)
    p.add_argument('--repeats', type=int, default=7)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--scenario', choices=('count_half', 'count_unknown', 'project_id', 'project_half'))
    args = p.parse_args()
    scenarios = [('count_half', f'SELECT COUNT(*) FROM events WHERE amount >= {args.rows // 2 * 3}', 0),
                 ('count_unknown', 'SELECT COUNT(*) FROM events WHERE score > 90', 0),
                 ('project_id', 'SELECT id FROM events WHERE score > 50', 1),
                 ('project_half', f'SELECT id,score,weight FROM events WHERE amount >= {args.rows // 2 * 3}', 1)]
    results = []
    for name, sql, mode in scenarios:
        if args.scenario and args.scenario != name:
            continue
        times = [[], []]
        reference = None
        for repeat in range(args.repeats):
            for backend in (repeat % 2, 1 - repeat % 2):
                record = run(args.harness.resolve(), args.database.resolve(), sql,
                             args.iterations, 3, mode, backend)
                signature = record[3:6]
                if reference is None:
                    reference = signature
                assert signature == reference, (name, backend, signature, reference)
                times[backend].append(record[6] / args.iterations / args.rows)
        diag = [run(args.harness.resolve(), args.database.resolve(), sql, 1, 0, mode, b, 1)
                for b in (0, 1)]
        assert diag[0][10:] == diag[1][10:], (name, diag)
        public, internal = map(statistics.median, times)
        row = dict(name=name, sql=sql, public_ns_per_row=public, internal_ns_per_row=internal,
                   ratio=public / internal, gate_pass=public / internal < 1.05,
                   public_samples=times[0], internal_samples=times[1],
                   selected_rows=reference[1] // args.iterations, zone_trace=diag[0][10:])
        results.append(row)
        print(name, f'public/internal={row["ratio"]:.4f}', row['zone_trace'], flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(rows=args.rows, repeats=args.repeats,
                                          iterations=args.iterations, results=results), indent=2)+'\n')
    return 0 if all(r['gate_pass'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
