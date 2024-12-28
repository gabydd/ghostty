import { importObject, setChildThread, setFiles, setMainThread, zjs } from "./imports";

onmessage = async (e) => {
  console.log("module received from main thread");
  const [memory, instance, wasmModule, files, pid] = e.data;
  console.log(wasmModule)
  setMainThread(false);
  const temp = files.io[0];
  files.io[0] = files.io[1];
  files.io[1] = temp;
  console.log(files);
  setChildThread(true);
  setFiles(files);
  importObject.env.memory = new WebAssembly.Memory({shared: true, initial: 512, maximum: 65536});
  const results = await WebAssembly.instantiateStreaming(fetch(new URL("test.wasm", import.meta.url)), importObject);
  zjs.memory = importObject.env.memory;
  console.log(results.instance.exports)
  results.instance.exports.main();
};
