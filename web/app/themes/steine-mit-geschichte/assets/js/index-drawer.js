(() => {
  const drawer = document.querySelector('.index-drawer');
  if (!drawer) return;

  const panel = drawer.querySelector('.index-drawer__panel');
  const toggle = document.querySelector('[data-index-drawer-toggle]');
  const closeButtons = drawer.querySelectorAll('[data-index-drawer-close]');
  const focusableSelector = 'a, button, input, textarea, select, [tabindex]:not([tabindex="-1"])';
  let lastFocused = null;

  const setOpenState = (isOpen) => {
    drawer.setAttribute('aria-hidden', String(!isOpen));
    if (toggle) toggle.setAttribute('aria-expanded', String(isOpen));
    document.body.classList.toggle('index-drawer-open', isOpen);
  };

  const openDrawer = () => {
    lastFocused = document.activeElement;
    setOpenState(true);
    const focusable = panel.querySelectorAll(focusableSelector);
    if (focusable.length) {
      focusable[0].focus();
    }
  };

  const closeDrawer = () => {
    setOpenState(false);
    if (lastFocused && typeof lastFocused.focus === 'function') {
      lastFocused.focus();
    }
  };

  toggle?.addEventListener('click', () => {
    const isOpen = document.body.classList.contains('index-drawer-open');
    if (isOpen) {
      closeDrawer();
    } else {
      openDrawer();
    }
  });

  closeButtons.forEach((btn) => {
    btn.addEventListener('click', closeDrawer);
  });

  document.addEventListener('keydown', (event) => {
    if (!document.body.classList.contains('index-drawer-open')) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      closeDrawer();
      return;
    }

    if (event.key !== 'Tab') return;
    const focusable = panel.querySelectorAll(focusableSelector);
    if (!focusable.length) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  // Start closed
  setOpenState(false);
})();
