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
