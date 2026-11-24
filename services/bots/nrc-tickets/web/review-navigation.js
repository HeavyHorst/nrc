(() => {
  const main = document.querySelector('main[data-review-base]');
  if (!main) return;
  const base = main.dataset.reviewBase;
  const drafts = new Map();
  const formFor = view => view.querySelector('.review-point form');
  const pointFor = form => form.elements.point_id.value;
  const csrfFor = form => form.elements.csrf.value;
  let displayedURL = location.href;
  let read;
  let saving = false;

  function remember(form) {
    const radios = Array.from(form.elements.result);
    const result = form.elements.result.value;
    const comment = form.elements.comment;
    if (result !== (radios.find(radio => radio.defaultChecked)?.value ?? '') || comment.value !== comment.defaultValue) {
      drafts.set(pointFor(form), { result, comment: comment.value });
    } else {
      drafts.delete(pointFor(form));
    }
  }

  function showError(message) {
    main.querySelector('[data-navigation-error]')?.remove();
    const alert = document.createElement('p');
    alert.dataset.navigationError = '';
    alert.setAttribute('role', 'alert');
    alert.textContent = message;
    main.querySelector('.review-work').prepend(alert);
  }

  async function navigate(url, body, fromHistory = false) {
    read?.abort();
    const post = body !== undefined;
    const form = formFor(main);
    const focused = document.activeElement;
    const before = location.href;
    const request = new AbortController();
    if (post) {
      saving = true;
      form.inert = true;
    } else {
      read = request;
    }
    try {
      const response = await fetch(url, {
        method: post ? 'POST' : 'GET', body, signal: request.signal, mode: 'same-origin',
        headers: post ? { 'X-NRC-Review-Navigation': '1' } : undefined,
      });
      const finalURL = new URL(response.url);
      const page = new DOMParser().parseFromString(await response.text(), 'text/html');
      if (request.signal.aborted) return;
      if (!response.ok) {
        throw new Error(page.querySelector('main > [role="alert"]')?.textContent);
      }
      const next = page.querySelector('main[data-review-base]');
      if (!next || finalURL.pathname !== base || csrfFor(formFor(next)) !== csrfFor(form)) {
        if (post) throw new Error();
        // Login, expiration, a different guest invitation, or a closed run.
        location.replace(finalURL.href);
        return;
      }

      if (post) drafts.delete(pointFor(form));
      else remember(form);
      const nextForm = formFor(next);
      const draft = drafts.get(pointFor(nextForm));
      if (draft) {
        nextForm.elements.result.value = draft.result;
        nextForm.elements.comment.value = draft.comment;
      }
      const finish = main.querySelector('.review-finish');
      const nextFinish = next.querySelector('.review-finish');
      if (finish && nextFinish) {
        nextFinish.open = finish.open;
        for (const name of ['decision', 'comment']) {
          nextFinish.querySelector(`[name="${name}"]`).value = finish.querySelector(`[name="${name}"]`).value;
        }
      }
      const concurrentHistory = location.href !== before;
      // The POST redirect is followed by fetch, which can omit the fragment.
      finalURL.hash = `point-${pointFor(nextForm)}`;
      if (!fromHistory && !concurrentHistory && finalURL.href !== location.href) history.pushState(null, '', finalURL);
      displayedURL = fromHistory ? before : finalURL.href;
      main.replaceChildren(...next.childNodes);
      const heading = main.querySelector('.review-work h2');
      heading.tabIndex = -1;
      heading.focus({ preventScroll: true });
      const { top, bottom } = heading.getBoundingClientRect();
      if (top < 0 || bottom > innerHeight) heading.scrollIntoView({ block: 'center' });
    } catch (error) {
      if (request.signal.aborted) return;
      if (fromHistory) history.replaceState(null, '', displayedURL);
      showError(error.message && !(error instanceof TypeError) ? error.message : post
        ? 'Speichern nicht bestätigt. Bitte den aktuellen Stand prüfen, bevor Sie erneut senden.'
        : 'Der Prüfpunkt konnte nicht geladen werden. Bitte versuchen Sie es erneut.');
    } finally {
      if (read === request) read = undefined;
      if (post) {
        form.inert = false;
        if (form.isConnected) focused?.focus({ preventScroll: true });
        saving = false;
        if (location.href !== before && location.href !== displayedURL) navigate(location.href, undefined, true);
      }
    }
  }

  main.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const url = new URL(link.href);
    if (url.origin !== location.origin || url.pathname !== base || !url.searchParams.has('point')) return;
    event.preventDefault();
    if (!saving) navigate(url);
  });

  main.addEventListener('submit', event => {
    if (event.target !== formFor(main)) return;
    event.preventDefault();
    if (!saving) navigate(event.target.action, new URLSearchParams(new FormData(event.target)));
  });

  addEventListener('popstate', () => {
    if (!saving) navigate(location.href, undefined, true);
  });
})();
