/*
 * A minimal PNG writer: 8-bit RGB or RGBA, no interlace — as
 * simulator/tools/snap.js writes its frames.
 */
import zlib from 'node:zlib';

const CRC = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  CRC[n] = c >>> 0;
}
function crc(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC[(c ^ b) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body));
  return Buffer.concat([length, body, sum]);
}

/* `pixels`: w x h, `channels` bytes each (3, RGB; 4, RGBA), rows top to bottom. */
export function png(w, h, pixels, channels = 3) {
  const row = w * channels;
  const raw = Buffer.alloc((row + 1) * h);              // each row: filter 0, then its pixels
  for (let y = 0; y < h; y++) pixels.copy(raw, y * (row + 1) + 1, y * row, (y + 1) * row);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(w, 0); header.writeUInt32BE(h, 4);
  header[8] = 8; header[9] = channels === 4 ? 6 : 2;    // 8 bits, RGBA or RGB
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
