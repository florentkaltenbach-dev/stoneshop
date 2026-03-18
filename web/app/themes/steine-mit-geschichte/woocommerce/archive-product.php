<?php
/**
 * Product archive template override (custom router).
 *
 * This file intentionally routes to the theme render layer instead of using
 * the default WooCommerce loop markup.
 *
 * @see https://woocommerce.com/document/template-structure/
 * @package WooCommerce\Templates
 * @version 8.6.0
 */

defined('ABSPATH') || exit;

get_header();

// Load render layer
require_once get_template_directory() . '/inc/smg-render.php';

// Router
if (is_shop() && !is_product_category() && !is_product_tag() && !is_search()) {
    smg_render_tags_index();
} elseif (is_product_tag()) {
    smg_render_tag_archive();
} else {
    smg_render_collection_page();
}

get_footer();
