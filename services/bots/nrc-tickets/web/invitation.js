// The invitation secret is a fragment, never an HTTP URL/query. Remove it
// before any exchange and retain neither localStorage nor sessionStorage copies.
(async () => {
  // After a rejected exchange this page stays open. Another invitation may
  // only change the fragment, so reload to perform its validated exchange.
  addEventListener('hashchange', () => location.reload());
  const token = location.hash.slice(1);
  history.replaceState(null, '', '/abnahmen/einladung');
  const status = document.getElementById('status');
  if (!/^[a-f0-9]{64}$/.test(token)) {
    status.textContent = 'Ungültige Einladung. Bitte öffnen Sie den vollständigen Einladungslink.';
    return;
  }
  try {
    const response = await fetch('/abnahmen/einladung', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ token }),
    });
    if (!response.ok) throw new Error('exchange failed');
    location.replace('/abnahmen/gast');
  } catch {
    status.textContent = 'Einladung konnte nicht geöffnet werden. Bitte versuchen Sie den ursprünglichen Link erneut.';
  }
})();
