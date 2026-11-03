#!/usr/bin/env node
// 界面端到端测试：用 Chrome 无头模式打开 app/web/index.html 的模拟数据模式，逐项点击验证交互。
// 通过 --remote-debugging-pipe 与 Chrome 通信（不开端口），不会影响本机的 FolderSync。
// 运行：node tests/ui-e2e.js    需要 Google Chrome；截图输出到 $UI_SHOTS（默认系统临时目录）
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!fs.existsSync(CHROME)) { console.log('# 未找到 Google Chrome，跳过界面测试'); process.exit(0); }
const PAGE = 'file://' + path.resolve(__dirname, '../app/web/index.html');
const SHOTS = process.env.UI_SHOTS || fs.mkdtempSync(path.join(os.tmpdir(), 'fs-ui-shots-'));
fs.mkdirSync(SHOTS, { recursive: true });
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'fs-ui-profile-'));

const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--hide-scrollbars', '--remote-debugging-pipe', '--user-data-dir=' + profile, 'about:blank'],
  { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
const toChrome = chrome.stdio[3];
const fromChrome = chrome.stdio[4];
let seq = 0;
const waiting = new Map();
let buf = '';
fromChrome.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\0')) >= 0) {
    const msg = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    const w = msg.id && waiting.get(msg.id);
    if (w) { waiting.delete(msg.id); if (msg.error) w.reject(new Error(msg.error.message)); else w.resolve(msg.result); }
  }
});
function send(method, params, sessionId) {
  const id = ++seq;
  toChrome.write(JSON.stringify({ id, method, params: params || {}, sessionId }) + '\0');
  return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let passed = 0, failed = 0;
function check(name, ok, detail) {
  if (ok) { passed++; console.log('ok - ' + name); }
  else { failed++; console.log('not ok - ' + name + (detail !== undefined ? '  → ' + JSON.stringify(detail) : '')); }
}

async function openPage(query, width, height) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const S = (m, p) => send(m, p, sessionId);
  await S('Page.enable');
  await S('Runtime.enable');
  await S('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: false });
  await S('Page.navigate', { url: PAGE + query });
  await sleep(1200);
  const ev = async (expr) => {
    const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error((r.exceptionDetails.exception || {}).description || r.exceptionDetails.text);
    return r.result.value;
  };
  const shot = async (name) => {
    const { data } = await S('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOTS, name + '.png'), Buffer.from(data, 'base64'));
  };
  return { ev, shot };
}

(async () => {
  // ---------------- 日志页（大窗口） ----------------
  const w = await openPage('?mode=window&route=history', 1000, 900);
  const rows = await w.ev(`[...document.querySelectorAll('#hist .hist')].map(r => r.dataset.run)`);
  check('无变化的记录不显示', !rows.includes('m4'), rows);
  check('记录按时间从新到旧', rows.join(',') === 'm2,m1,m3', rows);
  check('只有一个文件的记录直接显示文件名、不可展开',
    await w.ev(`(() => { const r = document.querySelector('.hist[data-run="m1"]'); return !r.classList.contains('more') && r.querySelector('.hrow .fname').textContent; })()`) === 'src/Controller/OrderController.php');

  const count = `document.querySelectorAll('.hist[data-run="m2"] .files .fl').length`;
  const moreText = `(document.querySelector('.hist[data-run="m2"] [data-more]') || {}).textContent || ''`;
  const isOpen = `document.querySelector('.hist[data-run="m2"]').classList.contains('open')`;
  const filesVisible = `getComputedStyle(document.getElementById('files-m2')).display !== 'none'`;

  await w.ev(`document.querySelector('.hist[data-run="m2"] .hrow').click()`); await sleep(300);
  check('点击标题展开，默认显示 15 个文件', await w.ev(isOpen) && await w.ev(count) === 15, await w.ev(count));
  check('显示"查看更多（还剩 31 个）"', (await w.ev(moreText)).includes('还剩 31 个'), await w.ev(moreText));
  await w.shot('logs-expanded');

  await sleep(1300);   // 期间模拟的状态推送每 0.5 秒一次
  check('状态推送不会收起或重画已展开的记录', await w.ev(isOpen) && await w.ev(count) === 15);

  await w.ev(`document.querySelector('.hist[data-run="m2"] [data-more]').click()`); await sleep(300);
  check('"查看更多"再加载一批（最多 50 个，这里剩 31 个全部加载）', await w.ev(count) === 46, await w.ev(count));
  check('全部加载后不再显示"查看更多"', (await w.ev(moreText)) === '');
  const calls = await w.ev(`window.__fsMock.calls.filter(c => c.startsWith('run-files m2'))`);
  check('分批读取：先取 15 条，再从第 15 条起取 31 条', JSON.stringify(calls) === JSON.stringify(['run-files m2 15 0', 'run-files m2 50 15']), calls);

  await w.ev(`document.querySelector('.hist[data-run="m2"] [data-fold]').click()`); await sleep(200);
  check('底部"收起"可以收起', !(await w.ev(isOpen)) && !(await w.ev(filesVisible)));

  await w.ev(`document.querySelector('.hist[data-run="m2"] .hrow').click()`); await sleep(200);
  check('再次展开回到 15 个（不重复请求）', await w.ev(count) === 15 && (await w.ev(`window.__fsMock.calls.length`)) === 2);
  await w.ev(`document.querySelector('.hist[data-run="m2"] .hrow').click()`); await sleep(200);
  check('再点一次标题可以收起', !(await w.ev(isOpen)) && !(await w.ev(filesVisible)));

  await w.ev(`document.querySelector('.hist[data-run="m3"] .hrow').click()`); await sleep(300);
  check('失败记录展开后显示错误输出', (await w.ev(`document.querySelector('.hist[data-run="m3"] .errout').textContent`)).includes('Broken pipe'));
  await w.shot('logs-failed');

  // ---------------- 日志列表：默认 15 条 + 滚动加载 ----------------
  const h = await openPage('?mode=window&route=history&many=1200', 600, 500);
  const rowCount = `document.querySelectorAll('#hist .hist').length`;
  check('日志列表默认只渲染 15 条', await h.ev(rowCount) === 15, await h.ev(rowCount));
  check('日志按时间从新到旧', await h.ev(`document.querySelector('#hist .hist').dataset.run`) === 'x1199');
  await h.ev(`document.getElementById('main').scrollTop = document.getElementById('main').scrollHeight`); await sleep(300);
  check('滚动到底部追加下一批（+50）', await h.ev(rowCount) === 65, await h.ev(rowCount));
  for (let i = 0; i < 24; i++) {
    await h.ev(`(() => { const m = document.getElementById('main'); m.scrollTop = m.scrollHeight; })()`);
    await sleep(120);
  }
  check('滚动加载最多到 1000 条', await h.ev(rowCount) === 1000, await h.ev(rowCount));
  await h.shot('logs-loaded');

  // ---------------- 设置页 ----------------
  const s = await openPage('?mode=window&route=settings', 1000, 1400);
  check('设置页有"开机自动启动"开关且默认开启', await s.ev(`!!document.getElementById('st-autostart') && document.getElementById('st-autostart').checked`));
  check('设置页有"卸载 FolderSync"', await s.ev(`!!document.querySelector('[data-sys="uninstall"]')`));

  // ---------------- 设置页：导出 / 导入配置 ----------------
  check('设置页有导出、导入配置入口', await s.ev(`!!document.querySelector('[data-a="export-config"]') && !!document.querySelector('[data-a="import-config"]')`));
  await s.ev(`document.querySelector('[data-a="export-config"]').click()`); await sleep(200);
  check('导出配置走原生保存面板', /exportConfig/.test(await s.ev(`(window.__fsMock.calls || []).join(' ')`)));
  await s.ev(`window.confirm = () => true; document.querySelector('[data-a="import-config"]').click()`); await sleep(900);
  const icalls = await s.ev(`(window.__fsMock.calls || []).filter(c => c === 'importConfig' || c.indexOf('import ') === 0)`);
  check('导入先取预览、确认后才写入，并恢复应用设置', icalls.length === 2 && icalls[1].indexOf('--json') > 0, icalls);
  check('导入后按备份恢复浮动状态条设置', (await s.ev(`(document.getElementById('st-delay') || {}).value`)) === '3');
  await s.shot('settings');

  // ---------------- 安装引导（缺少依赖） ----------------
  const g = await openPage('?mode=window&route=setup&mock=setup', 1000, 800);
  check('缺少依赖时显示安装命令', (await g.ev(`document.querySelector('#setup [data-copy]').dataset.copy`)) === 'brew install rsync fswatch');
  await g.shot('setup');

  // ---------------- 浮层 ----------------
  const p = await openPage('?mode=popover', 460, 640);
  check('浮层只有"项目""日志"两个标签', (await p.ev(`[...document.querySelectorAll('.tabs [data-go]')].map(b => b.textContent).join(',')`)) === '项目,日志');
  check('浮层卡片没有"复制"按钮', await p.ev(`!document.querySelector('[data-act="copy"]')`));
  check('浮层底部显示当前版本号', (await p.ev(`(document.querySelector('#verline .ver') || {}).textContent`)) === 'v2.4.0');
  check('没有新版本时不显示更新按钮', await p.ev(`!document.querySelector('#verline .upd')`));
  await p.shot('popover-version');

  // 有新版本：底部出现高亮更新按钮，点击调用安装
  const pu = await openPage('?mode=popover&update=new', 460, 640);
  check('有新版本时显示更新按钮', (await pu.ev(`(document.querySelector('#verline .upd') || {}).textContent`)) === '更新到 2.4.1');
  check('更新按钮在小窗底部靠右、位于"退出"左侧', await pu.ev(`(() => {
    const up = document.querySelector('#verline .upd'), quit = document.querySelector('[data-a="quit"]').getBoundingClientRect();
    if (!up) return false;
    const r = up.getBoundingClientRect();
    return r.right <= quit.left && r.top > 400;
  })()`));
  await pu.ev(`document.querySelector('#verline .upd').click()`);
  check('点击更新后请求下载安装', (await pu.ev(`(window.__fsMock.calls || []).filter(c => c.startsWith('update ')).join(',')`)) === 'update install');
  await pu.shot('popover-update');

  // ---------------- 设置页：版本号 / 检查更新 / 位置预览 ----------------
  const s2 = await openPage('?mode=window&route=settings&update=new', 1000, 1400);
  check('设置页不再有"跳过"按钮出现时机', await s2.ev(`!document.getElementById('st-skip')`));
  check('设置页"关于"显示版本号', (await s2.ev(`[...document.querySelectorAll('.srow b')].map(b => b.textContent).find(t => t.startsWith('FolderSync v'))`)) === 'FolderSync v2.4.0');
  check('设置页有检查更新入口', await s2.ev(`!!document.querySelector('[data-a="check-update"]') || !!document.querySelector('[data-a="update"]')`));
  await s2.ev(`document.querySelector('[data-corner="bottomLeft"]').click()`);
  await sleep(120);
  check('切换位置时请求状态条预览', /previewOverlay bottomLeft/.test(await s2.ev(`(window.__fsMock.calls || []).join(' ')`)));
  await s2.shot('settings-about');
})()
  .catch((e) => { failed++; console.log('not ok - 测试异常: ' + e.message); })
  .finally(() => {
    console.log(`\n${passed} passed, ${failed} failed   截图: ${SHOTS}`);
    chrome.kill();
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) { /* ignore */ }
    process.exit(failed ? 1 : 0);
  });
