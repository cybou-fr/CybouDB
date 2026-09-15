const path = require('path');
const fs = require('fs');

let nativeBinding = null;

const candidates = [
  path.join(__dirname, 'cyboudb.node'),
  path.join(__dirname, 'cyboudb_node.node'),
  path.join(__dirname, 'target', 'release', 'cyboudb_node.node'),
  path.join(__dirname, 'target', 'release', 'cyboudb_node.dll'),
  path.join(__dirname, 'target', 'debug', 'cyboudb_node.node'),
  path.join(__dirname, 'target', 'debug', 'cyboudb_node.dll'),
];

for (const candidate of candidates) {
  if (fs.existsSync(candidate)) {
    try {
      nativeBinding = require(candidate);
      break;
    } catch (e) {
      // try next candidate
    }
  }
}

if (!nativeBinding) {
  throw new Error('Failed to load CybouDB native addon. Searched candidates: ' + candidates.join(', '));
}

const { Database, Transaction, version } = nativeBinding;

Database.prototype.transaction = function(fn) {
  const tx = this.beginTransaction();
  try {
    const result = fn(tx);
    tx.commit();
    return result;
  } catch (err) {
    try {
      tx.rollback();
    } catch (_) {}
    throw err;
  }
};

module.exports = {
  Database,
  Transaction,
  version,
};
