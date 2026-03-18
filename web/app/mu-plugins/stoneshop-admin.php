<?php
/**
 * Plugin Name: StoneShop Admin Cleanup
 * Description: Strips the product edit screen down to essentials for the stone archive.
 * Version: 1.0.0
 */

defined('ABSPATH') || exit;

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

/* ==========================================================================
   3a. Remove Unused Meta Boxes
   ========================================================================== */

function stoneshop_remove_product_metaboxes() {
    remove_meta_box('postexcerpt', 'product', 'normal');
    remove_meta_box('slugdiv', 'product', 'normal');
    remove_meta_box('postcustom', 'product', 'normal');
    remove_meta_box('commentsdiv', 'product', 'normal');
    remove_meta_box('commentstatusdiv', 'product', 'normal');
    // WooCommerce Brands taxonomy metabox.
    remove_meta_box('product_branddiv', 'product', 'side');
    remove_meta_box('tagsdiv-product_brand', 'product', 'side');

    // Google Listings & Ads metabox.
    remove_meta_box('channel_visibility', 'product', 'side');
    remove_meta_box('channel_visibility', 'product', 'normal');

    // Replace default category checklist with single-select dropdown.
    remove_meta_box('product_catdiv', 'product', 'side');
    remove_meta_box('stoneshop_sku', 'product', 'side');

    remove_meta_box('woocommerce-product-data', 'product', 'normal');
}

add_action('add_meta_boxes_product', 'stoneshop_remove_product_metaboxes', 999);
add_action('do_meta_boxes', function ($post_type) {
    if ($post_type === 'product') {
        stoneshop_remove_product_metaboxes();
    }
}, 999, 1);

/* ==========================================================================
   3a.1 Single Product Category Selector
   ========================================================================== */

add_action('add_meta_boxes_product', function () {
    add_meta_box(
        'stoneshop_product_category',
        __('Produktkategorie', 'stoneshop'),
        'stoneshop_product_category_render',
        'product',
        'side',
        'default'
    );
}, 9);

function stoneshop_product_category_terms_flat() {
    $terms = get_terms([
        'taxonomy'   => 'product_cat',
        'hide_empty' => false,
    ]);

    if (is_wp_error($terms) || empty($terms)) {
        return [];
    }

    $by_parent = [];
    foreach ($terms as $term) {
        $parent = (int) $term->parent;
        if (!isset($by_parent[$parent])) {
            $by_parent[$parent] = [];
        }
        $by_parent[$parent][] = $term;
    }

    foreach ($by_parent as &$children) {
        usort($children, function ($a, $b) {
            return strcasecmp($a->name, $b->name);
        });
    }
    unset($children);

    $flat = [];
    $walk = function ($parent_id, $depth) use (&$walk, $by_parent, &$flat) {
        if (!isset($by_parent[$parent_id])) {
            return;
        }

        foreach ($by_parent[$parent_id] as $term) {
            $flat[] = [
                'term'  => $term,
                'depth' => $depth,
            ];
            $walk((int) $term->term_id, $depth + 1);
        }
    };

    $walk(0, 0);
    return $flat;
}

function stoneshop_product_category_render($post) {
    wp_nonce_field('stoneshop_product_category_nonce', 'stoneshop_product_category_nonce_field');
    $current_sku = strtoupper(trim((string) get_post_meta($post->ID, '_sku', true)));

    $assigned_ids = wp_get_post_terms($post->ID, 'product_cat', ['fields' => 'ids']);
    $selected_id = 0;
    if (!is_wp_error($assigned_ids) && !empty($assigned_ids)) {
        $assigned_ids = array_map('intval', $assigned_ids);
        sort($assigned_ids, SORT_NUMERIC);
        $selected_id = (int) $assigned_ids[0];

        // Legacy fallback: if multiple categories are assigned, prefer the one
        // matching the current SKU prefix to avoid accidental SKU/category flips.
        $current_prefix = stoneshop_sku_prefix_from_sku(get_post_meta($post->ID, '_sku', true));
        if ($current_prefix !== '') {
            foreach ($assigned_ids as $term_id) {
                $term_prefix = stoneshop_sku_normalize_prefix(get_term_meta($term_id, '_sku_prefix', true));
                if ($term_prefix === $current_prefix) {
                    $selected_id = (int) $term_id;
                    break;
                }
            }
        }
    }

    $flat_terms = stoneshop_product_category_terms_flat();
    ?>
    <label for="stoneshop_product_cat" class="screen-reader-text">
        <?php esc_html_e('Produktkategorie', 'stoneshop'); ?>
    </label>
    <select id="stoneshop_product_cat" name="stoneshop_product_cat" style="width:100%;">
        <option value=""><?php esc_html_e('— Kategorie wählen —', 'stoneshop'); ?></option>
        <?php foreach ($flat_terms as $row) :
            $term = $row['term'];
            $depth = (int) $row['depth'];
            $prefix = get_term_meta($term->term_id, '_sku_prefix', true);
            $indent = str_repeat('— ', $depth);
            $label = $indent . $term->name;
            if ($prefix) {
                $label .= ' (' . $prefix . ')';
            }
            ?>
            <option
                value="<?php echo esc_attr($term->term_id); ?>"
                <?php selected($selected_id, (int) $term->term_id); ?>
            >
                <?php echo esc_html($label); ?>
            </option>
        <?php endforeach; ?>
    </select>
    <?php if ($current_sku !== '') : ?>
        <p id="stoneshop_category_preview" style="margin:8px 0 0;color:#2271b1;font-weight:600;">
            <?php echo esc_html__('Aktuelle Artikelnummer:', 'stoneshop') . ' ' . esc_html($current_sku); ?>
        </p>
    <?php endif; ?>
    <p style="margin:6px 0 0;color:#666;">
        <?php esc_html_e('Eine Kategorie wählen. SKU wird automatisch beim Speichern gesetzt.', 'stoneshop'); ?>
    </p>
    <?php
}

add_action('save_post_product', function ($post_id) {
    if (!isset($_POST['stoneshop_product_category_nonce_field']) ||
        !wp_verify_nonce($_POST['stoneshop_product_category_nonce_field'], 'stoneshop_product_category_nonce')) {
        return;
    }
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (!current_user_can('edit_post', $post_id)) return;

    if (!isset($_POST['stoneshop_product_cat'])) {
        return;
    }

    $term_id = absint($_POST['stoneshop_product_cat']);
    if ($term_id > 0) {
        wp_set_object_terms($post_id, [$term_id], 'product_cat', false);
    } else {
        wp_set_object_terms($post_id, [], 'product_cat', false);
    }
}, 8);

/* ==========================================================================
   3a.2 Category Thumbnail Fallback
   ========================================================================== */

if (!function_exists('stoneshop_product_cat_current_thumbnail_id')) {
    function stoneshop_product_cat_current_thumbnail_id($term_id) {
        $thumbnail_id = absint(get_term_meta((int) $term_id, 'thumbnail_id', true));
        if ($thumbnail_id <= 0) {
            return 0;
        }

        $attachment = get_post($thumbnail_id);
        if (!$attachment || $attachment->post_type !== 'attachment') {
            return 0;
        }

        return $thumbnail_id;
    }
}

if (!function_exists('stoneshop_product_cat_first_product_image_id')) {
    function stoneshop_product_cat_first_product_image_id($term_id) {
        $featured_query = new WP_Query([
            'post_type'              => 'product',
            'post_status'            => 'publish',
            'posts_per_page'         => 1,
            'fields'                 => 'ids',
            'orderby'                => 'ID',
            'order'                  => 'ASC',
            'no_found_rows'          => true,
            'ignore_sticky_posts'    => true,
            'update_post_meta_cache' => false,
            'update_post_term_cache' => false,
            'meta_query'             => [
                [
                    'key'     => '_thumbnail_id',
                    'compare' => 'EXISTS',
                ],
                [
                    'key'     => '_thumbnail_id',
                    'value'   => 0,
                    'compare' => '>',
                    'type'    => 'NUMERIC',
                ],
            ],
            'tax_query'              => [
                [
                    'taxonomy'         => 'product_cat',
                    'field'            => 'term_id',
                    'terms'            => [(int) $term_id],
                    'include_children' => true,
                ],
            ],
        ]);

        if (!empty($featured_query->posts)) {
            $product_id = (int) $featured_query->posts[0];
            if ($product_id > 0) {
                $image_id = absint(get_post_thumbnail_id($product_id));
                if ($image_id > 0) {
                    return $image_id;
                }
            }
        }

        // Fallback: use first gallery image from first product in this category.
        $gallery_query = new WP_Query([
            'post_type'              => 'product',
            'post_status'            => 'publish',
            'posts_per_page'         => 1,
            'fields'                 => 'ids',
            'orderby'                => 'ID',
            'order'                  => 'ASC',
            'no_found_rows'          => true,
            'ignore_sticky_posts'    => true,
            'update_post_meta_cache' => false,
            'update_post_term_cache' => false,
            'meta_query'             => [
                [
                    'key'     => '_product_image_gallery',
                    'compare' => 'EXISTS',
                ],
                [
                    'key'     => '_product_image_gallery',
                    'value'   => '',
                    'compare' => '!=',
                ],
            ],
            'tax_query'              => [
                [
                    'taxonomy'         => 'product_cat',
                    'field'            => 'term_id',
                    'terms'            => [(int) $term_id],
                    'include_children' => true,
                ],
            ],
        ]);

        if (empty($gallery_query->posts)) {
            return 0;
        }

        $product_id = (int) $gallery_query->posts[0];
        if ($product_id <= 0) {
            return 0;
        }

        $gallery_raw = (string) get_post_meta($product_id, '_product_image_gallery', true);
        if ($gallery_raw === '') {
            return 0;
        }

        $gallery_ids = array_filter(array_map('absint', explode(',', $gallery_raw)));
        if (empty($gallery_ids)) {
            return 0;
        }

        return (int) $gallery_ids[0];
    }
}

if (!function_exists('stoneshop_product_cat_maybe_set_thumbnail')) {
    function stoneshop_product_cat_maybe_set_thumbnail($term_id) {
        $term_id = absint($term_id);
        if ($term_id <= 0) {
            return 0;
        }

        if (stoneshop_product_cat_current_thumbnail_id($term_id) > 0) {
            return 0;
        }

        $thumbnail_id = stoneshop_product_cat_first_product_image_id($term_id);
        if ($thumbnail_id <= 0) {
            return 0;
        }

        update_term_meta($term_id, 'thumbnail_id', $thumbnail_id);
        return $thumbnail_id;
    }
}

if (!function_exists('stoneshop_product_cat_backfill_thumbnails_once')) {
    function stoneshop_product_cat_backfill_thumbnails_once() {
        $version_key = 'stoneshop_product_cat_thumb_backfill_v1';
        if (get_option($version_key) === 'done') {
            return;
        }

        $term_ids = get_terms([
            'taxonomy'   => 'product_cat',
            'hide_empty' => false,
            'fields'     => 'ids',
        ]);

        if (is_wp_error($term_ids)) {
            return;
        }

        foreach ($term_ids as $term_id) {
            stoneshop_product_cat_maybe_set_thumbnail((int) $term_id);
        }

        update_option($version_key, 'done', false);
    }
}

add_action('init', 'stoneshop_product_cat_backfill_thumbnails_once', 30);
add_action('created_product_cat', 'stoneshop_product_cat_maybe_set_thumbnail', 20);
add_action('edited_product_cat', 'stoneshop_product_cat_maybe_set_thumbnail', 20);

add_action('save_post_product', function ($post_id) {
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (wp_is_post_revision($post_id)) return;
    if (get_post_type($post_id) !== 'product') return;
    $post_status = get_post_status($post_id);
    if (in_array($post_status, ['trash', 'auto-draft', 'inherit'], true)) return;

    $term_ids = wp_get_post_terms($post_id, 'product_cat', ['fields' => 'ids']);
    if (is_wp_error($term_ids) || empty($term_ids)) {
        return;
    }

    foreach ($term_ids as $term_id) {
        stoneshop_product_cat_maybe_set_thumbnail((int) $term_id);
    }
}, 25);

add_action('set_object_terms', function ($object_id, $terms, $tt_ids, $taxonomy) {
    if ($taxonomy !== 'product_cat') {
        return;
    }

    $object_id = absint($object_id);
    if ($object_id <= 0 || get_post_type($object_id) !== 'product') {
        return;
    }

    $term_ids = wp_get_post_terms($object_id, 'product_cat', ['fields' => 'ids']);
    if (is_wp_error($term_ids) || empty($term_ids)) {
        return;
    }

    foreach ($term_ids as $term_id) {
        stoneshop_product_cat_maybe_set_thumbnail((int) $term_id);
    }
}, 20, 4);

add_action('woocommerce_before_subcategory', function ($category) {
    if (is_object($category) && isset($category->term_id)) {
        stoneshop_product_cat_maybe_set_thumbnail((int) $category->term_id);
    }
}, 1);

/* ==========================================================================
   3a.3 Product Tag Thumbnail (mirrors Category Thumbnail)
   ========================================================================== */

/**
 * "Add New Tag" form fields — thumbnail picker
 */
add_action('product_tag_add_form_fields', function () {
    ?>
    <div class="form-field term-thumbnail-wrap">
        <label><?php esc_html_e('Thumbnail', 'stoneshop'); ?></label>
        <div id="product_tag_thumbnail" style="float:left;margin-right:10px;">
            <img src="<?php echo esc_url(wc_placeholder_img_src()); ?>" width="60" height="60" />
        </div>
        <div style="line-height:60px;">
            <input type="hidden" id="product_tag_thumbnail_id" name="product_tag_thumbnail_id" />
            <button type="button" class="upload_image_button button"><?php esc_html_e('Upload/Add image', 'stoneshop'); ?></button>
            <button type="button" class="remove_image_button button" style="display:none;"><?php esc_html_e('Remove image', 'stoneshop'); ?></button>
        </div>
        <div class="clear"></div>
    </div>
    <?php
});

/**
 * "Edit Tag" form fields — thumbnail picker
 */
add_action('product_tag_edit_form_fields', function ($term) {
    $thumbnail_id = absint(get_term_meta($term->term_id, 'thumbnail_id', true));
    $image = $thumbnail_id ? wp_get_attachment_url($thumbnail_id) : wc_placeholder_img_src();
    ?>
    <tr class="form-field term-thumbnail-wrap">
        <th scope="row" valign="top"><label><?php esc_html_e('Thumbnail', 'stoneshop'); ?></label></th>
        <td>
            <div id="product_tag_thumbnail" style="float:left;margin-right:10px;">
                <img src="<?php echo esc_url($image); ?>" width="60" height="60" />
            </div>
            <div style="line-height:60px;">
                <input type="hidden" id="product_tag_thumbnail_id" name="product_tag_thumbnail_id" value="<?php echo esc_attr($thumbnail_id); ?>" />
                <button type="button" class="upload_image_button button"><?php esc_html_e('Upload/Add image', 'stoneshop'); ?></button>
                <button type="button" class="remove_image_button button" <?php echo $thumbnail_id ? '' : 'style="display:none;"'; ?>><?php esc_html_e('Remove image', 'stoneshop'); ?></button>
            </div>
            <div class="clear"></div>
        </td>
    </tr>
    <?php
});

/**
 * Save tag thumbnail on create/edit
 */
add_action('created_product_tag', 'stoneshop_save_product_tag_thumbnail', 10, 2);
add_action('edited_product_tag', 'stoneshop_save_product_tag_thumbnail', 10, 2);

function stoneshop_save_product_tag_thumbnail($term_id, $tt_id = '') {
    if (isset($_POST['product_tag_thumbnail_id'])) {
        $thumbnail_id = absint($_POST['product_tag_thumbnail_id']);
        if ($thumbnail_id > 0) {
            update_term_meta($term_id, 'thumbnail_id', $thumbnail_id);
            delete_term_meta($term_id, '_thumbnail_is_auto'); // Admin chose this
        } else {
            delete_term_meta($term_id, 'thumbnail_id');
            delete_term_meta($term_id, '_thumbnail_is_auto');
        }
    }
}

/**
 * Enqueue media uploader JS on product_tag admin screens
 */
add_action('admin_enqueue_scripts', function ($hook) {
    if ($hook !== 'edit-tags.php' && $hook !== 'term.php') {
        return;
    }
    $screen = get_current_screen();
    if (!$screen || $screen->taxonomy !== 'product_tag') {
        return;
    }

    wp_enqueue_media();
    add_action('admin_footer', 'stoneshop_product_tag_thumbnail_js');
});

function stoneshop_product_tag_thumbnail_js() {
    ?>
    <script>
    jQuery(function($) {
        // Only run on product_tag screens
        if (typeof wp === 'undefined' || typeof wp.media === 'undefined') return;

        var frame;
        var $img    = $('#product_tag_thumbnail img');
        var $input  = $('#product_tag_thumbnail_id');
        var $upload = $('.upload_image_button');
        var $remove = $('.remove_image_button');
        var placeholder = '<?php echo esc_js(wc_placeholder_img_src()); ?>';

        $upload.on('click', function(e) {
            e.preventDefault();
            if (frame) { frame.open(); return; }

            frame = wp.media({
                title: '<?php echo esc_js(__('Choose an image', 'stoneshop')); ?>',
                button: { text: '<?php echo esc_js(__('Use image', 'stoneshop')); ?>' },
                multiple: false
            });

            frame.on('select', function() {
                var attachment = frame.state().get('selection').first().toJSON();
                var src = attachment.sizes && attachment.sizes.thumbnail
                    ? attachment.sizes.thumbnail.url
                    : attachment.url;
                $img.attr('src', src);
                $input.val(attachment.id);
                $remove.show();
            });

            frame.open();
        });

        $remove.on('click', function(e) {
            e.preventDefault();
            $img.attr('src', placeholder);
            $input.val('');
            $remove.hide();
        });

        // Reset fields after "Add New Tag" form is submitted (AJAX)
        $(document).ajaxComplete(function(event, request, options) {
            if (request && request.readyState === 4 && request.status === 200
                && options.data && options.data.indexOf('action=add-tag') !== -1) {
                $img.attr('src', placeholder);
                $input.val('');
                $remove.hide();
            }
        });
    });
    </script>
    <?php
}

/* ==========================================================================
   3a.4 Tag Image Cache Invalidation
   ========================================================================== */

/**
 * Flush tag image transients + re-evaluate auto thumbnails when a product is saved
 * (covers image changes and tag reassignment via the product editor)
 */
add_action('save_post_product', function ($post_id) {
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (wp_is_post_revision($post_id)) return;
    if (get_post_type($post_id) !== 'product') return;
    $post_status = get_post_status($post_id);
    if (in_array($post_status, ['trash', 'auto-draft', 'inherit'], true)) return;

    $tag_ids = wp_get_post_terms($post_id, 'product_tag', ['fields' => 'ids']);
    if (is_wp_error($tag_ids) || empty($tag_ids)) {
        return;
    }

    foreach ($tag_ids as $tag_id) {
        delete_transient('smg_tag_image_' . (int) $tag_id);
        stoneshop_product_tag_maybe_set_thumbnail((int) $tag_id);
    }
}, 20);

/**
 * Flush tag image transients + re-evaluate auto thumbnails when tag assignments change
 */
add_action('set_object_terms', function ($object_id, $terms, $tt_ids, $taxonomy, $append, $old_tt_ids) {
    if ($taxonomy !== 'product_tag') {
        return;
    }
    if (get_post_type($object_id) !== 'product') {
        return;
    }

    // Flush for both old and new tags
    $all_tt_ids = array_unique(array_merge($tt_ids, $old_tt_ids));
    foreach ($all_tt_ids as $tt_id) {
        $term = get_term_by('term_taxonomy_id', $tt_id, 'product_tag');
        if ($term && !is_wp_error($term)) {
            delete_transient('smg_tag_image_' . (int) $term->term_id);
            stoneshop_product_tag_maybe_set_thumbnail((int) $term->term_id);
        }
    }
}, 20, 6);

/**
 * Flush tag image transient when a tag is edited
 */
add_action('edited_product_tag', function ($term_id) {
    delete_transient('smg_tag_image_' . (int) $term_id);
}, 20);

/* ==========================================================================
   3a.5 Product Tag Thumbnail Auto-Fallback
   ========================================================================== */

if (!function_exists('stoneshop_product_tag_first_product_image_id')) {
    function stoneshop_product_tag_first_product_image_id($term_id) {
        $query = new WP_Query([
            'post_type'              => 'product',
            'post_status'            => 'publish',
            'posts_per_page'         => 1,
            'fields'                 => 'ids',
            'orderby'                => 'ID',
            'order'                  => 'ASC',
            'no_found_rows'          => true,
            'ignore_sticky_posts'    => true,
            'update_post_meta_cache' => false,
            'update_post_term_cache' => false,
            'meta_query'             => [
                [
                    'key'     => '_thumbnail_id',
                    'compare' => 'EXISTS',
                ],
                [
                    'key'     => '_thumbnail_id',
                    'value'   => 0,
                    'compare' => '>',
                    'type'    => 'NUMERIC',
                ],
            ],
            'tax_query'              => [
                [
                    'taxonomy' => 'product_tag',
                    'field'    => 'term_id',
                    'terms'    => [(int) $term_id],
                ],
            ],
        ]);

        if (!empty($query->posts)) {
            $image_id = absint(get_post_thumbnail_id((int) $query->posts[0]));
            if ($image_id > 0) {
                return $image_id;
            }
        }
        return 0;
    }
}

if (!function_exists('stoneshop_product_tag_maybe_set_thumbnail')) {
    /**
     * Auto-set a tag thumbnail from its first product image.
     * Skips tags with a manually-chosen thumbnail (no _thumbnail_is_auto flag).
     * Re-evaluates tags whose thumbnail was auto-set.
     */
    function stoneshop_product_tag_maybe_set_thumbnail($term_id) {
        $term_id = absint($term_id);
        if ($term_id <= 0) {
            return 0;
        }

        // Don't overwrite a manually-chosen thumbnail
        $existing = absint(get_term_meta($term_id, 'thumbnail_id', true));
        $is_auto = (bool) get_term_meta($term_id, '_thumbnail_is_auto', true);

        if ($existing > 0 && !$is_auto) {
            // Admin manually set this — leave it alone
            $att = get_post($existing);
            if ($att && $att->post_type === 'attachment') {
                return 0;
            }
        }

        // Find the best product image for this tag
        $thumbnail_id = stoneshop_product_tag_first_product_image_id($term_id);

        if ($thumbnail_id <= 0) {
            // No product image available — clean up auto-set thumbnail
            if ($existing > 0 && $is_auto) {
                delete_term_meta($term_id, 'thumbnail_id');
                delete_term_meta($term_id, '_thumbnail_is_auto');
            }
            return 0;
        }

        // Set (or update) the auto thumbnail
        update_term_meta($term_id, 'thumbnail_id', $thumbnail_id);
        update_term_meta($term_id, '_thumbnail_is_auto', 1);
        return $thumbnail_id;
    }
}

add_action('created_product_tag', 'stoneshop_product_tag_maybe_set_thumbnail', 25);

/* ==========================================================================
   3b. Simple "Details" Meta Box (replaces WooCommerce product data tabs)
   ========================================================================== */

add_action('add_meta_boxes_product', function () {
    add_meta_box(
        'stoneshop_details',
        __('Produktdetails', 'stoneshop'),
        'stoneshop_details_render',
        'product',
        'normal',
        'high'
    );
}, 10);

function stoneshop_details_render($post) {
    wp_nonce_field('stoneshop_details_nonce', 'stoneshop_details_nonce_field');

    $price  = get_post_meta($post->ID, '_regular_price', true);
    $weight = get_post_meta($post->ID, '_weight', true);
    $length = get_post_meta($post->ID, '_length', true);
    $width  = get_post_meta($post->ID, '_width', true);
    $height = get_post_meta($post->ID, '_height', true);
    ?>
    <div class="stoneshop-details-grid">
        <div class="stoneshop-field">
            <label for="stoneshop_price"><?php esc_html_e('Preis (€)', 'stoneshop'); ?></label>
            <input type="text" id="stoneshop_price" name="stoneshop_price"
                   value="<?php echo esc_attr($price); ?>" placeholder="0.00">
        </div>
        <div class="stoneshop-field">
            <label for="stoneshop_weight"><?php esc_html_e('Gewicht (kg)', 'stoneshop'); ?></label>
            <input type="text" id="stoneshop_weight" name="stoneshop_weight"
                   value="<?php echo esc_attr($weight); ?>" placeholder="0.0">
        </div>
        <div class="stoneshop-field">
            <label for="stoneshop_length"><?php esc_html_e('Länge (cm)', 'stoneshop'); ?></label>
            <input type="text" id="stoneshop_length" name="stoneshop_length"
                   value="<?php echo esc_attr($length); ?>" placeholder="0">
        </div>
        <div class="stoneshop-field">
            <label for="stoneshop_width"><?php esc_html_e('Breite (cm)', 'stoneshop'); ?></label>
            <input type="text" id="stoneshop_width" name="stoneshop_width"
                   value="<?php echo esc_attr($width); ?>" placeholder="0">
        </div>
        <div class="stoneshop-field">
            <label for="stoneshop_height"><?php esc_html_e('Höhe (cm)', 'stoneshop'); ?></label>
            <input type="text" id="stoneshop_height" name="stoneshop_height"
                   value="<?php echo esc_attr($height); ?>" placeholder="0">
        </div>
    </div>
    <style>
        .stoneshop-details-grid {
            display: grid;
            grid-template-columns: repeat(5, 1fr);
            gap: 12px;
        }
        .stoneshop-field label {
            display: block;
            font-weight: 600;
            margin-bottom: 4px;
            font-size: 13px;
        }
        .stoneshop-field input {
            width: 100%;
        }
    </style>
    <?php
}

/**
 * Save product details
 */
add_action('save_post_product', function ($post_id) {
    if (!isset($_POST['stoneshop_details_nonce_field']) ||
        !wp_verify_nonce($_POST['stoneshop_details_nonce_field'], 'stoneshop_details_nonce')) {
        return;
    }
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (!current_user_can('edit_post', $post_id)) return;

    $fields = [
        'stoneshop_price'  => '_regular_price',
        'stoneshop_weight' => '_weight',
        'stoneshop_length' => '_length',
        'stoneshop_width'  => '_width',
        'stoneshop_height' => '_height',
    ];

    foreach ($fields as $form_key => $meta_key) {
        if (isset($_POST[$form_key])) {
            $value = sanitize_text_field($_POST[$form_key]);
            update_post_meta($post_id, $meta_key, $value);
        }
    }

    // Keep _price in sync with _regular_price (WooCommerce expects this)
    if (isset($_POST['stoneshop_price'])) {
        $price = sanitize_text_field($_POST['stoneshop_price']);
        update_post_meta($post_id, '_price', $price);
    }
}, 15);

/* ==========================================================================
   Force Simple Product Type
   ========================================================================== */

add_action('save_post_product', function ($post_id) {
    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;
    if (wp_is_post_revision($post_id)) return;

    wp_set_object_terms($post_id, 'simple', 'product_type');
}, 5);

/* ==========================================================================
   3c. Frontend reCAPTCHA Badge Visibility
   ========================================================================== */

add_action('wp_head', function () {
    if (is_admin()) {
        return;
    }

    if (function_exists('is_checkout') && is_checkout()) {
        return;
    }
    ?>
    <style id="stoneshop-recaptcha-badge-visibility">
        .grecaptcha-badge {
            visibility: hidden !important;
            opacity: 0 !important;
            pointer-events: none !important;
        }
    </style>
    <?php
}, 99);

/* ==========================================================================
   3d. Admin CSS for Product Edit Screen
   ========================================================================== */

add_action('admin_head', function () {
    $screen = get_current_screen();
    if (!$screen || $screen->id !== 'product') return;
    ?>
    <style>
        /* Single category selector */
        #stoneshop_product_category select {
            width: 100%;
        }

        /* SKU meta box — prominent */
        #stoneshop_sku .inside {
            font-size: 16px;
        }
        #stoneshop_sku {
            border-left: 4px solid #2271b1;
        }

        /* Gallery area wider */
        #woocommerce-product-images .inside {
            padding: 8px;
        }
        #woocommerce-product-images .product_images {
            min-height: 200px;
        }

        /* Hide WooCommerce product type selector (if it leaks through) */
        .product_data_tabs,
        #woocommerce-product-data {
            display: none !important;
        }
        #product_branddiv,
        #tagsdiv-product_brand,
        #channel_visibility {
            display: none !important;
        }

        /* Publish box: keep only Publish/Update button */
        #submitdiv #minor-publishing,
        #submitdiv #misc-publishing-actions,
        #submitdiv #delete-action,
        #submitdiv .misc-pub-section {
            display: none !important;
        }
        #submitdiv #major-publishing-actions {
            border-top: 0 !important;
            background: transparent !important;
        }
        #submitdiv #major-publishing-actions a {
            display: none !important;
        }
        #submitdiv #publishing-action {
            float: none !important;
            width: 100%;
            text-align: right;
        }
        #submitdiv #publish {
            float: none !important;
        }

        /* General tightening */
        #postdivrich {
            margin-bottom: 16px;
        }
    </style>
    <?php
});
