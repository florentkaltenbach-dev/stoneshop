<?php
/**
 * Steine mit Geschichte Theme Functions
 *
 * @package SteineMitGeschichte
 */

defined('ABSPATH') || exit;

/**
 * Theme Setup
 */
function smg_theme_setup() {
    // Add support for document title
    add_theme_support('title-tag');

    // Add support for post thumbnails
    add_theme_support('post-thumbnails');

    // Add support for HTML5 markup
    add_theme_support('html5', [
        'search-form',
        'comment-form',
        'comment-list',
        'gallery',
        'caption',
        'style',
        'script',
    ]);

    // Add support for WooCommerce
    add_theme_support('woocommerce');
    add_theme_support('wc-product-gallery-lightbox');
    add_theme_support('wc-product-gallery-slider');

    // Register navigation menus
    register_nav_menus([
        'primary' => __('Primary Navigation', 'steine-mit-geschichte'),
        'footer'  => __('Footer Navigation', 'steine-mit-geschichte'),
    ]);

    // Enable excerpt field on pages (used for front-page hero subtitle)
    add_post_type_support('page', 'excerpt');

    // Custom image sizes for object records
    add_image_size('object-thumbnail', 400, 400, false);
    add_image_size('object-medium', 800, 800, false);
    add_image_size('object-large', 1600, 1600, false);
}
add_action('after_setup_theme', 'smg_theme_setup');

/**
 * Disable WooCommerce hover zoom on single-product images.
 */
add_filter('woocommerce_single_product_zoom_enabled', '__return_false');

/**
 * Increase default WooCommerce single-product image target size.
 * This prevents browsers from selecting low-resolution 600px sources
 * when the image is rendered much larger in the custom layout.
 */
function smg_wc_single_image_size($size) {
    return [
        'width'  => 1600,
        'height' => '',
        'crop'   => 0,
    ];
}
add_filter('woocommerce_get_image_size_single', 'smg_wc_single_image_size');

/**
 * Enqueue Styles and Scripts
 */
function smg_enqueue_assets() {
    // Google Fonts - current primary pairing only
    $fonts_url = 'https://fonts.googleapis.com/css2?family=Cinzel:wght@400;500;600;700&family=EB+Garamond:ital,wght@0,400;0,500;0,600;1,400&display=swap';
    wp_enqueue_style('smg-google-fonts', $fonts_url, [], null);

    // Main stylesheet (contains design tokens)
    wp_enqueue_style(
        'smg-style',
        get_stylesheet_uri(),
        ['smg-google-fonts'],
        wp_get_theme()->get('Version')
    );

    // Component styles (with file modification time for cache busting)
    $component_css = get_template_directory() . '/assets/css/components.css';
    if (file_exists($component_css)) {
        wp_enqueue_style(
            'smg-components',
            get_template_directory_uri() . '/assets/css/components.css',
            ['smg-style'],
            filemtime($component_css)
        );
    }

    // Main JavaScript (when created)
    $main_js = get_template_directory() . '/assets/js/main.js';
    if (file_exists($main_js)) {
        wp_enqueue_script(
            'smg-main',
            get_template_directory_uri() . '/assets/js/main.js',
            [],
            wp_get_theme()->get('Version'),
            true
        );
    }

    // Index drawer for primary navigation access
    $drawer_js = get_template_directory() . '/assets/js/index-drawer.js';
    if (file_exists($drawer_js)) {
        wp_enqueue_script(
            'smg-index-drawer',
            get_template_directory_uri() . '/assets/js/index-drawer.js',
            [],
            filemtime($drawer_js),
            true
        );
    }
}
add_action('wp_enqueue_scripts', 'smg_enqueue_assets');

/**
 * Block Theme: Tell WooCommerce to keep using our PHP template overrides
 * (woocommerce/archive-product.php, woocommerce/single-product.php)
 * instead of its own block templates. Without this, WooCommerce detects
 * theme.json and bypasses our custom render layer entirely.
 */
add_filter('woocommerce_has_block_template', '__return_false');

/**
 * Block Theme: Force WC taxonomy archives to use our PHP template.
 * WordPress block template hierarchy resolves product_tag and product_cat
 * archives to templates/index.html before WooCommerce's template_include
 * can route them to archive-product.php. This filter overrides at priority
 * 100, after both WP block resolution and WC's template_loader (priority 10).
 */
function smg_force_wc_php_templates($template) {
    if (is_product_tag() || is_product_category()) {
        $wc_template = get_theme_file_path('woocommerce/archive-product.php');
        if (file_exists($wc_template)) {
            return $wc_template;
        }
    }
    return $template;
}
add_filter('template_include', 'smg_force_wc_php_templates', 100);

/**
 * Block Theme: Enqueue WC classic gallery scripts on product pages.
 * WC_Frontend_Scripts::load_scripts() (priority 10) skips gallery script
 * enqueue when wp_is_block_theme() returns true. Additionally,
 * BlockTemplatesController::dequeue_legacy_scripts (priority 20) explicitly
 * dequeues wc-single-product on product pages for block themes.
 * We re-enqueue the already-registered handles at priority 25, respecting
 * the theme's gallery feature declarations.
 */
function smg_enqueue_wc_gallery_scripts() {
    if (!is_product()) {
        return;
    }
    if (current_theme_supports('wc-product-gallery-slider')) {
        wp_enqueue_script('wc-flexslider');
    }
    if (current_theme_supports('wc-product-gallery-lightbox')) {
        wp_enqueue_script('wc-photoswipe-ui-default');
        wp_enqueue_style('photoswipe-default-skin');
        add_action('wp_footer', 'woocommerce_photoswipe');
    }
    wp_enqueue_script('wc-single-product');
}
add_action('wp_enqueue_scripts', 'smg_enqueue_wc_gallery_scripts', 25);

/**
 * Block Theme: Breadcrumb shortcode for use in block templates.
 * PHP templates call smg_breadcrumbs() directly; block templates
 * use [smg_breadcrumbs] via the core/shortcode block.
 */
function smg_breadcrumbs_shortcode() {
    ob_start();
    smg_breadcrumbs();
    return ob_get_clean();
}
add_shortcode('smg_breadcrumbs', 'smg_breadcrumbs_shortcode');

/**
 * Block Theme: Force frontend search to products only.
 * The core/search block cannot carry hidden fields, so we hook into
 * pre_get_posts to restrict the post type on the frontend.
 */
function smg_search_products_only($query) {
    if (!is_admin() && $query->is_main_query() && $query->is_search()) {
        $query->set('post_type', 'product');
    }
}
add_action('pre_get_posts', 'smg_search_products_only');

/**
 * Block Theme: Output index drawer HTML via wp_body_open.
 * This ensures the drawer works for both block templates (which don't use
 * header.php) and PHP templates (WooCommerce pages that still use header.php).
 */
function smg_render_index_drawer() {
    $collections_url = function_exists('wc_get_page_permalink')
        ? wc_get_page_permalink('shop')
        : home_url('/shop/');
    if (!$collections_url) {
        $collections_url = home_url('/shop/');
    }
    ?>
    <div class="index-drawer" id="index-drawer" aria-hidden="true">
        <div class="index-drawer__scrim" data-index-drawer-close aria-hidden="true"></div>
        <div class="index-drawer__panel" role="dialog" aria-modal="true" aria-labelledby="index-drawer-title">
            <header class="index-drawer__header">
                <h2 id="index-drawer-title" class="index-drawer__title">
                    <?php esc_html_e('Index', 'steine-mit-geschichte'); ?>
                </h2>
                <button type="button" class="index-drawer__close" data-index-drawer-close aria-label="<?php esc_attr_e('Close index', 'steine-mit-geschichte'); ?>">
                    <?php esc_html_e('Schlie&szlig;en', 'steine-mit-geschichte'); ?>
                </button>
            </header>

            <form role="search" method="get" class="index-drawer__search" action="<?php echo esc_url(home_url('/')); ?>">
                <label class="index-drawer__label" for="index-drawer-search">
                    <?php esc_html_e('Produkt suchen', 'steine-mit-geschichte'); ?>
                </label>
                <div class="index-drawer__field">
                    <input
                        type="search"
                        id="index-drawer-search"
                        class="index-drawer__input"
                        placeholder="<?php esc_attr_e('z. B. Steinpflege, Basalt, Kristall', 'steine-mit-geschichte'); ?>"
                        value="<?php echo esc_attr(get_search_query()); ?>"
                        name="s"
                    />
                    <input type="hidden" name="post_type" value="product" />
                </div>
            </form>

            <a class="index-drawer__collections" href="<?php echo esc_url($collections_url); ?>">
                <?php esc_html_e('Themen', 'steine-mit-geschichte'); ?>
            </a>

            <nav class="index-drawer__tree" aria-label="<?php esc_attr_e('Themen', 'steine-mit-geschichte'); ?>">
                <?php smg_render_product_tag_list(); ?>
            </nav>
        </div>
    </div>
    <?php
}
add_action('wp_body_open', 'smg_render_index_drawer');

/**
 * Widget Areas
 */
function smg_widgets_init() {
    register_sidebar([
        'name'          => __('Footer', 'steine-mit-geschichte'),
        'id'            => 'footer-widgets',
        'description'   => __('Footer widget area', 'steine-mit-geschichte'),
        'before_widget' => '<div id="%1$s" class="widget %2$s">',
        'after_widget'  => '</div>',
        'before_title'  => '<h3 class="widget-title">',
        'after_title'   => '</h3>',
    ]);
}
add_action('widgets_init', 'smg_widgets_init');

/**
 * Select a deterministic primary collection term for a product.
 * Rule: deepest assigned product category, excluding default category.
 */
function smg_get_primary_collection_term(int $product_id): ?WP_Term {
    $terms = get_the_terms($product_id, 'product_cat');
    if (empty($terms) || is_wp_error($terms)) {
        return null;
    }

    $default_category_id = (int) get_option('default_product_cat', 0);
    $terms = array_values(array_filter($terms, function ($term) use ($default_category_id) {
        return ($term instanceof WP_Term) && ((int) $term->term_id !== $default_category_id);
    }));

    if (empty($terms)) {
        return null;
    }

    $depth_cache = [];
    usort($terms, function (WP_Term $a, WP_Term $b) use (&$depth_cache) {
        $depth_a = $depth_cache[$a->term_id] ?? count(get_ancestors((int) $a->term_id, 'product_cat'));
        $depth_b = $depth_cache[$b->term_id] ?? count(get_ancestors((int) $b->term_id, 'product_cat'));
        $depth_cache[$a->term_id] = $depth_a;
        $depth_cache[$b->term_id] = $depth_b;

        if ($depth_a !== $depth_b) {
            return $depth_b <=> $depth_a;
        }

        $name_cmp = strcasecmp($a->name, $b->name);
        if ($name_cmp !== 0) {
            return $name_cmp;
        }

        return ((int) $a->term_id) <=> ((int) $b->term_id);
    });

    return $terms[0] ?? null;
}

/**
 * Breadcrumb Helper
 * Mandatory on object pages, text-based, hierarchical
 * Hierarchy: Home → Collections → [Collection Name] → [Stone Name]
 */
function smg_breadcrumbs() {
    if (is_front_page()) {
        return;
    }

    $separator = ' <span class="breadcrumb-separator" aria-hidden="true">·</span> ';
    $themes_url = wc_get_page_permalink('shop');
    $themes_label = __('Themen', 'steine-mit-geschichte');

    echo '<nav class="breadcrumbs" aria-label="' . esc_attr__('Breadcrumb', 'steine-mit-geschichte') . '">';
    echo '<a href="' . esc_url(home_url('/')) . '">' . esc_html__('Startseite', 'steine-mit-geschichte') . '</a>';

    if (is_shop() && !is_product_category() && !is_product_tag()) {
        // Tags Index page
        echo $separator;
        echo '<span aria-current="page">' . esc_html($themes_label) . '</span>';

    } elseif (is_product_tag()) {
        // Tag archive: Home → Themen → Tag Name
        $term = get_queried_object();
        echo $separator;
        echo '<a href="' . esc_url($themes_url) . '">' . esc_html($themes_label) . '</a>';
        echo $separator;
        echo '<span aria-current="page">' . esc_html($term->name) . '</span>';

    } elseif (is_singular('product')) {
        // Stone detail page: Home → Themen → Tag → Stone
        global $post;
        $tag = smg_get_primary_tag((int) $post->ID);

        echo $separator;
        echo '<a href="' . esc_url($themes_url) . '">' . esc_html($themes_label) . '</a>';

        if ($tag instanceof WP_Term) {
            echo $separator;
            echo '<a href="' . esc_url(get_term_link($tag)) . '">' . esc_html($tag->name) . '</a>';
        }

        echo $separator;
        echo '<span aria-current="page">' . esc_html(get_the_title()) . '</span>';

    } elseif (is_product_category()) {
        // Collection page (still accessible): Home → Themen → Collection
        $term = get_queried_object();

        echo $separator;
        echo '<a href="' . esc_url($themes_url) . '">' . esc_html($themes_label) . '</a>';

        $ancestors = get_ancestors($term->term_id, 'product_cat');
        $ancestors = array_reverse($ancestors);

        foreach ($ancestors as $ancestor_id) {
            $ancestor = get_term($ancestor_id, 'product_cat');
            echo $separator;
            echo '<a href="' . esc_url(get_term_link($ancestor)) . '">' . esc_html($ancestor->name) . '</a>';
        }

        echo $separator;
        echo '<span aria-current="page">' . esc_html($term->name) . '</span>';

    } elseif (is_page()) {
        echo $separator;
        echo '<span aria-current="page">' . esc_html(get_the_title()) . '</span>';
    }

    echo '</nav>';
}

/**
 * Body Classes
 */
function smg_body_classes($classes) {
    if (is_active_sidebar('footer-widgets')) {
        $classes[] = 'has-footer-widgets';
    }
    return $classes;
}
add_filter('body_class', 'smg_body_classes');


/* ==========================================================================
   WooCommerce Customization: Archival Interface
   ========================================================================== */

/**
 * Rename "Shop" to "Themen" throughout WooCommerce
 */
function smg_rename_shop_to_collections($title) {
    if (is_shop() && !is_product_category() && !is_search()) {
        return __('Themen', 'steine-mit-geschichte');
    }
    return $title;
}
add_filter('woocommerce_page_title', 'smg_rename_shop_to_collections');

/**
 * Change "Shop" in document title to "Themen"
 */
function smg_document_title_collections($title) {
    if (is_shop() && !is_product_category()) {
        $title['title'] = __('Themen', 'steine-mit-geschichte');
    }
    return $title;
}
add_filter('document_title_parts', 'smg_document_title_collections');

/**
 * Suppress WooCommerce Store UI Elements
 * Keep checkout functional but hide aggressive storefront elements
 */
function smg_suppress_store_ui() {
    // Remove prices from archive/loop
    remove_action('woocommerce_after_shop_loop_item_title', 'woocommerce_template_loop_price', 10);

    // Remove add-to-cart buttons from archive/loop
    remove_action('woocommerce_after_shop_loop_item', 'woocommerce_template_loop_add_to_cart', 10);

    // Remove sale flash/badges
    remove_action('woocommerce_before_shop_loop_item_title', 'woocommerce_show_product_loop_sale_flash', 10);
    remove_action('woocommerce_before_single_product_summary', 'woocommerce_show_product_sale_flash', 10);

    // Remove default related products (we show our own from same collection)
    remove_action('woocommerce_after_single_product_summary', 'woocommerce_output_related_products', 20);

    // Remove upsells
    remove_action('woocommerce_after_single_product_summary', 'woocommerce_upsell_display', 15);

    // Remove cross-sells from cart
    remove_action('woocommerce_cart_collaterals', 'woocommerce_cross_sell_display');

    // Remove product rating from archive
    remove_action('woocommerce_after_shop_loop_item_title', 'woocommerce_template_loop_rating', 5);

    // Remove result count and ordering from shop page
    remove_action('woocommerce_before_shop_loop', 'woocommerce_result_count', 20);
    remove_action('woocommerce_before_shop_loop', 'woocommerce_catalog_ordering', 30);

    // Remove sidebar on product pages
    remove_action('woocommerce_sidebar', 'woocommerce_get_sidebar', 10);

    // Replace <mark> with <span> in subcategory counts (removes browser-default yellow)
    add_filter('woocommerce_subcategory_count_html', function ($html) {
        return str_replace(['<mark', '</mark>'], ['<span', '</span>'], $html);
    });
}
add_action('init', 'smg_suppress_store_ui');

/**
 * Prices and Add to Cart are rendered in the stone detail template
 * (smg-render.php) rather than via WooCommerce summary hooks,
 * so we remove the default hooks to avoid duplication.
 */
function smg_hide_single_product_summary_hooks() {
    remove_action('woocommerce_single_product_summary', 'woocommerce_template_single_price', 10);
    remove_action('woocommerce_single_product_summary', 'woocommerce_template_single_add_to_cart', 30);
}
add_action('woocommerce_before_single_product', 'smg_hide_single_product_summary_hooks');

/**
 * Filter "Add to Cart" button text
 */
function smg_add_to_cart_text($text, $product) {
    return __('In den Warenkorb', 'steine-mit-geschichte');
}
add_filter('woocommerce_product_single_add_to_cart_text', 'smg_add_to_cart_text', 10, 2);
add_filter('woocommerce_product_add_to_cart_text', 'smg_add_to_cart_text', 10, 2);

/**
 * Hide "In Stock" / "Out of Stock" messages
 */
function smg_hide_stock_html($html, $product) {
    return '';
}
add_filter('woocommerce_get_stock_html', 'smg_hide_stock_html', 10, 2);

/**
 * Remove product meta (SKU, categories, tags) from single product
 */
function smg_remove_product_meta() {
    remove_action('woocommerce_single_product_summary', 'woocommerce_template_single_meta', 40);
}
add_action('woocommerce_before_single_product', 'smg_remove_product_meta');


/* ==========================================================================
   Translations / String Replacements
   ========================================================================== */

/**
 * Replace "Products" with "Objects" in various WooCommerce strings
 */
function smg_gettext_replacements($translated, $text, $domain) {
    if ($domain !== 'woocommerce') {
        return $translated;
    }

    $replacements = [
        'Products'          => __('Objekte', 'steine-mit-geschichte'),
        'Product'           => __('Objekt', 'steine-mit-geschichte'),
        'product'           => __('Objekt', 'steine-mit-geschichte'),
        'products'          => __('Objekte', 'steine-mit-geschichte'),
        'Shop'              => __('Themen', 'steine-mit-geschichte'),
        'Add to cart'       => __('In den Warenkorb', 'steine-mit-geschichte'),
        'Added to cart'     => __('Zum Warenkorb hinzugefügt', 'steine-mit-geschichte'),
        'View cart'         => __('Warenkorb ansehen', 'steine-mit-geschichte'),
        'Cart'              => __('Warenkorb', 'steine-mit-geschichte'),
        'Your cart'         => __('Ihr Warenkorb', 'steine-mit-geschichte'),
        'Cart totals'       => __('Zusammenfassung', 'steine-mit-geschichte'),
    ];

    if (isset($replacements[$text])) {
        return $replacements[$text];
    }

    return $translated;
}
add_filter('gettext', 'smg_gettext_replacements', 10, 3);


/* ==========================================================================
   Permalinks: Clean URLs
   ========================================================================== */

/**
 * Note: Permalink structure should be configured in WordPress Settings > Permalinks
 * Recommended structure for this archival theme:
 * - Product base: /stone/
 * - Product category base: /collection/
 *
 * These can be set via WooCommerce > Settings > Products > Product permalinks
 */

/**
 * Set product tag archive slug to /thema/ instead of /product-tag/
 */
add_filter('woocommerce_taxonomy_args_product_tag', function ($args) {
    $args['rewrite'] = ['slug' => 'thema', 'with_front' => false];
    return $args;
});

/**
 * Get a representative image ID for a collection term.
 * Prefers the WooCommerce term thumbnail; falls back to first product image.
 */
function smg_get_collection_image_id(int $term_id): int {
    $thumb_id = (int) get_term_meta($term_id, 'thumbnail_id', true);
    if ($thumb_id) {
        return $thumb_id;
    }

    $cache_key = 'smg_collection_image_' . $term_id;
    $cached = get_transient($cache_key);
    if ($cached !== false) {
        return (int) $cached;
    }

    $query = new WP_Query([
        'post_type'      => 'product',
        'posts_per_page' => 1,
        'no_found_rows'  => true,
        'tax_query'      => [[
            'taxonomy' => 'product_cat',
            'field'    => 'term_id',
            'terms'    => [$term_id],
        ]],
        'meta_query'     => [[
            'key'     => '_thumbnail_id',
            'compare' => 'EXISTS',
        ]],
        'orderby'        => 'date',
        'order'          => 'DESC',
    ]);

    $image_id = 0;
    if ($query->have_posts()) {
        $query->the_post();
        $image_id = (int) get_post_thumbnail_id(get_the_ID());
    }
    wp_reset_postdata();

    set_transient($cache_key, $image_id, 12 * HOUR_IN_SECONDS);

    return $image_id;
}

/**
 * Get a representative image ID for a product tag.
 * Queries the first product with a thumbnail in the tag, caches via transient.
 */
function smg_get_tag_image_id(int $term_id): int {
    // Explicit admin-chosen thumbnail takes priority
    $thumb_id = (int) get_term_meta($term_id, 'thumbnail_id', true);
    if ($thumb_id > 0) {
        return $thumb_id;
    }

    // Fall back to transient-cached auto-selection
    $cache_key = 'smg_tag_image_' . $term_id;
    $cached = get_transient($cache_key);
    if ($cached !== false) {
        return (int) $cached;
    }

    $query = new WP_Query([
        'post_type'      => 'product',
        'posts_per_page' => 1,
        'no_found_rows'  => true,
        'tax_query'      => [[
            'taxonomy' => 'product_tag',
            'field'    => 'term_id',
            'terms'    => [$term_id],
        ]],
        'meta_query'     => [[
            'key'     => '_thumbnail_id',
            'compare' => 'EXISTS',
        ]],
        'orderby'        => 'date',
        'order'          => 'DESC',
    ]);

    $image_id = 0;
    if ($query->have_posts()) {
        $query->the_post();
        $image_id = (int) get_post_thumbnail_id(get_the_ID());
    }
    wp_reset_postdata();

    set_transient($cache_key, $image_id, 12 * HOUR_IN_SECONDS);

    return $image_id;
}

/**
 * Render a flat list of product tags with counts (for the index drawer).
 */
function smg_render_product_tag_list(): void {
    $tags = get_terms([
        'taxonomy'   => 'product_tag',
        'hide_empty' => true,
        'orderby'    => 'name',
        'order'      => 'ASC',
    ]);

    if (empty($tags) || is_wp_error($tags)) {
        return;
    }

    echo '<ul class="smg-tag-list">';
    foreach ($tags as $tag) {
        $count = isset($tag->count) ? (int) $tag->count : 0;
        $url = get_term_link($tag);
        echo '<li class="smg-tag-list__item">';
        echo '<a class="smg-tag-list__link" href="' . esc_url($url) . '">';
        echo '<span class="smg-tag-list__name">' . esc_html($tag->name) . '</span>';
        echo '<span class="smg-tag-list__count">' . esc_html($count) . '</span>';
        echo '</a>';
        echo '</li>';
    }
    echo '</ul>';
}

/**
 * Get the primary product tag for a product (first by name, alphabetically).
 */
function smg_get_primary_tag(int $product_id): ?WP_Term {
    $tags = get_the_terms($product_id, 'product_tag');
    if (empty($tags) || is_wp_error($tags)) {
        return null;
    }

    usort($tags, function (WP_Term $a, WP_Term $b) {
        return strcasecmp($a->name, $b->name);
    });

    return $tags[0] ?? null;
}

/**
 * Render a nested category tree for product categories.
 */
function smg_render_product_category_tree(int $parent = 0, int $depth = 0): void {
    $terms = get_terms([
        'taxonomy'   => 'product_cat',
        'hide_empty' => false,
        'parent'     => $parent,
        'orderby'    => 'name',
        'order'      => 'ASC',
        'exclude'    => [get_option('default_product_cat', 0)],
    ]);

    if (empty($terms) || is_wp_error($terms)) {
        return;
    }

    echo '<ul class="smg-category-tree smg-category-tree--level-' . (int) $depth . '">';
    foreach ($terms as $term) {
        $count = isset($term->count) ? (int) $term->count : 0;
        $url = get_term_link($term);
        echo '<li class="smg-category-tree__item">';
        echo '<a class="smg-category-tree__link" href="' . esc_url($url) . '">';
        echo '<span class="smg-category-tree__name">' . esc_html($term->name) . '</span>';
        echo '<span class="smg-category-tree__count">' . esc_html($count) . '</span>';
        echo '</a>';
        smg_render_product_category_tree((int) $term->term_id, $depth + 1);
        echo '</li>';
    }
    echo '</ul>';
}
