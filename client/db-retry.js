// Retry only explicit pre-admission refusals. Never retry a lost response or
// carry a mutation across WebSocket sessions: its outcome may be unknown.
window.NRCDBRetry = {
  create({ getSocket, send, dispatch, decode }) {
    const pending = new Map();
    let bytes = 0;
    const codes = new Map([["db_connection_overloaded", 50], ["db_worker_overloaded", 150]]);
    function remove(id) {
      const entry = pending.get(id);
      if (!entry) return;
      clearTimeout(entry.expiry);
      clearTimeout(entry.retry);
      bytes -= entry.packet.byteLength;
      pending.delete(id);
    }
    function clear() {
      for (const id of pending.keys()) remove(id);
    }
    function track(packet, id) {
      if (!id || !(packet instanceof ArrayBuffer) || packet.byteLength < 2) return;
      id = id >>> 0;
      remove(id);
      // A short, bounded retry window. If tracking is full, the normal error
      // path still works; no request is dropped or delayed here.
      if (pending.size >= 128 || packet.byteLength > 8 * 1024 * 1024 - bytes) return;
      const entry = { packet: packet.slice(0), socket: getSocket(), attempts: 0,
        deadline: performance.now() + 2000, retry: null, expiry: null, refusal: null };
      pending.set(id, entry);
      bytes += entry.packet.byteLength;
      entry.expiry = setTimeout(() => {
        const refusal = entry.retry !== null ? entry.refusal : null;
        remove(id);
        if (refusal && getSocket() === entry.socket && entry.socket?.readyState === 1) dispatch(refusal);
      }, 2000);
    }
    function receive(view) {
      if (!pending.size || view.byteLength < 2) return false;
      const opcode = view.getUint16(0);
      // Mutation replies end in their correlation ID; transaction results put
      // it after the version. Clear before normal dispatch, even for large bodies.
      const mutationRequests = {121:16, 122:17, 124:18, 130:20, 131:21, 132:22, 133:23, 140:30, 141:31, 142:32, 150:40, 151:41, 137:27};
      if (mutationRequests[opcode] && view.byteLength >= 8) {
        const id = view.getUint32(opcode === 137 || opcode === 122 ? 4 : view.byteLength - 4);
        const entry = pending.get(id);
        if (entry && new DataView(entry.packet).getUint16(0) === mutationRequests[opcode]) remove(id);
        return false;
      }
      if (view.byteLength > 1024) return false;
      // Only error-capable small frames are decoded here. Large record pages
      // are not parsed a second time and cannot be admission refusals.
      if (![104, 123, 168].includes(opcode) &&
          !([134, 135, 136, 138, 164, 167].includes(opcode) && view.byteLength > 10 && view.getUint8(10) === 0)) return false;
      let response;
      try { response = decode(view); } catch { return false; }
      const code = response?.errorMsg ?? response?.error ?? response?.message ?? response?.page?.error;
      const id = response.correlationId >>> 0;
      const entry = pending.get(id);
      if (!entry) return false;
      const requestOpcode = new DataView(entry.packet).getUint16(0);
      if (opcode === 104) {
        if (response.originOpcode !== requestOpcode) return false;
      } else {
        const requests = {123:[16,17,18], 134:[20,21,22,23,24], 135:[25,60], 136:[26], 138:[28], 164:[56], 167:[59], 168:[62]};
        if (!requests[opcode]?.includes(requestOpcode)) return false;
      }
      if (!codes.has(code)) { remove(id); return false; }
      if (getSocket() !== entry.socket || entry.attempts >= 3 || performance.now() >= entry.deadline) {
        remove(id); return false;
      }
      if (entry.retry !== null) return true;
      const base = codes.get(code) * 2 ** entry.attempts;
      const delay = base + Math.random() * base / 2;
      if (performance.now() + delay >= entry.deadline) { remove(id); return false; }
      entry.refusal = view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength);
      entry.retry = setTimeout(() => {
        entry.retry = null;
        if (getSocket() !== entry.socket || entry.socket?.readyState !== 1) { remove(id); return; }
        if (performance.now() >= entry.deadline) {
          const refusal = entry.refusal; remove(id); dispatch(refusal); return;
        }
        entry.attempts++;
        send(entry.packet);
      }, delay);
      return true;
    }
    return { track, receive, clear };
  },
};
