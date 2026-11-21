/* Portable, same-version WebKit profile. The official v2 payload is included for validation and desktop interoperability. */
(() => {
  "use strict";
  if (location.origin !== "http://127.0.0.1:49173" || window.AtlasMemory)
    return;
  const marker = "__atlas_value__";
  const format = "ielts-atlas-ipad-memory";
  const externalBinding = "IELTSAtlasExternalBackupV2";
  const request = (r) =>
    new Promise((resolve, reject) => {
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
      r.onblocked = () => reject(new Error("数据存储正由另一窗口使用"));
    });
  const completed = (tx) =>
    new Promise((resolve, reject) => {
      tx.oncomplete = resolve;
      tx.onabort = tx.onerror = () =>
        reject(tx.error || new Error("数据事务中断"));
    });
  function b64(bytes) {
    let s = "";
    for (let start = 0; start < bytes.length; start += 16384)
      s += String.fromCharCode(...bytes.subarray(start, start + 16384));
    return btoa(s);
  }
  const bytes = (s) => Uint8Array.from(atob(s), (ch) => ch.charCodeAt(0));
  const tagged = (type, value) => ({ [marker]: type, value });
  async function pack(v) {
    if (v === undefined) return tagged("undefined", null);
    if (v === null || typeof v === "string" || typeof v === "boolean") return v;
    if (typeof v === "number")
      return Number.isFinite(v) && !Object.is(v, -0)
        ? v
        : tagged("number", Object.is(v, -0) ? "-0" : String(v));
    if (typeof v === "bigint") return tagged("bigint", String(v));
    if (v instanceof Date) return tagged("date", v.getTime());
    if (v instanceof RegExp) return tagged("regexp", [v.source, v.flags]);
    if (v instanceof Blob)
      return tagged(v instanceof File ? "file" : "blob", [
        b64(new Uint8Array(await v.arrayBuffer())),
        v.type,
        v.name || "",
        v.lastModified || 0,
      ]);
    if (v instanceof ArrayBuffer)
      return tagged("buffer", b64(new Uint8Array(v)));
    if (ArrayBuffer.isView(v))
      return tagged("view", [
        v.constructor.name,
        b64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)),
      ]);
    if (v instanceof Map)
      return tagged(
        "map",
        await Promise.all(
          Array.from(v, async ([k, x]) => [await pack(k), await pack(x)]),
        ),
      );
    if (v instanceof Set)
      return tagged("set", await Promise.all(Array.from(v, pack)));
    if (Array.isArray(v)) return Promise.all(v.map(pack));
    if (Object.prototype.toString.call(v) !== "[object Object]")
      throw new Error(
        "无法完整备份数据类型 " + Object.prototype.toString.call(v),
      );
    const pairs = await Promise.all(
      Object.keys(v).map(async (k) => [k, await pack(v[k])]),
    );
    return Object.hasOwn(v, marker)
      ? tagged("object", pairs)
      : Object.fromEntries(pairs);
  }
  const views = Object.fromEntries(
    [
      Int8Array,
      Uint8Array,
      Uint8ClampedArray,
      Int16Array,
      Uint16Array,
      Int32Array,
      Uint32Array,
      BigInt64Array,
      BigUint64Array,
      Float32Array,
      Float64Array,
      DataView,
    ].map((t) => [t.name, t]),
  );
  function unpack(v) {
    if (!v || typeof v !== "object") return v;
    if (Array.isArray(v)) return v.map(unpack);
    if (!Object.hasOwn(v, marker))
      return Object.fromEntries(
        Object.entries(v).map(([k, x]) => [k, unpack(x)]),
      );
    const x = v.value;
    switch (v[marker]) {
      case "object":
        return Object.fromEntries(x.map(([k, y]) => [k, unpack(y)]));
      case "undefined":
        return undefined;
      case "number":
        return Number(x);
      case "bigint":
        return BigInt(x);
      case "date":
        return new Date(x);
      case "regexp":
        return new RegExp(...x);
      case "file":
        return new File([bytes(x[0])], x[2], {
          type: x[1],
          lastModified: x[3],
        });
      case "blob":
        return new Blob([bytes(x[0])], { type: x[1] });
      case "buffer":
        return bytes(x).buffer;
      case "view":
        if (!Object.hasOwn(views, x[0])) throw new Error("未知二进制格式");
        return new views[x[0]](bytes(x[1]).buffer);
      case "map":
        return new Map(x.map(([k, y]) => [unpack(k), unpack(y)]));
      case "set":
        return new Set(x.map(unpack));
      default:
        throw new Error("未知的备份数据类型");
    }
  }
  async function dumpDatabase(name) {
    const db = await request(indexedDB.open(name));
    try {
      const names = Array.from(db.objectStoreNames);
      if (!names.length) return { name, version: db.version, stores: [] };
      const tx = db.transaction(names, "readonly");
      const jobs = names.map(async (n) => {
        const s = tx.objectStore(n);
        const indexes = Array.from(s.indexNames, (i) => {
          const x = s.index(i);
          return {
            name: i,
            keyPath: x.keyPath,
            unique: x.unique,
            multiEntry: x.multiEntry,
          };
        });
        const meta = {
          name: n,
          keyPath: s.keyPath,
          autoIncrement: s.autoIncrement,
          indexes,
        };
        const [keys, values] = await Promise.all([
          request(s.getAllKeys()),
          request(s.getAll()),
        ]);
        meta.rows = await Promise.all(
          keys.map(async (k, i) => [await pack(k), await pack(values[i])]),
        );
        return meta;
      });
      const [stores] = await Promise.all([Promise.all(jobs), completed(tx)]);
      return { name, version: db.version, stores };
    } finally {
      db.close();
    }
  }
  async function capture() {
    const api = window.AppData?.backups;
    if (!api) throw new Error("学习数据正在加载，请稍后重试");
    const learning = await api.export();
    if (!api.validateSnapshot(learning)) throw new Error("原版备份校验失败");
    const names = (await indexedDB.databases())
      .map((d) => d.name)
      .filter((n) => n && n !== externalBinding)
      .sort();
    const preferences = Array.from({ length: localStorage.length }, (_, i) => {
      const k = localStorage.key(i);
      return [k, localStorage.getItem(k)];
    });
    if (!names.length) throw new Error("没有找到学习数据库");
    const databases = await Promise.all(names.map(dumpDatabase));
    return JSON.stringify({
      format,
      version: 1,
      appVersion: "0.6.3.2",
      createdAt: new Date().toISOString(),
      learning,
      preferences,
      databases,
    });
  }
  async function writeDatabase(d) {
    if (
      !d.name ||
      d.name === externalBinding ||
      !Number.isSafeInteger(d.version) ||
      !Array.isArray(d.stores)
    )
      throw new Error("数据库信息无效");
    const r = indexedDB.open(d.name, d.version);
    r.onupgradeneeded = () => {
      for (const s of d.stores) {
        const obj = r.result.createObjectStore(s.name, {
          keyPath: s.keyPath,
          autoIncrement: s.autoIncrement,
        });
        for (const i of s.indexes)
          obj.createIndex(i.name, i.keyPath, {
            unique: i.unique,
            multiEntry: i.multiEntry,
          });
      }
    };
    const db = await request(r);
    try {
      if (d.stores.length) {
        const tx = db.transaction(
          d.stores.map((s) => s.name),
          "readwrite",
        );
        const finish = completed(tx);
        try {
          for (const s of d.stores) {
            const obj = tx.objectStore(s.name);
            for (const [key, value] of s.rows) {
              if (s.keyPath === null) obj.add(unpack(value), unpack(key));
              else obj.add(unpack(value));
            }
          }
        } catch (err) {
          try {
            tx.abort();
          } catch {}
          await finish.catch(() => {});
          throw err;
        }
        await finish;
      }
    } finally {
      db.close();
    }
    const check = await dumpDatabase(d.name);
    if (JSON.stringify(check) !== JSON.stringify(d))
      throw new Error("恢复后校验失败：" + d.name);
  }
  async function loadCore() {
    if (!window.AppData)
      await new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "/js/bundles/core-foundation.bundle.js";
        s.onload = resolve;
        s.onerror = () => reject(new Error("无法载入数据模块"));
        document.head.appendChild(s);
      });
    await window.AppData.ready;
    return window.AppData.backups;
  }
  async function restore(text) {
    if (location.pathname !== "/_atlas/restore.html")
      throw new Error("请在恢复窗口中打开备份");
    if ((await indexedDB.databases()).length || localStorage.length)
      throw new Error("恢复空间需要为空");
    const data = JSON.parse(text);
    if (data.format === format) {
      if (
        data.version !== 1 ||
        !Array.isArray(data.databases) ||
        !data.databases.length ||
        !Array.isArray(data.preferences)
      )
        throw new Error("无效的 iPad 记忆文件");
      const names = new Set();
      for (const db of data.databases) {
        if (names.has(db.name)) throw new Error("重复的数据库");
        names.add(db.name);
        await writeDatabase(db);
      }
      for (const pair of data.preferences) {
        if (
          !Array.isArray(pair) ||
          pair.length !== 2 ||
          pair.some((x) => typeof x !== "string")
        )
          throw new Error("无效的偏好设置");
        localStorage.setItem(...pair);
      }
      const api = await loadCore();
      if (!api.validateSnapshot(data.learning))
        throw new Error("学习记录校验失败");
      const live = await api.export();
      if (!api.validateSnapshot(live))
        throw new Error("无法读取恢复的学习记录");
    } else {
      const api = await loadCore();
      if (!api.validateSnapshot(data))
        throw new Error("请选择原版导出的完整 v2 JSON 或 iPad 记忆文件");
      const preview = await api.previewImport(data, {
        replace: true,
        practiceMode: "replace",
        applyClears: true,
        fullRestore: true,
      });
      const result = await api.commitImport(preview.id, {
        operationId: "ipad-restore-" + crypto.randomUUID(),
        confirmDestructive: preview.destructive === true,
      });
      if (result?.committed !== true) throw new Error("恢复未能提交");
    }
    return true;
  }
  Object.defineProperty(window, "AtlasMemory", {
    value: Object.freeze({ capture, restore }),
  });
})();
