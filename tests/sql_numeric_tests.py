"""IEEE edge cases using exact raw bits seeded through the storage API."""
from pax_support import *

with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / 'numeric.cdb'
    batch = pathlib.Path(directory) / 'batch.bin'
    initial = seed(path, [1, 3], [0, 1], command='create-pax-multi')
    schema = graph(initial)[2]
    table = initial[schema * P + 64:schema * P + 96].split(b'\0')[0].decode()
    # Quiet/signaling NaN, infinities, signed zeros, min subnormal, rounded
    # decimal, exact halfway neighbors, and max finite binary32.
    bits = [0x7fc12345, 0x7f812345, 0x7f800000, 0xff800000,
            0, 0x80000000, 1, 0x3dfcd6ea, 0x3f800000, 0x3f800002,
            0x7f7fffff, 0]
    fixture(batch, [[i, value] for i, value in enumerate(bits)],
            [[0, int(i == 11)] for i in range(len(bits))])
    run(harness, path, 40, 1, 0, batch)

    def query(name, predicate, expected):
        sql = f'SELECT c0 FROM {table} WHERE {predicate}'
        output = run(binary, 'query', path, sql).decode().splitlines()
        assert output[2:-1] == list(map(str, expected)), (sql, output, expected)
        check(name)

    for op in ['=', '!=', '<', '<=', '>', '>=']:
        # Both NaNs are non-NULL and unordered even for !=. NOT must produce
        # TRUE, distinguishing unordered FALSE from SQL UNKNOWN.
        query(f'NaN {op}', f'c0 < 2 AND c1 {op} 0.0', [])
        query(f'NOT NaN {op}', f'c0 < 2 AND NOT(c1 {op} 0.0)', [0, 1])
        query(f'NULL {op}', f'c0 = 11 AND NOT(c1 {op} 0.0)', [])
    query('NaN is not NULL', 'c0 < 2 AND c1 IS NOT NULL', [0, 1])
    query('positive infinity', 'c1 > 340282346638528859811704183484516925440.0', [2])
    query('negative infinity', 'c1 < -340282346638528859811704183484516925440.0', [3])
    query('signed zero', 'c1 = -0.0', [4, 5])
    query('minimum subnormal', 'c1 = 0.' + '0' * 44 + '1', [6])
    query('underflow to zero', 'c1 = -0.' + '0' * 60 + '1', [4, 5])
    query('long fraction', 'c1 = 0.123456789012345678901234567890', [7])
    query('halfway rounds down to even', 'c1 = 1.000000059604644775390625', [8])
    query('halfway rounds up to even', 'c1 = 1.000000178813934326171875', [9])
    query('max finite', 'c1 = 340282346638528859811704183484516925440.0', [10])
    run(binary, 'check', path)
print(f'SQL numeric suite: {check_count()} passed')
