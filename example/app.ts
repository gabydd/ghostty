import { createFile, writeFile } from "./file";
import { fdStart, importObject, setFiles, setWasmModule, zjs } from "./imports";
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
      handleKey,
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
    const config_str = makeStr("font-family = monospace\nfont-size = 24\n");
    // old(results);
    setWasmModule(results.module);
    const stdin = createFile(0, "stdin", 655336);
    const stdout = createFile(1, "stdout", 655336);

    const files = {
      nextFd: new SharedArrayBuffer(4),
      eventFd: new SharedArrayBuffer(1024),
      io: [stdin, stdout]
    }
    new Int32Array(files.nextFd)[0] = fdStart;
    setFiles(files);
    run(config_str.ptr, config_str.len);
    await new Promise((resolve) => setTimeout(resolve, 500))
    // const text = new TextEncoder().encode("hello world\r\n");
    // writeFile(stdin, text);
    function drawing() {
      requestAnimationFrame(() => {
        draw();
        drawing();
      });

    }
    drawing()
    function keyToKey(key: string) {
      switch (key.toLowerCase()) {
        case "a": return 1;
        case "b": return 2;
        case "c": return 3;
        case "d": return 4;
        case "e": return 5;
        case "f": return 6;
        case "g": return 7;
        case "h": return 8;
        case "i": return 9;
        case "j": return 10;
        case "k": return 11;
        case "l": return 12;
        case "m": return 13;
        case "n": return 14;
        case "o": return 15;
        case "p": return 16;
        case "q": return 17;
        case "r": return 18;
        case "s": return 19;
        case "t": return 20;
        case "u": return 21;
        case "v": return 22;
        case "w": return 23;
        case "x": return 24;
        case "y": return 25;
        case "z": return 26;
        case "0": return 27;
        case "1": return 28;
        case "2": return 29;
        case "3": return 30;
        case "4": return 31;
        case "5": return 32;
        case "6": return 33;
        case "7": return 34;
        case "8": return 35;
        case "9": return 36;
        case ";": return 37;
        case " ": return 38;
        case "'": return 39;
        case ",": return 40;
        case "`": return 41;
        case ".": return 42;
        case "/": return 43;
        case "-": return 44;
        case "+": return 45;
        case "=": return 46;
        case "[": return 47;
        case "]": return 48;
        case "\\": return 49;
        case "arrowup": return 50;
        case "arrowdown": return 51;
        case "arrowright": return 52;
        case "arrowleft": return 53;
        case "home": return 54;
        case "end": return 55;
        case "insert": return 56;
        case "delete": return 57;
        case "capslock": return 58;
        case "scrolllock": return 59;
        case "numlock": return 60;
        case "pageup": return 61;
        case "pagedown": return 62;
        case "escape": return 63;
        case "enter": return 64;
        case "tab": return 65;
        case "backspace": return 66;
      }
    }
    function toUTF8(key: string) {
      if (key.length === 1) return key.charCodeAt(0);
      switch (key) {
        case "Enter": return "\r".charCodeAt(0);
        case "Backspace": return 0x7F;
        case "ArrowUp": return 0;
        case "ArrowDown": return 0;
        case "ArrowLeft": return 0;
        case "ArrowRight": return 0;
      }
    }
    const textEncoder = new TextEncoder();
    window.addEventListener("keydown", (event) => {
      console.log(keyToKey(event.key))
      handleKey(1, toUTF8(event.key), keyToKey(event.key), event.shiftKey, event.ctrlKey, event.altKey, event.metaKey);
      
    });
    window.addEventListener("keyup", (event) => {
      handleKey(0, toUTF8(event.key), keyToKey(event.key), event.shiftKey, event.ctrlKey, event.altKey, event.metaKey);
      
    });
    // setInterval(() => {
    //   // const text = new TextEncoder().encode("🐏\n\r👍🏽\n\rM_ghostty\033[2;2H\033[48;2;240;40;40m\033[38;2;23;255;80mhello");
    //   const text = new TextEncoder().encode("🐏\r\n👍🏽\r\nM_ghostty\033[48;2;240;40;40m\033[38;2;23;255;80mhello\r\n");
    //   writeFile(stdin, text);
    // }, 10000)
  })
