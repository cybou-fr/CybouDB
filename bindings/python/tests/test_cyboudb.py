import unittest
import os
import cyboudb

class TestCybouDB(unittest.TestCase):
    DB_PATH = "test_py_cyboudb.cdb"

    def setUp(self):
        if os.path.exists(self.DB_PATH):
            os.remove(self.DB_PATH)

    def tearDown(self):
        if os.path.exists(self.DB_PATH):
            try:
                os.remove(self.DB_PATH)
            except OSError:
                pass

    def test_version(self):
        v = cyboudb.version()
        self.assertIsInstance(v, str)
        self.assertTrue(len(v) > 0)

    def test_basic_crud(self):
        db = cyboudb.Database.create(self.DB_PATH, pages=256)
        try:
            db.execute("CREATE TABLE users (id INT32 NOT NULL, name TEXT, balance FLOAT32);")
            db.execute("CREATE UNIQUE INDEX idx_user_id ON users (id);")

            # Parameterized inserts
            db.execute("INSERT INTO users VALUES (?, ?, ?);", [1, "Alice", 100.5])
            db.execute("INSERT INTO users VALUES (?, ?, ?);", [2, "Bob", 250.0])

            # Query
            rows = db.query("SELECT id, name, balance FROM users WHERE id = ?;", [1])
            self.assertEqual(len(rows), 1)
            row = rows[0]
            self.assertEqual(row[0], 1)
            self.assertEqual(row[1], "Alice")
            self.assertAlmostEqual(row[2], 100.5, places=2)
        finally:
            db.close()

    def test_transaction_commit_and_rollback(self):
        db = cyboudb.Database.create(self.DB_PATH, pages=256)
        try:
            db.execute("CREATE TABLE items (id INT32 NOT NULL, val TEXT);")

            # Successful commit
            with db.transaction() as tx:
                tx.execute("INSERT INTO items VALUES (?, ?);", [1, "item1"])

            rows = db.query("SELECT id, val FROM items WHERE id = ?;", [1])
            self.assertEqual(len(rows), 1)

            # Rollback on exception
            try:
                with db.transaction() as tx:
                    tx.execute("INSERT INTO items VALUES (?, ?);", [2, "item2"])
                    raise ValueError("Simulated error")
            except ValueError:
                pass

            # Item 2 should not exist
            rows = db.query("SELECT id, val FROM items WHERE id = ?;", [2])
            self.assertEqual(len(rows), 0)
        finally:
            db.close()

    def test_queues_and_streams(self):
        db = cyboudb.Database.create(self.DB_PATH, pages=256)
        try:
            db.execute("CREATE QUEUE test_queue;")
            db.execute("CREATE STREAM test_stream;")
            db.execute("CREATE CURSOR test_cursor ON test_stream;")

            # Queue
            db.enqueue("test_queue", "payload_1")
            db.enqueue("test_queue", "payload_2")

            msg1 = db.dequeue("test_queue")
            self.assertEqual(msg1, b"payload_1")
            msg2 = db.dequeue("test_queue")
            self.assertEqual(msg2, b"payload_2")
            msg3 = db.dequeue("test_queue")
            self.assertIsNone(msg3)

            # Stream
            db.append("test_stream", "event_alpha")
            event = db.read_stream("test_stream", "test_cursor")
            self.assertEqual(event, b"event_alpha")
        finally:
            db.close()

if __name__ == "__main__":
    unittest.main()
