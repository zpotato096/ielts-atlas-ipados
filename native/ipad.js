(() => {
  "use strict";
  const bridge = window.webkit?.messageHandlers?.atlasPort;
  if (!bridge || window !== top || document.__atlasIPad) return;
  Object.defineProperty(document, "__atlasIPad", { value: true });
  const local = location.origin === "http://127.0.0.1:49173";
  const home =
    local && (location.pathname === "/" || location.pathname === "/index.html");
  const port = (op, rest = {}) => bridge.postMessage({ op, ...rest });
  const report = (e) => {
    if (String(e?.message ?? e).includes("ATLAS_CANCEL")) return;
    const message = String(e?.message ?? e);
    if (typeof window.showMessage === "function")
      window.showMessage(message, "error");
    else alert(message);
  };
  function ask(op, values) {
    port(op, values).catch(report);
  }
  if (local || location.protocol === "blob:") {
    // Hold the actual Blob through the click: upstream revokes the temporary URL immediately after click().
    const blobs = new Map();
    try {
      const focus = window.focus.bind(window);
      window.focus = function () {
        port("focus").catch(() => {});
        return focus();
      };
    } catch {
      /* Some transient documents fix this property. */
    }
    const create = URL.createObjectURL.bind(URL),
      revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (value) => {
      const url = create(value);
      if (value instanceof Blob) blobs.set(url, value);
      return url;
    };
    URL.revokeObjectURL = (url) => {
      blobs.delete(String(url));
      return revoke(url);
    };
    async function saveBlob(blob, name) {
      const reader = new FileReader();
      const encoded = new Promise((ok, fail) => {
        reader.onload = () => ok(String(reader.result).split(",")[1]);
        reader.onerror = () => fail(reader.error);
      });
      reader.readAsDataURL(blob);
      await port("download", { name, data: await encoded });
    }
    function captureLink(a) {
      if (!a || !a.hasAttribute("download") || !blobs.has(a.href)) return false;
      const blob = blobs.get(a.href);
      saveBlob(blob, a.download || "IELTS-Atlas").catch(report);
      return true;
    }
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
      if (!captureLink(this)) return click.call(this);
    };
    document.addEventListener(
      "click",
      (e) => {
        const a = e.target.closest?.("a[download]");
        if (a && captureLink(a)) {
          e.preventDefault();
          e.stopImmediatePropagation();
        }
      },
      true,
    );
    window.addEventListener("message", (e) => {
      if (
        (e.source === window.opener || e.source === window.parent) &&
        e.data?.type === "PRACTICE_SUBMIT_ACK"
      )
        ask("completed");
    });
  }
  if (!home) return;
  const diskName =
    /^ielts-atlas-backup-(?:latest|\d{4}-\d{2}-\d{2}(?:-\d{9})?)\.json$/;
  async function disk(handle, action, name, text) {
    return port("disk", {
      token: handle.atlasDisk,
      action,
      name: name || "",
      text: text || "",
    });
  }
  class Directory {
    constructor(ref) {
      this.kind = "directory";
      this.name = ref.name;
      this.atlasDisk = ref.token;
    }
    async queryPermission() {
      return disk(this, "permission");
    }
    async requestPermission() {
      return this.queryPermission();
    }
    async getFileHandle(name, opts = {}) {
      if (!diskName.test(name))
        throw new DOMException("备份文件名无效", "NotAllowedError");
      if (!opts.create && !(await disk(this, "exists", name)))
        throw new DOMException("文件不存在", "NotFoundError");
      const folder = this;
      return {
        kind: "file",
        name,
        async getFile() {
          return new File([await disk(folder, "read", name)], name, {
            type: "application/json",
          });
        },
        async createWritable() {
          let value;
          return {
            async write(src) {
              value =
                typeof src === "string" ? src : await new Blob([src]).text();
            },
            async close() {
              await disk(folder, "write", name, value);
            },
            async abort() {
              value = null;
            },
          };
        },
      };
    }
    async *values() {
      for (const name of await disk(this, "list"))
        if (diskName.test(name)) yield { kind: "file", name };
    }
  }
  if (!window.showDirectoryPicker) {
    window.showDirectoryPicker = async (opts) => {
      if (opts?.id !== "ielts-atlas-external-backup")
        throw new DOMException("仅用于学习备份", "NotSupportedError");
      try {
        return new Directory(await port("chooseBackupDirectory"));
      } catch (e) {
        if (String(e).includes("ATLAS_CANCEL"))
          throw new DOMException("已取消", "AbortError");
        throw e;
      }
    };
    const get = IDBObjectStore.prototype.get;
    IDBObjectStore.prototype.get = function (key) {
      const req = get.apply(this, arguments);
      if (
        this.transaction.db.name === "IELTSAtlasExternalBackupV2" &&
        this.name === "binding" &&
        key === "directory-handle"
      )
        req.addEventListener("success", () => {
          if (req.result?.atlasDisk)
            Object.setPrototypeOf(req.result, Directory.prototype);
        });
      return req;
    };
  }
  const uri = (vol, path) =>
    "/_atlas/material/" +
    encodeURIComponent(vol) +
    "/" +
    path.split("/").map(encodeURIComponent).join("/");
  function patchLibraries() {
    const discovery = window.LibraryDiscovery;
    if (!discovery || discovery.__atlasPort) return;
    const scan = discovery.discover.bind(discovery),
      resolve = discovery.resolveRuntimeResource.bind(discovery);
    discovery.discover = async function (files, opts) {
      const vol = files?.[0]?.atlasVolume;
      if (!vol) return scan(files, opts);
      const data = await scan(files, { ...opts, registerRuntime: false });
      for (const e of data.entries) {
        e.atlasVolume = vol;
        e.runtimeResourceMode = "ipad-files";
      }
      return data;
    };
    discovery.resolveRuntimeResource = (e, kind) => {
      if (!e?.atlasVolume) return resolve(e, kind);
      const file = kind === "pdf" ? e.pdfFilename : e.filename;
      return file ? uri(e.atlasVolume, String(e.path || "") + file) : "";
    };
    Object.defineProperty(discovery, "__atlasPort", { value: true });
  }
  async function pickLibrary(input) {
    const result = await port("chooseLibrary");
    patchLibraries();
    const list = result.paths.map((path) => ({
      name: path.split("/").at(-1),
      webkitRelativePath: path,
      atlasVolume: result.volume,
      async text() {
        const r = await fetch(uri(result.volume, path));
        if (!r.ok) throw new Error("无法读取题源 " + path);
        return r.text();
      },
    }));
    Object.defineProperty(input, "files", { configurable: true, value: list });
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }
  const directoryInput = (t) =>
    t instanceof HTMLInputElement &&
    t.type === "file" &&
    (t.hasAttribute("webkitdirectory") ||
      /^(reading|listening)-(full|inc)-input$/.test(t.id));
  const inputClick = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function () {
    if (directoryInput(this)) {
      pickLibrary(this).catch(report);
      return;
    }
    return inputClick.apply(this, arguments);
  };
  document.addEventListener(
    "click",
    (e) => {
      if (directoryInput(e.target)) {
        e.preventDefault();
        e.stopImmediatePropagation();
        pickLibrary(e.target).catch(report);
      }
    },
    true,
  );
  let subscribed = false;
  const offered = new Set();
  function attach() {
    patchLibraries();
    const manager = document.getElementById("library-manager-btn");
    if (manager && !document.getElementById("atlas-mount-extensions")) {
      const b = document.createElement("button");
      b.className = manager.className;
      b.id = "atlas-mount-extensions";
      b.type = "button";
      b.textContent = "导入原版扩展目录";
      b.addEventListener("click", () =>
        port("chooseExtensions")
          .then(() => location.reload())
          .catch(report),
      );
      manager.parentElement.appendChild(b);
    }
    const anchor = document.getElementById("import-data-btn");
    if (anchor && !document.getElementById("atlas-export-memory")) {
      for (const [op, id, text] of [
        ["exportMemory", "atlas-export-memory", "导出 iPad 记忆文件"],
        ["importMemory", "atlas-import-memory", "恢复 iPad 记忆文件"],
      ]) {
        const b = document.createElement("button");
        b.type = "button";
        b.id = id;
        b.className = anchor.className;
        b.textContent = text;
        b.addEventListener("click", () => ask(op));
        anchor.parentElement.appendChild(b);
      }
    }
    if (!subscribed && window.AppData?.backups) {
      subscribed = true;
      window.AppData.backups.onDataCommitted((event) => {
        const ids = (event.targets || [])
          .filter(
            (x) =>
              x.store === "practiceSummaries" &&
              x.type === "upsert" &&
              x.recordId,
          )
          .map((x) => x.recordId);
        if (ids.some((id) => !offered.has(id))) {
          ids.forEach((id) => offered.add(id));
          ask("completed");
        }
      });
    }
  }
  document.addEventListener("DOMContentLoaded", attach);
  window.addEventListener("load", attach);
  const timer = setInterval(() => {
    attach();
    if (
      subscribed &&
      window.LibraryDiscovery?.__atlasPort &&
      document.getElementById("atlas-export-memory")
    )
      clearInterval(timer);
  }, 300);
})();
