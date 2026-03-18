<?php
/**
 * Plugin Name: StoneShop SKU Auto-Generation
 * Description: Auto-generates SKU codes (category prefix + running number) for products.
 * Version: 1.0.0
 */

defined('ABSPATH') || exit;

if (!defined('STONESHOP_SKU_COUNTER_START')) {
    define('STONESHOP_SKU_COUNTER_START', 100);
}

if (!defined('STONESHOP_SKU_MAX_ATTEMPTS')) {
    define('STONESHOP_SKU_MAX_ATTEMPTS', 5000);
}

if (!function_exists('stoneshop_sku_counter_base')) {
    function stoneshop_sku_counter_base() {
        return (int) STONESHOP_SKU_COUNTER_START;
    }
}

if (!function_exists('stoneshop_sku_max_attempts')) {
    function stoneshop_sku_max_attempts() {
        return max(1, (int) STONESHOP_SKU_MAX_ATTEMPTS);
    }
}

if (!function_exists('stoneshop_sku_normalize_prefix')) {
    function stoneshop_sku_normalize_prefix($prefix) {
        $prefix = strtoupper(trim((string) $prefix));
        if ($prefix === '' || !preg_match('/^[A-Z]{1,4}$/', $prefix)) {
            return '';
        }
        return $prefix;
    }
}

if (!function_exists('stoneshop_sku_prefix_from_sku')) {
    function stoneshop_sku_prefix_from_sku($sku) {
        $sku = strtoupper(trim((string) $sku));
        if (preg_match('/^([A-Z]{1,4})\d+$/', $sku, $m)) {
            return $m[1];
        }
        return '';
    }
}

if (!function_exists('stoneshop_sku_product_prefixes')) {
    function stoneshop_sku_product_prefixes($post_id) {
        $terms = wp_get_post_terms($post_id, 'product_cat', ['fields' => 'ids']);
        if (is_wp_error($terms) || empty($terms)) {
            return [];
        }

        $terms = array_map('intval', $terms);
        sort($terms, SORT_NUMERIC);

        $prefixes = [];
        foreach ($terms as $tid) {
            $prefix = stoneshop_sku_normalize_prefix(get_term_meta($tid, '_sku_prefix', true));
            if ($prefix !== '') {
                $prefixes[$prefix] = true;
            }
        }

        return array_keys($prefixes);
    }
}

if (!function_exists('stoneshop_sku_request_prefix')) {
    function stoneshop_sku_request_prefix() {
        if (!isset($_POST['stoneshop_product_cat'])) {
            return '';
        }
        $term_id = absint($_POST['stoneshop_product_cat']);
        if ($term_id <= 0) {
            return '';
        }
        return stoneshop_sku_normalize_prefix(get_term_meta($term_id, '_sku_prefix', true));
    }
}

if (!function_exists('stoneshop_sku_pick_prefix_for_product')) {
    function stoneshop_sku_pick_prefix_for_product($post_id, $current_sku = '') {
        // Use explicit admin selection when available.
        $request_prefix = stoneshop_sku_request_prefix();
        if ($request_prefix !== '') {
            return $request_prefix;
        }

        $prefixes = stoneshop_sku_product_prefixes($post_id);
        if (empty($prefixes)) {
            return '';
        }

        // For legacy multi-category products, keep current prefix if still assigned.
        $current_prefix = stoneshop_sku_prefix_from_sku($current_sku);
        if ($current_prefix !== '' && in_array($current_prefix, $prefixes, true)) {
            return $current_prefix;
        }

        // Deterministic fallback.
        return $prefixes[0];
    }
}

if (!function_exists('stoneshop_sku_lock_name')) {
    function stoneshop_sku_lock_name($prefix) {
        $clean = preg_replace('/[^A-Z0-9_]/', '', strtoupper((string) $prefix));
        return 'stoneshop_sku_' . $clean;
    }
}

if (!function_exists('stoneshop_sku_acquire_lock')) {
    function stoneshop_sku_acquire_lock($prefix, $timeout = 5) {
        global $wpdb;
        $lock_name = stoneshop_sku_lock_name($prefix);
        $acquired = (int) $wpdb->get_var($wpdb->prepare(
            'SELECT GET_LOCK(%s, %d)',
            $lock_name,
            (int) $timeout
        ));
        return $acquired === 1;
    }
}

if (!function_exists('stoneshop_sku_release_lock')) {
    function stoneshop_sku_release_lock($prefix) {
        global $wpdb;
        $lock_name = stoneshop_sku_lock_name($prefix);
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_name));
    }
}

if (!function_exists('stoneshop_sku_exists_elsewhere')) {
    function stoneshop_sku_exists_elsewhere($sku, $exclude_post_id = 0) {
        global $wpdb;

        $exclude_post_id = (int) $exclude_post_id;
        if ($exclude_post_id > 0) {
            $sql = $wpdb->prepare(
                "SELECT 1
                 FROM {$wpdb->postmeta} pm
                 INNER JOIN {$wpdb->posts} p ON p.ID = pm.post_id
                 WHERE pm.meta_key = '_sku'
                   AND pm.meta_value = %s
                   AND p.post_type = 'product'
                   AND p.post_status NOT IN ('trash', 'auto-draft', 'inherit')
                   AND p.ID <> %d
                 LIMIT 1",
                $sku,
                $exclude_post_id
            );
        } else {
            $sql = $wpdb->prepare(
                "SELECT 1
                 FROM {$wpdb->postmeta} pm
                 INNER JOIN {$wpdb->posts} p ON p.ID = pm.post_id
                 WHERE pm.meta_key = '_sku'
                   AND pm.meta_value = %s
                   AND p.post_type = 'product'
                   AND p.post_status NOT IN ('trash', 'auto-draft', 'inherit')
                 LIMIT 1",
                $sku
            );
        }

        return (bool) $wpdb->get_var($sql);
    }
}

/* ==========================================================================
   2a. Category Prefix Admin Field
   ========================================================================== */

if (!function_exists('stoneshop_sku_registered_prefixes')) {
    function stoneshop_sku_registered_prefixes($exclude_term_id = 0) {
        $exclude_term_id = (int) $exclude_term_id;
        $terms = get_terms([
            'taxonomy'   => 'product_cat',
            'hide_empty' => false,
            'fields'     => 'ids',
        ]);

        if (is_wp_error($terms) || empty($terms)) {
            return [];
        }

        $prefixes = [];
        foreach ($terms as $term_id) {
            $term_id = (int) $term_id;
            if ($exclude_term_id > 0 && $term_id === $exclude_term_id) {
                continue;
            }
            $prefix = stoneshop_sku_normalize_prefix(get_term_meta($term_id, '_sku_prefix', true));
            if ($prefix !== '') {
                $prefixes[$prefix] = true;
            }
        }

        $prefixes = array_keys($prefixes);
        sort($prefixes, SORT_STRING);
        return $prefixes;
    }
}

if (!function_exists('stoneshop_sku_prefix_is_unique')) {
    function stoneshop_sku_prefix_is_unique($prefix, $exclude_term_id = 0) {
        $prefix = stoneshop_sku_normalize_prefix($prefix);
        if ($prefix === '') {
            return false;
        }
        return !in_array($prefix, stoneshop_sku_registered_prefixes($exclude_term_id), true);
    }
}

if (!function_exists('stoneshop_sku_prefix_notice_key')) {
    function stoneshop_sku_prefix_notice_key() {
        $user_id = get_current_user_id();
        if ($user_id <= 0) {
            return '';
        }
        return 'stoneshop_sku_prefix_notice_' . $user_id;
    }
}

if (!function_exists('stoneshop_sku_prefix_set_notice')) {
    function stoneshop_sku_prefix_set_notice($message) {
        $key = stoneshop_sku_prefix_notice_key();
        if ($key === '') {
            return;
        }
        set_transient($key, (string) $message, 120);
    }
}

add_action('admin_notices', function () {
    $screen = function_exists('get_current_screen') ? get_current_screen() : null;
    if (!$screen || $screen->taxonomy !== 'product_cat') {
        return;
    }

    $key = stoneshop_sku_prefix_notice_key();
    if ($key === '') {
        return;
    }
    $message = get_transient($key);
    if (!$message) {
        return;
    }
    delete_transient($key);

    echo '<div class="notice notice-error is-dismissible"><p>' . esc_html($message) . '</p></div>';
});

if (!function_exists('stoneshop_render_sku_prefix_validation_script')) {
    function stoneshop_render_sku_prefix_validation_script($used_prefixes, $required = false) {
        ?>
        <script>
            (function () {
                const input = document.getElementById('sku_prefix');
                const feedback = document.getElementById('stoneshop_sku_prefix_feedback');
                if (!input || !feedback) return;

                const form = input.form || input.closest('form');
                const submit = form ? form.querySelector('button[type="submit"], input[type="submit"]') : null;
                const used = new Set(<?php echo wp_json_encode(array_values($used_prefixes)); ?>);
                const isRequired = <?php echo $required ? 'true' : 'false'; ?>;

                function setState(type, message) {
                    feedback.textContent = message;
                    feedback.style.fontWeight = '600';

                    if (type === 'error') {
                        feedback.style.color = '#b32d2e';
                        input.setAttribute('aria-invalid', 'true');
                        if (submit) submit.disabled = true;
                        return;
                    }

                    input.removeAttribute('aria-invalid');
                    if (submit) submit.disabled = false;
                    feedback.style.color = type === 'ok' ? '#06752f' : '#555d66';
                }

                function validate() {
                    const value = (input.value || '').toUpperCase().trim();
                    if (input.value !== value) {
                        input.value = value;
                    }

                    if (!value) {
                        if (isRequired) {
                            setState('error', 'Bitte ein neues SKU-Präfix eingeben.');
                            return false;
                        }
                        setState('info', 'Leer lassen, um kein Präfix zu setzen.');
                        return true;
                    }

                    if (!/^[A-Z]{1,4}$/.test(value)) {
                        setState('error', 'Nur 1-4 Grossbuchstaben (A-Z) erlaubt.');
                        return false;
                    }

                    if (used.has(value)) {
                        setState('error', 'Dieses SKU-Präfix ist bereits vergeben. Bitte ein neues wählen.');
                        return false;
                    }

                    setState('ok', 'Präfix ist verfügbar.');
                    return true;
                }

                input.addEventListener('input', validate);
                input.addEventListener('change', validate);
                if (form) {
                    form.addEventListener('submit', function (event) {
                        if (!validate()) {
                            event.preventDefault();
                        }
                    });
                }

                validate();
            })();
        </script>
        <?php
    }
}

add_filter('pre_insert_term', function ($term, $taxonomy) {
    if ($taxonomy !== 'product_cat') {
        return $term;
    }
    if (!is_admin() || !isset($_POST['sku_prefix'])) {
        return $term;
    }

    $prefix = strtoupper(trim((string) wp_unslash($_POST['sku_prefix'])));
    if ($prefix === '') {
        return new WP_Error(
            'stoneshop_sku_prefix_required',
            __('Bitte ein neues, eindeutiges SKU-Präfix eingeben.', 'stoneshop')
        );
    }
    if (!preg_match('/^[A-Z]{1,4}$/', $prefix)) {
        return new WP_Error(
            'stoneshop_sku_prefix_invalid',
            __('SKU-Präfix muss aus 1-4 Grossbuchstaben bestehen.', 'stoneshop')
        );
    }
    if (!stoneshop_sku_prefix_is_unique($prefix, 0)) {
        return new WP_Error(
            'stoneshop_sku_prefix_duplicate',
            __('Dieses SKU-Präfix ist bereits vergeben. Bitte ein neues wählen.', 'stoneshop')
        );
    }

    return $term;
}, 10, 2);

/**
 * Add SKU prefix field to "Add Category" form
 */
add_action('product_cat_add_form_fields', function () {
    $used_prefixes = stoneshop_sku_registered_prefixes();
    ?>
    <div class="form-field term-sku-prefix-wrap stoneshop-sku-prefix-wrap">
        <label for="sku_prefix"><?php esc_html_e('SKU-Präfix', 'stoneshop'); ?></label>
        <input type="text" name="sku_prefix" id="sku_prefix" maxlength="4" style="width:80px;" required
               pattern="[A-Z]{1,4}" placeholder="z.B. NP" autocomplete="off">
        <p class="description"><?php esc_html_e('1-4 Grossbuchstaben. Nur neue, noch nicht vergebene Präfixe.', 'stoneshop'); ?></p>
        <p class="description" id="stoneshop_sku_prefix_feedback" aria-live="polite"></p>
        <?php if (!empty($used_prefixes)) : ?>
            <p class="description"><?php echo esc_html__('Bereits vergeben:', 'stoneshop') . ' ' . esc_html(implode(', ', $used_prefixes)); ?></p>
        <?php endif; ?>
    </div>
    <?php stoneshop_render_sku_prefix_validation_script($used_prefixes, true); ?>
    <?php
});

/**
 * Add SKU prefix field to "Edit Category" form
 */
add_action('product_cat_edit_form_fields', function ($term) {
    $prefix = stoneshop_sku_normalize_prefix(get_term_meta($term->term_id, '_sku_prefix', true));
    $used_prefixes = stoneshop_sku_registered_prefixes((int) $term->term_id);
    ?>
    <tr class="form-field term-sku-prefix-wrap stoneshop-sku-prefix-wrap">
        <th scope="row"><label for="sku_prefix"><?php esc_html_e('SKU-Präfix', 'stoneshop'); ?></label></th>
        <td>
            <input type="text" name="sku_prefix" id="sku_prefix" value="<?php echo esc_attr($prefix); ?>"
                   maxlength="4" style="width:80px;" pattern="[A-Z]{1,4}" autocomplete="off">
            <p class="description"><?php esc_html_e('1-4 Grossbuchstaben. Darf nicht bereits vergeben sein.', 'stoneshop'); ?></p>
            <p class="description" id="stoneshop_sku_prefix_feedback" aria-live="polite"></p>
            <?php if (!empty($used_prefixes)) : ?>
                <p class="description"><?php echo esc_html__('Bereits vergeben:', 'stoneshop') . ' ' . esc_html(implode(', ', $used_prefixes)); ?></p>
            <?php endif; ?>
        </td>
    </tr>
    <?php stoneshop_render_sku_prefix_validation_script($used_prefixes, false); ?>
    <?php
}, 5);

add_action('admin_head-edit-tags.php', function () {
    if (!is_admin()) {
        return;
    }

    $taxonomy = isset($_GET['taxonomy']) ? sanitize_key((string) $_GET['taxonomy']) : '';
    if ($taxonomy !== 'product_cat') {
        return;
    }
    ?>
    <style>
        /* Product category forms: keep only Name, Parent and SKU prefix. */
        #addtag .form-field:not(.term-name-wrap):not(.term-parent-wrap):not(.term-sku-prefix-wrap) {
            display: none !important;
        }
        #edittag tr.form-field:not(.term-name-wrap):not(.term-parent-wrap):not(.term-sku-prefix-wrap) {
            display: none !important;
        }
    </style>
    <?php
});

/**
 * Save prefix on category create/edit
 */
function stoneshop_save_sku_prefix($term_id) {
    if (!isset($_POST['sku_prefix'])) {
        return;
    }

    $prefix = strtoupper(trim((string) wp_unslash($_POST['sku_prefix'])));

    // Validate: 1-4 uppercase letters or empty
    if ($prefix !== '' && !preg_match('/^[A-Z]{1,4}$/', $prefix)) {
        stoneshop_sku_prefix_set_notice(__('SKU-Präfix muss aus 1-4 Grossbuchstaben bestehen.', 'stoneshop'));
        return;
    }

    // Uniqueness check
    if ($prefix !== '') {
        if (!stoneshop_sku_prefix_is_unique($prefix, (int) $term_id)) {
            stoneshop_sku_prefix_set_notice(__('Dieses SKU-Präfix ist bereits vergeben. Bitte ein neues wählen.', 'stoneshop'));
            return;
        }
    }

    update_term_meta($term_id, '_sku_prefix', $prefix);
}
add_action('created_product_cat', 'stoneshop_save_sku_prefix');
add_action('edited_product_cat', 'stoneshop_save_sku_prefix');

/**
 * Add prefix column to category list table
 */
add_filter('manage_edit-product_cat_columns', function ($columns) {
    $new = [];
    foreach ($columns as $key => $label) {
        $new[$key] = $label;
        if ($key === 'name') {
            $new['sku_prefix'] = __('SKU-Präfix', 'stoneshop');
        }
    }
    return $new;
});

add_filter('manage_product_cat_custom_column', function ($content, $column, $term_id) {
    if ($column === 'sku_prefix') {
        $prefix = get_term_meta($term_id, '_sku_prefix', true);
        return $prefix ? '<code>' . esc_html($prefix) . '</code>' : '—';
    }
    return $content;
}, 10, 3);

/* ==========================================================================
   2b. Auto-Generate SKU on Product Save
   ========================================================================== */

add_action('save_post_product', function ($post_id) {
    // Skip autosave, revision, no permission
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (wp_is_post_revision($post_id)) return;
    if (!current_user_can('edit_post', $post_id)) return;
    $post_status = get_post_status($post_id);
    if (in_array($post_status, ['trash', 'auto-draft', 'inherit'], true)) return;

    $current_sku = strtoupper(trim((string) get_post_meta($post_id, '_sku', true)));
    $prefix = stoneshop_sku_pick_prefix_for_product($post_id, $current_sku);
    if (!$prefix) return;

    // Keep valid unique SKU with matching prefix.
    if ($current_sku &&
        preg_match('/^' . preg_quote($prefix, '/') . '\d+$/', $current_sku) &&
        !stoneshop_sku_exists_elsewhere($current_sku, $post_id)
    ) {
        return;
    }

    $option_name = '_sku_counter_' . $prefix;
    $max_attempts = stoneshop_sku_max_attempts();
    if (!stoneshop_sku_acquire_lock($prefix, 5)) {
        error_log(sprintf(
            'StoneShop SKU generation failed for product %d (%s): lock timeout.',
            (int) $post_id,
            $prefix
        ));
        return;
    }

    try {
        if (get_option($option_name) === false) {
            add_option($option_name, stoneshop_sku_counter_base(), '', 'no');
        }

        $start_number = (int) get_option($option_name, stoneshop_sku_counter_base());
        if ($start_number < stoneshop_sku_counter_base()) {
            $start_number = stoneshop_sku_counter_base();
        }

        for ($attempt = 0; $attempt < $max_attempts; $attempt++) {
            $candidate_number = $start_number + $attempt + 1;
            if ($candidate_number <= stoneshop_sku_counter_base()) {
                continue;
            }
            $candidate_sku = $prefix . $candidate_number;
            if (!stoneshop_sku_exists_elsewhere($candidate_sku, $post_id)) {
                update_option($option_name, $candidate_number, 'no');
                update_post_meta($post_id, '_sku', $candidate_sku);
                return;
            }
        }

        error_log(sprintf(
            'StoneShop SKU generation failed for product %d (%s): exceeded %d attempts.',
            (int) $post_id,
            $prefix,
            $max_attempts
        ));
    } finally {
        stoneshop_sku_release_lock($prefix);
    }
}, 20);

/* ==========================================================================
   2c. SKU Display Meta Box
   ========================================================================== */

add_action('add_meta_boxes_product', function () {
    add_meta_box(
        'stoneshop_sku',
        __('Artikelnummer', 'stoneshop'),
        'stoneshop_sku_meta_box_render',
        'product',
        'side',
        'high'
    );
});

function stoneshop_sku_meta_box_render($post) {
    $sku = get_post_meta($post->ID, '_sku', true);

    if ($sku) {
        echo '<div style="font-size:24px;font-weight:700;letter-spacing:1px;padding:8px 0;">';
        echo esc_html($sku);
        echo '</div>';
    } else {
        // Detect prefix from assigned category
        $terms = wp_get_post_terms($post->ID, 'product_cat', ['fields' => 'ids']);
        $prefix = '';
        if (!is_wp_error($terms)) {
            foreach ($terms as $tid) {
                $p = get_term_meta($tid, '_sku_prefix', true);
                if ($p) {
                    $prefix = $p;
                    break;
                }
            }
        }
        if ($prefix) {
            $next_number = (int) get_option('_sku_counter_' . $prefix, stoneshop_sku_counter_base()) + 1;
            $next_sku = $prefix . $next_number;
            echo '<div style="color:#666;padding:8px 0;">';
            echo '<strong id="stoneshop_sku_preview">' . esc_html($next_sku) . ' — ';
            echo esc_html__('wird beim Speichern gesetzt', 'stoneshop') . '</strong>';
            echo '</div>';
        } else {
            echo '<div style="color:#999;padding:8px 0;">';
            echo '<span id="stoneshop_sku_preview">' .
                esc_html__('Kategorie mit SKU-Präfix auswählen, dann speichern.', 'stoneshop') .
                '</span>';
            echo '</div>';
        }
    }
}

/* ==========================================================================
   2d. WP-CLI Command for Backfill
   ========================================================================== */

if (defined('WP_CLI') && WP_CLI) {
    WP_CLI::add_command('stoneshop sku-init', function ($args, $assoc_args) {
        // Step 1: Discover prefixes from category term meta (dynamic, no static mapping)
        WP_CLI::log('--- Discovering SKU prefixes from categories ---');
        $terms = get_terms([
            'taxonomy'   => 'product_cat',
            'hide_empty' => false,
        ]);

        $registered_prefixes = [];
        $prefix_term = [];
        if (!is_wp_error($terms)) {
            foreach ($terms as $term) {
                $prefix = strtoupper(trim((string) get_term_meta($term->term_id, '_sku_prefix', true)));
                if ($prefix === '') {
                    continue;
                }
                if (!preg_match('/^[A-Z]{1,4}$/', $prefix)) {
                    WP_CLI::warning("  {$term->name} (ID {$term->term_id}) has invalid prefix '{$prefix}', ignored");
                    continue;
                }
                if (isset($prefix_term[$prefix]) && $prefix_term[$prefix] !== (int) $term->term_id) {
                    WP_CLI::warning("  Duplicate prefix '{$prefix}' on term IDs {$prefix_term[$prefix]} and {$term->term_id}");
                }
                $registered_prefixes[$prefix] = true;
                $prefix_term[$prefix] = (int) $term->term_id;
                WP_CLI::log("  {$term->name} (ID {$term->term_id}) -> {$prefix}");
            }
        }
        WP_CLI::success(count($registered_prefixes) . ' category prefixes discovered.');

        // Step 2: Scan products for existing SKU values; fallback to title pattern for missing SKU
        WP_CLI::log('');
        WP_CLI::log('--- Scanning products for SKU patterns ---');

        $products = get_posts([
            'post_type'      => 'product',
            'posts_per_page' => -1,
            'post_status'    => 'any',
        ]);

        $counters = [];   // prefix => max number
        $matched  = 0;
        $skipped  = 0;

        foreach ($products as $product) {
            $title = (string) $product->post_title;
            $current_sku = strtoupper(trim((string) get_post_meta($product->ID, '_sku', true)));

            if (preg_match('/^([A-Z]{1,4})(\d{1,})$/', $current_sku, $m)) {
                $found_prefix = $m[1];
                $found_number = (int) $m[2];
                $registered_prefixes[$found_prefix] = true;
                if (!isset($counters[$found_prefix]) || $found_number > $counters[$found_prefix]) {
                    $counters[$found_prefix] = $found_number;
                }
                $matched++;
                continue;
            }

            // Fallback: match pattern like "NP108" or "LLMP23" at end of title
            if (preg_match('/([A-Z]{1,4})(\d{1,})$/', $title, $m)) {
                $found_prefix = $m[1];
                $found_number = (int) $m[2];
                if (!isset($registered_prefixes[$found_prefix])) {
                    WP_CLI::warning("  #{$product->ID} \"{$title}\" — prefix {$found_prefix} is not registered on any category");
                    $skipped++;
                    continue;
                }
                $sku = $found_prefix . $found_number;
                update_post_meta($product->ID, '_sku', $sku);
                WP_CLI::log("  #{$product->ID} \"{$title}\" -> {$sku}");
                $matched++;
                if (!isset($counters[$found_prefix]) || $found_number > $counters[$found_prefix]) {
                    $counters[$found_prefix] = $found_number;
                }
                continue;
            }

            $skipped++;
        }

        WP_CLI::success("{$matched} products matched, {$skipped} skipped.");

        // Step 3: Initialize counters
        WP_CLI::log('');
        WP_CLI::log('--- Initializing SKU counters ---');

        // Ensure counters for all known prefixes (even if no products found)
        foreach (array_keys($registered_prefixes) as $prefix) {
            if (!isset($counters[$prefix])) {
                $counters[$prefix] = stoneshop_sku_counter_base();
            }
        }

        foreach ($counters as $prefix => $max) {
            $option_name = '_sku_counter_' . $prefix;
            update_option($option_name, $max, 'no');
            WP_CLI::log("  {$prefix}: counter set to {$max}");
        }

        WP_CLI::success('All counters initialized. New products will continue from these numbers.');
    });

    /**
     * Suggest (or apply) product tags based on keyword matching against
     * category names, material attributes, location attributes, and a
     * curated keyword list derived from the product catalog.
     *
     * ## OPTIONS
     *
     * [--apply]
     * : Actually create product_tag terms and assign them to products.
     *   Without this flag the command only prints suggestions.
     *
     * [--min-products=<num>]
     * : Only suggest tags that match at least this many products.
     * ---
     * default: 1
     * ---
     *
     * ## EXAMPLES
     *
     *     wp stoneshop tag-suggest
     *     wp stoneshop tag-suggest --apply
     *     wp stoneshop tag-suggest --min-products=2
     */
    WP_CLI::add_command('stoneshop tag-suggest', function ($args, $assoc_args) {
        $apply        = isset($assoc_args['apply']);
        $min_products = max(1, (int) ($assoc_args['min-products'] ?? 1));

        // ── 1. Build keyword dictionary ────────────────────────────────
        $keywords = []; // keyword (lowercase) => display label

        // Curated tag list from catalog analysis
        $curated = [
            // Material / Mineral
            'Lapislazuli', 'Rhyolith', 'Goldmarmor', 'Dolomit',
            'Schwarzenbach-Dolomit', 'Serpentin', 'Nolla-Pyrit',
            'Rheingoldschiefer', 'Tropfstein', 'Bergkristall',
            'Amethyst', 'Basalt', 'Onkolith', 'Schörl', 'Turmalin',
            'Achat', 'Opalholz', 'Stromatolith', 'Quarz',
            // Geological / Scientific
            'Fossil', 'Verkieseltes Holz',
            // Form / Shape
            'Platte', 'Dünnschliff-Platte', 'Scheibe', 'Kugel', 'Rohstein',
            // Object Type
            'Engel', 'Buddha', 'Marmorobst', 'Steinmörser',
            'Buchstützen', 'Zimmerbrunnen', 'Wanduhr', 'Steinlampe',
            'Weinständer', 'Schmuck',
            // Theme / Artist
            'Kunst', 'Peter Fraefel', 'Pflege',
        ];

        foreach ($curated as $label) {
            $keywords[mb_strtolower($label)] = $label;
        }

        // Also pull from product_cat term names (split compound names)
        $cat_terms = get_terms(['taxonomy' => 'product_cat', 'hide_empty' => false]);
        if (!is_wp_error($cat_terms)) {
            foreach ($cat_terms as $term) {
                $parts = preg_split('/\s*[-–—]\s*/', $term->name);
                foreach ($parts as $part) {
                    $part = trim($part);
                    if (mb_strlen($part) < 3) continue;
                    $key = mb_strtolower($part);
                    if (!isset($keywords[$key])) {
                        $keywords[$key] = $part;
                    }
                }
            }
        }

        // Pull from pa_material attribute terms
        $mat_terms = get_terms(['taxonomy' => 'pa_material', 'hide_empty' => false]);
        if (!is_wp_error($mat_terms) && is_array($mat_terms)) {
            foreach ($mat_terms as $term) {
                $key = mb_strtolower(trim($term->name));
                if (mb_strlen($key) >= 3 && !isset($keywords[$key])) {
                    $keywords[$key] = trim($term->name);
                }
            }
        }

        // Pull from pa_location attribute terms
        $loc_terms = get_terms(['taxonomy' => 'pa_location', 'hide_empty' => false]);
        if (!is_wp_error($loc_terms) && is_array($loc_terms)) {
            foreach ($loc_terms as $term) {
                $key = mb_strtolower(trim($term->name));
                if (mb_strlen($key) >= 3 && !isset($keywords[$key])) {
                    $keywords[$key] = trim($term->name);
                }
            }
        }

        WP_CLI::log(sprintf('Keyword dictionary: %d entries', count($keywords)));

        // ── 2. Match keywords against products ─────────────────────────
        $products = get_posts([
            'post_type'      => 'product',
            'posts_per_page' => -1,
            'post_status'    => 'publish',
        ]);

        WP_CLI::log(sprintf('Products to scan: %d', count($products)));

        $tag_products = [];   // keyword => [product IDs]
        $product_tags = [];   // product ID => [keywords]
        $unmatched    = [];

        foreach ($products as $post) {
            $haystack = mb_strtolower(
                $post->post_title . ' ' . wp_strip_all_tags($post->post_content)
            );

            $matched = [];
            foreach ($keywords as $key => $label) {
                if (mb_strpos($haystack, $key) !== false) {
                    $matched[] = $key;
                    $tag_products[$key][] = $post->ID;
                }
            }

            if (empty($matched)) {
                $unmatched[] = $post;
            } else {
                $product_tags[$post->ID] = $matched;
            }
        }

        // ── 3. Filter by min-products ──────────────────────────────────
        $filtered_tags = [];
        foreach ($tag_products as $key => $ids) {
            if (count($ids) >= $min_products) {
                $filtered_tags[$key] = $ids;
            }
        }

        // Sort by count descending
        uasort($filtered_tags, function ($a, $b) {
            return count($b) <=> count($a);
        });

        // ── 4. Output: Tag summary ─────────────────────────────────────
        WP_CLI::log('');
        WP_CLI::log('=== Tag Summary ===');

        $tag_table = [];
        foreach ($filtered_tags as $key => $ids) {
            $tag_table[] = [
                'Tag'      => $keywords[$key],
                'Keyword'  => $key,
                'Products' => count($ids),
            ];
        }
        WP_CLI\Utils\format_items('table', $tag_table, ['Tag', 'Keyword', 'Products']);

        // ── 5. Output: Per-product assignments ─────────────────────────
        WP_CLI::log('');
        WP_CLI::log('=== Per-Product Assignments ===');

        $product_table = [];
        foreach ($product_tags as $pid => $keys) {
            // Only include tags that passed the min-products filter
            $valid_keys = array_filter($keys, function ($k) use ($filtered_tags) {
                return isset($filtered_tags[$k]);
            });
            if (empty($valid_keys)) continue;

            $labels = array_map(function ($k) use ($keywords) {
                return $keywords[$k];
            }, $valid_keys);

            $product_table[] = [
                'ID'    => $pid,
                'Title' => get_the_title($pid),
                'Tags'  => implode(', ', $labels),
            ];
        }
        WP_CLI\Utils\format_items('table', $product_table, ['ID', 'Title', 'Tags']);

        // ── 6. Output: Unmatched products ──────────────────────────────
        if (!empty($unmatched)) {
            WP_CLI::log('');
            WP_CLI::log('=== Unmatched Products (need manual tagging) ===');
            $unmatched_table = [];
            foreach ($unmatched as $post) {
                $unmatched_table[] = [
                    'ID'    => $post->ID,
                    'Title' => $post->post_title,
                ];
            }
            WP_CLI\Utils\format_items('table', $unmatched_table, ['ID', 'Title']);
        }

        WP_CLI::log('');
        WP_CLI::log(sprintf(
            'Summary: %d tags (>= %d products), %d products tagged, %d unmatched',
            count($filtered_tags),
            $min_products,
            count($product_table),
            count($unmatched)
        ));

        // ── 7. Apply if requested ──────────────────────────────────────
        if (!$apply) {
            WP_CLI::log('');
            WP_CLI::log('Dry run. Use --apply to create tags and assign to products.');
            return;
        }

        WP_CLI::log('');
        WP_CLI::log('=== Applying Tags ===');

        $created = 0;
        $assigned = 0;

        foreach ($filtered_tags as $key => $product_ids) {
            $label = $keywords[$key];
            $slug  = sanitize_title($label);

            // Create or get the product_tag term
            $term = get_term_by('slug', $slug, 'product_tag');
            if (!$term) {
                $result = wp_insert_term($label, 'product_tag', ['slug' => $slug]);
                if (is_wp_error($result)) {
                    WP_CLI::warning("Failed to create tag '{$label}': " . $result->get_error_message());
                    continue;
                }
                $term_id = $result['term_id'];
                $created++;
                WP_CLI::log("  Created tag: {$label} (ID {$term_id})");
            } else {
                $term_id = $term->term_id;
            }

            // Assign to products (append, don't replace)
            foreach ($product_ids as $pid) {
                wp_set_object_terms($pid, [$term_id], 'product_tag', true);
                $assigned++;
            }
        }

        WP_CLI::success(sprintf('Done: %d tags created, %d assignments made.', $created, $assigned));
    });
}
