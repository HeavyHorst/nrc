// Only presentation: native multipart form submission owns the upload.
for (const input of document.querySelectorAll('.file-upload input[type=file]')) {
  const update = () => {
    const selection = input.closest('.attachment-upload').querySelector('#selected-files');
    const names = Array.from(input.files, file => file.name);
    selection.textContent = names.length ? `${names.length} ${names.length === 1 ? 'Datei' : 'Dateien'} ausgewählt: ${names.join(', ')}` : 'Keine Dateien ausgewählt.';
  };
  input.addEventListener('change', update);
  update();
  input.closest('.file-upload').classList.add('is-enhanced');
}

const ticketDetails = document.querySelector('.ticket-aside details');
if (ticketDetails) {
  const narrow = matchMedia('(max-width: 760px)');
  const layout = () => { ticketDetails.open = !narrow.matches; };
  narrow.addEventListener('change', layout);
  layout();
}

const copyTicket = document.querySelector('.ticket-copy');
if (copyTicket && navigator.clipboard?.writeText) {
  const link = document.querySelector('.ticket-direct-link');
  const status = document.querySelector('.ticket-copy-status');
  copyTicket.hidden = false;
  link.hidden = true;
  copyTicket.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(link.href);
      link.hidden = true;
      status.textContent = 'Link kopiert.';
    } catch {
      link.textContent = link.href;
      link.hidden = false;
      status.textContent = 'Automatisches Kopieren fehlgeschlagen. Kopieren Sie den angezeigten Direktlink.';
    }
  });
}
