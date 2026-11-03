/* FolderSync 界面：mode=popover（菜单栏浮层，标签页） / mode=window（独立窗口，侧边栏导航） */
(function () {
  'use strict';
  const params = new URLSearchParams(location.search);
  const MODE = params.get('mode') || 'window';
  document.body.classList.add(MODE);

  // ---------------- 原生桥接（浏览器里打开时用模拟数据，便于调试） ----------------
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fs;
  let seq = 0;
  const pending = {};
  window.__fsReply = (id, obj) => { const p = pending[id]; if (p) { delete pending[id]; p(obj); } };
  function call(cmd, extra) {
    return new Promise((resolve) => {
      const id = 'r' + (++seq);
      pending[id] = resolve;
      const msg = Object.assign({ id, cmd }, extra || {});
      if (native) native.postMessage(msg); else Mock.handle(msg);
    });
  }
  const cli = (args, timeout) => call('run', { args, timeout });

  // ---------------- 图标（与菜单栏一致的上下箭头） ----------------
  const P = {
    logo: '<path d="M7 20V4M3 8l4-4 4 4M17 4v16M13 16l4 4 4-4"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>',
    expand: '<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  };
  const ico = (n) => `<svg class="i" viewBox="0 0 24 24">${P[n]}</svg>`;

  // ---------------- 状态与路由 ----------------
  let S = { rules: [], now: Date.now() / 1000, settings: {} };
  // window: projects | project:<名> | new | history | settings；popover: rules | history | settings
  let route = MODE === 'window' ? 'projects' : 'rules';
  let stamp = 0;
  let copyFrom = null;      // "复制"时作为新建表单的预填来源
  const keys = {};          // 各区块上次渲染的内容指纹：没变就不重画（避免闪烁、避免冲掉正在输入的内容）

  window.__fsState = (s) => { S = s; stamp = Date.now(); update(); };
  window.__fsRoute = (r) => { if (r) go(r === 'rules' && MODE === 'window' ? 'projects' : r); };

  // ---------------- 工具 ----------------
  const $ = (s, el) => (el || document).querySelector(s);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const home = (p) => (p || '').replace(/^\/Users\/[^/]+/, '~');
  function ago(t) {
    if (!t) return '';
    const d = Math.max(0, S.now - t);
    if (d < 60) return '刚刚';
    if (d < 3600) return Math.floor(d / 60) + ' 分钟前';
    if (d < 86400) return Math.floor(d / 3600) + ' 小时前';
    const dt = new Date(t * 1000);
    return (dt.getMonth() + 1) + '月' + dt.getDate() + '日 ' + String(dt.getHours()).padStart(2, '0') + ':' + String(dt.getMinutes()).padStart(2, '0');
  }
  const speed = (b) => b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB/s' : Math.round((b || 0) / 1024) + ' KB/s';
  const TRIG = { change: '推送改动', full: '全量同步', push: '上传', pull: '下载', preview: '预览' };
  function toast(msg) {
    const t = $('#toast'); t.textContent = msg; t.classList.add('on');
    clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove('on'), 2600);
  }
  const outMsg = (r) => ((r.err || '') + '\n' + (r.out || '')).trim().split('\n').filter(Boolean).slice(-4).join('\n');
  const rules = () => S.rules || [];
  const ruleBy = (n) => rules().find((r) => r.name === n);
  const tick30 = () => Math.floor((S.now || 0) / 30);     // 相对时间每 30 秒刷新一次
  const runKey = (r) => r ? [r.phase, r.trigger, r.percent, r.files_done, r.deleted, r.speed_bps, r.current_file, r.checked, r.check_total, r.eta_s,
    r.current_started_at ? Math.floor((S.now - r.current_started_at) / 1) : 0].join('|') : '';
  const lastKey = (l) => l ? [l.run_id, l.result, l.acked, l.summary].join('|') : '';
  const ruleKey = (r) => [r.name, r.enabled, r.valid, r.delete, r.local, r.remote, r.host, r.user, r.error, runKey(r.run), lastKey(r.last)].join('§');
  function ruleDot(r) {
    if (r.run) return 'run';
    if (r.last && r.last.result === 'failed' && !r.last.acked) return 'bad';
    return r.enabled ? 'ok' : 'off';
  }

  // ---------------- 拖动窗口：顶部区域被网页覆盖，按下时交给原生窗口拖动 ----------------
  document.addEventListener('mousedown', (e) => {
    if (MODE !== 'window' || e.button !== 0) return;
    if (e.target.closest('button, input, textarea, select, a')) return;
    if (!e.target.closest('[data-drag]')) return;
    if (e.detail === 2) { call('zoom'); return; }
    call('drag');
  });

  // ---------------- 外框 ----------------
  function shell() {
    const app = $('#app');
    if (MODE === 'popover') {
      app.innerHTML = `<div class="pop">
        <header class="top">
          <div class="brand"><span class="logo">${ico('logo')}</span><span>FolderSync</span><span id="daemon" class="dot"></span></div>
          <div class="actions">
            <button class="icon" data-a="refresh" title="刷新">${ico('refresh')}</button>
            <button class="icon" data-a="expand" title="在窗口中打开">${ico('expand')}</button>
            <button class="icon" data-a="settings" title="设置">${ico('gear')}</button>
          </div>
        </header>
        <nav class="tabs">
          <button data-go="rules">项目</button><button data-go="history">日志</button>
        </nav>
        <main id="main"></main>
        <footer class="bottom"><span id="updated">—</span><span class="grow"></span><span id="verline"></span><button class="link" data-a="quit">退出</button></footer>
      </div>`;
    } else {
      app.innerHTML = `<div class="win">
        <aside class="side">
          <div class="side-top" data-drag><span class="logo">${ico('logo')}</span><span>FolderSync</span></div>
          <div class="side-nav" id="sidenav"></div>
          <div class="side-foot" data-drag><span id="daemon" class="dot"></span><span id="daemon-text">—</span></div>
        </aside>
        <section class="content">
          <header class="crumb" data-drag id="crumb"></header>
          <main id="main"></main>
        </section>
      </div>`;
    }
  }

  function go(r) {
    if (r !== 'new') copyFrom = null;
    route = r;
    Object.keys(keys).forEach((k) => delete keys[k]);
    renderPage();
    update();
    const m = $('#main'); if (m) m.scrollTop = 0;
  }

  // 每次状态推送：只更新内容真正变化的区块
  function update() {
    const d = $('#daemon');
    if (d) d.className = 'dot' + (S.daemon_running ? ' on' : '');
    const dt = $('#daemon-text');
    if (dt) dt.textContent = S.daemon_running ? '后台守护运行中' : '后台守护未运行';
    const up = $('#updated');
    if (up) up.textContent = stamp ? '刚刚更新' : '—';
    document.querySelectorAll('.tabs [data-go]').forEach((b) => b.classList.toggle('on', b.dataset.go === route));
    if (MODE === 'window') renderSide();
    renderVersion();

    if (route === 'rules' || route === 'projects') {
      const k = rules().map(ruleKey).join('#') + tick30() + (S.error || '');
      if (keys.list !== k) { keys.list = k; $('#main').innerHTML = listHTML(); }
    } else if (route.startsWith('project:')) {
      const r = ruleBy(route.slice(8));
      if (!r) { if (rules().length) go('projects'); return; }
      if (!$('#proj-status')) { renderPage(); keys.status = ''; }   // 首次打开时数据还没到：到达后补画整页
      const k = ruleKey(r) + tick30();
      if (keys.status !== k) { keys.status = k; const el = $('#proj-status'); if (el) el.innerHTML = statusCardHTML(r, true); }
    } else if (route === 'history') {
      // 有同步结束才重新取记录；时间文字每 30 秒原地刷新
      const k = rules().map((r) => lastKey(r.last)).join('#');
      if (keys.hist !== k) { keys.hist = k; loadHistory(); }
      const tk = tick30();
      if (keys.histTick !== tk) { keys.histTick = tk; updateTimes(); }
    } else if (route === 'settings') {
      // 设置页不随状态推送重画（会冲掉正在输入的内容）；但首次打开时配置还没加载，到达后补画一次
      if (!keys.settingsReady && S.global) { keys.settingsReady = true; renderPage(); }
      const el = $('#svc-line');
      if (el) el.textContent = `${S.daemon_running ? '运行中' : '未运行'} · rsync：${S.rsync || '未找到 GNU rsync（brew install rsync）'}`;
      const b = $('[data-sys=reload]');
      if (b && !b.disabled) b.textContent = S.daemon_running ? '重启守护' : '启动守护';
      const ul = $('#upd-line');
      if (ul) ul.textContent = updStatus(S.update || {});
    }
  }
  // ---------------- 版本号与更新 ----------------
  let verKey = '';
  function updLabel(u) {
    if (u.state === 'downloading') return `下载中 ${Math.round((u.progress || 0) * 100)}%`;
    if (u.state === 'installing') return '正在安装…';
    if (u.state === 'available') return `更新到 ${u.version}`;
    return '';
  }
  function updButtonHTML() {
    const u = S.update || {}, label = updLabel(u);
    if (!label) return '';
    const busy = u.state !== 'available';
    return `<button class="upd" data-a="update" title="从 GitHub 下载新版本并覆盖安装，完成后自动重启"${busy ? ' disabled' : ''}>${ico('refresh')}<span>${esc(label)}</span></button>`;
  }
  function updStatus(u) {
    if (u.state === 'checking') return '正在检查更新…';
    if (u.state === 'downloading') return `正在下载更新 ${Math.round((u.progress || 0) * 100)}%`;
    if (u.state === 'installing') return '正在安装，应用即将重启…';
    if (u.state === 'available') return `有新版本 ${u.version} 可用`;
    if (u.state === 'latest') return '已是最新版本';
    if (u.state === 'failed') return `检查更新失败：${u.message || '未知原因'}`;
    return '自动检查更新（每 6 小时一次）';
  }
  // 小窗底部：版本号常驻，有新版本时版本号左侧出现高亮更新按钮
  function renderVersion() {
    const u = S.update || {};
    const key = [S.version, u.state, u.version, u.progress, u.message].join('|');
    if (key === verKey) return;
    verKey = key;
    const box = $('#verline');
    if (box) box.innerHTML = updButtonHTML() + `<span class="ver" title="当前版本">v${esc(S.version || '')}</span>`;
    const ub = $('#upd-box');
    if (ub) ub.innerHTML = updButtonHTML() || '<button class="btn" data-a="check-update">检查更新</button>';
  }



  function renderSide() {
    const nav = $('#sidenav');
    if (!nav) return;
    const k = route + '|' + rules().map((r) => r.name + ruleDot(r)).join(',');
    if (keys.side === k) return;
    keys.side = k;
    const on = (r) => route === r ? ' on' : '';
    nav.innerHTML = `
      <button class="nav${on('projects')}" data-go="projects">${ico('folder')}<span>项目</span><span class="badge">${rules().length}</span></button>
      <div class="sub">
        ${rules().map((r) => `<button class="subitem${on('project:' + r.name)}" data-go="project:${esc(r.name)}"><i class="dot ${ruleDot(r)}"></i><span class="n">${esc(r.name)}</span></button>`).join('')}
        <button class="subitem add${on('new')}" data-go="new">＋ 新增项目</button>
      </div>
      <button class="nav${on('history')}" data-go="history">${ico('clock')}<span>日志</span></button>
      <button class="nav${on('settings')}" data-go="settings">${ico('gear')}<span>设置</span></button>`;
  }

  function crumb(parts) {
    const c = $('#crumb');
    if (!c) return;
    c.innerHTML = parts.map((p, i) => i < parts.length - 1
      ? `<button class="c" data-go="${esc(p[1])}">${esc(p[0])}</button><span class="sep">/</span>`
      : `<b>${esc(p[0])}</b>`).join('') + `<span class="actions"><button class="icon" data-a="refresh" title="刷新">${ico('refresh')}</button></span>`;
  }

  // 切换页面时整页渲染；之后由 update() 做增量更新
  function renderPage() {
    verKey = '';   // 整页重画后「关于」里的更新按钮要重新计算
    const m = $('#main');
    if (route === 'rules' || route === 'projects') { crumb([['项目']]); m.innerHTML = listHTML(); }
    else if (route === 'history') { crumb([['日志']]); histSig = ''; histShown = FIRST; m.innerHTML = '<div id="hist"><div class="empty">加载中…</div></div>'; }
    else if (route === 'settings') { crumb([['设置']]); m.innerHTML = settingsHTML(); bindSettings(); }
    else if (route === 'setup') { crumb([['安装']]); m.innerHTML = '<div id="setup"><div class="empty">正在检查运行环境…</div></div>'; loadSetup(); }
    else if (route === 'new') {
      crumb([['项目', 'projects'], [copyFrom ? '复制「' + copyFrom.name + '」' : '新增项目']]);
      m.innerHTML = editorHTML(null, copyFrom); bindEditor(null);
    }
    else if (route.startsWith('project:')) {
      const name = route.slice(8), r = ruleBy(name);
      if (!r) { m.innerHTML = '<div class="empty">加载中…</div>'; return; }
      crumb([['项目', 'projects'], [name]]);
      m.innerHTML = `<div class="section">状态</div><div id="proj-status">${statusCardHTML(r, true)}</div>
        <div class="section" style="margin-top:18px">配置</div>${editorHTML(r)}`;
      bindEditor(r);
    }
  }

  // ---------------- 项目卡片 ----------------
  function statusLine(r) {
    const run = r.run, last = r.last;
    if (run) {
      const ph = run.phase, trig = TRIG[run.trigger] || '同步';
      if (ph === 'connecting') return `<div class="status">${trig} · 连接中…<div class="bar indet"><i></i></div></div>`;
      if (ph === 'scanning') return `<div class="status">${trig} · 比对中 ${run.checked}/${run.check_total || '?'}<div class="bar indet"><i></i></div></div>`;
      const curFor = run.current_started_at ? Math.floor(S.now - run.current_started_at) : 0;
      return `<div class="status">${trig} ${run.percent}% · 已传 ${run.files_done} 个${run.deleted ? ' · 删除 ' + run.deleted : ''} · ${speed(run.speed_bps)}${run.eta_s != null ? ' · 剩约 ' + run.eta_s + ' 秒' : ''}
        ${run.current_file ? `<span class="file">当前：${esc(run.current_file)}${curFor >= 5 ? '（' + curFor + ' 秒）' : ''}</span>` : ''}
        <div class="bar"><i style="width:${run.percent}%"></i></div></div>`;
    }
    if (!last) return `<div class="status">尚未同步</div>`;
    if (last.result === 'failed') return `<div class="status bad">${last.acked ? '' : '● '}同步失败 · ${esc(last.error)} · ${ago(last.finished_at)}</div>`;
    return `<div class="status">${esc(last.summary)} · ${TRIG[last.trigger] || ''} · ${ago(last.finished_at)}</div>`;
  }

  function actionBtns(r, detail) {
    const run = r.run, last = r.last;
    const failed = last && last.result === 'failed' && !last.acked && !run;
    const canSkip = run && run.phase === 'transferring' && run.current_file && run.current_started_at &&
      (S.now - run.current_started_at) >= 5;   // 与状态条一致：程序内部固定 5 秒
    const b = [];
    if (run) {
      if (canSkip) b.push(`<button class="btn" data-act="skip">跳过当前文件</button>`);
      b.push(`<button class="btn danger" data-act="cancel">停止</button>`);
    } else if (failed) {
      b.push(`<button class="btn primary" data-act="retry">重试</button>`, `<button class="btn" data-act="ack">关闭提示</button>`);
    } else {
      b.push(`<button class="btn" data-act="full" ${r.enabled && r.valid ? '' : 'disabled'}>全量同步</button>`);
    }
    if (!detail) b.push(`<button class="btn" data-act="edit">编辑</button>`);
    if (!run) b.push(`<button class="btn" data-act="toggle">${r.enabled ? '停用' : '启用'}</button>`);
    if (MODE === 'window') b.push(`<button class="btn" data-act="copy">复制</button>`);
    b.push(`<button class="btn" data-act="reveal">打开目录</button>`);
    return `<div class="btns">${b.join('')}</div>`;
  }

  function statusCardHTML(r, detail) {
    const failed = r.last && r.last.result === 'failed' && !r.last.acked && !r.run;
    return `<div class="card ${failed ? 'failed' : ''} ${r.enabled ? '' : 'disabled'}" data-rule="${esc(r.name)}">
      <div class="row"><span class="name ${detail ? '' : 'click'}" ${detail ? '' : 'data-act="edit"'}>${esc(r.name)}</span>
        ${r.enabled ? '' : '<span class="badge">已停用</span>'}
        ${r.delete ? '<span class="badge del">同步删除</span>' : ''}
        ${r.valid ? '' : '<span class="badge del" title="' + esc(r.error) + '">配置有误</span>'}
      </div>
      <div class="path" title="${esc(r.local)} → ${esc(r.user)}@${esc(r.host)}:${esc(r.remote)}">${esc(home(r.local))} → ${esc(r.user)}@${esc(r.host)}:${esc(r.remote)}</div>
      ${statusLine(r)}
      ${!r.valid ? `<div class="status bad">${esc(r.error)}</div>` : ''}
      ${actionBtns(r, detail)}
    </div>`;
  }

  function listHTML() {
    if (S.error && !rules().length) return `<div class="errbox">${esc(S.error)}</div>`;
    if (!rules().length) return `<div class="empty">还没有同步项目<br><br><button class="btn primary" data-a="new">新增项目</button></div>`;
    const running = rules().filter((r) => r.run).length;
    return `<div class="section">同步项目<span class="tag">${running ? running + ' 个同步中' : rules().length + ' 个'}</span></div>
      <div class="grid">${rules().map((r) => statusCardHTML(r, false)).join('')}</div>`;
  }

  // ---------------- 编辑表单 ----------------
  function editorHTML(r, prefill) {
    const isNew = !r;
    if (isNew && prefill) r = Object.assign({}, prefill, { name: prefill.name + '-copy', run: null, last: null });
    r = r || { name: '', enabled: true, local: '', remote: '', host: '', port: '22', user: '', key_file: '', delete: false, include: [], exclude: ['.git/**', 'node_modules/**', '.DS_Store'], extra: '', remote_owner: '' };
    return `<form class="editor card" onsubmit="return false">
      <div id="ed-err"></div>
      <div class="field"><label>名称</label><input type="text" name="name" value="${esc(r.name)}" placeholder="字母、数字、. _ -"></div>
      <div class="field switch"><input type="checkbox" name="enabled" id="ed-en" ${r.enabled ? 'checked' : ''}><label for="ed-en">启用（监听本地改动并自动推送）</label></div>
      <div class="field"><label>本地目录</label><div class="inline"><input type="text" name="local" value="${esc(r.local)}"><button class="btn" type="button" data-pick="folder">选择…</button></div></div>
      <div class="cols">
        <div class="field"><label>服务器</label><input type="text" name="host" value="${esc(r.host)}"></div>
        <div class="field"><label>端口</label><input type="number" name="port" value="${esc(r.port || 22)}"></div>
        <div class="field"><label>用户名</label><input type="text" name="user" value="${esc(r.user)}"></div>
      </div>
      <div class="field"><label>远端目录（绝对路径）</label><input type="text" name="remote" value="${esc(r.remote)}"></div>
      <div class="field"><label>SSH 私钥</label><div class="inline"><input type="text" name="key_file" value="${esc(r.key_file)}" placeholder="留空则使用 ssh-agent"><button class="btn" type="button" data-pick="file">选择…</button></div></div>
      <div class="field switch"><input type="checkbox" name="delete" id="ed-del" ${r.delete ? 'checked' : ''}><label for="ed-del">同步删除远端文件</label></div>
      <div class="warnbox" id="ed-delwarn" style="display:${r.delete ? 'block' : 'none'}">开启后：本地删除的文件会立即在远端删除；手动全量同步时远端多出的文件也会被删除。远端删除不可恢复；下方"排除"里的路径永远不会被删除。</div>
      <div class="field"><label>排除（每行一项）</label><textarea name="exclude" spellcheck="false">${esc((r.exclude || []).join('\n'))}</textarea><div class="hint">* 匹配一层，** 匹配多层，例如 .git/**、*.log、runtime/**</div></div>
      <div class="field"><label>仅包含（可选，每行一项）</label><textarea name="include" spellcheck="false">${esc((r.include || []).join('\n'))}</textarea><div class="hint">填写后只同步匹配的文件</div></div>
      <div class="cols" style="grid-template-columns:1fr 1fr">
        <div class="field"><label>远端属主（可选）</label><input type="text" name="remote_owner" value="${esc(r.remote_owner)}" placeholder="www:www"></div>
        <div class="field"><label>附加 rsync 参数（可选）</label><input type="text" name="extra" value="${esc(r.extra)}"></div>
      </div>
      <div class="btns">
        <button class="btn primary" type="button" data-ed="save">${isNew ? '创建' : '保存'}</button>
        ${isNew ? '' : '<button class="btn" type="button" data-ed="test">测试连接</button>'}
        <button class="btn" type="button" data-ed="back">返回列表</button>
        <span class="grow"></span>
        ${isNew ? '' : '<button class="btn danger" type="button" data-ed="remove">删除项目</button>'}
      </div>
    </form>`;
  }

  // 文本框随内容加高：最少 3 行，最多 15 行，超出后出现滚动条
  function autoGrow(t) {
    const line = 18, pad = 14, max = line * 15 + pad;
    t.style.height = 'auto';
    const h = Math.min(Math.max(t.scrollHeight, line * 3 + pad), max);
    t.style.height = h + 'px';
    t.style.overflowY = t.scrollHeight > max ? 'auto' : 'hidden';
  }

  function formValues(f) {
    const v = (n) => f.elements[n].value.trim();
    const list = (n) => v(n).split(/[\n,]/).map((s) => s.trim()).filter(Boolean).join(', ');
    return {
      name: v('name'),
      kv: {
        enabled: f.elements.enabled.checked ? 'true' : 'false', local: v('local'), remote: v('remote'), host: v('host'),
        port: v('port') === '22' ? '' : v('port'), user: v('user'), key_file: v('key_file'),
        delete: f.elements.delete.checked ? 'true' : 'false', exclude: list('exclude'), include: list('include'),
        remote_owner: v('remote_owner'), extra: v('extra'),
      },
    };
  }

  function bindEditor(orig) {
    const f = $('form.editor');
    if (!f) return;
    const err = (msg) => { $('#ed-err').innerHTML = msg ? `<div class="errbox">${esc(msg)}</div>` : ''; };
    f.querySelectorAll('textarea').forEach((t) => { autoGrow(t); t.addEventListener('input', () => autoGrow(t)); });
    f.elements.delete.addEventListener('change', (e) => { $('#ed-delwarn').style.display = e.target.checked ? 'block' : 'none'; });
    f.querySelectorAll('[data-pick]').forEach((b) => b.addEventListener('click', async () => {
      const folder = b.dataset.pick === 'folder';
      const r = await call(folder ? 'chooseFolder' : 'chooseFile', { start: f.elements.local.value });
      if (r.path) f.elements[folder ? 'local' : 'key_file'].value = r.path;
    }));
    f.querySelectorAll('[data-ed]').forEach((b) => b.addEventListener('click', async () => {
      const act = b.dataset.ed;
      if (act === 'back') { go(MODE === 'window' ? 'projects' : 'rules'); return; }
      if (act === 'test') {
        b.disabled = true; b.textContent = '测试中…';
        let r = await cli(['test', orig.name], 30);
        if (r.code === 4) {
          // 首次连接新服务器：取回指纹让用户核对，确认后才写入 known_hosts，再重测一次
          const fr = await cli(['trust-host', orig.name, '--json'], 30);
          let d = null;
          try { d = JSON.parse(fr.out || ''); } catch (e) { /* ignore */ }
          if (d && d.fingerprints && d.fingerprints.length) {
            const list = d.fingerprints.map((x) => `${x.type}  ${x.fp}`).join('\n');
            if (confirm(`首次连接 ${d.host}:${d.port}，请核对服务器指纹\n可请服务器管理员在服务器上执行 ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub 对照：\n\n${list}\n\n确认无误并信任这台服务器？`)) {
              const w = await cli(['trust-host', orig.name, '--yes'].concat(d.fingerprints.map((x) => x.fp)), 30);
              if (w.code !== 0) { b.disabled = false; b.textContent = '测试连接'; err(outMsg(w)); return; }
              r = await cli(['test', orig.name], 30);
            }
          } else {
            r = fr;
          }
        }
        b.disabled = false; b.textContent = '测试连接';
        if (r.code === 0) { err(''); toast(outMsg(r)); } else err(outMsg(r));
        return;
      }
      if (act === 'remove') {
        if (!confirm(`删除项目「${orig.name}」？只删除配置，不会删除本地或远端文件。`)) return;
        const r = await cli(['rule-rm', orig.name]);
        if (r.code === 0) { toast('已删除'); call('refresh'); go('projects'); } else err(outMsg(r));
        return;
      }
      const { name, kv } = formValues(f);
      if (!name) { err('请填写名称'); return; }
      if (kv.delete === 'true' && !(orig && orig.delete)) {
        if (!confirm('确认开启"同步删除远端文件"？\n本地删除的文件会在远端直接删除，不可恢复。')) return;
      }
      const pairs = Object.keys(kv).map((k) => k + '=' + kv[k]);
      b.disabled = true;
      let r;
      if (!orig) {
        r = await cli(['rule-add', name].concat(pairs.filter((p) => !/=$/.test(p))));
      } else {
        r = { code: 0 };
        if (name !== orig.name) r = await cli(['rule-rename', orig.name, name]);
        if (r.code === 0) r = await cli(['rule-set', name].concat(pairs));
      }
      b.disabled = false;
      if (r.code === 0) {
        err(''); toast('已保存，守护进程会自动应用'); call('refresh');
        if (!orig || name !== orig.name) go('project:' + name);
      } else err(outMsg(r));
    }));
  }

  // ---------------- 日志 ----------------
  const OPS = { U: ['↑', '上传'], G: ['↓', '下载'], D: ['✕', '远端删除'], S: ['⤼', '跳过'] };
  const opIcon = (op) => `<span class="op op-${op}" title="${(OPS[op] || ['', ''])[1]}">${(OPS[op] || ['·'])[0]}</span>`;
  const HIST_MAX = 1000, FIRST = 15, STEP = 50, HIST_STEP = 50;
  const openRuns = {};      // 已展开的记录：run_id → 当前显示的文件条数
  const runCache = {};      // run_id → { files, total, error_output }；清单写完就不再变化，可以缓存
  let histItems = null, histSig = '', histShown = FIRST;   // 日志列表默认只画 15 条，滚动再追加
  (params.get('expand') || '').split(',').filter(Boolean).forEach((id) => { openRuns[id] = FIRST; });   // 调试：预先展开

  // run_id 里有小数点，不能拼进 CSS 选择器（#files-1.2.3 会被当成类名而报错），一律用 getElementById
  const filesEl = (id) => document.getElementById('files-' + id);
  const histRow = (id) => { const el = filesEl(id); return el ? el.closest('.hist') : null; };
  const noChange = (h) => h.result === 'ok' && !h.files && !h.deleted && !(h.skipped || []).length;

  async function loadHistory() {
    const r = await cli(['history', String(HIST_MAX)]);
    if (route !== 'history') return;
    let items = [];
    try { items = JSON.parse(r.out || '[]'); } catch (e) { /* ignore */ }
    items = items.filter((x) => !x.dry_run && !noChange(x)).reverse().slice(0, HIST_MAX);
    const sig = items.map((h) => h.run_id + ':' + h.result).join(',');
    if (sig === histSig) return;
    histSig = sig;
    histItems = items;
    renderHistory();
  }

  function histRowHTML(h) {
    const sample = (h.sample || []).map((x) => x.split('\t'));
    const failed = h.result === 'failed';
    const one = !failed && sample.length === 1 && (h.files || 0) + (h.deleted || 0) + (h.skipped || []).length <= 1;
    const more = failed || (!one && sample.length > 0);
    const detail = one ? `${opIcon(sample[0][0])}<span class="fname">${esc(sample[0][1])}</span>` : esc(h.summary);
    const id = esc(h.run_id || '');
    return `<div class="hist${more ? ' more' : ''}${openRuns[h.run_id] != null ? ' open' : ''}" data-run="${id}">
      <div class="hrow">
        <span class="t" data-ts="${h.finished_at || 0}">${ago(h.finished_at)}</span>
        <span class="s${failed ? ' bad' : ''}"><b>${esc(h.rule)}</b> · ${TRIG[h.trigger] || h.trigger} · ${detail}${more ? '<span class="caret">›</span>' : ''}</span>
        <span class="d">${h.duration_s}s</span>
      </div>
      <div class="files" id="files-${id}"></div>
    </div>`;
  }

  function renderHistory() {
    const box = $('#hist');
    if (!box || !histItems) return;
    box.innerHTML = histItems.length ? histItems.slice(0, histShown).map(histRowHTML).join('') : '<div class="empty">暂无同步记录</div>';
    Object.keys(openRuns).forEach((id) => { if (filesEl(id)) fillRun(id); else delete openRuns[id]; });
    fillHist();
  }

  // 往列表尾部追加下一批记录（不重画已有行，保留滚动和展开状态）
  function appendHistory(n) {
    const box = $('#hist');
    if (!box || !histItems || histShown >= histItems.length) return false;
    const next = histItems.slice(histShown, histShown + n);
    histShown += next.length;
    box.insertAdjacentHTML('beforeend', next.map(histRowHTML).join(''));
    Object.keys(openRuns).forEach((id) => { if (filesEl(id)) fillRun(id); });
    return true;
  }

  // 窗口较高、首屏 15 条填不满时继续加载，直到填满或取完 1000 条
  function fillHist() {
    const m = $('#main');
    while (route === 'history' && m && m.scrollHeight <= m.clientHeight + 1) {
      if (!appendHistory(HIST_STEP)) break;
    }
  }

  document.addEventListener('scroll', (e) => {
    if (route !== 'history' || e.target.id !== 'main') return;
    const m = e.target;
    if (m.scrollTop + m.clientHeight >= m.scrollHeight - 200) appendHistory(HIST_STEP);
  }, true);

  // 只改时间文字，不重画列表：不打断滚动、展开状态和文字选择
  function updateTimes() {
    document.querySelectorAll('#hist [data-ts]').forEach((el) => {
      const v = ago(+el.dataset.ts);
      if (el.textContent !== v) el.textContent = v;
    });
  }

  async function fetchRunFiles(id, limit, offset) {
    const r = await cli(['run-files', id, String(limit), String(offset)]);
    try { return JSON.parse(r.out || '{}'); } catch (e) { return {}; }
  }

  // 保证缓存里至少有当前要显示的条数（首次取 15 条，"查看更多"每次再取 50 条）
  async function ensureRun(id) {
    const want = openRuns[id] || FIRST;
    let c = runCache[id];
    if (!c) {
      const d = await fetchRunFiles(id, want, 0);
      c = runCache[id] = { files: d.files || [], total: d.total || 0, error_output: d.error_output || '' };
    }
    while (c.files.length < Math.min(want, c.total)) {
      const d = await fetchRunFiles(id, want - c.files.length, c.files.length);
      if (!d.files || !d.files.length) break;
      c.files = c.files.concat(d.files);
    }
    return c;
  }

  function runFilesHTML(id) {
    const c = runCache[id];
    if (!c) return '<div class="fl sub">加载中…</div>';
    const shown = c.files.slice(0, openRuns[id] || FIRST);
    let html = c.error_output ? `<pre class="errout">${esc(c.error_output)}</pre>` : '';
    html += shown.map((f) => `<div class="fl">${opIcon(f.op)}<span class="fname">${esc(f.path)}</span></div>`).join('');
    if (!shown.length && !c.error_output) html = '<div class="fl sub">没有保存文件清单</div>';
    const rest = c.total - shown.length;
    html += `<div class="fbar">${rest > 0 ? `<button class="link" data-more="${esc(id)}">查看更多（还剩 ${rest} 个）</button>` : ''}`
      + `<button class="link" data-fold="${esc(id)}">收起</button></div>`;
    return html;
  }

  async function fillRun(id) {
    if (!runCache[id]) { const el = filesEl(id); if (el) el.innerHTML = runFilesHTML(id); }
    await ensureRun(id);
    const el = filesEl(id);
    if (el && openRuns[id] != null) el.innerHTML = runFilesHTML(id);
  }

  function toggleRun(id, open) {
    const row = histRow(id);
    if (!row) return;
    if (open === undefined) open = openRuns[id] == null;
    if (open) {
      openRuns[id] = FIRST;
      row.classList.add('open');
      fillRun(id);
      return;
    }
    delete openRuns[id];
    row.classList.remove('open');
    filesEl(id).innerHTML = '';
    // 从长列表底部"收起"时，标题可能已经滚出视野：滚回这一行
    const m = $('#main');
    if (m && row.getBoundingClientRect().top < m.getBoundingClientRect().top) row.scrollIntoView({ block: 'start' });
  }

  function showMore(id) {
    openRuns[id] = (openRuns[id] || FIRST) + STEP;
    fillRun(id);
  }

  // ---------------- 设置 ----------------
  function settingsHTML() {
    const st = S.settings || {}, g = S.global || {};
    const ignore = String(g.watch_ignore || '').split(/\s+/).filter(Boolean).join('\n');
    const corner = st.overlayCorner === 'bottomLeft' ? 'bottomLeft' : 'bottomRight';
    return `<div class="section">通用</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>开机自动启动</b><div class="desc">登录 Mac 后自动运行 FolderSync 和后台同步；关闭后需要手动打开 FolderSync 才会同步</div></div>
        <label class="toggle"><input type="checkbox" id="st-autostart" ${S.autostart !== false ? 'checked' : ''}><span></span></label></div>
    </div>
    <div class="section">浮动状态条</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>显示浮动状态条</b><div class="desc">同步时在屏幕角落显示进度，鼠标悬停可停止或跳过</div></div>
        <label class="toggle"><input type="checkbox" id="st-en" data-auto ${st.overlayEnabled !== false ? 'checked' : ''}><span></span></label></div>
      <div class="srow"><div class="lbl"><b>自动推送时的显示时机</b><div class="desc">推送持续超过这个时间才出现；手动全量同步、上传、下载会立即出现</div></div>
        <div class="unit"><input type="number" id="st-delay" data-auto min="0" step="0.5" value="${st.overlayDelay != null ? st.overlayDelay : 2}"><span>秒</span></div></div>
      <div class="srow"><div class="lbl"><b>位置</b><div class="desc">也可以直接拖动状态条，位置会被记住</div></div>
        <div class="seg" id="st-corner"><button data-corner="bottomLeft" class="${corner === 'bottomLeft' ? 'on' : ''}">左下角</button><button data-corner="bottomRight" class="${corner === 'bottomRight' ? 'on' : ''}">右下角</button></div></div>
    </div>
    <div class="section">同步</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>改动去抖</b><div class="desc">文件改动后等待多久再推送，用来合并连续保存</div></div>
        <div class="unit"><input type="number" id="g-debounce" min="0.1" step="0.1" value="${esc(g.debounce || '1')}"><span>秒</span></div></div>
      <div class="srow col"><div class="lbl"><b>不监听的目录名</b><div class="desc">每行一个，所有项目通用；这些目录里的改动不会触发推送（项目自己的"排除"另行设置）</div></div>
        <textarea id="g-ignore" spellcheck="false">${esc(ignore)}</textarea></div>
      <div class="srow end"><span class="desc" id="g-hint">修改后点保存，守护进程会自动应用</span><button class="btn primary" data-a="save-sync">保存</button></div>
    </div>
    <div class="section">配置备份</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>导出配置</b><div class="desc">把所有项目和本页设置存成一个文件，系统重装后用来恢复；不含 SSH 私钥</div></div>
        <button class="btn" data-a="export-config">导出…</button></div>
      <div class="srow"><div class="lbl"><b>导入配置</b><div class="desc">只补进本机没有的项目，同名项目保留本机配置；导入前自动备份当前配置</div></div>
        <button class="btn" data-a="import-config">导入…</button></div>
    </div>
    <div class="section">后台服务</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>守护进程</b><div class="desc" id="svc-line">—</div></div>
        <button class="btn" data-sys="reload">—</button></div>
      <div class="srow"><div class="lbl"><b>配置文件</b><div class="desc mono">${esc(home(S.config || ''))}</div></div>
        <button class="btn" data-sys="config">打开</button></div>
      <div class="srow"><div class="lbl"><b>日志</b><div class="desc">同步记录与错误输出</div></div>
        <button class="btn" data-sys="log">打开</button></div>
      <div class="srow"><div class="lbl"><b>卸载 FolderSync</b><div class="desc">停止后台同步，删除开机启动项和命令行工具，并把应用移到废纸篓；配置和同步记录会保留</div></div>
        <button class="btn danger" data-sys="uninstall">卸载…</button></div>
    </div>
    <div class="section">关于</div>
    <div class="group">
      <div class="srow"><div class="lbl"><b>FolderSync v${esc(S.version || '—')}</b><div class="desc" id="upd-line">${esc(updStatus(S.update || {}))}</div></div>
        <span id="upd-box"><button class="btn" data-a="check-update">检查更新</button></span></div>
    </div>`;
  }

  // ---------------- 首次安装引导（缺少依赖、或直接从 DMG 里打开时显示） ----------------
  async function loadSetup() {
    const box = $('#setup');
    const d = await call('doctor');
    if (!box || route !== 'setup') return;
    box.innerHTML = setupHTML(d);
  }

  function setupHTML(d) {
    if (!d || d.error) return `<div class="errbox">${esc((d && d.error) || '无法检查运行环境')}</div>`;
    const item = (ok, title, desc) => `<div class="srow"><div class="lbl"><b>${ok ? '✓' : '✗'} ${title}</b><div class="desc">${desc}</div></div></div>`;
    let html = '<div class="section">运行环境</div><div class="group">';
    if (d.app_location_ok === false) {
      html += item(false, '请先把 FolderSync 拖到"应用程序"文件夹', '现在是直接从安装盘（DMG）里打开的。拖到"应用程序"后再从那里打开，才能开机启动、使用 Finder 右键菜单。');
      return html + '</div>';
    }
    html += item(d.rsync && d.rsync.ok, 'GNU rsync 3.1+', d.rsync && d.rsync.ok ? esc(d.rsync.version) : '系统自带的 openrsync 不支持实时进度和同步删除');
    html += item(!!d.fswatch, 'fswatch', d.fswatch ? esc(d.fswatch) : '用于监听本地文件改动，保存后立即推送');
    html += '</div>';
    if (d.ok) {
      return html + '<div class="section">安装</div><div class="group"><div class="srow end"><span class="desc">环境已就绪</span><button class="btn primary" data-a="setup-install">完成安装</button></div></div>';
    }
    html += '<div class="section">安装缺少的组件</div><div class="group">';
    let n = 1;
    if (!d.brew) {
      html += `<div class="srow"><div class="lbl"><b>${n++}. 安装 Homebrew</b><div class="desc">打开 brew.sh，把首页的安装命令粘贴到"终端"里执行</div></div><button class="btn" data-a="open-brew">打开 brew.sh</button></div>`;
    }
    html += `<div class="srow"><div class="lbl"><b>${n}. 在"终端"里执行</b><div class="desc mono">${esc(d.install_cmd)}</div></div><button class="btn" data-copy="${esc(d.install_cmd)}">复制命令</button></div>`;
    html += '<div class="srow end"><span class="desc">装好后点"重新检测"</span><button class="btn primary" data-a="recheck">重新检测</button></div></div>';
    return html;
  }

  async function setupInstall(btn) {
    if (btn) { btn.disabled = true; btn.textContent = '安装中…'; }
    const r = await call('setupInstall');
    if (btn) { btn.disabled = false; btn.textContent = '完成安装'; }
    if (r.code === 0) { toast('安装完成，可以开始添加项目了'); call('refresh'); go(rules().length ? 'projects' : 'new'); }
    else toast(outMsg(r) || '安装失败');
  }

  function bindSettings() {
    const t = $('#g-ignore');
    if (t) { autoGrow(t); t.addEventListener('input', () => autoGrow(t)); }
    const as = $('#st-autostart');
    if (as) as.addEventListener('change', async () => {
      const r = await cli(['autostart', as.checked ? 'on' : 'off']);
      if (r.code === 0) { toast(as.checked ? '已开启开机自动启动' : '已关闭开机自动启动（本次登录内同步不受影响）'); call('refresh'); }
      else { as.checked = !as.checked; toast(outMsg(r)); }
    });
    document.querySelectorAll('[data-auto]').forEach((el) => el.addEventListener('change', saveOverlay));
    document.querySelectorAll('[data-corner]').forEach((b) => b.addEventListener('click', () => {
      document.querySelectorAll('[data-corner]').forEach((x) => x.classList.toggle('on', x === b));
      call('previewOverlay', { corner: b.dataset.corner });   // 在目标位置显示 2 秒状态条预览
      saveOverlay(true);
    }));
  }

  // 状态条设置属于应用本身：改了立即生效
  async function saveOverlay(silent) {
    const on = $('[data-corner].on');
    await call('settings', { value: {
      overlayEnabled: $('#st-en').checked, overlayDelay: Math.max(0, parseFloat($('#st-delay').value) || 0),
      overlayCorner: on ? on.dataset.corner : 'bottomRight' } });
    if (!silent) toast('已保存');
  }

  // ---------------- 配置备份（导出 / 导入） ----------------
  async function exportConfig(btn) {
    if (btn) btn.disabled = true;
    const r = await call('exportConfig');
    if (btn) btn.disabled = false;
    if (!r || r.cancelled) return;
    if (r.code !== 0) { toast(r.err || '导出失败'); return; }
    toast('已导出到 ' + home(r.path || ''));
  }

  // 先取预览，用户确认后才写入；同名项目保留本机配置，导入前命令行会自动备份
  async function importConfig(btn) {
    if (btn) btn.disabled = true;
    const r = await call('importConfig');
    if (btn) btn.disabled = false;
    if (!r || r.cancelled) return;
    if (r.code !== 0) { toast(r.err || '导入失败'); return; }
    const p = r.preview || {};
    if (!p.ok) { toast(p.error || '这个文件不是 FolderSync 的配置备份'); return; }
    const added = p.added || [], skipped = p.skipped || [];
    const lines = [`备份里有 ${p.imported} 个项目`, added.length ? `新增 ${added.length} 个：${added.join('、')}` : '没有需要新增的项目'];
    if (skipped.length) lines.push(`${skipped.length} 个同名项目保留本机配置：${skipped.join('、')}`);
    if (p.settings) lines.push('本页的应用设置也会按备份恢复');
    if (!confirm(`导入配置？\n${lines.join('\n')}\n\n导入前会自动备份当前配置。`)) return;
    const out = await cli(['import', r.path, '--json']);
    if (out.code !== 0) { toast(outMsg(out)); return; }
    let res = {};
    try { res = JSON.parse(out.out); } catch (e) { res = {}; }
    if (p.settings) await call('settings', { value: p.settings });
    if (typeof p.autostart === 'boolean' && p.autostart !== S.autostart) {
      await cli(['autostart', p.autostart ? 'on' : 'off']);
    }
    keys.settingsReady = false;   // 下次状态推送时按新配置重画设置页
    call('refresh');
    toast(`已导入 ${(res.added || []).length} 个新项目${res.backup ? '，原配置已备份' : ''}`);
  }

  // 点击更新：从 GitHub 下载新版本、覆盖安装，应用随后自动重启
  async function installUpdate(btn) {
    const u = S.update || {};
    if (u.installable === false) {
      call('openURL', { url: 'https://github.com/terranc/folder-sync/releases/latest' });
      toast('当前不是「应用程序」里的安装版，已打开下载页面');
      return;
    }
    if (btn) btn.disabled = true;
    const r = await call('update', { action: 'install' });
    if (r && r.state === 'failed') { toast(r.message || '更新失败'); verKey = ''; renderVersion(); }
  }



  async function saveSync() {
    const g = S.global || {}, kv = [];
    const deb = $('#g-debounce').value.trim();
    const ign = $('#g-ignore').value.split(/[\s,]+/).filter(Boolean).join(' ');
    if (deb !== String(g.debounce || '')) kv.push('debounce=' + deb);
    if (ign !== String(g.watch_ignore || '').split(/\s+/).filter(Boolean).join(' ')) kv.push('watch_ignore=' + ign);
    if (!kv.length) { toast('没有改动'); return; }
    const r = await cli(['global-set'].concat(kv));
    if (r.code !== 0) { toast(outMsg(r)); return; }
    call('refresh');
    toast('已保存，守护进程会自动应用');
  }

  // ---------------- 事件 ----------------
  document.addEventListener('click', async (e) => {
    const more = e.target.closest('[data-more]');
    if (more) { showMore(more.dataset.more); return; }
    const fold = e.target.closest('[data-fold]');
    if (fold) { toggleRun(fold.dataset.fold, false); return; }
    const hrow = e.target.closest('.hist.more > .hrow');
    if (hrow) { toggleRun(hrow.parentNode.dataset.run); return; }
    const t = e.target.closest('button, [data-act]');
    if (!t || t.dataset.corner) return;
    if (t.dataset.go) { go(t.dataset.go); return; }
    const a = t.dataset.a;
    if (a === 'refresh') { call('refresh'); delete keys.hist; toast('已刷新'); return; }
    if (a === 'check-update') { await call('update', { action: 'check' }); verKey = ''; renderVersion(); return; }
    if (a === 'update') { await installUpdate(t); return; }
    if (a === 'expand') { call('expand', { route: route === 'rules' ? 'projects' : route }); return; }
    if (a === 'settings') { if (MODE === 'popover') call('expand', { route: 'settings' }); else go('settings'); return; }
    if (a === 'quit') { call('quit'); return; }
    if (a === 'new') { if (MODE === 'popover') call('expand', { route: 'new' }); else go('new'); return; }
    if (a === 'save-sync') { saveSync(); return; }
    if (a === 'export-config') { exportConfig(t); return; }
    if (a === 'import-config') { importConfig(t); return; }
    if (a === 'recheck') { $('#setup').innerHTML = '<div class="empty">正在检查运行环境…</div>'; loadSetup(); return; }
    if (a === 'setup-install') { setupInstall(t); return; }
    if (a === 'open-brew') { call('openURL', { url: 'https://brew.sh/zh-cn/' }); return; }
    if (t.dataset.copy) { await call('copyText', { text: t.dataset.copy }); toast('已复制，粘贴到"终端"执行'); return; }
    if (t.dataset.sys) {
      const s = t.dataset.sys;
      if (s === 'reload') {
        t.disabled = true; t.textContent = '处理中…';
        const r = await cli(S.daemon_running ? ['reload'] : ['start'], 90);
        t.disabled = false; toast(r.code === 0 ? '已完成' : outMsg(r)); update();
      }
      if (s === 'config') call('openFile', { path: S.config });
      if (s === 'log') call('openLog');
      if (s === 'uninstall') call('uninstall');
      return;
    }
    const card = t.closest('[data-rule]');
    if (!card || !t.dataset.act) return;
    const name = card.dataset.rule, rule = ruleBy(name) || {};
    switch (t.dataset.act) {
      case 'full': call('spawn', { args: ['sync', name, '--bg'] }); toast(`「${name}」开始全量同步`); break;
      case 'cancel': cli(['cancel', name]).then(() => toast('已停止')); break;
      case 'skip': cli(['skip', name]).then(() => toast('已跳过当前文件')); break;
      case 'retry': await cli(['ack', name]); call('spawn', { args: ['sync', name, '--bg'] }); toast('正在重试'); break;
      case 'ack': cli(['ack', name]); break;
      case 'reveal': call('reveal', { path: rule.local }); break;
      case 'toggle': {
        const r = await cli(['rule-set', name, 'enabled=' + (rule.enabled ? 'false' : 'true')]);
        if (r.code === 0) { toast(rule.enabled ? `已停用「${name}」` : `已启用「${name}」`); call('refresh'); } else toast(outMsg(r));
        break;
      }
      case 'copy': copyFrom = JSON.parse(JSON.stringify(rule)); route = 'new'; Object.keys(keys).forEach((k) => delete keys[k]); renderPage(); update(); break;
      case 'edit': if (MODE === 'popover') call('expand', { route: 'project:' + name }); else go('project:' + name); break;
    }
  });

  // ---------------- 浏览器调试用模拟 ----------------
  const Mock = {
    t0: Date.now() / 1000,
    state() {
      const now = Date.now() / 1000, el = now - this.t0;
      return {
        daemon_running: true, autostart: true, now, config: '/Users/me/.config/folder-sync/config.conf', rsync: '/opt/homebrew/bin/rsync',
        version: '2.4.0', update: { state: params.get('update') === 'new' ? 'available' : 'latest', version: '2.4.1', current: '2.4.0', progress: 0, message: '', installable: params.get('update') !== 'local' },
        global: { debounce: '0.5', watch_ignore: '.git node_modules .idea .DS_Store' }, settings: this._settings || { overlayDelay: 2, overlayCorner: 'bottomRight', overlayEnabled: true },
        rules: [
          { name: 'pinme', enabled: true, valid: true, delete: false, local: '/Users/me/www/PinMe/meal.server', remote: '/data/www/pinme', host: 'pinme.example.com', user: 'deploy', port: '22', key_file: '', include: [], exclude: ['.git/**', 'runtime/**', 'vendor/**', 'storage/logs/**'], extra: '', remote_owner: '',
            run: { phase: 'transferring', trigger: 'full', percent: Math.min(99, Math.floor(el * 7) % 100), files_done: 132 + Math.floor(el), deleted: 0, speed_bps: 4404019, eta_s: 20, checked: 2140, check_total: 3150, current_file: 'public/assets/app.3f9c.js', current_started_at: now - 7, started_at: now - 30 }, last: null },
          { name: 'youxiang', enabled: true, valid: true, delete: true, local: '/Users/me/www/youxiang', remote: '/var/www/youxiang', host: 'yx.example.com', user: 'root', port: '22', key_file: '~/.ssh/id_ed25519', include: [], exclude: ['.git/**'], extra: '', remote_owner: 'www:www',
            run: null, last: { run_id: 'a', result: 'failed', acked: false, error: 'SSH 连接中断（退出码 255）', finished_at: now - 120, trigger: 'change', summary: '失败' } },
          { name: 'blog', enabled: false, valid: true, delete: false, local: '/Users/me/www/blog', remote: '/srv/blog', host: 'blog.example.com', user: 'me', port: '22', key_file: '', include: [], exclude: [], extra: '', remote_owner: '',
            run: null, last: { run_id: 'b', result: 'ok', acked: true, summary: '同步 3 个文件', finished_at: now - 4000, trigger: 'change' } },
        ],
      };
    },
    tick() { window.__fsState(this.state()); },
    handle(msg) {
      let res = { code: 0, out: '', err: '' };
      const now = Date.now() / 1000;
      if (msg.cmd === 'run' && msg.args[0] === 'history') {
        // CLI 按时间从旧到新输出
        const many = +params.get('many') || 0;
        res.out = JSON.stringify(many ? Array.from({ length: many }, (_, i) => ({
          run_id: 'x' + i, rule: 'pinme', trigger: 'change', result: 'ok', files: 1, deleted: 0, skipped: [], summary: '同步 1 个文件',
          sample: ['U\tsrc/F' + i + '.php'], finished_at: now - 1000 + i, duration_s: 1,
        })) : [
          { run_id: 'm4', rule: 'pinme', trigger: 'change', result: 'ok', files: 0, deleted: 0, skipped: [], summary: '无变化', sample: [], finished_at: now - 400, duration_s: 0 },
          { run_id: 'm3', rule: 'youxiang', trigger: 'full', result: 'failed', files: 0, deleted: 0, skipped: [], summary: '失败：SSH 连接中断（退出码 255）', sample: [], finished_at: now - 300, duration_s: 92 },
          { run_id: 'm1', rule: 'pinme', trigger: 'change', result: 'ok', files: 1, deleted: 0, skipped: [], summary: '同步 1 个文件', sample: ['U\tsrc/Controller/OrderController.php'], finished_at: now - 60, duration_s: 1 },
          { run_id: 'm2', rule: 'merchant.server', trigger: 'change', result: 'ok', files: 46, deleted: 0, skipped: [], summary: '同步 46 个文件', sample: ['U\tcommon/components/payment/File01.php', 'U\tcommon/components/payment/File02.php', 'U\tcommon/components/payment/File03.php'], finished_at: now - 30, duration_s: 1 },
        ]);
      }
      if (msg.cmd === 'run' && msg.args[0] === 'run-files') {
        const id = msg.args[1], lim = +msg.args[2] || 2000, off = +msg.args[3] || 0;
        const total = id === 'm2' ? 46 : 0, files = [];
        for (let i = off; i < Math.min(total, off + lim); i++) files.push({ op: 'U', path: `common/components/payment/File${String(i + 1).padStart(2, '0')}.php` });
        res.out = JSON.stringify({ run_id: id, total, offset: off, files, error_output: id === 'm3' ? 'client_loop: send disconnect: Broken pipe\nrsync error: unexplained error (code 255) at io.c(232) [sender=3.4.1]' : '' });
        this.calls = (this.calls || []).concat([msg.args.join(' ')]);
      }
      if (msg.cmd === 'doctor') {
        res = params.get('mock') === 'setup'
          ? { ok: false, missing: 'rsync fswatch', install_cmd: 'brew install rsync fswatch', rsync: { ok: false, path: '/usr/bin/rsync', version: 'openrsync: protocol version 29' }, fswatch: '', brew: '/opt/homebrew/bin/brew', app_location_ok: true }
          : { ok: true, missing: '', install_cmd: '', rsync: { ok: true, version: 'rsync  version 3.5.1' }, fswatch: '/opt/homebrew/bin/fswatch', brew: '/opt/homebrew/bin/brew', app_location_ok: true };
      }
      if (msg.cmd === 'exportConfig') {
        this.calls = (this.calls || []).concat(['exportConfig']);
        res = { code: 0, path: '/Users/me/Downloads/folder-sync-config.json' };
      }
      if (msg.cmd === 'importConfig') {
        this.calls = (this.calls || []).concat(['importConfig']);
        res = { code: 0, path: '/Users/me/Downloads/folder-sync-config.json', preview: {
          ok: true, mode: 'merge', imported: 2, added: ['blog'], skipped: ['pinme'],
          settings: { overlayEnabled: true, overlayDelay: 3, overlayCorner: 'bottomLeft' }, autostart: true } };
      }
      if (msg.cmd === 'run' && msg.args[0] === 'import') {
        this.calls = (this.calls || []).concat([msg.args.join(' ')]);
        res.out = JSON.stringify({ ok: true, added: ['blog'], skipped: ['pinme'], backup: '/Users/me/.config/folder-sync/config.conf.bak.20260101-120000' });
      }
      if (msg.cmd === 'settings') {
        if (msg.value) this._settings = Object.assign({}, this.state().settings, msg.value);
        res = this.state().settings;
      }
      if (msg.cmd === 'update') {
        this.calls = (this.calls || []).concat(['update ' + (msg.action || 'check')]);
        const u = Object.assign({}, this.state().update);
        if (msg.action === 'install') { u.state = 'downloading'; u.progress = 0.12; }
        res = u;
      }
      if (msg.cmd === 'previewOverlay') this.calls = (this.calls || []).concat(['previewOverlay ' + msg.corner]);
      setTimeout(() => window.__fsReply(msg.id, res), 30);
    },
  };
  window.__fsMock = Mock;   // 供 UI 测试检查调用记录

  // ---------------- 启动 ----------------
  shell();
  if (params.get('route')) route = params.get('route');
  if (native) call('state').then((s) => { if (s && s.rules) S = s; renderPage(); update(); });
  else { S = Mock.state(); renderPage(); update(); setInterval(() => Mock.tick(), 500); }
})();
