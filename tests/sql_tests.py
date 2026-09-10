#!/usr/bin/env python3
"""Portable SQL regression suite. Run: python tests/sql_tests.py [binary]."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ("cyboudb.exe" if os.name == "nt" else "cyboudb")
passed = 0
failed = 0


def invoke(*args):
    return subprocess.run([str(BINARY), *map(str, args)], capture_output=True,
                          text=True, timeout=30)


def check(name, sql, rc=0, message=None, rows=None):
    global passed, failed
    result = invoke("query", database, sql)
    problems = []
    if result.returncode != rc:
        problems.append(f"exit {result.returncode}, expected {rc}")
    if message is not None and message not in result.stdout + result.stderr:
        problems.append(f"missing diagnostic {message!r}")
    if rc == 0 and result.stderr:
        problems.append(f"unexpected stderr: {result.stderr!r}")
    if rows is not None:
        lines = result.stdout.splitlines()
        expected = [" | ".join(map(str, row)) for row in rows]
        footer = f"({len(rows)} {'row' if len(rows) == 1 else 'rows'})"
        if len(lines) != len(expected) + 3 or lines[2:-1] != expected or lines[-1:] != [footer]:
            problems.append(f"expected ordered rows {expected!r} and {footer!r}")
    if problems:
        failed += 1
        print(f"FAIL {name}: {'; '.join(problems)}\nSQL: {sql}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}")
    else:
        passed += 1
        print(f"ok   {name}")


def run():
    check('create_table', 'CREATE TABLE users ( id INT64 NOT NULL, age INT32, active BOOL NOT NULL, score FLOAT32 )', rc=0, message='Table created')
    check('create_type_aliases', 'CREATE TABLE aliases (i INTEGER, b BIGINT, r REAL, ok BOOLEAN)', rc=0, message='Table created')
    check('insert_type_aliases', 'INSERT INTO aliases VALUES (-7, 9000000000, 1.5, TRUE)', rc=0, message='INSERT 1')
    check('select_type_aliases', 'SELECT i,b,r,ok FROM aliases', rc=0, rows=[(-7, 9000000000, '1.50', 'TRUE')])
    check('insert_join_aliases',
          'INSERT INTO aliases VALUES (25,10,2.5,FALSE),(40,11,3.5,TRUE),(40,12,4.5,FALSE)',
          rc=0, message='INSERT 3')
    check('reserved_update_keyword', 'CREATE TABLE reserved_kw (update INT32)', rc=2, message='expected column name')
    check('vector_type_reserved_not_stored', 'CREATE TABLE vector_decl (embedding VECTOR(FLOAT32, 3))', rc=2, message='expected column data type')
    check('create_duplicate_table', 'CREATE TABLE users ( x INT32 )', rc=2, message='table already exists')
    check('create_duplicate_case', 'CREATE TABLE USERS ( x INT32 )', rc=2, message='table already exists')
    check('insert_valid_rows', 'INSERT INTO users VALUES (1, 25, TRUE, 10.5), (2, NULL, FALSE, 99.5), (3, 40, TRUE, 75.0), (4, -15, TRUE, -5.25)', rc=0, message='INSERT 4')
    check('insert_null_into_not_null', 'INSERT INTO users VALUES (NULL, 30, TRUE, 0.0)', rc=2, message='cannot insert NULL into non-nullable column')
    check('insert_type_mismatch_float', 'INSERT INTO users VALUES (5, 3.14, TRUE, 0.0)', rc=2, message='type mismatch')
    check('insert_int32_overflow', 'INSERT INTO users VALUES (6, 3000000000, TRUE, 0.0)', rc=2, message='type mismatch')
    check('verify_rollback_after_failed_inserts', 'SELECT id FROM users', rc=0, rows=[(1,), (2,), (3,), (4,)])
    check('select_all', 'SELECT * FROM users', rc=0, rows=[(1, 25, 'TRUE', '10.50'), (2, 'NULL', 'FALSE', '99.50'), (3, 40, 'TRUE', '75.00'), (4, -15, 'TRUE', '-5.25')])
    check('select_columns', 'SELECT id, age FROM users', rc=0, rows=[(1, 25), (2, 'NULL'), (3, 40), (4, -15)])
    check('select_case_insensitive', 'SELECT ID, AGE FROM USERS', rc=0, rows=[(1, 25), (2, 'NULL'), (3, 40), (4, -15)])
    check('select_alias_as', 'SELECT id FROM users AS u WHERE age > 30', rc=0, rows=[(3,)])
    check('select_alias_bare', 'SELECT id FROM users u WHERE age > 30', rc=0, rows=[(3,)])
    check('select_qualified_table',
          'SELECT users.id FROM users WHERE users.age > 30', rc=0, rows=[(3,)])
    check('select_qualified_alias_as',
          'SELECT u.id FROM users AS u WHERE u.age > 30', rc=0, rows=[(3,)])
    check('select_qualified_alias_bare',
          'SELECT u.id FROM users u WHERE u.age > 30', rc=0, rows=[(3,)])
    check('select_wrong_projection_namespace',
          'SELECT nope.id FROM users', rc=2, message='column not found in schema')
    check('select_wrong_where_namespace',
          'SELECT id FROM users WHERE nope.age > 30', rc=2,
          message='column not found in schema')
    check('select_alias_hides_table_name',
          'SELECT users.id FROM users AS u', rc=2,
          message='column not found in schema')
    # JOIN execution is a correctness-first nested loop over qualified integer
    # equi-keys. Without ORDER BY, these checks intentionally assert the
    # producer's deterministic batch order as an additional regression guard.
    check('join_ast_plain',
          'SELECT u.id FROM users u JOIN aliases a ON u.age = a.i', rc=0,
          rows=[(1,), (3,), (3,)])
    check('join_ast_inner',
          'SELECT u.id FROM users AS u INNER JOIN aliases AS a ON u.age = a.i',
          rc=0, rows=[(1,), (3,), (3,)])
    check('join_ast_left',
          'SELECT u.id,a.b FROM users u LEFT JOIN aliases a ON u.age = a.i',
          rc=0, rows=[(1,10), (3,11), (3,12), (2,'NULL'), (4,'NULL')])
    check('join_left_lhs_projection',
          'SELECT u.id FROM users u LEFT JOIN aliases a ON u.age = a.i', rc=0,
          rows=[(1,), (3,), (3,), (2,), (4,)])
    check('join_requires_on',
          'SELECT u.id FROM users u JOIN aliases a', rc=2)
    check('join_resolves_right_table',
          'SELECT u.id FROM users u JOIN missing_join m ON u.id = m.id', rc=2,
          message='table not found in catalog')
    check('join_requires_equality',
          'SELECT u.id FROM users u JOIN aliases a ON u.id > a.i', rc=2,
          message='JOIN ON currently requires column = column')
    check('join_requires_two_columns',
          'SELECT u.id FROM users u JOIN aliases a ON u.id = 1', rc=2,
          message='JOIN ON currently requires column = column')
    check('join_reversed_key_order',
          'SELECT u.id FROM users u JOIN aliases a ON a.i = u.age', rc=0,
          rows=[(1,), (3,), (3,)])
    check('join_unknown_namespace',
          'SELECT u.id FROM users u JOIN aliases a ON nope.age = a.i', rc=2,
          message='column not found in schema')
    check('join_missing_key_column',
          'SELECT u.id FROM users u JOIN aliases a ON u.missing = a.i', rc=2,
          message='column not found in schema')
    check('join_key_type_mismatch',
          'SELECT u.id FROM users u JOIN aliases a ON u.id = a.i', rc=2,
          message='type mismatch')
    check('join_float_key_gated',
          'SELECT u.id FROM users u JOIN aliases a ON u.score = a.r', rc=2,
          message='JOIN keys currently require INT32 or INT64')
    check('join_bool_key_gated',
          'SELECT u.id FROM users u JOIN aliases a ON u.active = a.ok', rc=2,
          message='JOIN keys currently require INT32 or INT64')
    check('join_where_gated',
          'SELECT u.id FROM users u JOIN aliases a ON u.age = a.i WHERE u.id > 1',
          rc=2, message='JOIN WHERE predicates are not implemented yet')
    check('join_right_projection',
          'SELECT a.b FROM users u JOIN aliases a ON u.age = a.i', rc=0,
          rows=[(10,), (11,), (12,)])
    check('join_mixed_projections',
          'SELECT u.id,a.b FROM users u JOIN aliases a ON u.age = a.i', rc=0,
          rows=[(1,10), (3,11), (3,12)])
    check('join_projection_requires_namespace',
          'SELECT id FROM users u JOIN aliases a ON u.age = a.i', rc=2,
          message='JOIN projections must be explicitly qualified')
    check('join_star_requires_expansion_contract',
          'SELECT * FROM users u JOIN aliases a ON u.age = a.i', rc=2,
          message='JOIN projections must be explicitly qualified')
    check('join_missing_right_projection',
          'SELECT a.missing FROM users u JOIN aliases a ON u.age = a.i', rc=2,
          message='column not found in schema')
    check('create_join_left_batch',
          'CREATE TABLE join_l (k INT32, lv INT64)', rc=0,
          message='Table created')
    check('create_join_right_batch',
          'CREATE TABLE join_r (k INT32, rv INT64)', rc=0,
          message='Table created')
    check('insert_join_left_batch',
          'INSERT INTO join_l VALUES ' + ','.join(f'(7,{i})' for i in range(9)),
          rc=0, message='INSERT 9')
    check('insert_join_right_batch',
          'INSERT INTO join_r VALUES ' + ','.join(
              f'(7,{"NULL" if i == 3 else i})' for i in range(8)),
          rc=0, message='INSERT 8')
    expected_join_batch = [
        (left, 'NULL' if right == 3 else right)
        for left in range(9) for right in range(8)
    ]
    check('join_flushes_full_output_batch',
          'SELECT l.lv,r.rv FROM join_l l INNER JOIN join_r r ON l.k = r.k',
          rc=0, rows=expected_join_batch)
    check('join_no_matches',
          'SELECT l.lv,a.b FROM join_l l JOIN aliases a ON l.k = a.i',
          rc=0, rows=[])
    check('join_left_no_matches',
          'SELECT l.lv,a.b FROM join_l l LEFT JOIN aliases a ON l.k = a.i',
          rc=0, rows=[(i,'NULL') for i in range(9)])
    check('create_join_empty_right',
          'CREATE TABLE join_empty (k INT32, rv INT64)', rc=0,
          message='Table created')
    check('join_left_empty_right',
          'SELECT l.lv,r.rv FROM join_l l LEFT JOIN join_empty r ON l.k = r.k',
          rc=0, rows=[(i,'NULL') for i in range(9)])
    check('create_join_left_65',
          'CREATE TABLE join_l65 (k INT32, lv INT64)', rc=0,
          message='Table created')
    check('insert_join_left_65',
          'INSERT INTO join_l65 VALUES ' + ','.join(f'(7,{i})' for i in range(65)),
          rc=0, message='INSERT 65')
    check('join_left_flushes_unmatched_batch',
          'SELECT l.lv,r.rv FROM join_l65 l LEFT JOIN join_empty r ON l.k = r.k',
          rc=0, rows=[(i,'NULL') for i in range(65)])
    check('create_join_int64_right',
          'CREATE TABLE join_i64 (k BIGINT, value INT32)', rc=0,
          message='Table created')
    check('insert_join_int64_right',
          'INSERT INTO join_i64 VALUES (10,1),(11,2),(10,3)', rc=0,
          message='INSERT 3')
    check('join_int64_key',
          'SELECT a.b,r.value FROM aliases a JOIN join_i64 r ON a.b = r.k',
          rc=0, rows=[(10,1), (10,3), (11,2)])
    check('select_nonexistent_col', 'SELECT nonexistent FROM users', rc=2, message='column not found in schema')
    check('select_nonexistent_table', 'SELECT id FROM missing_tbl', rc=2, message='table not found in catalog')
    check('where_eq_int', 'SELECT id FROM users WHERE id = 1', rc=0, rows=[(1,)])
    check('where_neq_int', 'SELECT id FROM users WHERE id != 1', rc=0, rows=[(2,), (3,), (4,)])
    check('where_gt_int', 'SELECT id FROM users WHERE age > 30', rc=0, rows=[(3,)])
    check('where_lte_int', 'SELECT id FROM users WHERE age <= 25', rc=0, rows=[(1,), (4,)])
    check('where_neg_int', 'SELECT id FROM users WHERE age < 0', rc=0, rows=[(4,)])
    check('where_bool', 'SELECT id FROM users WHERE active = TRUE', rc=0, rows=[(1,), (3,), (4,)])
    check('where_float_gt', 'SELECT id FROM users WHERE score > 50.0', rc=0, rows=[(2,), (3,)])
    check('where_float_neg', 'SELECT id FROM users WHERE score < 0.0', rc=0, rows=[(4,)])
    check('where_is_null', 'SELECT id FROM users WHERE age IS NULL', rc=0, rows=[(2,)])
    check('where_is_not_null', 'SELECT id FROM users WHERE age IS NOT NULL', rc=0, rows=[(1,), (3,), (4,)])
    check('where_comp_null_lit', 'SELECT id FROM users WHERE age = NULL', rc=0, rows=[])
    check('where_not_null_lit', 'SELECT id FROM users WHERE NOT (age = NULL)', rc=0, rows=[])
    check('where_not_is_null', 'SELECT id FROM users WHERE NOT (age IS NULL)', rc=0, rows=[(1,), (3,), (4,)])
    check('where_and', 'SELECT id FROM users WHERE age > 20 AND active = TRUE', rc=0, rows=[(1,), (3,)])
    check('where_or', 'SELECT id FROM users WHERE age > 30 OR id = 2', rc=0, rows=[(2,), (3,)])
    check('where_complex', 'SELECT id FROM users WHERE (age > 20 OR id = 4) AND active = TRUE', rc=0, rows=[(1,), (3,), (4,)])
    check('limit_basic', 'SELECT id FROM users LIMIT 2', rc=0,
          rows=[(1,), (2,)])
    check('limit_zero', 'SELECT id FROM users LIMIT 0', rc=0, rows=[])
    check('limit_overflow_rows', 'SELECT id FROM users LIMIT 99', rc=0,
          rows=[(1,), (2,), (3,), (4,)])
    check('limit_offset', 'SELECT id FROM users LIMIT 2 OFFSET 1', rc=0,
          rows=[(2,), (3,)])
    check('limit_offset_past_end', 'SELECT id FROM users LIMIT 2 OFFSET 99',
          rc=0, rows=[])
    check('limit_after_where',
          'SELECT id FROM users WHERE active = TRUE LIMIT 2 OFFSET 1',
          rc=0, rows=[(3,), (4,)])
    check('limit_join',
          'SELECT u.id,a.b FROM users u JOIN aliases a ON u.age = a.i LIMIT 2 OFFSET 1',
          rc=0, rows=[(3,11), (3,12)])
    check('limit_left_join_unmatched',
          'SELECT u.id,a.b FROM users u LEFT JOIN aliases a ON u.age = a.i LIMIT 2 OFFSET 3',
          rc=0, rows=[(2,'NULL'), (4,'NULL')])
    check('limit_requires_integer', 'SELECT id FROM users LIMIT 1.5', rc=2)
    check('limit_rejects_negative', 'SELECT id FROM users LIMIT -1', rc=2)
    check('offset_requires_limit', 'SELECT id FROM users OFFSET 1', rc=2)
    check('order_by_ast_asc', 'SELECT id FROM users ORDER BY id', rc=2,
          message='ORDER BY execution is not implemented yet')
    check('order_by_ast_explicit_asc', 'SELECT id FROM users ORDER BY id ASC', rc=2,
          message='ORDER BY execution is not implemented yet')
    check('order_by_ast_desc_limit',
          'SELECT id FROM users ORDER BY id DESC LIMIT 2 OFFSET 1', rc=2,
          message='ORDER BY execution is not implemented yet')
    check('order_by_ast_qualified_join',
          'SELECT u.id FROM users u JOIN aliases a ON u.age = a.i ORDER BY u.id DESC LIMIT 2',
          rc=2, message='ORDER BY execution is not implemented yet')
    check('order_by_requires_by', 'SELECT id FROM users ORDER id', rc=2)
    check('order_by_requires_column', 'SELECT id FROM users ORDER BY LIMIT 1', rc=2)
    check('order_by_rejects_multiple', 'SELECT id FROM users ORDER BY id, age', rc=2)
    check('order_by_requires_projected_column',
          'SELECT id FROM users ORDER BY age', rc=2,
          message='column not found in schema')
    check('order_by_wrong_namespace',
          'SELECT u.id FROM users u ORDER BY nope.id', rc=2,
          message='column not found in schema')
    check('order_by_join_namespace_must_match_projection',
          'SELECT u.id FROM users u JOIN aliases a ON u.age = a.i ORDER BY a.id',
          rc=2, message='column not found in schema')
    check('count_all', 'SELECT count(*) FROM users', rows=[(4,)])
    check('count_case_insensitive', 'SELECT COUNT(*) FROM USERS', rows=[(4,)])
    check('count_filter', 'SELECT count(*) FROM users WHERE age > 30', rows=[(1,)])
    check('count_filter_none', 'SELECT count(*) FROM users WHERE age > 999', rows=[(0,)])
    check('count_filter_null', 'SELECT count(*) FROM users WHERE age IS NULL', rows=[(1,)])
    check('count_limit_one', 'SELECT count(*) FROM users LIMIT 1', rows=[(4,)])
    check('count_limit_zero', 'SELECT count(*) FROM users LIMIT 0', rows=[])
    check('count_limit_offset', 'SELECT count(*) FROM users LIMIT 1 OFFSET 1', rows=[])
    check('count_syntax_no_args', 'SELECT count() FROM users', rc=2, message='syntax error')
    check('count_syntax_col_arg', 'SELECT count(id) FROM users', rc=2, message='syntax error')
    check('count_syntax_extra_col', 'SELECT count(*), id FROM users', rc=2, message='syntax error')
    check('count_syntax_leading_col', 'SELECT id, count(*) FROM users', rc=2, message='expected column name')
    check('overflow_int', 'SELECT id FROM users WHERE id > 99999999999999999999999', rc=2, message='integer literal overflow')
    check('create_b63', 'CREATE TABLE b63 ( id INT64 NOT NULL, val INT32 )', rc=0, message='Table created')
    check('insert_b63', 'INSERT INTO b63 VALUES ' + ','.join(f'({i}, {i})' for i in range(1, 64)), rc=0, message='INSERT 63')
    check('select_b63_all', 'SELECT id FROM b63', rc=0, rows=[(i,) for i in range(1, 64)])
    check('select_b63_filter', 'SELECT id FROM b63 WHERE id > 30', rc=0, rows=[(i,) for i in range(31, 64)])
    check('create_b64', 'CREATE TABLE b64 ( id INT64 NOT NULL, val INT32 )', rc=0, message='Table created')
    check('insert_b64', 'INSERT INTO b64 VALUES ' + ','.join(f'({i}, {i})' for i in range(1, 65)), rc=0, message='INSERT 64')
    check('select_b64_all', 'SELECT id FROM b64', rc=0, rows=[(i,) for i in range(1, 65)])
    check('select_b64_filter', 'SELECT id FROM b64 WHERE id <= 32', rc=0, rows=[(i,) for i in range(1, 33)])
    check('create_b65', 'CREATE TABLE b65 ( id INT64 NOT NULL, val INT32 )', rc=0, message='Table created')
    check('insert_b65', 'INSERT INTO b65 VALUES ' + ','.join(f'({i}, {i})' for i in range(1, 66)), rc=0, message='INSERT 65')
    check('select_b65_all', 'SELECT id FROM b65', rc=0, rows=[(i,) for i in range(1, 66)])
    check('select_b65_filter_cross', 'SELECT id FROM b65 WHERE id > 64', rc=0, rows=[(65,)])
    check('create_bmulti', 'CREATE TABLE bmulti ( id INT64 NOT NULL, val INT32 )', rc=0, message='Table created')
    check('insert_bmulti_part1', 'INSERT INTO bmulti VALUES ' + ','.join(f'({i}, {i})' for i in range(1, 201)), rc=0, message='INSERT 200')
    check('insert_bmulti_part2', 'INSERT INTO bmulti VALUES ' + ','.join(f'({i}, {i})' for i in range(201, 401)), rc=0, message='INSERT 200')
    check('select_bmulti_all', 'SELECT id FROM bmulti', rc=0, rows=[(i,) for i in range(1, 401)])
    check('select_bmulti_cross_page', 'SELECT id FROM bmulti WHERE id > 350', rc=0, rows=[(i,) for i in range(351, 401)])
    check('select_bmulti_single_row', 'SELECT id FROM bmulti WHERE id = 399', rc=0, rows=[(399,)])
    check('count_bmulti_all', 'SELECT count(*) FROM bmulti', rows=[(400,)])
    check('count_bmulti_filter', 'SELECT count(*) FROM bmulti WHERE id > 350', rows=[(50,)])
    check('not_or_unknown', 'SELECT id FROM users WHERE NOT(age > 30 OR id = 2)', rows=[(1,), (4,)])
    check('not_and_unknown', 'SELECT id FROM users WHERE NOT(age > 30 AND active = TRUE)', rows=[(1,), (2,), (4,)])
    check('create_truth', 'CREATE TABLE truth (id INT32, a BOOL, b BOOL)', message='Table created')
    values = [True, False, None]
    combinations = [(a, b) for a in values for b in values]
    literal = lambda v: 'NULL' if v is None else str(v).upper()
    check('insert_truth', 'INSERT INTO truth VALUES ' + ','.join(
        f'({i},{literal(a)},{literal(b)})' for i, (a, b) in enumerate(combinations)), message='INSERT 9')
    def sql_and(a, b):
        return False if a is False or b is False else None if a is None or b is None else True
    def sql_or(a, b):
        return True if a is True or b is True else None if a is None or b is None else False
    for op, function in [('AND', sql_and), ('OR', sql_or)]:
        expression = f'(a = TRUE {op} b = TRUE)'
        for negate in (False, True):
            expected = []
            for i, (a, b) in enumerate(combinations):
                value = function(a, b)
                if negate and value is not None:
                    value = not value
                if value is True:
                    expected.append((i,))
            check(f'truth_{op}_{negate}', 'SELECT id FROM truth WHERE ' +
                  ('NOT ' if negate else '') + expression, rows=expected)
    columns = ','.join(f'c{i} INT32' for i in range(64))
    check('columns_64', f'CREATE TABLE wide ({columns})', message='Table created')
    check('columns_65', f'CREATE TABLE excessive ({columns}, c64 INT32)', rc=2, message='column count exceeds maximum of 64')
    check('insert_wide', 'INSERT INTO wide VALUES (' + ','.join(map(str, range(64))) + ')', message='INSERT 1')
    projection = ','.join(f'c{i}' for i in range(64))
    check('projection_64', f'SELECT {projection} FROM wide', rows=[tuple(range(64))])
    check('projection_65', f'SELECT {projection},c0 FROM wide', rc=2, message='projection count exceeds maximum of 64')
    check('projection_high_bit', 'SELECT c63,c0,c63 FROM wide WHERE c62 = 62', rows=[(63,0,63)])
    check('create_values_limit', 'CREATE TABLE limits (id INT32)', message='Table created')
    values256 = ','.join(f'({i})' for i in range(256))
    check('values_257', f'INSERT INTO limits VALUES {values256},(256)', rc=2, message='row count exceeds maximum of 256')
    check('values_257_unchanged', 'SELECT id FROM limits', rows=[])
    check('values_256', f'INSERT INTO limits VALUES {values256}', message='INSERT 256')
    check('values_256_exact', 'SELECT id FROM limits', rows=[(i,) for i in range(256)])
    # Expression nesting. Parser, binder and executor all recurse over the
    # tree, so the depth an input may reach has to be the parser's decision
    # rather than the stack's.
    depth_ok = '(' * 63 + 'id = 1' + ')' * 63
    check('expr_depth_64', f'SELECT id FROM users WHERE {depth_ok}', rows=[(1,)])
    depth_bad = '(' * 64 + 'id = 1' + ')' * 64
    check('expr_depth_65', f'SELECT id FROM users WHERE {depth_bad}', rc=2,
          message='expression nesting exceeds maximum of 64')
    check('expr_depth_not', 'SELECT id FROM users WHERE ' + 'NOT ' * 200 + 'id = 1',
          rc=2, message='expression nesting exceeds maximum of 64')
    # A statement rejected for depth must not poison the next one.
    check('expr_depth_recovers', 'SELECT id FROM users WHERE id = 1', rows=[(1,)])

    # A statement too large for the command line is refused, never clipped:
    # half a WHERE clause still parses and would quietly mean something else.
    # The two systems clip at different places - Windows captures the whole
    # command line into a 4096-character buffer, Linux only bounds the single
    # argument - so the padding is sized to cross whichever limit applies
    # while staying under the CreateProcess maximum.
    padding = 700 if os.name == 'nt' else 9000
    check('statement_too_long',
          'SELECT id FROM users WHERE id = 1 ' + 'OR id = 1 ' * padding, rc=2,
          message='exceeds the command-line limit')

    check('float_digits_128', 'SELECT id FROM users WHERE score = 0.' + '0' * 126 + '1', rows=[])
    for name, literal in [('digits_129', '0.' + '0' * 127 + '1'),
                          ('float_overflow', '9' * 40 + '.0'),
                          ('negative_float_overflow', '-' + '9' * 40 + '.0')]:
        check(name, 'INSERT INTO users VALUES (9, 1, TRUE, ' + literal + ')',
              rc=2, message='FLOAT32 literal exceeds range or 128 digits')
    for literal in ['1.0e2', '1e2', 'NaN', 'Inf', '.5', '1.']:
        check('unsupported_float_' + literal,
              f'INSERT INTO users VALUES (9, 1, TRUE, {literal})', rc=2)
    check('float_errors_unchanged', 'SELECT id FROM users', rows=[(1,), (2,), (3,), (4,)])
    result = invoke('check', database)
    if result.returncode or 'Status:          OK' not in result.stdout:
        raise RuntimeError(f'Integrity check failed: {result.stdout} {result.stderr}')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='cyboudb-sql-') as directory:
        database = Path(directory) / 'test.cyboudb'
        setup = invoke('create-pax-multi', database, '10000', '--force')
        if setup.returncode:
            sys.exit(f'Database setup failed: {setup.stdout} {setup.stderr}')
        run()
    print(f'SQL test suite: {passed} passed, {failed} failed')
    sys.exit(1 if failed else 0)
