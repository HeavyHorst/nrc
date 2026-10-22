// NRC owns invitations. Every provider supplies a normal external HTTPS link.
(() => {
  const $ = id => document.getElementById(id);
  let socket, workspace = '', username = '', enabled = false, ready = false;
  let call = null, selected = false, pending = false, externalSession = false;
  let conference = null, invitePicker = null;
  let conferences = new Map(), library = null, expiryTimer, panelOpen = false;
  let generation = 0, retry, pendingTimer, ringTimer, audio, pendingAction = '';
  let appointmentRequest = null, requestSequence = 0;
  const reasons = {decline:'Call declined', cancel:'Call cancelled',
    disconnect:'Invitation cancelled · connection lost', timeout:'No answer',
    unavailable:'Call unavailable · check DM access and provider'};

  function clearJoin() {
    $('callJoin').hidden = true;
    $('callJoin').removeAttribute('href');
  }
  function stopRing() {
    clearInterval(ringTimer); ringTimer = null;
  }
  function tone() {
    if (!audio || audio.state !== 'running') return;
    const oscillator = audio.createOscillator(), gain = audio.createGain();
    oscillator.connect(gain); gain.connect(audio.destination);
    oscillator.frequency.value = 440;
    gain.gain.setValueAtTime(0.04, audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.001, audio.currentTime + 0.5);
    oscillator.start(); oscillator.stop(audio.currentTime + 0.5);
  }
  function unlockAudio() {
    if (!enabled || !window.AudioContext) return;
    audio ||= new AudioContext();
    audio.resume().catch(() => {});
  }
  function settle() { pending = false; clearTimeout(pendingTimer); }
  function notice(text) {
    panelOpen = true;
    $('callPanel').hidden = false;
    $('callStatus').textContent = text;
  }
  const expired = item => !item || item.expires_at * 1000 <= Date.now();
  const expiryLabel = item => expired(item) ? 'Links expired · the conference may still be running'
    : `Links valid until ${new Date(item.expires_at * 1000).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}`;
  function render() {
    if (!$('callStart')) return;
    const dm = typeof currentRoomId !== 'undefined' && activeDMs.has(currentRoomId);
    $('callStart').hidden = !enabled || !dm || systemLogVisible;
    $('callStart').disabled = !ready || !!call || pending;
    $('callStart').title = ready ? 'Start a video call' : 'Call service reconnecting';
    $('callHistory').hidden = !enabled;
    $('callHistory').textContent = `CONFERENCES (${conferences.size})`;
    $('callHistory').disabled = !!call || pending;
    $('callPanel').hidden = !panelOpen;
    $('callPeer').textContent = conference ? conference.title : 'VIDEO INVITATION';
    $('callExpiry').hidden = !conference;
    $('callExpiry').textContent = conference ? expiryLabel(conference) : '';
    clearJoin();
    if (conference && !expired(conference) && panelOpen) {
      $('callJoin').href = conference.url; $('callJoin').hidden = false;
    }
    clearTimeout(expiryTimer);
    const nextExpiry = [...conferences.values()].filter(item => !expired(item)).reduce((next,item) => Math.min(next,item.expires_at * 1000), Infinity);
    if (Number.isFinite(nextExpiry)) expiryTimer = setTimeout(render, Math.min(2147483647, nextExpiry - Date.now() + 10));
    if (library) for (const button of library.panel.querySelectorAll('[data-conference-id]')) {
      button.querySelector('span').textContent = expiryLabel(conferences.get(button.dataset.conferenceId));
    }
    if (invitePicker && expired(conference)) {
      invitePicker.actions.querySelector('.btn--primary').disabled = true;
      invitePicker.panel.querySelector('.call-hint').textContent = 'Invitation links expired. The external conference may still be running.';
    }
    const incoming = call?.state === 'ringing' && call.callee === username;
    $('callAccept').hidden = !incoming;
    $('callDecline').hidden = !incoming;
    $('callEnd').hidden = !call || !selected || incoming;
    $('callEnd').textContent = 'CANCEL CALL';
    $('callDismiss').hidden = !!call;
    $('callInvite').hidden = !conference?.conference_id;
    $('callInvite').disabled = !ready || !!call || pending || expired(conference);
    $('callExternalHint').hidden = !externalSession || expired(conference);
    for (const id of ['callAccept','callDecline','callEnd']) $(id).disabled = pending;
    if (!call) { stopRing(); return; }
    panelOpen = true; $('callPanel').hidden = false;
    $('callInvitationPeer').textContent = `INVITATION · ${call.caller === username ? call.callee : call.caller}`;
    $('callStatus').textContent = pending ? ({accept:'Connecting…', decline:'Declining…', cancel:'Cancelling…'}[pendingAction] || 'Calling…')
      : incoming ? 'Incoming video call' : 'Calling…';
    if (incoming && !pending && !ringTimer) { tone(); ringTimer = setInterval(tone, 2500); }
    if (!incoming || pending) stopRing();
  }
  function send(action, dmID = String(currentRoomId), conferenceID = '') {
    if (!ready || pending || socket?.readyState !== WebSocket.OPEN) return;
    if (action === 'start') {
      if (call || !activeDMs.has(BigInt(dmID))) return;
      selected = true;
      if (!conferenceID) { conference = null; externalSession = false; clearJoin(); }
      $('callInvitationPeer').textContent = `INVITATION · ${activeDMs.get(BigInt(dmID)).username}`;
      notice('Sending invitation…');
    }
    pending = true;
    pendingAction = action;
    socket.send(JSON.stringify({action, dm_id:call?.dm_id || dmID, call_id:call?.id || '', ...(conferenceID ? {conference_id:conferenceID} : {})}));
    // A stuck command must not leave an unresponsive invitation UI.
    pendingTimer = setTimeout(() => socket?.close(), 10000);
    render();
  }
  function join(credentials) {
    clearJoin();
    try {
      const url = new URL(credentials.url);
      if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || !credentials.conference_id || !Number.isFinite(credentials.expires_at)) throw new Error('Invalid conference link');
      $('callJoin').href = url.href;
      $('callJoin').hidden = false;
      conference = credentials;
      conferences.set(credentials.conference_id, credentials);
    } catch {
      notice('Invalid conference link');
    }
    render();
  }
  function showConferences() {
    if (library || call || pending) return;
    const view = NRCModal.create({title:'CONFERENCES', closeButton:true, onCancel:() => { library = null; }});
    library = view;
    const list = document.createElement('div'); list.className = 'call-library';
    if (!conferences.size) {
      const empty = document.createElement('p'); empty.className = 'call-hint';
      empty.textContent = 'No conferences available. Start a video call from a DM.'; list.append(empty);
    }
    for (const item of [...conferences.values()].sort((a,b) => b.expires_at - a.expires_at || a.conference_id.localeCompare(b.conference_id))) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'btn call-library-entry';
      button.dataset.conferenceId = item.conference_id;
      const title = document.createElement('strong'); title.textContent = item.title;
      const meta = document.createElement('span'); meta.textContent = expiryLabel(item);
      button.append(title, meta);
      button.onclick = () => { view.close(); library = null; conference = item; externalSession = true; panelOpen = true; $('callInvitationPeer').textContent = ''; $('callStatus').textContent = ''; render(); };
      list.append(button);
    }
    view.panel.insertBefore(list, view.actions); view.show();
  }
  function invite() {
    if (!conference?.conference_id || expired(conference) || !ready || call || pending || invitePicker) return;
    const source = conference, version = generation;
    const view = NRCModal.create({title:'INVITE PERSON', onCancel:() => { invitePicker = null; }});
    invitePicker = view;
    const field = document.createElement('label');
    field.className = 'detail-edit-field';
    field.innerHTML = '<span class="detail-edit-label">PERSON</span><nrc-select><select id="callInviteUser" class="task-detail-select" data-custom-select-wrap data-custom-select-search-placeholder="SEARCH PEOPLE..."></select></nrc-select>';
    const select = field.querySelector('select');
    for (const [id, dm] of [...activeDMs].filter(([, dm]) => !dm.optimistic && dm.username !== username).sort((a,b) => a[1].username.localeCompare(b[1].username))) {
      select.add(new Option(dm.username, String(id)));
    }
    view.panel.insertBefore(field, view.actions);
    const hint = document.createElement('p'); hint.className = 'call-hint';
    hint.textContent = select.options.length ? `Conference: ${source.title}. Choose a person from your DM contacts.` : 'No contacts available. Open a DM with the person first.';
    view.panel.insertBefore(hint, view.actions);
    for (const [label, submit] of [['CANCEL',false],['INVITE',true]]) {
      const button = document.createElement('button');
      button.type = 'button'; button.className = submit ? 'btn btn--primary' : 'btn btn--ghost'; button.textContent = label;
      button.disabled = submit && !select.options.length;
      button.onclick = () => {
        view.close(); invitePicker = null;
        if (submit && version === generation && conference === source && !expired(source)) send('start', select.value, source.conference_id);
      };
      view.actions.append(button);
    }
    view.show();
  }
  function receive(event) {
    let value;
    try { value = JSON.parse(event.data); } catch { socket?.close(); return; }
    if (value.type === 'appointment') {
      if (!appointmentRequest || value.request_id !== appointmentRequest.id) return;
      const request = appointmentRequest; appointmentRequest = null;
      clearTimeout(request.timer);
      if (value.join) request.resolve(value.join);
      else request.reject(new Error(value.message || 'Conference unavailable'));
      return;
    }
    if (value.type === 'ready') {
      username = value.username; ready = true;
      const selectedID = conference?.conference_id;
      conferences = new Map(); conference = null;
      for (const item of value.conferences || []) { join(item); }
      conference = conferences.get(selectedID) || null;
      document.dispatchEvent(new Event('nrc:calls-access'));
      externalSession = !!conference; render(); return;
    }
    if (value.type === 'error') {
      if (!call) selected = false;
      settle(); render(); notice('Invitation unavailable · user offline/busy, access denied or conference expired'); return;
    }
    if (value.type !== 'state' || !value.call) return;
    settle(); call = value.call;
    if (call.state === 'ended') {
      const text = reasons[call.reason] || 'Call ended';
      call = null; selected = false; render(); notice(text); return;
    }
    if (call.state === 'accepted') {
      $('callInvitationPeer').textContent = `INVITATION · ${call.caller === username ? call.callee : call.caller}`;
      call = null; selected = false; externalSession = !!(value.join || conference);
      if (value.join) { conference = null; clearJoin(); }
      render(); notice(value.join ? 'Invitation accepted' : 'Invitation accepted on another device');
      if (value.join) join(value.join);
      return;
    }
    render();
    if (value.join) join(value.join);
  }
  function connect(version) {
    if (version !== generation || !enabled) return;
    const url = new URL(`/calls/ws/${encodeURIComponent(workspace)}`, location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const next = new WebSocket(url); socket = next;
    next.onmessage = event => { if (socket === next) receive(event); };
    next.onclose = () => {
      if (socket !== next) return;
      socket = null; ready = false; settle();
      rejectAppointment();
      document.dispatchEvent(new Event('nrc:calls-access'));
      const hadCall = !!call; call = null; selected = false; render();
      if (hadCall) notice('Invitation cancelled · connection lost');
      retry = setTimeout(() => connect(version), 5000);
    };
  }
  function disconnect() {
    const hadCall = !!call;
    rejectAppointment();
    invitePicker?.close(); invitePicker = null; conference = null; externalSession = false;
    library?.close(); library = null; conferences.clear(); clearTimeout(expiryTimer);
    generation++; clearTimeout(retry); settle();
    const old = socket; socket = null; old?.close();
    enabled = false; ready = false; username = ''; call = null; selected = false;
    document.dispatchEvent(new Event('nrc:calls-access'));
    stopRing(); clearJoin(); render();
    panelOpen = hadCall; $('callPanel').hidden = !hadCall;
    if (hadCall) notice('Invitation cancelled · connection lost');
  }
  async function refreshAccess() {
    disconnect();
    const version = generation;
    workspace = currentWorkspaceId;
    try {
      const response = await fetch('/api/features', {credentials:'same-origin', cache:'no-store'});
      const features = response.ok ? await response.json() : {};
      if (version !== generation || features.calls !== true) return;
      enabled = true; render(); connect(version);
    } catch { /* Optional service stays absent when not configured. */ }
  }

  function rejectAppointment() {
    if (!appointmentRequest) return;
    clearTimeout(appointmentRequest.timer);
    appointmentRequest.reject(new Error('Conference service disconnected'));
    appointmentRequest = null;
  }
  function joinAppointment(assetID, occurrenceAt) {
    if (!ready || socket?.readyState !== WebSocket.OPEN) return Promise.reject(new Error('Conference service unavailable'));
    if (appointmentRequest) return Promise.reject(new Error('Conference preparation already in progress'));
    return new Promise((resolve, reject) => {
      const id = String(++requestSequence);
      const timer = setTimeout(() => {
        appointmentRequest = null;
        reject(new Error('Conference preparation timed out · retry'));
      }, 10000);
      appointmentRequest = {id, resolve, reject, timer};
      socket.send(JSON.stringify({action:'appointment', request_id:id, appointment_id:String(assetID), occurrence_at:String(occurrenceAt)}));
    });
  }
  window.NRCCalls = {refreshAccess, disconnect, render, joinAppointment, available:() => enabled && ready};
  document.addEventListener('DOMContentLoaded', () => {
    $('callStart').onclick = () => send('start');
    $('callAccept').onclick = () => send('accept');
    $('callDecline').onclick = () => send('decline');
    $('callEnd').onclick = () => send('cancel');
    $('callInvite').onclick = invite;
    $('callHistory').onclick = showConferences;
    $('callDismiss').onclick = () => { panelOpen = false; render(); $('callHistory').focus(); };
  });
  document.addEventListener('pointerdown', unlockAudio);
  document.addEventListener('keydown', unlockAudio);
  window.addEventListener('pagehide', disconnect);
})();
