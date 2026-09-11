# =============================================================================
#  tests/vector_sql_tests.py - SQL Vector Type & Storage Extents Test Suite
# =============================================================================

import os
import subprocess
import sys

CYBOUDB_EXE = os.path.join(os.path.dirname(__file__), '..', 'cyboudb.exe')
DB_PATH = 'test_vector_suite.cdb'
DB_NON_LARGE = 'test_vector_non_large.cdb'

failed_tests = 0
passed_tests = 0


def cleanup():
    for path in [DB_PATH, DB_NON_LARGE]:
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass


def run_cmd(args, stdin_input=None):
    return subprocess.run(
        [CYBOUDB_EXE] + args,
        input=stdin_input,
        capture_output=True,
        text=True
    )


def test(name, condition, detail=""):
    global failed_tests, passed_tests
    if condition:
        print(f"ok   {name}")
        passed_tests += 1
    else:
        print(f"FAIL {name}: {detail}")
        failed_tests += 1


def main():
    cleanup()

    # 1. Reject vector in non-large database (lacking CybouDB_FEATURE_VECTOR)
    res = run_cmd(['create-pax-multi', DB_NON_LARGE, '256', '--force'])
    test('create_non_large_db', res.returncode == 0, res.stderr)

    res = run_cmd(['query', DB_NON_LARGE, 'CREATE TABLE v (e VECTOR(FLOAT32, 3));'])
    test('vector_rejected_without_feature',
         res.returncode == 2 and 'VECTOR storage extents are not implemented yet' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    # 2. Create large database (with CybouDB_FEATURE_VECTOR)
    res = run_cmd(['create-large', DB_PATH, '512', '--force'])
    test('create_large_db', res.returncode == 0, res.stderr)

    # 3. Create table with VECTOR column
    res = run_cmd(['query', DB_PATH, 'CREATE TABLE items (id INT64 NOT NULL, emb VECTOR(FLOAT32, 3));'])
    test('create_vector_table', res.returncode == 0 and 'Table created.' in res.stdout, res.stdout)

    # 4. REPL .schema rendering
    res = run_cmd([DB_PATH], stdin_input='.schema items\n.quit\n')
    test('repl_schema_vector',
         res.returncode == 0 and 'emb  VECTOR(FLOAT32, 3)' in res.stdout,
         res.stdout)

    # 5. Insert valid vector literals
    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (1, [1.0, 2.0, 3.0]);'])
    test('insert_vector_basic', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (2, [-1.5, 0.0, 2.25]);'])
    test('insert_vector_negative_floats', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (3, NULL);'])
    test('insert_vector_null', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (4, [0.0, 0.0, 0.0]), (5, [10.0, 20.0, 30.0]);'])
    test('insert_vector_multi_row', res.returncode == 0 and 'INSERT 2' in res.stdout, res.stdout)

    # 6. Select vector columns
    res = run_cmd(['query', DB_PATH, 'SELECT id, emb FROM items;'])
    expected_rows = [
        '1 | [1.00, 2.00, 3.00]',
        '2 | [-1.50, 0.00, 2.25]',
        '3 | NULL',
        '4 | [0.00, 0.00, 0.00]',
        '5 | [10.00, 20.00, 30.00]',
    ]
    all_rows_present = all(r in res.stdout for r in expected_rows)
    test('select_vector_rows', res.returncode == 0 and all_rows_present and '(5 rows)' in res.stdout, res.stdout)

    # 7. Filter on NULL / IS NOT NULL
    res = run_cmd(['query', DB_PATH, 'SELECT id FROM items WHERE emb IS NULL;'])
    test('where_vector_is_null', res.returncode == 0 and '3' in res.stdout and '(1 row)' in res.stdout, res.stdout)

    res = run_cmd(['query', DB_PATH, 'SELECT id FROM items WHERE emb IS NOT NULL;'])
    test('where_vector_is_not_null', res.returncode == 0 and '(4 rows)' in res.stdout, res.stdout)

    # 8. Dimension mismatch rejection
    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (6, [1.0, 2.0]);'])
    test('vector_dim_mismatch_too_few',
         res.returncode == 2 and 'type mismatch' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (7, [1.0, 2.0, 3.0, 4.0]);'])
    test('vector_dim_mismatch_too_many',
         res.returncode == 2 and 'type mismatch' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    # 9. Empty vector literal rejection
    res = run_cmd(['query', DB_PATH, 'INSERT INTO items VALUES (8, []);'])
    test('vector_empty_literal_rejected',
         res.returncode == 2 and 'syntax error' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    # 10. Dimension range limits
    res = run_cmd(['query', DB_PATH, 'CREATE TABLE v0 (e VECTOR(FLOAT32, 0));'])
    test('vector_dim_zero_rejected',
         res.returncode == 2 and 'syntax error' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    res = run_cmd(['query', DB_PATH, 'CREATE TABLE v_big (e VECTOR(FLOAT32, 4097));'])
    test('vector_dim_too_large_rejected',
         res.returncode == 2 and 'syntax error' in res.stdout,
         f"rc={res.returncode}, out={res.stdout}")

    # 11. Multi-page vector extent chain (dimension 1024 spans 2 pages)
    res = run_cmd(['query', DB_PATH, 'CREATE TABLE multi_page_vec (id INT64 NOT NULL, emb VECTOR(FLOAT32, 1024));'])
    test('create_multi_page_vec_table', res.returncode == 0, res.stdout)

    lines = []
    for i in range(0, 1024, 64):
        chunk = [f'{x}.0' for x in range(i + 1, i + 65)]
        lines.append(', '.join(chunk))
    floats = ',\n'.join(lines)
    sql = f'INSERT INTO multi_page_vec VALUES (100, [\n{floats}\n]);\nSELECT id, emb FROM multi_page_vec;\n.quit\n'

    res = run_cmd([DB_PATH], stdin_input=sql)
    test('multi_page_vector_insert_and_select',
         res.returncode == 0 and 'INSERT 1' in res.stdout and '100 | [1.00, 2.00,' in res.stdout and '1024.00]' in res.stdout,
         res.stdout[:200])

    # 12. Database integrity check via cyboudb check
    res = run_cmd(['check', DB_PATH])
    test('vector_database_check', res.returncode == 0 and 'Status:          OK' in res.stdout, res.stdout)

    cleanup()

    print(f"\nVector SQL test suite: {passed_tests} passed, {failed_tests} failed")
    sys.exit(0 if failed_tests == 0 else 1)


if __name__ == '__main__':
    main()
