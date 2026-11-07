/// JavaScript evaluated in every script context before the user's code: the built-in library and `__run`,
/// which builds the `flow` object, calls `handle(flow)` and hands the result back to Swift.
let prelude = #"""
(function (g) {
  const N = g.__native;
  delete g.__native;

  function toBytes(v) {
    if (v instanceof Uint8Array) return v;
    if (typeof v === "string") return N.utf8Encode(v);
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    if (Array.isArray(v)) return new Uint8Array(v);
    throw new TypeError("Expected a string or bytes");
  }

  function show(x) {
    if (typeof x === "string") return x;
    if (x instanceof Error) return String(x);
    if (x === undefined) return "undefined";
    if (x instanceof Uint8Array) return "Uint8Array(" + x.length + ")";
    try { const s = JSON.stringify(x); return s === undefined ? String(x) : s; } catch (e) { return String(x); }
  }

  function logger(level) {
    return function () { N.log(level, Array.prototype.map.call(arguments, show).join(" ")); };
  }
  g.console = { log: logger("log"), info: logger("info"), warn: logger("warn"), error: logger("error"), debug: logger("log") };

  g.utf8 = {
    encode: function (s) { return N.utf8Encode(String(s)); },
    decode: function (b) { return N.utf8Decode(toBytes(b)); },
  };
  g.base64 = {
    encode: function (v) { return N.base64Encode(toBytes(v)); },
    decode: function (s) { return N.base64Decode(String(s)); },
  };
  g.btoa = function (s) {
    s = String(s);
    const bytes = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c > 255) throw new Error("btoa: the string contains characters outside of the Latin-1 range");
      bytes[i] = c;
    }
    return N.base64Encode(bytes);
  };
  g.atob = function (s) {
    const bytes = N.base64Decode(String(s));
    let out = "";
    for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    return out;
  };
  g.crypto = {
    md5: function (v) { return N.hash("md5", toBytes(v)); },
    sha1: function (v) { return N.hash("sha1", toBytes(v)); },
    sha256: function (v) { return N.hash("sha256", toBytes(v)); },
    sha512: function (v) { return N.hash("sha512", toBytes(v)); },
    hmac: function (alg, key, msg) { return N.hmac(String(alg).toLowerCase(), toBytes(key), toBytes(msg)); },
  };

  function headerObject(list) {
    const obj = {};
    for (const [name, value] of list) {
      const key = Object.keys(obj).find(function (k) { return k.toLowerCase() === name.toLowerCase(); });
      if (key === undefined) obj[name] = value;
      else if (Array.isArray(obj[key])) obj[key].push(value);
      else obj[key] = [obj[key], value];
    }
    return obj;
  }

  function headerList(obj) {
    const list = [];
    if (obj === null || typeof obj !== "object") return list;
    for (const name of Object.keys(obj)) {
      const v = obj[name];
      if (v === undefined || v === null) continue;
      if (Array.isArray(v)) { for (const x of v) list.push([name, String(x)]); }
      else list.push([name, String(v)]);
    }
    return list;
  }

  function message(m, bytes) {
    const headers = headerObject(m.headers);
    return { method: m.method, url: m.url, status: m.status, headers: headers,
             body: N.utf8Decode(bytes), bodyBytes: bytes, headerSnapshot: JSON.stringify(headerList(headers)) };
  }

  /// `original` is the message as the script received it, or null for a response the script created.
  function exported(m, original) {
    if (m === null || typeof m !== "object") throw new TypeError("flow.response must be an object");
    const out = { method: String(m.method === undefined ? "" : m.method), url: String(m.url === undefined ? "" : m.url),
                  status: m.status === undefined ? null : Number(m.status), headers: headerList(m.headers),
                  headersChanged: true, bodyChanged: true, bytes: null };
    if (original !== null && JSON.stringify(out.headers) === original.headerSnapshot) out.headersChanged = false;
    if (original !== null && m.bodyBytes === original.bodyBytes && m.body === original.body) {
      out.bodyChanged = false;
      out.bytes = original.bodyBytes;
    } else if (original === null ? m.bodyBytes !== undefined : m.bodyBytes !== original.bodyBytes) {
      out.bytes = m.bodyBytes === null || m.bodyBytes === undefined ? new Uint8Array(0) : toBytes(m.bodyBytes);
    } else {
      const b = m.body;
      if (b === null || b === undefined) out.bytes = new Uint8Array(0);
      else if (typeof b === "string") out.bytes = N.utf8Encode(b);
      else if (typeof b === "object") out.bytes = N.utf8Encode(JSON.stringify(b));
      else throw new TypeError("body must be a string, an object or null");
    }
    return out;
  }

  g.__run = function (input, requestBytes, responseBytes, shared) {
    g.$shared = JSON.parse(shared);
    if (typeof handle !== "function") throw new Error("The script has no handle(flow) function");
    const request = message(input.request, requestBytes);
    delete request.status;
    const original = { request: { body: request.body, bodyBytes: request.bodyBytes, headerSnapshot: request.headerSnapshot } };
    delete request.headerSnapshot;
    let response;
    if (input.response) {
      response = message(input.response, responseBytes);
      delete response.method;
      delete response.url;
      original.response = { body: response.body, bodyBytes: response.bodyBytes, headerSnapshot: response.headerSnapshot };
      delete response.headerSnapshot;
    }
    let aborted = false;
    const flow = { phase: input.phase, id: input.id, request: request, response: response,
                   abort: function () { aborted = true; } };
    handle(flow);
    const out = { aborted: aborted, shared: JSON.stringify(g.$shared === undefined ? {} : g.$shared) };
    if (aborted) return out;
    out.request = exported(flow.request, original.request);
    if (flow.response !== undefined && flow.response !== null) {
      out.response = exported(flow.response, flow.response === response ? original.response : null);
    }
    return out;
  };
})(this);
"""#
