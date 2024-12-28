export function createFile(fd: number, name: string, size: number): WasiFile {
  return {
    fd: fd,
    name: name,
    size: size,
    pos: new SharedArrayBuffer(4),
    bytes: new SharedArrayBuffer(size),
    reading: new Uint8ClampedArray(0),
  }
}
export type WasiFile = {
  fd: number;
  name: string;
  size: number;
  pos: SharedArrayBuffer;
  bytes: SharedArrayBuffer;
  reading: Uint8ClampedArray;
  
}

export function writeFile(file: WasiFile, content: Uint8Array) {
  while (content.length > 0) {
    const pos = new Int32Array(file.pos);
    Atomics.wait(pos, 0, file.size);
    const off = Atomics.load(pos, 0);
    const place = Math.min(content.length + off, file.size);
    Atomics.store(pos, 0, place)
    const io = new Uint8ClampedArray(file.bytes, off);
    io.set(content.slice(0, place - off));
    content = content.slice(place - off);
    Atomics.notify(pos, 0);
    if (file.fd === 1) {
      console.error(place);
    }
  }
}

export function readFile(file: WasiFile) {
  if (file.reading.length != 0) return file.reading;
  const len = new Int32Array(file.pos);
  // for blocking read need something like this
  // if (len[0] == 0) {
  //   Atomics.wait(len, 0, 0, 1000);
  // }
  const length = len[0];
  if (length === 0) {
    return file.reading;
  }
  const bytes = new Uint8ClampedArray(file.bytes, 0, length).slice();
  file.reading = bytes;
  Atomics.store(len, 0, 0);
  Atomics.notify(len, 0);
  return bytes;
}
