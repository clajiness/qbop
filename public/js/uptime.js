(() => {
  const counter = document.getElementById('app-uptime');
  if (!counter) return;

  const initialSeconds = Number(counter.dataset.uptimeSeconds);
  if (!Number.isFinite(initialSeconds) || initialSeconds < 0) return;

  const loadedAt = Date.now();

  function update() {
    // Elapsed wall time catches up after a throttled tab or sleeping computer.
    const elapsed = Math.max(0, Math.floor((Date.now() - loadedAt) / 1000));
    const total = initialSeconds + elapsed;
    const days = Math.floor(total / 86400);
    const hours = Math.floor(total / 3600) % 24;
    const minutes = Math.floor(total / 60) % 60;
    const seconds = total % 60;

    counter.textContent = `${days}d, ${hours}h, ${minutes}m, ${seconds}s`;
  }

  window.setInterval(update, 1000);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) update();
  });
  window.addEventListener('pageshow', update);
})();
