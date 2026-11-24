(() => {
  const list = document.querySelector('[data-list-filters]');
  if (!list) return;
  const path = list.dataset.listFilters;
  let pending;

  async function load(url, push) {
    pending?.abort();
    const request = new AbortController();
    pending = request;
    list.setAttribute('aria-busy', 'true');
    try {
      const response = await fetch(url, { signal: request.signal, mode: 'same-origin' });
      if (response.redirected || !response.ok) throw new Error('Full page required');
      const page = new DOMParser().parseFromString(await response.text(), 'text/html');
      if (request.signal.aborted) return;
      const next = page.querySelector('[data-list-filters]');
      if (next?.dataset.listFilters !== path) throw new Error('Missing list');
      const focused = document.activeElement;
      const restoreFocus = list.contains(focused);
      if (push && url.href !== location.href) history.pushState(null, '', url);
      list.replaceChildren(...next.childNodes);
      if (restoreFocus) {
        const match = focused instanceof HTMLAnchorElement
          ? Array.from(list.querySelectorAll('a[href]')).find(link => link.href === focused.href)
          : Array.from(list.querySelectorAll('form input, form select, form button')).find(control =>
            control.tagName === focused.tagName && control.name === focused.name && control.type === focused.type);
        const target = match ?? list.querySelector('.ticket-tabs [aria-current]');
        target?.focus({ preventScroll: true });
      }
    } catch {
      // GET only: fall back to a regular navigation for expired sessions,
      // network errors, or any response that isn't the expected list.
      if (!request.signal.aborted) {
        if (push) location.assign(url);
        else location.reload();
      }
    } finally {
      if (pending === request) {
        list.removeAttribute('aria-busy');
        pending = undefined;
      }
    }
  }

  list.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    const url = new URL(link.href);
    if (url.origin !== location.origin || url.pathname !== path || url.hash || link.target || link.hasAttribute('download')) return;
    event.preventDefault();
    load(url, true);
  });

  list.addEventListener('submit', event => {
    const form = event.target;
    if (!form.matches('form.ticket-filters') || form.method !== 'get') return;
    const url = new URL(form.action);
    if (url.origin !== location.origin || url.pathname !== path) return;
    url.search = new URLSearchParams(new FormData(form));
    event.preventDefault();
    load(url, true);
  });

  addEventListener('popstate', () => load(new URL(location.href), false));
})();
