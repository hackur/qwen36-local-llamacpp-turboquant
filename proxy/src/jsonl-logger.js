// Per-request JSONL logger. One file per UTC day under <cache_dir>/logs/.
import { mkdirSync, createWriteStream } from "node:fs";
import { resolve } from "node:path";

export class JsonlLogger {
  constructor({ cacheDir }) {
    this.dir = resolve(cacheDir, "logs");
    mkdirSync(this.dir, { recursive: true });
    this.streams = new Map(); // YYYY-MM-DD -> WriteStream
  }

  streamFor(date) {
    if (this.streams.has(date)) return this.streams.get(date);
    const path = resolve(this.dir, `${date}.jsonl`);
    const s = createWriteStream(path, { flags: "a" });
    this.streams.set(date, s);
    return s;
  }

  write(record) {
    const ts = record.timestamp || new Date().toISOString();
    const date = ts.slice(0, 10);
    const line = JSON.stringify({ ...record, timestamp: ts }) + "\n";
    this.streamFor(date).write(line);
  }

  closeAll() {
    for (const s of this.streams.values()) s.end();
    this.streams.clear();
  }
}
