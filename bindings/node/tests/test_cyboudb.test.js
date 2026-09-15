const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { Database, version } = require('../index.js');

const DB_PATH = path.join(__dirname, 'test_node_cyboudb.cdb');

function cleanup() {
  if (fs.existsSync(DB_PATH)) {
    try {
      fs.unlinkSync(DB_PATH);
    } catch (_) {}
  }
}

test('version returns valid string', () => {
  const ver = version();
  assert.strictEqual(typeof ver, 'string');
  assert.ok(ver.length > 0);
});

test('basic CRUD and indexes', () => {
  cleanup();
  const db = Database.create(DB_PATH, 256);
  try {
    db.execute('CREATE TABLE users (id INT32 NOT NULL, name TEXT, balance FLOAT32);');
    db.execute('CREATE UNIQUE INDEX idx_user_id ON users (id);');

    // Parameterized inserts
    db.execute('INSERT INTO users VALUES (?, ?, ?);', [1, 'Alice', 123.45]);
    db.execute('INSERT INTO users VALUES (?, ?, ?);', [2, 'Bob', 67.89]);

    // Query
    const rows = db.query('SELECT id, name, balance FROM users WHERE id = ?;', [1]);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0][0], 1);
    assert.strictEqual(rows[0][1], 'Alice');
    assert.ok(Math.abs(rows[0][2] - 123.45) < 0.01);
  } finally {
    db.close();
    cleanup();
  }
});

test('transactions atomic commit and rollback', () => {
  cleanup();
  const db = Database.create(DB_PATH, 256);
  try {
    db.execute('CREATE TABLE items (id INT32 NOT NULL, label TEXT);');

    // 1. Successful commit
    db.transaction((tx) => {
      tx.execute('INSERT INTO items VALUES (?, ?);', [10, 'first_item']);
    });

    const rows1 = db.query('SELECT id, label FROM items WHERE id = ?;', [10]);
    assert.strictEqual(rows1.length, 1);
    assert.strictEqual(rows1[0][1], 'first_item');

    // 2. Automatic rollback on exception
    assert.throws(() => {
      db.transaction((tx) => {
        tx.execute('INSERT INTO items VALUES (?, ?);', [20, 'second_item']);
        throw new Error('Simulated failure');
      });
    }, /Simulated failure/);

    const rows2 = db.query('SELECT id, label FROM items WHERE id = ?;', [20]);
    assert.strictEqual(rows2.length, 0);
  } finally {
    db.close();
    cleanup();
  }
});

test('durable queues and event streams', () => {
  cleanup();
  const db = Database.create(DB_PATH, 256);
  try {
    db.execute('CREATE QUEUE jobs;');
    db.execute('CREATE STREAM audit;');
    db.execute('CREATE CURSOR reader_app ON audit;');

    // Queue FIFO
    db.enqueue('jobs', 'task_one');
    db.enqueue('jobs', 'task_two');

    const msg1 = db.dequeue('jobs');
    assert.ok(Buffer.isBuffer(msg1));
    assert.strictEqual(msg1.toString('utf-8'), 'task_one');

    const msg2 = db.dequeue('jobs');
    assert.ok(Buffer.isBuffer(msg2));
    assert.strictEqual(msg2.toString('utf-8'), 'task_two');

    const msg3 = db.dequeue('jobs');
    assert.strictEqual(msg3, null);

    // Stream Append & Read
    db.append('audit', 'event_login');
    const evt = db.readStream('audit', 'reader_app');
    assert.ok(Buffer.isBuffer(evt));
    assert.strictEqual(evt.toString('utf-8'), 'event_login');
  } finally {
    db.close();
    cleanup();
  }
});
