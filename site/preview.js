(() => {
  const data = window.RICK_PREVIEW;
  if (!data) return;
  const sprite = document.getElementById('sprite');
  const speech = document.getElementById('speech');
  const status = document.getElementById('demo-status');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lines = ['Begin badly. Begin anyway.', 'Let it breathe.', 'The screen will wait. The sunset won’t.', 'Make room for the thing you haven’t noticed yet.', 'A little less can say a little more.', 'The work kept. So did you.'];
  let lineIndex = 0, animation = 'idle', frame = 0, lastFrame = 0;
  let timers = [], busy = false, workStep = 0;
  function pose(name) { animation = name; frame = 0; lastFrame = 0; draw(); }
  function draw() { sprite.src = data.images[data.animations[animation].frames[frame].file]; }
  function later(fn, milliseconds) { timers.push(setTimeout(fn, milliseconds)); }
  function reset() {
    timers.forEach(clearTimeout); timers = []; busy = false;
    document.getElementById('music').textContent = 'Play a record';
    document.getElementById('music').setAttribute('aria-pressed', 'false');
    document.getElementById('breath').textContent = 'Take a breath';
    document.getElementById('breath').setAttribute('aria-pressed', 'false');
    status.textContent = 'Just keeping you company.';
  }
  function speak(text) { speech.textContent = text; }
  function thought() { reset(); pose('nod'); speak(lines[lineIndex++ % lines.length]); }
  document.getElementById('rick').addEventListener('click', thought);
  document.getElementById('thought').addEventListener('click', thought);
  document.getElementById('tea').addEventListener('click', () => {
    reset(); busy = true; pose('tea'); speak('There’s time for this, too.');
    later(() => { busy = false; pose('idle'); }, 4500);
  });
  document.getElementById('breath').addEventListener('click', () => {
    const stopping = document.getElementById('breath').getAttribute('aria-pressed') === 'true';
    reset();
    if (stopping) { pose('idle'); speak('Here when you need me.'); return; }
    busy = true; pose('meditate');
    const button = document.getElementById('breath');
    button.textContent = 'End breath'; button.setAttribute('aria-pressed', 'true');
    status.textContent = 'One quiet minute. End whenever you like.';
    let at = 0;
    for (let i = 0; i < 4; i++) {
      for (const [text, length] of [['In…', 4000], ['Hold…', 4000], ['Out…', 6000]]) {
        later(() => speak(text), at); at += length;
      }
    }
    later(() => { reset(); pose('idle'); speak('A little space. That’s all.'); }, at);
  });
  // The app's own headphones: on with the music, a nod on every beat.
  document.getElementById('music').addEventListener('click', () => {
    const stopping = document.getElementById('music').getAttribute('aria-pressed') === 'true';
    reset();
    if (stopping) { pose('unphones'); speak('Listen for what isn’t there.'); return; }
    busy = true; pose('phones');
    const button = document.getElementById('music');
    button.textContent = 'Stop the record'; button.setAttribute('aria-pressed', 'true');
    status.textContent = 'Music playing · any app';
    speak('Listen without deciding.');
  });
  document.getElementById('work').addEventListener('click', () => {
    reset(); busy = true;
    const states = [['think', 'Claude is working', 'I’ll keep watch.'], ['look', 'Claude needs you · Permission requested', 'Your turn.'], ['nod', 'Ready for your review', 'The next choice is yours.']];
    const [name, label, line] = states[workStep++ % states.length];
    pose(name); status.textContent = 'Demo: ' + label; speak(line);
    document.getElementById('work').textContent = workStep % 3 === 0 ? 'Follow Claude' : 'Next agent state';
  });
  document.getElementById('zoom').addEventListener('click', (event) => {
    const on = document.querySelector('.desktop').classList.toggle('zoomed');
    event.currentTarget.setAttribute('aria-pressed', String(on));
    event.currentTarget.textContent = on ? 'Actual size −' : 'Look closer +';
    document.querySelector('.demo-caption span').textContent = on ? 'A closer look at the same pixel artwork.' : 'His actual default size. Click him. He has a thought.';
  });
  let hiddenAt = 0;
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) hiddenAt = Date.now();
    else { lastFrame = 0; if (Date.now() - hiddenAt > 1000 && busy) { reset(); pose('idle'); speak('Welcome back.'); } }
  });
  function animate(time) {
    if (!document.hidden && !reduced.matches) {
      const current = data.animations[animation];
      if (!lastFrame) lastFrame = time;
      if (time - lastFrame >= current.frames[frame].hold * 1000 / 30) {
        lastFrame = time; frame++;
        if (frame >= current.frames.length) {
          frame = 0;
          if (current.next) animation = current.next;
        }
        draw();
      }
    }
    requestAnimationFrame(animate);
  }
  requestAnimationFrame(animate);
  setInterval(() => {
    if (busy || document.hidden || reduced.matches || animation !== 'idle') return;
    pose(['tea', 'adjust', 'glance', 'glint'][Math.floor(Math.random() * 4)]);
    later(() => { if (!busy) pose('idle'); }, 4500);
  }, 15000);
  document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', async () => {
    const target = document.getElementById(button.dataset.copy);
    const feedback = document.getElementById('copy-status');
    try {
      await navigator.clipboard.writeText(target.textContent);
      button.textContent = 'Copied ✓'; feedback.textContent = 'Paste it into Terminal on your Mac.';
    } catch {
      const range = document.createRange(); range.selectNodeContents(target);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      feedback.textContent = 'Command selected. Press ⌘C to copy.';
    }
  }));
})();
