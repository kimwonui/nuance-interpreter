// The concept film: a short silent loop in the hero (poster first, video only after the page has loaded),
// and the full 44-second film with its original music in a dialog. Nothing plays with sound until someone
// presses "Watch the film"; the full film isn't downloaded before that.
(function () {
  const params = new URLSearchParams(location.search);
  const reduce = params.has("reduced") || matchMedia("(prefers-reduced-motion: reduce)").matches;
  const conn = navigator.connection || {};
  const saveData = !!conn.saveData || /(^|-)2g$/.test(conn.effectiveType || "");
  const small = () => innerWidth <= 600 || saveData;
  const $ = (s, r) => (r || document).querySelector(s);

  // ---------------------------------------------------------------- Hero loop
  const frame = $(".hf-frame");
  const loop = $(".hf-loop");
  const pauseBtn = $(".hf-pause");
  let inView = true, userPaused = false, filmOpen = false, loaded = false;

  function wantPlay() { return loaded && inView && !userPaused && !filmOpen && !document.hidden; }
  function sync() {
    if (!loaded) return;
    if (wantPlay()) { const p = loop.play(); if (p) p.catch(() => {}); }
    else loop.pause();
  }
  function setPauseLabel() {
    pauseBtn.classList.toggle("paused", userPaused);
    pauseBtn.setAttribute("aria-label", userPaused ? "Play the background video" : "Pause the background video");
  }
  function loadLoop() {
    if (loaded || reduce || saveData) return;
    loaded = true;
    loop.src = small() ? loop.dataset.srcSm : loop.dataset.srcLg;
    loop.addEventListener("playing", () => frame.classList.add("playing"), { once: true });
    pauseBtn.hidden = false;
    sync();
  }
  if (loop) {
    if (window.IntersectionObserver) {
      new IntersectionObserver((e) => { inView = e[0].isIntersecting; sync(); }, { threshold: 0.15 }).observe(frame);
    }
    document.addEventListener("visibilitychange", sync);
    pauseBtn.addEventListener("click", () => { userPaused = !userPaused; setPauseLabel(); sync(); });
    // Poster first: start fetching the loop only once everything else has loaded.
    const later = () => (window.requestIdleCallback ? requestIdleCallback(loadLoop, { timeout: 1500 }) : setTimeout(loadLoop, 300));
    if (document.readyState === "complete") later(); else addEventListener("load", later, { once: true });
  }

  // ---------------------------------------------------------------- Full film
  const dialog = $("#film");
  const film = $("video", dialog);
  let opener = null, restore = true;

  function source() { return small() || innerWidth < 1100 ? film.dataset.srcSm : film.dataset.srcLg; }
  function open(e) {
    opener = e.currentTarget;
    if (!film.getAttribute("src")) {
      film.poster = film.dataset.poster;
      film.src = source();
    }
    if (!dialog.showModal) { location.href = film.src; return; } // very old browsers: open the file itself
    filmOpen = true;
    sync();
    dialog.showModal();
    if (film.ended) film.currentTime = 0;
    if (reduce) film.focus(); // reduced motion: open paused, the viewer presses play
    else { const p = film.play(); if (p) p.catch(() => film.focus()); }
  }
  function close() { if (dialog.open) dialog.close(); }

  document.querySelectorAll("[data-film-open]").forEach((b) => b.addEventListener("click", open));
  $(".fd-close", dialog).addEventListener("click", close);
  $("[data-film-close]", dialog).addEventListener("click", () => { restore = false; close(); }); // then the link scrolls to the demo
  dialog.addEventListener("click", (e) => { if (e.target === dialog) close(); }); // backdrop
  dialog.addEventListener("close", () => {
    film.pause();
    filmOpen = false;
    sync();
    if (restore && opener) {
      // The play button on the hero video is mouse-only; hand keyboard focus to the main button instead.
      const target = opener.getAttribute("aria-hidden") === "true" ? $(".hero-copy [data-film-open]") : opener;
      if (target) target.focus({ preventScroll: true });
    }
    restore = true;
  });
})();
