(function () {
  // One controller per search surface. Results are projections, not entity-cache writes.
  function createController(options = {}) {
    const fetchImpl = options.fetchImpl || ((...args) => fetch(...args));
    const setTimer = options.setTimer || setTimeout;
    const clearTimer = options.clearTimer || clearTimeout;
    const getUrl = options.getSearchUrl || (() => getSearchUrl());
    const getWorkspace = options.getWorkspace || (() => currentWorkspaceId);
    let timer = null;
    let controller = null;
    let generation = 0;

    function cancel() {
      generation++;
      if (timer !== null) clearTimer(timer);
      timer = null;
      controller?.abort();
      controller = null;
    }

    function search(request, { debounce = 0, onResult, onError } = {}) {
      cancel();
      const body = { ...request, workspace: getWorkspace(), conv_id: "0" };
      const requestGeneration = generation;
      const active = () => requestGeneration === generation &&
        body.workspace === getWorkspace();
      const run = async () => {
        timer = null;
        if (!active()) return;
        controller = new AbortController();
        const signal = controller.signal;
        try {
          const response = await fetchImpl(getUrl(), {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body), signal,
          });
          if (!response.ok) throw new Error(`search service returned ${response.status}`);
          if (body.filters && response.headers?.get?.("X-NRC-Search-Version") !== "typed-v1") {
            throw new Error("search service does not support typed search");
          }
          const data = await response.json();
          if (!active() || signal.aborted) return;
          const results = data.results == null ? [] : data.results;
          if (!Array.isArray(results)) throw new Error("search service returned invalid results");
          onResult?.({ ...data, results });
        } catch (error) {
          if (active() && !signal.aborted && error?.name !== "AbortError") onError?.(error);
        } finally {
          if (requestGeneration === generation) controller = null;
        }
      };
      if (debounce) timer = setTimer(run, debounce);
      else run();
    }

    return { search, cancel };
  }
  window.NRCSearch = { createController };
})();
