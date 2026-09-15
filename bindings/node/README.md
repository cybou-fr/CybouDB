# CybouDB Node.js & TypeScript Bindings

Official high-performance Node.js and TypeScript bindings for [CybouDB](https://github.com/cybou-fr/CybouDB), the zero-dependency embedded columnar database engine written from scratch in x86-64 assembly.

CybouDB consolidates **relational tables**, **secondary B+tree indexes**, **exact vector search**, **durable FIFO queues**, and **replayable event streams** into a single `.cdb` file under one unified ACID transaction boundary.

## Installation

```bash
npm install @cyboudb/node
```

## Quick Start

```typescript
import { Database, version } from '@cyboudb/node';

// 1. Create a database file (512 pages = 2 MiB)
const db = Database.create('app.cdb', 512);

// 2. Define schema
db.execute('CREATE TABLE workers (id INT32 NOT NULL, name TEXT, tasks INT32);');
db.execute('CREATE UNIQUE INDEX idx_worker_id ON workers (id);');
db.execute('CREATE QUEUE tasks;');
db.execute('CREATE STREAM audit_log;');
db.execute('CREATE CURSOR monitor ON audit_log;');

// 3. Populate data with typed parameters
db.execute('INSERT INTO workers VALUES (?, ?, ?);', [1, 'Worker Alpha', 0]);
db.execute('INSERT INTO workers VALUES (?, ?, ?);', [2, 'Worker Beta', 0]);
db.enqueue('tasks', 'generate_embeddings');

// 4. Atomic transaction across Queue + Table + Stream
db.transaction((tx) => {
  // Pop job from FIFO queue
  const taskBytes = tx.dequeue('tasks');
  const task = taskBytes ? taskBytes.toString('utf-8') : 'unknown';
  console.log(`Processing: ${task}`);

  // Update relational state
  tx.execute('UPDATE workers SET tasks = 1 WHERE id = 1;');

  // Append audit trail event to stream
  tx.append('audit_log', `Worker Alpha completed ${task}`);
  // Automatically COMMITS on return, or ROLLS BACK on error
});

// 5. Query relational records
const rows = db.query('SELECT id, name, tasks FROM workers WHERE id = ?;', [1]);
for (const [id, name, tasks] of rows) {
  console.log(`Worker #${id}: ${name} (tasks: ${tasks})`);
}

// 6. Read from stream
const event = db.readStream('audit_log', 'monitor');
if (event) {
  console.log(`Stream Event: ${event.toString('utf-8')}`);
}

// 7. Close connection
db.close();
```

## Features

- **Direct N-API / Native Speed**: Powered by CybouDB's x86-64 assembly engine and NAPI-rs.
- **First-Class TypeScript Support**: Full type definitions included (`index.d.ts`).
- **Ideal for Local-First & Desktop**: Replace SQLite + Redis + Vector DB in Electron and Tauri applications with a single file `.cdb` without daemon processes.
- **Unified ACID Transactions**: Atomic execution across relational updates, queue pops, and stream appends.
