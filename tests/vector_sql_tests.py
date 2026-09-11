# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#  tests/vector_sql_tests.py - SQL Vector Type & Storage Extents Test Suite
# =============================================================================

import ctypes
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

if len(sys.argv) > 1:
    CYBOUDB_EXE = os.path.abspath(sys.argv[1])
else:
    default_win = os.path.join(os.path.dirname(__file__), '..', 'cyboudb.exe')
    default_nix = os.path.join(os.path.dirname(__file__), '..', 'cyboudb')
    CYBOUDB_EXE = default_win if os.path.exists(default_win) else default_nix

sys.path.insert(0, os.path.dirname(__file__))
from corrupt import crc32c

P = 4096
failed_tests = 0
passed_tests = 0


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


def u64(b, off):
    return struct.unpack_from("<Q", b, off)[0]


def u32(b, off):
    return struct.unpack_from("<I", b, off)[0]


def find_leaf_run_pages(b, leaf):
    for p in (1, 2, 4, 8, 16, 32):
        crc_off = leaf * P + p * P - 4
        if crc_off + 4 <= len(b):
            stored = u32(b, crc_off)
            if stored == crc32c(b[leaf * P:crc_off]):
                return p
    return 1


def seal_leaf(b, leaf, run_pages):
    crc_off = leaf * P + run_pages * P - 4
    crc = crc32c(b[leaf * P:crc_off])
    struct.pack_into("<I", b, crc_off, crc)


def lock_reader_pin(file_path):
    """Pin reader byte 1 to simulate an active reader hold."""
    if os.name == "nt":
        class Overlapped(ctypes.Structure):
            _fields_ = [("internal", ctypes.c_void_p),
                        ("internal_high", ctypes.c_void_p),
                        ("offset", ctypes.c_uint32),
                        ("offset_high", ctypes.c_uint32),
                        ("event", ctypes.c_void_p)]
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.restype = ctypes.c_void_p
        handle = kernel32.CreateFileW(str(file_path), 0x80000000, 3,
                                      None, 3, 0x80, None)
        assert handle not in (None, ctypes.c_void_p(-1).value)
        ov = Overlapped(offset=1)
        assert kernel32.LockFileEx(ctypes.c_void_p(handle), 1, 0, 1, 0,
                                   ctypes.byref(ov))
        return lambda: kernel32.CloseHandle(ctypes.c_void_p(handle))
    else:
        import fcntl
        f = open(file_path, "rb")
        fcntl.lockf(f, fcntl.LOCK_SH | fcntl.LOCK_NB, 1, 1, os.SEEK_SET)
        return f.close


def main():
    with tempfile.TemporaryDirectory(prefix="cyboudb-vector-") as temp_dir:
        db_path = os.path.join(temp_dir, "test_vector_suite.cdb")
        db_non_large = os.path.join(temp_dir, "test_vector_non_large.cdb")

        # 1. Reject vector in non-large database (lacking CybouDB_FEATURE_VECTOR)
        res = run_cmd(['create-pax-multi', db_non_large, '256', '--force'])
        test('create_non_large_db', res.returncode == 0, res.stderr)

        res = run_cmd(['query', db_non_large, 'CREATE TABLE v (e VECTOR(FLOAT32, 3));'])
        test('vector_rejected_without_feature',
             res.returncode == 2 and 'VECTOR storage extents are not implemented yet' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        # 2. Create large database (with CybouDB_FEATURE_VECTOR)
        res = run_cmd(['create-large', db_path, '512', '--force'])
        test('create_large_db', res.returncode == 0, res.stderr)

        # 3. Create table with VECTOR column
        res = run_cmd(['query', db_path, 'CREATE TABLE items (id INT64 NOT NULL, emb VECTOR(FLOAT32, 3));'])
        test('create_vector_table', res.returncode == 0 and 'Table created.' in res.stdout, res.stdout)

        # 4. REPL .schema rendering
        res = run_cmd([db_path], stdin_input='.schema items\n.quit\n')
        test('repl_schema_vector',
             res.returncode == 0 and 'emb  VECTOR(FLOAT32, 3)' in res.stdout,
             res.stdout)

        # 5. Insert valid vector literals
        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (1, [1.0, 2.0, 3.0]);'])
        test('insert_vector_basic', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (2, [-1.5, 0.0, 2.25]);'])
        test('insert_vector_negative_floats', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (3, NULL);'])
        test('insert_vector_null', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (4, [0.0, 0.0, 0.0]), (5, [10.0, 20.0, 30.0]);'])
        test('insert_vector_multi_row', res.returncode == 0 and 'INSERT 2' in res.stdout, res.stdout)

        # 6. Select vector columns
        res = run_cmd(['query', db_path, 'SELECT id, emb FROM items;'])
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
        res = run_cmd(['query', db_path, 'SELECT id FROM items WHERE emb IS NULL;'])
        test('where_vector_is_null', res.returncode == 0 and '3' in res.stdout and '(1 row)' in res.stdout, res.stdout)

        res = run_cmd(['query', db_path, 'SELECT id FROM items WHERE emb IS NOT NULL;'])
        test('where_vector_is_not_null', res.returncode == 0 and '(4 rows)' in res.stdout, res.stdout)

        # 8. Dimension mismatch rejection
        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (6, [1.0, 2.0]);'])
        test('vector_dim_mismatch_too_few',
             res.returncode == 2 and 'type mismatch' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (7, [1.0, 2.0, 3.0, 4.0]);'])
        test('vector_dim_mismatch_too_many',
             res.returncode == 2 and 'type mismatch' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        # 9. Empty vector literal rejection
        res = run_cmd(['query', db_path, 'INSERT INTO items VALUES (8, []);'])
        test('vector_empty_literal_rejected',
             res.returncode == 2 and 'syntax error' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        # 10. Dimension range limits
        res = run_cmd(['query', db_path, 'CREATE TABLE v0 (e VECTOR(FLOAT32, 0));'])
        test('vector_dim_zero_rejected',
             res.returncode == 2 and 'syntax error' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        res = run_cmd(['query', db_path, 'CREATE TABLE v_big (e VECTOR(FLOAT32, 4097));'])
        test('vector_dim_too_large_rejected',
             res.returncode == 2 and 'syntax error' in res.stdout,
             f"rc={res.returncode}, out={res.stdout}")

        # 11. Multi-page vector extent chain (dimension 1024 spans 2 pages)
        res = run_cmd(['query', db_path, 'CREATE TABLE multi_page_vec (id INT64 NOT NULL, emb VECTOR(FLOAT32, 1024));'])
        test('create_multi_page_vec_table', res.returncode == 0, res.stdout)

        lines = []
        for i in range(0, 1024, 64):
            chunk = [f'{x}.0' for x in range(i + 1, i + 65)]
            lines.append(', '.join(chunk))
        floats = ',\n'.join(lines)
        sql = f'INSERT INTO multi_page_vec VALUES (100, [\n{floats}\n]);\nSELECT id, emb FROM multi_page_vec;\n.quit\n'

        res = run_cmd([db_path], stdin_input=sql)
        test('multi_page_vector_insert_and_select',
             res.returncode == 0 and 'INSERT 1' in res.stdout and '100 | [1.00, 2.00,' in res.stdout and '1024.00]' in res.stdout,
             res.stdout[:200])

        # 12. Database integrity check via cyboudb check
        res = run_cmd(['check', db_path])
        test('vector_database_check', res.returncode == 0 and 'Status:          OK' in res.stdout, res.stdout)

        # =========================================================================
        # 13. Deep PAX Storage Validation & Corruption Recovery Tests
        # =========================================================================
        with open(db_path, 'rb') as f:
            b_orig = bytearray(f.read())

        sb1_gen = u64(b_orig, 1 * P + 8) if b_orig[1 * P:1 * P + 4] == b'ASQS' else -1
        sb2_gen = u64(b_orig, 2 * P + 8) if b_orig[2 * P:2 * P + 4] == b'ASQS' else -1
        latest_sb = 2 * P if sb2_gen > sb1_gen else 1 * P
        older_sb = 1 * P if latest_sb == 2 * P else 2 * P

        root = u64(b_orig, latest_sb + 40)
        schema = u64(b_orig, root * P + 64 + 8)
        data = u64(b_orig, schema * P + 40)
        leaf = data if b_orig[data * P:data * P + 4] == b'ASQP' else u64(b_orig, data * P + 64)
        run_pages = find_leaf_run_pages(b_orig, leaf)
        col1_off = leaf * P + 64 + 16
        stream = leaf * P + u32(b_orig, col1_off + 12)

        # 13a. Non-NULL vector cell: mutate length 12 -> 16
        b_corrupt = bytearray(b_orig)
        b_corrupt[older_sb:older_sb + 4] = b'XXXX'
        struct.pack_into('<Q', b_corrupt, stream + 8, 16)
        seal_leaf(b_corrupt, leaf, run_pages)
        corrupt_path = os.path.join(temp_dir, "corrupt_non_null_len.cdb")
        with open(corrupt_path, 'wb') as f:
            f.write(b_corrupt)
        res = run_cmd(['check', corrupt_path])
        test('corrupt_vector_non_null_len_rejected', res.returncode == 2, f"rc={res.returncode}")

        # 13b. NULL vector cell: mutate root 0 -> 1
        b_corrupt = bytearray(b_orig)
        b_corrupt[older_sb:older_sb + 4] = b'XXXX'
        struct.pack_into('<Q', b_corrupt, stream + 2 * 16, 1)
        seal_leaf(b_corrupt, leaf, run_pages)
        corrupt_path = os.path.join(temp_dir, "corrupt_null_root.cdb")
        with open(corrupt_path, 'wb') as f:
            f.write(b_corrupt)
        res = run_cmd(['check', corrupt_path])
        test('corrupt_vector_null_root_rejected', res.returncode == 2, f"rc={res.returncode}")

        # 13c. NULL vector cell: mutate length 0 -> 12
        b_corrupt = bytearray(b_orig)
        b_corrupt[older_sb:older_sb + 4] = b'XXXX'
        struct.pack_into('<Q', b_corrupt, stream + 2 * 16 + 8, 12)
        seal_leaf(b_corrupt, leaf, run_pages)
        corrupt_path = os.path.join(temp_dir, "corrupt_null_len.cdb")
        with open(corrupt_path, 'wb') as f:
            f.write(b_corrupt)
        res = run_cmd(['check', corrupt_path])
        test('corrupt_vector_null_len_rejected', res.returncode == 2, f"rc={res.returncode}")

        # 13d. Damage newly allocated leaf, keep older superblock intact -> fallback succeeds
        res = run_cmd(['query', db_path, 'CREATE TABLE fb_vec (id INT64, v VECTOR(FLOAT32, 3));'])
        test('create_fallback_table', res.returncode == 0, res.stdout)
        res = run_cmd(['query', db_path, 'INSERT INTO fb_vec VALUES (1, [1.0, 2.0, 3.0]);'])
        test('insert_fallback_row1', res.returncode == 0, res.stdout)
        # Second insert allocates a fresh copy of the leaf for the new generation
        res = run_cmd(['query', db_path, 'INSERT INTO fb_vec VALUES (2, [4.0, 5.0, 6.0]);'])
        test('insert_fallback_row2', res.returncode == 0, res.stdout)

        with open(db_path, 'rb') as f:
            b_fb = bytearray(f.read())

        g1 = u64(b_fb, 1 * P + 8) if b_fb[1 * P:1 * P + 4] == b'ASQS' else -1
        g2 = u64(b_fb, 2 * P + 8) if b_fb[2 * P:2 * P + 4] == b'ASQS' else -1
        latest_sb_fb = 2 * P if g2 > g1 else 1 * P

        root_fb = u64(b_fb, latest_sb_fb + 40)
        # Lookup fb_vec in catalog
        cat_count = u32(b_fb, root_fb * P + 36)
        schema_fb = None
        for i in range(cat_count):
            entry_off = root_fb * P + 64 + i * 16
            s_page = u64(b_fb, entry_off + 8)
            t_name = bytes(b_fb[s_page * P + 64:s_page * P + 128]).split(bytes([0]))[0]
            if t_name == b'fb_vec':
                schema_fb = s_page
                break
        assert schema_fb is not None, "fb_vec not found in catalog"

        data_fb = u64(b_fb, schema_fb * P + 40)
        leaf_fb = data_fb if b_fb[data_fb * P:data_fb * P + 4] == b'ASQP' else u64(b_fb, data_fb * P + 64)
        run_pages_fb = find_leaf_run_pages(b_fb, leaf_fb)
        col1_fb = leaf_fb * P + 64 + 16
        stream_fb = leaf_fb * P + u32(b_fb, col1_fb + 12)

        # Corrupt latest leaf length (dim 3 -> 12 bytes; set to 16)
        struct.pack_into('<Q', b_fb, stream_fb + 8, 16)
        seal_leaf(b_fb, leaf_fb, run_pages_fb)

        fallback_path = os.path.join(temp_dir, "fallback.cdb")
        with open(fallback_path, 'wb') as f:
            f.write(b_fb)
        res = run_cmd(['check', fallback_path])
        test('corrupted_latest_leaf_falls_back_to_prior_gen',
             res.returncode == 0 and 'Status:          OK' in res.stdout,
             res.stdout)

        res = run_cmd(['query', fallback_path, 'SELECT count(*) FROM fb_vec;'])
        test('fallback_recovers_prior_generation_data',
             res.returncode == 0 and '1' in res.stdout,
             res.stdout)

        # =========================================================================
        # 14. DROP TABLE with Extents, Active Readers, Page Reuse, and Fault Injection
        # =========================================================================
        drop_db = os.path.join(temp_dir, "drop_extent_test.cdb")
        res = run_cmd(['create-large', drop_db, '256', '--force'])
        test('create_drop_test_db', res.returncode == 0, res.stderr)

        res = run_cmd(['query', drop_db, 'CREATE TABLE ext_data (id INT64 NOT NULL, emb VECTOR(FLOAT32, 1024), doc TEXT);'])
        test('create_extent_table_for_drop', res.returncode == 0, res.stdout)

        # Insert extent row
        res = run_cmd([drop_db], stdin_input=f'INSERT INTO ext_data VALUES (1, [\n{floats}\n], \'long text data spanning extents\');\n.quit\n')
        test('insert_extent_row_for_drop', res.returncode == 0 and 'INSERT 1' in res.stdout, res.stdout)

        res = run_cmd(['info', drop_db])
        test('info_before_drop', res.returncode == 0 and 'Allocated Pages:' in res.stdout, res.stdout)

        # 14a. Active reader pin during DROP TABLE
        unpin = lock_reader_pin(drop_db)
        try:
            # Active reader is holding byte 1 lock; drop table in writer
            res = run_cmd(['query', drop_db, 'DROP TABLE ext_data;'])
            test('drop_extent_table_with_active_reader', res.returncode == 0 and 'Table dropped.' in res.stdout, res.stdout)
        finally:
            unpin()

        res = run_cmd(['check', drop_db])
        test('check_after_drop_unpin', res.returncode == 0 and 'Status:          OK' in res.stdout, res.stdout)

        # 14b. Retired page reuse after dropping extent table
        # Create a new table and insert rows to verify reclaimed pages are reused cleanly
        res = run_cmd(['query', drop_db, 'CREATE TABLE replacement (id INT64 NOT NULL, v VECTOR(FLOAT32, 3));'])
        test('create_replacement_table', res.returncode == 0, res.stdout)

        res = run_cmd(['query', drop_db, 'INSERT INTO replacement VALUES (1, [1.0, 2.0, 3.0]), (2, [4.0, 5.0, 6.0]);'])
        test('insert_into_replacement_table', res.returncode == 0 and 'INSERT 2' in res.stdout, res.stdout)

        res = run_cmd(['query', drop_db, 'SELECT id, v FROM replacement;'])
        test('select_from_replacement_table',
             res.returncode == 0 and '1 | [1.00, 2.00, 3.00]' in res.stdout and '2 | [4.00, 5.00, 6.00]' in res.stdout,
             res.stdout)

        res = run_cmd(['check', drop_db])
        test('check_after_retired_page_reuse', res.returncode == 0 and 'Status:          OK' in res.stdout, res.stdout)

        # 14c. Fault injection during DROP TABLE (torn latest superblock falls back safely)
        with open(drop_db, 'rb') as f:
            good_state = bytearray(f.read())
        # Drop table replacement
        res = run_cmd(['query', drop_db, 'DROP TABLE replacement;'])
        test('drop_replacement_table', res.returncode == 0 and 'Table dropped.' in res.stdout, res.stdout)

        with open(drop_db, 'rb') as f:
            dropped_state = bytearray(f.read())

        # Determine latest and older superblock in dropped_state
        g1 = u64(dropped_state, 1 * P + 8) if dropped_state[1 * P:1 * P + 4] == b'ASQS' else -1
        g2 = u64(dropped_state, 2 * P + 8) if dropped_state[2 * P:2 * P + 4] == b'ASQS' else -1
        latest_sb_drop = 2 * P if g2 > g1 else 1 * P

        # Tear the latest superblock write (corrupt its CRC)
        dropped_state[latest_sb_drop + 124] ^= 0xFF
        with open(drop_db, 'wb') as f:
            f.write(dropped_state)

        # Database check must fall back to previous generation where replacement still exists
        res = run_cmd(['check', drop_db])
        test('check_torn_drop_superblock_falls_back', res.returncode == 0 and 'Status:          OK' in res.stdout, res.stdout)

        res = run_cmd(['query', drop_db, 'SELECT id FROM replacement;'])
        test('torn_drop_table_recovered_intact', res.returncode == 0 and '(2 rows)' in res.stdout, res.stdout)

    print(f"\nVector SQL test suite: {passed_tests} passed, {failed_tests} failed")
    sys.exit(0 if failed_tests == 0 else 1)


if __name__ == '__main__':
    main()
