/**
 * CybouDB Node.js & TypeScript Quickstart Demo
 *
 * Demonstrates:
 * - Unified single-file .cdb database
 * - Relational tables and B+Tree indexes
 * - Durable FIFO queues
 * - Replayable event streams
 * - Unified cross-primitive ACID transactions
 */

const fs = require('fs');
const path = require('path');
const { Database, version } = require('../index.js');

const DB_PATH = path.join(__dirname, 'quickstart_demo.cdb');

function main() {
  if (fs.existsSync(DB_PATH)) {
    fs.unlinkSync(DB_PATH);
  }

  console.log('=== CybouDB Node.js Quickstart Demo ===');
  console.log(`-> Engine Version: ${version()}`);

  // 1. Create database (512 pages = 2 MiB)
  console.log(`-> Creating database: ${DB_PATH}`);
  const db = Database.create(DB_PATH, 512);

  try {
    // 2. Define schema
    console.log('-> Creating schema (Table, Index, Queue, Stream, Cursor)...');
    db.execute('CREATE TABLE workers (id INT32 NOT NULL, name TEXT, tasks INT32);');
    db.execute('CREATE UNIQUE INDEX idx_worker_id ON workers (id);');
    db.execute('CREATE QUEUE tasks;');
    db.execute('CREATE STREAM audit_log;');
    db.execute('CREATE CURSOR monitor ON audit_log;');

    // 3. Populate workers
    console.log('-> Populating workers with parameterized query...');
    db.execute('INSERT INTO workers VALUES (?, ?, ?);', [1, 'Worker Alpha', 0]);
    db.execute('INSERT INTO workers VALUES (?, ?, ?);', [2, 'Worker Beta', 0]);

    // 4. Enqueue jobs
    console.log("-> Enqueueing jobs into 'tasks' FIFO queue...");
    db.enqueue('tasks', 'generate_embeddings');
    db.enqueue('tasks', 'index_documents');

    // 5. Atomic transaction across Queue + Table + Stream
    console.log('-> Executing atomic transaction across Queue + Table + Stream...');
    db.transaction((tx) => {
      // Dequeue task
      const taskBytes = tx.dequeue('tasks');
      const taskName = taskBytes ? taskBytes.toString('utf-8') : 'unknown';
      console.log(`   [Tx] Dequeued job: '${taskName}'`);

      // Update worker record
      tx.execute('UPDATE workers SET tasks = 1 WHERE id = 1;');
      console.log('   [Tx] Incremented completed tasks for Worker #1');

      // Append audit event
      tx.append('audit_log', `Worker Alpha finished '${taskName}'`);
      console.log('   [Tx] Appended audit event to stream');

      console.log('   [Tx] Committing transaction atomically...');
    });

    // 6. Query updated state
    console.log('-> Querying workers from table:');
    const rows = db.query('SELECT id, name, tasks FROM workers WHERE id = ?;', [1]);
    for (const row of rows) {
      console.log(`   Worker #${row[0]}: Name='${row[1]}', Tasks=${row[2]}`);
    }

    // 7. Read stream events
    console.log("-> Reading audit event from stream as cursor 'monitor':");
    const event = db.readStream('audit_log', 'monitor');
    if (event) {
      console.log(`   Stream Event: ${event.toString('utf-8')}`);
    }
  } finally {
    db.close();
    if (fs.existsSync(DB_PATH)) {
      fs.unlinkSync(DB_PATH);
    }
  }

  console.log('=== Demo completed successfully! ===');
}

main();
