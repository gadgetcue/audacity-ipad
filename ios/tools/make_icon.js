// Placeholder 1024x1024 app icon (opaque, as iOS requires): blue gradient + white waveform bars.
const zlib = require('zlib'), fs = require('fs');
const N = 1024, buf = Buffer.alloc((N * 3 + 1) * N);
const bars = [0.22,0.38,0.62,0.86,0.58,0.95,0.7,0.45,0.78,0.52,0.3,0.18];
for (let y = 0; y < N; y++) {
  buf[y * (N * 3 + 1)] = 0;
  for (let x = 0; x < N; x++) {
    const t = (x + y) / (2 * N);
    let r = 10 + 60 * t, g = 120 + 60 * t, b = 245 - 20 * t; // #0A78F5 -> lighter
    const bw = 44, gap = 22, total = bars.length * bw + (bars.length - 1) * gap, x0 = (N - total) / 2;
    const i = Math.floor((x - x0) / (bw + gap)), off = (x - x0) - i * (bw + gap);
    if (i >= 0 && i < bars.length && off < bw) {
      const h = bars[i] * 560, cy = N / 2, top = cy - h / 2, bot = cy + h / 2, rad = bw / 2, cx = off - rad;
      let inside = y >= top + rad && y <= bot - rad;
      if (!inside && y < top + rad) inside = cx * cx + (y - (top + rad)) ** 2 <= rad * rad;
      if (!inside && y > bot - rad) inside = cx * cx + (y - (bot - rad)) ** 2 <= rad * rad;
      if (inside) { r = g = b = 255; }
    }
    const p = y * (N * 3 + 1) + 1 + x * 3; buf[p] = r; buf[p + 1] = g; buf[p + 2] = b;
  }
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32 ? zlib.crc32(td) >>> 0 : crc32(td));
  return Buffer.concat([len, td, crc]);
}
function crc32(b) { let c, crc = 0xffffffff; for (const v of b) { c = (crc ^ v) & 0xff; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crc = (crc >>> 8) ^ c; } return (crc ^ 0xffffffff) >>> 0; }
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(N, 0); ihdr.writeUInt32BE(N, 4); ihdr[8] = 8; ihdr[9] = 2;
fs.writeFileSync(process.argv[2], Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(buf)), chunk('IEND', Buffer.alloc(0))]));
