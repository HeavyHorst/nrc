// Same-origin proxy only. No provider credentials or implicit mail operations.
(() => {
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const labels = {not_subscribed:'Nicht angemeldet',pending:'Bestätigung ausstehend',subscribed:'Angemeldet',unsubscribed:'Abgemeldet',blocked:'Gesperrt'};
  const campaignLabels = {draft:'Entwurf',queued:'Eingereiht',sending:'Versand läuft',sent:'Versendet',completed_with_errors:'Mit Versandfehlern abgeschlossen'};
  const recipientLabels = {pending:'Ausstehend',inflight:'Wird übermittelt',sent:'An Mailjet übergeben',skipped:'Übersprungen',failed:'Fehlgeschlagen',unknown:'Ausgang unklar'};
  let enabled = false, customersEnabled = false, workspace = '', state = null, campaign = null, dirty = false, busy = false, epoch = 0;
  let activeDialog = null;
  let reviewedAudience = null;
  let controller = new AbortController();
  let contactRows = [], contactTotal = 0, contactOffset = 0, contactMore = false, contactLoading = false, contactError = '', contactStale = false;
  let contactCursor = null;
  let contactGeneration = 0, contactController = null, searchTimer = null;
  function cancelContacts() {
    contactGeneration++; contactController?.abort(); contactController = null;
    if (searchTimer !== null) { clearTimeout(searchTimer); searchTimer = null; }
    contactLoading = false;
  }
  const editable = () => !campaign || campaign.status === 'draft';
  function clear(reason) {
    cancelContacts(); contactRows = []; contactTotal = contactOffset = 0; contactMore = false;
    epoch++; controller.abort(); controller = new AbortController();
    enabled = false; workspace = ''; state = campaign = null; dirty = busy = false;
    reviewedAudience = null;
    if ($('newsletterBtn')) $('newsletterBtn').hidden = true;
    activeDialog?.close(); activeDialog = null;
    if ($('newsletterPanel')) $('newsletterPanel').replaceChildren();
    if (reason && $('newsletterPanel')) {
      const message = document.createElement('p'); message.setAttribute('role','status'); message.textContent = reason; $('newsletterPanel').append(message);
    } else if (window.NRCViewManager?.getActiveView() === 'newsletter') window.NRCViewManager.setActiveView('chat');
  }
  function disconnect() {
    cancelContacts();
    epoch++; controller.abort(); controller = new AbortController();
    enabled = false; busy = false;
    reviewedAudience = null;
    activeDialog?.close(); activeDialog = null;
    notice('Verbindung unterbrochen · Entwurf bleibt erhalten. Laufende Aktionen vor erneutem Versand prüfen.');
    controls();
  }
  async function request(path, method = 'GET', body, signal = controller.signal) {
    const generation = epoch;
    const response = await fetch(path, {method, credentials:'same-origin', cache:'no-store', signal,
      headers: {...(body ? {'Content-Type':'application/json'} : {}), ...(path.startsWith('/newsletter/api') ? {'X-NRC-Workspace':workspace} : {})}, body:body ? JSON.stringify(body) : undefined});
    if (generation !== epoch) throw new DOMException('Stale', 'AbortError');
    if (response.status === 401 || response.status === 403) { clear('Keine Berechtigung für Newsletter.'); throw new Error('Keine Berechtigung für Newsletter.'); }
    const data = await response.json().catch(() => ({}));
    if (generation !== epoch) throw new DOMException('Stale', 'AbortError');
    if (!response.ok) throw new Error(response.status === 409 ? 'Versionskonflikt. Entwurf bleibt erhalten. Änderungen kopieren und Kampagne neu öffnen.' : (typeof data.error === 'string' ? data.error : 'Dienst nicht verfügbar. Bitte später erneut prüfen.'));
    return data;
  }
  async function refreshAccess() {
    if (workspace && (typeof currentWorkspaceId === 'undefined' || workspace !== currentWorkspaceId)) clear();
    disconnect();
    try {
      const features = await request('/api/features');
      const authorizedWorkspace = features.newsletter_workspace || '';
      if (features.newsletter !== true || !authorizedWorkspace || typeof currentWorkspaceId === 'undefined' || authorizedWorkspace !== currentWorkspaceId) { clear(); return; }
      workspace = authorizedWorkspace; enabled = true; customersEnabled = features.customers === true;
      if ($('newsletterBtn')) $('newsletterBtn').hidden = false;
      if ($('nlForm')) await run(async () => { notice('Zugriff bestätigt. Eingaben bleiben erhalten.'); await loadState(); });
    } catch (error) { if (error.name !== 'AbortError') console.warn('Newsletter nicht verfügbar'); }
  }
  function notice(text) { if ($('nlStatus')) { $('nlStatus').textContent = text; $('nlStatus').title = text; } }
  async function run(action) {
    if (busy || !enabled) return;
    busy = true; controls(); const generation = epoch;
    try { await action(); }
    catch (error) { if (error.name !== 'AbortError') notice(error.message); }
    finally { if (generation === epoch) { busy = false; controls(); } }
  }
  function field(id, title, type = 'text') { return `<label class="detail-edit-field"><span class="detail-edit-label">${title}</span><input class="task-detail-input" id="${id}" type="${type}"></label>`; }
  function mount() {
    $('newsletterPanel').innerHTML = `<header class="panel-header"><div><span>NEWSLETTER / MAILJET</span><span id="nlStatus" role="status" aria-live="polite">Lädt …</span></div></header>
      <div class="nl-toolbar"><nav class="tab-group" aria-label="Newsletter-Bereiche"><button class="btn nav-tab active" id="nlCampaignTab" aria-pressed="true">Kampagnen<span class="tab-count" id="nlCampaignCount">0</span></button><button class="btn nav-tab" id="nlSubscriberTab" aria-pressed="false">Kontakte<span class="tab-count" id="nlSubscriberCount">0</span></button></nav><div class="nl-actions"><button class="btn header-operation" id="nlRefresh">Aktualisieren</button><button class="btn btn--primary header-operation header-create-action" id="nlNew">+ Kampagne</button></div></div>
      <div id="nlCampaigns" class="nl-layout"><aside class="nl-register" aria-label="Kampagnen"><div id="nlList"></div></aside>
      <section class="nl-editor"><div class="nl-identity"><span class="nl-meta" id="nlRevision"></span><h2 id="nlHeading">Neue Kampagne</h2><p id="nlCampaignState" class="nl-meta"></p></div>
      <div class="nl-compose"><section class="nl-section"><header class="panel-header"><div><span>Inhalt & Vorlage</span></div></header>
      <form id="nlForm" class="nl-fields">${field('nlTitle','Interner Titel')}<label class="detail-edit-field"><span class="detail-edit-label">Mailjet-Vorlage</span><nrc-select><select class="task-detail-select" id="nlTemplate" data-custom-select-portal data-custom-select-search-placeholder="Vorlagen suchen …"></select></nrc-select></label>${field('nlSubject','Betreff')}<div id="nlVariables" class="nl-fields"></div><button class="btn" id="nlSave">Speichern</button></form><p id="nlSender" class="nl-meta"></p></section>
      <section class="nl-section nl-preview"><header class="panel-header"><div><span>Vorlagenansicht</span><button class="btn" id="nlPreview">Laden</button></div></header><p id="nlPreviewStatus" class="nl-meta">Mailjet-Vorlagenansicht nach dem Speichern. Die fertige Mail prüfen Sie per Testmail.</p><div class="nl-preview-empty" id="nlPreviewEmpty"><strong>Mailjet-Vorlage</strong><span>Entwurf speichern und Vorlagenansicht laden.</span></div><iframe id="nlFrame" title="Newsletter-Vorlagenansicht" sandbox="" referrerpolicy="no-referrer" hidden></iframe><details id="nlTextDetails" hidden><summary class="nl-meta">Textversion der Vorlage</summary><pre id="nlText"></pre></details></section></div></section>
      <aside class="nl-review"><section class="nl-section"><header class="panel-header"><div><span>Empfänger</span></div></header><div class="nl-eligible"><strong id="nlEligible">0</strong><span>bestätigte Empfänger<br><span class="nl-meta">eindeutige E-Mail-Adressen</span></span></div><dl id="nlAudience"></dl><p class="nl-meta">Nur bestätigte, nicht gesperrte Abonnenten. Keine automatische Anmeldung von Kundenkontakten.</p></section><section class="nl-section"><header class="panel-header"><div><span>Test & Freigabe</span></div></header>${field('nlTestEmail','Testadresse','email')}<button class="btn" id="nlTest">Testmail senden …</button><p class="nl-meta">Nach Änderungen erneut speichern und testen. Der Versand benötigt eine separate Bestätigung.</p><button class="btn" id="nlSend">Versand bestätigen …</button></section><div id="nlRecipients"></div></aside></div>
      <section id="nlSubscribers" hidden><div class="nl-subscriber-filter"><label class="nl-search"><span class="filter-label">Kontakte suchen</span><input class="filter-input" id="nlSearch" type="search" placeholder="Name oder E-Mail …"></label><span class="nl-meta" id="nlContactCount" role="status"></span></div><p class="nl-meta">Kontakte werden nicht automatisch angemeldet. Jede Einladung fordert eine Double-Opt-in-Bestätigung an.</p><div class="nl-contact nl-contact-head" aria-hidden="true"><span>Name / E-Mail</span><span>Einwilligung / Nachweis</span><span>Aktionen</span></div><div id="nlContacts"></div></section>`;
    $('nlForm').insertAdjacentHTML('afterbegin', `<label class="detail-edit-field"><span class="detail-edit-label">Versandart</span><nrc-select><select class="task-detail-select" id="nlKind"><option value="newsletter">Newsletter · mit Einwilligung</option><option value="service">Serviceinformation · ohne Werbung</option></select></nrc-select></label><section id="nlService" class="nl-fields" hidden><p class="nl-meta">Nur notwendige, nicht werbliche Kundeninformationen. Keine Umgehung der Newsletter-Einwilligung. Zustellsperren bleiben wirksam.</p>${field('nlServiceReason','Sachlicher Anlass / betroffene Änderung')}<label class="detail-edit-field"><span class="detail-edit-label">Kundenkreis</span><nrc-select><select class="task-detail-select" id="nlScope"><option value="selected_customers">Ausgewählte Kunden</option><option value="all_customers">Alle nicht archivierten Kunden</option></select></nrc-select></label><div id="nlCustomers" class="nl-fields"></div></section>`);
    $('nlAudience').insertAdjacentHTML('afterend', '<button class="btn" id="nlReviewAudience" type="button">Empfängerkreis prüfen</button><p class="nl-meta" id="nlAudienceNotice"></p>');
    $('nlList').insertAdjacentHTML('beforebegin', '<label class="filter-checkbox-label"><input type="checkbox" id="nlArchived">Archivierte anzeigen</label>');
    $('nlCampaignState').insertAdjacentHTML('afterend', '<div class="nl-actions"><button class="btn btn--danger" id="nlDelete" hidden>Entwurf löschen …</button><button class="btn" id="nlArchive" hidden>Archivieren …</button><button class="btn" id="nlRestore" hidden>Wiederherstellen …</button></div>');
    $('nlArchived').onchange = register;
    for (const [id, action, title] of [['nlDelete','delete','Entwurf löschen'],['nlArchive','archive','Archivieren'],['nlRestore','restore','Wiederherstellen']]) {
      $(id).onclick = () => {
        const selected = campaign;
        dialog(title, action === 'delete' ? `„${selected.title}“ endgültig löschen? Auch ungespeicherte Eingaben werden verworfen. Kontakte und Einwilligungen bleiben erhalten.` : `„${selected.title}“ ${action === 'archive' ? 'archivieren' : 'wiederherstellen'}? Versandstatus und Empfängerhistorie bleiben erhalten. Es werden keine E-Mails verschickt.`, '', async () => {
          const result = await api(`/campaigns/${encodeURIComponent(selected.id)}/${action}`, {revision:selected.revision});
          state.campaigns = action === 'delete' ? state.campaigns.filter(c => c.id !== selected.id) : state.campaigns.map(c => c.id === selected.id ? result : c);
          dirty = false;
          campaign = action === 'delete' ? null : result;
          choose(campaign, true);
          const success = action === 'delete' ? 'Entwurf gelöscht.' : action === 'archive' ? 'Kampagne archiviert.' : 'Kampagne wiederhergestellt.';
          try { await loadState(); notice(success); }
          catch (error) {
            // The mutation was acknowledged. Never offer to repeat it just because a read failed.
            if (enabled && error.name !== 'AbortError') notice(`${success} Aktualisierung fehlgeschlagen. Bitte „Aktualisieren“ verwenden.`);
          }
        });
      };
    }
    $('nlKind').onchange = $('nlScope').onchange = () => { dirty = true; reviewedAudience = null; serviceFields(); };
    $('nlReviewAudience').onclick = () => run(async () => {
      reviewedAudience = await api(`/campaigns/${encodeURIComponent(campaign.id)}/audience`, {revision:campaign.revision});
      const a = reviewedAudience.audience;
      $('nlEligible').textContent = a.recipients.length;
      $('nlAudienceNotice').textContent = `${a.customers} Kunden · ${a.recipients.length} eindeutige Adressen · ${a.excluded} ausgeschlossen · ${a.duplicates} doppelt. Ohne erreichbaren Servicekontakt: ${a.missing.map(c => c.name).join(', ') || 'keine'}.`;
    });
    $('nlCampaignTab').onclick = () => tab(false); $('nlSubscriberTab').onclick = () => tab(true);
    $('nlRefresh').onclick = () => enabled ? run(async () => { notice('Aktualisiert. Eingaben bleiben erhalten.'); await loadState(); }) : refreshAccess();
    $('nlNew').onclick = () => choose(null);
    $('nlForm').oninput = () => { dirty = true; reviewedAudience = null; clearPreview(); controls(); };
    $('nlTemplate').onchange = () => { variables({}); dirty = true; clearPreview(); controls(); };
    $('nlForm').onsubmit = event => { event.preventDefault(); run(save); };
    $('nlPreview').onclick = () => run(async () => {
      const values = {...campaign.variables};
      const result = await api(`/campaigns/${encodeURIComponent(campaign.id)}/preview`, {revision:campaign.revision});
      // Only simple variables, not a local implementation of Mailjet's template language.
      const substitute = (source, html) => (source || '').replace(/\{\{\s*var:([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g, (match, key) =>
        Object.hasOwn(values, key) ? (html ? esc(values[key]) : String(values[key] ?? '')) : match);
      // CSP precedes provider markup. Sandbox forbids scripts, forms, popups and same-origin access.
      // Template contents are inert even during parsing (no image/iframe fetch).
      const template = document.createElement('template'); template.innerHTML = substitute(result.html, true);
      template.content.querySelectorAll('script,meta,base,link,iframe,object,embed,form,template,svg,math').forEach(node => node.remove());
      template.content.querySelectorAll('*').forEach(node => { for (const attribute of [...node.attributes]) if (/^on/i.test(attribute.name) || /href$/i.test(attribute.name) || ['target','action','formaction'].includes(attribute.name)) node.removeAttribute(attribute.name); });
      $('nlFrame').srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; form-action 'none'; base-uri 'none'"><style>:root{color-scheme:only light;background:Canvas;color:CanvasText}</style>${template.innerHTML}`;
      $('nlFrame').hidden = false; $('nlPreviewEmpty').hidden = true; $('nlTextDetails').hidden = !result.text;
      $('nlText').textContent = substitute(result.text, false); $('nlPreviewStatus').textContent = 'Lokale Vorschau mit gespeicherten Werten · Nur einfache {{var:…}}-Platzhalter werden als Text ersetzt; andere Mailjet-Ausdrücke bleiben unverändert. Externe Inhalte sind blockiert. Die verbindliche Darstellung prüfen Sie per Testmail.';
    });
    $('nlTest').onclick = () => {
      if (!$('nlTestEmail').value || !$('nlTestEmail').checkValidity()) { $('nlTestEmail').reportValidity(); return; }
      const email = $('nlTestEmail').value;
      dialog('Testmail senden', `Eine echte Testmail wird an ${email} gesendet.`, null, async () => { await api(`/campaigns/${encodeURIComponent(campaign.id)}/test`, {revision:campaign.revision,email}); clearPreview(); await reloadCampaign(); });
    };
    $('nlSend').onclick = () => dialog(campaign.kind === 'service' ? 'Serviceinformation versenden' : 'Newsletter versenden', `${campaign.kind === 'service' ? `Nicht werbliche Serviceinformation: ${campaign.service_reason}. ${$('nlAudienceNotice').textContent}` : 'Unwiderruflicher Versand an berechtigte Abonnenten.'} Betreff exakt eingeben: ${campaign.subject}`, 'Betreff zur Bestätigung', async confirmation => {
      if (confirmation !== campaign.subject) throw new Error('Betreff stimmt nicht überein. Kein Versand.');
      await api(`/campaigns/${encodeURIComponent(campaign.id)}/send`, {revision:campaign.revision,confirmation,...(campaign.kind === 'service' ? {audience_token:reviewedAudience?.token || ''} : {})}); reviewedAudience = null; await reloadCampaign();
    });
    $('nlContacts').insertAdjacentHTML('afterend', '<nrc-page-loader id="nlContactPager"></nrc-page-loader>');
    $('nlContactPager').addEventListener('nrc:load-more', () => loadContacts(false));
    $('nlSearch').placeholder = 'Name, E-Mail oder Firma …';
    $('nlSearch').oninput = () => {
      if (!enabled) return;
      cancelContacts(); contactRows = []; contactTotal = contactOffset = 0; contactMore = false; contactError = ''; contactStale = false;
      contactLoading = true; contacts();
      searchTimer = setTimeout(() => { searchTimer = null; loadContacts(true); }, 200);
    };
  }
  const api = (path, body, method = 'POST') => request('/newsletter/api' + path, method, body);
  function serviceFields() {
    const service = $('nlKind').value === 'service';
    $('nlService').hidden = !service;
    $('nlCustomers').hidden = $('nlScope').value === 'all_customers';
    controls();
  }
  function tab(subscribers) {
    $('nlCampaigns').hidden = subscribers; $('nlSubscribers').hidden = !subscribers;
    for (const [id, active] of [['nlCampaignTab', !subscribers], ['nlSubscriberTab', subscribers]]) {
      $(id).classList.toggle('active', active); $(id).setAttribute('aria-pressed', String(active));
    }
    contactPager();
  }
  function variables(values) {
    const template = state?.templates?.find(t => t.id === $('nlTemplate').value);
    $('nlVariables').replaceChildren();
    for (const key of template?.variables || []) {
      const label = document.createElement('label'); label.className = 'detail-edit-field';
      const title = document.createElement('span'); title.className = 'detail-edit-label';
      const words = key.replace(/([a-zäöüß])([A-ZÄÖÜ])/g, '$1 $2').replace(/[_-]+/g, ' ');
      title.textContent = words.charAt(0).toLocaleUpperCase('de') + words.slice(1);
      const input = document.createElement('textarea'); input.className = 'task-detail-textarea'; input.rows = 3;
      input.dataset.variable = key; input.value = values[key] ?? ''; label.append(title, input); $('nlVariables').append(label);
    }
  }
  function clearPreview() {
    $('nlFrame').removeAttribute('srcdoc'); $('nlFrame').hidden = true; $('nlPreviewEmpty').hidden = false; $('nlTextDetails').hidden = true; $('nlTextDetails').open = false; $('nlText').textContent = ''; $('nlPreviewStatus').textContent = 'Lokale Vorschau nicht geladen. Einfache Platzhalter werden mit gespeicherten Werten angezeigt; die fertige Mail prüfen Sie per Testmail.';
  }
  function choose(next, confirmed = false) {
    if (!confirmed && (busy || (dirty && !window.confirm('Ungespeicherte Änderungen verwerfen?')))) return;
    campaign = next; dirty = false;
    reviewedAudience = null;
    $('nlKind').value = next?.kind || 'newsletter'; $('nlScope').value = next?.audience || 'selected_customers';
    $('nlServiceReason').value = next?.service_reason || '';
    $('nlCustomers').querySelectorAll('input').forEach(input => input.checked = (next?.customer_ids || []).includes(input.value));
    $('nlAudienceNotice').textContent = '';
    serviceFields();
    tab(false);
    $('nlTitle').value = next?.title || ''; $('nlSubject').value = next?.subject || '';
    $('nlTemplate').value = next?.template_id || state?.templates?.[0]?.id || ''; variables(next?.variables || {});
    clearPreview();
    controls(); register();
  }
  async function save() {
    const body = {title:$('nlTitle').value,subject:$('nlSubject').value,template_id:$('nlTemplate').value,variables:Object.fromEntries([...$('nlVariables').querySelectorAll('[data-variable]')].map(input => [input.dataset.variable,input.value]))};
    body.kind = $('nlKind').value;
    if (body.kind === 'service') {
      body.service_reason = $('nlServiceReason').value;
      body.audience = $('nlScope').value;
      body.customer_ids = body.audience === 'all_customers' ? [] : [...$('nlCustomers').querySelectorAll('input:checked')].map(input => input.value);
      if (!body.service_reason.trim() || (body.audience === 'selected_customers' && !body.customer_ids.length)) throw new Error('Serviceanlass und Kundenkreis sind erforderlich.');
    }
    if (!body.title.trim() || !body.subject.trim() || !body.template_id) throw new Error('Titel, Vorlage und Betreff sind erforderlich.');
    const result = await api(campaign ? `/campaigns/${encodeURIComponent(campaign.id)}` : '/campaigns', campaign ? {...body, revision:campaign.revision} : body, campaign ? 'PUT' : 'POST');
    // Keep the form bound to the revision that accepted these values. A later
    // state read may reveal another editor's revision, not our form contents.
    const saved = result.campaign || result;
    if (!saved.id) throw new Error('Speicherantwort ohne Kampagnen-ID. Bitte aktualisieren und gespeicherten Stand prüfen.');
    campaign = saved; dirty = false;
    clearPreview();
    reviewedAudience = null;
    notice('Gespeichert. Vor Versand diesen Stand testen.');
    await loadState();
  }
  async function reloadCampaign() { await loadState(); if (!dirty) notice('Provider-Status aktualisiert.'); }
  async function loadState() {
    state = await request('/newsletter/api/summary');
    const selected = new Set([...$('nlCustomers').querySelectorAll('input:checked')].map(input => input.value));
    $('nlCustomers').innerHTML = (state.customers || []).map(c => `<label class="filter-checkbox-label"><input class="filter-checkbox" type="checkbox" value="${esc(c.customer_id)}" ${selected.has(c.customer_id) ? 'checked' : ''}><span>${esc(c.name)} / ${c.contacts.length} Servicekontakte</span></label>`).join('') || '<p class="nl-meta">Keine nicht archivierten Kunden.</p>';
    reviewedAudience = null;
    $('nlAudienceNotice').textContent = '';
    const templateId = $('nlTemplate').value;
    const needsVariables = !$('nlTemplate').options.length;
    $('nlTemplate').innerHTML = (state.templates || []).map(t => `<option value="${esc(t.id)}">${esc(t.name)}</option>`).join('');
    if (templateId) $('nlTemplate').value = templateId;
    if (needsVariables) variables({});
    const latest = campaign && state.campaigns.find(c => c.id === campaign.id);
    if (campaign && (latest?.revision !== campaign.revision || latest?.updated_at !== campaign.updated_at || latest?.tested_revision !== campaign.tested_revision)) clearPreview();
    if (campaign && latest?.revision !== campaign.revision) {
      dirty = true; notice('Kampagne extern geändert. Eingaben kopieren und gespeicherten Stand neu öffnen.');
    } else if (latest) campaign = latest;
    $('nlSender').textContent = `Absender: ${state.from_name || '—'} <${state.from_email || '—'}> · Antwort an: ${state.reply_to || '—'}`;
    $('nlEligible').textContent = state.audience?.eligible ?? 0;
    $('nlCampaignCount').textContent = state.campaigns?.length ?? 0;
    $('nlSubscriberCount').textContent = state.audience?.total ?? 0;
    $('nlAudience').innerHTML = Object.entries({total:'Kontakte',eligible:'Berechtigt (eindeutig)',duplicates:'Doppelte Adressen',not_subscribed:'Nicht bestätigt',unsubscribed:'Abgemeldet',blocked:'Gesperrt / ohne E-Mail'}).map(([key,label]) => `<div><dt>${label}</dt><dd>${esc(state.audience?.[key] ?? 0)}</dd></div>`).join('');
    register(); await loadContacts(true);
  }
  function register() {
    const includeArchived = $('nlArchived').checked;
    $('nlCampaignCount').textContent = (state?.campaigns || []).filter(c => includeArchived || !c.archived).length;
    $('nlList').innerHTML = (state?.campaigns || []).map((c,i) => !includeArchived && c.archived ? '' : `<button class="nl-row" data-campaign="${i}" aria-pressed="${c.id === campaign?.id}"><strong>${esc(c.title)}</strong><span>${c.archived ? 'Archiviert · ' : ''}${esc(campaignLabels[c.status] || c.status)} · R${esc(c.revision)}</span></button>`).join('') || '<p>Keine Kampagnen in dieser Ansicht.</p>';
    $('nlList').querySelectorAll('button').forEach(button => button.onclick = () => choose(state.campaigns[Number(button.dataset.campaign)]));
  }
  function controls() {
    if (!$('nlSave')) return;
    const available = enabled && state?.configured && !busy;
    const completed = ['sent','completed_with_errors'].includes(campaign?.status);
    $('nlDelete').hidden = !campaign || campaign.status !== 'draft';
    $('nlArchive').hidden = !completed || !!campaign?.archived;
    $('nlRestore').hidden = !completed || !campaign?.archived;
    for (const id of ['nlDelete','nlArchive','nlRestore']) $(id).disabled = !enabled || busy;
    $('nlSave').disabled = !available || !editable(); $('nlNew').disabled = !available;
    $('nlForm').querySelectorAll('input,select,textarea').forEach(input => input.disabled = !available || !editable());
    const saved = available && campaign && !dirty;
    $('nlPreview').disabled = !saved; $('nlTest').disabled = !saved || !editable();
    const service = $('nlKind').value === 'service';
    $('nlSend').disabled = !saved || !editable() || campaign.tested_revision !== campaign.revision || (service ? !reviewedAudience?.audience?.recipients?.length : !state.audience?.eligible);
    $('nlReviewAudience').disabled = !saved || !editable();
    $('nlReviewAudience').hidden = !service;
    $('nlAudience').hidden = service;
    $('nlAudience').parentElement.lastElementChild.textContent = service ? 'Nur ausdrücklich zugeordnete Servicekontakte. Newsletter-Abmeldungen gelten nicht für notwendige Serviceinformationen; Zustellsperren bleiben wirksam.' : 'Nur bestätigte, nicht gesperrte Abonnenten. Keine automatische Anmeldung von Kundenkontakten.';
    $('nlEligible').parentElement.querySelector('span').firstChild.textContent = service ? 'Serviceempfänger' : 'bestätigte Empfänger';
    if (service && !reviewedAudience) $('nlEligible').textContent = '—';
    else if (!service) $('nlEligible').textContent = state?.audience?.eligible ?? 0;
    $('nlRevision').textContent = campaign ? `R${campaign.revision} ${dirty ? '· UNGESPEICHERT' : ''}` : 'NEU';
    $('nlHeading').textContent = campaign?.title || 'Neue Kampagne';
    $('nlCampaignState').textContent = campaign ? `${campaign.archived ? 'Archiviert · ' : ''}${campaignLabels[campaign.status] || campaign.status} · getesteter Stand: ${campaign.tested_revision || '—'} ${campaign.error || ''}` : 'Noch nicht gespeichert';
    $('nlRecipients').innerHTML = (campaign?.recipients || []).map(r => `<p>${esc(r.name)} · ${esc(r.email)}<br><span class="nl-meta">${esc(recipientLabels[r.status] || r.status)} ${esc(r.error)}</span></p>`).join('');
    $('nlRefresh').disabled = busy;
    $('nlContacts').querySelectorAll('button').forEach(button => button.disabled = button.hasAttribute('data-open-contact') ? !enabled || !customersEnabled || busy : !available);
    contactPager();
  }
  function contactPager() {
    $('nlContactPager')?.setState({hasMore:contactMore, loading:contactLoading, error:contactError, disabled:!enabled || busy, active:!$('nlSubscribers').hidden, root:$('newsletterPanel'), label:'MEHR LADEN'});
  }
  async function loadContacts(reset) {
    if (!enabled || (!reset && (contactLoading || !contactMore && !contactError))) return;
    if (reset) { cancelContacts(); contactRows = []; contactTotal = contactOffset = 0; contactCursor = null; contactMore = false; contactStale = false; }
    const generation = ++contactGeneration;
    contactController = new AbortController(); contactLoading = true; contactError = ''; contacts();
    try {
      const query = $('nlSearch').value.trim();
      const page = await request('/newsletter/api/subscribers/search', 'POST', {query, ...(query ? {offset:contactOffset} : {cursor:contactCursor}), limit:25}, contactController.signal);
      if (generation !== contactGeneration) return;
      if (!Array.isArray(page.subscribers) || !Number.isSafeInteger(page.total_count) || page.total_count < 0 ||
          page.subscribers.length > 25 || typeof page.has_more !== 'boolean' || (page.has_more && !page.subscribers.length)) throw new Error('Ungültige Kontaktseite. Bitte erneut versuchen.');
      if (query) {
        if (!Number.isSafeInteger(page.next_offset) || page.next_offset !== Math.min(contactOffset, page.total_count) + page.subscribers.length || page.next_offset > page.total_count ||
            page.has_more !== (page.next_offset < page.total_count)) throw new Error('Ungültige Suchantwort. Bitte erneut versuchen.');
      } else if (page.has_more && (!/^-?\d+$/.test(page.next_cursor?.updated_at ?? '') || !/^[1-9]\d*$/.test(page.next_cursor?.asset_id ?? '') ||
          contactCursor && (BigInt(page.next_cursor.updated_at) > BigInt(contactCursor.updated_at) ||
            BigInt(page.next_cursor.updated_at) === BigInt(contactCursor.updated_at) && BigInt(page.next_cursor.asset_id) >= BigInt(contactCursor.asset_id)))) {
        throw new Error('Ungültiger Kontaktcursor. Bitte erneut versuchen.');
      }
      contactRows = [...new Map([...contactRows, ...page.subscribers].map(row => [row.contact_id, row])).values()];
      contactTotal = page.total_count; contactOffset = query ? page.next_offset : 0; contactCursor = query ? null : page.next_cursor;
      contactMore = page.has_more; contactStale ||= page.stale === true;
    } catch (error) { if (generation === contactGeneration && error.name !== 'AbortError') contactError = 'Kontaktsuche nicht verfügbar. Bitte erneut versuchen.'; }
    finally { if (generation === contactGeneration) { contactLoading = false; contacts(); } }
  }
  function contacts() {
    const rows = contactRows;
    $('nlContactCount').textContent = `${contactLoading ? 'Suche läuft … · ' : ''}${rows.length} / ${contactTotal} Kontakte${contactStale ? ' · Suchstand möglicherweise veraltet; bitte aktualisieren.' : ''}`;
    if (!rows.length && contactLoading) $('nlContactCount').textContent = 'Suche läuft …';
    else if (!rows.length && contactError) $('nlContactCount').textContent = 'Suche fehlgeschlagen';
    $('nlContacts').innerHTML = rows.map((s,i) => `<div class="nl-contact" data-contact-id="${esc(s.contact_id)}"><span><button class="btn btn--row" type="button" data-open-contact="${i}" aria-label="Kontakt ${esc(s.name)} öffnen"><strong>${esc(s.name)}</strong></button><br><span class="nl-meta">${esc(s.email)}</span><br><span class="nl-meta">Firma: ${esc((s.companies || []).map(c => c.name).join(' · ') || 'Keine Zuordnung')}</span></span><span>${esc(labels[s.status] || s.status)}${s.source ? `<br><span class="nl-meta">${esc(s.source)}</span>` : ''}${s.confirmed_at ? `<br><span class="nl-meta">Bestätigt: ${esc(new Date(s.confirmed_at).toLocaleString(undefined, {dateStyle:'medium',timeStyle:'short'}))}</span>` : ''}</span><span class="nl-contact-actions">${['not_subscribed','unsubscribed','pending'].includes(s.status) ? `<button class="btn btn--row" data-invite="${i}">${s.status === 'pending' ? 'Erneut anfordern' : 'Einladen'} …</button>` : ''}${s.status === 'subscribed' || s.status === 'pending' ? `<button class="btn btn--row" data-optout="${i}">Abmelden …</button>` : ''}</span></div>`).join('') || (contactLoading || contactError ? '' : '<p>Keine passenden Kontakte.</p>');
    $('nlContacts').querySelectorAll('[data-open-contact]').forEach(button => button.onclick = async () => {
      if (!enabled || !customersEnabled || busy) return;
      const generation = epoch;
      // Customers has an independent, asynchronous capability check. Complete
      // it before asking its renderer to open a record.
      await window.NRCCustomers?.refreshAccess();
      if (generation !== epoch || !enabled || busy || (window.NRCCustomers && !window.NRCCustomers.isEnabled())) return;
      window.NRCInspector?.openEntity({roomId:0n,type:'contact',id:BigInt(rows[Number(button.dataset.openContact)].contact_id),subview:'read'});
    });
    rows.forEach(s => {
      const proof = s.import_proof;
      if (!proof) return;
      const row = $('nlContacts').querySelector(`[data-contact-id="${CSS.escape(s.contact_id)}"]`);
      const details = document.createElement('details');
      const summary = document.createElement('summary'); summary.textContent = 'Importnachweis';
      const text = document.createElement('p'); text.className = 'nl-meta';
      text.textContent = `Ursprüngliche Quelle: ${proof.source} · Bestätigt: ${proof.confirmed_at} · Umfang: ${proof.scope} · Nachweis: ${proof.evidence} · Externe ID: ${proof.external_id || '—'} · Importiert: ${proof.imported_at}`;
      details.append(summary,text); row.children[1].append(details);
    });
    $('nlContacts').querySelectorAll('[data-invite]').forEach(button => button.onclick = () => {
      const s = rows[Number(button.dataset.invite)];
      dialog('Bestätigung anfordern', `${s.email}: Eine CRM-Kontaktadresse ist keine Marketing-Einwilligung. Eine einzelne Double-Opt-in-Einladung wird gesendet. Keine Anmeldung ohne Bestätigung. Herkunft / Anlass dokumentieren.`, 'Quelle / Anlass (erforderlich)', async source => {
        if (!source.trim()) throw new Error('Quelle ist erforderlich.');
        await api(`/subscribers/${encodeURIComponent(s.contact_id)}/invite`, {source}); await loadState();
      });
    });
    $('nlContacts').querySelectorAll('[data-optout]').forEach(button => button.onclick = () => {
      const s = rows[Number(button.dataset.optout)];
      dialog('Kontakt abmelden', `${s.email} erhält künftig keine Newsletter mehr.`, null, async () => { await api(`/subscribers/${encodeURIComponent(s.contact_id)}/unsubscribe`, {}); await loadState(); });
    });
    controls();
  }
  function dialog(title, explanation, label, action) {
    if (!enabled || busy || $('newsletterDialog')) return;
    const opener = document.activeElement;
    const contactId = opener?.closest('[data-contact-id]')?.dataset.contactId;
    const view = window.NRCModal.create({title, className:'nl-dialog'});
    activeDialog = view; view.root.id = 'newsletterDialog'; view.canClose = () => !busy;
    const form = document.createElement('form'); form.id = 'nlDialogForm'; form.className = 'nl-fields';
    form.innerHTML = `<p class="nrc-dialog-message" id="nlDialogMessage">${esc(explanation)}</p>${label ? field('nlConfirmation',esc(label)) : ''}<p role="status" id="nlDialogStatus"></p>`;
    view.root.setAttribute('aria-describedby','nlDialogMessage'); view.panel.insertBefore(form,view.actions);
    view.actions.innerHTML = `<button class="btn" type="button">Abbrechen</button><button class="btn btn--primary" type="submit" form="nlDialogForm">${esc(title)}</button>`;
    view.actions.querySelector('[type=button]').onclick = () => view.cancel();
    form.onsubmit = async event => {
      event.preventDefault(); const value = $('nlConfirmation')?.value || '';
      let completed = false;
      await run(async () => { const buttons = [...view.root.querySelectorAll('button')]; buttons.forEach(b => b.disabled = true);
        try { await action(value); completed = true; } catch (error) { if (view.root.isConnected) { $('nlDialogStatus').textContent = error.message; buttons.forEach(b => b.disabled = false); } throw error; }
      });
      if (completed && activeDialog === view) {
        view.close(); activeDialog = null;
        // Controls are enabled again before native focus return. A refreshed
        // subscriber row needs its replacement action, not the detached opener.
        if (!opener?.isConnected || opener.disabled || !opener.checkVisibility({visibilityProperty:true})) {
          const row = contactId ? document.querySelector(`[data-contact-id="${CSS.escape(contactId)}"]`) : null;
          [row?.querySelector('button:not(:disabled)'), contactId ? $('nlSearch') : null, $('nlPreview'), $('nlRefresh')]
            .find(node => node && !node.disabled && node.checkVisibility())?.focus();
        }
      }
    };
    view.show();
  }
  async function open() {
    if (!enabled) return;
    if ($('nlForm')) return;
    mount(); await run(async () => {
      await loadState(); notice(state.configured ? 'Bereit · Mailjet' : 'Mailjet nicht konfiguriert. Aktionen gesperrt.');
    });
  }
  window.NRCNewsletter = {isEnabled:() => enabled, refreshAccess, disconnect, clear, open};
  document.addEventListener('DOMContentLoaded', () => { if ($('newsletterBtn')) $('newsletterBtn').onclick = () => window.NRCViewManager.setActiveView('newsletter'); });
  window.addEventListener('pagehide', () => clear());
})();
