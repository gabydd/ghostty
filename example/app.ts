import { importObject, setFiles, setStdin, setWasmModule, zjs } from "./imports";
import { old } from "./old";

const url = new URL("ghostty-wasm.wasm", import.meta.url);
fetch(url.href)
  .then((response) => response.arrayBuffer())
  .then((bytes) => WebAssembly.instantiate(bytes, importObject))
  .then(async (results) => {
    const memory = importObject.env.memory;
    const {
      malloc,
      run,
      draw,
    } = results.instance.exports;

    // Give us access to the zjs value for debugging.
    globalThis.zjs = zjs;
    console.log(zjs);

    // Initialize our zig-js memory
    zjs.memory = memory;

    // Helpers
    const makeStr = (str) => {
      const utf8 = new TextEncoder().encode(str);
      const ptr = malloc(utf8.byteLength);
      new Uint8Array(memory.buffer, ptr).set(utf8);
      return { ptr: ptr, len: utf8.byteLength };
    };

    // Create our config
    const config_str = makeStr("font-family = monospace\nfont-size = 32\n");
    // old(results);
    setWasmModule(results.module);
    const stdin = new SharedArrayBuffer(1024);
    const files = {
      nextFd: new SharedArrayBuffer(4),
      polling: new SharedArrayBuffer(4),
      has: new SharedArrayBuffer(1024),
    }
    new Int32Array(files.nextFd)[0] = 4;
    setFiles(files);
    setStdin(stdin);
    run(config_str.ptr, config_str.len);
    await new Promise((resolve) => setTimeout(resolve, 500))
    const io = new Uint8ClampedArray(stdin, 4);
    const text = new TextEncoder().encode("hello world\r\n");
    io.set(text);
    const n = new Int32Array(stdin);
    Atomics.store(n, 0, text.length)
    Atomics.notify(n, 0);
    function drawing() {
      requestAnimationFrame(() => {
        draw();
        drawing();
      });

    }
    drawing()
    setInterval(() => {
      // const text = new TextEncoder().encode("🐏\n\r👍🏽\n\rM_ghostty\033[2;2H\033[48;2;240;40;40m\033[38;2;23;255;80mhello");
      const text = new TextEncoder().encode("🐏\r\n👍🏽\r\nM_ghostty\033[48;2;240;40;40m\033[38;2;23;255;80mhello\r\n");
      const n = new Int32Array(stdin);
      const place = Atomics.add(n, 0, text.length)
      const io = new Uint8ClampedArray(stdin, 4 + place);
      io.set(text);
      Atomics.notify(n, 0);
    }, 5000)
  })
