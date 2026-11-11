const state = { user: null, csrf: null, users: [], services: [], logs: [] };
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

async function api(url, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body) headers.set('Content-Type', 'application/json');
  if (options.method && options.method !== 'GET' && state.csrf) headers.set('X-CSRF-Token', state.csrf);
  const response = await fetch(url, { ...options, headers, credentials: 'same-origin' });
  const data = await response.json().catch(() => ({}));
  if (response.status === 401 && url !== '/api/login') { showLogin(); throw new Error('Tu sesión terminó. Vuelve a iniciar sesión.'); }
  if (!response.ok) throw new Error(data.error || `Error HTTP ${response.status}`);
  return data;
}
function showToast(message) {
  const toast = $('#toast'); toast.textContent = message; toast.classList.add('show');
  clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove('show'), 2800);
}
function showLogin() { $('#app-shell').classList.add('hidden'); $('#login-screen').classList.remove('hidden'); }
function showApp() { $('#login-screen').classList.add('hidden'); $('#app-shell').classList.remove('hidden'); }
function setPage(name) {
  const page = document.getElementById(name) ? name : 'dashboard';
  $$('.page').forEach(section => section.classList.toggle('active', section.id === page));
  $$('.nav-link').forEach(link => link.classList.toggle('active', link.dataset.page === page));
  $('#page-title').textContent = ({dashboard:'Resumen',users:'Usuarios',limits:'Límites',expiry:'Vencimientos',services:'Servicios',security:'Auditoría'})[page];
}
async function checkSession() {
  try {
    const data = await api('/api/session'); state.user = data.user; state.csrf = data.csrf_token;
    if (!data.logged_in) return showLogin();
    $('#current-user').textContent = state.user; showApp(); await loadAll();
  } catch (error) { showLogin(); }
}
async function loadAll() {
  const [dashboard, users, services, logs] = await Promise.all([
    api('/api/dashboard'), api('/api/users'), api('/api/services'), api('/api/logs')
  ]);
  state.users = users; state.services = services; state.logs = logs;
  $('#stat-users').textContent = dashboard.users.total;
  $('#stat-users-sub').textContent = `${dashboard.users.active} activos · registros solamente`;
  $('#stat-services').textContent = dashboard.services.length;
  $('#stat-expiry').textContent = dashboard.upcoming_expirations.length;
  renderServices(); renderUsers(); renderLimits(); renderExpiry(); renderLogs();
}
function renderServices() {
  const markup = state.services.map(service => `<div class="list-item"><span><strong>${esc(service.name)}</strong><small>Puertos: ${esc(service.ports)}</small></span><span class="read-only">Solo referencia</span></div>`).join('');
  $('#services-preview').innerHTML = markup; $('#services-table').innerHTML = markup;
}
function renderUsers() {
  const query = ($('#user-search').value || '').trim().toLowerCase();
  const filtered = state.users.filter(user => user.username.toLowerCase().includes(query));
  $('#user-table').innerHTML = filtered.map(user => `<tr><td><strong>${esc(user.username)}</strong></td><td>${user.max_sessions}</td><td>${esc(user.expires_on)}</td><td><span class="state ${user.status}">${user.status === 'active' ? 'Activo' : 'Suspendido'}</span></td><td>${esc(user.notes || '—')}</td><td><button class="table-action" data-edit="${user.id}">Editar</button><button class="table-action danger" data-delete="${user.id}">Eliminar</button></td></tr>`).join('') || '<tr><td colspan="6">No hay registros.</td></tr>';
  $$('[data-edit]', $('#user-table')).forEach(button => button.addEventListener('click', () => openDialog(state.users.find(u => u.id === Number(button.dataset.edit)))));
  $$('[data-delete]', $('#user-table')).forEach(button => button.addEventListener('click', () => deleteUser(Number(button.dataset.delete))));
}
function renderLimits() {
  $('#limit-cards').innerHTML = state.users.map(user => `<article class="limit-card"><strong>${esc(user.username)}</strong><span>Máximo registrado: ${user.max_sessions}</span><small>No aplicado a sesiones reales.</small></article>`).join('') || '<p>No hay registros.</p>';
}
function renderExpiry() {
  $('#expiry-table').innerHTML = [...state.users].sort((a,b) => a.expires_on.localeCompare(b.expires_on)).map(user => `<tr><td>${esc(user.username)}</td><td>${esc(user.expires_on)}</td><td><span class="state ${user.status}">${user.status === 'active' ? 'Activo' : 'Suspendido'}</span></td><td>${esc(user.notes || '—')}</td></tr>`).join('') || '<tr><td colspan="4">No hay registros.</td></tr>';
}
function renderLogs() {
  const markup = state.logs.map(log => `<div class="list-item"><span><strong>${esc(log.action)}</strong><small>${esc(log.actor)} · ${esc(log.target)} · ${esc(log.detail)}</small></span><time>${esc(new Date(log.occurred_at).toLocaleString())}</time></div>`).join('');
  $('#logs-list').innerHTML = markup || '<p>No hay eventos.</p>';
  $('#audit-table').innerHTML = state.logs.slice(0,8).map(log => `<tr><td>${esc(new Date(log.occurred_at).toLocaleString())}</td><td>${esc(log.actor)}</td><td>${esc(log.action)}</td><td>${esc(log.target)}</td><td>${esc(log.detail)}</td></tr>`).join('') || '<tr><td colspan="5">No hay eventos.</td></tr>';
}
function openDialog(user = null) {
  const form = $('#user-form'); form.reset(); $('#form-error').textContent = '';
  $('#dialog-title').textContent = user ? 'Editar registro' : 'Agregar registro';
  form.elements.id.value = user?.id || '';
  form.elements.username.value = user?.username || '';
  form.elements.max_sessions.value = user?.max_sessions || 1;
  form.elements.expires_on.value = user?.expires_on || new Date().toISOString().slice(0,10);
  form.elements.status.value = user?.status || 'active'; form.elements.notes.value = user?.notes || '';
  $('#user-dialog').showModal();
}
async function deleteUser(id) {
  const user = state.users.find(item => item.id === id);
  if (!user || !confirm(`¿Eliminar el registro de ${user.username}? No se modifica ninguna cuenta del sistema.`)) return;
  try { await api(`/api/users/${id}`, {method:'DELETE'}); await loadAll(); showToast('Registro eliminado.'); }
  catch (error) { showToast(error.message); }
}
$('#login-form').addEventListener('submit', async event => {
  event.preventDefault(); $('#login-error').textContent = '';
  const values = Object.fromEntries(new FormData(event.currentTarget));
  try {
    const result = await api('/api/login', {method:'POST', body:JSON.stringify(values)});
    state.user = result.user; state.csrf = result.csrf_token; $('#current-user').textContent = state.user;
    showApp(); await loadAll();
  } catch (error) { $('#login-error').textContent = error.message; }
});
$('#logout-btn').addEventListener('click', async () => {
  try { await api('/api/logout', {method:'POST'}); state.user = null; state.csrf = null; showLogin(); }
  catch (error) { showToast(error.message); }
});
$('#new-user-btn').addEventListener('click', () => openDialog());
$('#close-dialog').addEventListener('click', () => $('#user-dialog').close());
$('#cancel-dialog').addEventListener('click', () => $('#user-dialog').close());
$('#user-search').addEventListener('input', renderUsers);
$('#user-form').addEventListener('submit', async event => {
  event.preventDefault(); const form = event.currentTarget; const id = form.elements.id.value;
  const payload = {username:form.elements.username.value, max_sessions:Number(form.elements.max_sessions.value), expires_on:form.elements.expires_on.value, status:form.elements.status.value, notes:form.elements.notes.value};
  try {
    await api(id ? `/api/users/${id}` : '/api/users', {method:id ? 'PUT' : 'POST', body:JSON.stringify(payload)});
    $('#user-dialog').close(); await loadAll(); showToast('Registro guardado.');
  } catch (error) { $('#form-error').textContent = error.message; }
});
$$('.nav-link').forEach(link => link.addEventListener('click', event => {event.preventDefault(); const name=link.dataset.page; location.hash=name; setPage(name);}));
window.addEventListener('hashchange', () => setPage(location.hash.slice(1)));
setPage(location.hash.slice(1)); checkSession();
