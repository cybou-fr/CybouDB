/**
 * CybouDB Node.js & TypeScript Bindings
 */

export interface Transaction {
  /**
   * Execute a SQL statement within this transaction.
   */
  execute(sql: string, params?: Array<any>): void;

  /**
   * Query rows within this transaction.
   */
  query(sql: string, params?: Array<any>): Array<Array<any>>;

  /**
   * Enqueue a payload string into a queue within this transaction.
   */
  enqueue(queue: string, payload: string): void;

  /**
   * Dequeue a payload from a queue within this transaction.
   */
  dequeue(queue: string): Buffer | null;

  /**
   * Append an event payload to a stream within this transaction.
   */
  append(stream: string, payload: string): void;

  /**
   * Manually commit the transaction.
   */
  commit(): void;

  /**
   * Manually rollback the transaction.
   */
  rollback(): void;
}

export class Database {
  /**
   * Create a new database file sized in 4096-byte pages and open it read-write.
   */
  static create(path: string, pages?: number): Database;

  /**
   * Open an existing database file.
   */
  static open(path: string, readOnly?: boolean): Database;

  /**
   * Execute a SQL DDL or mutating statement.
   */
  execute(sql: string, params?: Array<any>): void;

  /**
   * Query rows matching a SQL SELECT query.
   */
  query(sql: string, params?: Array<any>): Array<Array<any>>;

  /**
   * Enqueue a message payload string into a durable FIFO queue.
   */
  enqueue(queue: string, payload: string): void;

  /**
   * Dequeue the next available message payload from a FIFO queue.
   */
  dequeue(queue: string): Buffer | null;

  /**
   * Append an event record to an append-only stream.
   */
  append(stream: string, payload: string): void;

  /**
   * Read the next event from a stream using a durable named cursor.
   */
  readStream(stream: string, cursor: string): Buffer | null;

  /**
   * Execute a callback inside an ACID transaction, automatically committing on return
   * or rolling back on exception.
   */
  transaction<T>(fn: (tx: Transaction) => T): T;

  /**
   * Manually begin a transaction.
   */
  beginTransaction(): Transaction;

  /**
   * Close the database connection.
   */
  close(): void;
}

/**
 * Returns the native CybouDB engine version.
 */
export function version(): string;
