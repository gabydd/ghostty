import { importObject, zjs } from "./imports";
import { old } from "./old";

const url = new URL("ghostty-wasm.wasm", import.meta.url);
fetch(url.href)
  .then((response) => response.arrayBuffer())
  .then((bytes) => WebAssembly.instantiate(bytes, importObject))
  .then((results) => {
    const memory = importObject.env.memory;
    const {
      malloc,
      run,
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
    const config_str = makeStr("font-family = monospace\nfont-size 32\n");
    old(results);
    run(config_str.ptr, config_str.len);
  })
