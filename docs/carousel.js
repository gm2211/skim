(function () {
  const track = document.getElementById('track');
  const slides = Array.from(track.children);
  const dotsEl = document.getElementById('dots');
  const prevBtn = document.getElementById('prev');
  const nextBtn = document.getElementById('next');
  const playBtn = document.getElementById('playpause');
  const AUTOPLAY_MS = 5000;

  let index = 0;
  let autoplayTimer = null;
  let playing = true;

  // Build dots
  slides.forEach((_, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('role', 'tab');
    b.setAttribute('aria-label', `Slide ${i + 1}`);
    b.addEventListener('click', () => go(i, true));
    dotsEl.appendChild(b);
  });
  const dots = Array.from(dotsEl.children);

  function measure() {
    const slideEl = slides[0];
    const style = getComputedStyle(track);
    const gap = parseFloat(style.columnGap || style.gap || '0');
    return slideEl.getBoundingClientRect().width + gap;
  }

  function render() {
    const step = measure();
    const trackWidth = track.parentElement.clientWidth;
    const slideWidth = slides[0].getBoundingClientRect().width;
    // Center active slide in viewport
    const offset = (trackWidth - slideWidth) / 2 - step * index;
    track.style.transform = `translateX(${offset}px)`;
    slides.forEach((s, i) => s.classList.toggle('is-active', i === index));
    dots.forEach((d, i) => d.classList.toggle('is-active', i === index));
  }

  function go(i, user) {
    index = (i + slides.length) % slides.length;
    render();
    if (user) restartAutoplay();
  }

  function next(user) { go(index + 1, user); }
  function prev(user) { go(index - 1, user); }

  function startAutoplay() {
    stopAutoplay();
    autoplayTimer = setInterval(() => next(false), AUTOPLAY_MS);
  }
  function stopAutoplay() {
    if (autoplayTimer) clearInterval(autoplayTimer);
    autoplayTimer = null;
  }
  function restartAutoplay() {
    if (playing) startAutoplay();
  }

  prevBtn.addEventListener('click', () => prev(true));
  nextBtn.addEventListener('click', () => next(true));
  playBtn.addEventListener('click', () => {
    playing = !playing;
    playBtn.classList.toggle('paused', !playing);
    playBtn.setAttribute('aria-label', playing ? 'Pause' : 'Play');
    if (playing) startAutoplay(); else stopAutoplay();
  });

  // Keyboard
  document.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight') next(true);
    else if (e.key === 'ArrowLeft') prev(true);
  });

  // Swipe
  let touchStartX = null;
  track.addEventListener('touchstart', (e) => { touchStartX = e.touches[0].clientX; }, { passive: true });
  track.addEventListener('touchend', (e) => {
    if (touchStartX == null) return;
    const dx = e.changedTouches[0].clientX - touchStartX;
    if (Math.abs(dx) > 48) (dx < 0 ? next : prev)(true);
    touchStartX = null;
  });

  // Pause on hover
  const highlights = document.querySelector('.highlights');
  highlights.addEventListener('mouseenter', stopAutoplay);
  highlights.addEventListener('mouseleave', restartAutoplay);

  // Pause when tab hidden
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopAutoplay();
    else restartAutoplay();
  });

  window.addEventListener('resize', render);

  // Start — ensure images measured
  const imgs = slides.map(s => s.querySelector('img')).filter(Boolean);
  Promise.all(imgs.map(img => img.complete ? Promise.resolve() : new Promise(res => {
    img.addEventListener('load', res);
    img.addEventListener('error', res);
  }))).then(() => {
    render();
    startAutoplay();
  });
})();
