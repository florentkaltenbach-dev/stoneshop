/**
 * Variant Switcher
 * Enables instant theme switching without page reload
 */
(function() {
  'use strict';

  const VARIANTS = ['v0', 'v1', 'v2', 'v3', 'v4', 'v5'];
  const VARIANT_NAMES = {
    'v0': 'Cinzel + Crimson',
    'v1': 'Cinzel + Garamond',
    'v2': 'Cinzel + Cormorant',
    'v3': 'Decorative + Spectral',
    'v4': 'Cinzel Bold + Source',
    'v5': 'Cinzel Light + Lora'
  };

  /**
   * Get current variant from body class
   */
  function getCurrentVariant() {
    for (const v of VARIANTS) {
      if (document.body.classList.contains('variant-' + v)) {
        return v;
      }
    }
    return 'v0';
  }

  /**
   * Switch to a new variant instantly
   */
  function switchVariant(newVariant) {
    if (!VARIANTS.includes(newVariant)) return;

    const currentVariant = getCurrentVariant();
    if (currentVariant === newVariant) return;

    // Update URL and reload so PHP-rendered variant content changes
    const url = new URL(window.location);
    url.searchParams.set('variant', newVariant);
    window.location.href = url.toString();
  }

  /**
   * Update admin bar dropdown selection indicator
   */
  function updateAdminBarDropdown(newVariant) {
    // Update parent menu text
    const parentLink = document.querySelector('#wp-admin-bar-smg-variant > a');
    if (parentLink) {
      parentLink.textContent = 'Variant: ' + newVariant;
    }

    // Update submenu item indicators
    VARIANTS.forEach(v => {
      const item = document.querySelector('#wp-admin-bar-smg-variant-' + v + ' > a');
      if (item) {
        const isActive = v === newVariant;
        const label = VARIANT_NAMES[v] || v;
        item.textContent = (isActive ? '● ' : '○ ') + v + ' - ' + label;
      }
    });
  }

  /**
   * Update all links on page to preserve variant parameter
   */
  function updatePageLinks(newVariant) {
    const links = document.querySelectorAll('a[href]');
    const currentHost = window.location.host;

    links.forEach(link => {
      try {
        const url = new URL(link.href);

        // Only update internal links
        if (url.host !== currentHost) return;

        // Skip admin links
        if (url.pathname.includes('/wp-admin')) return;

        // Skip logout/login links
        if (url.pathname.includes('wp-login')) return;

        if (newVariant === 'v0') {
          url.searchParams.delete('variant');
        } else {
          url.searchParams.set('variant', newVariant);
        }
        link.href = url.toString();
      } catch (e) {
        // Invalid URL, skip
      }
    });
  }

  /**
   * Initialize variant switcher
   */
  function init() {
    // Intercept admin bar variant menu clicks
    document.addEventListener('click', function(e) {
      const link = e.target.closest('a');
      if (!link) return;

      // Check if it's a variant switcher link
      const href = link.getAttribute('href');
      if (!href) return;

      try {
        const url = new URL(href, window.location.origin);
        const variant = url.searchParams.get('variant');

        // Check if this is an admin bar variant link
        if (link.closest('#wp-admin-bar-smg-variant') && variant) {
          e.preventDefault();
          switchVariant(variant);
        }
      } catch (e) {
        // Invalid URL, ignore
      }
    });

    // Add keyboard shortcut for quick switching (Alt + 0-5)
    document.addEventListener('keydown', function(e) {
      if (!e.altKey) return;

      const num = parseInt(e.key);
      if (num >= 0 && num <= 5) {
        e.preventDefault();
        switchVariant('v' + num);
      }
    });

    // Create floating variant switcher for easier testing
    createFloatingSwitcher();
  }

  /**
   * Create a floating variant switcher panel
   */
  function createFloatingSwitcher() {
    // Only show for logged-in users (check for admin bar)
    if (!document.body.classList.contains('logged-in')) return;

    const switcher = document.createElement('div');
    switcher.id = 'smg-variant-switcher';
    switcher.innerHTML = `
      <style>
        #smg-variant-switcher {
          position: fixed;
          bottom: 20px;
          left: 20px;
          background: rgba(0,0,0,0.9);
          color: #fff;
          padding: 12px;
          border-radius: 8px;
          font-family: system-ui, sans-serif;
          font-size: 12px;
          z-index: 99999;
          box-shadow: 0 4px 20px rgba(0,0,0,0.3);
        }
        #smg-variant-switcher .title {
          font-weight: 600;
          margin-bottom: 8px;
          font-size: 11px;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          opacity: 0.7;
        }
        #smg-variant-switcher .variants {
          display: flex;
          gap: 6px;
          flex-wrap: wrap;
          max-width: 200px;
        }
        #smg-variant-switcher button {
          padding: 6px 10px;
          border: 1px solid rgba(255,255,255,0.3);
          background: transparent;
          color: #fff;
          border-radius: 4px;
          cursor: pointer;
          font-size: 11px;
          font-family: inherit;
          transition: all 0.15s;
        }
        #smg-variant-switcher button:hover {
          background: rgba(255,255,255,0.1);
          border-color: rgba(255,255,255,0.5);
        }
        #smg-variant-switcher button.active {
          background: #fff;
          color: #000;
          border-color: #fff;
        }
        #smg-variant-switcher .hint {
          margin-top: 8px;
          font-size: 10px;
          opacity: 0.5;
        }
        #smg-variant-switcher .close {
          position: absolute;
          top: 4px;
          right: 8px;
          background: none;
          border: none;
          color: rgba(255,255,255,0.5);
          cursor: pointer;
          font-size: 16px;
          padding: 4px;
        }
        #smg-variant-switcher .close:hover {
          color: #fff;
        }
      </style>
      <button class="close" title="Close (will reappear on reload)">&times;</button>
      <div class="title">Theme Variant</div>
      <div class="variants">
        ${VARIANTS.map(v => `<button data-variant="${v}" title="${VARIANT_NAMES[v]}">${v}</button>`).join('')}
      </div>
      <div class="hint">Alt+0-5 to switch</div>
    `;

    document.body.appendChild(switcher);

    // Update active state
    function updateActiveButton() {
      const current = getCurrentVariant();
      switcher.querySelectorAll('button[data-variant]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.variant === current);
      });
    }
    updateActiveButton();

    // Handle clicks
    switcher.addEventListener('click', function(e) {
      const btn = e.target.closest('button[data-variant]');
      if (btn) {
        switchVariant(btn.dataset.variant);
        updateActiveButton();
      }

      if (e.target.classList.contains('close')) {
        switcher.remove();
      }
    });
  }

  // Initialize when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
