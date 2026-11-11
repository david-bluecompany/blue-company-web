const state = {
  user: null,
  view: 'dashboard'
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function formatDate(dateText) {
  if (!dateText) return '—';
  const d = new Date(dateText);
  return Number.isNaN(d.getTime()) ? dateText : d.toLocaleString('es-ES', { dateStyle: 'medium' });
}

async function checkSession() {
  const res = await fetch('/api/session');
  const data = await res.json();
  state.user = data.user || null;
  const loginScreen = $('#login-screen');
  const appShell = $('#app-shell');
  if (data.logged_in) {
    loginScreen.classList.add('hidden');
    appShell.classList.remove('hidden');
    $('#current-user').textContent = data.user;
    loadDashboard();
  } else {
    appShell.classList.add('hidden');
    loginScreen.classList.remove('hidden');
  }
}

async function loadDashboard() {
  try {
    const [dashboardRes, usersRes, servicesRes, logsRes] = await Promise.all([
      fetch('/api/dashboard'),
      fetch('/api/users'),
      fetch('/api/services'),
      fetch('/api/logs')
    ]);

    const dashboard = await dashboardRes.json();
    const users = await usersRes.json();
    const services = await servicesRes.json();
    const logs = await logsRes.json();

    $('#stat-users').textContent = dashboard.totals.users;
    $('#stat-users-sub').textContent = `${dashboard.totals.active_users} activos`;
    $('#stat-sessions').textContent = dashboard.totals.sessions;
    $('#stat-sessions-sub').textContent = `/${dashboard.totals.limit}`;
    $('#stat-services').textContent = dashboard.totals.services_active;
    $('#stat-services-sub').textContent = `/ ${dashboard.totals.services_total}`;
    $('#stat-memory').textContent = `${dashboard.totals.memory_used}%`;
    $('#stat-memory-sub').textContent = 'uso';
    $('#server-name').textContent = dashboard.server.name;
    $('#server-meta').textContent = `${dashboard.server.os} · Linux · 4 núcleos`;
    $('#server-ip').textContent = dashboard.server.ip;
    $('#cpu-value').textContent = `${dashboard.totals.server_load}%`;
    $('#ram-value').textContent = `${dashboard.totals.memory_used}%`;
    $('#disk-value').textContent = `${dashboard.totals.disk_used}%`;
    $('#cpu-bar').style.width = `${dashboard.totals.server_load}%`;
    $('#ram-bar').style.width = `${dashboard.totals.memory_used}%`;
    $('#disk-bar').style.width = `${dashboard.totals.disk_used}%`;

    const preview = services.slice(0, 5).map(s => `
      <div class="list-item">
        <div>
          <strong>${s.name}</strong>
          <div class="tiny">${s.port}</div>
        </div>
        <span class="badge ${s.status === 'active' ? 'active' : 'inactive'}">${s.status === 'active' ? 'Activo' : 'Inactivo'}</span>
      </div>
    `).join('');
    $('#services-preview').innerHTML = preview;

    const audits = logs.slice(0, 5).map(log => `
      <tr>
        <td>${formatDate(log.timestamp)}</td>
        <td>${log.action}</td>
        <td>${log.details}</td>
      </tr>
    `).join('');
    $('#audit-table').innerHTML = audits;

    renderUsers(users);
    renderLimits(users);
    renderServices(services);
    renderLogs(logs);
    bindNav();
  } catch (err) {
    console.error(err);
  }
}

function renderUsers(users) {
  const q = $('#user-search')?.value || '';
  const visible = users.filter(u => u.username.toLowerCase().includes(q.toLowerCase()));
  $('#user-table').innerHTML = visible.map(u => `
    <tr>
      <td>${u.username}</td>
      <td>${u.limit_connections}</td>
      <td>${u.expiration || '—'}</td>
      <td><span class="badge ${u.state === 'active' ? 'active' : 'inactive'}">${u.state === 'active' ? 'Activo' : 'Suspendido'}</span></td>
      <td>
        <button class="primary-btn" data-id="${u.id}" data-state="${u.state === 'active' ? 'suspended' : 'active'}">${u.state === 'active' ? 'Suspender' : 'Reactivar'}</button>
      </td>
    </tr>
  `).join('');

  $('#user-table .primary-btn').forEach(button => {
    button.addEventListener('click', async () => {
      const id = button.dataset.id;
      const stateValue = button.dataset.state;
      await fetch(`/api/users/${id}/toggle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ state: stateValue })
      });
      loadDashboard();
    });
  });
}

function renderLimits(users) {
  const html = users.map(u => `
    <div class="limit-card">
      <h4>${u.username}</h4>
      <div class="tiny">Sesiones: ${u.limit_connections}</div>
      <div class="progress" style="margin-top:12px"><div style="width:${Math.min(100, 50)}%"></div></div>
    </div>
  `).join('');
  $('#limit-cards').innerHTML = html;
}

function renderServices(services) {
  const html = services.map(s => `
    <div class="list-item">
      <div>
        <strong>${s.name}</strong>
        <div class="tiny">${s.port} · ${s.description}</div>
      </div>
      <button class="primary-btn" data-service-id="${s.id}" data-status="${s.status === 'active' ? 'inactive' : 'active'}">${s.status === 'active' ? 'Desactivar' : 'Activar'}</button>
    </div>
  `).join('');
  $('#services-table').innerHTML = html;

  $('#services-table .primary-btn').forEach(button => {
    button.addEventListener('click', async () => {
      const id = button.dataset.serviceId;
      const status = button.dataset.status;
      await fetch(`/api/services/${id}/toggle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status })
      });
      loadDashboard();
    });
  });
}

function renderLogs(logs) {
  $('#logs-list').innerHTML = logs.map(log => `
    <div class="list-item">
      <div>
        <strong>${log.action}</strong>
        <div class="tiny">${log.details}</div>
      </div>
      <span class="tiny">${formatDate(log.timestamp)}</span>
    </div>
  `).join('');
}

function bindNav() {
  const navLinks = $$('.nav-link');
  navLinks.forEach(link => {
    link.addEventListener('click', (e) => {
      e.preventDefault();
      const target = link.getAttribute('href').replace('#', '');
      state.view = target;
      $$('.nav-link').forEach(item => item.classList.toggle('active', item === link));
      $$('.page').forEach(page => page.classList.toggle('active', page.id === target));
      $('#page-title').textContent = link.textContent.trim();
    });
  });
}

$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target).entries());
  const res = await fetch('/api/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  });
  const result = await res.json();
  if (!result.ok) {
    alert(result.error || 'Error de autenticación');
    return;
  }
  await checkSession();
});

$('#logout-btn').addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST' });
  await checkSession();
});

$('#new-user-btn').addEventListener('click', () => {
  $('#modal').classList.remove('hidden');
});

$('#close-modal').addEventListener('click', () => {
  $('#modal').classList.add('hidden');
});

$('#user-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = new FormData(e.target);
  const payload = Object.fromEntries(form.entries());
  const response = await fetch('/api/users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const result = await response.json();
  if (!result.ok) {
    alert(result.error || 'No se pudo crear el usuario');
    return;
  }
  $('#modal').classList.add('hidden');
  e.target.reset();
  loadDashboard();
});

$('#user-search').addEventListener('input', () => {
  if (state.user) {
    fetch('/api/users')
      .then(r => r.json())
      .then(renderUsers);
  }
});

checkSession();
