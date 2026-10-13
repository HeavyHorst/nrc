// Delay presentation, never the request or its busy/disabled state.
window.createLoadingIndicator = onChange => {
  let loading = false, visible = false, timer = null, generation = 0;
  return {
    update(next) {
      if (next === loading) return visible;
      loading = next;
      const current = ++generation;
      clearTimeout(timer);
      timer = null;
      visible = false;
      if (loading) timer = setTimeout(() => {
        if (current !== generation || !loading) return;
        timer = null;
        visible = true;
        onChange();
      }, 150);
      return visible;
    },
  };
};
